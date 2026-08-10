#!/usr/bin/env bash
# tests/prove_gates_discriminate.sh
#
# WO-18 Task 4. Break every gate deliberately and record TWO things about each:
# whether it caught the break at all, and whether the break was visible in the
# TOP-LINE VERDICT rather than only in detail output.
#
# ── WHY THE SECOND COLUMN IS THE POINT ────────────────────────────────────
# This project's recurring failure is not a check that returns the wrong answer.
# It is a check that returns the right answer where nobody reads it. A suite
# printed real failures while the run reported CLEAN and exited 0. A perimeter
# checker returned two hundred rows of noise and got muted. A body-coverage gate
# reported CANNOT VERIFY for months because its prerequisite lived outside the
# artifact. Every one of those was a correct check with an unread result.
#
# So "caught" is not the pass condition here. "Caught, and said so in the line a
# human or a CI job actually looks at" is.
#
# ── METHOD ────────────────────────────────────────────────────────────────
# The replay runner's SCORING is the unit under test for group A, so group A
# drives it with synthetic suites against a minimal schema rather than replaying
# the real one. That is deliberate: it isolates the runner's verdict logic from
# the 27 real suites, runs in seconds instead of minutes, and each real suite
# already carries its own documented discrimination check.
#
# Every case asserts an EXPECTED exit code and an EXPECTED top-line string.
# A gate that cannot be made to fail is reported as a FINDING, not a pass.
#
# Usage:  ./tests/prove_gates_discriminate.sh
# Exit 0 = every gate discriminated and said so up top.

set -uo pipefail
export LC_ALL="${LC_ALL:-C}"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d /tmp/gatediscrim.XXXXXX)"
RESULTS="$WORK/results.tsv"
: > "$RESULTS"
FAILURES=0

cleanup() { pg_ctl -D "$WORK/pgdata" stop -m fast >/dev/null 2>&1 || true; }
trap cleanup EXIT

# record <gate> <break> <caught yes/no> <topline yes/no> <detail>
record() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$RESULTS"
  if [ "$3" != "yes" ] || [ "$4" != "yes" ]; then
    FAILURES=$((FAILURES+1))
    echo "  FINDING  $1 / $2 -- caught=$3 topline=$4"
  else
    echo "  ok       $1 / $2"
  fi
}

# ══════════════════════════════════════════════════════════════════════════
# GROUP A -- the replay runner's verdict logic
# ══════════════════════════════════════════════════════════════════════════
echo "== group A: replay runner scoring =="
A="$WORK/runnerA"
mkdir -p "$A/tests" "$A/sql"
cp "$REPO/tests/replay_fresh_install.sh" "$A/tests/"
# Minimal schema: the runner's post-replay verification requires
# perimeter_assert() to exist and return zero, and every public table to have
# RLS. One table with RLS satisfies both without dragging in the real schema.
cat > "$A/sql/00_minimal.sql" <<'SQL'
create table t_min(id int primary key);
alter table t_min enable row level security;
create function perimeter_assert()
returns table(category text, object_schema text, object_name text,
              grantee text, privilege text)
language sql stable as $$ select null::text, null::text, null::text,
                                 null::text, null::text where false $$;
SQL

mk_suite() { printf '%s\n' "$2" > "$A/tests/$1"; }

run_A() {  # run_A <expected_exit> <expected_topline_regex> <label>
  local exp_exit="$1" exp_top="$2" label="$3" out ec
  out=$(cd "$A" && ./tests/replay_fresh_install.sh "$A/sql" 2>&1); ec=$?
  local caught=no topline=no
  [ "$ec" = "$exp_exit" ] && caught=yes
  echo "$out" | grep -qE "$exp_top" && topline=yes
  echo "$out" > "$WORK/A_${label}.log"
  echo "$caught $topline $ec"
}

# A0 -- CONTROL. Without this, every case below could be satisfied by a runner
# that fails on everything, and the whole group would prove nothing.
rm -f "$A"/tests/[0-9]*.sql
mk_suite "10_ok.sql" "select 'SUITE_RESULT: PASS' as verdict;"
read -r c t ec <<< "$(run_A 0 '^REPLAY CLEAN -- 1 suite' A0)"
record "replay runner" "CONTROL: one passing suite (expect clean)" "$c" "$t" "exit=$ec"

# A1 -- a suite that states FAIL
mk_suite "11_fail.sql" "select 'SUITE_RESULT: FAIL' as verdict;"
read -r c t ec <<< "$(run_A 1 '^VALIDATION SUITE FAILED' A1)"
record "replay runner" "suite emits SUITE_RESULT: FAIL" "$c" "$t" "exit=$ec"
rm -f "$A/tests/11_fail.sql"

# A2 -- a suite with no verdict at all. This is the legacy-heuristic case: it
# used to score PASS?, then UNRESOLVED-with-fallback, and must now be fatal.
mk_suite "12_noverdict.sql" "select 1 as some_column;"
read -r c t ec <<< "$(run_A 2 '^REPLAY INCOMPLETE' A2)"
record "replay runner" "suite emits no SUITE_RESULT line" "$c" "$t" "exit=$ec"
rm -f "$A/tests/12_noverdict.sql"

# A3 -- a suite whose only failure signal is a NULL assertion printing a blank
# cell. This is the exact shape that made 21 of 24 assertions "pass" against a
# function that lacked the feature entirely.
mk_suite "13_null.sql" "$(cat <<'SQL'
select null::boolean as pass;
select case when count(*) = 0 then 'SUITE_RESULT: PASS'
            else 'SUITE_RESULT: FAIL' end as verdict
from (select null::boolean as pass) x where pass is not true;
SQL
)"
read -r c t ec <<< "$(run_A 1 '^VALIDATION SUITE FAILED' A3)"
record "replay runner" "assertion evaluates to NULL (blank cell)" "$c" "$t" "exit=$ec"
rm -f "$A/tests/13_null.sql"

# A4 -- a suite that errors outright
mk_suite "14_err.sql" "select * from table_that_does_not_exist;"
read -r c t ec <<< "$(run_A 1 '^VALIDATION SUITE FAILED' A4)"
record "replay runner" "suite raises a SQL error" "$c" "$t" "exit=$ec"
rm -f "$A/tests/14_err.sql"

# A5 -- a suite opting out via REQUIRES-DEPLOYMENT. Before WO-18 this printed
# SKIP and the run still reported CLEAN at exit 0.
mk_suite "15_skip.sql" "$(printf -- '-- REQUIRES-DEPLOYMENT: synthetic opt-out\nselect 1;\n')"
read -r c t ec <<< "$(run_A 2 '^REPLAY INCOMPLETE' A5)"
record "replay runner" "suite declares REQUIRES-DEPLOYMENT" "$c" "$t" "exit=$ec"
rm -f "$A/tests/15_skip.sql"

# A6 -- a schema file that fails to apply
cp "$A/sql/00_minimal.sql" "$WORK/00_minimal.bak"
echo "select * from nope_not_here;" >> "$A/sql/00_minimal.sql"
read -r c t ec <<< "$(run_A 1 '^REPLAY FAILED' A6)"
record "replay runner" "schema file fails to apply" "$c" "$t" "exit=$ec"
cp "$WORK/00_minimal.bak" "$A/sql/00_minimal.sql"

# A7 -- a table without RLS. Post-replay verification, not the suite loop.
echo "create table t_norls(id int);" >> "$A/sql/00_minimal.sql"
read -r c t ec <<< "$(run_A 1 'REPLAY APPLIED BUT VERIFICATION FAILED' A7)"
record "replay runner" "table created without RLS" "$c" "$t" "exit=$ec"
cp "$WORK/00_minimal.bak" "$A/sql/00_minimal.sql"

# A8 -- perimeter_assert returning a violation
sed -i.bak 's/where false/where true/' "$A/sql/00_minimal.sql"
read -r c t ec <<< "$(run_A 1 'REPLAY APPLIED BUT VERIFICATION FAILED' A8)"
record "replay runner" "perimeter_assert returns a row" "$c" "$t" "exit=$ec"
cp "$WORK/00_minimal.bak" "$A/sql/00_minimal.sql"

# ══════════════════════════════════════════════════════════════════════════
# GROUP B -- migration drift checker
# ══════════════════════════════════════════════════════════════════════════
echo "== group B: migration drift =="
DRIFT="$REPO/tests/migration_drift.sh"
B="$WORK/drift"; mkdir -p "$B"

run_B() {  # run_B <tsv> <expected_exit> <expected_topline_regex> <label>
  local out ec caught=no topline=no
  # Invoked through bash on purpose: migration_drift.sh is not chmod +x in the
  # repo, and the first version of this harness called it directly and recorded
  # "Permission denied" as a gate that failed to discriminate. A harness bug
  # reported as a gate defect is the same class of error the harness exists to
  # find, so it is called the way its callers call it.
  out=$(cd "$REPO" && bash "$DRIFT" "$1" 2>&1); ec=$?
  [ "$ec" = "$2" ] && caught=yes
  echo "$out" | grep -qE "$3" && topline=yes
  echo "$out" > "$WORK/B_$4.log"
  echo "$caught $topline $ec"
}

# Build an applied.tsv that reconciles, from the repo's own baseline.
if [ -f "$REPO/tests/migration_baseline.txt" ]; then
  awk 'NF' "$REPO/tests/migration_baseline.txt" > "$B/applied_ok.tsv"
  # B1 -- an applied migration with no repo file
  { cat "$B/applied_ok.tsv"; printf '9999\tghost_migration_that_has_no_file\n'; } > "$B/applied_ghost.tsv"
  read -r c t ec <<< "$(run_B "$B/applied_ghost.tsv" 1 'MIGRATION DRIFT DETECTED' B1)"
  record "migration drift" "applied migration with no repo file" "$c" "$t" "exit=$ec"

  # B2 -- body coverage unverifiable: point BODIES_REPO at an empty dir
  mkdir -p "$B/empty"
  out=$(cd "$REPO" && BODIES_REPO="$B/empty" bash "$DRIFT" "$B/applied_ok.tsv" 2>&1); ec=$?
  c=no; t=no
  [ "$ec" = "3" ] || [ "$ec" = "1" ] && c=yes
  echo "$out" | grep -qE 'BODY COVERAGE IS UNVERIFIED|MIGRATION DRIFT DETECTED' && t=yes
  echo "$out" > "$WORK/B_B2.log"
  record "migration drift" "bodies repo absent (BODIES_REPO -> empty path)" "$c" "$t" "exit=$ec"
else
  record "migration drift" "no migration_baseline.txt to build a fixture from" "no" "no" "SKIPPED - FINDING"
fi

# ══════════════════════════════════════════════════════════════════════════
# GROUP C -- Rule 0 secret sweep
# ══════════════════════════════════════════════════════════════════════════
echo "== group C: rule 0 sweep =="
# DISCOVERED, NOT NAMED -- same rule, and the same mistake made here first.
# The first version of this file hardcoded the private repo's directory name to
# locate the sweep, and the sweep caught it: the CONTROL case failed because
# this very file had introduced a Rule 0 violation into the public repo. That is
# the fourth instance of a control whose prerequisite was written by name rather
# than discovered, and the second in two days inside the tooling built to catch
# that class.
#
# The sweep is found by looking for a sibling directory that CONTAINS a
# rule0-sweep.sh, never by naming the repository it lives in.
SWEEP=""
_siblings="$(cd "$REPO/.." 2>/dev/null && pwd)"
if [ -n "$_siblings" ]; then
  for _cand in "$_siblings"/*/; do
    if [ -f "${_cand}rule0-sweep.sh" ]; then SWEEP="${_cand}rule0-sweep.sh"; break; fi
  done
fi

if [ -n "$SWEEP" ] && [ -f "$SWEEP" ]; then
  # The sweep takes the PUBLIC repo to scan as $1; it is not a no-arg command.
  # Sweeping the public vault is what the push gate actually does.
  SCANME="$WORK/publicrepo"; mkdir -p "$SCANME"
  cp -R "$REPO/." "$SCANME/" 2>/dev/null
  rm -rf "$SCANME/.git"
  # C0 -- CONTROL: an unmodified public repo must sweep clean. Without this,
  # C1 is satisfied by a sweep that fails on everything.
  out=$(bash "$SWEEP" "$SCANME" 2>&1); ec=$?
  c=no; t=no
  [ "$ec" = "0" ] && c=yes
  echo "$out" | grep -qE 'SWEEP CLEAN' && t=yes
  echo "$out" > "$WORK/C_C0.log"
  record "rule 0 sweep" "CONTROL: unmodified repo (expect clean)" "$c" "$t" "exit=$ec"

  # C1 -- plant a KNOWN identifier. This is what the sweep is actually built to
  # find, and it must find it.
  #
  # The identifier is EXTRACTED FROM THE SWEEP'S OWN PATTERN LIST at runtime and
  # never written into this file. Writing a real project ref into a public test
  # fixture is itself the Rule 0 violation the sweep exists to stop -- and the
  # first version of this case did exactly that, which the CONTROL above caught
  # on the next run. Second time in this one file that naming a secret rather
  # than discovering it produced a leak.
  #
  # Side effect worth having: if the denylist is ever rewritten, this case tests
  # whatever the list actually contains rather than what it contained today.
  KNOWN_IDENT="$(grep -oE '"[a-z]{15,}\|[^"]*"' "$SWEEP" | head -1 \
                  | tr -d '"' | cut -d'|' -f1)"
  if [ -z "$KNOWN_IDENT" ]; then
    record "rule 0 sweep" "could not extract a known identifier from the sweep" "no" "no" "FINDING"
  else
  printf 'connection notes for project %s\n' "$KNOWN_IDENT" > "$SCANME/PLANTED_IDENT_TESTFILE.md"
  out=$(bash "$SWEEP" "$SCANME" 2>&1); ec=$?
  c=no; t=no
  [ "$ec" != "0" ] && c=yes
  echo "$out" | grep -qE 'SWEEP FAILED' && t=yes
  echo "$out" > "$WORK/C_C1.log"
  record "rule 0 sweep" "planted KNOWN identifier (project ref)" "$c" "$t" "exit=$ec"
  rm -f "$SCANME/PLANTED_IDENT_TESTFILE.md"
  fi

  # C2 -- plant a CREDENTIAL that is not on the denylist: a live-shaped Postgres
  # URL with a password, for a project ref the sweep has never seen.
  #
  # THIS CASE IS EXPECTED TO FAIL TODAY AND IS LEFT FAILING ON PURPOSE.
  # The sweep matches a fixed list of hard identifiers -- two project refs, some
  # personal and company names, the agent codenames. It carries no pattern for
  # secrets as a CLASS: no password-in-URL, no JWT, no service_role key, no
  # cloud provider token. A credential for any project not already on the list
  # sweeps clean and is safe to push, according to the gate that exists to stop
  # exactly that.
  #
  # This matters right now for two reasons. The owner is about to ROTATE the
  # database password: the new one is, by construction, not on any denylist. And
  # every push in this project is gated on this script's exit code, which means
  # the gate is trusted precisely as far as its list is current.
  #
  # Not fixed here. Widening a push gate is an owner decision, the sweep's own
  # header calls it "a judgement gate, not a lint rule", and WO-18 forbids new
  # capability during a health pass. Recorded as a finding instead.
  printf 'postgresql://postgres:hunter2ExampleSecret@db.abcdefghijklmnop.supabase.co:5432/postgres\n' \
    > "$SCANME/PLANTED_SECRET_TESTFILE.md"
  out=$(bash "$SWEEP" "$SCANME" 2>&1); ec=$?
  c=no; t=no
  [ "$ec" != "0" ] && c=yes
  echo "$out" | grep -qE 'SWEEP FAILED' && t=yes
  echo "$out" > "$WORK/C_C2.log"
  record "rule 0 sweep" "planted CREDENTIAL not on the denylist (KNOWN GAP)" "$c" "$t" "exit=$ec"
else
  record "rule 0 sweep" "no sibling rule0-sweep.sh discovered" "no" "no" "FINDING"
fi

# ══════════════════════════════════════════════════════════════════════════
echo
echo "== GATE DISCRIMINATION TABLE =="
printf '%-18s | %-52s | %-7s | %-8s\n' "GATE" "HOW IT WAS BROKEN" "CAUGHT" "TOP-LINE"
printf '%-18s-+-%-52s-+-%-7s-+-%-8s\n' "$(printf '%.0s-' {1..18})" "$(printf '%.0s-' {1..52})" "-------" "--------"
while IFS=$'\t' read -r g b c t d; do
  printf '%-18s | %-52s | %-7s | %-8s\n' "$g" "${b:0:52}" "$c" "$t"
done < "$RESULTS"

echo
if [ "$FAILURES" -ne 0 ]; then
  echo "GATE AUDIT FAILED -- $FAILURES gate case(s) did not catch the break or did"
  echo "not surface it in the top-line verdict. A gate that cannot be made to fail"
  echo "is a finding, not a pass. Logs: $WORK"
  trap - EXIT; cleanup
  exit 1
fi
echo "GATE AUDIT CLEAN -- every case above was caught AND visible in the top line."
echo "Logs: $WORK"
