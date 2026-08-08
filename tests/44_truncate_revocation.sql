-- tests/44_truncate_revocation.sql
--
-- Proves sql/44 removed the table-level bypass AND that perimeter_assert() can
-- see one when it exists.
--
-- ── THE ASSERTION THAT MATTERS ────────────────────────────────────────────
-- Assertion 4 grants TRUNCATE back on a scratch table and requires the checker
-- to report it. Without that, every other assertion here is satisfied by a
-- checker that returns nothing under all conditions -- which is precisely the
-- state the old checker was in for this privilege, and it read as clean for
-- months.
--
-- ── WHY THE TRUNCATE ITSELF IS NOT EXECUTED ───────────────────────────────
-- The privilege is asserted by inspection, not by running TRUNCATE against a
-- governed table. Running it would destroy the fixture to prove something the
-- catalogue already answers, and a suite that has to destroy data to check a
-- destruction guard is not one anyone will run twice.

\set ON_ERROR_STOP on
begin;

create temporary table t_result(n int, name text, pass boolean, detail text);

-- 1. POSITIVE CONTROL FIRST. The checker must be capable of returning rows at
--    all in this environment. A perimeter suite whose checker is inert reports
--    a clean perimeter for the same reason a broken one does.
create table if not exists public._suite_perimeter_probe(id int);
grant select on public._suite_perimeter_probe to authenticated;

insert into t_result
select 1, 'positive_control: perimeter_assert reports a deliberate exposure',
  coalesce(exists (
    select 1 from perimeter_assert()
    where object_name = '_suite_perimeter_probe' and grantee = 'authenticated'), false),
  'a SELECT grant to authenticated must be reported';

-- 2. No governed table grants TRUNCATE to service_role any more.
insert into t_result
select 2, 'no TRUNCATE held by service_role on public or vault_auth',
  coalesce(count(*) = 0, false),
  count(*)::text || ' table(s) still grant TRUNCATE to service_role: '
    || coalesce(string_agg(table_name, ',' order by table_name), '-')
from information_schema.role_table_grants
where table_schema in ('public','vault_auth')
  and privilege_type = 'TRUNCATE' and grantee = 'service_role';

-- 3. The DEFAULT no longer re-grants it. This is the assertion that stops the
--    fix decaying: without it, a passing suite today says nothing about the
--    table created by the next migration.
create table public._suite_default_acl_probe(id int);
insert into t_result
select 3, 'a newly created table does not inherit TRUNCATE for service_role',
  coalesce(not exists (
    select 1 from information_schema.role_table_grants
    where table_schema='public' and table_name='_suite_default_acl_probe'
      and privilege_type='TRUNCATE' and grantee='service_role'), false),
  'default privileges must not re-introduce it on CREATE TABLE';

-- 4. THE DISCRIMINATION CASE. Put the privilege back and require a report.
grant truncate on public._suite_default_acl_probe to service_role;
insert into t_result
select 4, 'perimeter_assert REPORTS a TRUNCATE grant when one exists',
  coalesce(exists (
    select 1 from perimeter_assert()
    where category = 'destructive_grant'
      and object_name = '_suite_default_acl_probe'
      and grantee = 'service_role'
      and privilege = 'TRUNCATE'), false),
  'if this is false the checker is blind and assertion 2 proved nothing';

-- 5. ...and stops reporting it once revoked, so it is not simply always-on.
revoke truncate on public._suite_default_acl_probe from service_role;
insert into t_result
select 5, 'and stops reporting it once the grant is removed',
  coalesce(not exists (
    select 1 from perimeter_assert()
    where category = 'destructive_grant'
      and object_name = '_suite_default_acl_probe'), false),
  'a checker that always reports is as useless as one that never does';

-- 6. A declared READ exception must not excuse a TRUNCATE grant. The three RLS
--    tables carry table exceptions for authenticated SELECT; if the new
--    category matched on identity alone, those rows would silently whitelist
--    destruction on exactly the governed tables that matter most.
grant truncate on public.memories to service_role;
insert into t_result
select 6, 'an existing READ exception does not whitelist TRUNCATE',
  coalesce(exists (
    select 1 from perimeter_assert()
    where category = 'destructive_grant' and object_name = 'memories'), false),
  'memories has a declared table exception for authenticated SELECT';
revoke truncate on public.memories from service_role;

-- 7. The delete-audit table specifically. It is the evidence store for the
--    guard this bypass defeats, so it being truncatable made the bypass
--    self-erasing.
insert into t_result
select 7, 'the delete-audit table is not truncatable by service_role',
  coalesce(not exists (
    select 1 from information_schema.role_table_grants
    where table_schema='public' and table_name='hard_delete_audit'
      and privilege_type='TRUNCATE' and grantee='service_role'), false),
  'evidence destructible by the privilege it exists to observe is not evidence';

-- 8. The row-level guards still work. A revocation that also broke the
--    sanctioned delete path would trade one hole for an outage.
do $c$ begin
  delete from public.hard_delete_audit where false;
  insert into t_result values (8,'sanctioned paths unaffected by the revocation',true,'no-op delete accepted');
exception when others then
  insert into t_result values (8,'sanctioned paths unaffected by the revocation',false,SQLERRM);
end $c$;

insert into t_result
select 99, 'GUARD_no_null_assertions', coalesce(count(*) = 0, false),
  count(*)::text || ' assertion(s) evaluated to NULL'
from t_result where pass is null;

drop table if exists public._suite_perimeter_probe;
drop table if exists public._suite_default_acl_probe;

select n, name, coalesce(pass,false) as pass, detail from t_result order by n;

select case when count(*) = 0 then 'SUITE_RESULT: PASS' else 'SUITE_RESULT: FAIL' end as verdict
from t_result where pass is not true;

rollback;
