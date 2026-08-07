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

echo "  tables with rows after replay (expect only schema_changelog and provenance_registry):"
psql -d "$DB" -t -A -c "select coalesce(string_agg(relname||'='||n_live_tup,', '),'(all empty)') from pg_stat_user_tables where n_live_tup>0;" | sed 's/^/    /'

if [ "$PERIM" != "0" ] || [ "$NORLS" != "(none)" ]; then
  echo "REPLAY APPLIED BUT VERIFICATION FAILED"
  exit 1
fi

echo
echo "REPLAY CLEAN."
echo "NOTE: a local replay cannot prove cloud-host default-privilege behavior"
echo "on newly created objects, nor extension placement. Those still require"
echo "validation against a real hosted project."
