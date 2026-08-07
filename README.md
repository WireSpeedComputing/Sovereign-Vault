# Sovereign Vault

A self-hosted knowledge and operations backend for AI-heavy businesses, built
on plain Postgres. Facts, decisions, and operational state live in a database
the business owns outright — not inside Claude, ChatGPT, or any vendor's
memory silo. Any authorized model or application is a client, never an owner.

This is the multi-user business counterpart to
[jryski/sovereign-memory-core](https://github.com/jryski/sovereign-memory-core),
a personal single-principal knowledge layer. See `LINEAGE.md` for exactly what
was adopted, adapted, or intentionally left out. **This is a new repo, not a
fork** — the two are expected to diverge permanently. Personal and business
have different trust models and should not chase feature parity.

## The rule this repo lives by

**Schema in the repo. Data in the database.** This repo contains DDL,
enforcement functions, docs, and templates. It never contains principals,
grants, scopes, incidents, personnel facts, project identifiers, or anything
else describing a real deployment. If you're about to commit a real person's
name or a real project reference, you're holding data — put it in the
database the schema exists to create.

## Why this exists

1. **Data sovereignty.** Facts live in a database you control, exportable as
   plain SQL and JSON. Switching AI vendors is a config change, not a
   migration crisis.
2. **Best tool for the job.** Any authorized model or application with a safe
   Postgres path reads and writes the same store.
3. **Verifiable source of truth.** Every fact carries provenance. Consequential
   tables reject unsourced writes at the database level, not by agent
   discipline. Corrections supersede; nothing is silently rewritten.
4. **Multiple humans, multiple agents, one boundary.** Principals and
   capability grants make "who can do what" an explicit, reviewable row —
   never implied by role or team membership.

## Status

Applied and validated against both vanilla PostgreSQL 16 and a real Supabase
project running PostgreSQL 17. All Phase 1 acceptance tests plus the
import-framework tests pass on both. The domain-layer example, compliance
scanning, promotion/rejection governance, and owner-scoped boot surfaces are
also applied and tested — see `STATUS.md`, which is the authoritative
record and lists every defect found and fixed along the way.

**Read `STATUS.md`'s "Known open risks" before trusting this with real
business data.** The private identity-binding layer now exists, but it ships
with zero bindings and zero grants. Until real Auth/OAuth tokens are verified
and reviewed bindings are activated, shared administrative connections remain
control-plane authority rather than attributable identity.

## Repo map

```
README.md                    you are here
STATUS.md                    what's drafted vs. applied vs. tested
LINEAGE.md                   relationship to sovereign-memory-core
sql/00_extensions.sql        vector, pgcrypto, role shims for non-Supabase PG
sql/01_core.sql              Phase 0: memories, wiki, hot index, deadlines,
                              doc integrity, enforced DDL changelog, RLS lockdown
sql/02_principals.sql        Phase 1: principals, capability grants, audit trail
sql/03_provenance.sql        Phase 1: provenance_basis enforcement,
                              agent-cannot-self-attest guard
sql/04_temporal.sql          Phase 1: temporal truth columns, supersede_memory()
sql/05_perimeter_assert.sql  Phase 1: perimeter check covering BOTH table grants
                              and function grants (Supabase auto-grants SELECT
                              to anon/authenticated on new public tables by
                              default; function-only checks miss it)
sql/06_import.sql            import framework: preserve-then-normalize,
                              import batches, raw artifacts, human-gated
                              promotion, cutover scorecard
sql/07_default_privileges.sql  ALTER DEFAULT PRIVILEGES hardening + one-time
                              remediation sweep (closes the Supabase auto-grant
                              class of gap for anything created afterward)
sql/08_advisor_fixes.sql     pin search_path where the advisor flagged it
sql/09_review_queue.sql       contradiction / confirmation queue: imports and
                              agents never silently pick a side
sql/10-12                    EXAMPLE domain layer (supplier/claims/compliance
                              module) + compliance_check() scan RPC. Illustrates
                              the "bring your own schema" contract; replace with
                              your own domain.
sql/13-16                    promotion-deadlock fix (transaction-local guard),
                              owner/visibility separation + owner-scoped boot
                              surfaces, hot-index destructive-eviction removal,
                              whitespace-class rejection
sql/17_reject_memory.sql     the third leg of propose/accept/reject/supersede
sql/18                       compliance_check disclaimer false-positive fix
                              (safe_context_pattern) + compliance_coverage()
sql/19_schema_changelog_rls.sql  RLS on the DDL changelog table
sql/20-22                    transition custody, governed retrieval, and
                              wiki-page source-agent parity
sql/23_identity_capability_enforcement.sql  private fail-closed identity
                              bindings and dual human/agent authorization
tests/                       isolation and compliance regression tests, meant
                              to be RUN, not read. See the header of
                              tests/20_* for the one-term-per-test discipline
                              and why it exists.
docs/01-architecture.md      concepts, "bring your own schema" contract for
                              domain tables, temporal/supersede pattern template
docs/02-onboarding-principals.md   template for registering humans and agents
                              with scoped capabilities (placeholders only —
                              your real roster is data, not repo content)
docs/03-identity-capability-enforcement.md  threat model, exposure boundary,
                              activation gates, and deployment/data split
```

Note: file numbering here is cumulative-by-topic and does not map 1:1 to a
deployment's applied-migration numbering. Several live fix-migrations are
folded into the file they correct rather than committed one-per-migration.
Verify a deployment against these files by content, not by name — a
name-matching audit missed a real RLS gap that only a content grep caught.

## What's deliberately NOT here

- Any real deployment's data: no principals, no grants, no project IDs, no
  personnel history. See "The rule this repo lives by."
- No domain tables (products, orders, suppliers, whatever your business
  tracks). Those are yours to add, following the contract in
  `docs/01-architecture.md` — temporal columns, a `supersede_*()` function
  instead of direct UPDATE, and registration in `provenance_registry` if the
  table is consequential.
- No RAG framework, no agent framework, no UI. This is a data layer with
  enforced rules.
- Vector search is a regenerable cache. Never treat it as the system of record.

## Quick start

1. Create a Supabase project or vanilla Postgres 15+ database.
2. Run `sql/00_extensions.sql` through
   `sql/23_identity_capability_enforcement.sql` in
   numeric order. `sql/10`–`sql/12` are an example domain module — skip or
   replace them with your own domain schema.
3. Register your own principals (`docs/02-onboarding-principals.md` has the
   template) — do not skip this and use only the service-role key for
   everything, or multi-user is cosmetic.
4. Run `select * from perimeter_assert();` and confirm it returns zero rows
   for anything you didn't explicitly intend.
5. Add your domain tables following `docs/01-architecture.md`.

## License / provenance

Extracted from a live multi-user business deployment and genericized.
Architecture partly derived from
[jryski/sovereign-memory-core](https://github.com/jryski/sovereign-memory-core)'s
published design (see LINEAGE.md). Use freely. No warranty. Read
`docs/01-architecture.md` — especially the open question at the end —
before putting anything sensitive in it.
