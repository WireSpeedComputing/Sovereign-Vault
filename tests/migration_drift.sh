#!/usr/bin/env bash
# tests/migration_drift.sh
#
# Executable drift inventory: what is APPLIED to a deployment versus what is
# COMMITTED to this repo. Part of upstream sovereign-memory-core #58.
#
# ── WHY THIS EXISTS ────────────────────────────────────────────────────────
# Three times in this project an applied migration had no repo file:
#
#   Migration A (#71)                 existed only in a chat transcript
#   Migration B (#72)                 same
#   36_retrieval_embedding_backlog    applied via apply_migration, never filed
#
# Every one was caught by a human noticing. That does not scale, and the third
# was the expensive kind: retrieval_embedding_backlog() is the RPC the deployed
# embed-retrieval-units edge function calls, so a fresh install from this repo
# produced a database where that function returned 500 on a missing RPC. The
# schema replayed clean. Nothing said the pipeline was broken.
#
# A repo that has drifted from its deployment is not a repo you can rebuild
# from, which is the same claim tests/replay_fresh_install.sh exists to defend.
# Replay proves the repo builds. This proves the repo is COMPLETE.
#
# ── WHAT IT CANNOT DO ──────────────────────────────────────────────────────
# This compares migration INVENTORIES, not schema content. A repo file whose
# body has drifted from the applied object still shows as present here. Catching
# that needs definition-level comparison (canonicalized bodies, signatures,
# ownership, security mode, search paths, grants, triggers, policies,
# constraints, indexes) -- that is the restore-verification half of #58 and is
# not this script. Stated plainly so a green run is not over-read.
#
# ── USAGE ──────────────────────────────────────────────────────────────────
#   ./tests/migration_drift.sh applied.tsv
#
# where applied.tsv is `version<TAB>name` per line, obtained WITHOUT mutating
# anything:
#
#   select version, name from supabase_migrations.schema_migrations order by version;
#
# Exit 0 = inventories reconcile. Exit 1 = drift; each item is listed.
#
# The repo side is read from sql/*.sql. A repo file declares which deployment
# migrations it carries with a MIGRATION: line in its header, e.g.
#
#   -- MIGRATION: 37_wiki_supersession_issue71
#
# A file may declare several (sql/23 folds three) and a migration may be
# declared by exactly one file.
#
# ── THE BASELINE ───────────────────────────────────────────────────────────
# Migrations at or before the version in tests/migration_baseline.txt are NOT
# checked. Everything after it must declare a file.
#
# This is not laziness, it is the honest boundary. The historical mapping from
# deployment migrations to repo files is many-to-one (several fix migrations
# collapsed into one file) and was never recorded at the time. Reconstructing it
# from migration NAMES would be a guess dressed up as an inventory -- the same
# move as retyping applied DDL from a description, which this project has now
# refused three times. A checker that emits thirty-five reconstructed false
# positives gets muted in a week, and then it catches nothing.
#
# So: history is declared out of scope, explicitly and in one place, and
# everything from the baseline forward is checked strictly. Lower the baseline
# whenever someone verifies an older mapping against the applied DDL.

set -uo pipefail
export LC_ALL="${LC_ALL:-C}"

APPLIED_FILE="${1:-}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SQL_DIR="$REPO_ROOT/sql"

if [ -z "$APPLIED_FILE" ] || [ ! -f "$APPLIED_FILE" ]; then
  cat <<USAGE
usage: $0 <applied.tsv>

  applied.tsv: lines of  version<TAB>name  from the deployment:
    select version, name from supabase_migrations.schema_migrations order by version;

  This script never connects to a deployment itself. The read is done by
  whoever runs it, deliberately: a drift checker that holds production
  credentials is a bigger risk than the drift it detects.
USAGE
  exit 2
fi

BASELINE_FILE="$REPO_ROOT/tests/migration_baseline.txt"
BASELINE="$(grep -oE '^[0-9]{14}' "$BASELINE_FILE" 2>/dev/null | head -1)"
BASELINE_REPO_FILE="$(grep -oE '^BASELINE_REPO_FILE=[0-9]+' "$BASELINE_FILE" 2>/dev/null | head -1 | cut -d= -f2)"
BASELINE_REPO_FILE="${BASELINE_REPO_FILE:-0}"
if [ -z "$BASELINE" ]; then
  echo "no baseline version found in $BASELINE_FILE"; exit 2
fi
echo "baseline: migrations at or before $BASELINE are out of scope (see $(basename "$BASELINE_FILE"))"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── repo side ──────────────────────────────────────────────────────────────
# Declared migrations, and which file declared each (to catch double-claims).
: > "$TMP/declared"
: > "$TMP/undeclared_files"
: > "$TMP/historical_files"
for f in "$SQL_DIR"/*.sql; do
  base="$(basename "$f")"
  found=0
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    printf '%s\t%s\n' "$m" "$base" >> "$TMP/declared"
    found=1
  done < <(grep -oE '^-- MIGRATION: [A-Za-z0-9_.-]+' "$f" | sed 's/^-- MIGRATION: //')
  if [ "$found" -eq 0 ]; then
    num="$(printf '%s' "$base" | grep -oE '^[0-9]+' || echo 999)"
    if [ "$((10#$num))" -le "$BASELINE_REPO_FILE" ]; then
      echo "$base" >> "$TMP/historical_files"
    else
      echo "$base" >> "$TMP/undeclared_files"
    fi
  fi
done

cut -f1 "$TMP/declared" | sort > "$TMP/repo_migrations"
awk -F'\t' -v b="$BASELINE" '$1+0 > b+0 { gsub(/[[:space:]]*$/,"",$2); print $2 }' \
  "$APPLIED_FILE" | sort > "$TMP/applied_migrations"

DRIFT=0

echo "== applied but NOT committed =="
if comm -13 "$TMP/repo_migrations" "$TMP/applied_migrations" | grep -q .; then
  comm -13 "$TMP/repo_migrations" "$TMP/applied_migrations" | sed 's/^/  /'
  echo "  ^^ these are running on the deployment with no file in this repo."
  echo "     A fresh install will NOT reproduce them. Read the applied DDL back"
  echo "     with pg_get_functiondef()/pg_dump and file it -- do not retype it"
  echo "     from memory or from a description."
  DRIFT=1
else
  echo "  none"
fi

echo "== committed but NOT applied =="
if comm -23 "$TMP/repo_migrations" "$TMP/applied_migrations" | grep -q .; then
  comm -23 "$TMP/repo_migrations" "$TMP/applied_migrations" | sed 's/^/  /'
  echo "  ^^ the repo claims these are deployment migrations but the deployment"
  echo "     has not run them. Either the claim is wrong, or an apply is pending."
  DRIFT=1
else
  echo "  none"
fi

echo "== declared by more than one file =="
if cut -f1 "$TMP/declared" | sort | uniq -d | grep -q .; then
  for m in $(cut -f1 "$TMP/declared" | sort | uniq -d); do
    echo "  $m  <- $(awk -v k="$m" -F'\t' '$1==k{printf "%s ", $2}' "$TMP/declared")"
  done
  echo "  ^^ a migration must be carried by exactly one file, or reconciling"
  echo "     the repo against the deployment stops being deterministic."
  DRIFT=1
else
  echo "  none"
fi

echo "== repo files below the baseline (historical, mapping never recorded) =="
if [ -s "$TMP/historical_files" ]; then
  echo "  $(wc -l < "$TMP/historical_files" | tr -d ' ') files, sql/00 through sql/$(printf '%02d' "$BASELINE_REPO_FILE") -- out of scope, see $(basename "$BASELINE_FILE")"
else
  echo "  none"
fi

echo "== repo files declaring no migration (not yet applied) =="
if [ -s "$TMP/undeclared_files" ]; then
  sed 's/^/  /' "$TMP/undeclared_files"
  echo "  ^^ informational, not drift by itself. Each should be a file that is"
  echo "     genuinely not applied yet. If one of these IS applied, it is"
  echo "     missing its MIGRATION: header and the check above cannot see it."
else
  echo "  none"
fi

echo
if [ "$DRIFT" -ne 0 ]; then
  echo "MIGRATION DRIFT DETECTED."
  exit 1
fi
echo "MIGRATION INVENTORY RECONCILES."
echo "NOTE: inventory only. This does not compare definitions, grants, or"
echo "policies -- a file present but stale still reads as clean here."
