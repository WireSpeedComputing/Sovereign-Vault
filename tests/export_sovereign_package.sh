#!/usr/bin/env bash
# tests/export_sovereign_package.sh
#
# Produce a SOVEREIGN EXPORT PACKAGE from a running Sovereign Vault database.
# Part of upstream sovereign-memory-core #58.
#
# ── WHAT #58 IS ACTUALLY ASKING ────────────────────────────────────────────
# "Owning a Supabase project is not sufficient evidence of sovereignty." The
# claim under test is that the vault can be reconstituted and VERIFIED somewhere
# the original host has no reach. That needs three separable things, and this
# script is the first:
#
#   1. export   this file           -- read-only, leaves the source untouched
#   2. restore  restore_sovereign_package.sh  -- into a second clean cluster
#   3. verify   verify_restore.sh   -- definition-level, not name-level
#
# ── READ-ONLY, AND THAT IS LOAD-BEARING ────────────────────────────────────
# #58's acceptance requires "failure modes leave the source untouched". This
# script issues no DDL and no DML. It runs pg_dump and SELECTs. It also
# deliberately does not hold or accept credentials for a hosted project: point
# it at a database with the standard PG* environment variables, the same
# decision tests/migration_drift.sh makes and for the same reason.
#
# ── SELF-SUFFICIENCY ───────────────────────────────────────────────────────
# The package carries a COPY of the sql/*.sql files it was exported against,
# not just their hashes. A package that requires you to already have the right
# repo checkout is not an exit path -- it is a bookmark. The repo copy is still
# hashed against the package so repo drift is reported, but the restore does
# not depend on it.
#
# ── USAGE ──────────────────────────────────────────────────────────────────
#   PGHOST=... PGPORT=... PGDATABASE=... ./tests/export_sovereign_package.sh OUTDIR
#
# Exit 0 = package written. Non-zero = nothing usable was produced.

set -uo pipefail
export LC_ALL="${LC_ALL:-C}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TESTS_DIR="$REPO_ROOT/tests"
OUT="${1:-}"
DB="${PGDATABASE:-svsource}"

if [ -z "$OUT" ]; then
  echo "usage: PGHOST=... PGPORT=... PGDATABASE=... $0 <output-dir>" >&2
  exit 2
fi

fail() { echo "EXPORT FAILED: $*" >&2; exit 1; }

command -v pg_dump >/dev/null || fail "pg_dump not on PATH"
command -v python3 >/dev/null || fail "python3 not on PATH (needed to canonicalize definitions)"

psql -d "$DB" -t -A -c "select 1" >/dev/null 2>&1 || fail "cannot connect to database '$DB'"

rm -rf "$OUT"
mkdir -p "$OUT"/{meta,schema,schema/sql,data,hashes,probes} || fail "cannot create $OUT"

# Every hashing session must agree on how values render as text, or the "same
# data" produces two different hashes for reasons that have nothing to do with
# the data. Pinned here and identically in verify_restore.sh.
PSQL_PINNED=(psql -d "$DB" -X -q -v ON_ERROR_STOP=1)
RENDER_PIN="set timezone='UTC'; set datestyle='ISO, YMD'; set extra_float_digits=3; set bytea_output='hex'; set intervalstyle='postgres';"

echo "== sovereign export =="
echo "   source db : $DB @ ${PGHOST:-<default>}:${PGPORT:-<default>}"
echo "   output    : $OUT"

# ── meta: versions, refs, settings ────────────────────────────────────────
{
  echo "exported_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "exporter_script=tests/export_sovereign_package.sh"
  echo "server_version=$(psql -d "$DB" -t -A -c 'show server_version')"
  echo "server_version_num=$(psql -d "$DB" -t -A -c 'show server_version_num')"
  echo "pg_dump_version=$(pg_dump --version | head -1)"
  echo "psql_version=$(psql --version | head -1)"
  echo "python_version=$(python3 --version 2>&1)"
  echo "uname=$(uname -a)"
  echo "lc_all=${LC_ALL}"
  echo "server_encoding=$(psql -d "$DB" -t -A -c 'show server_encoding')"
  echo "lc_collate=$(psql -d "$DB" -t -A -c "select datcollate from pg_database where datname=current_database()")"
  echo "lc_ctype=$(psql -d "$DB" -t -A -c "select datctype from pg_database where datname=current_database()")"
  echo "default_collation_version=$(psql -d "$DB" -t -A -c "select datcollversion from pg_database where datname=current_database()")"
} > "$OUT/meta/versions.txt"

psql -d "$DB" -t -A -F $'\t' -c \
  "select extname, extversion, (select nspname from pg_namespace where oid=extnamespace) from pg_extension order by extname;" \
  > "$OUT/meta/extensions.tsv"

psql -d "$DB" -t -A -F $'\t' -c \
  "select name, setting from pg_settings where name in
   ('server_version','block_size','data_checksums','max_identifier_length',
    'standard_conforming_strings','DateStyle','TimeZone','default_text_search_config')
   order by name;" > "$OUT/meta/settings.tsv"

{
  echo "repo_root=$REPO_ROOT"
  if git -C "$REPO_ROOT" rev-parse HEAD >/dev/null 2>&1; then
    echo "git_commit=$(git -C "$REPO_ROOT" rev-parse HEAD)"
    echo "git_describe=$(git -C "$REPO_ROOT" describe --always --dirty 2>/dev/null)"
    echo "git_branch=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    # A dirty tree is not a pinned commit. #58 asks for "a pinned exact commit";
    # recording the commit while the working tree differs from it would be a
    # claim the package cannot support, so the uncommitted files are listed.
    DIRTY="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)"
    if [ -n "$DIRTY" ]; then
      echo "git_tree_clean=false"
      echo "git_uncommitted:"
      printf '%s\n' "$DIRTY" | sed 's/^/  /'
    else
      echo "git_tree_clean=true"
    fi
  else
    echo "git_commit=(not a git repository)"
    echo "git_tree_clean=unknown"
  fi
} > "$OUT/meta/source_ref.txt"

# ── schema: the repo files themselves, copied and hashed ──────────────────
: > "$OUT/meta/repo_sql_manifest.tsv"
SQLCOUNT=0
for f in $(ls "$REPO_ROOT"/sql/*.sql | sort); do
  cp "$f" "$OUT/schema/sql/$(basename "$f")" || fail "cannot copy $f"
  printf '%s\t%s\n' "$(basename "$f")" "$(shasum -a 256 "$f" | awk '{print $1}')" \
    >> "$OUT/meta/repo_sql_manifest.tsv"
  SQLCOUNT=$((SQLCOUNT+1))
done
echo "   sql files : $SQLCOUNT copied and hashed"

# pg_dump schema is carried as a CROSS-CHECK, not as the restore path. The
# restore applies sql/*.sql, because #58 requires the supported migration path
# be the thing that is proven. If the two disagree, that disagreement IS the
# finding -- see verify_restore.sh's definition inventory comparison.
pg_dump -d "$DB" --schema-only --no-owner --no-privileges \
  > "$OUT/schema/pg_dump_schema_reference.sql" 2>"$OUT/schema/pg_dump_schema.err" \
  || fail "pg_dump --schema-only failed; see $OUT/schema/pg_dump_schema.err"

# ── definition-level inventory (the anti-name-equality check) ─────────────
psql -d "$DB" -X -q -f "$TESTS_DIR/schema_inventory.sql" > "$OUT/schema/inventory.jsonl" \
  2>"$OUT/schema/inventory.err" || fail "schema_inventory.sql failed; see $OUT/schema/inventory.err"
[ -s "$OUT/schema/inventory.jsonl" ] || fail "schema inventory came back empty"

python3 "$TESTS_DIR/canonicalize_inventory.py" "$OUT/schema/inventory.jsonl" \
  > "$OUT/schema/inventory.hashes.tsv" || fail "canonicalization failed (duplicate keys?)"
INV_FP="$(awk -F'\t' '$1=="FINGERPRINT"{print $2}' "$OUT/schema/inventory.hashes.tsv")"
INV_N="$(awk -F'\t' '$1=="FINGERPRINT"{print $3}' "$OUT/schema/inventory.hashes.tsv")"
echo "   inventory : $INV_N, fingerprint ${INV_FP:0:16}..."

# ── data payload ──────────────────────────────────────────────────────────
# Plain SQL, not custom format. A custom-format dump requires pg_restore of a
# compatible version to even READ; plain SQL can be inspected with an editor
# and loaded by any psql. For an artifact whose whole purpose is "you can get
# out", inspectability beats compactness.
#
# --disable-triggers is REQUIRED and is a real caveat, stated here and repeated
# in RESTORE.md: this schema makes status='current' unreachable by direct
# INSERT (sql/26), so a COPY of promoted rows would be rejected by the very
# guard that makes promotion meaningful. The restore path is therefore a
# TRUSTED path that runs with the guards off. Restoring a package is equivalent
# to superuser access; it is not a way for an untrusted caller to smuggle rows
# past review.
pg_dump -d "$DB" --data-only --no-owner --no-privileges --disable-triggers \
  > "$OUT/data/data.sql" 2>"$OUT/data/data.err" \
  || fail "pg_dump --data-only failed; see $OUT/data/data.err"

# Sequence state travels with --data-only via setval(); assert it is present,
# because a restored identity column that restarts at 1 collides on the next
# insert and does so silently until then.
SETVALS=$(grep -c "setval" "$OUT/data/data.sql" || true)
echo "   data      : $(wc -l < "$OUT/data/data.sql" | tr -d ' ') lines, $SETVALS setval call(s)"

# ── per-table row counts and content hashes ───────────────────────────────
cat > "$OUT/hashes/_table_hashes.sql" <<'SQLEOF'
-- Per-table row count and content hash. Generated into the package so the
-- destination runs BYTE-IDENTICAL SQL rather than a re-typed equivalent.
--
-- The hash is over each row rendered as text, sorted by that text. Sorting by
-- the rendering rather than by a key means physical order, insertion order and
-- any clustering difference cannot change the hash, while a single changed
-- character in any column does.
--
-- Rendering is pinned below (timezone, datestyle, float digits, bytea,
-- interval). Without that pin the same rows hash differently on a machine in
-- another timezone -- the sort of green-then-red-then-muted checker this
-- project keeps having to delete.
--
-- ══════════════════════════════════════════════════════════════════════════
-- WHY THIS USES \gexec AND NOT A TEMPORARY TABLE
-- ══════════════════════════════════════════════════════════════════════════
-- The first version of this file built its results in a `create temporary
-- table _tbl_hash`. That CREATE is DDL, sql/01 installs an event trigger on
-- ddl_command_end, and so MEASURING the database wrote a row into
-- schema_changelog:
--
--   (590,"2026-08-07T18:51:02Z",<db_user>,"CREATE TABLE",table,
--    pg_temp._tbl_hash,)
--
-- The hash of schema_changelog therefore covered a row created by the act of
-- hashing, at a timestamp unique to that run. Source and destination produced
-- the same ROW COUNT -- each added exactly one -- and different CONTENT, so the
-- row-count check passed and the content check failed for a reason that had
-- nothing to do with the restore.
--
-- The tempting fixes are both wrong. Excluding schema_changelog from hashing
-- would stop verifying the one table that records schema tampering. Turning the
-- event trigger off during hashing would hide the measurement instead of not
-- making it. So the measurement stops emitting DDL: the per-table queries are
-- generated as text and run with psql's \gexec, which executes them without
-- creating anything.
--
-- Recorded at length because a checker that changes what it measures is not a
-- checker, and this one looked correct.
set timezone='UTC'; set datestyle='ISO, YMD'; set extra_float_digits=3;
set bytea_output='hex'; set intervalstyle='postgres';
set search_path = public, extensions;
\pset format unaligned
\pset tuples_only on
\pset fieldsep '\t'
\pset footer off

select format(
  'select %L, %L, count(*)::text, encode(digest(coalesce(string_agg(x, chr(10) order by x), %L), %L), %L) from (select t::text as x from %I.%I t) s',
  n.nspname, c.relname, '', 'sha256', 'hex', n.nspname, c.relname)
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname in ('public','vault_auth') and c.relkind = 'r'
  and not exists (select 1 from pg_depend d where d.objid = c.oid and d.deptype = 'e')
order by n.nspname, c.relname
\gexec
SQLEOF

psql -d "$DB" -X -q -f "$OUT/hashes/_table_hashes.sql" \
  > "$OUT/hashes/table_hashes.tsv" 2>"$OUT/hashes/table_hashes.err" \
  || fail "table hashing failed; see $OUT/hashes/table_hashes.err"
TABLES=$(wc -l < "$OUT/hashes/table_hashes.tsv" | tr -d ' ')
ROWS=$(awk -F'\t' '{s+=$3} END{print s+0}' "$OUT/hashes/table_hashes.tsv")
echo "   tables    : $TABLES tables, $ROWS rows total"

# ── evidence locators, per row, so a mismatch names the record ────────────
# A single per-table hash tells you SOMETHING changed. #58 asks specifically
# about evidence locators; those get their own row-level list so a failure
# points at 'wiki:fixture/handbook#3' instead of at 'retrieval_units'.
psql -d "$DB" -X -q -t -A -F $'\t' <<'SQLEOF' > "$OUT/hashes/evidence_locators.tsv"
set timezone='UTC'; set datestyle='ISO, YMD';
set search_path = public, extensions;
select ru.exact_locator,
       ru.source_relation,
       ru.source_id::text,
       ru.unit_kind,
       ru.ordinal::text,
       ru.record_status::text,
       ru.source_content_hash,
       encode(digest(ru.rendered_text,'sha256'),'hex'),
       coalesce(ru.provenance_basis::text,''),
       coalesce(ru.citation,''),
       case when ru.invalidated_at is null then 'live' else 'invalidated' end
from retrieval_units ru
order by ru.exact_locator, ru.id;
SQLEOF

# ── lifecycle baseline ────────────────────────────────────────────────────
# A content hash is not a breakdown: it tells you something changed, not that
# four rows moved from current to superseded. The distribution is carried
# separately so check D can name the transition.
psql -d "$DB" -X -q -t -A -F $'\t' <<'SQLEOF' > "$OUT/hashes/lifecycle.tsv"
select 'memories', string_agg(status||'='||n, ',' order by status)
from (select status::text as status, count(*) n from memories group by 1) s
union all
select 'wiki_pages', string_agg(status||'='||n, ',' order by status)
from (select status::text as status, count(*) n from wiki_pages group by 1) s;
SQLEOF

# ── supersession chains, materialized as evidence ─────────────────────────
psql -d "$DB" -X -q -t -A -F $'\t' <<'SQLEOF' > "$OUT/hashes/supersession_chains.tsv"
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

# ── source-side probes, recorded BEFORE the restore ───────────────────────
# #58 asks for positive / negative / conflict / stale-state / evidence-request
# probes. Running them on the source too is what makes the destination results
# meaningful: "the negative probe was rejected after restore" only proves
# something if it was also rejected before.
bash "$TESTS_DIR/sovereign_probes.sh" "$DB" > "$OUT/probes/source_probes.txt" 2>&1
PROBE_RC=$?
echo "   probes    : source-side rc=$PROBE_RC ($(grep -c '^PROBE' "$OUT/probes/source_probes.txt" || echo 0) probes)"

# ── manifest + checksums ──────────────────────────────────────────────────
bash "$TESTS_DIR/release_manifest.sh" "$OUT" || fail "release manifest generation failed"

echo
echo "EXPORT COMPLETE: $OUT"
echo "  package checksum : $(awk -F'\"' '/\"package_sha256\"/{print $4}' "$OUT/manifest.json" 2>/dev/null || true)"
echo "  next: ./tests/restore_sovereign_package.sh $OUT"
exit 0
