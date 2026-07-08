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

Phase 0 and Phase 1 (see below) were applied to a real PostgreSQL 16 instance
and all Phase 1 acceptance tests pass there. **Not yet validated against
Supabase specifically.** See `STATUS.md` for the honest checklist before this
is trusted with real business data.

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
docs/01-architecture.md      concepts, "bring your own schema" contract for
                              domain tables, temporal/supersede pattern template
docs/02-onboarding-principals.md   template for registering humans and agents
                              with scoped capabilities (placeholders only —
                              your real roster is data, not repo content)
```

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
2. Run `sql/00_extensions.sql` through `sql/05_perimeter_assert.sql` in order.
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
