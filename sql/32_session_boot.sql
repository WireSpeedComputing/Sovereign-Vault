-- 32_session_boot.sql
--
-- MIGRATION: 55_session_boot
--
-- APPLIED 2026-08-08. Verified live: boot_schema_version 1.0.0, degraded=true
-- with reasons ["instruction_integrity=no-blessing","agent_contract=not_implemented"]
-- -- it reports its own gaps rather than presenting a confident empty envelope.
-- perimeter_assert stayed at 0: not granted to anon/authenticated.
--

-- Declares no `-- MIGRATION:` header, which tests/migration_drift.sh reads as
-- "repo file declaring no migration (not yet applied)". Do not add one until a
-- deployment actually runs it.
--
-- ADOPT: sibling protocol repo sovereign-memory-core, `session_boot()`
-- (its sql/01_core.sql lines 405-434), under the contract that repo's issue #72
-- states ("Fail closed on single-store misses and expose topology in session
-- boot"). See docs/10-sibling-pattern-adoption.md for the full diff and for the
-- reasons each divergence below was taken deliberately.
--
-- ── SOURCING NOTE, READ THIS BEFORE TRUSTING THE PROVENANCE ────────────────
-- The work order cited upstream issue #3 as the source. Upstream #3 is CLOSED
-- with the body "This work is tracked privately" and carries no requirements at
-- all (same for #4 and #5). The substantive, still-open upstream requirement
-- for a boot surface is #72. This file is written against #72 and against the
-- sibling's shipped implementation, not against #3, because #3 has no content
-- to implement. That substitution is a judgement call and is flagged rather
-- than smoothed over.
--
-- ── WHY THIS EXISTS ────────────────────────────────────────────────────────
-- Every session in this repo re-derives its own state by hand: which topics are
-- hot, what is due, what is awaiting review, whether the operating instructions
-- have drifted. Four different ad-hoc queries, four chances to get the
-- visibility predicate wrong. One surface that applies the predicate once is
-- both more useful and strictly safer than N callers each rolling their own.
--
-- ── AUTHORIZATION: ONE PATH, NOT TWO ───────────────────────────────────────
-- Nothing here invents an access rule. Content comes from the existing
-- owner-scoped wrappers `memory_hot_ranked_for()` and `deadlines_upcoming_for()`
-- (sql/14), and every count is filtered by `is_owner_or_shared()` — the same
-- total predicate sql/31_is_owner_or_shared_total_function.sql made NULL-safe,
-- and the same one `retrieve_context()` (sql/21 line 161) filters on before it
-- ranks. A second authorization path is how two surfaces end up disagreeing
-- about who may see what.
--
-- Principal admission copies `retrieve_context()` exactly: NULL principal and
-- inactive/unknown principal both RAISE. Boot does not degrade to an anonymous
-- view, because an anonymous view of a principal-scoped surface is the thing
-- that leaks.
--
-- ── ENVELOPE, NOT ROWSET; COVERAGE, NOT SILENCE ────────────────────────────
-- Returns one jsonb envelope for the reason sql/21's header line 19 gives: a
-- bare empty rowset is indistinguishable from "nothing exists". Every block
-- carries its own `coverage` state so "queried and empty" is distinguishable
-- from "not queried". That is #72 requirement 2 applied to the blocks this
-- deployment actually has.
--
-- Coverage vocabulary (deliberately the same three-state shape as
-- verify_doc_integrity's no-blessing/match/mismatch and
-- verify_promoted_integrity's unaudited/match/mismatch):
--   'queried'              -- the block was evaluated against this principal
--   'unscoped'             -- evaluated, but NOT principal-scoped; see reason
--   'unavailable'          -- could not be evaluated; the block is not authority
--
-- ── DIVERGENCES FROM THE SIBLING, EACH ON PURPOSE ──────────────────────────
--  1. Principal is `uuid` referencing principals(id), not `text` naming a
--     household member. The sibling hardcodes 'example-user'/'example-partner'
--     in CHECK constraints. This repo made principals a table in sql/02
--     precisely so a business is not limited to two names.
--  2. No `channel_inbox`. The sibling's `household_channel` table does not
--     exist here and is not being imported: it is a household messaging feature,
--     not a memory-custody concern.
--  3. `coordination` replaces it, reading `review_queue` (sql/09) — this repo's
--     actual open-work surface, and what #72 requirement 4 is asking for.
--     It reports AGGREGATES ONLY, never `review_queue.detail`, because that
--     column is free text that can quote the contents of a private memory and
--     review_queue carries no owner/visibility column to filter it by. Its
--     coverage is therefore 'unscoped' and says so. Reporting an unscoped count
--     honestly is defensible; leaking free text through a "boot" call is not.
--  4. `degraded` / `degraded_reasons` are added, per #72 requirement 5.
--  5. `boot_schema_version` is added, per #72 requirement 2 ("an explicit
--     schema/version"). Bump it when a field's meaning changes.
--
-- ── RECONCILIATION WITH docs/08's PROPOSED agent_contract() ────────────────
-- docs/08 Part 3 correctly records that no `session_boot()` exists here and
-- proposes `public.agent_contract()` as a first-call introspection surface.
-- These are SEPARATE surfaces and stay separate. The distinction is the
-- authorization posture, not the field list:
--
--   agent_contract()  is deployment-neutral. docs/08 lines 403-407: "no
--                     deployment identifiers, no principal names... Digests and
--                     booleans only." docs/08 lines 389-401 contemplate GRANTing
--                     it to `authenticated` as a second declared
--                     perimeter_exception, so a fresh agent can call it before
--                     it knows anything.
--   session_boot()    is principal-scoped and returns principal content. It must
--                     NEVER be granted to `authenticated` and declares no
--                     perimeter_exception.
--
-- Folding them into one function would mean either granting a content-bearing
-- surface to `authenticated`, or making the contract surface unreachable to the
-- fresh agent that needs it most. Both are worse than two functions.
--
-- They are reconciled rather than duplicated: session_boot's `contract` block
-- DELEGATES to agent_contract() when it exists, and reports
-- state='not_implemented' when it does not — which is the state today, since
-- docs/08 proposes that function and nothing has built it. The block is
-- therefore honest on an unmodified deployment and becomes useful the moment
-- docs/08's proposal is implemented, without this file changing.

-- ══════════════════════════════════════════════════════════════════════════
-- session_boot
-- ══════════════════════════════════════════════════════════════════════════

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
  v_out           jsonb;
  v_instr_path    constant text := '_system/ai-instructions';
begin
  -- Admission. Identical in shape to retrieve_context() (sql/21 lines 149-154).
  if p_principal_id is null then
    raise exception 'session_boot requires a principal';
  end if;
  select p.kind into v_kind
    from principals p where p.id = p_principal_id and p.active;
  if not found then
    raise exception 'principal % is not active', p_principal_id;
  end if;

  -- Instruction integrity. 'no-blessing' is a real state, not a pass: it means
  -- no operator has ever registered an expected digest for this deployment.
  -- Same discipline as sql/26's 'unaudited'.
  select vd.state into v_instr_state from verify_doc_integrity(v_instr_path) vd;
  v_instr_state := coalesce(v_instr_state, 'no-blessing');
  if v_instr_state <> 'match' then
    v_degraded := v_degraded || ('instruction_integrity=' || v_instr_state);
  end if;

  -- Contract block: delegate to docs/08's proposed agent_contract() if it has
  -- been built. Absent it, say so. Never synthesize a contract answer here --
  -- an invented digest is worse than an admitted gap.
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
    'boot_schema_version', '1.0.0',
    'principal_id',        p_principal_id,
    'principal_kind',      v_kind::text,
    'booted_at',           now(),

    -- ── hot topics: via the owner-scoped wrapper, never the raw view ──────
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

    -- ── deadlines: via the owner-scoped wrapper ───────────────────────────
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

    -- ── coordination: aggregates only, and honest about not being scoped ──
    'coordination', jsonb_build_object(
      'source',   'review_queue',
      'coverage', 'unscoped',
      'reason',   'review_queue carries no owner/visibility column, so per-principal scoping is not possible; counts are deployment-wide and no free-text detail is returned',
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

    -- ── instruction integrity ─────────────────────────────────────────────
    'instruction_integrity', jsonb_build_object(
      'coverage', 'queried',
      'path',     v_instr_path,
      'state',    v_instr_state),

    -- ── contract: delegated, never synthesized ────────────────────────────
    'contract', jsonb_build_object(
      'surface',  'public.agent_contract()',
      'state',    v_contract_st,
      'embedded', v_contract,
      'see',      'docs/08-contract-version-and-drift.md'),

    -- ── health: every count principal-scoped by the SAME predicate ────────
    'health', jsonb_build_object(
      'coverage', 'queried',
      'memories_current_visible', (
        select count(*) from memories m
        where m.status = 'current'
          and is_owner_or_shared(m.owner, m.visibility, p_principal_id)),
      'memories_proposed_visible', (
        select count(*) from memories m
        where m.status = 'proposed'
          and is_owner_or_shared(m.owner, m.visibility, p_principal_id)),
      'wiki_current_visible', (
        select count(*) from wiki_pages w
        where w.status = 'current'
          and is_owner_or_shared(w.owner, w.visibility, p_principal_id)),
      'retrieval_units_visible', (
        select count(*) from retrieval_units ru
        where ru.invalidated_at is null
          and ru.record_status = 'current'
          and is_owner_or_shared(ru.owner, ru.visibility, p_principal_id))),

    -- ── fail-closed signal (#72 requirement 5) ────────────────────────────
    'degraded',         (array_length(v_degraded, 1) is not null),
    'degraded_reasons', to_jsonb(v_degraded)
  ) into v_out;

  return v_out;
end; $$;

comment on function public.session_boot(uuid) is
  'Principal-scoped first-call orientation envelope. Content is filtered by is_owner_or_shared() only -- no second authorization path. MUST NOT be granted to anon or authenticated and declares no perimeter_exception; the deployment-neutral counterpart proposed in docs/08 is agent_contract(), which is a separate surface for that reason. ';

revoke all on function public.session_boot(uuid) from public, anon, authenticated;
grant execute on function public.session_boot(uuid) to service_role;
