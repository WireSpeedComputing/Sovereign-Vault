#!/usr/bin/env bash
set -euo pipefail
umask 077
if [[ "$#" -gt 1 ]]; then printf 'Supply at most one private receipt parent directory.\n' >&2; exit 1; fi
private_parent="${1:-/tmp}"
if [[ "$private_parent" != /* || ! -d "$private_parent" ]]; then printf 'Private receipt parent must be an existing absolute directory.\n' >&2; exit 1; fi
repo_root=$(cd "$(dirname "$0")/.." && pwd -P)
private_parent=$(cd "$private_parent" && pwd -P)
case "$private_parent/" in "$repo_root/"*) printf 'Receipts must remain outside the source checkout.\n' >&2; exit 1 ;; esac
receipt_dir=$(mktemp -d "$private_parent/business-core-receipt.XXXXXXXX")
task_dir=$(mktemp -d /tmp/business-core-pg17.XXXXXXXX)
task_container="business-core-pg17-${task_dir##*.}"
container_id=""
created=0
cleanup() {
  if [[ "$created" == 1 ]]; then docker rm -f "$container_id" >"$receipt_dir/cleanup.log" 2>&1; fi
  case "$task_dir" in /tmp/business-core-pg17.*) rm -rf -- "$task_dir" ;; *) printf 'Unexpected temporary path; retained.\n' >&2 ;; esac
}
trap cleanup EXIT
printf 'PRIVATE_RECEIPT_DIRECTORY=%s\n' "$receipt_dir"
if ! node "$repo_root/tests/business-core-pg17-fixture.mjs" "$task_dir" >"$receipt_dir/generator.log" 2>&1; then
  printf 'Whole-profile generation failed; details retained in the private receipt.\n' >&2
  exit 1
fi
cp "$task_dir/core-source-hashes.json" "$receipt_dir/"
# Only byte-copied public SQL and synthetic controls live in this exclusive
# directory; UID 999 must traverse it. The container mount stays read-only.
find "$task_dir" -type d -exec chmod 0755 {} +
find "$task_dir" -type f -exec chmod 0644 {} +
image_id=$(docker image inspect pgvector/pgvector:pg17 --format '{{.Id}}' 2>"$receipt_dir/image-inspect.log")
printf '%s\n' "$image_id" >"$receipt_dir/image-id.txt"
if docker container inspect "$task_container" >/dev/null 2>&1; then
  printf 'Refusing to reuse an existing acceptance container.\n' >&2
  exit 1
fi
container_id=$(docker create --pull never --name "$task_container" --network none --user 999:999 \
  --tmpfs /var/lib/postgresql/data:rw,uid=999,gid=999,mode=0700,size=256m \
  --cap-drop ALL --security-opt no-new-privileges --memory 512m --pids-limit 128 --cpus 1 \
  --log-driver local -e POSTGRES_HOST_AUTH_METHOD=trust \
  --mount "type=bind,src=$task_dir,dst=/work,readonly" "$image_id" 2>"$receipt_dir/container.log")
if [[ ! "$container_id" =~ ^[0-9a-f]{64}$ ]]; then printf 'Unexpected container identity; refusing to continue.\n' >&2; exit 1; fi
created=1
docker start "$container_id" >"$receipt_dir/start.log" 2>&1
ready=0
for n in $(seq 1 30); do
  if docker exec "$container_id" pg_isready -U postgres -d postgres >/dev/null 2>&1; then ready=1; break; fi
  sleep 1
done
if [[ "$ready" != 1 ]]; then
  docker logs "$container_id" >"$receipt_dir/postgres.log" 2>&1
  printf 'Isolated PostgreSQL did not become ready; details retained in the private receipt.\n' >&2
  exit 1
fi
if ! docker exec "$container_id" psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 -q -f /work/core-acceptance.sql >"$receipt_dir/acceptance.log" 2>&1; then
  docker logs "$container_id" >"$receipt_dir/postgres.log" 2>&1
  printf 'Whole-profile acceptance failed; details retained in the private receipt.\n' >&2
  exit 1
fi
docker logs "$container_id" >"$receipt_dir/postgres.log" 2>&1
printf 'CORE_PG17_ALL_ACCEPTANCE_PASS\n'
