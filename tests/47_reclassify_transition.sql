-- tests/47_reclassify_transition.sql
--
-- Proves the lock blocks direct authorization changes, the sanctioned path
-- still works after the lock, and the audit row is written.
--
-- The ordering assertion (2 then 5) is the one that matters: this project has
-- twice shipped a lock that made the thing it was protecting uncorrectable.

\set ON_ERROR_STOP on
begin;

create temporary table t_result(n int, name text, pass boolean, detail text);
create temporary table t_ids(k text primary key, v uuid);
insert into t_ids(k,v) values
  ('human', gen_random_uuid()), ('agent', gen_random_uuid()), ('rec', gen_random_uuid());
create or replace function pg_temp.id(text) returns uuid language sql stable as
  $$ select v from t_ids where k = $1 $$;

insert into principals(id,kind,display_name,active) values
  (pg_temp.id('human'),'human','suite-reclass-human',true),
  (pg_temp.id('agent'),'agent','suite-reclass-agent',true);

insert into scope_registry(scope,kind,identifier,description) values
  ('workstream:suite-target','workstream','suite-target','synthetic test scope')
on conflict do nothing;

insert into memories(id,content,workstream,tags,source_kind,status,owner,visibility,provenance_basis)
values (pg_temp.id('rec'),'suite reclassify fixture',null,'{}','manual','proposed',
        pg_temp.id('human'),'shared','human_direct');
select promote_memory(pg_temp.id('rec'), pg_temp.id('human'));

-- 1. POSITIVE CONTROL: a lifecycle UPDATE that touches no authorization input
--    still works. A lock that blocks everything would pass assertion 2.
do $c$ begin
  update memories set updated_at = now() where id = pg_temp.id('rec');
  insert into t_result values (1,'positive_control: non-authorization UPDATE still permitted',true,'accepted');
exception when others then
  insert into t_result values (1,'positive_control: non-authorization UPDATE still permitted',false,SQLERRM);
end $c$;

-- 2. Direct UPDATE of workstream is refused.
do $c$ begin
  update memories set workstream = 'suite-target' where id = pg_temp.id('rec');
  insert into t_result values (2,'direct UPDATE of workstream is refused',false,'ACCEPTED -- the lock is not wired');
exception when others then
  insert into t_result values (2,'direct UPDATE of workstream is refused',true,SQLERRM);
end $c$;

-- 3. ...and of owner.
do $c$ begin
  update memories set owner = pg_temp.id('agent') where id = pg_temp.id('rec');
  insert into t_result values (3,'direct UPDATE of owner is refused',false,'ACCEPTED');
exception when others then
  insert into t_result values (3,'direct UPDATE of owner is refused',true,SQLERRM);
end $c$;

-- 4. ...and of visibility.
do $c$ begin
  update memories set visibility = 'private' where id = pg_temp.id('rec');
  insert into t_result values (4,'direct UPDATE of visibility is refused',false,'ACCEPTED');
exception when others then
  insert into t_result values (4,'direct UPDATE of visibility is refused',true,SQLERRM);
end $c$;

-- 5. THE ORDERING ASSERTION. The sanctioned path still works after the lock.
--    A lock that makes its own subject uncorrectable is the failure this
--    project has shipped twice.
do $c$ declare n integer; begin
  n := reclassify_record(pg_temp.id('rec'), 'suite-target', pg_temp.id('human'), 'suite: classification test');
  insert into t_result values (5,'sanctioned reclassify works AFTER the lock', n = 1, 'fields changed: '||n::text);
exception when others then
  insert into t_result values (5,'sanctioned reclassify works AFTER the lock',false,SQLERRM);
end $c$;

-- 6. The change actually landed.
insert into t_result
select 6, 'the record now carries the new workstream',
  coalesce((select workstream from memories where id = pg_temp.id('rec')) = 'suite-target', false),
  'workstream=' || coalesce((select workstream from memories where id = pg_temp.id('rec')),'NULL');

-- 7. An audit row exists, with both scopes recorded. The scope pair is the
--    point: "workstream changed" is not the interesting fact, "the set of
--    principals who can read this changed from A to B" is.
insert into t_result
select 7, 'an audit row records the scope movement and the actor',
  coalesce(count(*) = 1, false),
  coalesce(string_agg(old_scope||' -> '||new_scope||' by '||acting_principal::text, '; '), 'NO AUDIT ROW')
from record_authorization_audit
where record_id = pg_temp.id('rec') and field = 'workstream';

-- 8. An AGENT cannot reclassify. Agents propose; humans enact.
do $c$ begin
  perform reclassify_record(pg_temp.id('rec'), 'suite-target', pg_temp.id('agent'), 'suite: agent attempt');
  insert into t_result values (8,'an agent principal cannot reclassify',false,'ACCEPTED -- an agent widened its own reach');
exception when others then
  insert into t_result values (8,'an agent principal cannot reclassify',true,SQLERRM);
end $c$;

-- 9. A reason is required. An authorization change with no stated reason is the
--    unattributed rewrite the function exists to prevent.
do $c$ begin
  perform reclassify_record(pg_temp.id('rec'), 'suite-target', pg_temp.id('human'), '   ');
  insert into t_result values (9,'a blank reason is refused',false,'ACCEPTED');
exception when others then
  insert into t_result values (9,'a blank reason is refused',true,SQLERRM);
end $c$;

-- 10. An unregistered scope is refused. A typo that silently creates a scope
--     nobody holds reads as "classified" and behaves as "invisible to everyone".
do $c$ begin
  perform reclassify_record(pg_temp.id('rec'), 'suite-typo-nonexistent', pg_temp.id('human'), 'suite: typo');
  insert into t_result values (10,'an unregistered target scope is refused',false,'ACCEPTED');
exception when others then
  insert into t_result values (10,'an unregistered target scope is refused',true,SQLERRM);
end $c$;

-- 11. The audit table is append-only.
do $c$ begin
  delete from record_authorization_audit where record_id = pg_temp.id('rec');
  insert into t_result values (11,'the audit table refuses DELETE',false,'ACCEPTED -- the audit is editable');
exception when others then
  insert into t_result values (11,'the audit table refuses DELETE',true,SQLERRM);
end $c$;

-- 12. The window closes. After a successful call the lock must be back on --
--     a GUC left 'on' turns a one-statement exemption into an open door for the
--     rest of the transaction.
do $c$ begin
  update memories set workstream = 'suite-target-again' where id = pg_temp.id('rec');
  insert into t_result values (12,'the reclassify window closes after the call',false,'ACCEPTED -- app.reclassifying left on');
exception when others then
  insert into t_result values (12,'the reclassify window closes after the call',true,SQLERRM);
end $c$;

-- 13. Content is still immutable. The whole argument for this file is that
--     authorization inputs were mutable while content was not; that asymmetry
--     must close in the direction of locking down, not opening up.
do $c$ begin
  update memories set content = 'rewritten' where id = pg_temp.id('rec');
  insert into t_result values (13,'content remains locked',false,'ACCEPTED -- custody lock regressed');
exception when others then
  insert into t_result values (13,'content remains locked',true,SQLERRM);
end $c$;

insert into t_result
select 99,'GUARD_no_null_assertions', coalesce(count(*)=0,false),
  count(*)::text||' assertion(s) evaluated to NULL'
from t_result where pass is null;

select n, name, coalesce(pass,false) as pass, left(detail,90) as detail from t_result order by n;

select case when count(*) = 0 then 'SUITE_RESULT: PASS' else 'SUITE_RESULT: FAIL' end as verdict
from t_result where pass is not true;

rollback;
