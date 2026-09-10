# WO-10 exit report — autonomous session, 2026-08-08

Owner away. Queue-rather-than-block was applied: nothing stalled waiting on a
decision, and every decision that needed one is in the queue at the bottom.

**Migrations applied this session: 52, 53, 54, 55, 56.**
**Deliberate holds respected: `sql/26` and `pending/D` were not applied, not
modified, and not staged for apply.**

---

## Before anything: the baseline was already broken

The replay harness failed on arrival, before this session touched a file. Three
independent causes, all real. Applying anything on top of a red baseline would
have meant "verified on a fresh replay" was a claim I could not make.

1. **Three table grants from migration 48 were undeclared.** `perimeter_assert`
   flagged them correctly. Those grants are what make the RLS policies reachable
   at all — RLS filters rows, a table privilege decides whether the role may
   touch the table. Declared as a *pair* with their policies: the grant opens the
   door, the policy decides who walks through.

2. **A semantics conflict on the deployment, verified directly.** `sql/39`
   (migration 51, applied) locks `content` from INSERT for **every** status.
   `docs/04` and `sql/26` both say a `proposed` candidate is work in progress and
   freely editable. Probed production: editing a proposed row's content is
   **REJECTED**; editing its tags is **ACCEPTED**. The review loop the docs
   describe is not what the deployment does. `tests/23` now records applied
   behaviour with a comment saying it is not an endorsement. **Queued as decision
   D1.**

3. **`sql/33` is not applicable as written** and was moved to
   `pending/F_agent_registry_integrity_BLOCKED.sql` with its test. Its own
   assertions fail against applied reality: it expects `source_agent`
   reattribution between active agents to succeed, and migration 51 makes
   `source_agent` immutable after insert. `sql/39` says that is intended.
   Applying it would have installed a guard whose own test fails. **Queued as
   decision D2.**

---

## Task A — apply the safe backlog

| Migration | Repo file | Verified live |
|---|---|---|
| **52** hard-delete guard | `sql/34` | unarmed DELETE blocked; armed override writes a receipt and removes the row |
| **53** perimeter exception model | `sql/28` | **242 findings → 0**, 6 exceptions, all `still_present` |
| **54** incremental projection | `sql/41` (was `pending/C`) | promotion projects with no manual refresh; operational writes do **not** re-project; delete invalidates; count back to 135; drift 0 |
| **55** session_boot | `sql/32` | `degraded=true` with both real reasons; perimeter stayed 0 |
| **56** consequential domains | `sql/31` | **inert as designed**: 4 policies, 0 bindings, 0 classified rows, nothing else moved |

**Migration 52 closed a hole demonstrated in the same session.** Before applying,
a plain `DELETE` on `memories` succeeded — which made the custody locks and the
promoted-record audit strictly weaker than they read, since delete-and-reinsert
was always available and `verify_promoted_integrity()` cannot see a row that is
gone.

**Migration 54 broke a test, correctly.** `tests/27` creates ACL drift by
updating visibility, then asserts the rescan repairs it. After 54 the triggers
repair that drift in the same statement, so the test found zero drift and
reported the repair path as broken. The repair path is not obsolete — it is what
corrects drift predating the triggers. `tests/27` now disables the sync trigger
around the mutation. Deleting the assertion would have removed the only coverage
of the repair path on the day it became the only way to reach it.

**File-number collision resolved**: `sql/33` left `sql/` entirely, so only one
file is numbered 31. Note the deeper issue, flagged during triage: **repo `sql/NN`
numbers do not track migration numbers** (`sql/34`→52, `sql/28`→53). A directory
listing is actively misleading; the `MIGRATION:` headers are the mapping to
trust.

---

## Task B — issues

Closed with evidence: **#5** (delete-guard), citing the receipt row, the absent
source row, and the honest limit that `app.allow_delete` is a session GUC — a
speed bump plus a receipt, not an authorization boundary.

Left open with accurate status: **#3** (session_boot was unapplied when assessed),
**#4** (design fork, see D2), **#10**, **#21**, **#17**.

**#10 is the one worth reading.** `perimeter_assert()` now returns 0 — but
`vector` **is still in `public`**, with 118 vector-owned functions each granted
EXECUTE to both `anon` and `authenticated`. Independently confirmed here.
Nothing was revoked or moved; it stopped being *reported*. Declarable is not
relocated, and a reader seeing 0 must not infer the fix. The issue stays open.

**#17 stays open on a real gap.** `scope_registry` gives workstreams a durable
grain but governs **authority only** — zero constraints reference `workstream`
on `memories`. A grant on `workstream:brnad` is rejected; a memory *stamped*
`'brnad'` inserts cleanly and becomes a row nobody can ever be granted read on.
Silent fail-closed, presenting as "the memory vanished."

**A wrong comment was published and corrected.** `pending/C` was applied as
migration 54 between the triage agent's verification and its post on #21. It
caught this, re-verified, and posted a retraction on the same thread. The wrong
version is still visible above the correction. The lesson it recorded is worth
keeping: *on this repo a read is only true until it is published*.

---

## Task C — upstream

Four comments posted to `jryski/sovereign-memory-core`: **#52**, **#12**, **#11**,
**#40**. Sweep run as its own command with `$?` checked, exit 0 before each, and
the published bodies were pulled back down afterward and re-swept.

**Three places my own brief overstated the evidence, all corrected before
posting rather than repeated:**

1. **"roughly ten citations that resolve to nothing" was wrong in both
   directions.** Measured: 285 governed rows with a non-direct-human basis, zero
   violating the citation constraint. 219 resolve by FK to a preserved artifact.
   66 have no artifact link — 13 embed a UUID in prose (8 resolve, **5 do not**),
   53 contain no machine-resolvable token at all. Strict reading: **5**. The
   reading #11 actually cares about: **66 / 53**. The remembered figure was
   retired in the comment.

2. **Our own sovereignty proof has a defect matching what #52 forbids.**
   `sovereignty_proof.sh --skip-discrimination` prints a warning and then
   **exits 0 with the same closing banner as a full pass** — a skip
   indistinguishable from verification, which is #52's own criterion. Also, check
   F seeds its supersession-cycle CTE from `supersedes is null`, making a cycle
   **structurally unreachable**: a cycle present at export passes. Both were
   posted as our failures.

3. **`sql/28`'s body says "close to two hundred" while its header says 242.**
   Cited 242 as the recorded applied figure and flagged that the pre-migration
   state no longer exists to re-measure.

**Two latent defects found in `sql/06`'s `import_cutover_scorecard`:** its counts
use `count(ra.id)` across a LEFT JOIN to `memories`, so an artifact yielding two
candidates is **double-counted** — correct today only because the measured
maximum candidates-per-artifact is exactly 1, and it breaks the moment #11 is
implemented. And `sunset_ready` compares cross-batch counts to a single-batch
`max(expected_count)`; one live source has 3 batches summing 84 against a max of
39. Raised upstream as a **question**, not a verdict, because it turns on whether
`expected_count` is per-batch or restates the source total — intent not
recoverable from the code.

---

## Task D — task board schema (built, NOT applied)

`sql/40_task_board.sql` + `tests/40_task_board.sql`. 21 assertions across four
sections, all passing. Our issue #22.

**Policies deliberately absent**, with the reason in the header rather than a
gap. Task visibility must reuse the RLS model from migration 43 — not invent a
parallel one. Until that migration exists the tables sit at RLS-enabled-with-no-
policy, reachable only via service_role: the same posture `memories` had for
weeks. The `owner`/`visibility` columns are present now so the later change is a
policy and not a schema migration.

**The invariant:** a task points at data, never carries a copy. Structural
(references are validated id pairs; resolution at read time, so a superseded
referent reports `stale`) plus best-effort (a trigger rejects a body containing a
referent's content verbatim). The second **cannot** catch paraphrase or a figure
lifted from a sentence — asserted as a limit in `tests/40` section D so it
appears in output, not only in prose.

Staleness is **computed, never stored**. A stored `is_stale` flag would itself go
stale — the exact defect migration 39 fixed in the retrieval projection.

`requires_evidence` **ratchets on**: a gate you can switch off when it blocks you
is advisory. Dependency cycles are rejected at write with a depth cap.

**Two real bugs the tests found, both mine.** `task_reference_state`'s OUT
parameters shadowed columns, giving "column reference ref_table is ambiguous" at
**runtime** — the function creates cleanly and fails on first call. And a test
looked up a row a prior failing block had rolled back, so it updated **zero rows**
and read that as the guard being broken; it now asserts `ROW_COUNT`. The second
is the same shape as defects found three times before here: a check reporting a
result without having checked.

---

## Decision queue — needs the owner

**D1 — Can a proposed candidate be edited?** Migration 51 says no (content locked
from insert, all statuses). `docs/04` and `sql/26` say yes (candidates are work
in progress). Both are defensible; they cannot both hold. Today the deployment
enforces custody-first, and the documentation describes something else. Affects
whether `sql/26` can be applied as written.

**D2 — Custody-first or registry-first for agent attribution?** Migration 51
makes `source_agent` immutable after insert. `pending/F` (was `sql/33`) assumes
it is correctable between registered active agents. Its own test proves the
conflict.

**D3 — Custody locks are on `memories` only.** Verified: 1 custody trigger on
`memories`, **0 on `wiki_pages`**. So `wiki_pages.source_agent` and content are
mutable today while `memories`' are locked. That asymmetry is nobody's recorded
decision — it looks like an omission rather than a choice, but I did not assume
it and did not change it.

**D4 — `vector` in `public` (#10).** The exception model made it declarable; it
is not relocated. 118 functions still granted to `anon` and `authenticated`.

**D5 — Undeclared workstreams are silently unreachable (#17).** A typo'd
workstream on a memory inserts cleanly and produces a row nobody can be granted
read on. Zero drift today; the failure mode is silent.

**D6 — `expected_count` semantics** in `import_cutover_scorecard`: per-batch or
whole-source? Raised upstream as a question.

---

## Awaiting owner approval

**The two deliberate holds, at the top as instructed:**

1. **`sql/26_propose_then_promote.sql`** — HELD. Changes every write path and
   makes agent decision records require human promotion. Also interacts with D1:
   as written it assumes candidates are editable, which the deployment currently
   forbids.
2. **`pending/D_scope_hierarchy.sql`** — HELD. Widens authority. Everything
   applied so far narrows it.

**Built and tested, not applied:**

3. `sql/40_task_board.sql` — task board schema. Needs its RLS policy migration
   before it is usable by anyone but service_role.
4. `pending/F_agent_registry_integrity_BLOCKED.sql` — blocked on D2.

**Unfinished work, stated plainly:**

- **#21 checkbox 3 is genuinely unmet.** Migration 54 ships
  `sync_retrieval_units()` and its triggers but **no monitoring surface** for
  unprojected rows. `retrieval_acl_drift()` covers drift; nothing covers
  unprojected. That is why #21 was not closed.
- The `sovereignty_proof.sh --skip-discrimination` exit-0 defect is reported
  upstream but **not fixed**.
- The `import_cutover_scorecard` double-count is reported but **not fixed**;
  it is latent until #11 lands.

---

## Disagreements with the work order

**"`sql/32`, `sql/33`, `sql/34` — apply if their tests pass."** `sql/33`'s tests
do not pass and cannot, against applied reality. Treating "the file exists and
was tested once" as equivalent to "it is applicable now" is the failure this
instruction was written to prevent, and it would have caught itself here — the
test failed rather than the guard misbehaving silently.

**The stated perimeter figure was ~98 non-extension findings; the actual total
was 242.** Not a material error, but the shape matters: three of those were the
deliberate table grants, and the rest were extension internals. The count in a
work order is a memory of a measurement, not a measurement.

## Gates

Every gate run as its own command with `$?` checked on the next line, never
piped. Final state: **replay 0, drift 0, sweep 0.** Deployment: 3 policies, 10
scopes, 135 live units, 0 ACL drift, 0 unprojected, perimeter 0.
