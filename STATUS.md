# STATUS

Last updated: 2026-07-08. Phase 0 and Phase 1 SQL were applied to a real
PostgreSQL 16 instance (Ubuntu, pgvector 0.6.0) and all 8 Phase 1 acceptance
tests were executed for real, not just reasoned about. Results below. This
was NOT tested against Supabase specifically — see "Not yet tested."

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

- **Not tested against Supabase specifically.** Supabase's Postgres has
  additional preconfigured roles, extensions, and default-privilege behavior
  (including auto-granting SELECT to anon/authenticated on new public
  tables) that a vanilla PG16 instance does not reproduce exactly. Before
  trusting this on a real Supabase project: run the same 8 tests there, and
  additionally create a throwaway table with no explicit revokes and confirm
  `perimeter_assert()` catches its auto-grants — that's the exact failure
  mode this file exists to detect.
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
