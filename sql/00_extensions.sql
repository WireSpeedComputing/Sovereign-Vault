-- 00_extensions.sql
-- Sovereign Vault (business) — Phase 0
-- Idempotent. Safe to re-run.

create extension if not exists vector;
create extension if not exists pgcrypto;   -- for digest() used in doc integrity

-- Supabase projects come with anon/authenticated/service_role roles built in.
-- Vanilla Postgres does not. Every REVOKE in this repo targets those role
-- names, so create shim roles here if they don't already exist — this makes
-- the SQL portable to non-Supabase Postgres and is also what makes local
-- testing against plain PG16 possible at all.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin bypassrls;
  end if;
end $$;

-- pg_net and pg_cron are NOT required by anything in sql/01-05 as shipped —
-- they're only needed once you add embedding backfill (calling an edge
-- function on a schedule, as production deployments of this pattern do). Supabase
-- projects have both preinstalled; vanilla Postgres needs pg_cron added to
-- shared_preload_libraries in postgresql.conf before `create extension`
-- will succeed, which this script cannot do for you. Uncomment when you
-- actually add scheduled embedding:
-- create extension if not exists pg_net;
-- create extension if not exists pg_cron;
