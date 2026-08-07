#!/usr/bin/env bash
# tests/prove_verifier_discriminates.sh
#
# DELIBERATELY CORRUPT a restored fixture, once per damage type, and assert that
# tests/verify_restore.sh CATCHES each one — and that it does NOT fire on a
# change that is genuinely equivalent.
#
# ── WHY THIS FILE EXISTS ──────────────────────────────────────────────────
# A verifier that has only ever printed OK proves nothing. It is
# indistinguishable from a verifier whose checks silently query the wrong table,
# compare a string to itself, or return zero rows and call that a match. This
# project has shipped exactly that kind of check before -- a name-equality
# replay comparison read as proof of definition equivalence, a perimeter check
# that returned two hundred rows of extension noise, a secret sweep that matched
# shell builtins. Every one of them looked green.
#
# So: every check in verify_restore.sh gets a corruption designed to trip it,
# and the run FAILS if a corruption goes undetected. The last case is the
# opposite direction and matters just as much -- a semantically identical
# function body written in condensed form must NOT be reported as drift, because
# that is the real sql/27 case and a checker that cries wolf gets muted.
#
# ── METHOD ────────────────────────────────────────────────────────────────
# Each case gets its OWN database, cloned from the freshly restored one with
# `createdb --template`. No case can see another's damage, and the pristine
# restore is never mutated. Everything here happens in the DESTINATION cluster,
# which is disposable by construction; the source is never touched.
#
# ── USAGE ─────────────────────────────────────────────────────────────────
#   PGHOST=... PGPORT=... ./tests/prove_verifier_discriminates.sh <package> <restored-db>
#
# Exit 0 = the verifier discriminates. 1 = at least one corruption went
# undetected (or an equivalence was falsely reported as drift).

set -uo pipefail
export LC_ALL="${LC_ALL:-C}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TESTS_DIR="$REPO_ROOT/tests"
PKG="${1:-}"
BASE_DB="${2:-svrestore}"

[ -n "$PKG" ] && [ -d "$PKG" ] || { echo "usage: $0 <package-dir> <restored-db>" >&2; exit 2; }
PKG="$(cd "$PKG" && pwd)"
WORK="$(mktemp -d)"
FAILED=0
CASE_N=0

cleanup() {
  for d in $(psql -d postgres -t -A -c "select datname from pg_database where datname like 'svcorrupt_%'" 2>/dev/null); do
    dropdb --force "$d" >/dev/null 2>&1 || true
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "=========================================================================="
echo " PROVING THE VERIFIER CAN FAIL"
echo " base restored db: $BASE_DB   cluster: ${PGHOST:-<default>}:${PGPORT:-<default>}"
echo "=========================================================================="
echo

# Control: the pristine restore must PASS. If it does not, every "caught"
# result below is meaningless -- a verifier that fails on everything catches
# nothing in particular.
echo "-- CONTROL: pristine restore must PASS --"
if bash "$TESTS_DIR/verify_restore.sh" "$PKG" "$BASE_DB" > "$WORK/control.txt" 2>&1; then
  echo "   PASS  pristine restore verifies clean ($(grep -c '^  PASS' "$WORK/control.txt") checks)"
else
  echo "   FAIL  pristine restore does NOT verify clean -- corruption results below"
  echo "         would be meaningless. Aborting."
  grep -E '^  FAIL' "$WORK/control.txt" | sed 's/^/         /'
  exit 1
fi
echo

# run_case <name> <expect: CAUGHT|CLEAN> <expected-check-prefix|-> <sql>
run_case() {
  local name="$1" expect="$2" want_check="$3" sql="$4"
  CASE_N=$((CASE_N+1))
  local db="svcorrupt_$(printf '%02d' "$CASE_N")"

  dropdb --force "$db" >/dev/null 2>&1 || true
  createdb -T "$BASE_DB" "$db" >/dev/null 2>&1 || {
    echo "   FAIL  $name (could not clone $BASE_DB)"; FAILED=1; return; }

  # Damage is applied with triggers off where the schema's own guards would
  # (correctly) refuse it. That is the point: the guards stop a CALLER, they do
  # not stop someone with superuser on the destination. The verifier has to
  # catch what the guards cannot.
  # session_replication_role=replica turns the row triggers off; event_triggers=off
  # stops the DDL changelog from recording the damage. Both are what a tamperer
  # with superuser would do, and both keep each case isolated to the ONE check it
  # is testing -- without event_triggers=off every DDL corruption would also trip
  # the row-count check via schema_changelog, and "caught" would stop meaning
  # "caught by the check that is supposed to catch it".
  if ! psql -d "$db" -X -q -v ON_ERROR_STOP=1 > "$WORK/$db.sql.log" 2>&1 <<SQLEOF
set session_replication_role = replica;
set event_triggers = off;
$sql
set event_triggers = on;
set session_replication_role = origin;
SQLEOF
  then
    echo "   FAIL  $name (the corruption itself errored -- the case is not testing what it claims)"
    sed 's/^/         /' "$WORK/$db.sql.log" | grep -E 'ERROR' | head -3
    FAILED=1
    dropdb --force "$db" >/dev/null 2>&1
    return
  fi

  local rc=0
  bash "$TESTS_DIR/verify_restore.sh" "$PKG" "$db" > "$WORK/$db.verify.txt" 2>&1 || rc=1
  local got="CLEAN"
  [ "$rc" -ne 0 ] && got="CAUGHT"

  local verdict="FAIL"
  if [ "$got" = "$expect" ]; then
    verdict="PASS"
    if [ "$expect" = "CAUGHT" ] && [ "$want_check" != "-" ]; then
      if ! grep -qE "^  FAIL  $want_check" "$WORK/$db.verify.txt"; then
        verdict="FAIL"
        echo "   FAIL  $name -- caught, but NOT by check $want_check (caught by the wrong check)"
        grep -E '^  FAIL' "$WORK/$db.verify.txt" | head -5 | sed 's/^/         /'
        FAILED=1
        dropdb --force "$db" >/dev/null 2>&1
        return
      fi
    fi
  else
    FAILED=1
  fi

  echo "   $verdict  $name"
  echo "         expected $expect, got $got"
  if [ "$got" = "CAUGHT" ]; then
    grep -E '^  FAIL' "$WORK/$db.verify.txt" | sed 's/^/         > /'
    # one line of the actual failure detail, so the transcript shows the
    # verifier naming the damage rather than merely returning non-zero
    awk '/^  FAIL/{f=1;next} f&&/^        /{print "         > "$0; c++; if(c>=2) exit}' \
      "$WORK/$db.verify.txt"
  fi
  dropdb --force "$db" >/dev/null 2>&1
}

echo "-- CORRUPTIONS --"

run_case "A/B  a row is deleted" CAUGHT "A" \
  "delete from review_queue where kind = 'low_provenance';"

run_case "B    a single field is altered, row count unchanged" CAUGHT "B" \
  "update principals set notes = 'silently altered' where kind = 'agent';"

run_case "C    an evidence locator's rendered text is tampered with" CAUGHT "C" \
  "update retrieval_units set rendered_text = rendered_text || ' [INJECTED]'
   where id = (select id from retrieval_units where invalidated_at is null
               order by exact_locator limit 1);"

run_case "D    a lifecycle state is rewritten in place" CAUGHT "D" \
  "update memories set status = 'current'
   where id = (select id from memories where status = 'entered_in_error' limit 1);"

run_case "E    a required citation is erased" CAUGHT "E" \
  "update memories set citation = null
   where provenance_basis = 'decision_record' and citation is not null;"

run_case "F    a supersession chain is broken" CAUGHT "F" \
  "update memories set supersedes = null
   where supersedes is not null;"

run_case "G    the hot index is corrupted (touch_count below its floor)" CAUGHT "G" \
  "update memory_hot_index set touch_count = 0;"

run_case "H    the perimeter is opened to anon" CAUGHT "H" \
  "grant select on memories to anon;"

run_case "J    a FUNCTION BODY is rewritten under the SAME NAME" CAUGHT "J" \
  "create or replace function is_owner_or_shared(p_row_owner uuid,
     p_row_visibility visibility_level, p_principal_id uuid)
   returns boolean language sql stable set search_path to 'public' as \$fn\$
     select true;
   \$fn\$;"

run_case "J    an index is dropped" CAUGHT "J" \
  "drop index idx_memories_owner;"

run_case "J    a function is flipped to SECURITY INVOKER" CAUGHT "J" \
  "alter function memory_hot_ranked_for(uuid) security invoker;"

run_case "J    a constraint is dropped" CAUGHT "J" \
  "alter table retrieval_units drop constraint retrieval_units_source_relation_check;"

run_case "J    a search_path is removed from a definer function" CAUGHT "J" \
  "alter function promote_memory(uuid, uuid) reset search_path;"

run_case "K    a guard trigger is dropped" CAUGHT "J" \
  "drop trigger trg_insert_status_sanction_memories on memories;"

run_case "K    a sanctioned function stops checking the principal" CAUGHT "J" \
  "create or replace function promote_memory(p_id uuid, p_promoted_by uuid)
   returns text language plpgsql security definer set search_path = public as \$fn\$
   begin
     set local app.promoting = 'on';
     update memories set status = 'current' where id = p_id;
     set local app.promoting = 'off';
     return 'promoted';
   end; \$fn\$;"

# embed_error rather than workstream: workstream is referenced by the
# deadlines_upcoming view, and PostgreSQL refuses to retype a column a view
# depends on. The first version of this case picked workstream, errored, and was
# reported as FAIL "the corruption itself errored" -- which is the harness
# refusing to score a case that never tested anything.
run_case "J    a column TYPE is changed" CAUGHT "J" \
  "alter table memories alter column embed_error type varchar(100);"

run_case "J    a column DEFAULT is moved back to 'current'" CAUGHT "J" \
  "alter table memories alter column status set default 'current';"

run_case "J    RLS is switched off on a table" CAUGHT "H" \
  "alter table memories disable row level security;"

run_case "J    a trigger is repointed at a different function" CAUGHT "J" \
  "drop trigger trg_enforce_provenance_memories on memories;
   create trigger trg_enforce_provenance_memories before insert or update on memories
     for each row execute function enforce_artifact_promotable();"

# ── THE sql/27 CASE, END TO END ───────────────────────────────────────────
# The self-test in canonicalize_inventory.py pins this on an abbreviated body.
# Here it runs against the REAL refresh_retrieval_units() -- 4KB of plpgsql with
# nine comment blocks -- through the whole verifier, twice:
#
#   * condensed, semantics untouched            -> must verify CLEAN
#   * condensed, ONE ACL predicate removed      -> must be CAUGHT by J
#
# The two differ by 51 characters out of ~3500 -- the deleted predicate is
# `and ru.workstream is not distinct from m.workstream`, measured, not estimated.
# (An earlier draft of this comment said 32 and disagreed with docs/07, which
# said 51. docs/07 was right. Two numbers for one fact is how a document stops
# being evidence.) If the verifier called the first
# drift it would cry wolf on the real deployed/repo pair; if it called the second
# clean it would miss the exact defect sql/27 exists to fix. Both directions on
# the same body is the only way to show it is doing neither.
#
# The condensation below is done with sed/tr -- deliberately NOT with
# canonicalize_inventory.py, so this is not the canonicalizer grading its own
# homework.
RRU_SIG="refresh_retrieval_units()"
RRU_BODY="$(psql -d "$BASE_DB" -X -q -t -A -c \
  "select prosrc from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='refresh_retrieval_units';")"
RRU_CONDENSED="$(printf '%s\n' "$RRU_BODY" \
  | sed -E 's/--.*$//' | tr '\n' ' ' | tr -s ' ')"
RRU_BROKEN="$(printf '%s' "$RRU_CONDENSED" \
  | sed 's/and ru\.workstream is not distinct from m\.workstream//')"

echo "         real body: $(printf '%s' "$RRU_BODY" | wc -c | tr -d ' ') chars"
echo "         condensed: $(printf '%s' "$RRU_CONDENSED" | wc -c | tr -d ' ') chars"
echo "         broken   : $(printf '%s' "$RRU_BROKEN" | wc -c | tr -d ' ') chars"

# Two cases that ONLY check J can see. perimeter_assert() looks at
# anon/authenticated, and the row checks look at data; neither notices a grant to
# a third role or a policy appearing where there was none. Every table in this
# schema has RLS ENABLED WITH NO POLICY -- deny-all for non-superusers -- so a
# single permissive policy silently converts the entire access model, without
# changing one row or one object name.
run_case "J    EXECUTE granted to a third role (invisible to perimeter_assert)" CAUGHT "J" \
  "grant execute on function promote_memory(uuid, uuid) to service_role;"

run_case "J    a permissive RLS policy appears where there were none" CAUGHT "J" \
  "create policy p_probe_open on memories for select to public using (true);"

run_case "J    sql/27 body, ONE ACL predicate deleted from the condensed form" CAUGHT "J" \
  "create or replace function refresh_retrieval_units()
   returns table (invalidated int, repaired_acl_drift int,
                  projected_memories int, projected_wiki int)
   language plpgsql security definer set search_path = public, extensions
   as \$rru\$ $RRU_BROKEN \$rru\$;"

echo
echo "-- EQUIVALENCE (the verifier must NOT cry wolf) --"
echo "   This is the sql/27 case: the deployed refresh_retrieval_units() and the"
echo "   repo's are semantically identical and textually different. A raw-text"
echo "   definition check reports drift on that correct pair forever."

# Rebuild is_owner_or_shared with identical semantics but condensed formatting
# and different comments -- exactly the shape of the real sql/27 divergence.
# The original body (sql/14) is, verbatim:
#     SELECT p_row_owner = p_principal_id OR p_row_visibility = 'shared';
# Below it is reflowed across lines, re-indented, and given entirely different
# comments. Identical tokens, identical order, identical case.
run_case "-    a body is reformatted and its comments rewritten" CLEAN "-" \
  "create or replace function is_owner_or_shared(p_row_owner uuid,
     p_row_visibility visibility_level, p_principal_id uuid)
   returns boolean language sql stable set search_path to 'public' as \$fn\$
       /* Commentary bearing no resemblance to the original, plus a block
          comment the original never had. */
       SELECT p_row_owner = p_principal_id
              OR      -- reflowed and re-indented
              p_row_visibility = 'shared';
   \$fn\$;"

run_case "-    sql/27 body, condensed exactly as the applied migration was" CLEAN "-" \
  "create or replace function refresh_retrieval_units()
   returns table (invalidated int, repaired_acl_drift int,
                  projected_memories int, projected_wiki int)
   language plpgsql security definer set search_path = public, extensions
   as \$rru\$ $RRU_CONDENSED \$rru\$;"

echo
echo "=========================================================================="
if [ "$FAILED" -ne 0 ]; then
  echo " DISCRIMINATION PROOF FAILED: the verifier does not reliably distinguish"
  echo " a corrupted restore from a clean one. Do not trust a green verify_restore."
  exit 1
fi
echo " DISCRIMINATION PROVEN: $CASE_N cases, every corruption caught by the"
echo " intended check, and a semantically-equivalent reformat correctly ignored."
echo "=========================================================================="
exit 0
