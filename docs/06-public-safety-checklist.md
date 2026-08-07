# Public-safety checklist

Upstream `sovereign-memory-core#40` requires two things: an automated check over
changed files, and a mandatory human review of everything the automated check
cannot read. `contrib/rule0-sweep.generic.sh` is the first. This document is the
second, and it is the more important half.

## The one thing to read first

**The file scanner has never once caught the leaks that actually matter here.**
Every real near-miss in this repository has been prose: a sentence describing
which enforcement path is not yet wired, a status note reconstructing the order
in which a deployment was repaired, a count of rows in a private table. None of
those contain a hostname, a key, or a surname. A regex will never flag them.

So do not read the sections below as a formality that follows a green check. The
green check covers the easy half.

## What runs, and what it covers

`contrib/rule0-sweep.generic.sh` scans changed files by default, the full tree
with `--all`, and git history in every mode. Patterns live in an external
private config; the tool itself contains none, which is why it can be published.
`contrib/rule0-sweep.test.sh` is its positive control: it plants fake secrets,
asserts the sweep fails, then asserts it passes on a structurally similar clean
fixture. Run the test suite before trusting a clean result from a config you
have just edited.

Two properties worth knowing before you rely on a green run:

- **A clean `--changed` run on an unchanged tree scans zero files.** The sweep
  says so out loud rather than printing "clean", because 0 files scanned and 0
  findings are not the same statement. Run `--all` before a first publication.
- **The history pass is depth-limited by config.** A leak older than the
  configured depth is invisible. Set `history-depth 0` for a repo that has never
  been swept end to end.

## Surfaces the scanner cannot see

The scanner reads the working tree and git history. Everything below is a
publication surface it never touches. Each one has shipped a leak somewhere, in
some project, for the same reason: it does not feel like publishing.

### Issue bodies

Written fast, usually while the problem is still hot, usually by pasting the
thing that broke.

- [ ] No pasted error output. Stack traces carry local paths, hostnames,
      database names, role names, and sometimes connection strings.
- [ ] No row counts, table sizes, or record counts from a real deployment.
      "About two hundred rows" is a fact about a private system.
- [ ] No reconstruction of *which* check is currently unenforced, in what order
      the gaps stack, or which one is easiest to reach. Describing a missing
      control generically is doctrine; describing it as the state of a running
      system is a map.
- [ ] Reproduction steps use synthetic fixtures, not "run this against prod".
- [ ] No screenshots. See the artifact section.
- [ ] Title as well as body. Titles are indexed, quoted into notifications, and
      almost never edited afterwards.

### Pull-request bodies and review comments

- [ ] The PR body does not explain the vulnerability that the PR closes in
      enough detail to exploit an unpatched deployment elsewhere.
- [ ] Review comments do not paste "here is what it returned on the real
      instance" as justification. Paste the synthetic fixture's output instead.
- [ ] Inline suggestions do not contain a real value that was redacted in the
      diff. Suggestions are separate objects; redacting the file does not touch
      them.
- [ ] Commit messages inside the PR were swept. They are part of history and the
      sweep reads them, but only to the configured depth — confirm the depth
      covered this branch.
- [ ] Force-push does not delete comments. A comment on a rewritten commit
      survives, orphaned and still public.

### Release notes and tags

- [ ] Release notes are written from the changelog, not from the internal status
      document. The status document is where the deployment detail lives.
- [ ] No "fixes the issue we hit on the production instance on <date>" framing.
      Dates plus a described failure mode are a timeline of when a real system
      was exposed.
- [ ] Auto-generated notes were read before publishing. Generated notes
      concatenate commit subjects, including the ones written at 2am.
- [ ] Tag messages (`git tag -m`) were swept. They are objects in the repository
      but are not diffs, so a `git log -p` pass does not see them.

### CI logs and workflow output

- [ ] The workflow does not echo the config file, environment, or secret names.
      Masked secrets are masked by exact value; a name is not masked, and a
      transformed value (base64, first eight characters) is not masked either.
- [ ] The sweep runs in CI with `--config` pointing at a secret-mounted file
      that is never written into the workspace.
- [ ] Log retention is understood: a leak in a log is public until the log is
      purged, and purging a log does not purge a fork's copy of it.
- [ ] A failing sweep in CI prints paths and line numbers — which is itself a
      disclosure if the log is public. Prefer failing with a count and a
      pointer, and reading the detail locally.

### Uploaded artifacts

This is the category that most often defeats a file scanner completely, because
the bytes are not text.

- [ ] Screenshots. Cropping in a viewer often leaves the original in the file's
      metadata, and a browser screenshot carries tab titles, bookmark bars, and
      URL bars.
- [ ] Terminal recordings and asciinema casts contain the full scrollback,
      including the command that set the environment variable.
- [ ] `.zip`, `.tar.gz`, `.sqlite`, `.parquet`, `.pdf`, `.xlsx`, `.png`: the
      sweep reads these as binary or skips them by glob. Their contents were
      never checked. Extract and sweep the extracted directory, or do not attach
      them.
- [ ] Database dumps and "sanitised" exports. Sanitisation that was not tested
      is an assertion, not a fact — the same standard applied to the sweep
      itself applies here: plant a known row, run the sanitiser, confirm the row
      is gone.
- [ ] Diagrams exported from a drawing tool frequently retain layers, comments,
      and the original unredacted shapes under the black boxes.

## The judgement questions no pattern can ask

Run through these once per publication. They are ordered by how often they have
actually mattered.

1. **Does this reduce the work required to attack a real deployment?** Not
   "does it contain a secret" — does it shorten someone's path. A sentence
   naming which control is not yet enforced does that; a hostname often does
   not.
2. **Is this a fact about a running system, or a portable claim?** "The schema
   supports X" is portable. "Our instance is currently at X" is not.
3. **Would this let someone reconstruct the sequence of a real incident?**
   Ordered narratives of what broke, when, and what was tried are internal
   coordination transcripts wearing a technical hat.
4. **Is a count, digest, or receipt exact?** Exact private counts, stable
   digests, and custody receipts are identifiers even when they look like
   statistics.
5. **Is this someone's personal information?** Including yours. A commit author
   line, a calendar reference, a household detail in an aside.
6. **Would I be comfortable if this were quoted back in six months with no
   surrounding context?** Everything here is quotable forever and editable by
   nobody who reads the quote.

## Accepted exceptions

An exception that is not written down is a silent skip. This repository carries
its accepted findings as declared records in the private sweep config: id,
scope, regex, justification, and an optional expiry. Every run prints every
exception and exactly how many lines it suppressed; one that suppressed nothing
is reported as stale so it can be deleted rather than left in place quietly
pre-authorising a future leak.

The same conclusion was reached independently on the SQL side, where deliberate
perimeter exposures were moved out of a function body into a declared exception
table with a reason column plus a review function that reports whether each
declared exception is still present. Two tools, same shape, and for the same
reason: a suppression you cannot audit is a leak you have agreed in advance not
to see.

The standing exception in this repository is pre-existing author metadata in
already-published commits. Rewriting that history would change every commit SHA,
including those cited from public documents, in exchange for suppressing a fact
that is public anyway. It is scoped to the history pass only, so a new history
leak still fails the sweep.

Adding an exception is a decision with an owner and a date. It is not a way to
make a run go green.

## Why this document exists in the form it does

The temptation with a checklist is to make it exhaustive enough that completing
it feels like proof. It is not proof. The sweep is a floor: it catches the
mechanical half, it can fail, and there is a test suite that demonstrates it
failing on planted input and passing on clean input.

Everything above the floor is judgement, and the honest framing is that a green
sweep plus a ticked checklist means *no one found a problem*, which is a weaker
claim than *there is no problem* and should be reported as the weaker one.
