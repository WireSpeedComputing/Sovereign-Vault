-- APPLIED as deployment migration 43 (2026-08-07)
--
-- MIGRATION: 43_rls_policies_scope_narrows_visibility
--
-- APPLIED 2026-08-07 as migration 43. Capability grants were issued in the same
-- session -- see STATUS.md. Grants are deployment data and are not in this repo.
--
-- WO-08 Task 2 / our issue #11: RLS policy wiring. LIVE.
--
-- ############################################################
-- APPLY ORDER. This file assumes, in order:
--   sql/30_scope_bound_authority.sql   (scope_registry, the scope grammar)
--   pending/B_retrieval_topology_ISSUE72.sql  (Part 2's retrieve_context)
-- It REDEFINES retrieve_context() on top of B's version. Applying this without
-- B silently reverts B's topology envelope. Applying B after this silently
-- reverts the scope gate below. They must go in order, or be merged first.
-- Stated here because "apply the pending files" is the kind of instruction that
-- gets executed alphabetically.
-- ############################################################
--
-- ══════════════════════════════════════════════════════════════════════════
-- WHAT WAS ACTUALLY WRONG
-- ══════════════════════════════════════════════════════════════════════════
-- Verified live: ZERO RLS policies exist across every RLS-enabled table, and
-- nothing calls has_capability() or request_has_capability(). Access works only
-- because service_role carries BYPASSRLS.
--
-- The consequence is not "slightly permissive". RLS enabled with no policy is
-- DENY-ALL. So a founder who authenticates today resolves to the right
-- principal, evaluates capability correctly, and then sees NOTHING — the
-- identity layer works and there is no path from it to a row. That is the last
-- structural blocker to multi-user, and it fails in the safe direction, which
-- is why nobody noticed.
--
-- ══════════════════════════════════════════════════════════════════════════
-- THE MODEL: SCOPE NARROWS VISIBILITY
-- ══════════════════════════════════════════════════════════════════════════
-- A row is readable iff it passes BOTH:
--   1. the existing owner/visibility predicate (is_owner_or_shared), and
--   2. the principal holds read on the row's workstream scope.
--
-- Strictly more restrictive than today. Union-with-visibility was rejected
-- outright: an authority rule that GRANTS access is not an authority model, and
-- adding one could only ever widen.
--
-- NULL workstream is 69% of current rows (84 of 122). Those are not exempt and
-- are not backfilled. They map to one reserved, grantable scope,
-- 'workstream:unclassified':
--   * backfilling forces invented classifications onto genuinely cross-cutting
--     content, and a wrong classification is worse than an honest null;
--   * exempting leaves the model governing 31% of the corpus, which is
--     decorative in a new way.
-- Granting that scope is a deliberate, auditable act, exactly like any other.
--
-- ══════════════════════════════════════════════════════════════════════════
-- ONE AUTHORIZATION PATH, TWO IDENTITY SOURCES
-- ══════════════════════════════════════════════════════════════════════════
-- The dangerous version of this change is two predicates that agree today and
-- drift apart later. There is one composition rule, written once, reached two
-- ways:
--   can_read_row(owner, visibility, workstream, principal)  -- explicit actor,
--       for SECURITY DEFINER functions that already carry a principal
--   can_read_row_as_request(owner, visibility, workstream)  -- request identity,
--       for RLS policies, resolving the principal from verified JWT claims
-- The second delegates the scope decision to the same place the first does.

-- ── The reserved-scope rule, in exactly one place ─────────────────────────
create or replace function public.row_scope(p_workstream text)
returns text language sql immutable set search_path = public as $$
  select 'workstream:' || coalesce(nullif(btrim(p_workstream), ''), 'unclassified');
$$;

comment on function public.row_scope(text) is
  'Maps a row workstream to its capability scope. NULL and empty both map to workstream:unclassified -- a real, grantable scope, not an exemption. Single source of truth for that mapping: if it lived in each policy, one policy would eventually spell it differently and silently widen.';

-- ── Explicit-principal form: for definer functions ────────────────────────
create or replace function public.can_read_row(
  p_owner uuid, p_visibility visibility_level, p_workstream text, p_principal_id uuid
) returns boolean language sql stable security definer
set search_path = public as $$
  select public.is_owner_or_shared(p_owner, p_visibility, p_principal_id)
     and public.has_capability(p_principal_id, public.row_scope(p_workstream), 'read');
$$;

-- ── Request-identity form: for RLS policies ───────────────────────────────
-- SECURITY DEFINER is safe here and is NOT the thing that would break identity.
-- Verified empirically before relying on it: SECURITY DEFINER rewrites
-- current_user and leaves session_user ALONE, and
-- vault_auth._trusted_request_claims() gates on session_user='authenticator'.
-- So a definer wrapper does not blind the claims check.
--
-- Being definer also keeps the grant surface minimal: authenticated needs
-- EXECUTE on this one function, and nothing else -- not is_owner_or_shared, not
-- has_capability, not any vault_auth internal.
create or replace function public.can_read_row_as_request(
  p_owner uuid, p_visibility visibility_level, p_workstream text
) returns boolean language sql stable security definer
set search_path = public, vault_auth as $$
  select coalesce(
    public.is_owner_or_shared(p_owner, p_visibility,
                              vault_auth.current_human_principal_id())
    and public.request_has_capability(public.row_scope(p_workstream), 'read'),
  false);
$$;

-- coalesce(..., false) is load-bearing, not defensive habit. An unresolved
-- identity makes current_human_principal_id() NULL, is_owner_or_shared() NULL,
-- and the whole AND NULL. A policy USING clause treats NULL as NOT VISIBLE, so
-- this would fail closed anyway -- but three-valued logic silently turning a
-- guard into a maybe is precisely the class of defect raised upstream as #74,
-- and relying on the caller's null handling is how it recurs. Made explicit.

revoke all on function public.can_read_row(uuid, visibility_level, text, uuid)
  from public, anon, authenticated;
revoke all on function public.can_read_row_as_request(uuid, visibility_level, text)
  from public, anon;
grant execute on function public.can_read_row_as_request(uuid, visibility_level, text)
  to authenticated;
grant execute on function public.row_scope(text) to authenticated;

-- ══════════════════════════════════════════════════════════════════════════
-- POLICIES
-- ══════════════════════════════════════════════════════════════════════════
-- SELECT only. Writes continue to go through the sanctioned SECURITY DEFINER
-- functions, which is the existing model; adding INSERT/UPDATE policies now
-- would create a second write path alongside promote/supersede/reject and
-- undo sql/26. Deliberate omission, not an oversight.

-- ── DECLARE THE TWO NEW EXPOSURES ─────────────────────────────────────────
-- Both grants above are deliberate API surface, and perimeter_assert() (sql/28)
-- correctly flags any EXECUTE granted to `authenticated`. Declaring them keeps
-- the checker at zero findings so a REAL exposure still stands out -- the whole
-- point of sql/28 was that a checker returning noise gets ignored.
--
-- Caught by the replay harness failing verification immediately after this file
-- landed, which is the check doing its job rather than a nuisance.
insert into perimeter_exception (object_kind, object_identity, grantee, reason) values
 ('function',
  'public.can_read_row_as_request(p_owner uuid, p_visibility visibility_level, p_workstream text)',
  'authenticated',
  'The RLS predicate itself. Every SELECT policy on memories, wiki_pages and retrieval_units calls it, so authenticated must hold EXECUTE or the policies cannot evaluate. SECURITY DEFINER, so it adds no privilege beyond the decision it returns, and it resolves identity from verified JWT claims rather than from any caller-supplied argument.'),
 ('function','public.row_scope(p_workstream text)','authenticated',
  'Pure mapping from a workstream to its capability scope string. No data access, IMMUTABLE, and it is called inside the predicate above. Exposed only so the predicate can be evaluated in a policy context.')
on conflict do nothing;

drop policy if exists memories_read on public.memories;
create policy memories_read on public.memories
  for select to authenticated
  using (public.can_read_row_as_request(owner, visibility, workstream));

drop policy if exists wiki_pages_read on public.wiki_pages;
create policy wiki_pages_read on public.wiki_pages
  for select to authenticated
  using (public.can_read_row_as_request(owner, visibility, workstream));

-- ── The projection: the second enforcement surface ────────────────────────
-- retrieval_units carries its OWN copies of owner/visibility/workstream, and
-- that divergence has already caused one real defect (ACL drift, fixed in
-- sql/27 and applied as migration 39). A policy written against the unit's own
-- columns would rebuild exactly that hazard: correct on the day it is written,
-- wrong the moment a copy goes stale.
--
-- So this policy does NOT trust the projection's columns. It resolves back to
-- the source row and asks the same question about it. The projection therefore
-- cannot serve a row the source would deny, by construction rather than by
-- keeping two copies in agreement.
--
-- Cost: a correlated lookup per row. Accepted. The alternative is an
-- authorization decision made from a cache.
drop policy if exists retrieval_units_read on public.retrieval_units;
create policy retrieval_units_read on public.retrieval_units
  for select to authenticated
  using (
    case source_relation
      when 'memories' then exists (
        select 1 from public.memories m
        where m.id = retrieval_units.source_id
          and public.can_read_row_as_request(m.owner, m.visibility, m.workstream))
      when 'wiki_pages' then exists (
        select 1 from public.wiki_pages w
        where w.id = retrieval_units.source_id
          and public.can_read_row_as_request(w.owner, w.visibility, w.workstream))
      else false
    end
  );

-- ══════════════════════════════════════════════════════════════════════════
-- retrieve_context: RLS DOES NOT PROTECT IT, so it enforces scope itself
-- ══════════════════════════════════════════════════════════════════════════
-- retrieve_context is SECURITY DEFINER and owned by a superuser, so it BYPASSES
-- every policy above. Adding RLS and stopping here would leave the primary read
-- path completely ungoverned while the policies made it look solved -- a
-- permissive mistake that returns data and looks perfect, which is the exact
-- failure this work is most exposed to.
--
-- The vis CTE gains the scope gate via can_read_row(), the explicit-principal
-- form of the same rule the policies use. Filtering still happens BEFORE
-- ranking, so a scope the principal lacks cannot influence a score or a count.
--
-- Body is otherwise pending/B Part 2 verbatim. The duplication is a real
-- maintenance hazard and is called out in the apply-order block at the top:
-- these two files must be merged or applied in order.
create or replace function retrieve_context(
  p_principal_id    uuid,
  p_query           text,
  p_query_embedding vector(384) default null,
  p_budget_chars    int default 8000,
  p_max_units       int default 20
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $fn$
declare v_out jsonb;
begin
  if p_principal_id is null then
    raise exception 'retrieve_context requires a principal';
  end if;
  if not exists (select 1 from principals where id = p_principal_id and active) then
    raise exception 'principal % is not active', p_principal_id;
  end if;

  with vis as (
    -- FILTER BEFORE RANK, now including the scope gate
    select ru.* from retrieval_units ru
    where ru.invalidated_at is null
      and ru.record_status = 'current'
      and can_read_row(ru.owner, ru.visibility, ru.workstream, p_principal_id)
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
  topo as (
    select t.store_key, t.store_role, t.queryable_by_this_runtime,
           t.default_coverage_state
    from retrieval_topology t where t.status = 'current'
  ),
  ev as (
    select ((select count(*) from vis) > 0 and (select tsq from q) is not null) as evaluated
  ),
  complete as (
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
    'global_completeness', (select ok from complete),
    'topology', jsonb_build_object(
      'schema_version', '1',
      'stores', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'store_key', t.store_key, 'store_role', t.store_role,
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

revoke execute on function retrieve_context(uuid, text, vector, int, int)
  from anon, authenticated, public;

-- ══════════════════════════════════════════════════════════════════════════
-- THE LIMIT THAT DOES NOT GO AWAY
-- ══════════════════════════════════════════════════════════════════════════
-- service_role carries BYPASSRLS. Every policy in this file is invisible to it,
-- and the deployment's own tooling uses that key. So this governs the
-- AUTHENTICATED path and does not touch the administrative one.
--
-- That is the same boundary already recorded for app.promoting and for
-- actor_assurance, and it is not closable with another policy. It closes when
-- the service-role key stops being the ambient credential.
--
-- Asserted in tests/E section D rather than left in prose, so if someone ever
-- believes they have fixed it, the test tells them the docs are now wrong.
