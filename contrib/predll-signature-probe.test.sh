#!/usr/bin/env bash
#
# predll-signature-probe.test.sh — discrimination proof for the pre-DDL probe.
#
# Every case is paired: an instruction corpus the probe MUST block on, and a
# structurally similar one it MUST NOT block on. If only the first half
# existed, `exit 1` would pass this suite; if only the second, `exit 0` would.
#
# The fixtures reproduce the two confirmed instances from
# docs/08-contract-version-and-drift.md, with fabricated instruction text:
#   1. supersede_memory() lost its 5-argument form   (sql/20 line 147)
#   2. refresh_retrieval_units() went 3 -> 4 columns (sql/27 line 113)
#
# Self-contained and safe to run concurrently: everything happens inside one
# mktemp -d, no fixed ports, no fixed paths, no network, no writes outside it.
#
#   bash contrib/predll-signature-probe.test.sh
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="$SCRIPT_DIR/predll-signature-probe.sh"
[ -f "$PROBE" ] || { echo "cannot find $PROBE" >&2; exit 1; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/predlltest.XXXXXX")" || exit 1
trap 'rm -rf "$ROOT"' EXIT INT TERM

PASSED=0; FAILED=0; OUT=""; RC=0

section() { printf '\n--- %s\n' "$1"; }
ok()  { PASSED=$((PASSED + 1)); printf '  ok   %s\n' "$1"; }
bad() {
  FAILED=$((FAILED + 1))
  printf '  FAIL %s\n' "$1"
  printf '       ---- probe output ----\n'
  printf '%s\n' "$OUT" | sed 's/^/       /'
  printf '       ---- exit %s ----\n' "$RC"
}
probe() { OUT="$(bash "$PROBE" "$@" 2>&1)"; RC=$?; }
expect_rc()   { if [ "$RC" -eq "$1" ]; then ok "$2 (exit $RC)"; else bad "$2 — expected exit $1, got $RC"; fi; }
expect_has()  { case "$OUT" in *"$1"*) ok "$2" ;; *) bad "$2 — expected output to contain: $1" ;; esac; }
expect_lacks(){ case "$OUT" in *"$1"*) bad "$2 — output should NOT contain: $1" ;; *) ok "$2" ;; esac; }

# ===========================================================================
# fixtures — DDL
# ===========================================================================

# Instance 1: the 5-arg form is dropped, a 6-arg form replaces it.
cat >"$ROOT/ddl_supersede.sql" <<'SQL'
-- MIGRATION: fabricated fixture modelled on sql/20
drop function if exists supersede_memory(uuid, text, provenance_basis, text, text);

create function supersede_memory(
  p_old uuid, p_reason text, p_basis provenance_basis,
  p_note text, p_actor uuid, p_actor_note text
) returns uuid
language plpgsql security definer as $$
begin
  return p_old;
end; $$;
SQL

# Instance 2: return table widened 3 -> 4 columns, drop was unavoidable.
cat >"$ROOT/ddl_refresh.sql" <<'SQL'
-- MIGRATION: fabricated fixture modelled on sql/27
drop function if exists refresh_retrieval_units();

create function refresh_retrieval_units()
returns table (invalidated int, repaired_acl_drift int, projected_memories int, projected_wiki int)
language plpgsql as $$
begin
  return;
end; $$;
SQL

# A migration that touches no function at all — the parser must not call this clean.
cat >"$ROOT/ddl_table_only.sql" <<'SQL'
-- MIGRATION: fabricated fixture, tables only
create table widget (id uuid primary key, label text not null);
create index widget_label_idx on widget (label);
SQL

# ===========================================================================
# fixtures — instruction corpora
# ===========================================================================

# STALE: teaches the dead 5-argument call. Must block.
mkdir -p "$ROOT/corpus_stale"
cat >"$ROOT/corpus_stale/runbook.md" <<'EOD'
# Operating instructions

To retire a record, call:

    select supersede_memory(v_old_id, 'superseded', 'operator', 'see ticket');

Wait, that is four. The full form is:

    select supersede_memory(v_old_id, 'superseded', 'operator', 'note', 'extra');

Then confirm the row is gone.
EOD

# CURRENT: same runbook, updated to the 6-argument form. Must NOT block.
mkdir -p "$ROOT/corpus_current"
cat >"$ROOT/corpus_current/runbook.md" <<'EOD'
# Operating instructions

To retire a record, call:

    select supersede_memory(v_old_id, 'superseded', 'operator', 'note', v_actor_id, 'actor note');

The actor is required. The old unaudited five-argument form was dropped and
errors if called, so do not reintroduce it.
EOD

# UNRELATED: mentions nothing this DDL touches. Must NOT block.
mkdir -p "$ROOT/corpus_unrelated"
cat >"$ROOT/corpus_unrelated/notes.md" <<'EOD'
# Unrelated operating notes

Rotate the export key quarterly. The retrieval projection is refreshed by a
scheduled job. Escalate to the owner before applying anything in pending/.

Nothing here calls into the memory lifecycle at all.
EOD

# ADVERSARIAL: names the function but never calls it at the dead arity.
# This is the false-positive trap — family A alone would block on it.
mkdir -p "$ROOT/corpus_mentions"
cat >"$ROOT/corpus_mentions/design.md" <<'EOD'
# Design discussion

We considered whether supersede_memory should record an actor. It should, and
the change is now applied. See the migration notes for the rationale.

supersede_memory is the only lifecycle function that was ever unaudited.
EOD

# ===========================================================================
section "extraction"
# ===========================================================================
probe --ddl "$ROOT/ddl_supersede.sql" --corpus "$ROOT/corpus_unrelated" --list
expect_rc 0 "--list exits clean"
expect_has "supersede_memory" "extracted the dropped function name"
expect_has "explicitly dropped" "recorded why it is affected"

probe --ddl "$ROOT/ddl_refresh.sql" --corpus "$ROOT/corpus_unrelated" --list
expect_rc 0 "--list exits clean for instance 2"
expect_has "refresh_retrieval_units" "extracted the second dropped function"

# ===========================================================================
section "POSITIVE CONTROL: a stale instruction blocks the apply"
# ===========================================================================
probe --ddl "$ROOT/ddl_supersede.sql" --corpus "$ROOT/corpus_stale"
expect_rc 1 "stale runbook blocks"
expect_has "PROBE FAILED" "verdict says failed"
expect_has "runbook.md" "names the offending file"
expect_has "5 argument(s)" "says which arity it matched"
expect_has "that form is gone" "explains why the hit matters"
expect_lacks "PROBE CLEAN" "a blocking run never prints the clean verdict"

# ===========================================================================
section "NEGATIVE CONTROL: an updated or unrelated corpus does not block"
# ===========================================================================
probe --ddl "$ROOT/ddl_supersede.sql" --corpus "$ROOT/corpus_current"
expect_rc 0 "corpus updated to the 6-arg form passes"
expect_has "PROBE CLEAN" "verdict says clean"

probe --ddl "$ROOT/ddl_supersede.sql" --corpus "$ROOT/corpus_unrelated"
expect_rc 0 "unrelated corpus passes"
expect_has "no instruction mentions this name" "says the name was never mentioned"

# The discriminating case: family A alone would block here. Family B must not.
probe --ddl "$ROOT/ddl_supersede.sql" --corpus "$ROOT/corpus_mentions"
expect_rc 0 "a corpus that merely NAMES the function does not block"
expect_has "no call site with the removed arity" "distinguishes a mention from a call site"
expect_has "advisory" "still surfaces the mentions for human review"

# ===========================================================================
section "zero-argument functions (regression: docs/08 instance 2's shape)"
# ===========================================================================
# refresh_retrieval_units() takes no arguments. An earlier arity_of() returned
# the empty string rather than 0 for `()`, so the family-B comparison silently
# never matched and a dropped zero-arg function could not be detected at all.
# --list looked fine — the arity column was simply blank. Only a corpus with a
# real zero-arg call site exposes it, which is why this section exists.
mkdir -p "$ROOT/corpus_zeroarg"
cat >"$ROOT/corpus_zeroarg/refresh.md" <<'EOD'
# Maintenance instructions

Refresh the projection before reading:

    select invalidated, projected_memories, projected_wiki
    from refresh_retrieval_units();

Three counts come back.
EOD

probe --ddl "$ROOT/ddl_refresh.sql" --corpus "$ROOT/corpus_zeroarg" --list
expect_has "	0	" "a zero-argument signature records arity 0, not blank"

probe --ddl "$ROOT/ddl_refresh.sql" --corpus "$ROOT/corpus_zeroarg"
expect_rc 1 "a zero-argument call site in an instruction blocks"
expect_has "0 argument(s)" "says the arity it matched was zero"
expect_has "refresh.md" "names the offending file"

# and the negative half: a corpus that never calls it must not block
probe --ddl "$ROOT/ddl_refresh.sql" --corpus "$ROOT/corpus_unrelated"
expect_rc 0 "a corpus with no call site still passes for a zero-arg function"

# ===========================================================================
section "affected signatures are not searched twice"
# ===========================================================================
# supersede_memory is both explicitly dropped AND recreated at a new arity, so
# it is affected for two reasons. It must still be one row and one hit.
probe --ddl "$ROOT/ddl_supersede.sql" --corpus "$ROOT/corpus_unrelated" --list
expect_has "arity changed 5 -> 6; explicitly dropped" "both reasons merge onto one row"
probe --ddl "$ROOT/ddl_supersede.sql" --corpus "$ROOT/corpus_stale"
if [ "$(printf '%s\n' "$OUT" | grep -c 'that form is gone')" = "1" ]; then
  ok "the same stale call site is reported once, not once per reason"
else
  bad "duplicate hits for one signature"
fi

# ===========================================================================
section "the probe cannot trivially succeed"
# ===========================================================================
# Each unattested case asserts its OWN reason, not just the word UNATTESTED.
# Exit 3 alone is too weak: three different failures share it, so a test that
# checks only the code passes when the wrong guard fires. (Caught by mutation:
# deleting the missing-path guard still exited 3 via the no-files guard, and an
# "UNATTESTED"-only assertion could not tell the difference.)
probe --ddl "$ROOT/ddl_supersede.sql" --corpus "$ROOT/does-not-exist"
expect_rc 3 "a missing corpus is UNATTESTED, not clean"
expect_has "corpus path does not exist" "blocked for the missing-path reason specifically"
expect_lacks "PROBE CLEAN" "a missing corpus never reads as clean"

mkdir -p "$ROOT/corpus_empty"
: >"$ROOT/corpus_empty/blank.md"
probe --ddl "$ROOT/ddl_supersede.sql" --corpus "$ROOT/corpus_empty"
expect_rc 3 "a corpus of empty files is UNATTESTED, not clean"
expect_has "0 bytes" "blocked for the zero-bytes reason specifically"

mkdir -p "$ROOT/corpus_nofiles"
probe --ddl "$ROOT/ddl_supersede.sql" --corpus "$ROOT/corpus_nofiles"
expect_rc 3 "an empty corpus directory is UNATTESTED"
expect_has "no files" "blocked for the no-files reason specifically"

probe --ddl "$ROOT/ddl_table_only.sql" --corpus "$ROOT/corpus_stale"
expect_rc 3 "a DDL yielding no signatures is UNATTESTED, not clean"
expect_has "no function definition could be extracted" "explains what it could not do"

probe --corpus "$ROOT/corpus_stale"
expect_rc 2 "missing --ddl is a usage error"

probe --ddl "$ROOT/nope.sql" --corpus "$ROOT/corpus_stale"
expect_rc 2 "a missing ddl file is a usage error"

# ===========================================================================
section "rule 4 interim: a jsonb envelope change must be declared"
# ===========================================================================
# Instance 4 (docs/08): a create-or-replace of a jsonb-returning function whose
# signature is byte-identical. No drop, no arity change, no result change --
# nothing the first three rules can see.
cat >"$ROOT/ddl_envelope_undeclared.sql" <<'SQL'
-- MIGRATION: fabricated fixture modelled on pending/B
drop function if exists helper_noop();
create function helper_noop() returns int language sql as $$ select 1 $$;

CREATE OR REPLACE FUNCTION retrieve_context(
  p_principal_id uuid, p_query text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $fn$
begin
  return jsonb_build_object('retrieval_status', 'evaluated_partial_coverage');
end; $fn$;
SQL

cat >"$ROOT/ddl_envelope_declared.sql" <<'SQL'
-- MIGRATION: fabricated fixture modelled on pending/B
-- PUBLIC SIGNATURE CHANGE: retrieval_status gains a third value,
-- evaluated_partial_coverage. Callers switching exhaustively will break.
drop function if exists helper_noop();
create function helper_noop() returns int language sql as $$ select 1 $$;

CREATE OR REPLACE FUNCTION retrieve_context(
  p_principal_id uuid, p_query text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $fn$
begin
  return jsonb_build_object('retrieval_status', 'evaluated_partial_coverage');
end; $fn$;
SQL

# Without the flag, the envelope change is invisible — that is instance 4, and
# asserting it here keeps the hole honest instead of implied.
probe --ddl "$ROOT/ddl_envelope_undeclared.sql" --corpus "$ROOT/corpus_unrelated"
expect_rc 0 "WITHOUT --require-envelope-note the envelope change is INVISIBLE (instance 4)"
expect_has "PROBE CLEAN" "the probe reports clean on a real contract break"

probe --ddl "$ROOT/ddl_envelope_undeclared.sql" --corpus "$ROOT/corpus_unrelated" --require-envelope-note
expect_rc 1 "--require-envelope-note blocks an undeclared jsonb envelope change"
expect_has "declares no envelope change" "explains what is missing"

probe --ddl "$ROOT/ddl_envelope_declared.sql" --corpus "$ROOT/corpus_unrelated" --require-envelope-note
expect_rc 0 "a declared envelope change passes"
expect_has "PROBE CLEAN" "declaration satisfies the interim control"

# ===========================================================================
printf '\n=========================================\n'
printf 'passed: %s   failed: %s\n' "$PASSED" "$FAILED"
if [ "$FAILED" -ne 0 ]; then
  printf 'TEST SUITE FAILED\n'
  exit 1
fi
printf 'TEST SUITE PASSED\n'
printf 'Proven: the probe blocks on an instruction teaching a removed signature,\n'
printf 'passes on an updated one, does not block on a bare mention, and refuses\n'
printf 'to call an unreadable/empty corpus or an unparsed DDL "clean".\n'
printf 'Also proven, deliberately: WITHOUT --require-envelope-note it reports\n'
printf 'clean on instance 4. That assertion exists so the hole cannot be\n'
printf 'quietly closed by wishful thinking.\n'
exit 0
