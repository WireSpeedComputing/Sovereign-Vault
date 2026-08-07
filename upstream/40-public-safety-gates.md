# Draft comment for upstream sovereign-memory-core#40

**Status: DRAFT. Not posted.** Review before posting. Confirm nothing below
names a real identifier, and confirm the "not yet done" section is still
accurate at the time of posting.

---

We implemented #40 downstream and would like to offer the tooling back. Two
things here: what we built, and one design decision we got wrong the first time
that we think belongs in the doctrine rather than in our repo alone.

## What we built

**A pattern-driven file and history sweep.** Bash, grep, git — no dependencies,
no network, no writes to the scanned repo. It scans changed files by default
(`--changed`), supports `--base REF` for a PR branch in CI, `--all` for a
pre-publication audit, and runs a git-history pass in every mode.

The design constraint that shaped everything: **a leak checker has to name the
things it looks for, so a checker that lives inside the repository it protects
is itself the leak.** Our first version solved that by keeping the whole script
in a private sibling repo, which made it unshareable and unreviewable — the
opposite of what this repo is for.

The version we are offering is the mechanism only. Every identifier lives in an
external config file that stays private. With no config the script **refuses to
run and exits 2**, rather than reporting "clean". There is deliberately no
built-in fallback pattern list, because a checker that can only succeed is not a
checker.

**A positive-control test suite.** Every case is paired: something the sweep
must catch, and something structurally similar it must not. It plants fake
secrets in a `mktemp -d` fixture and asserts the sweep fails, then asserts it
passes on a clean fixture containing the same adversarial noise. It also asserts
the sweep refuses to run without patterns, that a deliberately broken sweep
never prints the clean verdict, and that a cleanup commit does not hide a leak
from the history pass. 46 assertions, no fixed ports or paths, safe to run
concurrently.

We mutation-tested the suite rather than trusting a green run: twelve deliberate
breakages of the sweep (dropping the word-boundary flag, making the
case-sensitive pass case-insensitive, disabling scope checking on exceptions,
disabling the history pass, removing the empty-config guard, removing the expiry
check, and others). All twelve were caught. Two survived the first attempt, and
in both cases the mutation itself was faulty rather than the test — which is
worth reporting, because "the mutant survived" and "the mutation did not apply"
look identical in a summary line.

**A human review checklist** for the surfaces a file scanner structurally
cannot read: issue bodies and titles, PR bodies, review comments and inline
suggestions, release notes and tag messages, CI logs, and uploaded artifacts.

## The design decision we got wrong first, and why it belongs in doctrine

Our first sweep used one case-insensitive pattern list for everything: project
refs, people, hostnames, and internal component codenames alike.

Codenames are short, ordinary English words. A case-insensitive substring match
on a codename like `TEST` or `MAIN` fires on the shell builtin in every script
in the tree and on the branch name in every README. The sweep produced screens
of hits on a clean repository.

The fix was not a bigger ignore list. It was splitting the patterns by what kind
of string each one is:

- **hard identifiers** — refs, keys, hostnames, domains, surnames. No innocent
  usage in English or code. Matched **case-insensitively, as substrings**,
  because they leak inside URLs, connection strings, base64 and camelCase.
- **names** — codenames and product names that are also ordinary words. Matched
  **case-sensitively and whole-word**, so ordinary prose and shell keywords do
  not trip them.

The lesson is the point: **a checker that cries wolf gets ignored.** It does not
get fixed, it gets skipped, and then it is worse than no checker, because from
the outside it looks like coverage.

We rediscovered exactly this failure, independently, in a completely unrelated
tool in the same project. A SQL perimeter assertion returned close to two
hundred rows against a real deployment — nearly all of them extension-owned
objects that the schema does not control and could not revoke without breaking
legitimate callers — while returning zero rows on a local replay. It passed in
the only environment where it was cheap to run and was unusable in the one
environment it existed to protect, and the noise is precisely why nobody noticed
for months.

Two tools, different languages, different authors, same bug: **the check was
tuned for recall and never for actionability.** We would suggest #40's
requirements say so explicitly — a public-safety check that produces
unactionable output has not met the requirement, however complete its coverage.

## Exceptions are declared records, not `grep -v`

Real sweeps accumulate accepted findings. Ours has one: pre-existing author
metadata in already-published commits, where rewriting history would change
every commit SHA — including those cited from public documents — to suppress a
fact that is public anyway.

The tempting implementation is a `| grep -v` bolted onto the pipeline. That is a
silent skip. It carries no reason, no owner and no expiry, it keeps suppressing
after the finding is gone, and six months later it is indistinguishable from a
bug.

In the version offered here an exception is a declared record:
`id | scope | regex | justification | expires`. Scope is `files`, `history` or
`all`, so a history-scoped exception cannot swallow a file finding. The
justification is mandatory and validated. Every run prints every exception and
exactly how many lines it suppressed. An exception that suppressed nothing is
reported as **stale** — and fails under `--strict` — so it can be deleted rather
than left quietly pre-authorising a future leak. An expired exception halts the
run as a config error.

This mirrors what the same project concluded on the SQL side, where deliberate
perimeter exposures were moved out of a function body into a declared exception
table with a reason column, plus a review function reporting whether each
declared exception is still present. Same shape, different language, and for the
same reason: a suppression you cannot audit is a leak you have agreed in advance
not to see.

## Against #40's acceptance criteria

| criterion | state |
|---|---|
| File scanning implemented and documented | done — sweep script plus checklist doc |
| Synthetic regression cases fail for the intended reason | done — paired positive/negative controls, and the exit-2 cases assert the specific error text so an unrelated crash cannot pass them |
| Existing public-safe fixtures pass | done — the clean fixture is deliberately stuffed with the lowercase forms of the codenames |
| No private evidence copied into the implementation | done by construction — the tool contains no patterns; the example config is entirely fabricated |
| Tracker text, releases, logs, artifacts covered by guidance | done — human checklist |
| Issue and PR templates include the checklist | **not yet done** in our repo |

Two limitations we would rather state than let a green run imply:

1. **A `--changed` run on an unchanged tree scans zero files.** The script says
   so explicitly instead of printing "clean", because 0 files scanned and 0
   findings are different statements — but it is a real gap in any CI that only
   ever runs in changed mode.
2. **The history pass is depth-limited.** A leak older than the configured depth
   is invisible unless `history-depth 0` is set.

## Offer

The tool, its example config, the test suite and the checklist are drop-in and
carry nothing project-specific:

- `contrib/rule0-sweep.generic.sh`
- `contrib/rule0-sweep.config.example` (every value fabricated)
- `contrib/rule0-sweep.test.sh`
- `docs/06-public-safety-checklist.md`

Happy to open a PR against this repo if the shape is useful, or to adapt the
config format if you would rather it were declarative in a different way. The
one thing we would ask to keep whichever direction it goes is the two-pass
split and the reason for it, since the single-list version is the obvious
implementation and it is the one that fails.
