We implemented #46 downstream. Everything below cites a file in this branch.
**Status: written, replays clean, NOT applied to any deployment.**

Implementation: `sql/26_propose_then_promote.sql`. Tests:
`tests/23_promotion_guards_negative.sql` (31 assertions).

## The finding worth upstreaming, before the conformance table

We probed all five forbidden paths #46 names against a clean PG17 replay of
`sql/00`–`sql/22`. **All five were open, plus three more.** The root cause was
not a broken guard. It was that *no guard ran on the INSERT path at all*:

- `enforce_bounded_status_transition` is `BEFORE UPDATE` only.
- `enforce_agent_cannot_self_attest` constrains only `source_kind='agent'`.

So `promote_memory()` was a **convenience wrapper, not a chokepoint**. Any
caller could `INSERT ... status='current'` directly and never touch it. The
review gate was real, correct, and trivially avoidable by not using it — which
is worse than an absent gate, because the gate's existence is what made everyone
stop looking.

We think that is the generalizable shape: a function that *looks* like the only
door is not a chokepoint until something rejects the paths that go around it.

## The artifact gate must be an ALLOWLIST, and this is not a stylistic preference

`memories.source_artifact_id` was a bare FK, unconstrained with respect to
`raw_artifacts.action`. `hold` / `exclude` / `evidence` artifacts normalized into
memories and promoted cleanly through the sanctioned human gate.

The obvious fix is a denylist on those three classes. **That fix ships looking
correct and leaves the most common case wide open.** `raw_artifacts.action` is
nullable by design — `sql/06` states the principle as "classification is
explicit, never defaulted" — so **`NULL` is the default state of every freshly
landed artifact**, and an unclassified artifact was promotable.

This is a fifth artifact class #46 does not name, and it is the *default* one.
`enforce_artifact_promotable()` is therefore an allowlist on `action='import'`
(`sql/26` Part 2). `tests/23` covers it as `b4_unclassified_artifact_cannot_become_authority`
alongside the hold/exclude/evidence cases, precisely so the null case cannot be
dropped later as an edge case.

It is enforced at INSERT rather than at promotion, because #46's requirement is
that an evidence artifact cannot **normalize into a memory fact at all** — not
merely that it cannot later be promoted. A rejected normalization leaves nothing
behind to promote.

## Conformance against the acceptance criteria

| #46 acceptance criterion | Status |
| --- | --- |
| Each forbidden promotion path has a failing-negative test | Yes — Section B, 13 assertions |
| Approved import path remains possible only through explicit review | Yes — `b8_approved_import_path_still_works` |
| Tests run in validation suite | Yes — `tests/replay_fresh_install.sh` executes every `tests/NN_*.sql` not marked `REQUIRES-DEPLOYMENT` |

## The fix, and two things about it that were not obvious

`status='current'` becomes unreachable by direct INSERT. Everything lands
`proposed`; the `SECURITY DEFINER` functions become the sole path to authority.

**1. It is deliberately not keyed on `source_kind`.** `source_kind` is
caller-declared, so any rule keyed on it is bypassable by assertion — a caller
who wants to skip an agent rule declares `manual`. `tests/23` asserts this
directly with `b6_ingest_cannot_self_confer_authority` and
`b6b_manual_cannot_self_confer_authority`: the same hole reached through two
different self-descriptions.

**2. The column default had to move, or the guard breaks every existing writer.**
`memories.status` defaulted to `'current'` (`sql/01`). An ordinary writer that
never mentions `status` therefore got `'current'` by default and was rejected
with an error naming a value the caller never set. We found this by verification
after writing the trigger, not by design. `sql/26` moves the default to
`'proposed'`, which is the doctrine stated as a default rather than as a trap.
`b4b_status_omitted_write_lands_proposed` asserts the default and the guard
agree — if you adopt the trigger without the default change, that is the
assertion that will catch it.

## A bug the new guard created, found before it shipped

`supersede_memory()` set `app.promoting = 'off'` immediately after updating the
old row, and only *then* inserted the successor — which lands at
`status='current'`. With the new `BEFORE INSERT` guard, the successor INSERT fell
**outside** the sanction window, so legitimate supersession was blocked by the
guard meant to stop illegitimate promotion.

The GUC span is widened to cover the successor INSERT. Worth noting this is the
exact inverse of the earlier `sql/13` fix, which *narrowed* the span because
`SET LOCAL` persists to end-of-transaction. The rule that reconciles both: **the
span must be as wide as the sanctioned work and no wider.**
`b9_supersession_still_works` is the regression test.

## What we deliberately did NOT close

- **`wiki_pages` is not gated at INSERT.** It has no `promote_wiki()`, its column
  default is `status='current'`, and `supersede_wiki()` (`sql/24`) only replaces
  an already-current page. Gating wiki INSERT would make `wiki_pages`
  uncreatable with no sanctioned path. Closing that asymmetry needs a
  `promote_wiki()` first. The artifact allowlist and the audit **do** cover
  `wiki_pages`; only the INSERT status gate is memories-only.
- **`app.promoting` is a session GUC.** Anyone holding an unrestricted role can
  set it and walk through every guard in the file. This closes the *accidental*
  path, not the deliberate one — accident-prevention and audit surface, not
  enforcement. Real enforcement needs per-principal connection identity.
  **Section D of `tests/23` asserts the bypasses still work**, so the limit
  appears in test output rather than only in prose. If a Section D test starts
  failing, our docs are the thing that is now wrong.

## On the test suite, because the shape matters more than the count

31 assertions in four sections: A = 7 positive controls, B = 13 forbidden paths,
C = 9 mutation-audit cases (see #47), D = 2 documented limits.

Three things we would suggest as doctrine for negative suites generally:

**Controls are not optional.** A negative-test file with no positive control
proves only that it can run. Every insert in Section A lands at `'proposed'`
deliberately: a control that inserted at `'current'` would, after this migration,
go green on the *status sanction* rather than on the pre-existing guard it names,
and quietly stop proving its own subject.

**The assertions were written against the doctrine before the fix existed.** At
one commit this file was all-red in Section B — nine forbidden paths probed,
eight open. They were not relaxed to fit the implementation.

**A NULL assertion is not a passing assertion.** `tests/23` ends with a
`GUARD_no_null_assertions` check. We added it after finding that a missing jsonb
key yields NULL from `->>`, so `(x ->> 'k') = 'v'` is NULL rather than false;
`bool_and()` ignores NULLs, `count(*) FILTER (WHERE NOT pass)` counts zero, and a
harness grepping for a false marker sees a blank column. **21 of 24 assertions in
one of our files "passed" against a function that lacked the feature entirely.**
If your suites aggregate with `bool_and`, this is worth checking today.

Happy to open a PR with the migration and the suite if the design looks right.
