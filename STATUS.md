# STATUS

Last updated: 2026-07-10. Phase 0 and Phase 1 SQL were applied to a real
PostgreSQL 16 instance (Ubuntu, pgvector 0.6.0) and all 8 Phase 1 acceptance
tests were executed for real, not just reasoned about. Results below. This
was NOT tested against Supabase at that time — see "Not yet tested" (2026-07-08
version), now superseded by the Postgres 17 / Supabase validation below.

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
