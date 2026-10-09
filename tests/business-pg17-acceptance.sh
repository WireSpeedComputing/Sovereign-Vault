#!/usr/bin/env bash
set -euo pipefail
task_dir=$(mktemp -d /tmp/business-pg17.XXXXXXXX)
task_container="business-pg17-${task_dir##*.}"
created=0
cleanup() {
  if [[ "$created" == 1 ]]; then docker rm -f "$task_container" >/dev/null; fi
  case "$task_dir" in /tmp/business-pg17.*) rm -rf -- "$task_dir" ;; *) printf 'Unexpected temporary path; retained.\n' >&2 ;; esac
}
trap cleanup EXIT
node "$(dirname "$0")/business-pg17-fixture.mjs" "$task_dir"
# The isolated container runs as UID 999, not the host caller. Only generated
# synthetic fixture SQL is made readable; the bind mount remains read-only.
chmod 0755 "$task_dir"
chmod 0644 "$task_dir"/pg17-*.sql
docker image inspect postgres:17 >/dev/null
if docker container inspect "$task_container" >/dev/null 2>&1; then
  printf 'Refusing to reuse an existing acceptance container.\n' >&2
  exit 1
fi
docker run --pull never -d --name "$task_container" --network none --user 999:999 \
  --tmpfs /var/lib/postgresql/data:rw,uid=999,gid=999,mode=0700,size=256m \
  --cap-drop ALL --security-opt no-new-privileges --memory 256m --pids-limit 128 --cpus 1 \
  --log-driver local -e POSTGRES_HOST_AUTH_METHOD=trust \
  --mount "type=bind,src=$task_dir,dst=/work,readonly" postgres:17 >/dev/null
created=1
ready=0
for n in $(seq 1 30); do
  if docker exec "$task_container" pg_isready -U postgres -d postgres >/dev/null 2>&1; then ready=1; break; fi
  sleep 1
done
if [[ "$ready" != 1 ]]; then docker logs "$task_container"; exit 1; fi
sql() { docker exec "$task_container" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q -f "/work/$1"; }
sql pg17-acceptance.sql
hold_and_check() {
  local hold="$1" marker="$2" check="$3" log="$task_dir/$1.log"
  sql "$hold" >"$log" 2>&1 &
  local held_pid=$! observed=0
  for n in $(seq 1 30); do
    if grep -q "$marker" "$log"; then observed=1; break; fi
    if ! kill -0 "$held_pid" 2>/dev/null; then cat "$log"; wait "$held_pid"; exit 1; fi
    sleep 0.2
  done
  if [[ "$observed" != 1 ]]; then cat "$log"; exit 1; fi
  sql "$check"
  wait "$held_pid"
}
hold_and_check pg17-target-hold.sql TARGET_HELD pg17-target-busy.sql
hold_and_check pg17-advisory-hold.sql ADVISORY_HELD pg17-advisory-busy.sql
hold_and_check pg17-share-hold.sql SHARE_HELD pg17-share-control.sql
printf 'PG17_ALL_ACCEPTANCE_PASS\n'
