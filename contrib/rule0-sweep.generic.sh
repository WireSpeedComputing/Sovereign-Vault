#!/usr/bin/env bash
#
# rule0-sweep.generic.sh — pre-publication leak sweep for a public repository.
# Dependency-light: bash, grep, git, find, xargs. No network, no writes to the
# scanned repo, no temp state outside mktemp.
#
# ---------------------------------------------------------------------------
# WHY THIS SCRIPT CONTAINS NO PATTERNS
# ---------------------------------------------------------------------------
# A leak checker has to name the things it is looking for. If the pattern list
# lives inside the repository being protected, the checker is itself the leak.
# The usual workaround — keeping the whole checker in a private repo — makes the
# tool unshareable and unreviewable.
#
# So this file is the mechanism and nothing else. Every identifier lives in an
# external config file that stays private. The tool is public; the patterns are
# not. There is deliberately no built-in fallback pattern list: with no config,
# this script REFUSES TO RUN (exit 2) rather than printing "clean". A checker
# that can only succeed is not a checker.
#
# ---------------------------------------------------------------------------
# WHY THE TWO PASSES ARE MATCHED DIFFERENTLY (the load-bearing design decision)
# ---------------------------------------------------------------------------
# The first version of this sweep used one case-insensitive pattern list for
# everything: project refs, people, hostnames, and internal component codenames
# alike. Codenames are short, generic English words — the kind of word that is
# also a shell builtin or a common git ref name. A case-insensitive substring
# match on a codename like TEST or MAIN fires on every shell script in the tree
# and on every document that mentions a branch. The sweep produced screens of
# hits on a clean repo.
#
# The fix was not a bigger ignore list. It was splitting the patterns by what
# kind of string they are:
#
#   HARD identifiers — project refs, API keys, hostnames, domains, surnames.
#     No legitimate English usage. Matched case-INSENSITIVELY as SUBSTRINGS,
#     because they leak inside URLs, base64 blobs, and camelCase.
#
#   NAMES — component codenames, product names, team names.
#     Ordinary words that collide with ordinary text. Matched CASE-SENSITIVELY
#     and WHOLE-WORD, so `echo` the builtin does not fire a codename spelled in
#     caps, and `main` the branch does not fire a codename spelled in caps.
#
# The lesson is the point: a checker that cries wolf gets ignored. It does not
# get fixed, it gets skipped, and then it is worse than no checker at all
# because it looks like coverage.
#
# This project rediscovered the same failure independently in a completely
# different tool. A SQL perimeter assertion returned ~200 rows against the real
# deployment — almost all of them extension-owned objects the schema does not
# control and cannot revoke — while returning zero rows locally. It passed in
# the only environment where it was cheap and was unusable in the only
# environment it existed to protect, and the noise is precisely why nobody
# noticed for months. Two tools, two authors, same bug: the check was tuned for
# recall and never for actionability.
#
# ---------------------------------------------------------------------------
# WHY EXCEPTIONS ARE DECLARED, NOT HARDCODED
# ---------------------------------------------------------------------------
# Real sweeps accumulate accepted findings. Ours has one: pre-existing git
# author metadata in already-published commits, where rewriting history would
# change every SHA referenced from public documents in exchange for suppressing
# a fact that is going public anyway.
#
# The tempting implementation is a `| grep -v` bolted onto the pipeline. That is
# a silent skip: it carries no reason, no owner, no expiry, and it is
# indistinguishable from a bug six months later. Worse, it keeps suppressing
# after the underlying finding is gone, and nobody can tell.
#
# Here an exception is a declared record: id, scope, regex, justification, and
# an optional expiry. Every run prints every exception, what it suppressed, and
# why. An exception that suppressed nothing is reported as STALE (and fails
# under --strict) so it can be deleted instead of silently pre-authorising a
# future leak. An expired exception is a hard config error.
#
# The same repository reached the same conclusion in SQL: deliberate perimeter
# exposures were moved out of a function body into a declared exception table
# with a reason column, plus a review function that reports whether each
# declared exception is still present. Same shape, different language.
#
# ---------------------------------------------------------------------------
# WHAT THIS TOOL CANNOT DO
# ---------------------------------------------------------------------------
# It reads files and git history. It cannot read issue bodies, PR descriptions,
# review comments, release notes, CI logs, or uploaded artifacts — which are
# publication surfaces every bit as much as the tree is. Pattern matching also
# cannot establish context or attack value: a hostname is a leak, a paragraph
# describing which denial path is unguarded is a worse leak, and no regex finds
# the second one. This script is a floor, not a gate. Pair it with the human
# review checklist.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   rule0-sweep.generic.sh --config /private/path/sweep.config [options] REPO
#
# Exit codes: 0 = clean, 1 = findings (review before publishing), 2 = usage or
# config error. 2 is never "clean" — treat it as a failed gate in CI.
#
set -uo pipefail

PROG="$(basename "$0")"
VERSION="1.0.0"

EXIT_CLEAN=0
EXIT_FINDINGS=1
EXIT_CONFIG=2

die() { printf '%s: error: %s\n' "$PROG" "$*" >&2; exit "$EXIT_CONFIG"; }

usage() {
  cat <<'HELPTEXT'
rule0-sweep.generic.sh — pre-publication leak sweep (pattern-driven, no built-in patterns)

USAGE
  rule0-sweep.generic.sh --config FILE [options] REPO

OPTIONS
  --config FILE      Pattern config. Required (or set RULE0_SWEEP_CONFIG).
                     Keep this file OUTSIDE the repository being scanned.
  --changed          Scan files changed vs HEAD plus untracked files. Default.
  --base REF         Scan files changed vs REF (use in CI on a PR branch).
  --all              Scan every tracked/present file. Use before a first push.
  --no-history       Skip the git-history pass.
  --history-depth N  Commits of history to scan (0 = all). Overrides config.
  --strict           Stale exceptions (suppressed nothing) become failures.
  --quiet            Print findings and the verdict only.
  --version          Print version and exit.
  -h, --help         This text.

EXIT CODES
  0  clean
  1  findings — review each one before publishing
  2  usage or config error (NOT a pass)

CONFIG FORMAT
  One directive per line. '#' starts a comment only at the start of a line.
  Blank lines ignored. Values run to end of line; surrounding space trimmed.

  hard   REGEX      Hard identifier. ERE, matched case-INSENSITIVELY as a
                    SUBSTRING. For refs, keys, hostnames, domains, surnames.
  name   REGEX      Codename/product name. ERE, matched CASE-SENSITIVELY and
                    WHOLE-WORD. For ordinary words used as internal names.
  include GLOB      Restrict the scan to paths matching GLOB. Repeatable.
                    If absent, every file is scanned (recommended).
  exclude GLOB      Skip paths matching GLOB. Repeatable. '.git/*' is always
                    skipped, as is the config file itself if it is in-tree.
  history-depth N   Commits of git history to scan. Default 20. 0 = all.
  except ID | SCOPE | REGEX | JUSTIFICATION [| YYYY-MM-DD]
                    Declared, auditable exception. SCOPE is files, history, or
                    all. REGEX is an ERE matched against the whole output line
                    ("path:lineno:text"), so it can anchor on a path or on
                    content. JUSTIFICATION is mandatory and must be a real
                    sentence. The optional 5th field is an expiry date; an
                    expired exception is a config error, not a warning.
                    No '|' inside any field.

  At least one 'hard' or 'name' pattern is required.
HELPTEXT
}

# --------------------------------------------------------------------------
# argument parsing
# --------------------------------------------------------------------------
REPO=""
CONFIG="${RULE0_SWEEP_CONFIG:-}"
MODE="changed"
BASE_REF=""
DO_HISTORY=1
HISTORY_DEPTH=""
STRICT=0
QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --config)        [ $# -ge 2 ] || die "--config needs a value"; CONFIG="$2"; shift 2 ;;
    --config=*)      CONFIG="${1#*=}"; shift ;;
    --changed)       MODE="changed"; shift ;;
    --all)           MODE="all"; shift ;;
    --base)          [ $# -ge 2 ] || die "--base needs a value"; MODE="base"; BASE_REF="$2"; shift 2 ;;
    --base=*)        MODE="base"; BASE_REF="${1#*=}"; shift ;;
    --no-history)    DO_HISTORY=0; shift ;;
    --history-depth) [ $# -ge 2 ] || die "--history-depth needs a value"; HISTORY_DEPTH="$2"; shift 2 ;;
    --strict)        STRICT=1; shift ;;
    --quiet)         QUIET=1; shift ;;
    --version)       printf '%s %s\n' "$PROG" "$VERSION"; exit 0 ;;
    -h|--help)       usage; exit 0 ;;
    --)              shift; break ;;
    -*)              die "unknown option: $1" ;;
    *)               [ -z "$REPO" ] || die "more than one repo path given"; REPO="$1"; shift ;;
  esac
done
[ -n "$REPO" ] || { [ $# -gt 0 ] && REPO="$1"; }

[ -n "$REPO" ] || { usage >&2; die "no repository path given"; }
[ -d "$REPO" ] || die "not a directory: $REPO"

if [ -z "$CONFIG" ]; then
  die "no pattern config. Pass --config FILE or set RULE0_SWEEP_CONFIG.
       This tool ships with NO built-in patterns on purpose (see header).
       Refusing to run rather than reporting a meaningless 'clean'."
fi
[ -f "$CONFIG" ] || die "config file not found: $CONFIG"
[ -r "$CONFIG" ] || die "config file not readable: $CONFIG"

REPO_ABS="$(cd "$REPO" && pwd)" || die "cannot enter $REPO"
CONFIG_ABS="$(cd "$(dirname "$CONFIG")" && pwd)/$(basename "$CONFIG")"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/rule0sweep.XXXXXX")" || die "mktemp failed"
trap 'rm -rf "$WORK"' EXIT INT TERM HUP

HARD_RE="$WORK/hard.re"
NAME_RE="$WORK/name.re"
INC_GLOB="$WORK/include.glob"
EXC_GLOB="$WORK/exclude.glob"
EXCEPTIONS="$WORK/exceptions"
: >"$HARD_RE"; : >"$NAME_RE"; : >"$INC_GLOB"; : >"$EXC_GLOB"; : >"$EXCEPTIONS"

# --------------------------------------------------------------------------
# config parsing
# --------------------------------------------------------------------------
trim() { printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

CFG_DEPTH=20
LINENO_CFG=0
while IFS= read -r line || [ -n "$line" ]; do
  LINENO_CFG=$((LINENO_CFG + 1))
  line="$(trim "$line")"
  case "$line" in
    '#'*) continue ;;
    '') continue ;;
  esac

  key="${line%%[[:space:]]*}"
  val="${line#"$key"}"
  val="$(trim "$val")"

  case "$key" in
    hard)
      [ -n "$val" ] || die "config line $LINENO_CFG: 'hard' with empty pattern (would match everything)"
      printf '%s\n' "$val" >>"$HARD_RE" ;;
    name)
      [ -n "$val" ] || die "config line $LINENO_CFG: 'name' with empty pattern (would match everything)"
      printf '%s\n' "$val" >>"$NAME_RE" ;;
    include)
      [ -n "$val" ] || die "config line $LINENO_CFG: 'include' with empty glob"
      printf '%s\n' "$val" >>"$INC_GLOB" ;;
    exclude)
      [ -n "$val" ] || die "config line $LINENO_CFG: 'exclude' with empty glob"
      printf '%s\n' "$val" >>"$EXC_GLOB" ;;
    history-depth)
      case "$val" in
        ''|*[!0-9]*) die "config line $LINENO_CFG: history-depth must be a non-negative integer" ;;
      esac
      CFG_DEPTH="$val" ;;
    except)
      IFS='|' read -r e_id e_scope e_re e_just e_exp <<EOF
$val
EOF
      e_id="$(trim "${e_id:-}")"
      e_scope="$(trim "${e_scope:-}")"
      e_re="$(trim "${e_re:-}")"
      e_just="$(trim "${e_just:-}")"
      e_exp="$(trim "${e_exp:-}")"
      case "$e_id" in
        '') die "config line $LINENO_CFG: except needs an id" ;;
        *[!A-Za-z0-9._-]*) die "config line $LINENO_CFG: except id '$e_id' must be [A-Za-z0-9._-]" ;;
      esac
      case "$e_scope" in
        files|history|all) : ;;
        *) die "config line $LINENO_CFG: except scope must be files, history, or all (got '$e_scope')" ;;
      esac
      [ -n "$e_re" ] || die "config line $LINENO_CFG: except '$e_id' has an empty regex (would suppress everything)"
      if [ "${#e_just}" -lt 12 ]; then
        die "config line $LINENO_CFG: except '$e_id' needs a real justification, not '$e_just'.
       An exception without a reason is a silent skip with extra steps."
      fi
      if [ -n "$e_exp" ]; then
        case "$e_exp" in
          [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
          *) die "config line $LINENO_CFG: except '$e_id' expiry must be YYYY-MM-DD (got '$e_exp')" ;;
        esac
        today="$(date +%Y-%m-%d)"
        if [ "$e_exp" \< "$today" ]; then
          die "except '$e_id' expired on $e_exp (today is $today).
       Renew it with a fresh review or delete it. Expired exceptions are not
       warnings: an unreviewed suppression is how a real finding gets through."
        fi
      fi
      printf '%s|%s|%s|%s|%s\n' "$e_id" "$e_scope" "$e_re" "$e_just" "$e_exp" >>"$EXCEPTIONS" ;;
    *)
      die "config line $LINENO_CFG: unknown directive '$key'" ;;
  esac
done <"$CONFIG_ABS"

[ -n "$HISTORY_DEPTH" ] || HISTORY_DEPTH="$CFG_DEPTH"
case "$HISTORY_DEPTH" in ''|*[!0-9]*) die "--history-depth must be a non-negative integer" ;; esac

N_HARD="$(awk 'END{print NR+0}' "$HARD_RE")"
N_NAME="$(awk 'END{print NR+0}' "$NAME_RE")"
if [ "$N_HARD" -eq 0 ] && [ "$N_NAME" -eq 0 ]; then
  die "config '$CONFIG_ABS' declares no 'hard' and no 'name' patterns.
       A sweep with no patterns always passes. Refusing to run."
fi

# --------------------------------------------------------------------------
# file list
# --------------------------------------------------------------------------
cd "$REPO_ABS" || die "cannot enter $REPO_ABS"

IS_GIT=0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 && IS_GIT=1

CONFIG_REL=""
case "$CONFIG_ABS" in
  "$REPO_ABS"/*) CONFIG_REL="${CONFIG_ABS#"$REPO_ABS"/}" ;;
esac

HAS_COMMITS=0
if [ "$IS_GIT" -eq 1 ] && git rev-parse --verify -q HEAD >/dev/null 2>&1; then
  HAS_COMMITS=1
fi

EFFECTIVE_MODE="$MODE"
MODE_NOTE=""
if [ "$IS_GIT" -eq 0 ]; then
  if [ "$MODE" != "all" ]; then
    MODE_NOTE="not a git work tree — falling back to a full-tree scan"
    EFFECTIVE_MODE="all"
  fi
  DO_HISTORY=0
elif [ "$MODE" = "changed" ] && [ "$HAS_COMMITS" -eq 0 ]; then
  MODE_NOTE="no commits yet — falling back to a full-tree scan"
  EFFECTIVE_MODE="all"
fi

RAW_LIST="$WORK/raw.list"
: >"$RAW_LIST"
case "$EFFECTIVE_MODE" in
  all)
    if [ "$IS_GIT" -eq 1 ]; then
      { git ls-files -z; git ls-files -z --others --exclude-standard; } >"$RAW_LIST" 2>/dev/null
    else
      find . -type f -print0 >"$RAW_LIST" 2>/dev/null
    fi ;;
  changed)
    { git diff --name-only -z --diff-filter=ACMR HEAD --
      git ls-files -z --others --exclude-standard; } >"$RAW_LIST" 2>/dev/null ;;
  base)
    git rev-parse --verify -q "$BASE_REF" >/dev/null 2>&1 || die "base ref not found: $BASE_REF"
    { git diff --name-only -z --diff-filter=ACMR "$BASE_REF" --
      git ls-files -z --others --exclude-standard; } >"$RAW_LIST" 2>/dev/null ;;
esac

matches_any_glob() { # $1 = path, $2 = glob file
  [ -s "$2" ] || return 1
  local g
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    # shellcheck disable=SC2254  # intentional: config supplies the glob
    case "$1" in $g) return 0 ;; esac
  done <"$2"
  return 1
}

FILE_LIST="$WORK/files.z"
: >"$FILE_LIST"
FILE_COUNT=0
SEEN="$WORK/seen"
: >"$SEEN"
while IFS= read -r -d '' f; do
  f="${f#./}"
  [ -n "$f" ] || continue
  case "$f" in .git/*|*/.git/*) continue ;; esac
  [ -n "$CONFIG_REL" ] && [ "$f" = "$CONFIG_REL" ] && continue
  [ -f "$f" ] || continue           # deleted / renamed-away paths
  grep -Fxq -- "$f" "$SEEN" 2>/dev/null && continue
  printf '%s\n' "$f" >>"$SEEN"
  if [ -s "$INC_GLOB" ] && ! matches_any_glob "$f" "$INC_GLOB"; then continue; fi
  if matches_any_glob "$f" "$EXC_GLOB"; then continue; fi
  printf '%s\0' "$f" >>"$FILE_LIST"
  FILE_COUNT=$((FILE_COUNT + 1))
done <"$RAW_LIST"

# --------------------------------------------------------------------------
# exception application (auditable, not silent)
# --------------------------------------------------------------------------
EXC_HITS="$WORK/exc_hits"     # id -> total suppressed, accumulated
: >"$EXC_HITS"

apply_exceptions() { # $1 = hits file (modified in place), $2 = scope
  [ -s "$EXCEPTIONS" ] || return 0
  local id scope re just exp n
  while IFS='|' read -r id scope re just exp; do
    [ -n "$id" ] || continue
    if [ "$scope" != "$2" ] && [ "$scope" != "all" ]; then continue; fi
    n="$(grep -c -E -- "$re" "$1" 2>/dev/null)" || n=0
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    if [ "$n" -gt 0 ]; then
      grep -v -E -- "$re" "$1" >"$1.tmp" 2>/dev/null
      mv "$1.tmp" "$1"
    fi
    printf '%s %s\n' "$id" "$n" >>"$EXC_HITS"
  done <"$EXCEPTIONS"
}

say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }

FOUND=0
PASSES_RUN=""

report_pass() { # $1 = label, $2 = hits file
  local n
  n="$(awk 'END{print NR+0}' "$2")"
  if [ "$n" -gt 0 ]; then
    cat "$2"
    FOUND=1
  else
    say "  clean"
  fi
}

# --------------------------------------------------------------------------
# pass 1 + 2: files
# --------------------------------------------------------------------------
say "== rule0 sweep =="
say "  repo:    $REPO_ABS"
say "  config:  $CONFIG_ABS"
say "  patterns: $N_HARD hard, $N_NAME name"
say "  mode:    $EFFECTIVE_MODE${MODE_NOTE:+  ($MODE_NOTE)}"
say "  files:   $FILE_COUNT"
say ""

if [ "$FILE_COUNT" -eq 0 ]; then
  say "== pass 1+2: files =="
  if [ "$EFFECTIVE_MODE" = "changed" ] || [ "$EFFECTIVE_MODE" = "base" ]; then
    say "  NO FILES SCANNED — nothing changed in this diff."
    say "  This is NOT a clean bill of health for the tree. Run with --all"
    say "  before a first publication or after a history rewrite."
  else
    say "  NO FILES SCANNED — the include/exclude globs matched nothing."
    say "  Check the config; an empty file list always 'passes'."
  fi
  say ""
else
  FILE_HITS="$WORK/file.hits"
  : >"$FILE_HITS"

  if [ "$N_HARD" -gt 0 ]; then
    say "== pass 1: hard identifiers (case-insensitive, substring) =="
    xargs -0 grep -n -H -i -E -f "$HARD_RE" -- <"$FILE_LIST" >"$WORK/p1" 2>/dev/null
    apply_exceptions "$WORK/p1" files
    report_pass "pass1" "$WORK/p1"
    cat "$WORK/p1" >>"$FILE_HITS"
    say ""
  fi

  if [ "$N_NAME" -gt 0 ]; then
    say "== pass 2: names (case-SENSITIVE, whole-word) =="
    say "  # case-sensitive + whole-word so shell builtins and git ref names do"
    say "  # not fire on codenames spelled in caps. See the header."
    xargs -0 grep -n -H -w -E -f "$NAME_RE" -- <"$FILE_LIST" >"$WORK/p2" 2>/dev/null
    apply_exceptions "$WORK/p2" files
    report_pass "pass2" "$WORK/p2"
    say ""
  fi
  PASSES_RUN="$PASSES_RUN files"
fi

# --------------------------------------------------------------------------
# pass 3: git history
# --------------------------------------------------------------------------
if [ "$DO_HISTORY" -eq 1 ] && [ "$IS_GIT" -eq 1 ] && [ "$HAS_COMMITS" -eq 1 ]; then
  if [ "$HISTORY_DEPTH" -eq 0 ]; then
    say "== pass 3: git history (all commits) =="
    git log -p --no-color 2>/dev/null >"$WORK/hist"
  else
    say "== pass 3: git history (last $HISTORY_DEPTH commits) =="
    git log -n "$HISTORY_DEPTH" -p --no-color 2>/dev/null >"$WORK/hist"
  fi

  : >"$WORK/p3"
  if [ "$N_HARD" -gt 0 ]; then
    grep -n -i -E -f "$HARD_RE" "$WORK/hist" 2>/dev/null | sed 's|^|history:|' >>"$WORK/p3"
  fi
  if [ "$N_NAME" -gt 0 ]; then
    grep -n -w -E -f "$NAME_RE" "$WORK/hist" 2>/dev/null | sed 's|^|history:|' >>"$WORK/p3"
  fi
  apply_exceptions "$WORK/p3" history

  if [ -s "$WORK/p3" ]; then
    head -40 "$WORK/p3"
    say "  ^^ FOUND IN HISTORY — a cleanup commit does not remove this."
    say "     Rewriting published history changes every SHA; decide deliberately."
    FOUND=1
  else
    say "  clean"
  fi
  PASSES_RUN="$PASSES_RUN history"
  say ""
elif [ "$DO_HISTORY" -eq 1 ]; then
  say "== pass 3: git history =="
  say "  SKIPPED — no git history available here."
  say ""
fi

# --------------------------------------------------------------------------
# exception audit
# --------------------------------------------------------------------------
STALE=0
if [ -s "$EXCEPTIONS" ]; then
  say "== declared exceptions (every run reports these) =="
  while IFS='|' read -r id scope re just exp; do
    [ -n "$id" ] || continue
    total="$(awk -v k="$id" '$1==k {s+=$2} END{print s+0}' "$EXC_HITS")"
    evaluated=0
    case " $PASSES_RUN " in
      *" $scope "*) evaluated=1 ;;
    esac
    [ "$scope" = "all" ] && [ -n "$PASSES_RUN" ] && evaluated=1
    say "  [$id] scope=$scope suppressed=$total${exp:+ expires=$exp}"
    say "      reason: $just"
    if [ "$evaluated" -eq 1 ] && [ "$total" -eq 0 ]; then
      say "      STALE: suppressed nothing this run. If the finding is gone,"
      say "             delete this exception — it is now pre-authorising a"
      say "             future leak that nobody will notice."
      STALE=1
    elif [ "$evaluated" -eq 0 ]; then
      say "      not evaluated (its pass did not run)"
    fi
  done <"$EXCEPTIONS"
  say ""
fi

# --------------------------------------------------------------------------
# verdict
# --------------------------------------------------------------------------
if [ "$FOUND" -ne 0 ]; then
  printf 'SWEEP FAILED — review every hit before publishing.\n'
  printf 'Some hits are legitimate (a lineage link, a genericised phrase). This is\n'
  printf 'a judgement gate, not a lint rule: a human decides, and a decision that\n'
  printf 'recurs becomes a declared exception with a reason, not a quiet edit.\n'
  exit "$EXIT_FINDINGS"
fi

if [ "$STALE" -eq 1 ] && [ "$STRICT" -eq 1 ]; then
  printf 'SWEEP FAILED (--strict) — stale exception(s) above suppressed nothing.\n'
  exit "$EXIT_FINDINGS"
fi

printf 'SWEEP CLEAN — file and history patterns found nothing.\n'
printf 'This does NOT cover issue bodies, PR bodies, review comments, release\n'
printf 'notes, CI logs, or uploaded artifacts. Complete the human checklist.\n'
exit "$EXIT_CLEAN"
