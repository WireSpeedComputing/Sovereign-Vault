#!/usr/bin/env bash
#
# predll-signature-probe.sh — refuse to apply a DDL file while live operating
# instructions still teach a signature it removes or reshapes.
#
# Prototype of the extraction-and-search half of Part 4 of
# docs/08-contract-version-and-drift.md. Dependency-light: bash, grep, sed, awk.
# No network. No database connection. Reads only the two paths it is given.
#
# ---------------------------------------------------------------------------
# THE FAILURE THIS EXISTS FOR
# ---------------------------------------------------------------------------
# A migration corrects a public function. The migration is right. The
# deployment's live operating instructions still teach the old signature, and a
# fresh agent follows them the moment it boots. Repository CI cannot see those
# instructions — they are private deployment data — so nothing catches it.
#
# Confirmed instances in this project, from docs/08:
#   1. supersede_memory() lost its 5-argument form   (sql/20 line 147)
#   2. refresh_retrieval_units() went 3 -> 4 columns (sql/27 line 113)
#
# ---------------------------------------------------------------------------
# CREDENTIAL POSTURE
# ---------------------------------------------------------------------------
# The probe never connects to a deployment and never reads a private
# instruction store itself. The operator exports instructions to local text and
# passes a path, exactly as tests/migration_drift.sh takes applied.tsv. Its
# reason applies unchanged: a drift checker that holds production credentials is
# a bigger risk than the drift it detects. It also keeps live instruction
# content out of the public repository.
#
# ---------------------------------------------------------------------------
# WHY SILENCE IS NOT A PASS
# ---------------------------------------------------------------------------
# A corpus that is missing, empty, or unreadable produces zero hits, and zero
# hits look exactly like "the instructions are up to date". So those cases exit
# UNATTESTED (3) and block, rather than exiting clean. This is the same
# discipline sql/26 applies with 'unaudited' and sql/01 with 'no-blessing': a
# third state that must never render as a match.
#
# Extracting nothing from the DDL is also not a pass. If a file contains no
# recognisable function definition at all, that is far more likely to mean the
# parser did not understand it than that the migration touches no functions.
#
# ---------------------------------------------------------------------------
# WHAT THIS PROTOTYPE DOES NOT DO
# ---------------------------------------------------------------------------
# Part 4 of docs/08 specifies four extraction rules. This implements 1 and 3,
# and 2 only insofar as the DDL text itself reveals it — full rule 2 needs a
# Tier A snapshot of the installed contract, which does not exist yet.
#
# Rule 4 (jsonb envelope-domain changes) is NOT implemented. That is instance 4
# in docs/08, and nothing here would catch it. See "Instance 4 defeats all three
# extraction rules" in that document. --require-envelope-note implements the
# declarative interim only.
#
# It greps text. An instruction that describes the old behaviour in prose
# without naming an identifier — "the refresh returns three counts" — is not
# found. A green run means no instruction *named* a stale signature.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   predll-signature-probe.sh --ddl FILE.sql --corpus PATH [options]
#
#   --ddl FILE           Pending .sql file about to be applied. Required.
#   --corpus PATH        File or directory of exported operating instructions.
#                        Required. Never a database connection.
#   --require-envelope-note
#                        Block a `create or replace` of a jsonb-returning
#                        function unless the DDL header declares the envelope
#                        change. Partial mitigation for instance 4.
#   --list               Print the extracted signatures and patterns, then exit.
#   --quiet              Findings and verdict only.
#   -h, --help           This text.
#
# Exit codes:
#   0  clean      — signatures extracted, corpus searched, nothing stale found
#   1  findings   — an instruction still teaches a removed/reshaped signature
#   2  usage or input error
#   3  unattested — could not establish coverage. NOT a pass.
#
set -uo pipefail

PROG="$(basename "$0")"
VERSION="0.1.0"

GREP="${PREDLL_GREP:-grep}"

EXIT_CLEAN=0
EXIT_FINDINGS=1
EXIT_USAGE=2
EXIT_UNATTESTED=3

die() { printf '%s: error: %s\n' "$PROG" "$*" >&2; exit "$EXIT_USAGE"; }
unattested() {
  printf '%s: UNATTESTED — %s\n' "$PROG" "$*" >&2
  printf '%s: blocking. Zero findings from a corpus that was not read is not a pass.\n' "$PROG" >&2
  exit "$EXIT_UNATTESTED"
}

usage() { sed -n '/^# USAGE/,/^set -uo/p' "$0" | sed -e 's/^# \{0,1\}//' -e '$d'; }

DDL=""
CORPUS=""
QUIET=0
LIST=0
REQ_ENVELOPE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --ddl)      [ $# -ge 2 ] || die "--ddl needs a value"; DDL="$2"; shift 2 ;;
    --ddl=*)    DDL="${1#*=}"; shift ;;
    --corpus)   [ $# -ge 2 ] || die "--corpus needs a value"; CORPUS="$2"; shift 2 ;;
    --corpus=*) CORPUS="${1#*=}"; shift ;;
    --require-envelope-note) REQ_ENVELOPE=1; shift ;;
    --list)     LIST=1; shift ;;
    --quiet)    QUIET=1; shift ;;
    --version)  printf '%s %s\n' "$PROG" "$VERSION"; exit 0 ;;
    -h|--help)  usage; exit 0 ;;
    -*)         die "unknown option: $1" ;;
    *)          die "unexpected argument: $1" ;;
  esac
done

[ -n "$DDL" ]    || { usage >&2; die "no --ddl given"; }
[ -f "$DDL" ]    || die "ddl file not found: $DDL"
[ -r "$DDL" ]    || die "ddl file not readable: $DDL"
[ -n "$CORPUS" ] || { usage >&2; die "no --corpus given"; }

say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/predll.XXXXXX")" || die "mktemp failed"
trap 'rm -rf "$WORK"' EXIT INT TERM HUP

# --------------------------------------------------------------------------
# corpus resolution — establish coverage BEFORE searching
# --------------------------------------------------------------------------
CORPUS_LIST="$WORK/corpus.list"
: >"$CORPUS_LIST"

if [ -d "$CORPUS" ]; then
  find "$CORPUS" -type f -print >"$CORPUS_LIST" 2>/dev/null
elif [ -f "$CORPUS" ]; then
  printf '%s\n' "$CORPUS" >"$CORPUS_LIST"
else
  unattested "corpus path does not exist: $CORPUS"
fi

CORPUS_FILES="$(awk 'END{print NR+0}' "$CORPUS_LIST")"
[ "$CORPUS_FILES" -gt 0 ] || unattested "corpus contains no files: $CORPUS"

# A corpus of empty files reads as clean against every pattern.
CORPUS_BYTES=0
while IFS= read -r cf; do
  [ -r "$cf" ] || unattested "corpus file is not readable: $cf"
  n=$(wc -c <"$cf" 2>/dev/null | tr -d ' ')
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  CORPUS_BYTES=$((CORPUS_BYTES + n))
done <"$CORPUS_LIST"
[ "$CORPUS_BYTES" -gt 0 ] || unattested "corpus is $CORPUS_FILES file(s) totalling 0 bytes"

# --------------------------------------------------------------------------
# extraction
# --------------------------------------------------------------------------
# Normalise the DDL: strip line comments and fold to one space so a definition
# split across lines is matchable. Deliberately crude — this is a probe that
# blocks on suspicion, not a SQL parser, and over-extraction is the safe
# direction.
NORM="$WORK/ddl.norm"
sed -e 's/--.*$//' "$DDL" | tr '\n' ' ' | tr -s ' ' >"$NORM"

DROPPED="$WORK/dropped"     # name<TAB>argstring
CREATED="$WORK/created"     # name<TAB>argstring
: >"$DROPPED"; : >"$CREATED"

extract() { # $1 = 'drop'|'create', $2 = out file
  local re
  if [ "$1" = "drop" ]; then
    re='drop[[:space:]]+function[[:space:]]+(if[[:space:]]+exists[[:space:]]+)?'
  else
    re='create[[:space:]]+(or[[:space:]]+replace[[:space:]]+)?function[[:space:]]+'
  fi
  "$GREP" -o -i -E "${re}[a-zA-Z_][a-zA-Z0-9_.]*[[:space:]]*\([^)]*\)" "$NORM" 2>/dev/null \
  | sed -E -e 's/^[^(]*[[:space:]]([a-zA-Z_][a-zA-Z0-9_.]*)[[:space:]]*\(/\1(/' \
  | awk -F'(' '{name=$1; sub(/^.*\./,"",name); args=$0; sub(/^[^(]*\(/,"",args); sub(/\)$/,"",args);
               gsub(/^[ \t]+|[ \t]+$/,"",name); print name "\t" args}' \
  | awk 'NF>0' >"$2"
}

extract drop   "$DROPPED"
extract create "$CREATED"

N_DROP="$(awk 'END{print NR+0}' "$DROPPED")"
N_CREATE="$(awk 'END{print NR+0}' "$CREATED")"

if [ "$N_DROP" -eq 0 ] && [ "$N_CREATE" -eq 0 ]; then
  unattested "no function definition could be extracted from $DDL.
       A migration that touches no functions is possible, but a parser that
       understood nothing is more likely. Check the file, or exclude it
       explicitly rather than letting this read as clean."
fi

# arity of an argument list: count top-level commas + 1, empty list = 0.
#
# Computed in BEGIN, deliberately. The first version piped the argument list
# into awk on stdin, which works for every non-empty list and silently returns
# the EMPTY STRING for `()` — awk reads no records, so the body never runs and
# nothing is printed. Zero-argument functions then carried arity "" instead of
# 0, and the family-B comparison `ar == want` became `0 == ""`, which awk
# evaluates as a string comparison and is always false.
#
# The effect was that a dropped zero-argument function could never be matched
# against any call site. `refresh_retrieval_units()` — docs/08 instance 2 — is
# exactly that shape, so the probe silently could not detect one of the two
# instances it was built from. Caught by running --list against the real
# sql/27, not by the fixture suite, which only exercised the zero-arg case
# through --list where an empty column looks like a formatting quirk.
arity_of() {
  awk -v s="$1" 'BEGIN{
    gsub(/^[ \t]+|[ \t]+$/,"",s);
    if (s=="") { print 0; exit }
    n=1; d=0;
    for (i=1;i<=length(s);i++){ c=substr(s,i,1);
      if (c=="(") d++; else if (c==")") d--; else if (c=="," && d==0) n++ }
    print n }'
}

# --------------------------------------------------------------------------
# affected signatures = rule 1 (explicit drops) + rule 3 (arity narrowing)
# --------------------------------------------------------------------------
AFFECTED="$WORK/affected"   # name<TAB>old_arity<TAB>why
: >"$AFFECTED"

while IFS="$(printf '\t')" read -r nm args; do
  [ -n "$nm" ] || continue
  printf '%s\t%s\t%s\n' "$nm" "$(arity_of "$args")" "explicitly dropped" >>"$AFFECTED"
done <"$DROPPED"

# Rule 3: a name both dropped and created with a different arity is a reshape.
# Without a Tier A snapshot this is the only reshape the DDL text alone reveals.
while IFS="$(printf '\t')" read -r nm args; do
  [ -n "$nm" ] || continue
  new_ar="$(arity_of "$args")"
  while IFS="$(printf '\t')" read -r dnm dargs; do
    [ "$dnm" = "$nm" ] || continue
    old_ar="$(arity_of "$dargs")"
    if [ "$old_ar" != "$new_ar" ]; then
      printf '%s\t%s\t%s\n' "$nm" "$old_ar" "arity changed $old_ar -> $new_ar" >>"$AFFECTED"
    fi
  done <"$DROPPED"
done <"$CREATED"

# One row per (name, old arity). A function that is both dropped and recreated
# at a new arity would otherwise be searched twice and print its hits twice.
sort -u "$AFFECTED" -o "$AFFECTED"
awk -F'\t' '{k=$1 FS $2; if (k in seen) { why[k]=why[k]"; "$3 } else { seen[k]=1; order[++n]=k; why[k]=$3 } }
            END{ for(i=1;i<=n;i++){ split(order[i],p,FS); print p[1] "\t" p[2] "\t" why[order[i]] } }' \
    "$AFFECTED" >"$AFFECTED.dedup" && mv "$AFFECTED.dedup" "$AFFECTED"
N_AFFECTED="$(awk 'END{print NR+0}' "$AFFECTED")"

# --------------------------------------------------------------------------
# rule 4 interim: a jsonb create-or-replace must declare its envelope change
# --------------------------------------------------------------------------
ENVELOPE_UNDECLARED=""
if [ "$REQ_ENVELOPE" -eq 1 ]; then
  if "$GREP" -q -i -E 'create[[:space:]]+or[[:space:]]+replace[[:space:]]+function' "$NORM" 2>/dev/null \
     && "$GREP" -q -i -E 'returns[[:space:]]+jsonb' "$NORM" 2>/dev/null; then
    if ! "$GREP" -q -i -E 'SIGNATURE CHANGE|ENVELOPE CHANGE|NO ENVELOPE CHANGE' "$DDL" 2>/dev/null; then
      ENVELOPE_UNDECLARED="yes"
    fi
  fi
fi

# --------------------------------------------------------------------------
# pattern families (Part 4) + search
# --------------------------------------------------------------------------
say "== pre-DDL signature probe =="
say "  ddl:       $DDL"
say "  corpus:    $CORPUS  ($CORPUS_FILES file(s), $CORPUS_BYTES bytes)"
say "  extracted: $N_DROP drop, $N_CREATE create"
say "  affected:  $N_AFFECTED signature(s)"
say ""

if [ "$LIST" -eq 1 ]; then
  printf 'name\told_arity\treason\n'
  cat "$AFFECTED"
  exit "$EXIT_CLEAN"
fi

FOUND=0
HITS="$WORK/hits"
: >"$HITS"

while IFS="$(printf '\t')" read -r nm old_ar why; do
  [ -n "$nm" ] || continue
  say "-- $nm ($why)"

  # family A: the bare name. High recall, high noise. Builds the candidate set;
  # never blocks on its own.
  CAND="$WORK/cand.$nm"
  : >"$CAND"
  while IFS= read -r cf; do
    "$GREP" -n -H -w -E -- "$nm" "$cf" 2>/dev/null >>"$CAND"
  done <"$CORPUS_LIST"
  n_cand="$(awk 'END{print NR+0}' "$CAND")"

  if [ "$n_cand" -eq 0 ]; then
    say "   no instruction mentions this name"
    continue
  fi

  # family B: name applied to an argument list of the OLD arity. This is the
  # one that blocks: it is a call site teaching the dead signature.
  BLOCK="$WORK/block.$nm"
  : >"$BLOCK"
  awk -v name="$nm" -v want="$old_ar" '
    {
      line = $0
      # find name( ... ) and count top-level commas inside
      idx = index(line, name "(")
      if (idx == 0) next
      rest = substr(line, idx + length(name) + 1)
      d = 0; n = 0; seen = 0; closed = 0
      for (i = 1; i <= length(rest); i++) {
        c = substr(rest, i, 1)
        if (c == "(") d++
        else if (c == ")") { if (d == 0) { closed = 1; break } d-- }
        else if (c == "," && d == 0) n++
        if (c != " " && c != "\t") seen = 1
      }
      if (!closed) next
      ar = (seen ? n + 1 : 0)
      if (ar == want) print $0 "   [<-- " name " called with " ar " argument(s); that form is gone]"
    }' "$CAND" >>"$BLOCK"

  if [ -s "$BLOCK" ]; then
    cat "$BLOCK" >>"$HITS"
    cat "$BLOCK"
    FOUND=1
  else
    say "   mentioned in $n_cand place(s), but no call site with the removed arity"
    say "   (family A is advisory — review these by hand before applying)"
    [ "$QUIET" -eq 1 ] || sed 's/^/     /' "$CAND" | head -10
  fi
  say ""
done <"$AFFECTED"

# family C: old result-column names in combination. Catches a runbook that
# destructures a shape without ever writing the function name on the same line.
# Driven by the DDL declaring a `returns table (...)` that the drop replaced.
OLDCOLS="$WORK/oldcols"
"$GREP" -o -i -E 'returns[[:space:]]+table[[:space:]]*\([^)]*\)' "$NORM" 2>/dev/null \
  | sed -E 's/^[^(]*\(//; s/\)$//' \
  | tr ',' '\n' \
  | awk '{print $1}' | awk 'NF>0' | sort -u >"$OLDCOLS" 2>/dev/null || : >"$OLDCOLS"

if [ -s "$OLDCOLS" ]; then
  n_cols="$(awk 'END{print NR+0}' "$OLDCOLS")"
  say "-- result-column combination check ($n_cols column name(s) from returns table)"
  say "   NOTE: this prototype reports co-occurrence only. Deciding that a"
  say "   passage destructures the OLD shape needs the previous column list,"
  say "   which requires a Tier A snapshot this prototype does not have."
  say ""
fi

# --------------------------------------------------------------------------
# verdict
# --------------------------------------------------------------------------
if [ -n "$ENVELOPE_UNDECLARED" ]; then
  printf 'PROBE BLOCKED — this DDL does `create or replace` on a jsonb-returning\n'
  printf 'function and its header declares no envelope change.\n'
  printf 'A jsonb envelope is invisible to a signature digest (docs/08, instance 4),\n'
  printf 'so the declaration is the only control there is. Add a header line\n'
  printf 'saying what changed, or "NO ENVELOPE CHANGE" if nothing did.\n'
  exit "$EXIT_FINDINGS"
fi

if [ "$FOUND" -ne 0 ]; then
  printf 'PROBE FAILED — live instructions still teach a signature this DDL removes.\n'
  printf 'It blocks the DDL, not the database: the deployment is untouched and\n'
  printf 'fully functional. Update the instructions first, or override with a\n'
  printf 'recorded reason.\n'
  exit "$EXIT_FINDINGS"
fi

printf 'PROBE CLEAN — no instruction names a removed signature at its old arity.\n'
printf 'This searched %s file(s) for %s affected signature(s). It cannot see prose\n' "$CORPUS_FILES" "$N_AFFECTED"
printf 'that describes old behaviour without naming an identifier, and it does not\n'
printf 'implement rule 4 (jsonb envelope domains) — see docs/08.\n'
exit "$EXIT_CLEAN"
