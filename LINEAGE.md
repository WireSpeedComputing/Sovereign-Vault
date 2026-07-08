# Lineage

This repo is seeded from the architecture published in
[jryski/sovereign-memory-core](https://github.com/jryski/sovereign-memory-core)
(personal, single-principal knowledge layer) and from a live multi-user
business deployment on Supabase (two dozen production migrations over
roughly six weeks). It is a new repository, not a fork or branch.

## Why not a fork

Personal and business have permanently different trust models. The personal
core assumes one owner and one trust boundary; the business core exists
specifically because that assumption breaks with more than one person. A git
fork implies shared history and upstream merges, which invites "keep it in
sync" pressure — a parity trap this project explicitly rejects. Patterns
transfer deliberately, via this document and direct review, not via git merge.

## Adopted as-is (structurally identical concept, reimplemented independently)

- Tiered structure: a generic knowledge/coordination layer, separate from
  domain-specific canonical tables ("bring your own schema").
- Provenance as a first-class, database-enforced concept rather than an
  agent-discipline convention.
- Corrections supersede; nothing is silently rewritten.
- Vector search treated as a regenerable cache, never system of record.
- Preserve-then-normalize import discipline for adopting external sources
  (referenced in docs/01-architecture.md; not yet built out here — see
  STATUS.md).

## Adapted (same goal, different mechanism)

- **Provenance basis** (`sql/03_provenance.sql`) generalizes a hardcoded
  financial-provenance trigger from the reference deployment — built after a
  fabricated figure in agent-generated output was caught in production —
  into a registry-driven pattern any table can opt into.
- **Temporal truth** (`sql/04_temporal.sql`): a multi-user business needs
  "when was this true" answered independently of "when did we record it,"
  which single-principal personal use doesn't force.

## New in this repo, not present in the personal core

- **Principals and capability grants** (`sql/02_principals.sql`). The personal
  core has no concept of multiple humans with different access; this is the
  entire reason the business version exists. See STATUS.md for the open
  question this doesn't fully close (shared service-role connection).
- **Perimeter assert covering table grants** (`sql/05_perimeter_assert.sql`).
  Built in response to a production finding: Supabase auto-grants SELECT to
  `anon`/`authenticated` on new `public` tables by default, and a perimeter
  check that only inspects function execute grants misses this entirely.
  That finding is why this file checks both.

## Explicitly NOT carried over

- Any single-owner assumption. Nothing in this repo should ever assume there
  is exactly one human principal.
- Personal-domain schemas (household, homelab, etc.) — out of scope entirely.
- Any of the reference deployment's data. Schema in the repo, data in the
  database — see README.

## A note on accuracy

This document describes the personal core based on its published README, not
a file-by-file diff of its SQL. If any claim above about that repo's
internals turns out to be wrong once someone actually diffs the two, this
document is what to correct.
