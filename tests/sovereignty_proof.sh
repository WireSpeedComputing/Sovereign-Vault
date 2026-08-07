#!/usr/bin/env bash
# tests/sovereignty_proof.sh
#
# The end-to-end harness for upstream sovereign-memory-core #58. Runs the whole
# claim, start to finish, with two genuinely separate PostgreSQL environments:
#
#   1. build a SOURCE environment  (port 5461) from sql/*.sql + a disposable fixture
#   2. EXPORT a sovereign package from it, read-only
#   3. RESTORE into a second, clean DESTINATION environment (port 5462)
#   4. VERIFY the destination against the package -- definition level, not names
#   5. PROVE THE VERIFIER CAN FAIL by corrupting the destination, one damage at
#      a time, and asserting each is caught by the check that should catch it
#
# Step 5 is not optional decoration. Steps 1-4 produce a green transcript
# whether or not the checks work. Without step 5 this is another green report.
#
# ── ISOLATION ─────────────────────────────────────────────────────────────
# Ports 5461 and 5462, data directories /tmp/agentB_pgdata and
# /tmp/agentB_restore_pgdata. Deliberately disjoint from
# tests/replay_fresh_install.sh (5433, /tmp/svreplay_pgdata) so both can run at
# once. Nothing here touches any hosted project; there is no credential to hold.
#
# ── USAGE ─────────────────────────────────────────────────────────────────
#   ./tests/sovereignty_proof.sh [--keep] [--skip-discrimination]
#
#   --keep                 leave both clusters running for inspection
#   --skip-discrimination  run 1-4 only. The transcript then says, in as many
#                          words, that it does not establish the checks work.
#
# Exit 0 = the full proof passed.

set -uo pipefail
export LC_ALL="${LC_ALL:-C}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TESTS_DIR="$REPO_ROOT/tests"

SRC_PORT="${SOURCE_PORT:-5461}"
SRC_PGDATA="${SOURCE_PGDATA:-/tmp/agentB_pgdata}"
SRC_SOCK="${SOURCE_SOCK:-/tmp/agentB_sock}"
SRC_DB="svsource"

DST_PORT="${RESTORE_PORT:-5462}"
DST_PGDATA="${RESTORE_PGDATA:-/tmp/agentB_restore_pgdata}"
DST_SOCK="${RESTORE_SOCK:-/tmp/agentB_restore_sock}"
DST_DB="svrestore"

PKG_DIR="${PACKAGE_DIR:-/tmp/agentB_package}"

KEEP=0
SKIP_DISC=0
for a in "$@"; do
  [ "$a" = "--keep" ] && KEEP=1
  [ "$a" = "--skip-discrimination" ] && SKIP_DISC=1
done

STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cleanup() {
  if [ "$KEEP" -eq 0 ]; then
    pg_ctl -D "$SRC_PGDATA" stop -m fast >/dev/null 2>&1 || true
    pg_ctl -D "$DST_PGDATA" stop -m fast >/dev/null 2>&1 || true
    rm -rf "$SRC_PGDATA" "$SRC_SOCK" "$DST_PGDATA" "$DST_SOCK"
  fi
}
trap cleanup EXIT

banner() {
  echo
  echo "=========================================================================="
  echo " $*"
  echo "=========================================================================="
}

die() { echo; echo "SOVEREIGNTY PROOF FAILED at: $*" >&2; exit 1; }

banner "SOVEREIGNTY PROOF -- upstream sovereign-memory-core #58"
echo " started (UTC) : $STARTED"
echo " repo          : $REPO_ROOT"
echo " source env    : port $SRC_PORT  $SRC_PGDATA"
echo " destination   : port $DST_PORT  $DST_PGDATA"
echo " package       : $PKG_DIR"
if git -C "$REPO_ROOT" rev-parse HEAD >/dev/null 2>&1; then
  echo " commit        : $(git -C "$REPO_ROOT" rev-parse HEAD)"
  DIRTY_N=$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  echo " uncommitted   : $DIRTY_N file(s)"
  [ "$DIRTY_N" != "0" ] && echo "   ^ the package records these. A dirty tree is not a pinned commit."
fi

# ── 1. source environment ─────────────────────────────────────────────────
banner "1/5  BUILD SOURCE ENVIRONMENT (port $SRC_PORT)"
pg_ctl -D "$SRC_PGDATA" stop -m fast >/dev/null 2>&1 || true
rm -rf "$SRC_PGDATA" "$SRC_SOCK"
mkdir -p "$SRC_SOCK"
initdb -D "$SRC_PGDATA" >/tmp/agentB_src_initdb.log 2>&1 || die "source initdb (see /tmp/agentB_src_initdb.log)"
pg_ctl -D "$SRC_PGDATA" -o "-p $SRC_PORT -k $SRC_SOCK -c listen_addresses=''" \
  -l /tmp/agentB_src_server.log start >/dev/null || die "source server start (see /tmp/agentB_src_server.log)"
sleep 2
export PGHOST="$SRC_SOCK" PGPORT="$SRC_PORT"
createdb "$SRC_DB" || die "source createdb"

N=0
for f in $(ls "$REPO_ROOT"/sql/*.sql | sort); do
  if out=$(psql -d "$SRC_DB" -v ON_ERROR_STOP=1 -q -f "$f" 2>&1); then
    N=$((N+1))
  else
    echo "  FAIL  $(basename "$f")"
    printf '%s\n' "$out" | grep -E "ERROR|FATAL" | head -5 | sed 's/^/        /'
    die "applying $(basename "$f")"
  fi
done
echo "  applied $N sql file(s) from the repo working tree"

psql -d "$SRC_DB" -v ON_ERROR_STOP=1 -q -f "$TESTS_DIR/sovereign_fixture.sql" >/dev/null 2>/tmp/agentB_fixture.err \
  || { sed 's/^/        /' /tmp/agentB_fixture.err | head -10; die "loading tests/sovereign_fixture.sql"; }
FIXROWS=$(psql -d "$SRC_DB" -t -A -c "select sum(n) from (select count(*) n from memories union all select count(*) from wiki_pages union all select count(*) from retrieval_units union all select count(*) from principals) s;")
echo "  fixture loaded (memories+wiki+units+principals = $FIXROWS rows)"
echo "  NOTE: disposable synthetic data. No real data is used anywhere in this proof."

# ── 2. export ─────────────────────────────────────────────────────────────
banner "2/5  EXPORT SOVEREIGN PACKAGE"
PGDATABASE="$SRC_DB" bash "$TESTS_DIR/export_sovereign_package.sh" "$PKG_DIR" || die "export"

# ── 3. restore ────────────────────────────────────────────────────────────
banner "3/5  RESTORE INTO A SECOND CLEAN ENVIRONMENT (port $DST_PORT)"
# Deliberately unset the source connection so a mistake in the restore script
# cannot silently talk to the source. The restore must stand up its own cluster.
unset PGHOST PGPORT PGDATABASE
bash "$TESTS_DIR/restore_sovereign_package.sh" "$PKG_DIR" --keep || die "restore"

export PGHOST="$DST_SOCK" PGPORT="$DST_PORT"

# Independent evidence that the destination is a different server from the
# source, not the same one under another name. Without this, "restored into a
# second environment" is an assertion about a shell variable.
SRC_ID=$(PGHOST="$SRC_SOCK" PGPORT="$SRC_PORT" psql -d "$SRC_DB" -t -A -c "select system_identifier::text from pg_control_system();")
DST_ID=$(psql -d "$DST_DB" -t -A -c "select system_identifier::text from pg_control_system();")
echo
echo "  source cluster system_identifier      : $SRC_ID"
echo "  destination cluster system_identifier : $DST_ID"
if [ "$SRC_ID" = "$DST_ID" ]; then
  die "source and destination are the SAME cluster -- the restore proved nothing"
fi
echo "  distinct clusters confirmed."

# ── 4. verify ─────────────────────────────────────────────────────────────
banner "4/5  VERIFY THE RESTORE"
VERIFY_RC=0
bash "$TESTS_DIR/verify_restore.sh" "$PKG_DIR" "$DST_DB" || VERIFY_RC=1
[ "$VERIFY_RC" -eq 0 ] || die "verification"

# ── 5. prove the verifier can fail ────────────────────────────────────────
if [ "$SKIP_DISC" -eq 1 ]; then
  banner "5/5  DISCRIMINATION PROOF -- SKIPPED"
  echo "  --skip-discrimination was passed."
  echo
  echo "  READ THIS: steps 1-4 above produce the same green transcript whether"
  echo "  the checks work or not. A verifier that has only ever printed OK is"
  echo "  indistinguishable from one that compares a string to itself. Without"
  echo "  step 5, THIS RUN DOES NOT ESTABLISH THAT THE VERIFICATION WORKS."
else
  banner "5/5  PROVE THE VERIFIER CAN FAIL"
  bash "$TESTS_DIR/prove_verifier_discriminates.sh" "$PKG_DIR" "$DST_DB" || die "discrimination proof"
fi

banner "SOVEREIGNTY PROOF COMPLETE"
echo " started  (UTC): $STARTED"
echo " finished (UTC): $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo " package       : $PKG_DIR"
echo " package sha256: $(shasum -a 256 "$PKG_DIR/CHECKSUMS.sha256" | awk '{print $1}')"
echo
echo " WHAT WAS PROVEN"
echo "   * the repo's own sql/*.sql rebuilds the schema in an empty cluster"
echo "   * a package exported from that cluster restores into a DIFFERENT cluster"
echo "     with no reference to the original host"
echo "   * the restored copy matches the source at the level of DEFINITIONS --"
echo "     bodies, signatures, ownership, security mode, search paths, grants,"
echo "     triggers, policies, constraints and indexes -- not object names"
echo "   * every guard, probe and integrity surface behaves identically after"
echo "     the restore as before the export"
[ "$SKIP_DISC" -eq 0 ] && \
echo "   * the verification CAN fail, and fails on the INTENDED check for each"
echo "     of 22 deliberate corruptions -- including the exact sql/27 body with"
echo "     one ACL predicate removed -- while correctly ignoring that same body"
echo "     condensed the way the applied migration condensed it"
echo "   * full write-up: docs/07-sovereignty-export-restore.md"
echo
echo " WHAT WAS NOT PROVEN -- see KNOWN LIMITATIONS in $PKG_DIR/MANIFEST.md"
echo "   * this used a fixture. The live deployment's data has never been"
echo "     through this pipeline."
echo "   * canonicalized definition equality is not semantic equivalence."
echo "   * vanilla PostgreSQL cannot reproduce Supabase default-privilege"
echo "     behavior, so a local clean perimeter is weaker than a hosted one."
echo "   * PostgREST, edge functions, cron, storage and auth are not in the"
echo "     package and are not restored. This is a system of record, not a"
echo "     running product."
echo "   * a sha256 is not a signature."
if [ "$KEEP" -eq 1 ]; then
  echo
  echo " clusters left running (--keep):"
  echo "   source:      PGHOST=$SRC_SOCK PGPORT=$SRC_PORT psql -d $SRC_DB"
  echo "   destination: PGHOST=$DST_SOCK PGPORT=$DST_PORT psql -d $DST_DB"
  echo "   stop: pg_ctl -D $SRC_PGDATA stop -m fast; pg_ctl -D $DST_PGDATA stop -m fast"
fi
exit 0
