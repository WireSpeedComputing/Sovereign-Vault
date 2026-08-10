#!/usr/bin/env bash
# tests/replay_fresh_install.sh
#
# Prove this repo builds from an empty database. Run this before trusting any
# claim that the repo and a deployment agree.
#
# WHY: for weeks this repo had never been proven to build from scratch, and
# during that window several files sat here as commented-out pseudocode that
# had never been executed. A repo that has only ever been applied incrementally
# to one long-lived database is not a repo you can rebuild from.
#
# Runs an ISOLATED PostgreSQL cluster on a non-default port with its own data
# directory, so it cannot touch any existing local server. Requires postgresql
# 15+ and pgvector available to that installation. No cloud project, no cost.
#
# Usage:  ./tests/replay_fresh_install.sh [path-to-sql-dir]
# Exit 0 = clean replay. Non-zero = a file failed; the error is printed.

set -uo pipefail

# macOS/Homebrew PG17 aborts at startup with "postmaster became multithreaded
# during startup" when the inherited locale is not one initdb can resolve --
# the postmaster's own HINT is to set LC_ALL. This script had been passing on
# this host and started failing on nothing but a locale change, so pin it
# rather than leave the harness dependent on the caller's shell.
export LC_ALL="${LC_ALL:-C}"

SQL_DIR="${1:-$(cd "$(dirname "$0")/../sql" && pwd)}"
PORT="${REPLAY_PORT:-5433}"
PGDATA_DIR="${REPLAY_PGDATA:-/tmp/svreplay_pgdata}"
SOCK_DIR="${REPLAY_SOCK:-/tmp/svreplay_sock}"
DB="svreplay"

cleanup() {
  pg_ctl -D "$PGDATA_DIR" stop -m fast >/dev/null 2>&1 || true
  rm -rf "$PGDATA_DIR" "$SOCK_DIR"
}
trap cleanup EXIT

echo "== initializing isolated cluster =="
rm -rf "$PGDATA_DIR" "$SOCK_DIR"
mkdir -p "$SOCK_DIR"
initdb -D "$PGDATA_DIR" >/tmp/svreplay_initdb.log 2>&1 || { echo "initdb FAILED, see /tmp/svreplay_initdb.log"; exit 1; }
pg_ctl -D "$PGDATA_DIR" \
  -o "-p $PORT -k $SOCK_DIR -c listen_addresses=''" \
  -l /tmp/svreplay_server.log start >/dev/null || { echo "server start FAILED, see /tmp/svreplay_server.log"; exit 1; }
sleep 2

export PGHOST="$SOCK_DIR" PGPORT="$PORT"
createdb "$DB" || { echo "createdb FAILED"; exit 1; }

echo "== applying $SQL_DIR in numeric order =="
FAILED=0
for f in $(ls "$SQL_DIR"/*.sql | sort); do
  if out=$(psql -d "$DB" -v ON_ERROR_STOP=1 -q -f "$f" 2>&1); then
    echo "  OK    $(basename "$f")"
  else
    echo "  FAIL  $(basename "$f")"
    echo "$out" | grep -E "ERROR|FATAL" | head -5 | sed 's/^/        /'
    FAILED=1
    break
  fi
done
[ "$FAILED" -ne 0 ] && { echo "REPLAY FAILED"; exit 1; }

echo "== post-replay verification =="
PERIM=$(psql -d "$DB" -t -A -c "select count(*) from perimeter_assert();")
echo "  perimeter_assert findings (want 0): $PERIM"

NORLS=$(psql -d "$DB" -t -A -c "select coalesce(string_agg(c.relname,', '),'(none)') from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r' and not c.relrowsecurity;")
echo "  tables missing RLS (want none): $NORLS"

echo "  repo-owned functions:"
psql -d "$DB" -t -A -c "select string_agg(p.proname,',' order by p.proname) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and not exists (select 1 from pg_depend d where d.objid=p.oid and d.deptype='e');" | tr ',' '\n' | sed 's/^/    /'

echo "  tables with rows after replay (expect only schema_changelog, provenance_registry, perimeter_exception):"
psql -d "$DB" -t -A -c "select coalesce(string_agg(relname||'='||n_live_tup,', '),'(all empty)') from pg_stat_user_tables where n_live_tup>0;" | sed 's/^/    /'

if [ "$PERIM" != "0" ] || [ "$NORLS" != "(none)" ]; then
  echo "REPLAY APPLIED BUT VERIFICATION FAILED"
  exit 1
fi

# ── validation suite ──────────────────────────────────────────────────────
# Upstream #46 requires the guard tests run in the validation suite, not by
# hand. Every tests/NN_*.sql runs here unless it declares REQUIRES-DEPLOYMENT.
#
# A glob rather than a named list, deliberately: a new test file is picked up by
# existing, not by someone remembering to register it. A test nobody runs is
# indistinguishable from one that was never written.
#
# REQUIRES-DEPLOYMENT is an explicit opt-out, not a heuristic. The first version
# of this loop guessed -- it skipped any file containing :' (a psql variable)
# and ran everything else. That was wrong twice in one run: it skipped
# 23_promotion_guards_negative.sql, which merely contains the string
# 'raw_artifacts:', and it RAN 12_compliance_check_*.sql, which needs seeded
# compliance rules a fresh cluster does not have. Guessing which tests can run
# is exactly the sort of thing that quietly stops running a test.
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
SUITE_FAILED=0
SUITE_UNRESOLVED=0
SUITE_SKIPPED=0
SUITE_PASSED=0
echo "== validation suite =="
for tf in $(ls "$TEST_DIR"/[0-9]*.sql 2>/dev/null | sort); do
  # Line-anchored, and only in the header. The first version grepped for the
  # token ANYWHERE in the file, so a test file that merely DESCRIBED the
  # mechanism in a comment silently opted itself out and was never run --
  # which happened, to three new suites at once. A skip that can be triggered
  # by documentation is a skip nobody notices.
  # ── A SKIP IS NOT A PASS EITHER ─────────────────────────────────────────
  # This opt-out is still honoured, but it no longer buys a clean top line.
  # Two suites sat behind it for months -- 03 (owner/visibility isolation over
  # the boot surfaces) and 12 (six compliance regressions) -- and every replay
  # printed SKIP for both and then REPLAY CLEAN with exit 0. Neither actually
  # needed a deployment; one wanted three uuids substituted by hand and the
  # other wanted seed data that sql/53 has since shipped. Both now provision
  # their own fixtures and are scored.
  #
  # Counting skips into the same gate as unresolved suites means the next
  # suite to declare the opt-out has to justify it to whoever reads the exit
  # code, rather than disappearing behind a word that looks deliberate.
  if head -40 "$tf" | grep -qE '^-- REQUIRES-DEPLOYMENT(:|$)'; then
    echo "  SKIP  $(basename "$tf") (declares REQUIRES-DEPLOYMENT -- NOT scored)"
    SUITE_SKIPPED=$((SUITE_SKIPPED+1))
    continue
  fi
  if ! out=$(psql -d "$DB" -v ON_ERROR_STOP=1 -f "$tf" 2>&1); then
    echo "  FAIL  $(basename "$tf") (error)"
    echo "$out" | grep -E "ERROR|FATAL" | head -5 | sed 's/^/        /'
    SUITE_FAILED=1
    continue
  fi
  # ── READ THE VERDICT, DO NOT INFER IT ──────────────────────────────────
  # These files exit 0 even when an assertion is false, so the runner has to
  # decide. It used to grep the formatted output for '| f |'. That was wrong in
  # BOTH directions:
  #   * an assertion evaluating to NULL prints a BLANK cell, so real failures
  #     were invisible (21 of 24 assertions once "passed" against a function
  #     that lacked the feature entirely);
  #   * a file that legitimately prints boolean `actual`/`expected` data columns
  #     matched the pattern and was reported as failing when every assertion
  #     passed.
  # A suite must state its own verdict. Files emit `SUITE_RESULT: PASS|FAIL`.
  if echo "$out" | grep -q 'SUITE_RESULT: FAIL'; then
    echo "  FAIL  $(basename "$tf")"
    echo "$out" | grep -E 'SUITE_RESULT|\| f ' | head -8 | sed 's/^/        /'
    SUITE_FAILED=1
  elif echo "$out" | grep -q 'SUITE_RESULT: PASS'; then
    echo "  PASS  $(basename "$tf")"
    SUITE_PASSED=$((SUITE_PASSED+1))
  else
    # ── UNRESOLVED IS NOT A PASS, AND THERE IS NO LONGER A FALLBACK ────────
    # There used to be two heuristics here: a scan for '| f |' in the formatted
    # output, and a scan for the literal '*** FAIL ***'. Both are gone.
    #
    # They were removed rather than narrowed, on purpose. A heuristic that can
    # score a suite is a heuristic that can EXCUSE a suite from stating its own
    # verdict, and every unscored suite in this project's history got there by
    # being tolerable to the runner. While a fallback existed, "no SUITE_RESULT"
    # was a survivable condition; now it is a non-zero exit.
    #
    # Nothing is lost by deleting the '*** FAIL ***' scan:
    # 20_disease_claim_term_coverage.sql is the only file that emits that
    # marker, and its own derived verdict is computed from the same rows
    # (`WHERE result <> 'PASS'`), so the signal is read by the file itself
    # rather than inferred from its formatting by someone else.
    #
    # The '| f |' scan was wrong in both directions and is documented as such
    # above: a NULL assertion prints a blank cell and read as a pass, and a
    # suite printing legitimate boolean data columns read as a failure.
    echo "  UNRESOLVED  $(basename "$tf") (no SUITE_RESULT verdict -- cannot be scored)"
    SUITE_UNRESOLVED=$((SUITE_UNRESOLVED+1))
  fi
done
[ "$SUITE_FAILED" -ne 0 ] && { echo "VALIDATION SUITE FAILED"; exit 1; }

# Exit 2, not 0 and not 1. An unresolved suite is not a failure and it is not a
# pass; reporting it as either is how this went unnoticed. "Everything that
# could be scored passed" is a different claim from "everything passed", and the
# top line must not make the second claim while the second is unknown.
if [ "$SUITE_UNRESOLVED" -ne 0 ] || [ "$SUITE_SKIPPED" -ne 0 ]; then
  echo
  echo "REPLAY INCOMPLETE -- $SUITE_UNRESOLVED unscored, $SUITE_SKIPPED skipped, $SUITE_PASSED passed."
  echo "Every suite that COULD be scored passed. That is not the same as a clean"
  echo "replay, and this line exists so the difference is visible. Give the"
  echo "unresolved suites a derived SUITE_RESULT line, and justify or remove any"
  echo "REQUIRES-DEPLOYMENT opt-out."
  exit 2
fi

echo
# The count is printed on the CLEAN line deliberately. "REPLAY CLEAN" on its own
# is true of a run that scored twenty-five suites and of a run that scored none;
# this project has shipped both and could not tell them apart from the top line.
echo "REPLAY CLEAN -- $SUITE_PASSED suite(s) scored, 0 unresolved, 0 skipped."
echo "NOTE: a local replay cannot prove cloud-host default-privilege behavior"
echo "on newly created objects, nor extension placement. Those still require"
echo "validation against a real hosted project."
