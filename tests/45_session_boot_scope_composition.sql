-- tests/45_session_boot_scope_composition.sql
--
-- Proves sql/43 composed capability scope into every read path session_boot
-- assembles, AND that this suite fails when it has not been.
--
-- ── HOW THIS SUITE WAS PROVEN TO DISCRIMINATE ─────────────────────────────
-- Run against the PRE-fix definitions (sql/32's session_boot and sql/14's two
-- wrappers, all filtering on is_owner_or_shared alone), this suite reports
-- SUITE_RESULT: FAIL with assertions 2, 3, 4, 5 and 7 failing -- the four
-- authorization sites plus the drifted-copy case. The observed failing output
-- is recorded in the commit message.
--
-- That control matters more than the passing run. Every fixture row here is
-- visibility='shared' and owner-mismatched, which is the exact shape that made
-- is_owner_or_shared() return true for everything in production. A suite built
-- on private rows would pass against the BROKEN code, because owner/visibility
-- alone would already deny them -- and it would have certified the defect.
--
-- ── FIXTURES ARE SYNTHETIC ────────────────────────────────────────────────
-- No corpus content. Scope names are invented for this suite and are not the
-- deployment's workstreams.

\set ON_ERROR_STOP on
begin;

create temporary table t_result(n int, name text, pass boolean, detail text);

-- ══════════════════════════════════════════════════════════════════════════
-- Fixtures
-- ══════════════════════════════════════════════════════════════════════════
-- Two scopes, three principals:
--   p_none  -- holds nothing. Must see zero of everything.
--   p_alpha -- holds read on scope alpha only. Must see alpha rows only.
--   p_both  -- holds read on both. Sees everything, and is the positive
--              control: without it, every assertion below is satisfied by a
--              system that returns nothing to anyone.
create temporary table t_ids(k text primary key, v uuid);
insert into t_ids(k, v) values
  ('p_none',  gen_random_uuid()),
  ('p_alpha', gen_random_uuid()),
  ('p_both',  gen_random_uuid()),
  ('m_alpha', gen_random_uuid()),
  ('m_beta',  gen_random_uuid()),
  ('m_due_a', gen_random_uuid()),
  ('m_due_b', gen_random_uuid()),
  ('w_beta',  gen_random_uuid());

create or replace function pg_temp.id(text) returns uuid language sql stable as
  $$ select v from t_ids where k = $1 $$;

insert into principals(id, kind, display_name, active) values
  (pg_temp.id('p_none'),  'human', 'suite-principal-none',  true),
  (pg_temp.id('p_alpha'), 'human', 'suite-principal-alpha', true),
  (pg_temp.id('p_both'),  'human', 'suite-principal-both',  true);

insert into scope_registry(scope, kind, identifier, description) values
  ('workstream:suite-alpha', 'workstream', 'suite-alpha', 'synthetic test scope'),
  ('workstream:suite-beta',  'workstream', 'suite-beta',  'synthetic test scope')
on conflict do nothing;

-- granted_by is NOT NULL: a grant with no grantor is an unattributable
-- authorization change, which is the property the whole capability model
-- exists to provide. The suite supplies one rather than working around it.
insert into capability_grants(principal_id, resource_scope, permissions, granted_by) values
  (pg_temp.id('p_alpha'), 'workstream:suite-alpha', array['read']::capability_permission[], pg_temp.id('p_both')),
  (pg_temp.id('p_both'),  'workstream:suite-alpha', array['read']::capability_permission[], pg_temp.id('p_both')),
  (pg_temp.id('p_both'),  'workstream:suite-beta',  array['read']::capability_permission[], pg_temp.id('p_both'));

-- Every fixture row: visibility='shared', owner = a principal that is NOT the
-- one being tested. is_owner_or_shared() returns TRUE for all of them, for all
-- three principals. Only capability can tell them apart. That is the point.
--
-- source_kind='manual', not 'agent'. The first draft used 'agent' and the
-- lifecycle guard rejected it: agent-sourced rows must be 'proposed' unless
-- their provenance_basis is decision_record. That guard is correct and the
-- fixture was wrong, so the fixture changed. Setting provenance_basis to
-- decision_record purely to get past it would have been forging a provenance
-- claim to make a test convenient -- these rows are test scaffolding, not
-- decisions anyone recorded.
-- Rows are inserted at 'proposed' and promoted, because sql/26 makes
-- status='current' unreachable by direct INSERT. The suite goes through the
-- sanctioned path rather than around it: a fixture that bypassed the lifecycle
-- guard would be testing a database no deployment can actually be in.
insert into memories(id, content, workstream, tags, source_kind, status, owner, visibility,
                     provenance_basis)
values
  (pg_temp.id('m_alpha'), 'suite fixture alpha', 'suite-alpha', '{}', 'manual', 'proposed',
     pg_temp.id('p_both'), 'shared', 'human_direct'),
  (pg_temp.id('m_beta'),  'suite fixture beta',  'suite-beta',  '{}', 'manual', 'proposed',
     pg_temp.id('p_both'), 'shared', 'human_direct');

insert into memories(id, content, workstream, tags, source_kind, status, owner, visibility,
                     due_date, due_status, provenance_basis)
values
  (pg_temp.id('m_due_a'), 'suite deadline alpha', 'suite-alpha', '{}', 'manual', 'proposed',
     pg_temp.id('p_both'), 'shared', now() + interval '3 days', 'pending', 'human_direct'),
  (pg_temp.id('m_due_b'), 'suite deadline beta',  'suite-beta',  '{}', 'manual', 'proposed',
     pg_temp.id('p_both'), 'shared', now() + interval '4 days', 'pending', 'human_direct');

select promote_memory(pg_temp.id('m_alpha'), pg_temp.id('p_both'));
select promote_memory(pg_temp.id('m_beta'),  pg_temp.id('p_both'));
select promote_memory(pg_temp.id('m_due_a'), pg_temp.id('p_both'));
select promote_memory(pg_temp.id('m_due_b'), pg_temp.id('p_both'));

insert into wiki_pages(id, path, content, tags, source_kind, status, workstream, owner, visibility,
                       provenance_basis)
values
  (pg_temp.id('w_beta'), '_suite/beta', 'suite wiki fixture', '{}', 'manual', 'current',
     'suite-beta', pg_temp.id('p_both'), 'shared', 'human_direct');

-- ── The drifted-copy fixture ──────────────────────────────────────────────
-- A retrieval unit whose SOURCE is a beta record, but whose own copied columns
-- claim alpha. This is exactly the ACL drift migration 39 exists to repair.
-- p_alpha holds alpha and not beta. A count that trusts the projection's copy
-- returns 1 for them; a count that resolves to the source returns 0.
insert into retrieval_units(
  source_relation, source_id, source_content_hash, unit_kind, ordinal,
  exact_locator, rendered_text, owner, visibility, workstream, record_status)
values (
  'memories', pg_temp.id('m_beta'), 'suite-hash', 'span', 1,
  'suite:1', 'suite drifted unit',
  pg_temp.id('p_both'), 'shared', 'suite-alpha', 'current');

-- ══════════════════════════════════════════════════════════════════════════
-- Assertions
-- ══════════════════════════════════════════════════════════════════════════
-- coalesce(pass,false) everywhere: a NULL assertion is a non-assertion, and
-- reading one as a pass is instance 1 of this project's signature failure.

-- 1. POSITIVE CONTROL, and it runs first on purpose.
--    A suite of denials is satisfied by a system that grants nothing to anyone.
--    If this fails, every "sees zero" assertion below is meaningless.
insert into t_result
select 1, 'positive_control: p_both sees both memories, both deadlines, the wiki page',
  coalesce(
    (b->'health'->>'memories_current_visible')::int >= 4
    and jsonb_array_length(b->'deadlines'->'items') = 2
    and (b->'health'->>'wiki_current_visible')::int >= 1, false),
  'health=' || coalesce((b->'health'->>'memories_current_visible'),'NULL')
  || ' deadlines=' || coalesce(jsonb_array_length(b->'deadlines'->'items')::text,'NULL')
  || ' wiki=' || coalesce((b->'health'->>'wiki_current_visible'),'NULL')
from (select session_boot(pg_temp.id('p_both')) as b) s;

-- 2. Health counts are scope-composed: p_alpha sees alpha rows, not beta.
insert into t_result
select 2, 'health memories count is scope-composed for p_alpha',
  coalesce((b->'health'->>'memories_current_visible')::int = 2, false),
  'expected 2 (m_alpha + m_due_a), got ' || coalesce((b->'health'->>'memories_current_visible'),'NULL')
from (select session_boot(pg_temp.id('p_alpha')) as b) s;

-- 3. Deadlines are scope-composed. This is the surface the original report
--    named, and the one a principal reads first.
insert into t_result
select 3, 'deadlines are scope-composed for p_alpha',
  coalesce(jsonb_array_length(b->'deadlines'->'items') = 1
           and (b->'deadlines'->'items'->0->>'workstream') = 'suite-alpha', false),
  'items=' || coalesce((b->'deadlines'->'items')::text,'NULL')
from (select session_boot(pg_temp.id('p_alpha')) as b) s;

-- 4. wiki_pages count is scope-composed: p_alpha must not see the beta page.
insert into t_result
select 4, 'wiki count is scope-composed for p_alpha',
  coalesce((b->'health'->>'wiki_current_visible')::int = 0, false),
  'expected 0, got ' || coalesce((b->'health'->>'wiki_current_visible'),'NULL')
from (select session_boot(pg_temp.id('p_alpha')) as b) s;

-- 5. A principal with no grants sees nothing at all.
insert into t_result
select 5, 'p_none sees zero across every content block',
  coalesce(
    (b->'health'->>'memories_current_visible')::int = 0
    and (b->'health'->>'wiki_current_visible')::int = 0
    and jsonb_array_length(b->'deadlines'->'items') = 0
    and jsonb_array_length(b->'hot_topics'->'items') = 0, false),
  'mem=' || coalesce((b->'health'->>'memories_current_visible'),'NULL')
  || ' wiki=' || coalesce((b->'health'->>'wiki_current_visible'),'NULL')
  || ' dl=' || coalesce(jsonb_array_length(b->'deadlines'->'items')::text,'NULL')
from (select session_boot(pg_temp.id('p_none')) as b) s;

-- 6. ...and is TOLD it holds nothing, rather than shown an empty vault.
insert into t_result
select 6, 'p_none is degraded with capability_scopes=none and an empty scope list',
  coalesce(
    (b->>'degraded')::boolean
    and (b->'degraded_reasons') @> '["capability_scopes=none"]'::jsonb
    and (b->'scopes'->>'count')::int = 0, false),
  'degraded_reasons=' || coalesce((b->'degraded_reasons')::text,'NULL')
from (select session_boot(pg_temp.id('p_none')) as b) s;

-- 7. THE DRIFTED COPY, asserted as a DIVERGENCE rather than as a fixed number.
--    First draft asserted "expected 0" and failed with 2 -- because promoting
--    the alpha fixtures generates retrieval units for them, which p_alpha may
--    legitimately see. The assertion was wrong, not the code.
--
--    Asserting a total was the wrong shape anyway: it couples the test to how
--    many units the projection happens to make. What actually needs proving is
--    that the two ways of counting DISAGREE and boot takes the source-resolving
--    one. The second conjunct is the load-bearing half -- without it this passes
--    whenever the fixture fails to create any drift at all, which is precisely
--    how a drift test quietly stops testing drift.
insert into t_result
select 7, 'retrieval_units count resolves to the source row, not the projection copy',
  coalesce(boot = by_source and boot <> by_copy, false),
  'boot=' || boot::text || ' by_source=' || by_source::text || ' by_copy=' || by_copy::text
  || case when by_source = by_copy
          then ' -- FIXTURE BROKEN: no drift present, this assertion proved nothing'
          else '' end
from (
  select
    (session_boot(pg_temp.id('p_alpha'))->'health'->>'retrieval_units_visible')::int as boot,
    (select count(*) from retrieval_units ru
      where ru.invalidated_at is null and ru.record_status='current'
        and exists (select 1 from memories m where m.id=ru.source_id
                    and can_read_row(m.owner,m.visibility,m.workstream,pg_temp.id('p_alpha')))
    )::int as by_source,
    (select count(*) from retrieval_units ru
      where ru.invalidated_at is null and ru.record_status='current'
        and can_read_row(ru.owner,ru.visibility,ru.workstream,pg_temp.id('p_alpha'))
    )::int as by_copy
) q;

-- 8. The wrappers are independently callable, so they must enforce on their
--    own rather than relying on session_boot to filter what they return.
insert into t_result
select 8, 'deadlines_upcoming_for enforces scope when called directly',
  coalesce((select count(*) from deadlines_upcoming_for(pg_temp.id('p_alpha'))) = 1, false),
  'direct call returned ' || (select count(*) from deadlines_upcoming_for(pg_temp.id('p_alpha')))::text;

-- 9. Boot must never be MORE permissive than the policy predicate, for any
--    principal. Stated as an invariant rather than as fixed numbers so it keeps
--    holding as fixtures change.
insert into t_result
select 9, 'boot health count never exceeds the composed policy predicate',
  coalesce(bool_and(
    (session_boot(p.id)->'health'->>'memories_current_visible')::int
      = (select count(*) from memories m
         where m.status='current'
           and can_read_row(m.owner, m.visibility, m.workstream, p.id))), false),
  'compared across ' || count(*)::text || ' principals'
from principals p
where p.active and p.display_name like 'suite-principal-%';

-- GUARD: a NULL assertion is not a pass. 24/24 green with 21 inert assertions
-- is a real thing that happened here.
insert into t_result
select 99, 'GUARD_no_null_assertions', coalesce(count(*) = 0, false),
  count(*)::text || ' assertion(s) evaluated to NULL'
from t_result where pass is null;

-- ══════════════════════════════════════════════════════════════════════════
-- Verdict
-- ══════════════════════════════════════════════════════════════════════════
select n, name, coalesce(pass,false) as pass, detail from t_result order by n;

select case when count(*) = 0 then 'SUITE_RESULT: PASS' else 'SUITE_RESULT: FAIL' end as verdict
from t_result where pass is not true;

rollback;
