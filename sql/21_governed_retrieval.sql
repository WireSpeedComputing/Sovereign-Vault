-- 21_governed_retrieval.sql
--
-- The recall half of the system. Before this, embedding columns and HNSW
-- indexes existed on canonical tables with NO function querying them: storage
-- without retrieval.
--
-- Design: canonical rows stay authoritative. Retrieval units and embeddings are
-- DISPOSABLE DERIVED PROJECTIONS, rebuildable at any time, so a chunking change
-- or an embedding-model migration never touches the system of record.
-- Embeddings live in their own table keyed by model identity, so adopting a new
-- model is an additive row rather than a destructive overwrite of one vector
-- column, and two models can be compared side by side.
--
-- Two properties are load-bearing:
--   1. Principal/owner/visibility filtering happens BEFORE ranking, in its own
--      CTE. Ranking never sees a row the principal cannot see, so neither a
--      relevance score nor a match count can leak the existence of another
--      principal's private record.
--   2. retrieve_context returns a jsonb envelope, never a bare rowset. A bare
--      empty rowset is indistinguishable from "nothing relevant exists". The
--      envelope always reports what was searched, in which mode, and whether
--      the budget truncated anything, so "evaluated with 0 matches" is
--      distinguishable from "not evaluated at all".
--
-- Hybrid by design, FTS-capable today: there is no embedding pipeline yet, so
-- the caller supplies p_query_embedding when it has one. Without an embedding
-- the mode is reported as fts_only rather than silently implying semantic
-- recall happened. Fusion is reciprocal rank fusion, which needs no score
-- calibration between two incomparable scales.

create table retrieval_units (
  id                  uuid primary key default gen_random_uuid(),
  source_relation     text not null check (source_relation in ('memories','wiki_pages')),
  source_id           uuid not null,
  source_content_hash text not null,   -- detects source drift without reading the source
  unit_kind           text not null,   -- memory_atom | wiki_section
  ordinal             int  not null default 0,
  exact_locator       text not null,   -- points at a record, not "a similar document"
  rendered_text       text not null,
  fts                 tsvector generated always as (to_tsvector('english', rendered_text)) stored,
  owner               uuid references principals(id),
  visibility          visibility_level not null default 'shared',
  workstream          text,
  record_status       record_status not null,
  effective_from      timestamptz,
  effective_to        timestamptz,
  provenance_basis    provenance_basis,
  citation            text,
  generated_at        timestamptz not null default now(),
  invalidated_at      timestamptz
);

create unique index retrieval_units_live_uq
  on retrieval_units (source_relation, source_id, unit_kind, ordinal)
  where invalidated_at is null;
create index retrieval_units_fts_idx on retrieval_units using gin (fts);
create index retrieval_units_live_idx on retrieval_units (record_status)
  where invalidated_at is null;

create table retrieval_embeddings (
  id                 uuid primary key default gen_random_uuid(),
  retrieval_unit_id  uuid not null references retrieval_units(id) on delete cascade,
  model_provider     text not null,
  model_name         text not null,
  model_version      text not null,
  dimensions         int  not null,
  embedding          vector(384),
  rendered_text_hash text not null,   -- drift from the unit means the vector is stale
  embedded_at        timestamptz not null default now(),
  stale_at           timestamptz,
  unique (retrieval_unit_id, model_provider, model_name, model_version)
);
create index retrieval_embeddings_hnsw
  on retrieval_embeddings using hnsw (embedding vector_cosine_ops);

alter table retrieval_units      enable row level security;
alter table retrieval_embeddings enable row level security;
revoke all on retrieval_units, retrieval_embeddings from anon, authenticated;

-- Projection builder. Idempotent. Invalidates any live unit whose source is no
-- longer current or whose content hash drifted, then projects what is missing.
-- memories project as one atomic unit; wiki pages split on markdown headings.
create function refresh_retrieval_units()
returns table (invalidated int, projected_memories int, projected_wiki int)
language plpgsql security definer set search_path = public, extensions as $$
declare v_inv int := 0; v_mem int := 0; v_wiki int := 0;
begin
  update retrieval_units ru set invalidated_at = now()
  where ru.invalidated_at is null
    and not exists (
      select 1 from memories m
      where ru.source_relation = 'memories' and m.id = ru.source_id
        and m.status = 'current'
        and encode(digest(m.content,'sha256'),'hex') = ru.source_content_hash
      union all
      select 1 from wiki_pages w
      where ru.source_relation = 'wiki_pages' and w.id = ru.source_id
        and w.status = 'current'
        and encode(digest(w.content,'sha256'),'hex') = ru.source_content_hash
    );
  get diagnostics v_inv = row_count;

  insert into retrieval_units (source_relation, source_id, source_content_hash, unit_kind,
    ordinal, exact_locator, rendered_text, owner, visibility, workstream, record_status,
    effective_from, effective_to, provenance_basis, citation)
  select 'memories', m.id, encode(digest(m.content,'sha256'),'hex'), 'memory_atom',
    0, 'memories:'||m.id, m.content, m.owner, m.visibility, m.workstream, m.status,
    m.effective_from, m.effective_to, m.provenance_basis, m.citation
  from memories m
  where m.status = 'current'
    and not exists (select 1 from retrieval_units ru
      where ru.invalidated_at is null and ru.source_relation='memories'
        and ru.source_id = m.id and ru.ordinal = 0);
  get diagnostics v_mem = row_count;

  insert into retrieval_units (source_relation, source_id, source_content_hash, unit_kind,
    ordinal, exact_locator, rendered_text, owner, visibility, workstream, record_status,
    effective_from, effective_to, provenance_basis, citation)
  select 'wiki_pages', w.id, encode(digest(w.content,'sha256'),'hex'), 'wiki_section',
    s.ord::int, 'wiki:'||w.path||'#'||s.ord, s.section, w.owner, w.visibility,
    w.workstream, w.status, w.effective_from, w.effective_to, w.provenance_basis, w.citation
  from wiki_pages w
  cross join lateral (
    select section, row_number() over () as ord
    from regexp_split_to_table(w.content, E'\n(?=#{1,6}[[:space:]])') as section
  ) s
  where w.status = 'current'
    and length(trim(s.section)) > 0
    and not exists (select 1 from retrieval_units ru
      where ru.invalidated_at is null and ru.source_relation='wiki_pages'
        and ru.source_id = w.id and ru.ordinal = s.ord::int);
  get diagnostics v_wiki = row_count;

  return query select v_inv, v_mem, v_wiki;
end; $$;

revoke execute on function refresh_retrieval_units() from anon, authenticated, public;

create function retrieve_context(
  p_principal_id    uuid,
  p_query           text,
  p_query_embedding vector(384) default null,
  p_budget_chars    int default 8000,
  p_max_units       int default 20
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
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
        when (select count(*) from vis) = 0 then 'not_evaluated'
        when (select tsq from q) is null    then 'not_evaluated'
        else 'evaluated' end,
    'reason', case
        when (select count(*) from vis) = 0 then 'no_retrieval_units_visible_to_principal'
        when (select tsq from q) is null    then 'empty_query'
        else null end,
    'mode', case
        when (select count(*) from vis) = 0 or (select tsq from q) is null then null
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
    'results', coalesce((
       select jsonb_agg(to_jsonb(k) - 'rn' order by k.rrf desc) from kept k
    ), '[]'::jsonb)
  ) into v_out;

  return v_out;
end; $$;

revoke execute on function retrieve_context(uuid, text, vector, int, int)
  from anon, authenticated, public;
