-- 43_session_boot_scope_composition.sql
--
-- MIGRATION: 61_session_boot_scope_composition
--
-- WO-14 Phase 1a. Independently confirmed defect, then measured against
-- production before and after.
--
-- ══════════════════════════════════════════════════════════════════════════
-- WHAT WAS WRONG
-- ══════════════════════════════════════════════════════════════════════════
-- session_boot() is SECURITY DEFINER, so it bypasses every RLS policy. It
-- filtered content with is_owner_or_shared() and never consulted capability at
-- all. It therefore enforced the access model as it existed BEFORE scopes were
-- added (migration 43), while the policies enforce the model as it exists now.
--
-- Neither was written carelessly. sql/32's own header argues -- correctly, for
-- the day it was written -- that using is_owner_or_shared() and nothing else is
-- the safe choice because "a second authorization path is how two surfaces end
-- up disagreeing about who may see what." That reasoning was right. What
-- changed underneath it is that the authorization model gained a dimension, and
-- the single path it named stopped being the whole rule.
--
-- session_boot is the FIRST thing a session calls. A principal's opening
-- context was assembled by the one path that ignores scope.
--
-- ══════════════════════════════════════════════════════════════════════════
-- MEASURED ON PRODUCTION BEFORE THE FIX -- and it is worse than reported
-- ══════════════════════════════════════════════════════════════════════════
-- The defect was reported as "live disagreement across 5 of 8 active
-- principals, including up to three extra deadline records." The principal
-- count reproduced exactly. The magnitude did not.
--
--   5 of 8 active principals: boot showed 132 current + 99 proposed records.
--                             The policy path shows them 0. All of them.
--   3 of 8 active principals: agree at 132 / 99, because they hold grants on
--                             every registered scope.
--
-- There is no partial overlap anywhere. The disagreement is not a leak of a few
-- extra rows at the margin; for those five principals it is the entire corpus.
-- Recorded here because "extra deadline records" would have set the
-- expectation that a small diff was being closed, and a fix verified against
-- that expectation could have passed while leaving most of the gap open.
--
-- ══════════════════════════════════════════════════════════════════════════
-- THE FOURTH FINDING: is_owner_or_shared() currently denies nothing
-- ══════════════════════════════════════════════════════════════════════════
-- Measured on production at the same time: every one of the 231 current and
-- proposed rows carries visibility='shared', and none has a NULL owner. Since
-- the predicate is
--
--     (owner = principal) OR (visibility = 'shared')
--
-- its second disjunct is TRUE for every (row, principal) pair in the database.
-- The predicate has never once returned false in production. It is not a weak
-- filter; it is not a filter.
--
-- That is why the boot surface looked healthy for a year. It was applying an
-- authorization predicate that cannot deny, and every surface signal -- row
-- counts, coverage states, degraded flags -- was consistent with a working
-- access model. This is the ninth instance of a check reporting success
-- without checking, and the first one found in an access predicate rather
-- than in a test harness.
--
-- Not "fixed" here, because there is nothing broken in the function: it
-- correctly implements owner-or-shared. What was broken is relying on it alone.
-- Composing it with capability is exactly that fix. Left in place, because when
-- private-visibility rows exist it will start discriminating, and removing a
-- currently-inert guard is how you get a gap later.
--
-- ══════════════════════════════════════════════════════════════════════════
-- WHAT THIS CHANGES
-- ══════════════════════════════════════════════════════════════════════════
-- Four surfaces, not one. The report named session_boot; enumerating what boot
-- actually reads found two more functions with the same predicate, each
-- independently callable, plus one count inside boot resolving authorization
-- from a projection copy.
--
--   1. memory_hot_ranked_for(uuid)   -- own path, called by boot AND directly
--   2. deadlines_upcoming_for(uuid)  -- own path, called by boot AND directly
--   3. session_boot() health counts  -- owner/visibility only
--   4. session_boot() retrieval_units count -- trusted the PROJECTION's copies
--      of owner/visibility, which sql/36 explicitly refused to do for the
--      policy on the same table. See below.
--
-- All four now use can_read_row(owner, visibility, workstream, principal) --
-- the explicit-principal form of the identical rule the policies reach through
-- can_read_row_as_request(). One composition rule, written once in sql/36,
-- reached two ways. Not a copy of the rule: a call to it.
--
-- STRICTLY NARROWING. can_read_row() is is_owner_or_shared() AND capability.
-- No row becomes visible to anyone who could not already see it. A fix to an
-- over-permissive path that could widen anything would be the wrong fix.
--
-- ══════════════════════════════════════════════════════════════════════════
-- WHY THE retrieval_units COUNT RESOLVES BACK TO THE SOURCE ROW
-- ══════════════════════════════════════════════════════════════════════════
-- retrieval_units carries its own copies of owner/visibility/workstream. That
-- divergence has already produced one real defect here -- ACL drift, fixed in
-- sql/27 and applied as migration 39 -- and sql/36 therefore wrote the
-- retrieval_units POLICY to resolve back to the source row rather than trust
-- the copies.
--
-- session_boot's health count was still reading the copies. So the policy and
-- the boot count could disagree about the same unit whenever a copy went stale,
-- which is precisely the condition migration 39 exists to repair rather than
-- prevent. Fixed to match the policy exactly. The two now ask the same question
-- of the same row.
--
-- Nobody reported this one. It was found by enumerating what boot reads instead
-- of fixing what the report named, which is the argument for enumerating.
--
-- ══════════════════════════════════════════════════════════════════════════
-- NEW DEGRADED REASON: capability_scopes=none
-- ══════════════════════════════════════════════════════════════════════════
-- After this change, a principal holding no capability grants gets an empty
-- envelope. Empty is the CORRECT answer -- it is what the policies already give
-- them -- but sql/32's own governing rule is that "a bare empty rowset is
-- indistinguishable from 'nothing exists'", and an empty boot for an
-- unprovisioned principal is exactly that ambiguity in its most misleading
-- form: the vault looks empty rather than unreachable.
--
-- So absence of grants is now emitted as a degraded reason and the principal's
-- own granted scopes are reported back. Same discipline as migration 60, which
-- made perimeter_assert() emit "not evaluated" rather than return zero rows: an
-- empty result you can trust is worth more than an empty result you cannot
-- distinguish from a working one.
--
-- Reporting a principal their OWN scope list is not a disclosure: it is their
-- authorization state, on a surface that already returns their content, and
-- knowing you hold nothing is the difference between "ask for access" and
-- "conclude the system is broken."

-- ══════════════════════════════════════════════════════════════════════════
-- 1. memory_hot_ranked_for -- filter before LIMIT, as before
-- ══════════════════════════════════════════════════════════════════════════
-- The scope gate goes in the WHERE, not around the result. LIMIT 15 after an
-- unfiltered rank would let rows the principal cannot read consume slots and
-- silently shrink their result set -- a scope leak inverted into a denial, and
-- invisible from the output.
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
