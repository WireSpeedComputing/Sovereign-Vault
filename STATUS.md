# STATUS

Last updated: 2026-08-07. Most recent work: "Governed retrieval, Phase C", "Transition concurrency + actor custody", "Fresh-install replay", and
"Disease-claim false negative" below. The replay is reproducible — run
`tests/replay_fresh_install.sh` rather than trusting this file. Phase 0 and Phase 1 SQL were applied to a real PostgreSQL 16
instance (Ubuntu, pgvector 0.6.0) and all 8 Phase 1 acceptance tests were
executed for real, not just reasoned about. Results below. This was NOT
tested against Supabase at that time — see "Not yet tested" (2026-07-08
version), now superseded by the Postgres 17 / Supabase validation below.

## Retrieval projection: no auto-refresh, and a live visibility leak (2026-08-07)

Two separate problems in the retrieval projection. `pending/C_retrieval_projection_refresh.sql`
addresses both for future writes; NOT APPLIED.

### 1. The projection was never maintained automatically

`retrieval_units` is built by `refresh_retrieval_units()`, a full rescan invoked
by hand. Nothing called it. Six memories written by other sessions were
invisible to `retrieve_context()` until the refresh was run manually — the rows
existed, were `current`, and simply were not in the projection.

That failure is silent by construction. `retrieve_context()` reports
`units_visible` and `units_matched` honestly, but only about units that exist; a
memory that was never projected is indistinguishable from one that does not
exist. The envelope's entire purpose is to separate "nothing found" from
"nothing searched", and an unmaintained projection defeats it one layer down.

`pending/C` adds per-row AFTER triggers on `memories` and `wiki_pages`. Not a
rescan and not a schedule — `pg_cron` is not installed. The UPDATE triggers
carry a WHEN clause so embedding backfill, `hot_touch` and `due_status` writes
do not re-project. 13 tests in `pending/C_..._TEST.sql`, all passing on a fresh
replay with C applied.

### 2. LIVE DEFECT — a memory made private stays readable through retrieval

**This one needs an owner decision; it is on the deployment now.**

`refresh_retrieval_units()` invalidates a unit only when its source stops being
`current` or its CONTENT HASH drifts. It never compares `owner`, `visibility` or
`workstream`. `retrieve_context()` filters on the UNIT's copy of `visibility`,
not the source row's.

Verified on a clean PG17 replay of `sql/00-25` using only the documented
maintenance path:

| step | result |
|---|---|
| shared, after refresh | other principal matches the row (expected) |
| set `visibility='private'` | other principal **still matches** |
| run `refresh_retrieval_units()` | other principal **still matches** |
| inspect | `retrieval_units.visibility='shared'` while `memories.visibility='private'` |

The full rescan does not repair it, because the rescan has the same hash-only
invalidation rule. **No operation currently closes this except editing the
memory's text.**

It interacts badly with `sql/25`: now that a promoted record's content is
immutable, the one accident that used to clear a stale unit — someone editing
the text — cannot happen anymore, so the leak becomes permanent for the affected
row instead of eventually self-healing.

`pending/C` fixes it for rows changed after it is applied. It does NOT
retroactively repair units that are already stale, and fixing
`refresh_retrieval_units()` itself is a change to `sql/21` that has been left
for the owner rather than folded in. Any deployment that has ever changed a
memory's visibility or owner should be treated as having stale units until that
is done.

## Propose-then-promote + promoted-record audit — BUILT, NOT YET APPLIED (2026-08-07)

`sql/25_propose_then_promote.sql`. Upstream #46 (ADOPT) and #47 (ADOPT).
**This file is in `sql/` but the deployment does not have it.** It replays and
its tests pass; it has not been applied to any hosted project.

**What was open.** Probed against a clean PG17 replay of `sql/00-22`: all five
forbidden paths #46 names were open, plus three more. The root cause was not a
broken guard — it was that no guard ran on the INSERT path at all.
`enforce_bounded_status_transition` is BEFORE UPDATE only, and
`enforce_agent_cannot_self_attest` constrains only `source_kind='agent'`, so
`promote_memory()` was a convenience wrapper rather than a chokepoint and any
caller could INSERT `status='current'` directly. Separately,
`memories.source_artifact_id` was a bare FK unconstrained with respect to
`raw_artifacts.action`, so `hold`/`exclude`/`evidence` artifacts normalized and
promoted cleanly through the sanctioned human gate.

**A fifth artifact class the upstream issue does not name.** `action` is
nullable by design ("classification is explicit, never defaulted"), so `NULL` is
the default state of every landed artifact and was promotable. The guard is
therefore an **allowlist** on `action='import'`. A denylist keyed on
hold/exclude/evidence would have shipped looking correct while leaving the most
common case open.

**The fix.** `status='current'` is unreachable by direct INSERT; everything
lands `proposed` and the definer functions are the sole path. Deliberately not
keyed on `source_kind`, which is caller-declared and therefore bypassable by
assertion. Promoted records become immutable in their authority-bearing fields
(`content`, `provenance_basis`, `citation`, `source_kind`, `source_agent`);
operational fields stay mutable. `promoted_record_audit` records a content hash
per transition and is append-only; `verify_promoted_integrity()` reports
match / mismatch / unaudited.

**A bug this exposed, found before it shipped.** `supersede_memory()` set
`app.promoting = 'off'` immediately after updating the old row and only then
inserted the successor — which lands at `status='current'`. With the new BEFORE
INSERT guard, that successor INSERT fell outside the sanction window and
legitimate supersession was blocked by the guard meant to stop illegitimate
promotion. The GUC span is widened to cover the successor INSERT. Note this is
the exact inverse of the `sql/13` fix, which *narrowed* the span because
`SET LOCAL` persists to end-of-transaction. The span must be as wide as the
sanctioned work and no wider. `tests/23` b9 is the regression test.

**What this is not.** `app.promoting` is a session GUC; anyone holding
`service_role` can set it and bypass every guard in the file. This closes the
accidental path, not the deliberate one — accident-prevention and audit surface,
not enforcement, exactly as `actor_assurance` is labelled in `sql/20`. Real
enforcement needs per-principal connection identity (`vault_auth`).
`tests/23` section D asserts the bypasses still work so the limit shows up in
test output; if a section D test starts failing, the docs are now wrong.

**Tests.** `tests/23_promotion_guards_negative.sql`: 28 assertions across four
sections — 7 positive controls over pre-existing guards, 10 forbidden paths, 9
mutation-audit cases, 2 documented limits. All pass on a fresh replay. The
controls exist because a negative-test file with no control proves only that it
can run; at commit `161b835` this same file was all-red in section B by design,
and the assertions were written against the doctrine before the fix existed
rather than relaxed to fit it.

**Validation suite now runs on replay.** `tests/replay_fresh_install.sh`
executes every `tests/NN_*.sql` that does not declare `REQUIRES-DEPLOYMENT`.
`tests/03` (needs real principal ids) and `tests/12` (needs seeded compliance
rules) declare it. Verified the runner actually fails: a deliberately-false
probe file was detected and exited non-zero.

**Open, deliberately.** `wiki_pages` is NOT gated at INSERT. It has no
`promote_wiki()`, its column default is `status='current'`, and `supersede_wiki()`
only replaces an already-current page — gating wiki INSERT would make
`wiki_pages` uncreatable with no sanctioned path. Closing that asymmetry needs a
`promote_wiki()` first. The artifact allowlist and the audit DO cover
`wiki_pages`; only the INSERT status gate and the immutability guard are
memories-only. Wiki content drift remains covered by `doc_integrity` /
`bless_doc`.

**Also.** `tests/replay_fresh_install.sh` now pins `LC_ALL`: PG17 on macOS
aborts with "postmaster became multithreaded during startup" otherwise, which
was blocking the entire harness.

Documentation: `docs/04-record-lifecycle.md`.

## Wiki supersession — APPLIED (2026-08-07)

`sql/23_wiki_supersession.sql`, deployment migration 37. Upstream #71 closed on
this deployment. Staged as `pending/A_wiki_supersession_ISSUE71.sql` until
approval, then moved into `sql/` — `pending/` exists precisely so an unapproved
migration is not swept into a replay that would then prove something untrue.

## Governed retrieval, Phase C - IMPLEMENTED (2026-07-29)

Recall did not exist. Embedding columns and HNSW indexes sat on the canonical
tables with no function querying them: storage without retrieval, in a system
whose whole purpose is storing and recalling. `sql/21`.

Design follows the retrieval profile from the architecture review. Canonical
rows stay authoritative; `retrieval_units` and `retrieval_embeddings` are
disposable derived projections, rebuildable at will, so a chunking change or an
embedding-model migration never touches the system of record. Embeddings are
keyed by model identity in their own table, so adopting a new model is an
additive row rather than a destructive overwrite of one vector column, and two
models can be compared side by side.

Two properties are load-bearing:

1. **Filtering happens before ranking**, in its own CTE. Ranking never sees a
   row the principal cannot see, so neither a relevance score nor a match count
   can leak the existence of another principal's private record. Verified: a
   private canary owned by one principal was matched only by its owner; two
   other principals saw neither the match nor the unit in their visible count.
2. **`retrieve_context` returns a jsonb envelope, never a bare rowset.** An
   empty rowset is indistinguishable from "nothing relevant exists". The
   envelope always reports units visible, units matched, mode, budget used and
   whether results were truncated, so `evaluated` with zero matches is
   distinguishable from `not_evaluated` (no units visible, or an empty query).
   This is the same principle the compliance surface needs and does not yet have.

Hybrid by design, FTS-capable today: there is no embedding pipeline, so the
caller supplies a query embedding when it has one. Without one the receipt
reports `fts_only` rather than implying semantic recall happened. Fusion is
reciprocal rank fusion, which needs no calibration between incomparable scales.

Three defects were found and fixed during implementation, all mine:
- the projection builder called a non-existent function. plpgsql bodies are not
  validated at CREATE time, so the migration applied cleanly and would have
  failed only on first invocation.
- `retrieve_context` used `ON COMMIT DROP` temp tables, which persist for the
  transaction, so calling it twice in one statement failed. Rewritten as pure
  CTEs.
- a single match longer than the whole budget was dropped, returning an empty
  results array for a query that did match. The top match now always survives,
  truncated to fit and flagged per-result with `text_truncated`.

Verified on a fresh database: all 22 SQL files replay clean, and
`tests/21_transition_custody_and_retrieval.sql` passes end to end, including the
supersede positive path that had previously shipped asserted-but-unexecuted.

**Known limits.** No embedding pipeline, so semantic recall is unavailable until
one exists; the schema is ready for it. Wiki sections project but there are no
`current` wiki pages in the reference deployment yet, so heading-split rendering
is exercised only by tests. Domain renderers (Phase D) and session integration
(Phase E) are not started.

## Transition concurrency + actor custody — FIXED (2026-07-28)

An independent architecture review found two defects in the lifecycle
transition functions that prior sessions, including this repo's own test
batteries, had all missed. Both were confirmed against a live deployment
before fixing. `sql/20`.

**Defect 1 — lifecycle races.** `promote_memory`, `reject_memory`, and
`supersede_memory` each read a row's status, then UPDATE it later, with no row
lock and without retaining the expected state in the UPDATE predicate. Two
concurrent sessions can both read `proposed`; one promotes; the other then
rejects and overwrites the result. Not hypothetical: a session stuck
idle-in-COMMIT holding locks on this table was observed on a live deployment
the same day. Concurrent supersession could additionally produce two `current`
replacements for one predecessor, silently forking the record, because
`supersedes` carried no uniqueness constraint for live successors.

Fixed with `SELECT ... FOR UPDATE`, expected-state predicates
(`where id = ? and status = ?`) with an explicit lost-race exception, and a
partial unique index on `(supersedes) where supersedes is not null and
status = 'current'`.

**Defect 2 — supersession had no actor custody at all.** `supersede_memory()`
accepted no acting principal, performed no active-human validation, and
recorded no actor. Every supersession before this migration is attributable to
nobody. The actor is now a required argument, validated as an active human, and
recorded. **The old 5-argument form is dropped rather than left callable**, so
the unaudited path cannot be reached by accident.

**Honest labelling of what the actor proves.** A caller-supplied principal UUID
demonstrates only that the UUID belongs to an active human — not that the
caller *is* that human, while clients share one unrestricted credential. Rather
than leave that implicit, all three functions now stamp
`actor_assurance = 'caller_asserted_unauthenticated'` into the row metadata, so
a later reader cannot mistake these records for authenticated attribution. The
review's refinement on this point is worth recording: the blocker is not a
shared *physical connection* or pool, it is a shared *authorization identity*.
A shared pool is acceptable if every request carries independently verified
identity the client cannot forge — either by authenticating the human through
an identity provider and deriving the actor inside the trusted path, or via a
trusted gateway that authenticates each request and signs an identity
assertion the database verifies. Both remove the caller-supplied UUID. Neither
exists here yet, which is why human multi-user access remains deferred.

**Verification status, stated precisely.** Structural checks pass on the live
deployment: all three functions lock and retain expected state, the old
5-argument function is gone, the successor uniqueness index exists. Negative
paths verified live and fail before any mutation: an agent actor is rejected,
and a non-existent principal is rejected. **The positive path of the new
6-argument supersede — that a valid human actor succeeds and the actor is
recorded — has not yet been exercised end-to-end**, because the host available
at the time had no local Postgres to run `tests/replay_fresh_install.sh`
against. That test is outstanding and should be run before relying on this
migration in a fresh install.

## Fresh-install replay — PROVEN (2026-07-28)

**This repo had never been proven to build from scratch.** Two independent
reviewers flagged it: a design review listed clean-install CI as a
prerequisite, and a prior session declined to spin up a disposable cloud
project because it carried a billing cost needing the account owner's
sign-off. The gap stood for weeks while `sql/13`-`sql/18` sat in the repo as
commented-out pseudocode (since rewritten) that had never been executed here.

Done now, at zero cost, on local PostgreSQL 17.10 with pgvector 0.8.5, in an
isolated cluster on a non-default port and its own data directory.

**Result: all 20 files (`sql/00` through `sql/19`) apply clean from an empty
database, in numeric order, first attempt, zero errors.**

Post-replay verification:
- `perimeter_assert()` returns 0 rows.
- Every base table in `public` has RLS enabled — 0 exceptions. (This is the
  check that would have failed before `sql/19`; see the section below.)
- Object inventory: 22 tables, 4 views, 13 public enums, 19
  repo-owned functions (excluding extension-owned).
- **Equivalence with a live deployment confirmed by name, not count:** the
  list of repo-owned functions in the fresh build is character-for-character
  identical to the same list on a live production deployment. Raw object
  *counts* differ and are not a useful comparison — a cloud host's database
  carries its own auth/storage schemas, and extension function counts vary by
  extension version. Compare names, filtered to non-extension objects.
- Only two tables hold rows after replay: `schema_changelog` (the DDL event
  trigger correctly logging the migration run itself) and
  `provenance_registry` (schema configuration). No test fixtures persist.

Enforcement was then exercised on the fresh build, not assumed from schema
shape. 8 checks, all protections confirmed working:
provenance_basis required; an agent cannot claim `human_direct`; an agent
cannot land at `current` without `decision_record`; a bare `UPDATE` to
`current` is rejected; an agent cannot call the promotion function; a human
can; rejection works; and the transaction-local guard is **not** left armed
after a successful promotion (the `SET LOCAL` scope bug fixed on 2026-07-27
stays fixed).

One note on that battery, recorded because the distinction matters: the
bare-`UPDATE` check was initially scored "unexpected" because it was rejected
by the agent-self-attest guard rather than the bounded-transition guard the
test asserted on. The update was blocked — by an earlier layer, with an error
message that points the caller at the sanctioned function. That was a
too-narrow test assertion, not a schema defect. Two independent guards cover
that transition; a test asserting on one specific error string will
mis-attribute which one fired.

**What a local replay cannot prove**, and what therefore remains
cloud-host-specific: default-privilege behavior on newly created objects (the
gap `sql/07` exists to close), and the extension-in-public placement issue
tracked separately. Those stay validated only against a real hosted project.

## Disease-claim false negative — FIXED AND VERIFIED (2026-07-28)

A live deployment's verification pass found a false NEGATIVE in
`compliance_check()`: the sentence "cures anxiety" returned zero findings.
Root cause, confirmed live before fixing: the disease-claim rule's condition
alternation contained `anxiety disorder` but not bare `anxiety`, and its verb
alternation omitted `mitigate` — which is explicit statutory language in
DSHEA 21 U.S.C. 343(r)(6) ("diagnose, mitigate, treat, cure, or prevent").
Named conditions that *were* enumerated (depression, insomnia, "anxiety
disorder") fired correctly, so the rule was not broken — it was incomplete.

**False negatives are the worst failure mode for this tool.** A false positive
annoys a user; a false negative silently permits a regulatory violation. This
was the most serious defect found in the compliance surface to date.

**How it survived two prior verification passes:** both used COMPOUND test
sentences. "cures anxiety and treats depression" passes on the depression
clause, masking the anxiety gap completely. One of those passes then reported
the anxiety rule as verified on that basis — a wrong attribution, not a wrong
result. **Mandatory discipline going forward, recorded in
`tests/20_disease_claim_term_coverage.sql`: one claim term per test sentence,
never compound.** Every enumerated term gets an isolated positive test; every
approved structure/function phrase gets an isolated negative test.

**Fix (two layers, because enumeration alone will always have gaps):**
- *critical*: disease-claim verb + a named disease/disorder. Verb list
  extended with the statutory `mitigate` plus alleviate/relieve/remedy/heal/
  reverse/combat/fight/eliminate/eradicate. Condition list extended from 9
  terms to ~90 covering mental health, sleep, cognitive, cardiovascular,
  metabolic, GI, autoimmune, neurological, oncological and common others.
- *high*: disease-claim verb + a symptom or health-state noun, with no disease
  named. FDA 21 CFR 101.93(g) treats claims about characteristic symptoms of
  a disease as disease claims; this is the construction most often cited in
  supplement warning letters. Scored high rather than critical because some
  phrasings are contextually defensible and need human judgment.

Structure/function verbs (`supports`, `promotes`, `helps maintain`) are
deliberately absent from both verb lists, so approved framing never fires.

**16 isolated tests, all passing:** 8 named-disease terms fire, 3 implied
symptom claims fire, 3 approved structure/function phrasings stay silent, and
both disclaimer regressions from the 2026-07-27 fix still hold (the mandated
disclaimer alone produces zero findings; a real violation in the same text as
the disclaimer still fires).

**Note on where the rules live:** this repo ships the `language_rules` schema
and `compliance_check()` logic but *no seed rules* — rule rows are deployment
data. A consequence worth stating plainly: a fresh install has an empty
ruleset, and `compliance_check()` will report clean on everything until rules
are seeded. `compliance_coverage()` exists to make that visible rather than
mistaking an empty ruleset for a passing grade. Whether a generic starter
ruleset for US dietary-supplement compliance belongs in this repo (the
regulatory citations are public facts, not deployment data) is an open design
question, not an oversight.

## Correctness hardening — APPLIED AND VERIFIED (2026-07-27, same day as the section below)

A live deployment's own diligence pass against this schema found two real
defects in `compliance_check()` (introduced in the "Domain layer" work
below) and one repo-completeness gap. Fixed the same day, each with a test
proving both the bug and the fix -- not just reasoned about.

**Blocker: disclaimer false-positive.** The disease-claim `banned_phrase`
regex (added in `sql/12`) matches the shape of the FDA-mandated disclaimer
sentence itself — "...not intended to diagnose, treat, cure, or prevent any
disease." Net effect: the tool told users to remove the one sentence
regulation requires, on every compliant submission. Confirmed live before
fixing. **Correction to an earlier version of this note:** it claimed Postgres
regex has no lookbehind, and that this forced a function-logic fix. That is
false — Postgres ARE supports both `(?<=)` and `(?<!)`, verified on 17.6. The
`safe_context_pattern` approach is still the right design, but for a different
reason than originally stated: embedding the disclaimer sentence as a negative
lookbehind inside every rule's pattern would duplicate it across rules and make
each pattern nearly unreadable, whereas a declarative exempt-context column is
reusable and inspectable. Choose it for maintainability, not because the
alternative is unavailable. `sql/18` adds a nullable `safe_context_pattern`
column to `language_rules` and, in `compliance_check()`, strips any text
matching a rule's `safe_context_pattern` from a working copy before testing
that rule's pattern against it — so a match that only existed inside known
disclaimer boilerplate disappears, while a real violation elsewhere in the
same text still fires against the same stripped copy. Four tests, all
passing: disclaimer alone (zero findings), compliant copy with disclaimer
(zero findings), a real violation plus the disclaimer (violation flagged,
disclaimer not flagged), a real violation with no disclaimer (both the
violation and `missing_disclaimer` fire, unchanged prior behavior).

**`missing_disclaimer` over-firing.** It previously fired on any input
lacking the disclaimer sentence, including claim-free headlines and
internal notes — noise that trains users to ignore findings. Fixed
(`sql/18`, same migration): only raised when the input is actually
claim-bearing (a `banned_language`/positioning finding fired, an
`ingredient_claims` row matched regardless of pass/fail, or an ingredient
mention appears alongside a generic benefit verb). Two tests: a bare
compliant headline with no claims returns zero findings; a structure/
function claim without the disclaimer still fires it.

**Coverage honesty, not a code bug.** `compliance_check()`'s claim/dose
checking is only as complete as the `ingredient_claims` rows behind it.
Of the six branded ingredients in the example domain module, three had
zero claim rows at the time of this check (their supplier-sent claims
documents exist only as scanned/binary attachments that failed text
extraction, or were never supplied) — meaning a wrong claim or wrong dose
about any of those three would currently pass silently. Not faked or
worked around. Added `compliance_coverage()` (`sql/18`) reporting, per
ingredient, whether claim data exists at all and whether any of it states a
checkable minimum dose, so a clean `compliance_check()` result is never
mistaken for more coverage than it actually has.

**Repo-completeness gap found and closed the same day:** `reject_memory()`
— the third leg of the propose/accept/reject/supersede pattern — had been
added directly to the live database in a separate session and was never
committed to this repo at all. Added as `sql/17`, matching `promote_memory`'s
guard pattern exactly (see below).

**Consistency fix, not a proven live bug:** `reject_memory()`'s guarded
UPDATE was already wrapped in an explicit exception handler that resets the
`app.promoting` guard even if the UPDATE itself raises — more defensive
than `promote_memory`/`supersede_memory`'s original bare set-update-set
sequence. No live failure mode was found that actually exercises the gap
(the natural failure paths in both functions raise before the guard is
ever set), but the risk is structurally real: an exception during the
guarded UPDATE, caught by an outer block in the same transaction, would
otherwise leave the guard armed for whatever runs next in that transaction
— the same class of leak already fixed once for the multi-statement-
transaction case. Closed proactively by adopting `reject_memory`'s pattern
into both functions (`sql/13`, updated) rather than waiting for an incident
to prove it necessary.

**`sql/13`–`sql/18` were also found to be commented-out reference pseudocode
in this repo, not real applicable DDL** — inconsistent with every other file
here, all of which apply cleanly to a real database. Rewritten as real,
executable SQL matching exactly what has been tested live this session
(verified by static collision checks across all files — no naming
collision with `sql/00`–`sql/12`, confirmed via `grep`; full end-to-end
apply against a disposable project was considered and not done, since
spinning one up carries a real billing cost that needs the account owner's
sign-off, not just an agent's judgment call).

## Domain layer + multi-user hardening — APPLIED AND VERIFIED (2026-07-23 / 2026-07-27)

Two deployment sessions against the same live Supabase (PG17) project this
repo tracks. `sql/10` through `sql/16` were applied in order, each tested
against real data before being considered done (not just reasoned about).

**`sql/10`–`sql/12` (2026-07-23):** an example domain layer (a generic
supplier/claims/compliance module — see file headers for the shape) plus a
`compliance_check()` scan RPC. Two real bugs were found and fixed via smoke
testing before any real data touched the schema: (1) a RETURNS TABLE output
parameter sharing a name with a table column caused "ambiguous column"
errors — fixed by table-qualifying every reference. (2) `substring(text FROM
pattern)` is case-sensitive even when the presence check used the
case-insensitive `~*` operator, so a case-insensitive match could still
extract `NULL` — fixed by prefixing the extraction pattern with `(?i)`. A
third, subtler gap was caught by testing two claims on the same evidence
field rather than one: extracting a "stated value" by scanning the *entire*
input let a correct value on one claim mask a wrong value on a different
claim sharing the same unit. Fixed by windowing the extraction around each
claim's own text match instead of scanning the whole input.

**`sql/13` (2026-07-27): promotion deadlock fix.** A human-gated promotion
function (`promote_memory`-equivalent) performs its own sanctioned
status-mutating UPDATE, which was tripping the same provenance-guard trigger
meant to stop an agent from self-attesting a row to "current" — because the
trigger could not distinguish the sanctioned transition from a bare UPDATE
attempting the same thing. Confirmed present on real data before fixing: two
agent-sourced proposed rows with `source_document` provenance could never be
promoted through the sanctioned function. Fixed with a transaction-local GUC
guard, matching the existing `guard_canonical_write`/`app.allow_canonical_write`
precedent from the reference personal-core deployment (see LINEAGE.md).
**A second real bug was found testing the fix itself:** `SET LOCAL` persists
for the remainder of the *transaction*, not just the one guarded statement —
so if the sanctioned function is called as one statement inside a larger
multi-statement transaction, the guard stays armed for everything after it,
silently defeating it for a later bare UPDATE in that same transaction.
Fixed by resetting the guard immediately after the guarded statement, before
the function returns, rather than leaving it set until transaction end.
Regression-tested: the sanctioned promotion path still succeeds and stamps
the promoter; a bare UPDATE attempting the same transition is rejected,
including when run as a later statement in the same transaction as a
successful promotion; the pre-existing agent-cannot-self-attest INSERT rule
is unaffected; a general "no direct status mutation outside sanctioned
functions" guard now also covers non-agent-sourced rows, which the original,
narrower rule did not reach.

**A fourth bug, caught by `get_advisors` after deployment, not by the tests
above:** the new general bounded-status-mutation trigger function landed
with `EXECUTE` granted to `anon`/`authenticated` — directly callable via
`/rest/v1/rpc/`, despite being a trigger function with no legitimate direct
caller. The existing blanket `ALTER DEFAULT PRIVILEGES` (`sql/07`) evidently
does not reach every newly created function automatically. Fixed with an
explicit `REVOKE`. Lesson: run `get_advisors` after *every* migration that
adds a function, even ones "covered" by a standing default-privileges rule —
don't treat that rule as a guarantee.

**Honest limit, stated plainly and not just in this file:** under a single
shared service-role key, this guard is accident-prevention and audit, not
identity enforcement. Any caller sharing that connection can set the same
GUC directly and bypass the human-principal check that precedes it. The real
boundary is per-principal/per-agent connection identity, which this repo
does not yet have (see "Known open risks," unchanged since 2026-07-10).

**`sql/14`: owner/visibility separation.** Adds an `owner` column (whose
working set a row belongs to, for session-boot orientation) separate from a
`visibility` column (a future privacy layer, currently defaulting to a
permissive value). These are deliberately not the same axis: a
visibility-only model was found (on the reference personal-core deployment,
relayed for this repo's benefit — see LINEAGE.md) to leak correctly-shared
rows into every user's boot payload anyway, because nothing filtered by
*owner*. Added owner-scoped wrapper functions (a view cannot take a
parameter) for the ranking and deadline boot surfaces; the original unscoped
views remain as a global/admin reference, not the boot path.
**Isolation tests written and run** (`tests/03_owner_visibility_isolation.sql`,
parameterized by principal id): for each of three distinct principals, the
owner-scoped surfaces return that principal's own private rows plus all
shared rows, and zero rows privately owned by a different principal.
Confirmed by running the test, not assumed from the schema shape.

**`sql/15`: hot-index eviction defect.** The hot/attention index's
promote-from-staging step deleted the lowest-ranked row whenever a fixed
row cap was reached, silently losing history. Fixed by removing the
delete-on-cap-reached step entirely; the index table now grows unbounded,
and the row cap is enforced only in the read-side ranking view (`LIMIT`),
not the write path. Verified: pushed 18 topics through in one test where the
old cap was 15; all 18 remained in the index table afterward. **No migration
recovers rows evicted before this fix** — that history is genuinely gone;
noted here rather than glossed over.

**`sql/16`: whitespace-class rejection.** Added `CHECK (<col> !~ '^\s*$')`
on required text columns. A `btrim()`-only emptiness check (not present in
this repo before this file, but worth guarding against regardless) only
strips spaces by default — a value of solely tabs/newlines would pass such a
check while still being functionally empty. NULL is unaffected; this only
rejects a non-NULL whitespace-only value. Applied and validated against all
existing rows with zero constraint violations.

**Evidence-locator audit (report-only, no schema change):** scanned every
citation-style value across the deployment this session. Categories that
embed a database-checkable reference (an internal-artifact id, a
cross-referenced record id) were spot-checked for resolvability and came
back 100% resolvable. A meaningful minority of citations are prose
"recorded by X in session Y" references with no independently checkable
locator at all — not necessarily wrong, but not tooling-resolvable, which is
exactly the trap worth naming rather than assuming away (a NOT NULL
citation column proves a string is present, not that it resolves to
anything real). No correction was made to any citation this pass — the
constraint is "report classification, never invent a replacement locator."

## Postgres 17 / Supabase validation — APPLIED AND VERIFIED (2026-07-10)

`sql/00` through `sql/06` were applied in order, via migration, to a real
Supabase project running Postgres 17.6. All seven files applied clean —
zero PG17-specific errors, no fix-forward needed for the 00-06 set.

All 8 Phase 1 acceptance tests plus 4 import-framework tests (raw_artifacts
dedup, source_artifact_id linkage, promote_memory human-gating including the
agent-rejected and non-proposed-rejected cases, and the sunset_ready
regression check for the landed-less-than-expected case) were run for real
against the live project, inside a transaction that was rolled back
afterward so no test fixtures persist in the deployed database.

**Two of the twenty tests failed on first run — both were the exact
Supabase-specific gap this file's "Not yet tested" section predicted:**
`perimeter_assert()` did not return zero rows, and table grants to
anon/authenticated were not zero. Root cause: earlier migrations revoked
grants table-by-table as each table was created, which reliably covers
tables but misses (a) views, which get their own default-privilege grant
independent of their base tables, and (b) any table accidentally left out
of a REVOKE list by hand. Concretely: 4 views (capability_grants_active,
deadlines_upcoming, import_cutover_scorecard, memory_hot_ranked) and
1 table (schema_changelog) were exposed to anon/authenticated with full
privileges (SELECT/INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER) before
this was caught.

**Fixed forward, this session:** `sql/07_default_privileges.sql` —
(1) `ALTER DEFAULT PRIVILEGES` for both tables and functions in `public`,
so this class of gap cannot recur for anything created after this file
runs, and (2) a one-time remediation sweep that revokes all grants on every
table/view that already existed, closing the gap on the 5 objects above.
Verified via the canary procedure the work order specified: a throwaway
table and throwaway function with zero explicit revokes both showed up in
`perimeter_assert()` before `sql/07`, zero grants after. Re-ran the full
test battery after the fix — all 20 tests pass.

**`sql/08_advisor_fixes.sql`** — Supabase's security advisor
(`function_search_path_mutable`) caught one function, `log_ddl_change()`
(the DDL changelog's event trigger function), that was missed when every
other function in this repo got `set search_path = public`. Fixed and
verified; advisor finding cleared on re-run.

**Known residual gap, not fixed this session:** the function-level revoke
in `sql/07` cannot reach functions owned by a different role than the one
running the migration (Postgres silently no-ops a REVOKE the executing role
lacks authority over — WARNING, not an error). On this Supabase project,
~118 functions belonging to the `vector` and `pgcrypto` extensions are
owned by `supabase_admin`, not the migration role, and still show EXECUTE
granted to anon/authenticated. This is the advisor's `extension_in_public`
finding (vector was installed with no schema, landing in `public`) — a
structural fix (relocate the extension), not a privileges bug, and not
something to force through without dedicated regression testing of vector
operations afterward. Tracked as a GitHub issue rather than patched here.

**Advisor triage in full:** 13× `rls_enabled_no_policy` (INFO) across every
core table — expected and already documented below under "RLS policies...
not written yet"; tracked as its own issue rather than 13. 1×
`function_search_path_mutable` (WARN) — fixed, see above. 1×
`extension_in_public` (WARN) — tracked as an issue, see above.

## Phase 0 — Core knowledge layer: APPLIED AND VERIFIED (vanilla Postgres 16)

- [x] `sql/00_extensions.sql`, `sql/01_core.sql` written
- [x] Applied cleanly to a fresh Postgres 16 database, zero errors, on the
      second attempt (first attempt failed — see "Bugs found and fixed")

## Phase 1 — Multi-user foundation: APPLIED AND VERIFIED (vanilla Postgres 16)

- [x] `sql/02_principals.sql` — applied clean
- [x] `sql/03_provenance.sql` — applied clean
- [x] `sql/04_temporal.sql` — applied clean
- [x] `sql/05_perimeter_assert.sql` — applied clean AFTER a fix (see below)
- [x] All 8 acceptance tests run for real and passed:
  1. `perimeter_assert()` returns zero rows on a freshly-applied schema
  2. `memories` insert with `provenance_basis = null` rejected
  3. `source_kind='agent'` + `provenance_basis='human_direct'` rejected
  4. agent landing at `status='current'` without `decision_record` basis rejected
  5. `has_capability()` true for active grant, false after `revoked_at` set
  6. `supersede_memory()` correctly closes old row, links new row via
     `supersedes`, old row stays readable
  7. `capability_grant_audit` captured both the INSERT and the revoke UPDATE
  8. zero table grants to anon/authenticated after full apply

## Bugs found and fixed during the test pass

1. **`anon`/`authenticated` roles don't exist on vanilla Postgres.** Every
   REVOKE in the original draft targeted Supabase-specific roles. Fixed in
   `sql/00_extensions.sql` with a `DO` block that creates `anon`,
   `authenticated`, and `service_role` as shim roles if missing. This makes
   the repo portable to non-Supabase Postgres.
2. **`perimeter_assert()`'s function-grant check referenced
   `pg_proc_acl_expanded`, which does not exist** on Postgres 16 (or, as far
   as could be determined, any version). Replaced with a working
   `aclexplode(p.proacl)` query against `pg_proc` directly. Confirmed working
   — see acceptance tests 1 and 8 above.

Both bugs would have surfaced on first real deployment. Finding them in a
disposable environment first is the point of testing before calling
something done.

## Not yet tested (explicitly still open)

- ~~Not tested against Supabase specifically.~~ **Done 2026-07-10** — see
  "Postgres 17 / Supabase validation" above. The predicted failure mode
  (auto-grants on new public tables) was real, found the same session it was
  tested for, and closed with `sql/07_default_privileges.sql`.
- **No upgrade path for an existing deployment.** This repo assumes a fresh
  database. A live deployment with its own migration history predating
  principals, capability grants, and provenance_basis needs a written,
  branch-tested upgrade path before any of this touches it. That path is
  deployment-specific and belongs with the deployment, not in this repo.
- **RLS policies referencing `has_capability()` are not written yet.**
  `sql/02_principals.sql` defines the function; no table ships with a policy
  using it (RLS on the core tables is currently default-deny via blanket
  REVOKE, which is safe but not yet capability-aware). The policy template
  is in `docs/01-architecture.md`.

## Known open risks

- **A shared service-role connection remains the real boundary until
  per-principal or per-agent connection paths exist.** Rows in `principals`
  and `capability_grants` mean nothing if everything authenticates as one
  service-role key. Closing this requires a connection-identity decision
  (auth-provider UUIDs mapped to principal ids, per-agent keys resolved
  through an RPC, or per-agent database roles) — an infrastructure decision,
  not a SQL file. It is the single most important open item before Phase 1
  can honestly be called complete.
- **Parity creep** with the personal-core sibling repo: adopt patterns
  deliberately, record them in LINEAGE.md, stop there. Do not structurally
  sync the two.
- **Schema/data discipline:** nothing deployment-specific ever lands in this
  repo. If a change you're making requires naming a real person, project, or
  incident, it belongs in the deployment's database or private ops notes.
