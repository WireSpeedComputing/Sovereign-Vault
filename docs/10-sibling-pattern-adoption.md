# Sibling pattern adoption — `session_boot`, agent registry, delete guard

WO-09 Task E. Written 2026-08-07.

Three patterns from the sibling protocol repo `sovereign-memory-core` were
diffed against this repo and either adopted or deliberately diverged from. This
document is the written record of each decision. The code is
`sql/32_session_boot.sql`, `sql/33_agent_registry_integrity.sql` and
`sql/34_hard_delete_guard.sql`, with `tests/32`, `tests/33` and `tests/34`.

**All three SQL files are NOT YET APPLIED to any deployment.** Each declares no
`-- MIGRATION:` header, which `tests/migration_drift.sh` reads as "repo file
declaring no migration (not yet applied)".

---

## 0. A problem with the task as specified, stated first

The work order named upstream issues **#3** (`session_boot`), **#4** (agent
registry semantics) and **#5** (delete-guard) as the sources to diff against.

All three are CLOSED, and all three have the same body:

> Moved to private tracking — "This work is tracked privately."

They state no requirements at all. There is nothing in #3, #4 or #5 to adopt,
diverge from, or diff against. The same is true of #34 and #53.

Rather than stop, the substitution below was made, and every affected file
carries a SOURCING NOTE saying so:

| Work order | Actually used |
|---|---|
| #3 `session_boot` | The sibling's **shipped** `session_boot()` (`sql/01_core.sql` lines 405–434) plus upstream **#72**, "Fail closed on single-store misses and expose topology in session boot", which is OPEN, `priority:p0`, and states a seven-point required contract for exactly this surface. |
| #4 agent registry | The sibling's **shipped** `trusted_agents` table and the FK behind it (`sql/01_core.sql` lines 24–44, 59). |
| #5 delete-guard | The sibling's **shipped** `guard_hard_delete()` (`sql/01_core.sql` lines 361–375). |

This substitution is a judgement call. If the private trackers say something
different from what the shipped code and #72 say, this work is aimed at the
wrong target and should be re-reviewed against them. That is the single largest
uncertainty in this task and it cannot be resolved from here.

---

## 1. `session_boot` — ADOPTED, with divergences

### The diff

| Sibling | Here, before | Decision |
|---|---|---|
| `session_boot(p_viewer text)` returning a jsonb envelope | **Nothing.** Confirmed by `docs/08` Part 3, which grepped the tree and found only prose references in `sql/14` comments. | **Adopt.** |
| `p_viewer text`, with household members hardcoded in CHECK constraints | `principals` is a table (`sql/02`); `owner` is `uuid` (`sql/14`) | **Diverge:** `session_boot(p_principal_id uuid)`. A business is not two named people. |
| `hot_topics` from `memory_hot_ranked` filtered inline | `memory_hot_ranked_for(uuid)` already exists (`sql/14`) | **Adopt, delegating.** No second authorization path. |
| `deadlines` filtered inline | `deadlines_upcoming_for(uuid)` already exists (`sql/14`) | **Adopt, delegating.** |
| `channel_inbox` from `household_channel` | No such table | **Diverge: not imported.** Household messaging is not a memory-custody concern. |
| — | `review_queue` (`sql/09`) is this repo's open-work surface | **Add `coordination`,** which is what #72 requirement 4 asks for. |
| `instruction_integrity` from `verify_doc_integrity()` | `verify_doc_integrity()` exists (`sql/01`) | **Adopt unchanged.** |
| `health` counts | — | **Adopt,** every count filtered by `is_owner_or_shared()`. |
| — | — | **Add** `boot_schema_version`, per-block `coverage`, and `degraded`/`degraded_reasons`, per #72 requirements 2 and 5. |

### Authorization: one path, not two

The task required reusing `is_owner_or_shared()` and the existing owner/
visibility predicate rather than inventing a second path. That is what was done:
content comes from the existing `_for()` wrappers, and every count calls
`is_owner_or_shared()` directly — the same total predicate
`sql/31_is_owner_or_shared_total_function.sql` made NULL-safe and the same one
`retrieve_context()` filters on before ranking. Principal admission copies
`retrieve_context()` exactly: NULL and inactive/unknown both RAISE.

### The `coordination` divergence is the interesting one

`review_queue` has **no owner or visibility column**, so it cannot be
principal-scoped by the existing predicate. Two dishonest options were available
— scope it by `raised_by` and call it filtered, or omit the block and let boot
imply there is no open work. Neither was taken. The block reports **aggregates
only** (`open_count`, `oldest_open_age_days`, counts by `kind`), never
`review_queue.detail` (free text that can quote a private memory), and declares
`"coverage": "unscoped"` with the reason. `tests/32` B7 asserts the free text
never appears; D1 asserts the unscoped-count limit is still present, so the day
someone adds an owner column, D1 goes red and this document stops being true.

### Reconciliation with `docs/08`'s proposed `agent_contract()`

`docs/08` Part 3 correctly records that no `session_boot()` exists here and
proposes `public.agent_contract()` as a first-call introspection surface.

**They are separate surfaces and stay separate.** The distinction is the
authorization posture, not the field list:

- `agent_contract()` is deployment-neutral — `docs/08` lines 403–407: "no
  deployment identifiers, no principal names… Digests and booleans only" — and
  lines 389–401 contemplate GRANTing it to `authenticated` as a second declared
  `perimeter_exception`, so a fresh agent can reach it before it knows anything.
- `session_boot()` is principal-scoped and returns principal content. It must
  never be granted to `authenticated`, and `sql/32` declares no
  `perimeter_exception`. `tests/32` C14 asserts both.

Folding them together would mean either exposing a content-bearing surface at
the perimeter, or making the contract surface unreachable to the fresh agent
that needs it most.

They are **reconciled rather than duplicated**: `session_boot`'s `contract`
block *delegates* to `agent_contract()` when it exists and reports
`state = 'not_implemented'` when it does not — the state today. It never
synthesizes a contract answer; an invented digest is worse than an admitted gap.
`tests/32` C13 asserts this. When `docs/08`'s proposal is built, the block starts
carrying real output with no change to `sql/32`.

---

## 2. Agent registry semantics — PARTIALLY ADOPTED

### The diff

What the sibling has that **we already have, in a stronger form**:

| `trusted_agents` | Here |
|---|---|
| `agent_id` (PK) | `principals.agent_label`, partial UNIQUE index (`sql/02` line 30) |
| `active`, `retired_at` | `principals.active`, `deactivated_at` |
| `principal` (text naming a household member) | `vault_auth.principal_identity_bindings` (`sql/23`) — a reviewed binding from a real OAuth client to an agent principal |
| — | `capability_grants` (`sql/02`) — what the agent may *do*, scoped and revocable. No sibling equivalent. |

**Diverged, deliberately:**

- **`model` and `surface` are not adopted.** They are descriptive deployment
  metadata; nothing enforces on them upstream either. `capability_grants`
  already answers the only question with consequences, and `principals.notes`
  holds the rest. Two unenforced columns would grow the schema without growing
  an invariant.
- **A separate registry table is not adopted.** That would give us two
  writer-identity tables that can disagree. `principals` with `kind = 'agent'`
  *is* the registry.

### What was actually missing — the FK, not the table

The sibling's registry is load-bearing because of
`memories.source_agent text NOT NULL REFERENCES trusted_agents(agent_id)`. Ours
had no such link: `source_agent` is a bare nullable `text` on `memories`
(`sql/01` line 23) and on `wiki_pages` (`sql/22` line 18). Any writer could stamp
`'AGENT-THAT-NEVER-EXISTED'` and every provenance trigger in `sql/03` passed it.

`sql/22`'s own header calls `source_agent` "an attribution hole… a page can
satisfy every provenance trigger and still not say who produced it". The hole it
closed was the missing *column*; the column being unvalidated is the same hole
one layer down.

**Adopted** as a trigger, not an FK: an FK to `principals(agent_label)` would
require converting a deliberately *partial* unique index into a total one,
changing the principals table for every other consumer — and an FK cannot
express `kind = 'agent' AND active` at all, which is the actual invariant.

### The two-tier design, and the break it avoided

The first version required an **active** agent on every INSERT. Reading `sql/24`
afterwards showed that would have shipped a serious break:

- `supersede_memory()` (`sql/26`) writes the successor as `source_kind='manual'`,
  `source_agent=NULL`. Unaffected.
- `supersede_wiki()` (`sql/24`) **copies `v_old.source_agent` forward** onto the
  successor.

So a single-tier guard would have made **every wiki page authored by a
since-retired agent permanently uncorrectable** — the same "two individually
correct rules composing into a dead end" that `sql/26` records finding in
`supersede_memory`. An earlier draft of `sql/33`'s header asserted that
supersession carries nothing forward; that was simply false for wiki.

The guard therefore separates two questions a single `active` check was
conflating:

- **Registration** — "does this label name an agent principal at all?"
  Unconditional. A fabricated attribution is always rejected, including inside a
  sanctioned transition (`tests/33` B6).
- **Activeness** — "may this agent author something *new* right now?" Fresh
  authorship only, waived while `app.promoting` is armed, which is what
  `supersede_wiki()` sets.

`tests/33` C4 is the test that catches the regression if the waiver is ever
removed.

### Scope and limits

- Covers **`memories` and `wiki_pages` only**. Eleven tables carry a
  `source_agent` column; the `sql/10`/`sql/11` domain tables are exercised by
  `tests/12` and `tests/20`, which carry the deployment-only opt-out marker and
  do not run in a fresh replay. Extending a *rejecting* guard onto tables whose
  suite cannot be executed here would ship an unverified break. Asserted as
  `tests/33` D3.
- **Impersonation is not closed.** This proves the label names a registered
  agent, not that the caller *is* that agent. `source_agent` stays
  caller-asserted. Asserted as D1.
- **The activeness waiver rides a self-armable GUC.** Asserted as D2.

---

## 3. Delete-guard — ADOPTED

### The diff

This repo has an elaborate supersede-not-delete discipline: `record_status`
carries `superseded`, `retracted` and `entered_in_error`; `sql/26` makes
`current` unreachable by direct INSERT and promoted records immutable in place;
`sql/20` adds actor custody; `promoted_record_audit` is append-only because "an
audit trail that can be edited is not one".

And then:

```
$ grep -rniE 'before delete|hard.delete|allow_delete' sql/ tests/ docs/
(no output)
```

Every one of those controls is on INSERT or UPDATE. A bare
`DELETE FROM memories WHERE id = …` walked past all of them, destroyed the row,
and left nothing behind — not even a `schema_changelog` entry, since that is an
event trigger on `ddl_command_end` and never fires for DML.

**The immutability guard in `sql/26` was therefore strictly weaker than it
reads:** a caller who cannot rewrite a promoted record could delete it and
insert a replacement. `verify_promoted_integrity()` cannot detect that — it is a
LEFT JOIN *from* `memories`, so it reports on rows that exist. A deleted row is
reported by nothing. Deletion is the one mutation that erases its own evidence.

**Decision: adopt.**

### Divergences

- **Receipts go to a new `hard_delete_audit` table**, not the sibling's
  general-purpose `audit_log` (which does not exist here). Folding them into
  `promoted_record_audit` would mean widening that table's `event` CHECK from a
  later file — modifying `sql/26`'s object to store a different kind of fact.
- **The receipt stores a hash, not the content.** A safety table holding a second
  uncontrolled copy of every deleted row, with no owner/visibility columns, would
  be a bigger leak than the risk it mitigates. Asserted as `tests/34` C8.
- **Its append-only trigger uses a dedicated function**, not `sql/26`'s
  `forbid_audit_mutation()`. The first version did reuse it and the tests went
  green while the operator experience was wrong: that function hardcodes
  `'promoted_record_audit'` in its message, so touching `hard_delete_audit`
  raised an error naming a table the caller never touched. `tests/34` C7 now
  asserts the message names the right table.

### What is deliberately NOT covered

Each omission is load-bearing — a guard that closed these would have broken the
system, not secured it:

- **`retrieval_units` / `retrieval_embeddings`** — `sql/21` calls these
  "DISPOSABLE DERIVED PROJECTIONS, rebuildable at any time".
  `refresh_retrieval_units()` exists to rebuild them. Guarding them would break
  the repo's own embedding-migration story. `tests/34` C1 and C2.
- **`memory_hot_staging`** — `hot_touch()` deletes the staging row as its normal
  promote-from-staging step. `tests/34` C3.
- **`memory_hot_index`** — a derived attention index; `sql/15` already removed
  destructive eviction from the write path.
- **`review_queue`, `capability_grants`, `principals`** — out of scope;
  `capability_grants` already audits DELETE (`sql/02`).

### Limits

- **`app.allow_delete` is a self-armable session GUC.** Any service_role caller
  can arm it. This closes the **accidental** path — the stray DELETE, the
  migration with a bad WHERE clause, the agent that "cleans up" — not the
  deliberate one. Same limit, same words, already recorded for `app.promoting`
  in `sql/13`, `sql/20` and `sql/26`. Asserted as `tests/34` D1.
- **TRUNCATE is not covered.** No BEFORE DELETE trigger fires for TRUNCATE. This
  is a real hole in the adopted design and is present upstream too. Closing it
  needs a statement-level trigger or a revoked TRUNCATE privilege. Asserted as
  `tests/34` D3.
- **Domain tables are not covered**, for the same untestability reason as
  `sql/33`. Asserted as D2.

---

## 4. Test discipline and the discrimination runs

Each test file follows `tests/23_promotion_guards_negative.sql`: sections A
(positive controls), B (failing-negatives asserting the *rejection*), C
(legitimate path), D (documented limits), a `bool_and(coalesce(pass,false))` /
`FILTER (WHERE pass IS NOT TRUE)` summary, and the `GUARD_no_null_assertions`
row.

**Discrimination — tests were run against schemas without the change:**

| Run | Result |
|---|---|
| `tests/32` against a `session_boot` with the `is_owner_or_shared()` filter removed (identical otherwise; diff was six lines) | **5 of 9 B assertions went red** (B4, B5, B6, B8, B9) plus C5. A controls stayed green. |
| `tests/33` with the two enforcement triggers dropped, helpers retained | **6 of 6 B assertions went red.** A, C, D stayed green. |
| `tests/34` with the two enforcement triggers dropped, receipt table retained | **5 of 6 B assertions went red.** A stayed green. |

Dropping only the triggers, rather than omitting the whole file, isolates "the
guard does not enforce" from "the file is missing" — which is the question worth
asking.

**Assertions that do not discriminate are marked as such.** `tests/34` B6 stays
green in both worlds (a schema with no guard writes no receipts either); it is
labelled a consistency check, not evidence.

**Three defects were found in the tests themselves by these runs, not by
reading:**

1. `tests/33` B2 was **green on the wrong guard** — it inserted a wiki page at
   `status='current'`, which `sql/03`'s `enforce_agent_cannot_self_attest`
   rejects before `sql/33` is ever reached. Every B assertion now checks *which*
   guard fired via `SQLERRM LIKE`.
2. `tests/33` C4 and D3 were red for unrelated reasons (`sql/03`'s
   `decision_record` rule; a wrong column name on `suppliers`).
3. `tests/32` C4 was red because the envelope renders content only through
   `hot_topics` and `deadlines` — a shared row with neither is *counted* but never
   *rendered*. The test was wrong, not the code, and that is a real property of
   the surface now recorded in the fixture comment.

---

## 5. Two findings about the harness itself

### 5.1 My own test files were silently skipped

`tests/replay_fresh_install.sh` greps each test file for the literal
deployment-only opt-out string **anywhere in the file, comments included**. All
three new test files described that marker in prose and were therefore reported
as `SKIP`, not `FAIL` — they never ran, and nothing looked wrong. Fixed by never
spelling the token; the marker is now described rather than named. Anyone writing
a test file that discusses the opt-out mechanism will hit this.

### 5.2 A pre-existing false FAIL in the validation suite

`tests/31_total_predicate_null_safety.sql` is reported as **FAIL** by the runner
while actually passing. Its own summary prints `SUITE_RESULT: PASS` and every
`pass` column reads `t`.

The cause: the runner greps for `\|[[:space:]]*f[[:space:]]*(\||$)`, and that
file prints columns named `actual` and `expected` whose **correct** values are
`f`:

```
 ownerless_private_is_false      | f      | f        | t
```

Reproduced on a pristine schema with `sql/32`–`sql/34` absent, so it is
**unrelated to this work**. It means either the replay is currently failing and
nobody has noticed, or it has not been run since that file was added. Not fixed
here — it is another workstream's harness and the task forbade running it. It
should be fixed, most simply by having that test not print bare boolean columns
other than `pass`.

---

## 6. What could not be verified

- **The private trackers behind #3, #4 and #5.** See section 0.
- **Domain-table coverage** for both guards. `tests/12` and `tests/20` carry the
  deployment-only opt-out marker and cannot run in a fresh replay, so extending
  either guard there could not be validated. Left uncovered and asserted as a
  documented gap rather than shipped blind.
- **Anything host-specific.** As `tests/replay_fresh_install.sh` notes, a local
  replay cannot prove cloud-host default-privilege behaviour on newly created
  objects, nor extension placement. `session_boot`'s non-exposure was verified
  locally (`tests/32` C14) and `perimeter_assert()` returns 0 findings, but the
  hosted project is the only place that is conclusive.
- **Behaviour under real RLS with a non-superuser role.** The suite runs as
  superuser, faithful to how this deployment writes (service_role / SECURITY
  DEFINER), but it does not exercise RLS policies — consistent with `tests/23`,
  and noted rather than claimed otherwise.
- **`#72` requirements 1, 2, 3 and 6 in full** — multi-store topology, peer
  reachability, and client-side miss reporting. `sql/32` implements the
  coverage-state discipline those requirements rest on, but this deployment has
  a single store and no peer topology, so nothing here proves the fail-closed
  behaviour for an unreachable peer. That remains open.
