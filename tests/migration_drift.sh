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

# ── BODY COVERAGE: is the SQL stored anywhere at all? ─────────────────────
# The checks above compare applied migrations to PUBLIC repo files by MIGRATION:
# header. They say nothing about whether the migration BODY exists outside the
# hosted database. With 85 applied migrations and zero SQL in the private repo,
# every check above reported clean -- the checker was blind to the single
# largest structural risk in the project. That is the shape of failure this repo
# has now hit seven times: a check reporting success without checking.
#
# NOT baseline-filtered, deliberately. The baseline exists because the historical
# mapping from migrations to public repo files was never recorded. Body coverage
# has no such excuse: a migration from July is exactly as unrecoverable as one
# from today if its SQL exists only in a hosted database.
#
# If body coverage CANNOT be established, that is a FAILURE, not a skip. A skip
# here would restore precisely the blindness this section was added to remove.
# No default path. The location of the private migrations repository is
# deployment data and does not belong in a public repo -- the same reason the
# secret sweep itself lives outside this repository. Set BODIES_REPO in your
# environment. Unset means "cannot verify", which is a failure below, not a skip.
BODIES_REPO="${BODIES_REPO:-}"
BODY_DRIFT=0
echo "== migration bodies stored outside the hosted database =="
if [ -z "$BODIES_REPO" ]; then
  echo "  CANNOT VERIFY: BODIES_REPO is not set"
  echo "  ^^ This is a FAILURE, not a skip. Point BODIES_REPO at the private"
  echo "     migrations repository. A drift check that cannot see whether the"
  echo "     SQL exists anywhere is not a drift check."
  BODY_DRIFT=1
elif [ ! -d "$BODIES_REPO" ]; then
  echo "  CANNOT VERIFY: no bodies repo at the configured BODIES_REPO path"
  echo "  ^^ This is a FAILURE, not a skip. Set BODIES_REPO to the private"
  echo "     migrations repository. A drift check that cannot see whether the"
  echo "     SQL exists anywhere is not a drift check."
  BODY_DRIFT=1
elif [ ! -f "$BODIES_REPO/MANIFEST.tsv" ]; then
  echo "  CANNOT VERIFY: $BODIES_REPO exists but has no MANIFEST.tsv"
  echo "  ^^ FAILURE. Run extract-migrations.sh. Zero bodies stored is the"
  echo "     condition this check exists to detect, and it is the current state."
  BODY_DRIFT=1
else
  MISSING_BODIES=0
  while IFS="$(printf '\t')" read -r _v mname; do
    [ -z "$mname" ] && continue
    if ! awk -F"$(printf '\t')" -v n="$mname" '$3==n{found=1} END{exit !found}' \
         "$BODIES_REPO/MANIFEST.tsv" 2>/dev/null; then
      echo "  NO BODY STORED: $mname"
      MISSING_BODIES=$((MISSING_BODIES+1))
    fi
  done < "$APPLIED_FILE"
  if [ "$MISSING_BODIES" -ne 0 ]; then
    echo "  ^^ $MISSING_BODIES applied migration(s) exist only inside the hosted"
    echo "     database. If that project is lost, so is the ability to rebuild it."
    BODY_DRIFT=1
  else
    echo "  none -- every applied migration has a stored body"
  fi
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

# ── EXIT CODES: two different questions, two different answers ────────────
# 1  INVENTORY DRIFT -- an applied migration has no repo file, or vice versa.
#    This is a property of THIS deployment against THIS repo.
# 3  INVENTORY RECONCILES, BODY COVERAGE UNVERIFIED OR MISSING -- a property of
#    the PROJECT, not of any one deployment.
#
# They were one exit code until WO-14 Phase 3d, and conflating them made
# tests/verify_restore.sh report that a faithful restore had drifted, because
# migration bodies are not stored anywhere. A proof that can never pass is one
# people learn to ignore, which is how a gate dies quietly instead of loudly.
#
# 3 is NOT a pass. Callers that require full recoverability must treat any
# non-zero as failure; callers verifying restore fidelity specifically can
# distinguish 3 from 1. Neither is allowed to call it clean.
echo
if [ "$DRIFT" -ne 0 ]; then
  echo "MIGRATION DRIFT DETECTED."
  [ "$BODY_DRIFT" -ne 0 ] && echo "ALSO: migration body coverage unverified or incomplete."
  exit 1
fi
if [ "$BODY_DRIFT" -ne 0 ]; then
  echo "MIGRATION INVENTORY RECONCILES, BUT BODY COVERAGE IS UNVERIFIED OR INCOMPLETE."
  echo "This is exit 3, not exit 0. The inventory question and the recoverability"
  echo "question have different answers right now and both are reported."
  exit 3
fi
echo "MIGRATION INVENTORY RECONCILES."
echo "NOTE: inventory only. This does not compare definitions, grants, or"
echo "policies -- a file present but stale still reads as clean here."
