-- 45_session_boot_scope_composition.sql
-- Compose first-call, ranked, deadline, and count surfaces with canonical
-- scope/owner/visibility authorization. SECURITY DEFINER readers must invoke
-- the row predicate explicitly; table RLS alone may not constrain their owner.
-- Resolve projection authorization against canonical source rows, then filter
-- before ranking and LIMIT. Counts and content must use the same predicate.
-- An active principal without a matching capability receives no governed rows;
-- report the resulting degraded scope state without treating visibility as a
-- substitute for authority. No target roster or corpus is implied here.
-- MIGRATION: 61_session_boot_scope_composition

create or replace function public.memory_hot_ranked_for(p_principal_id uuid)
returns table(
  id uuid, memory_id uuid, topic_key text, summary text, workstream text,
  touch_count integer, last_touched timestamptz, created_at timestamptz, score numeric
)
language sql
stable
security definer
set search_path to 'public'
as $function$
  SELECT mhr.id, mhr.memory_id, mhr.topic_key, mhr.summary, mhr.workstream,
         mhr.touch_count, mhr.last_touched, mhr.created_at, mhr.score
  FROM memory_hot_ranked mhr
  JOIN memories m ON m.id = mhr.memory_id
  WHERE public.can_read_row(m.owner, m.visibility, m.workstream, p_principal_id)
  ORDER BY mhr.score DESC
  LIMIT 15;
$function$;

-- Scope is taken from m.workstream, the SOURCE row, not from mhr.workstream.
-- memory_hot_ranked carries its own copy for display; an authorization decision
-- made from a display copy is the retrieval_units defect in a second location.
revoke all on function public.memory_hot_ranked_for(uuid) from public, anon, authenticated;
grant execute on function public.memory_hot_ranked_for(uuid) to service_role;

-- ══════════════════════════════════════════════════════════════════════════
-- 2. deadlines_upcoming_for
-- ══════════════════════════════════════════════════════════════════════════
create or replace function public.deadlines_upcoming_for(p_principal_id uuid)
returns table(
  id uuid, content text, workstream text, due_date timestamptz, source_agent text,
  overdue boolean, days_until integer
)
language sql
stable
security definer
set search_path to 'public'
as $function$
  SELECT m.id, m.content, m.workstream, m.due_date, m.source_agent,
         m.due_date < now() AS overdue,
         EXTRACT(day FROM m.due_date - now())::integer AS days_until
  FROM memories m
  WHERE m.due_date IS NOT NULL AND m.due_status = 'pending' AND m.status = 'current'
    AND m.due_date < (now() + interval '14 days')
    AND public.can_read_row(m.owner, m.visibility, m.workstream, p_principal_id)
  ORDER BY m.due_date;
$function$;

revoke all on function public.deadlines_upcoming_for(uuid) from public, anon, authenticated;
grant execute on function public.deadlines_upcoming_for(uuid) to service_role;

-- ══════════════════════════════════════════════════════════════════════════
-- 3. session_boot
-- ══════════════════════════════════════════════════════════════════════════
-- Body is sql/32 verbatim except: the four authorization sites, the new
-- degraded reason, the scopes block, and the version bump. Everything else --
-- admission, coverage vocabulary, the coordination block's honest 'unscoped'
-- state, the contract delegation -- is unchanged and deliberately so.
create or replace function public.session_boot(p_principal_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_kind          principal_kind;
  v_instr_state   text;
  v_contract      jsonb;
  v_contract_st   text;
  v_degraded      text[] := '{}';
  v_scopes        text[];
  v_out           jsonb;
  v_instr_path    constant text := '_system/ai-instructions';
begin
  if p_principal_id is null then
    raise exception 'session_boot requires a principal';
  end if;
  select p.kind into v_kind
    from principals p where p.id = p_principal_id and p.active;
  if not found then
    raise exception 'principal % is not active', p_principal_id;
  end if;

  -- Scope inventory. Drives both the new degraded reason and the scopes block.
  select coalesce(array_agg(distinct g.resource_scope order by g.resource_scope), '{}')
    into v_scopes
    from capability_grants_active g
   where g.principal_id = p_principal_id
     and ('read'::capability_permission = any(g.permissions)
          or 'admin'::capability_permission = any(g.permissions));

  if array_length(v_scopes, 1) is null then
    -- Explicit ::text cast. Without it Postgres reads the bare literal as an
    -- array literal and raises "malformed array literal" at runtime -- the
    -- neighbouring appends only work because ('x=' || var) is already typed
    -- text. Caught by tests/32_session_boot.sql, which is the pre-existing
    -- suite for this function doing exactly what it exists to do.
    v_degraded := v_degraded || 'capability_scopes=none'::text;
  end if;

  select vd.state into v_instr_state from verify_doc_integrity(v_instr_path) vd;
  v_instr_state := coalesce(v_instr_state, 'no-blessing');
  if v_instr_state <> 'match' then
    v_degraded := v_degraded || ('instruction_integrity=' || v_instr_state);
  end if;

  if to_regprocedure('public.agent_contract()') is not null then
    begin
      execute 'select public.agent_contract()' into v_contract;
      v_contract_st := 'available';
    exception when others then
      v_contract    := null;
      v_contract_st := 'error';
    end;
  else
    v_contract_st := 'not_implemented';
  end if;
  if v_contract_st <> 'available' then
    v_degraded := v_degraded || ('agent_contract=' || v_contract_st);
  end if;

  select jsonb_build_object(
    -- 1.1.0: the meaning of every content field changed (scope now applies) and
    -- two fields were added. sql/32 says to bump when a field's meaning changes.
    'boot_schema_version', '1.1.0',
    'principal_id',        p_principal_id,
    'principal_kind',      v_kind::text,
    'booted_at',           now(),

    -- ── the principal's own authorization state ───────────────────────────
    'scopes', jsonb_build_object(
      'coverage', 'queried',
      'read_scopes', to_jsonb(v_scopes),
      'count', coalesce(array_length(v_scopes, 1), 0)),

    'hot_topics', jsonb_build_object(
      'coverage', 'queried',
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'topic_key',   h.topic_key,
                 'summary',     left(h.summary, 200),
                 'workstream',  h.workstream,
                 'touch_count', h.touch_count,
                 'score',       round(h.score, 4))
               order by h.score desc)
        from memory_hot_ranked_for(p_principal_id) h), '[]'::jsonb)),

    'deadlines', jsonb_build_object(
      'coverage', 'queried',
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'memory_id',  d.id,
                 'content',    left(d.content, 200),
                 'workstream', d.workstream,
                 'due_date',   d.due_date,
                 'overdue',    d.overdue,
                 'days_until', d.days_until)
               order by d.due_date)
        from deadlines_upcoming_for(p_principal_id) d), '[]'::jsonb)),

    'coordination', jsonb_build_object(
      'source',   'review_queue',
      'coverage', 'unscoped',
      'reason',   'review_queue carries no owner/visibility/workstream column, so neither per-principal scoping nor capability scoping is possible; counts are deployment-wide and no free-text detail is returned',
      'open_count', (select count(*) from review_queue rq where rq.resolution = 'pending'),
      'oldest_open_age_days', (
        select round(extract(epoch from (now() - min(rq.created_at))) / 86400.0, 2)
        from review_queue rq where rq.resolution = 'pending'),
      'by_kind', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'kind', k.kind,
                 'open_count', k.n,
                 'oldest_age_days', round(extract(epoch from (now() - k.oldest)) / 86400.0, 2))
               order by k.n desc, k.kind)
        from (select rq.kind, count(*) as n, min(rq.created_at) as oldest
              from review_queue rq where rq.resolution = 'pending'
              group by rq.kind) k), '[]'::jsonb)),

    'instruction_integrity', jsonb_build_object(
      'coverage', 'queried',
      'path',     v_instr_path,
      'state',    v_instr_state),

    'contract', jsonb_build_object(
      'surface',  'public.agent_contract()',
      'state',    v_contract_st,
      'embedded', v_contract,
      'see',      'docs/08-contract-version-and-drift.md'),

    -- ── health: every count now composed, same rule as the policies ───────
    'health', jsonb_build_object(
      'coverage', 'queried',
      'memories_current_visible', (
        select count(*) from memories m
        where m.status = 'current'
          and can_read_row(m.owner, m.visibility, m.workstream, p_principal_id)),
      'memories_proposed_visible', (
        select count(*) from memories m
        where m.status = 'proposed'
          and can_read_row(m.owner, m.visibility, m.workstream, p_principal_id)),
      'wiki_current_visible', (
        select count(*) from wiki_pages w
        where w.status = 'current'
          and can_read_row(w.owner, w.visibility, w.workstream, p_principal_id)),
      -- Resolves to the SOURCE row. Identical shape to the retrieval_units
      -- policy in sql/36. Does not read ru.owner/ru.visibility/ru.workstream.
      'retrieval_units_visible', (
        select count(*) from retrieval_units ru
        where ru.invalidated_at is null
          and ru.record_status = 'current'
          and case ru.source_relation
                when 'memories' then exists (
                  select 1 from memories m
                  where m.id = ru.source_id
                    and can_read_row(m.owner, m.visibility, m.workstream, p_principal_id))
                when 'wiki_pages' then exists (
                  select 1 from wiki_pages w
                  where w.id = ru.source_id
                    and can_read_row(w.owner, w.visibility, w.workstream, p_principal_id))
                else false
              end)),

    'degraded',         (array_length(v_degraded, 1) is not null),
    'degraded_reasons', to_jsonb(v_degraded)
  ) into v_out;

  return v_out;
end; $$;

comment on function public.session_boot(uuid) is
  'Principal-scoped first-call orientation envelope. Content is filtered by can_read_row() -- is_owner_or_shared() composed with capability scope, the same rule the RLS policies reach through can_read_row_as_request(). Reports the principal''s own read scopes and degrades with capability_scopes=none when they hold none, so an empty envelope is distinguishable from an empty vault. MUST NOT be granted to anon or authenticated; the deployment-neutral counterpart is agent_contract().';

revoke all on function public.session_boot(uuid) from public, anon, authenticated;
grant execute on function public.session_boot(uuid) to service_role;
