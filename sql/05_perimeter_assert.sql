-- 05_perimeter_assert.sql
-- Sovereign Vault (business) — Phase 1: perimeter assert
--
-- Motivating finding (production, 2026): Supabase auto-grants SELECT
-- to anon/authenticated on new tables in `public` by default privileges,
-- regardless of what you've locked down elsewhere. A perimeter check that
-- only looks at function execute grants (which is what an earlier
-- deployment's perimeter-assert did) will miss this every time. This version checks BOTH.
--
-- Run perimeter_assert() after every migration, and on a schedule. It is a
-- pure SELECT — it never revokes anything automatically, because an
-- automatic revoke on a false positive could take down legitimate access.
-- A human (or an agent with explicit 'admin' capability on 'table:*')
-- reviews the output and revokes deliberately.

create or replace function perimeter_assert()
returns table (
  category text,
  object_schema text,
  object_name text,
  grantee text,
  privilege text
) language sql stable security definer set search_path = public as $$
  -- Table/view grants to anon or authenticated in public schema
  select 'table_grant'::text, table_schema, table_name, grantee, privilege_type
  from information_schema.role_table_grants
  where table_schema = 'public'
    and grantee in ('anon', 'authenticated')

  union all

  -- Function execute grants to anon or authenticated. Uses aclexplode()
  -- against pg_proc.proacl directly — tested against Postgres 16 and
  -- confirmed working (earlier draft referenced a non-existent
  -- pg_proc_acl_expanded relation; this replaced it after that failed on
  -- a real database during Phase 1 testing, 2026-07-07).
  select 'function_grant'::text, n.nspname,
         p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')',
         r.rolname, a.privilege_type
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  cross join lateral aclexplode(p.proacl) a
  join pg_roles r on r.oid = a.grantee
  where n.nspname = 'public'
    and r.rolname in ('anon', 'authenticated')
    and p.proacl is not null

  order by 1, 2, 3;
$$;

revoke execute on function perimeter_assert() from anon, authenticated, public;
alter function perimeter_assert() set search_path = public;
