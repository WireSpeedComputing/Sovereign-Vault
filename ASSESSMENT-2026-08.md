# ASSESSMENT — 2026-08-08

Produced under WO-14, unattended. Every claim carries **VERIFIED**, **ASSUMED**
or **UNKNOWN**.

**VERIFIED** means something was run that would have failed if the claim were
false, and it did not. Where the check itself could not be shown capable of
failing, the claim is downgraded — several are, and they are the interesting
ones.

---

## THE VERDICT

### Can real users be added? **No — not yet.**

Not because the access model is wrong. As of today it is measurably right, and
the things that were wrong this morning are fixed and verified. The blockers are
all in the same category: **the system is defensible but not yet recoverable, and
nothing verifies that it is.**

Four blockers. None needs a redesign; all are mechanical.

| # | Blocker | State | Who can clear it |
|---|---|---|---|
| 1 | 85 migration bodies exist only inside hosted databases | UNCHANGED since 2026-07-28 | Owner — needs one credential |
| 2 | 4 applied migrations (57–60) have no repo file | CONFIRMED today | Me, next session |
| 3 | The restore verifier is not proven able to fail | REGRESSED into view today | Me, next session |
| 4 | Granting a real user any scope is outside my authority | By design | Owner |

**Blocker 1 is the one that matters and it is the same one as three weeks ago.**
The reasoning in WO-12 still holds exactly: putting people onto a system whose
deployment history exists in one place converts a *recoverable* state into an
*occupied* one. Today added 3 more migrations to the 85. It is now 88.

Blocker 3 is new information rather than new damage: the discrimination proof
never ran to completion before today because the run failed earlier. It has
probably been unproven for some time.

**What is no longer blocking:** every item WO-13 listed as a blocker — the
access-path disagreement, the TRUNCATE bypass, and the data-readiness problem —
is closed and verified below.

---

## 1. Access paths agree

**VERIFIED.** Measured across all 8 active principals, before and after.

| | before | after |
|---|---|---|
| principals where `session_boot` disagreed with the policy predicate | **5 of 8** | **0 of 8** |
| magnitude of the disagreement | 132 current + 99 proposed records | — |

Check: for each active principal, `session_boot(...)->health->memories_current_visible`
compared against `count(*) where can_read_row(...)`. It returned 5 non-zero
deltas before migration 61 and returns 0 now. It would have failed had the claim
been false — it did fail, that is how the defect was measured.

**The reported magnitude was wrong and wrong in the dangerous direction.** The
defect was described as "up to three extra deadline records." It was the entire
corpus for those five principals — no partial overlap anywhere. A fix verified
against the reported number could have passed while leaving nearly all of the
gap open.

**Four surfaces, not one** (migration 61): `memory_hot_ranked_for`,
`deadlines_upcoming_for`, `session_boot`'s health counts, and `session_boot`'s
`retrieval_units` count — which resolved authorization from the *projection's*
copied columns, the thing `sql/36` explicitly refused to do for the policy on
that same table. Nobody reported the fourth. It was found by enumerating what
boot reads instead of fixing what the report named.

A fifth was found and fixed the same day in Phase 5: `task_board()`, on a table
that has not shipped yet.

### `is_owner_or_shared()` has never denied anything in production

**VERIFIED.** All 231 current and proposed rows carry `visibility='shared'` and
none has a NULL owner. The predicate is `(owner = principal) OR (visibility =
'shared')`, so its second disjunct is true for every (row, principal) pair that
exists. It is not a weak filter; it is not a filter.

This is the ninth instance of this project's signature failure and the first
found in an access predicate rather than a test harness. Left in place — it
starts discriminating the day a private row exists, and deleting a currently
inert guard is how you get a gap later.

### A correction to the record

**VERIFIED.** An independent review reported `retrieve_context` as scope-blind.
It is not: it reaches the scope gate through `can_read_row()`, which calls
`has_capability(row_scope(...))`. The report string-matched for
`request_has_capability`/`row_scope` in the function body and missed the
indirection. Checked with `pg_get_functiondef`. The same report's `session_boot`
finding was correct.

---

## 2. Table-level bypass

**VERIFIED closed.** `TRUNCATE` held by `service_role` on tables in
`public`/`vault_auth`: **32 before, 0 after** (migration 62).

Every custody mechanism here is `FOR EACH ROW`. `TRUNCATE` is statement-level and
fires none of them, so one statement defeated custody field locks, the bounded
status-transition guard, the hard-delete guard and the delete-audit receipt — and
`hard_delete_audit` was itself truncatable, so the bypass could erase its own
evidence.

**Nobody granted it.** `pg_default_acl` gives new tables `arwdDxtm` to
`service_role`; the `D` is TRUNCATE. It arrives with `CREATE TABLE`. A one-time
revoke would have been undone by the next migration that creates a table, so the
`ALTER DEFAULT PRIVILEGES` is the fix and the revoke is cleanup. Asserted
separately (test 3 of `tests/44`) so the fix cannot silently rot.

**The reported gap was not the real gap.** `perimeter_assert()` was described as
inspecting "row-level and function grants only." It already inspected table
grants. The blind spot was the **grantee filter** — `in ('anon','authenticated')`
— so every privilege held by the credential all automation runs under was outside
its field of view. Fixing what was reported would have changed nothing.

### Still true, and now documented rather than implicit

**VERIFIED by inspection, not fixed:**
- The table **owner** can always `TRUNCATE`, `DROP` and `ALTER`. Ownership is not
  a grant and cannot be revoked from.
- A platform-owned default-privilege entry, owned by a role we are not a member
  of, still grants the full set including `TRUNCATE` to the network-facing roles
  for tables created *by that role* in `public`. No current table is affected. We
  cannot alter it.
- Detection of a table-level destruction is not a database control at all. It
  needs an independently held checkpoint that diverges afterwards — which is
  Blocker 1.

`docs/04` now states that immutability claims must name the operations they hold
against. "A promoted record cannot be altered" is false as written.

---

## 3. Data readiness

**VERIFIED.** Unclassified `current` records: **84 → 8**. 76 reclassified through
`reclassify_record()`, each writing an audit row carrying old scope, new scope,
actor and reason. Audit rows: **76**.

The distribution WO-14 called decorative is gone: `compliance` 2 → 12,
`marketing` 1 → 13.

**8 records remain unclassified deliberately.** Each is genuinely co-primary
across two or more scopes — production-run economics, fulfillment comparison,
ingredient sourcing, supplier co-marketing, founder structure, pay structure, and
two records where a privacy question is as load-bearing as the technical one.
The order said not to force one, and **that count is the finding: single-scope
classification does not fit roughly 10% of this corpus.** A record that is
genuinely both is not served by picking the more defensible label.

The transition was built **before** the classification, deliberately: 84 records
moving between authorization scopes at once is the largest bulk authorization
change this system will ever make, and running it through a direct `UPDATE` would
have established that such changes need no audit.

### Attribution honesty — flagged, not resolved

**VERIFIED as a limitation.** `reclassify_record()` is human-gated, so all 76
audit rows name the owner principal as actor. **The judgement was mine.** Every
reason string says so explicitly, because an audit implying a human reviewed 76
records individually is a false custody claim — the exact thing the
reject-and-repropose ruling exists to prevent. A `proposed_by` column would
express this properly. **Queued as a decision.**

---

## 4. Gate discrimination

This is where the assessment is least comfortable, and the discomfort is the
finding.

| gate | can it fail? | evidence |
|---|---|---|
| `tests/43` (session boot scope) | **VERIFIED** | 8 of 9 assertions fail against a deliberately reverted build; assertion 1, the positive control, correctly still passes |
| `tests/44` (TRUNCATE) | **VERIFIED** | grants the privilege back mid-suite and requires the checker to report it, then requires it to stop reporting once revoked |
| `tests/47` (reclassify) | **VERIFIED** | 13 assertions including the window closing, the audit refusing DELETE, and content remaining locked |
| `tests/45`, `tests/46` (Phase 5) | **VERIFIED** | four deliberately broken variants; the broken run found a real defect in the new schema — see below |
| `tests/migration_drift.sh` | **VERIFIED** | four states, including a manifest that is present and populated but describes a different project |
| Rule 0 sweep | **VERIFIED** | it caught a real leak I introduced today and blocked the push |
| replay harness | **VERIFIED** | it failed on three separate real defects during this run before passing |
| `perimeter_assert()` | **VERIFIED** | reports a deliberate exposure, and on a role-less host now emits `not_evaluated` instead of a false clean |
| **restore verifier** | **UNKNOWN — and previously believed VERIFIED** | see below |
| sovereignty proof end-to-end | **UNKNOWN** | blocked on the above |

### The restore verifier is not proven able to fail

**UNKNOWN.** `prove_verifier_discriminates.sh` runs 22 corruptions and 2
equivalence cases. All 22 corruptions are caught. One equivalence case — the one
asserting the verifier must *not* cry wolf — fails, so the discrimination proof
fails and `verify_restore` cannot be trusted green.

Two causes found and fixed, and it still fails:
1. It reflowed the **pre-`sql/31`** body of `is_owner_or_shared`, without the
   `coalesce` that makes the predicate total.
2. It declared `STABLE` where the live function is `IMMUTABLE`.

Both meant the fixture offered a body that genuinely differs and asserted the
verifier must call it clean. **The verifier was right and the fixture was wrong.**
A third difference remains and I did not find it before the run budget ended.

I did not weaken the case to make it green. The canonicalizer compares
volatility, security mode, `search_path` and ACLs as well as the body — which is
what makes it worth having and what makes a hand-written "equivalent" easy to get
wrong.

**Why this went unnoticed: the run failed earlier, at verification, and never
reached this step.** A check that never executes cannot report that it is wrong.

### Two defects fixed in the proof itself

**VERIFIED.** `sovereignty_proof.sh` printed `COMPLETE` and exited **0** when the
discrimination step was skipped. Now exits 2 with `INCOMPLETE`.

A second defect in the same block was not previously reported: the conditional
`[ "$SKIP_DISC" -eq 0 ] && \` guarded only the **first** `echo`. The three that
followed ran unconditionally, so a skipped run printed the tail of a sentence
asserting that 22 deliberate corruptions had each failed on the intended check —
a claim about work that had just been skipped. The transcript did not omit a
caveat; it stated something false.

---

## 5. Restore fidelity

**VERIFIED, and separate from recoverability.** Every restore check passes:

- A–H: row counts (980 rows, 47 tables), per-table content hashes, 14 evidence
  locators, lifecycle distribution, provenance, supersession chains, hot index,
  perimeter clean
- I: migration inventory reconciles
- J: 1259 objects, fingerprints identical at the level of definitions — bodies,
  signatures, ownership, security mode, search paths, grants, triggers, policies,
  constraints, indexes
- K: **23 of 23** conformance probes pass after restore; K2 verdicts identical to
  source

**These two questions were conflated and are now separated.** "Does this restored
database match its source" is restore fidelity. "Do the migration bodies exist
outside a hosted database" is recoverability. The drift checker returned one exit
code for both, which made a *faithful* restore report as drifted. Now: exit 1 =
inventory drift, exit 3 = inventory reconciles but body coverage unverified,
exit 0 = both clean. Exit 3 is **not** a pass — the sovereignty proof reads it and
refuses to report a complete proof.

A faithful restore of a schema you cannot rebuild is not sovereignty. It is
evidence that this copy matched that copy.

---

## 6. Vendor coupling

**VERIFIED by building the host, not by reading the code.**

Method: vanilla PG17, `sql/00`'s role shim stripped (which is what restoring a
platform dump looks like), apply `sql/` and observe.

**The first run was a false negative and the positive control caught it.** It
reported "0 files failing," which would have read as excellent portability. The
roles were still present, so nothing had been tested. With an explicit assertion
that the roles are genuinely absent: **38 of 48 files fail**, starting at
`01_core.sql`. That is loud and immediate — the safe direction.

**The finding is what survives that failure.** `sql/28`'s `perimeter_assert()`
applies cleanly because it revokes nothing. The *fixed* version did not, because
its file opened with a `revoke ... from service_role` and psql aborted before
reaching the function definition. So on a role-less host the checker that
survived was the **stale fail-open one** — returns 0 rows, and 0 rows is its own
definition of clean:

```
before: STALE (fail-open: returns 0 rows having checked nothing)  -- 0 rows
after:  FIXED (emits not_evaluated)                               -- 1 row
```

Migration 60 fixed this in production and **has no repo file**, so the repo could
not supply it either. The vendor-coupling fix existed only inside the hosted
database — absent from the one artifact a provider exit would use, on precisely
the hosts where an independent party would run the check to verify our work.

**A correction:** the order states seven functions reference platform role names.
Word-bounded, it is **one**. The higher count comes from substring matching —
`anon` matches inside "canonical," which appears throughout this schema. I made
the identical mistake in my first enumeration query. Six **policies** are bound
`TO authenticated`, and Phase 5 added three more today, so the restore-blocking
policy count went from 3 to 6.

---

## 7. The pattern that ran through the whole day

Five fixtures were found encoding a superseded authorization model:
`tests/32`, `tests/40`, `tests/31`, the sovereign fixture, and the task-board
suite. In **every single case every denial assertion kept passing.** The only
checks that noticed were the positive controls.

A suite of denials cannot distinguish "correctly restricted" from "entitled to
nothing." When an authorization model gains a dimension, every fixture written
before it silently becomes an unauthorized principal, and a denial-only suite
reports that as success.

None of these fixtures were written carelessly. Each was correct when written.

---

## 8. Current measured state

**VERIFIED** — single query, this deployment, at time of writing.

| metric | value |
|---|---|
| migrations applied | 63 |
| perimeter findings | 0 |
| TRUNCATE grants to `service_role` | 0 |
| access-path disagreements across 8 principals | 0 |
| `current` records still unclassified | 8 |
| reclassification audit rows | 76 |
| active principals | 8 |
| **active principals holding zero read scopes** | **5** |
| RLS policies (live) | 3 |

**The 5-of-8 figure is not a defect.** Those principals now correctly see nothing
and are told why (`capability_scopes=none`) rather than shown an empty vault.
Granting them scopes is deployment data and explicitly outside my authority.

**RLS policies live = 3, repo = 6.** The three task-board policies are built and
tested but not applied. Consistent, not drift.

---

## 9. UNKNOWN — the honest list

- **Whether the restore verifier can fail.** The single largest open item.
- **Whether any migration body exists outside a hosted database.** No credential
  reachable in this session. Unchanged for three weeks.
- **What migrations 57–60 actually contain.** Applied, no repo file. A fresh
  install from this repo will not reproduce them.
- **Whether `supersede_wiki()` copies `source_agent` onto its successor** after
  migration 57's custody lock.
- **Full-corpus statement yield.** Phase 4 was not reached. The 20-record sample
  remains non-representative by construction.
- **Whether the 76 classifications are correct.** They are one agent's judgement
  on a 165-character excerpt each, recorded as such and pending review.
- **Whether any obligation rule reflects real regulation.** The seeded rules
  carry placeholder authority strings by design and must be replaced before
  anything relies on them.
- **Behaviour of Phase 5's schema against real data.** Never applied.
- **Whether `perimeter_assert()` misses privileges inherited through `PUBLIC`.**
  Raised in WO-13, not tested. The grantee-filter fix addresses `service_role`,
  not `PUBLIC` inheritance.

---

## 10. What would clear the verdict

In order:

1. **Run the extraction.** The `extract-migrations.sh` script in the private
   migrations repository needs `PGURI_LIVE` and `PGURI_FROZEN` set in the owner's
   own shell — not pasted into a chat. Then commit **and push**; a local-only
   extraction is the failure being corrected.
2. **File migrations 57–60** by reading the applied DDL back with
   `pg_get_functiondef`, not by retyping from a description.
3. **Resolve the equivalence case** in the discrimination proof, then re-run the
   sovereignty proof to completion.
4. **Decide the scope grants** for the five unprovisioned principals.

1 and 2 are mechanical. 3 is an afternoon. 4 is a judgement only the owner can
make.

Nothing here requires redesign, and that is the substantive good news: the
authorization model held up under a day of adversarial pressure. What it lacks is
proof that it can be rebuilt.

---

# ADDENDUM — 2026-08-09 (WO-15)

## The verdict has not changed: **No.** But the blocker list has.

| # | Blocker (2026-08-08) | State now |
|---|---|---|
| 1 | migration bodies exist only in hosted databases | **CLEARED** — 92 bodies extracted and pushed |
| 2 | 4 applied migrations with no repo file | **CLEARED** — 57-60 filed |
| 3 | restore verifier not proven able to fail | **STILL OPEN** |
| 4 | granting real users any scope is outside my authority | unchanged, owner's call |

**New blocker, and it is the one to read first:**

| 5 | The compliance ruleset exists only as deployment data | **VERIFIED, NEW** |

No file in `sql/` seeds `language_rules`. The entire disease-claim detector —
both tiers — lives in exactly one database. A fresh install from this repo has
**no compliance detection at all**, and reports a clean replay because there is
no rule left to fail. This is the same class as blocker 1, which took three
weeks to clear, on a control with regulatory consequences.

It is not fixed here: seeding a statutory ruleset into a PUBLIC repo is a
decision about what this repo publishes, not a defect fix.

## Instance ten, and it is the cleanest example of the class

`tests/51`'s verdict line was `SELECT 'SUITE_RESULT: PASS' AS verdict;` — a
literal. The runner reads that line and nothing else, so every assertion in the
file could fail and it scored green. **The suite whose entire purpose was
proving the visibility predicate discriminates could not itself report a
failure.**

It was found by running the falsification instruction written at the bottom of
that same file. The instruction was correct and had never been executed.
Writing a test and running it are different acts, and a verification artifact
can encode its own falsification and still ship green.

## Gate discrimination — updated

| gate | can it fail? |
|---|---|
| replay top-line verdict | **VERIFIED** — unresolved suites now block CLEAN (exit 2); previously three suites were unread and the run reported clean |
| `tests/51` visibility | **VERIFIED** — fails on the pre-`coalesce` predicate, D1/D2 plus 7/12 NULL evaluations |
| `tests/20` disease claims | **VERIFIED** — was emitting `*** FAIL ***` into an unread text column |
| relation pass | **VERIFIED** — reverting the numeric rule turns it red and names the regression |
| replica-mode audit guards | **VERIFIED** — reverting `ENABLE ALWAYS` turns four assertions red |
| restore verifier | **UNKNOWN** — unchanged, still the largest open item |

## New findings

**B2 — `session_replication_role = replica`.** One session SET disables every
origin-mode trigger; 39 of 39 in `public` are origin mode. Worse than TRUNCATE
in kind (it permits silent in-place UPDATE with the audit guards off, so the
record afterwards is *false*, not merely unattributed), better in reach: the
parameter is superuser-context, `service_role` is not superuser, and there are
no SET grants on it. Mitigated for the two audit tables (migration 67); the
custody triggers deliberately stay origin-mode because the restore needs them
off.

**B1 — the only unscoped inference channel is declared.** A principal holding
*zero* scopes still receives deployment-wide `review_queue` counts, ages and a
by-kind breakdown from `session_boot`'s coordination block, which declares
itself `coverage: unscoped`. Content counts correctly return 0. It leaks
activity volume and the existence of review kinds, not content. Worth gating on
holding at least one scope; queued.

**B3 — a statement outlives its superseded source.** `statement_state()`
correctly reports `source_superseded`. `statement_visible_to()` — the
authorization path — consults only retraction and `can_read_row`, never source
status. The currency information exists in a function the caller must remember
to call. Asserted as a documented limit (`tests/52` assertion 12) rather than
patched by hiding such statements, which would lose history.

**A1/A2 — the statement layer earns its place narrowly.** The relation pass
independently rediscovered all three predicted contradictions with zero
inventions. Against document retrieval it wins categorically on the
intra-record case (the document path has *no mechanism*, not a weak one) and
loses on "why did we decide X", where extraction keeps the assertions and
discards the argument. See `docs/13`.

## What would clear the verdict now

1. **Decide what to do about blocker 5** — the compliance ruleset in one place.
2. **Resolve the equivalence case** in the discrimination proof, then run the
   sovereignty proof to completion.
3. **Decide the scope grants** for the five unprovisioned principals.

Two of three are decisions rather than work.

---

# REVISED VERDICT — 2026-08-09, end of WO-15

## Can real users be added? **Yes, once one decision is made — with two conditions.**

This is the first time the answer has not been an unqualified no. What changed is
that the two blockers that were about *not being able to prove anything* are
closed, and what remains is a decision and a re-run.

| # | Blocker | State |
|---|---|---|
| 1 | migration bodies exist only in hosted databases | **CLEARED** — 92 bodies extracted and pushed |
| 2 | 4 applied migrations with no repo file | **CLEARED** |
| 3 | restore verifier not proven able to fail | **CLEARED TODAY** |
| 5 | compliance ruleset existed only as deployment data | **CLEARED TODAY** |
| 4 | granting real users any scope | **the remaining decision — yours** |

### Blocker 3 closed, and it found something on the way out

The discrimination proof now passes: 22 of 22 corruptions caught on the intended
check, both equivalence cases clean. `verify_restore` can be trusted green,
which it could not be at any previous point in this project's history.

Getting there surfaced a defect nothing else would have: **`ENABLE ALWAYS` did
not survive a restore.** `pg_dump --disable-triggers` wraps the load in
`ENABLE TRIGGER ALL`, and the plain form resets firing mode to origin — so the
two audit guards hardened yesterday came back from a restore in the exact state
migration 67 exists to prevent. Silently, because the triggers were present and
enabled and only their firing mode changed. A name-equality check calls that
clean; check J named both objects. Fixed as data: export records every
always-mode trigger, restore re-asserts them.

### Blocker 5 closed on the seam in the data

19 rules, 4 carrying a regulatory authority. Those 4 ship in `sql/`; the other
15 stay deployment data. `tests/20` — the suite that would have caught the
disease-claim gap and could not run anywhere it mattered — now runs on every
replay and passes 30 of 30 in a fresh cluster.

## The two conditions

**1. Re-run the extraction.** Migrations 65–69 were applied today, after the
92-body extraction. The sovereignty proof reports this precisely and refuses to
call itself complete: it exits 2 with RECOVERABILITY NOT ESTABLISHED and names
the missing bodies. That is the gate working, not a defect — but it means the
recoverability claim is *stale*, not *false*, and a re-run makes it true.

**2. Grant the five unprovisioned principals their scopes.** Five of eight
active principals hold zero read scopes. They correctly see nothing and are told
why. Granting is deployment data and outside my authority by design.

Neither is work. Both are one action each.

## Current measured state

| | |
|---|---|
| migrations applied | 69 |
| perimeter findings | 0 |
| TRUNCATE held by the service credential | 0 |
| always-mode audit guards | 2 of 2 |
| regulatory rules seeded in the repo | 4 |
| `current` records unclassified | 8 (all genuinely cross-scope) |
| active principals with zero scopes | 5 |
| replay | CLEAN, all 24 suites scored |
| sovereignty proof | A–K pass, 22/22 corruptions caught, exit 2 on stale bodies |

## What I would still not call finished

- **Statement extraction remains a six-record sample.** Full-corpus yield is
  unknown. Not extended in this run; reported rather than rushed, because a
  hurried extraction violates the one rule that makes the layer trustworthy.
- **`agent_surface_alias` is empty on a fresh install.** Deployment data by
  design, but an empty alias map resolves nothing — instance 5's exact shape.
  Asserted in `tests/55` so it cannot be rediscovered by accident.
- **Four tables carry `owner`/`visibility` columns live that no repo file
  creates.** The drift checker compares migration inventories, not schema
  content, and says so. Unreconciled.
- **A statement can outlive a superseded source.** Asserted as a limit.
- **`session_boot`'s coordination block** returns deployment-wide review counts
  to a principal holding no scopes. Declared, not gated.

## The thing worth carrying forward

Ten instances now, and the last three were not found by the same method as the
first seven. Instances 1–7 were found by accident. Instance eight was found by
asking *which gates are unread*. Instance ten was found by **executing a
falsification instruction that had been written down and never run**. Blocker
5 and the `scope_registry` finding were found by asking *which controls exist in
only one place* — and that question, asked mechanically against a fresh install,
found two more in ten minutes.

The pattern has stopped being "we keep making this mistake" and started being a
question with a repeatable method attached. That is the difference between a
list of incidents and a technique.

