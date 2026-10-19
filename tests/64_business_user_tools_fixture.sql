-- Synthetic-only physical fixture. The runner then loads the exact checked-in
-- sql/23 + sql/25 identity definitions and the exact RLS predicate from sql/36.
-- Vector/retrieval/DDL logging features are outside this finite tool slice.
create role anon nologin nosuperuser nobypassrls;
create role authenticated nologin nosuperuser nobypassrls;
create role authenticator login nosuperuser nobypassrls noinherit;
create role service_role nologin nosuperuser bypassrls;
create role fixture_migration_admin login nosuperuser createdb createrole bypassrls;
grant authenticated,anon to authenticator;
grant all on schema public to fixture_migration_admin with grant option;
do $$ begin execute format('GRANT CREATE ON DATABASE %I TO fixture_migration_admin',current_database()); end $$;
create schema auth authorization fixture_migration_admin;
set session authorization fixture_migration_admin;
create type public.principal_kind as enum('human','agent','service');
create type public.capability_permission as enum('read','propose','write','admin');
create type public.record_status as enum('proposed','current','superseded','retracted','entered_in_error');
create type public.source_kind as enum('manual','agent','imported_artifact','ingest');
create type public.provenance_basis as enum('human_direct','decision_record','source_document','imported_artifact');
create type public.visibility_level as enum('private','shared');
create table public.principals(id uuid primary key,kind public.principal_kind not null,display_name text not null,active boolean not null default true);
create table public.capability_grants(id uuid primary key default gen_random_uuid(),principal_id uuid references public.principals(id),resource_scope text not null,permissions public.capability_permission[] not null,expires_at timestamptz,revoked_at timestamptz);
create view public.capability_grants_active with(security_invoker=true) as select * from public.capability_grants where revoked_at is null and (expires_at is null or expires_at>now());
alter table public.principals enable row level security;
alter table public.capability_grants enable row level security;
create table public.memories(id uuid primary key,content text not null,workstream text,tags text[] not null default '{}',source_kind public.source_kind not null default 'manual',source_ref text,status public.record_status not null default 'current',provenance_basis public.provenance_basis,citation text,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),owner uuid references public.principals(id),visibility public.visibility_level not null default 'shared');
create table public.wiki_pages(like public.memories including defaults including constraints);
alter table public.wiki_pages add column title text;
alter table public.memories enable row level security;
alter table public.wiki_pages enable row level security;
create table auth.sessions(id uuid primary key,user_id uuid not null,oauth_client_id uuid,not_after timestamptz);
revoke all on schema auth from public,anon,authenticated;
revoke all on all tables in schema auth from public,anon,authenticated;
create function auth.uid() returns uuid language sql stable set search_path=pg_catalog as $$ select nullif(current_setting('request.jwt.claims',true)::jsonb->>'sub','')::uuid $$;
create function public.is_owner_or_shared(p_row_owner uuid,p_row_visibility public.visibility_level,p_principal_id uuid)
returns boolean language sql stable set search_path=pg_catalog as $$ select p_row_owner=p_principal_id or p_row_visibility='shared' $$;
revoke all on function public.is_owner_or_shared(uuid,public.visibility_level,uuid) from public,anon,authenticated;
