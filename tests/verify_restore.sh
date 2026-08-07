#!/usr/bin/env bash
# tests/verify_restore.sh
#
# Post-restore verification for upstream sovereign-memory-core #58.
#
# ── THE CLAIM THIS TRIES TO BREAK ─────────────────────────────────────────
# "The restored database is the same vault." Every check below is an attempt to
# falsify that. The checks are grouped by what an attacker or an accident would
# have to change to slip past them:
#
#   A  row counts                per table, against the package
#   B  content hashes            per table, over every column of every row
#   C  evidence locators         per locator, so a failure names the record
#   D  lifecycle state           record_status distribution
#   E  provenance                basis presence, citation where required
#   F  supersession chains       lineage, depth, and terminal status
#   G  attention / hot index     staging and index integrity, FK reachability
#   H  perimeter_assert()        zero findings
#   I  migration drift           the executable inventory check, in the restore
#   J  DEFINITION EQUIVALENCE    the one that name-equality could not do
#   K  conformance probes        positive/negative/conflict/stale/evidence
#
# ── J IS THE POINT ────────────────────────────────────────────────────────
# A prior review correctly observed that tests/replay_fresh_install.sh
# establishes equivalence by object NAMES filtered to non-extension objects, and
# NAME-EQUALITY DOES NOT PROVE DEFINITION EQUIVALENCE. A function with the right
# name and a rewritten body, an index with the right name over different
# columns, a trigger pointed at a different function, a table with the right
# name and a dropped constraint -- all pass a name check.
#
# Check J compares canonicalized definitions, signatures, ownership, security
# mode, volatility, search paths, grants, triggers, policies, constraints,
# indexes, RLS flags, enum labels and comments, object by object.
#
# What canonicalization can and cannot prove is documented at the top of
# tests/canonicalize_inventory.py and asserted by its --self-test, which runs
# here as check J0. Short version: bodies are compared after stripping comments
# and collapsing whitespace outside string literals, because
# refresh_retrieval_units() as deployed and as written in sql/27 are
# semantically identical and textually different -- a raw-text check reports
# drift on that correct pair forever. The cost is that a keyword-case difference
# reports as drift, and that comment-only drift is invisible.
#
# ── PROVE IT DISCRIMINATES ────────────────────────────────────────────────
# A verifier that has only ever printed OK proves nothing. This file does NOT
# prove itself -- that would be circular. Its counterpart does:
#
#     ./tests/prove_verifier_discriminates.sh <package> <db>
#
# which clones the restored database once per damage type, applies exactly one
# corruption to each clone, and asserts that this script fails AND that it fails
# on the INTENDED check. Two cases run the other way and matter as much: a
# reformatted function body must verify CLEAN. That mutates the DESTINATION
# only, which is disposable by construction; the source is never touched.
#
# A green run of THIS script, on its own, does not establish that these checks
# work. Run the counterpart, or run tests/sovereignty_proof.sh which runs both.
#
# ── USAGE ─────────────────────────────────────────────────────────────────
#   PGHOST=... PGPORT=... ./tests/verify_restore.sh <package-dir> [dbname]
#
# Exit 0 = every check passed. 1 = at least one failed.

set -uo pipefail
export LC_ALL="${LC_ALL:-C}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TESTS_DIR="$REPO_ROOT/tests"
PKG="${1:-}"
DB="${2:-svrestore}"
ROLE_MAP="${SOVEREIGN_ROLE_MAP:-}"

[ -n "$PKG" ] && [ -d "$PKG" ] || { echo "usage: $0 <package-dir> [dbname]" >&2; exit 2; }
PKG="$(cd "$PKG" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILED=0
CHECKS=0
declare -a RESULTS

ok()   { CHECKS=$((CHECKS+1)); RESULTS+=("PASS  $1"); echo "  PASS  $1"; }
bad()  { CHECKS=$((CHECKS+1)); FAILED=1; RESULTS+=("FAIL  $1"); echo "  FAIL  $1"; }
note() { echo "        $*"; }

Q() { psql -d "$DB" -X -q -t -A -v ON_ERROR_STOP=1 "$@"; }

echo "== verifying restored environment =="
echo "   package : $PKG"
echo "   database: $DB @ ${PGHOST:-<default>}:${PGPORT:-<default>}"
[ -n "$ROLE_MAP" ] && echo "   role map: $ROLE_MAP  (a DECLARATION that these roles are the same principal)"
echo

psql -d "$DB" -t -A -c "select 1" >/dev/null 2>&1 || { echo "cannot connect to $DB" >&2; exit 2; }

# ══════════════════════════════════════════════════════════════════════════
# J0 — the canonicalizer must be shown to discriminate before it is trusted
# ══════════════════════════════════════════════════════════════════════════
echo "-- J0 canonicalizer self-test --"
if python3 "$TESTS_DIR/canonicalize_inventory.py" --self-test > "$WORK/selftest.txt" 2>&1; then
  ok "J0 canonicalizer discriminates in both directions"
  note "$(tail -1 "$WORK/selftest.txt")"
else
  bad "J0 canonicalizer self-test failed"
  sed 's/^/        /' "$WORK/selftest.txt"
fi

# ══════════════════════════════════════════════════════════════════════════
# A + B — row counts and per-table content hashes
# ══════════════════════════════════════════════════════════════════════════
echo "-- A/B row counts and content hashes --"
# The package carries the EXACT SQL that produced its hashes, so the
# destination runs byte-identical SQL rather than a re-typed equivalent. A
# hashing script that drifted from the one that made the baseline would compare
# two different questions and call the answer drift.
psql -d "$DB" -X -q -f "$PKG/hashes/_table_hashes.sql" > "$WORK/dest_tables.tsv" 2>"$WORK/dest_tables.err"
if [ ! -s "$WORK/dest_tables.tsv" ]; then
  bad "A/B could not compute destination table hashes"
  sed 's/^/        /' "$WORK/dest_tables.err"
else
  COUNT_MISMATCH=0; HASH_MISMATCH=0; MISSING=0; EXTRA=0
  : > "$WORK/ab_detail.txt"
  while IFS=$'\t' read -r s t n h; do
    [ -z "$t" ] && continue
    line="$(awk -F'\t' -v s="$s" -v t="$t" '$1==s && $2==t {print $3"\t"$4}' "$WORK/dest_tables.tsv")"
    if [ -z "$line" ]; then
      echo "MISSING TABLE   $s.$t" >> "$WORK/ab_detail.txt"; MISSING=1; continue
    fi
    dn="${line%%$'\t'*}"; dh="${line##*$'\t'}"
    [ "$n" = "$dn" ] || { echo "ROW COUNT       $s.$t package=$n restored=$dn" >> "$WORK/ab_detail.txt"; COUNT_MISMATCH=1; }
    [ "$h" = "$dh" ] || { echo "CONTENT HASH    $s.$t package=${h:0:16}... restored=${dh:0:16}..." >> "$WORK/ab_detail.txt"; HASH_MISMATCH=1; }
  done < "$PKG/hashes/table_hashes.tsv"
  while IFS=$'\t' read -r s t n h; do
    [ -z "$t" ] && continue
    awk -F'\t' -v s="$s" -v t="$t" '$1==s && $2==t {found=1} END{exit !found}' "$PKG/hashes/table_hashes.tsv" \
      || { echo "EXTRA TABLE     $s.$t (present in restore, absent from package)" >> "$WORK/ab_detail.txt"; EXTRA=1; }
  done < "$WORK/dest_tables.tsv"

  PKG_ROWS=$(awk -F'\t' '{s+=$3} END{print s+0}' "$PKG/hashes/table_hashes.tsv")
  DST_ROWS=$(awk -F'\t' '{s+=$3} END{print s+0}' "$WORK/dest_tables.tsv")

  if [ "$COUNT_MISMATCH" -eq 0 ] && [ "$MISSING" -eq 0 ] && [ "$EXTRA" -eq 0 ]; then
    ok "A row counts match on all $(wc -l < "$PKG/hashes/table_hashes.tsv" | tr -d ' ') tables ($PKG_ROWS rows)"
  else
    bad "A row counts differ (package $PKG_ROWS rows, restored $DST_ROWS)"
    grep -E "^(ROW COUNT|MISSING TABLE|EXTRA TABLE)" "$WORK/ab_detail.txt" | head -20 | sed 's/^/        /'
  fi
  if [ "$HASH_MISMATCH" -eq 0 ]; then
    ok "B per-table content hashes match on all tables"
  else
    bad "B per-table content hashes differ"
    grep "^CONTENT HASH" "$WORK/ab_detail.txt" | head -20 | sed 's/^/        /'
  fi
fi

# ══════════════════════════════════════════════════════════════════════════
# C — evidence locators, one row at a time
# ══════════════════════════════════════════════════════════════════════════
echo "-- C evidence locators --"
psql -d "$DB" -X -q -t -A -F $'\t' > "$WORK/dest_locators.tsv" <<'SQLEOF' 2>/dev/null
set timezone='UTC'; set datestyle='ISO, YMD';
set search_path = public, extensions;
select ru.exact_locator, ru.source_relation, ru.source_id::text, ru.unit_kind,
       ru.ordinal::text, ru.record_status::text, ru.source_content_hash,
       encode(digest(ru.rendered_text,'sha256'),'hex'),
       coalesce(ru.provenance_basis::text,''), coalesce(ru.citation,''),
       case when ru.invalidated_at is null then 'live' else 'invalidated' end
from retrieval_units ru
order by ru.exact_locator, ru.id;
SQLEOF
if diff -u "$PKG/hashes/evidence_locators.tsv" "$WORK/dest_locators.tsv" > "$WORK/loc.diff" 2>&1; then
  N=$(wc -l < "$PKG/hashes/evidence_locators.tsv" | tr -d ' ')
  if [ "$N" -eq 0 ]; then
    bad "C zero evidence locators -- the check is vacuous, not passing"
  else
    ok "C all $N evidence locators identical (locator, hashes, status, provenance)"
  fi
else
  bad "C evidence locators differ"
  head -25 "$WORK/loc.diff" | sed 's/^/        /'
fi

# ══════════════════════════════════════════════════════════════════════════
# D — lifecycle state
# ══════════════════════════════════════════════════════════════════════════
echo "-- D lifecycle (record_status distribution) --"
DIST=$(Q -c "select string_agg(status||'='||n, ',' order by status) from (
  select status::text as status, count(*) n from memories group by 1) s;")
WDIST=$(Q -c "select string_agg(status||'='||n, ',' order by status) from (
  select status::text as status, count(*) n from wiki_pages group by 1) s;")
# The package's own distribution, recomputed from its table hashes is not
# possible (a hash is not a breakdown), so the source distribution is read from
# the source probe transcript's sibling: the lifecycle line the exporter wrote.
PKG_DIST="$(awk -F'\t' '$1=="memories"{print $2}' "$PKG/hashes/lifecycle.tsv" 2>/dev/null)"
PKG_WDIST="$(awk -F'\t' '$1=="wiki_pages"{print $2}' "$PKG/hashes/lifecycle.tsv" 2>/dev/null)"
if [ -z "$PKG_DIST" ]; then
  bad "D package carries no lifecycle baseline (hashes/lifecycle.tsv missing)"
else
  if [ "$DIST" = "$PKG_DIST" ] && [ "$WDIST" = "$PKG_WDIST" ]; then
    ok "D lifecycle distribution matches"
    note "memories:   $DIST"
    note "wiki_pages: $WDIST"
  else
    bad "D lifecycle distribution differs"
    note "memories   package=$PKG_DIST restored=$DIST"
    note "wiki_pages package=$PKG_WDIST restored=$WDIST"
  fi
fi
# Coverage honesty: assert which enum values were never produced, rather than
# asserting a count of zero as though absence were coverage.
UNEX=$(Q -c "select coalesce(string_agg(l, ','), '(none)') from (
  select unnest(enum_range(null::record_status))::text l
  except select distinct status::text from memories
  except select distinct status::text from wiki_pages) s;")
note "record_status values never exercised by this fixture: $UNEX"
note "^ not a pass. These states are unverified by this proof."

# ══════════════════════════════════════════════════════════════════════════
# E — provenance
# ══════════════════════════════════════════════════════════════════════════
echo "-- E provenance --"
NOBASIS=$(Q -c "select (select count(*) from memories where provenance_basis is null)
                     + (select count(*) from wiki_pages where provenance_basis is null);")
NOCITE=$(Q -c "select (select count(*) from memories where provenance_basis is distinct from 'human_direct' and (citation is null or length(trim(citation))=0))
                    + (select count(*) from wiki_pages where provenance_basis is distinct from 'human_direct' and (citation is null or length(trim(citation))=0));")
BASES=$(Q -c "select string_agg(b||'='||n, ',' order by b) from (
  select coalesce(provenance_basis::text,'(null)') b, count(*) n from memories group by 1) s;")
DISTINCT_BASES=$(Q -c "select count(distinct provenance_basis) from memories where provenance_basis is not null;")
if [ "$NOBASIS" = "0" ] && [ "$NOCITE" = "0" ] && [ "$DISTINCT_BASES" -ge 2 ]; then
  ok "E provenance intact: every row declares a basis, every non-human_direct row cites"
  note "memories basis distribution: $BASES"
else
  bad "E provenance broken (rows without basis: $NOBASIS, missing citations: $NOCITE, distinct bases: $DISTINCT_BASES)"
  note "memories basis distribution: $BASES"
  [ "$DISTINCT_BASES" -lt 2 ] && note "fewer than two distinct bases means this check is near-vacuous"
fi

# ══════════════════════════════════════════════════════════════════════════
# F — supersession chains
# ══════════════════════════════════════════════════════════════════════════
echo "-- F supersession chains --"
psql -d "$DB" -X -q -t -A -F $'\t' > "$WORK/dest_chains.tsv" <<'SQLEOF' 2>/dev/null
set timezone='UTC'; set datestyle='ISO, YMD';
set search_path = public, extensions;
with recursive chain as (
  select m.id as root, m.id as node, m.status::text as status, 0 as depth
  from memories m where m.supersedes is null
  union all
  select c.root, m.id, m.status::text, c.depth + 1
  from memories m join chain c on m.supersedes = c.node
)
select 'memories', root::text, node::text, status, depth::text from chain
union all
select 'wiki_pages', w.id::text, coalesce(w.supersedes::text,''), w.status::text, w.path
from wiki_pages w
order by 1,2,5,3;
SQLEOF
CHAIN_OK=1
diff -q "$PKG/hashes/supersession_chains.tsv" "$WORK/dest_chains.tsv" >/dev/null 2>&1 || CHAIN_OK=0
# Structural invariants, checked independently of the baseline so a corrupted
# baseline cannot make a corrupted restore look fine.
ORPHAN=$(Q -c "select count(*) from memories m where m.supersedes is not null
               and not exists (select 1 from memories p where p.id = m.supersedes);")
MULTI=$(Q -c "select count(*) from (select supersedes from memories
              where supersedes is not null group by supersedes having count(*)>1) s;")
LIVEPRED=$(Q -c "select count(*) from memories p join memories s on s.supersedes = p.id
                 where p.status = 'current';")
DEEPEST=$(Q -c "with recursive c as (
    select id, 0 d from memories where supersedes is null
    union all select m.id, c.d+1 from memories m join c on m.supersedes = c.id)
  select coalesce(max(d),0) from c;")
if [ "$CHAIN_OK" = "1" ] && [ "$ORPHAN" = "0" ] && [ "$MULTI" = "0" ] && [ "$LIVEPRED" = "0" ] && [ "$DEEPEST" -ge 1 ]; then
  ok "F supersession chains intact (deepest chain: $DEEPEST, no orphans, no forks, no live predecessors)"
else
  bad "F supersession chains broken"
  [ "$CHAIN_OK" = "0" ] && { note "chain listing differs from the package:"; diff -u "$PKG/hashes/supersession_chains.tsv" "$WORK/dest_chains.tsv" 2>/dev/null | head -15 | sed 's/^/        /'; }
  [ "$ORPHAN" != "0" ] && note "$ORPHAN row(s) supersede a memory that does not exist"
  [ "$MULTI"  != "0" ] && note "$MULTI predecessor(s) superseded by more than one successor (a fork, not a chain)"
  [ "$LIVEPRED" != "0" ] && note "$LIVEPRED superseded predecessor(s) still marked current"
  [ "$DEEPEST" -lt 1 ] && note "no chain deeper than 0: this check is vacuous on this dataset"
fi

# ══════════════════════════════════════════════════════════════════════════
# G — attention / hot index integrity
# ══════════════════════════════════════════════════════════════════════════
echo "-- G attention / hot index --"
HOT_N=$(Q -c "select count(*) from memory_hot_index;")
STAGE_N=$(Q -c "select count(*) from memory_hot_staging;")
HOT_ORPHAN=$(Q -c "select count(*) from memory_hot_index h where not exists (select 1 from memories m where m.id=h.memory_id);")
STAGE_ORPHAN=$(Q -c "select count(*) from memory_hot_staging s where not exists (select 1 from memories m where m.id=s.memory_id);")
HOT_BADCOUNT=$(Q -c "select count(*) from memory_hot_index where touch_count < 1;")
HOT_LONG=$(Q -c "select count(*) from memory_hot_index where char_length(summary) > 200;")
BOTH=$(Q -c "select count(*) from memory_hot_index h join memory_hot_staging s on s.topic_key=h.topic_key;")
RANKED=$(Q -c "select count(*) from memory_hot_ranked;")
TOUCHED=$(Q -c "select count(*) from memories where hot_touched;")
if [ "$HOT_N" -ge 1 ] && [ "$STAGE_N" -ge 1 ] && [ "$HOT_ORPHAN" = "0" ] && [ "$STAGE_ORPHAN" = "0" ] \
   && [ "$HOT_BADCOUNT" = "0" ] && [ "$HOT_LONG" = "0" ] && [ "$BOTH" = "0" ] && [ "$TOUCHED" -ge 1 ]; then
  ok "G hot index intact ($HOT_N indexed, $STAGE_N staged, $RANKED ranked, $TOUCHED memories flagged)"
  note "no orphans, no topic in both index and staging, no summary over 200 chars"
else
  bad "G hot index integrity broken"
  note "indexed=$HOT_N staged=$STAGE_N orphans=$HOT_ORPHAN/$STAGE_ORPHAN badcount=$HOT_BADCOUNT oversize=$HOT_LONG in_both=$BOTH touched=$TOUCHED"
  { [ "$HOT_N" -lt 1 ] || [ "$STAGE_N" -lt 1 ]; } && note "an empty index or staging table makes this check vacuous"
fi

# ══════════════════════════════════════════════════════════════════════════
# H — perimeter
# ══════════════════════════════════════════════════════════════════════════
echo "-- H perimeter_assert() --"
PERIM=$(Q -c "select count(*) from perimeter_assert();")
NORLS=$(Q -c "select coalesce(string_agg(c.relname,', '),'') from pg_class c
              join pg_namespace n on n.oid=c.relnamespace
              where n.nspname='public' and c.relkind='r' and not c.relrowsecurity
                and not exists (select 1 from pg_depend d where d.objid=c.oid and d.deptype='e');")
if [ "$PERIM" = "0" ] && [ -z "$NORLS" ]; then
  ok "H perimeter clean: 0 findings, every repo-owned public table has RLS enabled"
  note "LIMIT: vanilla PostgreSQL does not apply Supabase's default grants to"
  note "anon/authenticated, so a local zero is weaker evidence than a hosted zero."
else
  if [ -n "$NORLS" ] && [ "$PERIM" = "0" ]; then
    bad "H row level security is DISABLED on repo-owned public table(s)"
  else
    bad "H perimeter findings after restore: $PERIM finding(s)"
  fi
  [ -n "$NORLS" ] && note "tables without RLS: $NORLS"
  psql -d "$DB" -X -q -c "select * from perimeter_assert() limit 15;" 2>/dev/null | sed 's/^/        /'
fi

# ══════════════════════════════════════════════════════════════════════════
# I — migration drift, in the restored environment
# ══════════════════════════════════════════════════════════════════════════
echo "-- I migration drift inventory --"
# The restored database has no supabase_migrations schema (it was built from
# sql/*.sql, not by Supabase's migration runner), so the applied inventory is
# synthesized from the MIGRATION: headers the package's own sql copies declare.
# That makes this a self-consistency check of the package: every migration a
# carried file claims to carry is accounted for by exactly one carried file.
grep -ohE '^-- MIGRATION: [A-Za-z0-9_.-]+' "$PKG"/schema/sql/*.sql 2>/dev/null \
  | sed 's/^-- MIGRATION: //' | sort \
  | awk '{printf "20260807999999\t%s\n", $0}' > "$WORK/applied.tsv"
if bash "$TESTS_DIR/migration_drift.sh" "$WORK/applied.tsv" > "$WORK/drift.txt" 2>&1; then
  ok "I migration inventory reconciles in the restored environment"
  note "$(grep -c . "$WORK/applied.tsv") declared migration(s); see the package's sql copies"
  note "LIMIT: inventory only. A file present but stale reads as clean here --"
  note "that gap is exactly what check J closes."
else
  bad "I migration drift detected in the restored environment"
  sed 's/^/        /' "$WORK/drift.txt" | head -25
fi

# ══════════════════════════════════════════════════════════════════════════
# J — DEFINITION EQUIVALENCE (not name equivalence)
# ══════════════════════════════════════════════════════════════════════════
echo "-- J definition-level schema equivalence --"
psql -d "$DB" -X -q -f "$TESTS_DIR/schema_inventory.sql" > "$WORK/dest_inv.jsonl" 2>"$WORK/dest_inv.err"
if [ ! -s "$WORK/dest_inv.jsonl" ]; then
  bad "J could not read the destination schema inventory"
  sed 's/^/        /' "$WORK/dest_inv.err" | head -5
else
  MAPARG=()
  [ -n "$ROLE_MAP" ] && MAPARG=(--role-map "$ROLE_MAP")
  python3 "$TESTS_DIR/canonicalize_inventory.py" "$WORK/dest_inv.jsonl" ${MAPARG[@]+"${MAPARG[@]}"} > "$WORK/dest_hashes.tsv" 2>"$WORK/dest_hash.err"
  if [ ! -s "$WORK/dest_hashes.tsv" ]; then
    bad "J canonicalization of the destination inventory failed"
    sed 's/^/        /' "$WORK/dest_hash.err" | head -10
  else
    SRC_FP=$(awk -F'\t' '$1=="FINGERPRINT"{print $2}' "$PKG/schema/inventory.hashes.tsv")
    DST_FP=$(awk -F'\t' '$1=="FINGERPRINT"{print $2}' "$WORK/dest_hashes.tsv")
    SRC_N=$(awk -F'\t' '$1=="FINGERPRINT"{print $3}' "$PKG/schema/inventory.hashes.tsv")
    DST_N=$(awk -F'\t' '$1=="FINGERPRINT"{print $3}' "$WORK/dest_hashes.tsv")

    grep -v '^FINGERPRINT' "$PKG/schema/inventory.hashes.tsv" | sort > "$WORK/src_objs"
    grep -v '^FINGERPRINT' "$WORK/dest_hashes.tsv"            | sort > "$WORK/dst_objs"
    awk -F'\t' '{print $2"\t"$3}' "$WORK/src_objs" | sort > "$WORK/src_names"
    awk -F'\t' '{print $2"\t"$3}' "$WORK/dst_objs" | sort > "$WORK/dst_names"

    ONLY_SRC=$(comm -23 "$WORK/src_names" "$WORK/dst_names" | wc -l | tr -d ' ')
    ONLY_DST=$(comm -13 "$WORK/src_names" "$WORK/dst_names" | wc -l | tr -d ' ')

    # Objects present in BOTH by name but whose canonical hash differs. This is
    # the class name-equality cannot see, so it is reported on its own line.
    join -t $'\t' -1 1 -2 1 \
      <(awk -F'\t' '{print $2"\x1f"$3"\t"$1}' "$WORK/src_objs" | sort) \
      <(awk -F'\t' '{print $2"\x1f"$3"\t"$1}' "$WORK/dst_objs" | sort) \
      | awk -F'\t' '$2 != $3 {print $1}' | tr '\x1f' ' ' > "$WORK/redefined.txt"
    REDEF=$(wc -l < "$WORK/redefined.txt" | tr -d ' ')

    if [ "$SRC_FP" = "$DST_FP" ]; then
      ok "J schema fingerprints identical ($SRC_N objects, ${SRC_FP:0:16}...)"
      note "compared: canonicalized definitions, signatures, ownership, security"
      note "mode, volatility, search_path, ACLs, triggers, policies, constraints,"
      note "indexes, RLS flags, enum labels, comments -- NOT just names."
      note "LIMIT: canonicalization strips comments and collapses whitespace"
      note "outside literals. It is not semantic equivalence; see"
      note "tests/canonicalize_inventory.py for what that does and does not prove."
    else
      bad "J schema definitions differ (package $SRC_N vs restored $DST_N objects)"
      note "package  fingerprint: $SRC_FP"
      note "restored fingerprint: $DST_FP"
      [ "$ONLY_SRC" != "0" ] && { note "$ONLY_SRC object(s) missing from the restore:"; comm -23 "$WORK/src_names" "$WORK/dst_names" | head -10 | sed 's/^/          /'; }
      [ "$ONLY_DST" != "0" ] && { note "$ONLY_DST object(s) added by the restore:";     comm -13 "$WORK/src_names" "$WORK/dst_names" | head -10 | sed 's/^/          /'; }
      if [ "$REDEF" != "0" ]; then
        note "$REDEF object(s) present under the SAME NAME with a DIFFERENT definition"
        note "(this is the class a name-equality check reports as clean):"
        head -15 "$WORK/redefined.txt" | sed 's/^/          /'
      fi
    fi
  fi
fi

# Extension versions, compared separately because extension internals are
# excluded from the inventory (they belong to the host, not the repo).
if [ -f "$PKG/meta/extensions.tsv" ]; then
  psql -d "$DB" -X -q -t -A -F $'\t' -c \
    "select extname, extversion, (select nspname from pg_namespace where oid=extnamespace) from pg_extension order by extname;" \
    > "$WORK/dest_ext.tsv" 2>/dev/null
  if diff -q "$PKG/meta/extensions.tsv" "$WORK/dest_ext.tsv" >/dev/null 2>&1; then
    ok "J2 extension inventory identical"
  else
    bad "J2 extension inventory differs"
    diff -u "$PKG/meta/extensions.tsv" "$WORK/dest_ext.tsv" 2>/dev/null | tail -10 | sed 's/^/        /'
  fi
fi

# ══════════════════════════════════════════════════════════════════════════
# K — conformance probes
# ══════════════════════════════════════════════════════════════════════════
echo "-- K conformance probes --"
if bash "$TESTS_DIR/sovereign_probes.sh" "$DB" > "$WORK/dest_probes.txt" 2>&1; then
  NP=$(grep -c '^PROBE' "$WORK/dest_probes.txt")
  ok "K all $NP conformance probes pass after restore"
else
  bad "K conformance probes failed after restore"
  grep -E '^PROBE .* FAIL' "$WORK/dest_probes.txt" | head -10 | sed 's/^/        /'
fi
# The probes must produce the SAME verdicts as at the source. A probe that
# passes in both places for different reasons is not evidence.
if [ -f "$PKG/probes/source_probes.txt" ]; then
  grep '^PROBE' "$PKG/probes/source_probes.txt" | awk '{print $2, $3, $4}' | sort > "$WORK/src_p"
  grep '^PROBE' "$WORK/dest_probes.txt"          | awk '{print $2, $3, $4}' | sort > "$WORK/dst_p"
  if diff -q "$WORK/src_p" "$WORK/dst_p" >/dev/null 2>&1; then
    ok "K2 probe verdicts identical to the source transcript"
  else
    bad "K2 probe verdicts differ between source and restore"
    diff -u "$WORK/src_p" "$WORK/dst_p" | head -15 | sed 's/^/        /'
  fi
fi

# ══════════════════════════════════════════════════════════════════════════
echo
echo "== summary =="
printf '%s\n' "${RESULTS[@]}" | sed 's/^/  /'
echo
if [ "$FAILED" -ne 0 ]; then
  echo "VERIFICATION FAILED ($CHECKS checks run)"
  exit 1
fi
echo "VERIFICATION PASSED ($CHECKS checks run)"
echo
echo "WHAT THIS DOES NOT PROVE -- see KNOWN LIMITATIONS in $PKG/MANIFEST.md:"
echo "  * this is a fixture, not the live deployment's data"
echo "  * canonicalized definition equality is not semantic equivalence"
echo "  * a local restore cannot reproduce Supabase default-privilege behavior"
echo "  * PostgREST, edge functions, cron and auth are outside the package"
echo "  * a sha256 is not a signature"
exit 0
