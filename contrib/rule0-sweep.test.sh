#!/usr/bin/env bash
#
# rule0-sweep.test.sh — discrimination proof for rule0-sweep.generic.sh.
#
# A checker that has only ever printed "clean" proves nothing. Every case below
# is paired: something the sweep MUST catch, and something structurally similar
# that it MUST NOT catch. If only the first half existed, a `grep .` would pass
# this suite; if only the second half existed, `exit 0` would.
#
# Self-contained and safe to run concurrently: everything happens inside a
# single mktemp -d, no fixed ports, no fixed paths, no writes outside it, no
# network, and the repository this file lives in is never touched.
#
#   bash contrib/rule0-sweep.test.sh
#
# Exit 0 = all assertions held. Exit 1 = at least one failed (output printed).
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWEEP="$SCRIPT_DIR/rule0-sweep.generic.sh"
[ -f "$SWEEP" ] || { echo "cannot find $SWEEP" >&2; exit 1; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rule0test.XXXXXX")" || exit 1
trap 'rm -rf "$ROOT"' EXIT INT TERM

PASSED=0
FAILED=0
CURRENT=""
OUT=""
RC=0

section() { printf '\n--- %s\n' "$1"; CURRENT="$1"; }
ok()  { PASSED=$((PASSED + 1)); printf '  ok   %s\n' "$1"; }
bad() {
  FAILED=$((FAILED + 1))
  printf '  FAIL %s\n' "$1"
  printf '       ---- sweep output ----\n'
  printf '%s\n' "$OUT" | sed 's/^/       /'
  printf '       ---- exit %s ----\n' "$RC"
}

sweep() { OUT="$(bash "$SWEEP" "$@" 2>&1)"; RC=$?; }

expect_rc() { # expected, label
  if [ "$RC" -eq "$1" ]; then ok "$2 (exit $RC)"; else bad "$2 — expected exit $1, got $RC"; fi
}
expect_has() { # needle, label
  case "$OUT" in *"$1"*) ok "$2" ;; *) bad "$2 — expected output to contain: $1" ;; esac
}
expect_lacks() { # needle, label
  case "$OUT" in *"$1"*) bad "$2 — output should NOT contain: $1" ;; *) ok "$2" ;; esac
}

g() { git -c user.name='Sweep Test' -c user.email='sweep@example.invalid' \
          -c commit.gpgsign=false -c init.defaultBranch=trunk "$@"; }

# ===========================================================================
# fixtures
# ===========================================================================

# The pattern config. Deliberately placed OUTSIDE every scanned tree, which is
# how a real deployment uses it: public tool, private patterns.
cat >"$ROOT/sweep.config" <<'CFG'
# hard identifiers: case-insensitive substring
hard  zzzzzzzzzzzzzzzzzzzz
hard  testperson
hard  testhost\.internal

# names: case-sensitive whole-word. These two are chosen to collide with a
# shell builtin and a git branch name when matched sloppily.
name  PRINTF
name  MAIN
CFG

# --- clean fixture -------------------------------------------------------
# Structurally adversarial: stuffed with the lowercase forms of the codenames.
# Under the original single-list case-insensitive design this tree produced a
# hit on nearly every line. It must now produce zero.
mkdir -p "$ROOT/clean"
cat >"$ROOT/clean/build.sh" <<'EOS'
#!/usr/bin/env bash
# ordinary script: the words below must never trip the sweep
for main in one two three; do
  printf 'building %s\n' "$main"
done
printf 'done\n'
git push origin trunk
EOS
cat >"$ROOT/clean/README.md" <<'EOD'
# Example project

Check out the main branch and run `build.sh`. Output uses printf-style
formatting. This project has seen MAINSTREAM adoption and the PRINTFOO helper
is unrelated to anything internal.

Contact: nobody. Host: localhost.
EOD
cat >"$ROOT/clean/notes.txt" <<'EOD'
Twenty z's would be a project ref, but zzzz is only four.
EOD

# --- dirty fixture -------------------------------------------------------
# Real leaks, one per category, each in a different file so the assertions can
# tell which pass caught what. It also contains the SAME noisy shell script as
# the clean fixture, so a failure here can be attributed precisely.
mkdir -p "$ROOT/dirty"
cp "$ROOT/clean/build.sh" "$ROOT/dirty/build.sh"
printf 'project_ref: ZZZZZZZZZZZZZZZZZZZZ\n' >"$ROOT/dirty/config.yml"
printf 'ssh admin@testhost.internal\n'          >"$ROOT/dirty/deploy.md"
printf 'Ask TestPerson for access.\n'     >"$ROOT/dirty/team.md"
printf 'The PRINTF service talks to MAIN.\n' >"$ROOT/dirty/arch.md"

# ===========================================================================
section "positive control: the sweep FAILS on planted secrets"
# ===========================================================================
sweep --config "$ROOT/sweep.config" --all "$ROOT/dirty"
expect_rc 1 "dirty tree fails"
expect_has "SWEEP FAILED" "verdict says failed"
expect_has "config.yml"  "hard pattern is case-insensitive (ZZZZ... matched lowercase pattern)"
expect_has "deploy.md"   "hostname caught"
expect_has "team.md"     "person name caught in mixed case"
expect_has "arch.md"     "codenames caught when spelled as codenames"
expect_lacks "build.sh"  "the noisy shell script is NOT among the hits"

# ===========================================================================
section "negative control: the sweep PASSES on a clean tree"
# ===========================================================================
sweep --config "$ROOT/sweep.config" --all "$ROOT/clean"
expect_rc 0 "clean tree passes"
expect_has "SWEEP CLEAN" "verdict says clean"
expect_lacks "build.sh"   "lowercase printf/main/origin do not fire (the whole design note)"
expect_lacks "README.md"  "MAINSTREAM and PRINTFOO do not fire (whole-word matching)"

# ===========================================================================
section "the checker cannot trivially succeed"
# ===========================================================================
sweep --all "$ROOT/dirty"
expect_rc 2 "no config is an error, not a pass"
expect_has "no pattern config" "explains why it refused"

printf '# only comments\n\ninclude *.md\n' >"$ROOT/empty.config"
sweep --config "$ROOT/empty.config" --all "$ROOT/dirty"
expect_rc 2 "a config with no patterns is an error, not a pass"
expect_has "no 'hard' and no 'name' patterns" "explains why it refused"

printf 'hard\n' >"$ROOT/bad1.config"
sweep --config "$ROOT/bad1.config" --all "$ROOT/dirty"
expect_rc 2 "empty pattern value rejected (would match every line)"
expect_has "'hard' with empty pattern" "rejected for the intended reason"

printf 'wat  something\n' >"$ROOT/bad2.config"
sweep --config "$ROOT/bad2.config" --all "$ROOT/dirty"
expect_rc 2 "unknown directive rejected rather than ignored"
expect_has "unknown directive 'wat'" "rejected for the intended reason"

# ===========================================================================
section "the config file is never scanned as part of the tree"
# ===========================================================================
# A config sitting inside the repo would otherwise match all of its own
# patterns and report a leak that is not there.
cp "$ROOT/sweep.config" "$ROOT/clean/in-tree.config"
sweep --config "$ROOT/clean/in-tree.config" --all "$ROOT/clean"
expect_rc 0 "in-tree config does not match itself"
rm -f "$ROOT/clean/in-tree.config"

# ===========================================================================
section "git history: a cleanup commit does not remove a leak"
# ===========================================================================
mkdir -p "$ROOT/repo1"
(
  cd "$ROOT/repo1" || exit 1
  g init -q . >/dev/null 2>&1
  printf 'nothing to see\n' >notes.md
  g add -A >/dev/null 2>&1; g commit -q -m "first" >/dev/null 2>&1
  printf 'ssh admin@testhost.internal\n' >host.md
  g add -A >/dev/null 2>&1; g commit -q -m "second" >/dev/null 2>&1
  g rm -q host.md >/dev/null 2>&1
  g commit -q -m "third" >/dev/null 2>&1
) || { echo "git fixture setup failed" >&2; exit 1; }

sweep --config "$ROOT/sweep.config" --all --no-history "$ROOT/repo1"
expect_rc 0 "working tree alone looks clean after the cleanup commit"

sweep --config "$ROOT/sweep.config" --all "$ROOT/repo1"
expect_rc 1 "history pass catches what the cleanup commit hid"
expect_has "FOUND IN HISTORY" "says where the finding is"

# ===========================================================================
section "changed-files mode does not silently pass a dirty tree"
# ===========================================================================
sweep --config "$ROOT/sweep.config" --changed --no-history "$ROOT/repo1"
expect_rc 0 "nothing changed, so the file passes find nothing"
expect_has "NOT a clean bill of health" "says out loud that 0 files scanned != clean"

sweep --config "$ROOT/sweep.config" --changed "$ROOT/repo1"
expect_rc 1 "changed-mode still fails on the historical leak"

# ===========================================================================
section "--base REF scans what a PR would add"
# ===========================================================================
mkdir -p "$ROOT/repo2"
BASE=""
(
  cd "$ROOT/repo2" || exit 1
  g init -q . >/dev/null 2>&1
  printf 'nothing to see\n' >notes.md
  g add -A >/dev/null 2>&1; g commit -q -m "base" >/dev/null 2>&1
  printf 'ssh admin@testhost.internal\n' >added.md
  g add -A >/dev/null 2>&1; g commit -q -m "branch work" >/dev/null 2>&1
) || { echo "git fixture setup failed" >&2; exit 1; }
BASE="$( (cd "$ROOT/repo2" && git rev-parse HEAD~1) 2>/dev/null )"

sweep --config "$ROOT/sweep.config" --base "$BASE" --no-history "$ROOT/repo2"
expect_rc 1 "file added since the base ref is caught"
expect_has "added.md" "names the added file"

sweep --config "$ROOT/sweep.config" --base HEAD --no-history "$ROOT/repo2"
expect_rc 0 "nothing added since HEAD"

# ===========================================================================
section "exceptions are auditable, scoped, and cannot swallow new findings"
# ===========================================================================
cat >"$ROOT/exc.config" <<'CFG'
hard  zzzzzzzzzzzzzzzzzzzz
hard  testperson
hard  testhost\.internal
name  PRINTF
name  MAIN
except  legacy-host | history | ^history:[0-9]+:[-+]ssh admin@testhost\.internal$ | Published commits only. Rewriting history would change every SHA cited elsewhere for a host that no longer exists. Owner decision, dated. | 2099-01-01
CFG

sweep --config "$ROOT/exc.config" --all "$ROOT/repo1"
expect_rc 0 "declared exception clears the accepted history finding"
expect_has "[legacy-host] scope=history suppressed=2" "reports exactly what it suppressed"
expect_has "reason:" "prints the justification on every run"

# the same exception must not cover a DIFFERENT leak in history
(
  cd "$ROOT/repo1" || exit 1
  printf 'Ask TestPerson for access.\n' >people.md
  g add -A >/dev/null 2>&1; g commit -q -m "fourth" >/dev/null 2>&1
  g rm -q people.md >/dev/null 2>&1
  g commit -q -m "fifth" >/dev/null 2>&1
) || exit 1
sweep --config "$ROOT/exc.config" --all "$ROOT/repo1"
expect_rc 1 "a NEW history leak still fails while the exception is in force"
expect_has "suppressed=2" "the old exception is still applied, not disabled"

# scope: a files-scoped exception must not cover a history finding
cat >"$ROOT/scope.config" <<'CFG'
hard  testhost\.internal
except  wrong-scope | files | ssh admin@testhost\.internal | Scoped to files on purpose so the test can prove scope is honoured and not ignored. | 2099-01-01
CFG
sweep --config "$ROOT/scope.config" --all "$ROOT/repo1"
expect_rc 1 "files-scoped exception does not suppress a history finding"

# ===========================================================================
section "stale and expired exceptions are surfaced, not silently honoured"
# ===========================================================================
cat >"$ROOT/stale.config" <<'CFG'
hard  testhost\.internal
except  never-fires | files | this-string-appears-nowhere-at-all | Deliberately matches nothing so the suite can prove a stale exception is reported rather than quietly carried forever. | 2099-01-01
CFG
sweep --config "$ROOT/stale.config" --all "$ROOT/clean"
expect_rc 0 "stale exception is a warning by default"
expect_has "STALE" "stale exception is reported"

sweep --config "$ROOT/stale.config" --all --strict "$ROOT/clean"
expect_rc 1 "--strict turns a stale exception into a failure"

cat >"$ROOT/expired.config" <<'CFG'
hard  testhost\.internal
except  long-gone | files | ssh admin | Expired on purpose so the suite can prove an unreviewed suppression stops the run instead of quietly continuing. | 2020-01-01
CFG
sweep --config "$ROOT/expired.config" --all "$ROOT/dirty"
expect_rc 2 "expired exception halts the run"
expect_has "expired on 2020-01-01" "says which exception and when"

cat >"$ROOT/nojust.config" <<'CFG'
hard  testhost\.internal
except  lazy | files | ssh admin | tmp
CFG
sweep --config "$ROOT/nojust.config" --all "$ROOT/dirty"
expect_rc 2 "an exception without a real justification is rejected"
expect_has "needs a real justification" "rejected for the intended reason"

cat >"$ROOT/emptyre.config" <<'CFG'
hard  testhost\.internal
except  wildcard | files |  | This would suppress every finding in the files pass and must be rejected outright.
CFG
sweep --config "$ROOT/emptyre.config" --all "$ROOT/dirty"
expect_rc 2 "an exception with an empty regex is rejected (it would suppress everything)"
expect_has "empty regex" "rejected for the intended reason"

# The suite must also prove it is not itself broken: an artificial break in the
# sweep script must NOT be reported as a pass anywhere. (This is the check that
# caught a heredoc syntax error masquerading as three passing exit-2 cases.)
sed 's/^set -uo pipefail$/set -uo pipefail; ((( SYNTAX ERROR/' "$SWEEP" >"$ROOT/broken.sh"
OUT="$(bash "$ROOT/broken.sh" --config "$ROOT/sweep.config" --all "$ROOT/clean" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ]; then ok "a broken sweep never reports clean (exit $RC)"; else bad "a broken sweep reported success"; fi
expect_lacks "SWEEP CLEAN" "a broken sweep does not print the clean verdict"

# ===========================================================================
printf '\n=========================================\n'
printf 'passed: %s   failed: %s\n' "$PASSED" "$FAILED"
if [ "$FAILED" -ne 0 ]; then
  printf 'TEST SUITE FAILED\n'
  exit 1
fi
printf 'TEST SUITE PASSED\n'
printf 'Proven: the sweep fails on planted secrets, passes on a structurally\n'
printf 'similar clean tree, refuses to run without patterns, sees through a\n'
printf 'cleanup commit, honours exception scope, and reports its own\n'
printf 'suppressions. Not proven: anything about non-file surfaces.\n'
exit 0
