Implemented and **applied** as a deployment migration on 2026-08-07:
`sql/24_wiki_supersession.sql`. It was staged in `pending/` until owner approval
and moved into `sql/` only once applied — `pending/` exists precisely so an
unapproved migration is not swept into a replay that would then prove something
untrue about the deployment.

## The finding that matters: supersession was blocked by TWO independent mechanisms

#71 identifies `wiki_pages_path_key UNIQUE (path)` as the blocker, and that is
correct as far as it goes. **It is not the only blocker.**
`enforce_bounded_status_transition` also rejects the status change, and its
sanctioned-function list names only the memory promotion and supersession
functions — both memories-only. So `wiki_pages` was **append-only in practice:
insertable, never supersedable**, by a second mechanism that has nothing to do
with path uniqueness.

**Replacing the UNIQUE constraint alone would NOT have restored supersession.**
The migration would have applied cleanly, the preflight would have passed, the
constraint would have been visibly correct — and the next supersession attempt
would still have failed, now with an error pointing somewhere else entirely.

That is why `supersede_wiki()` ships **in the same migration** rather than as the
follow-up item the checklist implies. We would suggest amending the issue's
required-work list accordingly: the constraint change and the sanctioned API are
one unit of work, not two.

The generalizable version: when a preflight confirms the blocker you went looking
for, that is not evidence it was the only one. We found the second only by
attempting the operation after the constraint change rather than declaring
victory on the DDL.

## Preflight, verified live before the dry run

Against the four audit items in the issue:

| check | result |
| --- | --- |
| `wiki_pages_path_key UNIQUE (path)` present | Confirmed, exactly as #71 found |
| duplicate active paths | **0** — nothing to reconcile, migration safe to proceed |
| inbound foreign keys depending on `path` | None. The only inbound FK references `id`, not `path` |
| `INSERT ... ON CONFLICT (path)` callers | One, and it is a **false positive**: it targets a different table (`doc_integrity`) which has its own primary key on `path`. Conflict-target inference is unaffected there |

That last row is the one worth calling out. #71 flags the `ON CONFLICT (path)`
audit because a partial unique index changes conflict-target inference — correct,
and a grep for the string finds a hit that looks alarming and is not. The audit
has to resolve which *table* each conflict target belongs to, or it produces a
scary answer and stalls the migration.

## What shipped

```sql
ALTER TABLE public.wiki_pages DROP CONSTRAINT wiki_pages_path_key;

CREATE UNIQUE INDEX wiki_pages_active_path_uq
  ON public.wiki_pages (path) WHERE status = 'current';
```

**Portability note:** #71 records the other deployment's index as
`UNIQUE (path) WHERE status='active'`. Ours predicates on `status = 'current'`,
because that is this schema's `record_status` vocabulary. The semantics are the
same — one live version per path — but the two indexes are not
copy-pasteable between deployments, and a drift check comparing index definitions
across them will report a difference that is correct rather than a defect.

`supersede_wiki()` deliberately **mirrors the memory supersession function rather
than copying the other deployment's implementation** — #71 explicitly warns
against copying it verbatim without security review, and we did not. It carries:

- an active **human** principal requirement (agents are rejected)
- `SELECT ... FOR UPDATE` on the predecessor
- an **expected-state predicate** (`WHERE id = ... AND status = 'current'`) with an
  explicit lost-race exception, so a concurrent supersession cannot silently fork
  the page
- the transaction guard set and reset inside an exception handler, so a failure
  cannot leave it armed for whatever runs next in the transaction
- `SET search_path = public` on the definer function, and `REVOKE EXECUTE` from
  `anon`, `authenticated` and `public`
- `actor_assurance` recorded on the predecessor's frontmatter, because a
  caller-supplied principal UUID proves the UUID belongs to an active human, **not
  that the caller is that human** under a shared credential. We would rather that
  caveat live in the data than in a doc.

The successor is created inside the same transaction as the predecessor's
closure, carries `supersedes`, and preserves the predecessor's bytes and
identity — the predecessor row is closed, not rewritten, so #71's concern about
the archival-path workaround changing the historical locator does not apply: the
locator is stable and both versions live at the same `path`.

## Test coverage, stated honestly — this is partial

`supersede_wiki()` is exercised in two places, and **neither is a dedicated #71
suite**:

- **Positive path**, end to end: the sovereignty fixture (`tests/sovereign_fixture.sql`)
  performs a real same-path supersession, and the #58 restore verification checks
  supersession chains for broken lineage, orphans, forks and live predecessors
  across both tables. So "same-path historical versions allowed", "atomic successor
  creation" and "preserved predecessor bytes/identity" are covered, as a
  side-effect of the sovereignty work rather than on purpose.
- **Negative path**: `tests/31_consequential_domains.sql` case `c9` asserts a
  classified page cannot be laundered through wiki supersession — the successor
  cannot silently drop its classification.

**What is NOT covered by any test we have:**

- two active versions denied (enforced structurally by the partial unique index,
  but **not asserted**)
- reapply / idempotence behaviour of the migration
- dependency-abort behaviour
- zero residue after negative probes
- explicit source-agent attribution asserted as its own case

We are not claiming those from the schema shape. The index makes the two-active
case structurally impossible and we have not written the test that proves it, and
those are different statements. Of the issue's test checklist, roughly half is
demonstrated and the rest is unwritten.

## Remaining asymmetry, and it is a real one

`wiki_pages` still has **no `promote_wiki()`**. Its column default is
`status='current'` and supersession only replaces an already-current page, so
wiki content enters at full authority with no review gate — while memories, after
the #46 work, cannot reach `current` by direct INSERT at all. We deliberately did
**not** gate wiki INSERT, because with no `promote_wiki()` that would make
`wiki_pages` uncreatable with no sanctioned path out.

So the honest state is: **#71's supersession semantics are closed; the wiki
lifecycle is still narrower than the memory lifecycle**, and closing that needs a
`promote_wiki()` first. Same gap is named in #46 and #58.
