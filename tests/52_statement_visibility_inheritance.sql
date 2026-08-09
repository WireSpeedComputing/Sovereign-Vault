-- tests/52_statement_visibility_inheritance.sql
--
-- A3. Proves a statement can never be more visible than its source.
--
-- ── WHY EVERY FIXTURE HERE IS PRIVATE ─────────────────────────────────────
-- Every row in the deployment carries visibility='shared', so the visibility
-- dimension has never denied anything in production. A test written against
-- that shape passes whether inheritance is enforced or not: shared inheriting
-- shared is indistinguishable from a column defaulting to shared.
--
-- So the sources here are PRIVATE and owned by someone other than the reader.
-- That is the branch production has never run, and it is the only shape in
-- which this constraint can be observed to do anything.
--
-- All fixtures synthetic. No corpus content.

\set ON_ERROR_STOP on
begin;

create temporary table t_result(n int, name text, pass boolean, detail text);
create temporary table t_ids(k text primary key, v uuid);
insert into t_ids(k,v) values
  ('owner', gen_random_uuid()), ('stranger', gen_random_uuid()),
  ('src_priv', gen_random_uuid()), ('src_shared', gen_random_uuid()),
  ('extraction', gen_random_uuid()), ('st_priv', gen_random_uuid()),
  ('st_shared', gen_random_uuid());
create or replace function pg_temp.id(text) returns uuid language sql stable as
  $$ select v from t_ids where k = $1 $$;

insert into principals(id,kind,display_name,active) values
  (pg_temp.id('owner'),'human','suite52-owner',true),
  (pg_temp.id('stranger'),'human','suite52-stranger',true);

insert into scope_registry(scope,kind,identifier,description) values
  ('workstream:suite52','workstream','suite52','synthetic test scope')
on conflict do nothing;

-- BOTH principals hold the scope, so scope is never the reason for a denial
-- below. Any denial that appears is attributable to visibility alone, which is
-- the dimension under test.
insert into capability_grants(principal_id,resource_scope,permissions,granted_by) values
  (pg_temp.id('owner'),   'workstream:suite52', array['read']::capability_permission[], pg_temp.id('owner')),
  (pg_temp.id('stranger'),'workstream:suite52', array['read']::capability_permission[], pg_temp.id('owner'));

-- The private source, owned by 'owner'.
insert into memories(id,content,workstream,tags,source_kind,status,owner,visibility,provenance_basis)
values (pg_temp.id('src_priv'),
        'The threshold was set to forty units in the second review.',
        'suite52','{}','manual','proposed', pg_temp.id('owner'),'private','human_direct');
insert into memories(id,content,workstream,tags,source_kind,status,owner,visibility,provenance_basis)
values (pg_temp.id('src_shared'),
        'The threshold was set to forty units in the second review.',
        'suite52','{}','manual','proposed', pg_temp.id('owner'),'shared','human_direct');
select promote_memory(pg_temp.id('src_priv'),   pg_temp.id('owner'));
select promote_memory(pg_temp.id('src_shared'), pg_temp.id('owner'));

insert into statement_extractions(id, method, actor_principal, ruleset_version, source_selector, notes)
values (pg_temp.id('extraction'),'human', pg_temp.id('owner'),'suite52','suite fixture',
        'synthetic extraction for the visibility inheritance suite');

-- Helper: build a statement whose span and hashes verify against its source.
create or replace function pg_temp.mk_statement(p_id uuid, p_src uuid, p_visibility visibility_level)
returns void language plpgsql as $$
declare v_content text; v_quote text;
begin
  select content into v_content from memories where id = p_src;
  v_quote := substring(v_content from 5 for 34);
  insert into statements(id, claim, modality, derived_from, source_content_hash,
                         span_start, span_end, quote_hash, extraction_id,
                         inherited_basis, visibility)
  values (p_id, 'the threshold was set to forty units', 'asserted', p_src,
          encode(digest(v_content,'sha256'),'hex'),
          5, 38, encode(digest(v_quote,'sha256'),'hex'), (select v from t_ids where k='extraction'),
          'human_direct', p_visibility);
end; $$;

-- ══════════════════════════════════════════════════════════════════════════
-- Assertions
-- ══════════════════════════════════════════════════════════════════════════

-- 1. POSITIVE CONTROL FIRST. A statement from a SHARED source is visible to a
--    stranger who holds the scope. Without this, every denial below is
--    satisfied by a layer that shows nobody anything.
select pg_temp.mk_statement(pg_temp.id('st_shared'), pg_temp.id('src_shared'), 'shared');
insert into t_result
select 1, 'positive_control: shared-source statement IS visible to a scoped stranger',
  coalesce(statement_visible_to(pg_temp.id('st_shared'), pg_temp.id('stranger')), false),
  'if false, every denial below proves nothing';

-- 2. THE LAUNDERING ATTEMPT. Insert a statement from a PRIVATE source and ask
--    for visibility='shared' explicitly. The caller does not get to choose.
select pg_temp.mk_statement(pg_temp.id('st_priv'), pg_temp.id('src_priv'), 'shared');
insert into t_result
select 2, 'a statement from a private source cannot be inserted as shared',
  coalesce((select visibility from statements where id = pg_temp.id('st_priv')) = 'private', false),
  'stored visibility = ' || coalesce((select visibility::text from statements where id = pg_temp.id('st_priv')),'NULL')
  || ' (caller asked for shared)';

-- 3. It is not visible to a stranger who holds the scope. Scope is held, so
--    only visibility can be doing the work.
insert into t_result
select 3, 'and it is not visible to a scoped stranger',
  coalesce(statement_visible_to(pg_temp.id('st_priv'), pg_temp.id('stranger')) = false, false),
  'stranger holds workstream:suite52, so a denial here is visibility alone';

-- 4. ...while its owner CAN see it. Pairs with 3: proves 3 is a filter, not an
--    empty table.
insert into t_result
select 4, 'its owner can see it',
  coalesce(statement_visible_to(pg_temp.id('st_priv'), pg_temp.id('owner')), false),
  'owner must retain access to their own private material';

-- 5. It cannot be widened by direct UPDATE.
update statements set visibility = 'shared' where id = pg_temp.id('st_priv');
insert into t_result
select 5, 'a direct UPDATE cannot widen it',
  coalesce((select visibility from statements where id = pg_temp.id('st_priv')) = 'private', false),
  'after UPDATE ... SET visibility=shared, stored value is '
    || coalesce((select visibility::text from statements where id = pg_temp.id('st_priv')),'NULL');

-- 6. THE DRIFT CASE, and the one a write-time check alone would miss. Narrow
--    the SOURCE and the statement must follow in the same statement -- there
--    must be no window in which a private record has shared statements.
select reclassify_record('memories', pg_temp.id('src_shared'), pg_temp.id('owner'),
        'suite52: narrowing the source to prove statements follow',
        '{"visibility":"private"}'::jsonb);
insert into t_result
select 6, 'narrowing the source narrows its statements',
  coalesce((select visibility from statements where id = pg_temp.id('st_shared')) = 'private', false),
  'statement visibility after the source was narrowed: '
    || coalesce((select visibility::text from statements where id = pg_temp.id('st_shared')),'NULL');

-- 7. ...and the read path agrees, because it never asked the statement.
insert into t_result
select 7, 'the read path agrees after the source narrowed',
  coalesce(statement_visible_to(pg_temp.id('st_shared'), pg_temp.id('stranger')) = false, false),
  'the stranger could read this statement before the source was narrowed';

-- 8. A retracted statement is not visible to anyone, including its owner.
update statements set retracted_at = now(), retraction_reason = 'suite52: retracted'
 where id = pg_temp.id('st_shared');
insert into t_result
select 8, 'a retracted statement is visible to nobody',
  coalesce(statement_visible_to(pg_temp.id('st_shared'), pg_temp.id('owner')) = false, false),
  'an unresolvable statement is not a visible one';

insert into t_result
select 99,'GUARD_no_null_assertions', coalesce(count(*)=0,false),
  count(*)::text||' assertion(s) evaluated to NULL'
from t_result where pass is null;

select n, name, coalesce(pass,false) as pass, left(detail,86) as detail from t_result order by n;

select case when count(*) = 0 then 'SUITE_RESULT: PASS' else 'SUITE_RESULT: FAIL' end as verdict
from t_result where pass is not true;

rollback;
