<!--
  Everything you type below is published, including this PR's title.
  The repository sweep does not read PR bodies, review comments, or inline
  suggestions. This checklist is the only gate on them.
  Full version: .github/PUBLIC-SAFETY.md  ·  Authority: docs/06-public-safety-checklist.md
-->

## What this changes

<!-- Portable description. "The schema supports X", not "our instance is at X". -->

## Why

<!-- Link the upstream issue if there is one. -->

---

## Public safety (required — see `docs/06-public-safety-checklist.md`)

**Automated half** — the sweep reads the tree and git history only:

- [ ] `contrib/rule0-sweep.generic.sh --config <private> --all --history-depth 0 --ci .`
      exits 0. Exit 2 is a failure, not a pass.
- [ ] If I changed the sweep or its config: `contrib/rule0-sweep.test.sh` passes,
      and I confirmed it still *fails* on planted input rather than only printing
      "clean".
- [ ] Any new declared exception has an id, a scope, a real justification and an
      expiry. I did not add one just to make this run go green.

**Human half** — the sweep is structurally unable to read any of this:

- [ ] **This PR body and its title** contain no pasted error output, no real row
      counts, no deployment identifiers, and no reconstruction of which control
      is currently unenforced.
- [ ] The PR body does not explain a vulnerability in enough detail to exploit an
      unpatched deployment elsewhere.
- [ ] Review comments will cite synthetic fixture output, never "here is what it
      returned on the real instance".
- [ ] Commit messages on this branch were swept, and the sweep's history depth
      actually covered this branch. (`--history-depth 0` if unsure.)
- [ ] No screenshots, terminal recordings, or archives are attached. If any are,
      they were extracted and swept first.

**Judgement** — answer these rather than ticking them:

1. Does anything here reduce the work required to attack a real deployment?
2. Is every claim portable, or does some of it describe a running system?

## Evidence

<!--
  If this PR adds or changes a check, state how you proved it can FAIL.
  A check that has only ever printed "clean" proves nothing. Paste the
  positive-control output, or name the assertions that cover it.
-->

- [ ] New or changed checks have a positive control: known-bad input produces a
      failure, known-good input produces a pass.

## Risk

- [ ] This touches `sql/` — if so, read `docs/09-apply-runbook-propose-then-promote.md`
      and say explicitly whether it is a public signature change
      (see `docs/08-contract-version-and-drift.md`).
- [ ] This is a migration. It is filed in `pending/` unless it has been approved
      and applied, because `tests/replay_fresh_install.sh` globs `sql/*.sql` and
      filing an unapplied migration there makes the harness prove something
      untrue about the deployment.
