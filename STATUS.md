# STATUS

Last updated: 2026-07-28. See "Disease-claim false negative" below for the most
recent work. Phase 0 and Phase 1 SQL were applied to a real PostgreSQL 16
instance (Ubuntu, pgvector 0.6.0) and all 8 Phase 1 acceptance tests were
executed for real, not just reasoned about. Results below. This was NOT
tested against Supabase at that time — see "Not yet tested" (2026-07-08
version), now superseded by the Postgres 17 / Supabase validation below.

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
fixing. Postgres regex has no lookbehind, so this needed a function-logic
fix, not a pattern tweak: `sql/18` adds a nullable `safe_context_pattern`
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
