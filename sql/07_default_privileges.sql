-- 07_default_privileges.sql
-- Sovereign Vault (business) — Phase 1 hardening: default privileges
--
-- Motivating finding (Supabase deployment, real project): Postgres grants
-- default privileges on new relations to the PUBLIC pseudo-role, and Supabase
-- projects ship anon/authenticated as real login-adjacent roles that inherit
-- through PUBLIC. The result: every new table, view, AND function created in
-- `public` after this project's initial setup starts out reachable by
-- anon/authenticated, regardless of what earlier migrations locked down.
-- perimeter_assert() (05_perimeter_assert.sql) is what catches this after the
-- fact; this file is what prevents it going forward.
--
-- Verified on a live Supabase project before shipping this file: a throwaway
-- table and throwaway function created with zero explicit revokes both
-- showed up in perimeter_assert() before this file was applied, and zero
-- grants after. Canary objects were dropped once confirmed; nothing from
-- the canary itself ships here.
--
-- Idempotent. Safe to re-run.

-- ── Forward-looking: change the default itself ──────────────────────────
-- Applies to objects created AFTER this statement runs, by the role that
-- runs it. Does not touch anything that already exists — see remediation
-- below for that.
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on functions from anon, authenticated, public;

-- ── Remediation: close the gap on objects that predate this file ───────
-- Earlier migrations in this repo revoked grants table-by-table as each
-- table was created, which means every view (views don't inherit their
-- base tables' grants — they get their own default-privilege grant on
-- creation) and at least one table were missed. Re-running perimeter_assert()
-- after 00-06 apply is what surfaced this; the fix is a blanket sweep here
-- rather than trusting per-migration diligence going forward.
do $$
declare r record;
begin
  for r in
    select table_schema, table_name
    from information_schema.tables
    where table_schema = 'public'
  loop
    execute format('revoke all on %I.%I from anon, authenticated', r.table_schema, r.table_name);
  end loop;
end $$;

-- Functions follow the same pattern: revoke EXECUTE from anon/authenticated
-- (and PUBLIC, since Postgres grants EXECUTE to PUBLIC by default on
-- function creation) for every function already in public. This is broader
-- than table remediation deliberately — a missed function-level revoke is
-- the same class of bug as a missed table-level revoke, and cheaper to
-- blanket-fix than to audit function-by-function.
do $$
declare r record;
begin
  for r in
    select n.nspname as schema_name, p.oid, p.proname,
           pg_get_function_identity_arguments(p.oid) as args
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
  loop
    execute format('revoke execute on function %I.%I(%s) from anon, authenticated, public',
      r.schema_name, r.proname, r.args);
  end loop;
end $$;

-- Note: this remediation pass intentionally does NOT touch functions or
-- extension-provided objects installed by extensions themselves (e.g. an
-- extension installed into `public` ships its own functions/operators,
-- some of which the revoke loop above will also catch since they live in
-- pg_proc under the public namespace). If perimeter_assert() still shows
-- function grants after this file applies, check whether an extension is
-- installed into `public` rather than a dedicated schema — that is a
-- separate, structural fix (moving the extension), not a privileges bug,
-- and should be tracked as its own item rather than patched here.
