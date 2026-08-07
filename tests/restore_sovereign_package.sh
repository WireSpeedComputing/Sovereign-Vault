#!/usr/bin/env bash
# tests/restore_sovereign_package.sh
#
# Restore a sovereign export package into a SECOND, CLEAN PostgreSQL
# environment with zero dependency on the original hosted project.
# Part of upstream sovereign-memory-core #58.
#
# ── WHAT "ZERO DEPENDENCY" MEANS HERE, CONCRETELY ─────────────────────────
# This script:
#   * initdb's its own cluster, on its own port, in its own data directory
#   * applies the sql/*.sql files CARRIED IN THE PACKAGE, not the repo's
#   * loads the package's data payload
#   * makes no network call, reads no credential, and contacts no Supabase API
#
# The repo is still consulted for ONE thing -- comparing the package's copy of
# each sql file against the working tree, so repo drift is reported. That
# comparison is informational; the restore does not use the repo's files. If
# the repo is absent the restore still completes and says so.
#
# ── ISOLATION ─────────────────────────────────────────────────────────────
# Port and data directory are distinct from tests/replay_fresh_install.sh
# (5433 / /tmp/svreplay_pgdata) so the two can run concurrently without
# colliding. Override with RESTORE_PORT / RESTORE_PGDATA / RESTORE_SOCK.
#
# ── USAGE ─────────────────────────────────────────────────────────────────
#   ./tests/restore_sovereign_package.sh <package-dir> [--keep]
#
#   --keep   leave the cluster running afterwards, so verify_restore.sh can be
#            pointed at it. Without it the cluster is destroyed on exit and the
#            restore proves only that the load succeeded.
#
# Exit 0 = restored. Non-zero = the destination is not usable; it is disposable
# either way, and the source was never touched.

set -uo pipefail
export LC_ALL="${LC_ALL:-C}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="${1:-}"
KEEP=0
[ "${2:-}" = "--keep" ] && KEEP=1

PORT="${RESTORE_PORT:-5462}"
PGDATA_DIR="${RESTORE_PGDATA:-/tmp/agentB_restore_pgdata}"
SOCK_DIR="${RESTORE_SOCK:-/tmp/agentB_restore_sock}"
DB="${RESTORE_DB:-svrestore}"

[ -n "$PKG" ] && [ -d "$PKG" ] || { echo "usage: $0 <package-dir> [--keep]" >&2; exit 2; }
PKG="$(cd "$PKG" && pwd)"

fail() { echo "RESTORE FAILED: $*" >&2; exit 1; }

cleanup() {
  if [ "$KEEP" -eq 0 ]; then
    pg_ctl -D "$PGDATA_DIR" stop -m fast >/dev/null 2>&1 || true
    rm -rf "$PGDATA_DIR" "$SOCK_DIR"
  fi
}
trap cleanup EXIT

echo "== restoring sovereign package =="
echo "   package : $PKG"
echo "   port    : $PORT   pgdata: $PGDATA_DIR"

# ── 1. verify the package before trusting a single byte of it ─────────────
# This runs FIRST and is fatal. Loading a package that does not match its own
# checksums and then verifying the result would produce a green report about a
# database built from unknown bytes.
[ -f "$PKG/CHECKSUMS.sha256" ] || fail "no CHECKSUMS.sha256 in package"
if ! ( cd "$PKG" && shasum -a 256 -c CHECKSUMS.sha256 --quiet ) 2>/tmp/agentB_ck.err; then
  echo "  files that do not match their recorded hash:" >&2
  ( cd "$PKG" && shasum -a 256 -c CHECKSUMS.sha256 2>/dev/null | grep -v ': OK$' | sed 's/^/    /' ) >&2
  fail "package checksum verification failed"
fi
PKG_SHA="$(shasum -a 256 "$PKG/CHECKSUMS.sha256" | awk '{print $1}')"
DECLARED="$(awk -F'"' '/"package_sha256"/{print $4}' "$PKG/manifest.json" 2>/dev/null)"
if [ -n "$DECLARED" ] && [ "$DECLARED" != "$PKG_SHA" ]; then
  fail "manifest package_sha256 ($DECLARED) != computed ($PKG_SHA)"
fi
echo "   checksum: OK ($PKG_SHA)"

# ── 2. requirements from the package's own version metadata ───────────────
NEED_NUM="$(awk -F= '/^server_version_num=/{print $2}' "$PKG/meta/versions.txt")"
command -v initdb >/dev/null || fail "initdb not on PATH"
HAVE_NUM="$(psql --version | awk '{print $3}' | awk -F. '{printf "%d%04d", $1, $2}')"
if [ -n "$NEED_NUM" ] && [ "$HAVE_NUM" -lt "$((NEED_NUM/100*100))" ] 2>/dev/null; then
  echo "   WARNING: destination psql is older than the source server ($HAVE_NUM < $NEED_NUM)"
fi

# ── 3. repo drift report (informational; the restore does not use the repo) ─
echo "== repo drift against the package's sql copies =="
if [ -d "$REPO_ROOT/sql" ] && [ -f "$PKG/meta/repo_sql_manifest.tsv" ]; then
  DRIFT=0
  while IFS=$'\t' read -r name want; do
    [ -z "$name" ] && continue
    if [ ! -f "$REPO_ROOT/sql/$name" ]; then
      echo "   MISSING IN REPO  $name"; DRIFT=1; continue
    fi
    got="$(shasum -a 256 "$REPO_ROOT/sql/$name" | awk '{print $1}')"
    [ "$got" = "$want" ] || { echo "   CHANGED IN REPO  $name"; DRIFT=1; }
  done < "$PKG/meta/repo_sql_manifest.tsv"
  for f in "$REPO_ROOT"/sql/*.sql; do
    b="$(basename "$f")"
    grep -q "^$b"$'\t' "$PKG/meta/repo_sql_manifest.tsv" || { echo "   NEW IN REPO      $b"; DRIFT=1; }
  done
  [ "$DRIFT" -eq 0 ] && echo "   none: the repo working tree matches the package"
  [ "$DRIFT" -ne 0 ] && echo "   ^^ informational. The restore uses the PACKAGE's copies, so this does"
  [ "$DRIFT" -ne 0 ] && echo "      not affect the result -- it tells you the repo has moved since export."
else
  echo "   skipped (no repo checkout, or no manifest) -- the restore does not need one"
fi

# ── 4. clean cluster ──────────────────────────────────────────────────────
echo "== initializing clean destination cluster =="
pg_ctl -D "$PGDATA_DIR" stop -m fast >/dev/null 2>&1 || true
rm -rf "$PGDATA_DIR" "$SOCK_DIR"
mkdir -p "$SOCK_DIR"
initdb -D "$PGDATA_DIR" >/tmp/agentB_restore_initdb.log 2>&1 \
  || fail "initdb failed, see /tmp/agentB_restore_initdb.log"
pg_ctl -D "$PGDATA_DIR" \
  -o "-p $PORT -k $SOCK_DIR -c listen_addresses=''" \
  -l /tmp/agentB_restore_server.log start >/dev/null \
  || fail "server start failed, see /tmp/agentB_restore_server.log"
sleep 2

export PGHOST="$SOCK_DIR" PGPORT="$PORT"
createdb "$DB" || fail "createdb failed"

# Assert the destination really is empty before anything is applied. A restore
# into a database that already had objects would produce a green verification
# about a database the package did not build.
PRE=$(psql -d "$DB" -t -A -c "select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind in ('r','v','m');")
[ "$PRE" = "0" ] || fail "destination is not empty ($PRE relations in public before restore)"
echo "   destination is empty: 0 relations in public"

# ── 5. apply the package's schema ─────────────────────────────────────────
echo "== applying package schema (schema/sql/*.sql, numeric order) =="
APPLIED=0
for f in $(ls "$PKG"/schema/sql/*.sql | sort); do
  if out=$(psql -d "$DB" -v ON_ERROR_STOP=1 -q -f "$f" 2>&1); then
    echo "   OK    $(basename "$f")"
    APPLIED=$((APPLIED+1))
  else
    echo "   FAIL  $(basename "$f")"
    printf '%s\n' "$out" | grep -E "ERROR|FATAL" | head -5 | sed 's/^/         /'
    fail "schema apply stopped at $(basename "$f")"
  fi
done
echo "   applied $APPLIED file(s)"

# ── 6. clear schema-seeded bootstrap rows ─────────────────────────────────
# FOUND BY RUNNING THIS, not by design. Several sql files INSERT rows as part of
# applying the schema -- schema_changelog's bootstrap entry (sql/01),
# provenance_registry (sql/03), perimeter_exception (sql/28),
# consequential_domain_policy (sql/31). Loading the package's data-only payload
# on top of those collides:
#
#   ERROR: duplicate key value violates unique constraint
#          "consequential_domain_policy_pkey"
#
# and the restore stopped dead. Worth stating plainly, because the tempting
# fixes are both wrong: ON CONFLICT DO NOTHING would silently keep the
# DESTINATION's version of any row whose content differs from the source's, and
# excluding those tables from the payload would silently drop whatever the
# source had added to them.
#
# The correct semantics for a restore is that the PACKAGE is authoritative for
# every row. So the schema's own seed rows are cleared first and the payload
# supplies all of them. One consequence to be explicit about: schema_changelog
# in the restored database is the SOURCE's DDL history, not the destination's.
# That is right -- it is data, and the source is the system of record -- but it
# does mean the restored changelog does not record the restore.
echo "== clearing schema-seeded bootstrap rows =="
psql -d "$DB" -X -q -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<'SQLEOF' || fail "could not clear seed rows"
do $$
declare stmt text;
begin
  select string_agg(format('%I.%I', n.nspname, c.relname), ', ')
    into stmt
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname in ('public','vault_auth') and c.relkind = 'r'
    and not exists (select 1 from pg_depend d where d.objid = c.oid and d.deptype = 'e');
  if stmt is not null then
    execute 'truncate table ' || stmt || ' restart identity cascade';
  end if;
end $$;
SQLEOF
echo "   cleared; the package payload is authoritative for every row"

# ── 7. load the data payload ──────────────────────────────────────────────
# event_triggers = off during the load. pg_dump --disable-triggers emits
# ALTER TABLE ... DISABLE/ENABLE TRIGGER around every table, and ALTER TABLE is
# DDL, so trg_log_ddl_change would write dozens of rows into schema_changelog
# WHILE schema_changelog is being COPYed into. The restored changelog would then
# be the source's history plus a burst of restore mechanics, and would never
# match the package's hash. Turning the event trigger off for the load keeps the
# restored changelog equal to the source's -- which is the row set the package
# actually carries.
echo "== loading data payload =="
cat > "$SOCK_DIR/_load.sql" <<SQLEOF
set event_triggers = off;
\\i $PKG/data/data.sql
set event_triggers = on;
SQLEOF
if out=$(psql -d "$DB" -v ON_ERROR_STOP=1 -q -f "$SOCK_DIR/_load.sql" 2>&1); then
  echo "   data loaded"
else
  printf '%s\n' "$out" | grep -E "ERROR|FATAL" | head -10 | sed 's/^/     /'
  fail "data load failed"
fi

EVT=$(psql -d "$DB" -t -A -c "select evtenabled from pg_event_trigger where evtname='trg_log_ddl_change';")
[ "$EVT" = "O" ] || fail "the DDL changelog event trigger is not enabled after load (evtenabled=$EVT)"
echo "   DDL changelog event trigger re-enabled"

# The payload disables triggers around each table and re-enables them. If a
# re-enable were missed the restored database would look correct and enforce
# nothing -- which is precisely the class of failure this whole work order is
# about. Checked explicitly rather than assumed.
DISABLED=$(psql -d "$DB" -t -A -c "
  select coalesce(string_agg(n.nspname||'.'||c.relname||'.'||t.tgname, ', '), '')
  from pg_trigger t join pg_class c on c.oid=t.tgrelid
  join pg_namespace n on n.oid=c.relnamespace
  where not t.tgisinternal and t.tgenabled = 'D';")
if [ -n "$DISABLED" ]; then
  fail "triggers left DISABLED after restore: $DISABLED"
fi
echo "   all triggers re-enabled after load"

ROWS=$(psql -d "$DB" -t -A -c "select coalesce(sum(n_live_tup),0) from pg_stat_user_tables;")
echo "   restored rows (approx, pre-ANALYZE): $ROWS"

echo
echo "RESTORE COMPLETE."
echo "  destination: dbname=$DB host=$SOCK_DIR port=$PORT"
if [ "$KEEP" -eq 1 ]; then
  echo "  cluster left running (--keep). Verify with:"
  echo "    PGHOST=$SOCK_DIR PGPORT=$PORT ./tests/verify_restore.sh $PKG $DB"
  echo "  Stop it with: pg_ctl -D $PGDATA_DIR stop -m fast && rm -rf $PGDATA_DIR $SOCK_DIR"
else
  echo "  cluster will now be destroyed (no --keep). NOTE: without verification,"
  echo "  a successful load proves only that the SQL ran -- not that what came"
  echo "  back is what went in. Re-run with --keep and then verify_restore.sh."
fi
exit 0
