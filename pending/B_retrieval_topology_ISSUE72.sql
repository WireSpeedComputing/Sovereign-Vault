-- PENDING OWNER APPROVAL — DO NOT APPLY
--
-- Migration B for upstream issue #72: fail closed on single-store misses and
-- expose topology. Placed in pending/ for the same reason as Migration A:
-- sql/*.sql is globbed by the replay harness.
--
-- ############################################################
-- STATUS: PARTIALLY BUILT. Read this before assuming otherwise.
--
--   PART 1 (below) — retrieval_topology table + seed rows.
--     Dry-run tested against the live database inside a rolled-back
--     transaction on 2026-08-07. Assertions passed, zero residue. NOT applied.
--
--   PART 2 — the retrieve_context() envelope change.
--     DESIGNED ONLY. NOT WRITTEN, NOT TESTED. The design intent is recorded at
--     the bottom of this file. Whoever picks this up must build and test it;
--     do not treat Part 1 passing as evidence that Part 2 works.
--
-- Recording this split explicitly because the work order that referenced
-- "Migration B" implied a complete, tested artifact. It is not one. Half of it
-- is a design note.
-- ############################################################
--
-- WHY THIS EXISTS: retrieve_context() currently returns
-- retrieval_status='evaluated' with units_matched=0 for a query that found
-- nothing locally. That reads as "nothing exists". It only ever searched this
-- store, while an external agent channel, a frozen predecessor store, and a
-- document corpus outside the database still hold material. A locally correct
-- negative is being broadened into an unsupported global negative.
--
-- Topology is table-driven rather than hardcoded in the function so the schema
-- stays generic and publishable while the rows remain deployment data.

-- ---------------------------------------------------------------- PART 1
CREATE TABLE retrieval_topology (
  id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_key                 text UNIQUE NOT NULL,
  store_role                text NOT NULL CHECK (store_role IN
                              ('primary','peer','frozen_source','external_channel','file_corpus')),
  queryable_by_this_runtime boolean NOT NULL DEFAULT false,
  default_coverage_state    text NOT NULL DEFAULT 'not_queried' CHECK (default_coverage_state IN
                              ('queried','not_queried','unreachable','unknown')),
  notes                     text,
  status                    record_status NOT NULL DEFAULT 'current',
  created_at                timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE retrieval_topology ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON retrieval_topology FROM anon, authenticated;

-- Seed rows are deployment data. Store keys are deliberately generic labels,
-- not deployment identifiers, so this file stays publishable.
INSERT INTO retrieval_topology
  (store_key, store_role, queryable_by_this_runtime, default_coverage_state, notes) VALUES
 ('local-knowledge-store','primary',        true,  'queried',
    'This deployment. The only store retrieve_context can reach.'),
 ('external-agent-channel','external_channel', false, 'not_queried',
    'Separate runtime holding coordination traffic and unmigrated records.'),
 ('frozen-import-source','frozen_source',   false, 'not_queried',
    'Read-only predecessor store retained for migration provenance.'),
 ('document-corpus','file_corpus',          false, 'unknown',
    'Filesystem/document repository outside the database; no adapter configured.');

-- ---------------------------------------------------------------- PART 2
-- NOT IMPLEMENTED. Design intent for retrieve_context()'s envelope:
--
--   * add "topology": { schema_version, stores: [ {store_key, store_role,
--     coverage_state} ] }, derived from retrieval_topology, never hardcoded.
--   * add "unqueried_stores": array of store_key where the runtime cannot
--     query. Must be populated from the table, not assumed empty.
--   * add "global_completeness": boolean. FALSE whenever any current topology
--     row is not queryable_by_this_runtime. With the seed above it is always
--     false today, which is the honest answer.
--   * upstream #72 item 3 requires that a single-store miss must not render as
--     "nothing found everywhere". A zero-match result while
--     global_completeness is false must be distinguishable in the envelope
--     from a zero-match result under full coverage. Consider a distinct
--     retrieval_status value rather than relying on the caller to read a
--     boolean it may ignore.
--   * upstream #72 item 2 requires coverage states to distinguish queried,
--     not_queried, unreachable, and unknown. The CHECK above enforces the
--     vocabulary; the envelope must surface it rather than collapsing to a
--     yes/no.
--   * upstream #72 item 6: any static fallback may carry only minimal
--     non-secret routing hints and must be labelled fallback, never authority.
--
-- Tests required before this is considered built: local hit, remote-store
-- hit (synthetic), partial miss, complete miss, unreachable peer, unknown
-- topology, and proof that a private peer's existence is not disclosed to an
-- unauthorized principal.
