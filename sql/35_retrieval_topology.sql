-- APPLIED as deployment migration 42 (2026-08-07)
--
-- MIGRATION: 42_retrieval_topology_issue72
--
-- APPLIED 2026-08-07 as migration 42, immediately before migration 43.
--
-- Migration B for upstream issue #72: fail closed on single-store misses and
-- expose topology. Placed in pending/ for the same reason as Migration A:
-- sql/*.sql is globbed by the replay harness.
--
-- ############################################################
-- STATUS
--
--   PART 1 — retrieval_topology table + seed rows.
--     Dry-run tested against the live database inside a rolled-back
--     transaction on 2026-08-07. Assertions passed, zero residue. NOT applied.
--
--   PART 2 — the retrieve_context() envelope change.
--     BUILT AND TESTED 2026-08-07 (WO-08 Task 8), having been a design note
--     until then. Assertions in pending/B_retrieval_topology_TEST.sql, all
--     passing on a fresh PG17 replay with Part 1 applied. NOT applied.
--
-- ⚠ PART 2 IS A PUBLIC SIGNATURE CHANGE to the most widely-used function in
-- this schema. The envelope gains three keys and retrieval_status gains a THIRD
-- VALUE. Any caller that switches exhaustively on retrieval_status, or validates
-- the envelope against a closed schema, breaks. Under docs/08's rule that is a
-- MAJOR bump requiring the pre-DDL instruction probe. It is the fourth
-- #70-class signature change identified in this project and the first one
-- caught BEFORE it shipped rather than after.
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
--
-- ── THE DESIGN DECISION THAT MATTERS ───────────────────────────────────────
-- The original design note proposed a `global_completeness` boolean and left
-- retrieval_status alone. That was rejected while building this.
--
-- #72 item 3 requires that a single-store miss not render as "nothing found
-- everywhere". A boolean the caller may ignore does not achieve that: the
-- existing envelope already reports units_matched=0 honestly, and the failure
-- mode is not that the number is wrong, it is that a CORRECT number is read as
-- a stronger claim than it supports. Adding another field a caller can skip
-- reproduces the problem one key over.
--
-- So retrieval_status itself carries it, as a third value:
--
--   not_evaluated              nothing was searched (empty query, or no units
--                              visible to this principal)
--   evaluated                  searched, AND every advertised store was reachable
--   evaluated_partial_coverage searched what this runtime can reach; one or more
--                              advertised stores were NOT queried
--
-- A caller that only knows the old vocabulary sees an unrecognised status and
-- must decide what to do, which is the correct failure mode for a fail-closed
-- contract. A caller that silently treats an unknown status as "evaluated" was
-- going to over-claim anyway.
--
-- Note that evaluated_partial_coverage applies to HITS as well as misses. That
-- is deliberate: finding something locally is not evidence that nothing more
-- exists elsewhere, and a status that flipped to 'evaluated' on a hit would
-- teach callers that a hit means complete coverage.
--
-- With the Part 1 seed, global_completeness is always false and the status is
-- therefore always evaluated_partial_coverage. That is the honest answer today,
-- not a bug: three of the four advertised stores genuinely cannot be queried
-- from here.
--
-- ── WHAT IS DELIBERATELY NOT EXPOSED ───────────────────────────────────────
-- #72 item 4 requires that private topology detail not reach an unauthorised
-- viewer. retrieval_topology.notes describes what each store IS -- "separate
-- runtime holding coordination traffic", "read-only predecessor store" -- which
-- is deployment intelligence, not routing information a caller needs.
--
-- The envelope exposes store_key, store_role and coverage_state, and NEVER
-- notes. Asserted in the test file rather than left to reviewer vigilance,
-- because a later `select *` refactor is exactly how such a field escapes.

CREATE OR REPLACE FUNCTION retrieve_context(
  p_principal_id    uuid,
  p_query           text,
  p_query_embedding vector(384) default null,
  p_budget_chars    int default 8000,
  p_max_units       int default 20
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $fn$
declare v_out jsonb;
begin
  if p_principal_id is null then
    raise exception 'retrieve_context requires a principal';
  end if;
  if not exists (select 1 from principals where id = p_principal_id and active) then
    raise exception 'principal % is not active', p_principal_id;
  end if;

  with vis as (
    -- FILTER BEFORE RANK
    select ru.* from retrieval_units ru
    where ru.invalidated_at is null
      and ru.record_status = 'current'
      and is_owner_or_shared(ru.owner, ru.visibility, p_principal_id)
  ),
  emb_avail as (
    select exists (
      select 1 from retrieval_embeddings e join vis v on v.id = e.retrieval_unit_id
      where e.stale_at is null and e.embedding is not null
    ) as ok
  ),
  q as (
    select case when p_query is null or length(trim(p_query)) = 0 then null
                else websearch_to_tsquery('english', p_query) end as tsq
  ),
  -- Topology is read fresh on every call: a store going unreachable must change
  -- the next answer, not the next deployment.
  topo as (
    select t.store_key, t.store_role, t.queryable_by_this_runtime,
           t.default_coverage_state
    from retrieval_topology t
    where t.status = 'current'
  ),
  ev as (
    select ((select count(*) from vis) > 0 and (select tsq from q) is not null) as evaluated
  ),
  complete as (
    -- No topology rows at all means nothing has been declared unreachable, so
    -- there is nothing to warn about. An empty table is not a claim of
    -- completeness, it is the absence of a claim; coalescing to true keeps a
    -- deployment that never configured topology behaving exactly as it does now.
    select coalesce(bool_and(t.queryable_by_this_runtime), true) as ok from topo t
  ),
  fts as (
    select v.id, ts_rank(v.fts, q.tsq) as s,
           row_number() over (order by ts_rank(v.fts, q.tsq) desc, v.id) as r
    from vis v cross join q
    where q.tsq is not null and v.fts @@ q.tsq
  ),
  vec as (
    select v.id, 1 - (e.embedding <=> p_query_embedding) as s,
           row_number() over (order by (e.embedding <=> p_query_embedding) asc, v.id) as r
    from vis v
    join retrieval_embeddings e on e.retrieval_unit_id = v.id
    where p_query_embedding is not null and e.stale_at is null and e.embedding is not null
  ),
  ranked as (
    select coalesce(f.id, x.id) as id,
           coalesce(1.0/(60 + f.r), 0) + coalesce(1.0/(60 + x.r), 0) as rrf,
           f.s as fts_score, x.s as vec_score
    from fts f full outer join vec x on x.id = f.id
  ),
  capped as (
    select r.id, r.rrf, r.fts_score, r.vec_score,
           row_number() over (order by r.rrf desc, r.id) as rn,
           sum(length(v.rendered_text)) over (order by r.rrf desc, r.id) as running
    from ranked r join vis v on v.id = r.id
    order by r.rrf desc, r.id
    limit greatest(p_max_units, 0)
  ),
  kept as (
    -- The top match always survives the budget. If it alone exceeds the budget
    -- its text is truncated and flagged, so a query that matched can never
    -- return an empty array -- the shape a caller misreads as "nothing found".
    select c.rrf, c.fts_score, c.vec_score, c.rn,
           v.exact_locator, v.source_relation, v.source_id, v.unit_kind, v.ordinal,
           v.workstream, v.provenance_basis, v.citation, v.effective_from,
           case when c.rn = 1 and length(v.rendered_text) > p_budget_chars
                then left(v.rendered_text, p_budget_chars)
                else v.rendered_text end as rendered_text,
           (c.rn = 1 and length(v.rendered_text) > p_budget_chars) as text_truncated
    from capped c join vis v on v.id = c.id
    where c.running <= p_budget_chars or c.rn = 1
  )
  select jsonb_build_object(
    'retrieval_status', case
        when not (select evaluated from ev)      then 'not_evaluated'
        when (select ok from complete)           then 'evaluated'
        else 'evaluated_partial_coverage' end,
    'reason', case
        when (select count(*) from vis) = 0 then 'no_retrieval_units_visible_to_principal'
        when (select tsq from q) is null    then 'empty_query'
        when not (select ok from complete)  then 'one_or_more_advertised_stores_not_queried'
        else null end,
    'mode', case
        when not (select evaluated from ev) then null
        when p_query_embedding is not null and (select ok from emb_avail) then 'hybrid'
        else 'fts_only' end,
    'principal_id', p_principal_id,
    'units_visible', (select count(*) from vis),
    'units_matched', (select count(*) from ranked),
    'units_returned', (select count(*) from kept),
    'embeddings_available', (select ok from emb_avail),
    'budget_chars', p_budget_chars,
    'budget_used', coalesce((select sum(length(k.rendered_text)) from kept k), 0),
    'truncated', (select count(*) from ranked) > (select count(*) from kept),
    -- ── #72 additions ──
    'global_completeness', (select ok from complete),
    'topology', jsonb_build_object(
      'schema_version', '1',
      'stores', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'store_key', t.store_key,
                 'store_role', t.store_role,
                 -- The local store's coverage is a fact about THIS call, not a
                 -- static property: if nothing was evaluated then nothing was
                 -- queried, and saying otherwise is the same over-claim this
                 -- migration exists to remove.
                 'coverage_state', case
                    when t.queryable_by_this_runtime
                      then case when (select evaluated from ev) then 'queried' else 'not_queried' end
                    else t.default_coverage_state end)
               order by t.store_key)
        from topo t), '[]'::jsonb)),
    'unqueried_stores', coalesce((
      select jsonb_agg(t.store_key order by t.store_key)
      from topo t where not t.queryable_by_this_runtime), '[]'::jsonb),
    'results', coalesce((
       select jsonb_agg(to_jsonb(k) - 'rn' order by k.rrf desc) from kept k
    ), '[]'::jsonb)
  ) into v_out;

  return v_out;
end; $fn$;

REVOKE EXECUTE ON FUNCTION retrieve_context(uuid, text, vector, int, int)
  FROM anon, authenticated, public;

COMMENT ON FUNCTION retrieve_context(uuid, text, vector, int, int) IS
  'Governed retrieval over the local store. retrieval_status is one of not_evaluated, evaluated, evaluated_partial_coverage -- the third means one or more advertised stores in retrieval_topology could not be queried, so a zero-match result is NOT evidence of global absence. Exposes store_key/store_role/coverage_state per store and never retrieval_topology.notes.';
