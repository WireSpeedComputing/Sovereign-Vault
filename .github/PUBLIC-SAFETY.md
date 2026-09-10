# Public-safety gate for tracker text

Every template in this directory embeds a short version of this page. This is
the long version, and `docs/06-public-safety-checklist.md` is the authority.

## Why tracker text has its own gate

`contrib/rule0-sweep.generic.sh` scans the working tree and git history. It
cannot read issue bodies, issue *titles*, pull-request bodies, review comments,
inline suggestions, release notes, tag messages, CI logs, or uploaded
artifacts. Every one of those is a publication surface, and none of them is
covered by a green sweep.

That is not a gap to be closed later by a better scanner. Those objects live in
the tracker's database, not the repository, so a repository-side tool is
structurally incapable of reading them. They are covered by review or they are
not covered.

## The failure mode this exists to stop

The leaks that have actually mattered in this project were prose, not secrets:

- a sentence describing which enforcement path is not yet wired
- a status note reconstructing the order in which a deployment was repaired
- an exact count of rows in a private table

None of those contain a hostname, a key, or a surname. No regex will ever flag
them. A green sweep says the mechanical half is clean, which is a weaker claim
than "this is safe to publish" and must be reported as the weaker one.

## Before you post anything

Ask the two questions that no pattern can ask:

1. **Does this reduce the work required to attack a real deployment?** Not "does
   it contain a secret" — does it shorten someone's path. A sentence naming
   which control is currently unenforced does that; a hostname often does not.
2. **Is this a fact about a running system, or a portable claim?** "The schema
   supports X" is portable and belongs here. "Our instance is currently at X" is
   not and does not.

Then the mechanical items:

- [ ] No pasted error output or stack traces. They carry local paths, database
      names, role names, and sometimes connection strings.
- [ ] No row counts, table sizes, or record counts from a real deployment.
- [ ] No description of *which* check is unenforced, in what order the gaps
      stack, or which is easiest to reach. Describing a missing control
      generically is doctrine; describing it as the state of a running system is
      a map.
- [ ] Reproduction steps use synthetic fixtures, never "run this against prod".
- [ ] No screenshots, terminal recordings, or archives. Their bytes are not text
      and were never swept. See `docs/06`, "Uploaded artifacts".
- [ ] The **title** was checked too. Titles are indexed, quoted into
      notifications, and almost never edited afterwards.
- [ ] Exact digests, receipts, and counts are treated as identifiers even when
      they look like statistics.

## Things that are easy to get wrong

- **Force-pushing does not delete review comments.** A comment on a rewritten
  commit survives, orphaned and still public.
- **Inline suggestions are separate objects.** Redacting a value in the diff
  does not touch a suggestion that quotes it.
- **Masked CI secrets are masked by exact value.** A secret's *name* is not
  masked, and neither is a transformed value — base64, or the first eight
  characters.
- **A failing sweep prints paths and line numbers**, which is itself a
  disclosure if the CI log is public. Prefer failing with a count and a pointer,
  and reading the detail locally.
- **Auto-generated release notes concatenate commit subjects**, including the
  ones written at 2am. Read them before publishing.

## Running the sweep

```sh
# before a first publication, or any time you want a real gate
contrib/rule0-sweep.generic.sh \
  --config /private/path/sweep.config \
  --all --history-depth 0 --ci .
```

`--ci` is what makes it a gate rather than a report: it turns "scanned zero
files", "stale exception", and "older commits never read" from warnings into
failures. A `--changed` run on an unchanged tree scans nothing and passes, so a
CI job wired only to that mode is green forever while covering nothing.

Exit 2 is **not** a pass. It means a usage, config, or grep-environment error,
and it must fail the job exactly like exit 1.

The sweep ships with no patterns. With no config it refuses to run rather than
reporting "clean", because a checker that can only succeed is not a checker.
Before trusting a clean result from a config you just edited, run
`contrib/rule0-sweep.test.sh` — it plants known-bad input and asserts the sweep
fails on it.
