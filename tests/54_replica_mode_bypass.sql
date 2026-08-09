-- tests/54_replica_mode_bypass.sql
--
-- B2. Proves session_replication_role=replica no longer switches off the audit
-- guards, and proves the suite would notice if it did.
--
-- Runs as superuser, which is the ONLY role that can set that parameter --
-- measured: pg_settings.context is 'superuser', service_role is not superuser,
-- and there are no explicit SET grants on it. Testing it as anyone else would
-- prove nothing, because nobody else can reach it.

\set ON_ERROR_STOP on
begin;

create temporary table t_result(n int, name text, pass boolean, detail text);
create temporary table t_ids(k text primary key, v uuid);
insert into t_ids(k,v) values ('p', gen_random_uuid()), ('rec', gen_random_uuid());
create or replace function pg_temp.id(text) returns uuid language sql stable as
  $$ select v from t_ids where k=$1 $$;

insert into principals(id,kind,display_name,active)
values (pg_temp.id('p'),'human','suite54',true);
insert into scope_registry(scope,kind,identifier,description)
values ('workstream:suite54','workstream','suite54','synthetic'),
       ('workstream:suite54b','workstream','suite54b','synthetic') on conflict do nothing;
-- Created in suite54, reclassified to suite54b, so the change is REAL and an
-- audit row is actually written. The first version created and reclassified to
-- the same scope: reclassify_record correctly did nothing, no audit row
-- existed, and the DELETE below hit zero rows -- so the row trigger never
-- fired and the tamper "succeeded" against an empty table. Assertion 0 now
-- proves there is something to tamper with before anything tries.
insert into memories(id,content,workstream,tags,source_kind,status,owner,visibility,provenance_basis)
values (pg_temp.id('rec'),'suite54 fixture','suite54','{}','manual','proposed',
        pg_temp.id('p'),'shared','human_direct');
select promote_memory(pg_temp.id('rec'), pg_temp.id('p'));

select reclassify_record(pg_temp.id('rec'),'suite54b', pg_temp.id('p'),
       'suite54: create an audit row for the tamper test');

-- A hard-delete receipt to attack as well. INSERT is permitted by the
-- append-only guard; only UPDATE and DELETE are refused.
insert into hard_delete_audit(table_name, record_id, record_status, record_owner,
                              content_sha256, db_user, actor_assurance)
values ('memories', pg_temp.id('rec'), 'current', pg_temp.id('p'),
        repeat('0',64), current_user, 'suite_fixture');

-- 0. PRECONDITION. A tamper test against an empty table passes for the wrong
--    reason: a row-level trigger cannot fire on zero rows.
insert into t_result
select 0, 'precondition: there is an audit row and a receipt to attack',
  coalesce((select count(*) from record_authorization_audit where record_id = pg_temp.id('rec')) = 1
       and (select count(*) from hard_delete_audit) >= 1, false),
  'auth rows=' || (select count(*) from record_authorization_audit where record_id = pg_temp.id('rec'))::text
  || ' receipts=' || (select count(*) from hard_delete_audit)::text;

-- 1. POSITIVE CONTROL: replica mode really does disable origin-mode triggers.
--    Without this, assertions 2 and 3 could pass simply because the SET had no
--    effect in this environment, and the suite would certify a protection it
--    never exercised.
set session_replication_role = replica;
do $c$ begin
  update memories set content = 'rewritten under replica mode' where id = pg_temp.id('rec');
  insert into t_result values (1,
    'positive_control: replica mode DOES bypass an origin-mode custody lock', true,
    'the custody lock on content did not fire -- so replica mode is in effect');
exception when others then
  insert into t_result values (1,
    'positive_control: replica mode DOES bypass an origin-mode custody lock', false,
    'custody lock still fired: '||SQLERRM||' -- replica mode is NOT in effect, so this suite proves nothing');
end $c$;

-- 2. THE FIX. The append-only audit guard is ENABLE ALWAYS, so it must still
--    refuse a DELETE even here.
do $c$ begin
  delete from record_authorization_audit where record_id = pg_temp.id('rec');
  insert into t_result values (2,'the authorization audit refuses DELETE under replica mode',
    false,'ACCEPTED -- the audit was erased with one session-level SET');
exception when others then
  insert into t_result values (2,'the authorization audit refuses DELETE under replica mode',
    true, SQLERRM);
end $c$;

-- 3. ...and an UPDATE, which is the worse case: a rewritten audit row still
--    reads as a genuine receipt.
do $c$ begin
  update record_authorization_audit set reason = 'forged reason'
   where record_id = pg_temp.id('rec');
  insert into t_result values (3,'the authorization audit refuses UPDATE under replica mode',
    false,'ACCEPTED -- an audit row was silently rewritten');
exception when others then
  insert into t_result values (3,'the authorization audit refuses UPDATE under replica mode',
    true, SQLERRM);
end $c$;

-- 4. Same for the delete-audit receipt table.
do $c$ begin
  delete from hard_delete_audit where true;
  insert into t_result values (4,'the hard-delete audit refuses DELETE under replica mode',
    false,'ACCEPTED -- the delete receipts were erased');
exception when others then
  insert into t_result values (4,'the hard-delete audit refuses DELETE under replica mode',
    true, SQLERRM);
end $c$;

reset session_replication_role;

-- 5. The guards are recorded as ALWAYS in the catalogue, not merely observed to
--    fire once. tgenabled='A' is the durable fact; the behaviour above is the
--    consequence.
insert into t_result
select 5, 'both audit guards are ENABLE ALWAYS in pg_trigger',
  coalesce(count(*) = 2, false),
  'ALWAYS-mode audit guards found: ' || count(*)::text || ' of 2'
from pg_trigger t join pg_class c on c.oid=t.tgrelid
where t.tgenabled = 'A'
  and t.tgname in ('trg_hard_delete_audit_append_only','trg_record_auth_audit_append_only');

-- 6. THE LIMIT, asserted rather than described. The custody locks themselves are
--    deliberately still origin-mode, because the restore path needs them off.
--    If someone "hardens" them later the restore breaks, so this assertion
--    exists to make that a conscious change rather than a surprise at 2am.
insert into t_result
select 6, 'custody and provenance triggers remain origin-mode, so restore still works',
  coalesce(count(*) >= 4, false),
  count(*)::text || ' origin-mode triggers on memories/wiki_pages (restore loads under replica mode)'
from pg_trigger t join pg_class c on c.oid=t.tgrelid
join pg_namespace n on n.oid=c.relnamespace
where not t.tgisinternal and n.nspname='public'
  and c.relname in ('memories','wiki_pages') and t.tgenabled='O';

insert into t_result
select 99,'GUARD_no_null_assertions', coalesce(count(*)=0,false),
  count(*)::text||' assertion(s) evaluated to NULL' from t_result where pass is null;

select n, name, coalesce(pass,false) as pass, left(detail,78) as detail from t_result order by n;

select case when count(*) = 0 then 'SUITE_RESULT: PASS' else 'SUITE_RESULT: FAIL' end as verdict
from t_result where pass is not true;

rollback;
