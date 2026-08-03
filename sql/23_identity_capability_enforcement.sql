-- 23_identity_capability_enforcement.sql
--
-- Identity is derived only on the authenticated runtime path. A shared direct
-- Postgres/service credential remains an administrative control plane and is
-- never treated as proof of a human or agent identity.
--
-- Agent-mediated authority is the intersection of the mapped human and mapped
-- OAuth client principals. This file deliberately creates zero bindings and
-- zero capability grants. Binding rows are deployment data and never belong in
-- this repository.
--
-- Folded from three separately reviewed deployment migrations: the active-
-- principal correctness guard, the private identity layer, and its FK indexes.

-- Sovereign Vault migration 34
-- Correctness-only change: inactive principals must never retain capability.
-- Wildcard scope semantics are intentionally out of scope.

create or replace function public.has_capability(
  p_principal_id uuid,
  p_resource_scope text,
  p_permission public.capability_permission
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select exists (
    select 1
    from public.principals p
    join public.capability_grants_active g
      on g.principal_id = p.id
    where p.id = p_principal_id
      and p.active
      and g.resource_scope = p_resource_scope
      and (
        p_permission = any(g.permissions)
        or 'admin'::public.capability_permission = any(g.permissions)
      )
  );
$function$;

revoke all on function public.has_capability(uuid, text, public.capability_permission)
  from public, anon, authenticated;
grant execute on function public.has_capability(uuid, text, public.capability_permission)
  to service_role;

comment on function public.has_capability(uuid, text, public.capability_permission) is
  'Exact-scope capability check for active principals only. Wildcard matching is intentionally not implemented. Administrative/service use only; authenticated requests use vault_auth.request_has_capability().';

-- Sovereign Vault migration 35
-- Private, fail-closed identity binding layer.
-- This migration deliberately creates zero bindings and zero capability grants.

create schema vault_auth;
comment on schema vault_auth is
  'Private identity-to-principal bindings and request capability resolution. Not an exposed Data API schema.';

revoke all on schema vault_auth from public, anon, authenticated, service_role;

create table vault_auth.principal_identity_bindings (
  id uuid primary key default gen_random_uuid(),
  identity_kind text not null
    check (identity_kind in ('auth_subject', 'oauth_client')),
  issuer text not null check (btrim(issuer) <> ''),
  identity_value text not null check (btrim(identity_value) <> ''),
  principal_id uuid not null references public.principals(id),
  binding_status text not null default 'pending'
    check (binding_status in ('pending', 'active', 'superseded', 'revoked')),
  review_status text not null default 'proposed'
    check (review_status in ('proposed', 'approved', 'rejected')),
  valid_from timestamptz not null default now(),
  valid_until timestamptz,
  supersedes_id uuid references vault_auth.principal_identity_bindings(id),
  created_by uuid not null references public.principals(id),
  reviewed_by uuid references public.principals(id),
  reviewed_at timestamptz,
  reason text not null check (btrim(reason) <> ''),
  citation text not null check (btrim(citation) <> ''),
  provenance_basis text not null check (btrim(provenance_basis) <> ''),
  workstream text not null check (btrim(workstream) <> ''),
  source_agent text not null check (btrim(source_agent) <> ''),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (valid_until is null or valid_until > valid_from),
  check (
    review_status <> 'approved'
    or (reviewed_by is not null and reviewed_at is not null)
  ),
  check (binding_status <> 'active' or review_status = 'approved')
);

create unique index principal_identity_bindings_active_identity_uidx
  on vault_auth.principal_identity_bindings(identity_kind, issuer, identity_value)
  where binding_status = 'active';

create index principal_identity_bindings_principal_idx
  on vault_auth.principal_identity_bindings(principal_id, identity_kind, binding_status);

alter table vault_auth.principal_identity_bindings enable row level security;
alter table vault_auth.principal_identity_bindings force row level security;
revoke all on vault_auth.principal_identity_bindings from public, anon, authenticated, service_role;

create table vault_auth.principal_identity_binding_audit (
  id bigint generated always as identity primary key,
  binding_id uuid,
  changed_at timestamptz not null default now(),
  operation text not null check (operation in ('INSERT', 'UPDATE', 'DELETE')),
  database_session_user text not null,
  database_current_user text not null,
  request_token_id text,
  request_claims jsonb,
  identity_kind text,
  issuer text,
  identity_value text,
  principal_id uuid,
  old_row jsonb,
  new_row jsonb
);

alter table vault_auth.principal_identity_binding_audit enable row level security;
alter table vault_auth.principal_identity_binding_audit force row level security;
revoke all on vault_auth.principal_identity_binding_audit from public, anon, authenticated, service_role;

create or replace function vault_auth._trusted_request_claims()
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $function$
declare
  claims_text text;
  claims jsonb;
begin
  if session_user <> 'authenticator' then
    return null;
  end if;

  claims_text := current_setting('request.jwt.claims', true);
  if claims_text is null or btrim(claims_text) = '' then
    return null;
  end if;

  claims := claims_text::jsonb;
  if claims ->> 'role' <> 'authenticated'
     or nullif(claims ->> 'sub', '') is null then
    return null;
  end if;

  return claims;
exception
  when others then
    return null;
end;
$function$;

create or replace function vault_auth._resolve_human_principal(p_claims jsonb)
returns uuid
language sql
stable
security definer
set search_path = ''
as $function$
  select b.principal_id
  from vault_auth.principal_identity_bindings b
  join public.principals p on p.id = b.principal_id
  where b.identity_kind = 'auth_subject'
    and b.issuer = p_claims ->> 'iss'
    and b.identity_value = p_claims ->> 'sub'
    and b.binding_status = 'active'
    and b.review_status = 'approved'
    and b.valid_from <= now()
    and (b.valid_until is null or b.valid_until > now())
    and p.kind = 'human'::public.principal_kind
    and p.active
  limit 1;
$function$;

create or replace function vault_auth._resolve_agent_principal(p_claims jsonb)
returns uuid
language sql
stable
security definer
set search_path = ''
as $function$
  select b.principal_id
  from vault_auth.principal_identity_bindings b
  join public.principals p on p.id = b.principal_id
  where b.identity_kind = 'oauth_client'
    and b.issuer = p_claims ->> 'iss'
    and b.identity_value = p_claims ->> 'client_id'
    and nullif(p_claims ->> 'client_id', '') is not null
    and b.binding_status = 'active'
    and b.review_status = 'approved'
    and b.valid_from <= now()
    and (b.valid_until is null or b.valid_until > now())
    and p.kind = 'agent'::public.principal_kind
    and p.active
  limit 1;
$function$;

create or replace function vault_auth.current_human_principal_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $function$
  select vault_auth._resolve_human_principal(vault_auth._trusted_request_claims());
$function$;

create or replace function vault_auth.current_agent_principal_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $function$
  select vault_auth._resolve_agent_principal(vault_auth._trusted_request_claims());
$function$;

create or replace function vault_auth.request_token_id()
returns text
language sql
stable
security definer
set search_path = ''
as $function$
  select coalesce(
    nullif(vault_auth._trusted_request_claims() ->> 'jti', ''),
    nullif(vault_auth._trusted_request_claims() ->> 'session_id', '')
  );
$function$;

create or replace function vault_auth.request_has_capability(
  p_resource_scope text,
  p_permission public.capability_permission
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  claims jsonb;
  human_principal uuid;
  agent_principal uuid;
  client_id text;
begin
  claims := vault_auth._trusted_request_claims();
  if claims is null then
    return false;
  end if;

  human_principal := vault_auth._resolve_human_principal(claims);
  if human_principal is null then
    return false;
  end if;

  client_id := nullif(claims ->> 'client_id', '');
  if client_id is null then
    return coalesce(
      public.has_capability(human_principal, p_resource_scope, p_permission),
      false
    );
  end if;

  agent_principal := vault_auth._resolve_agent_principal(claims);
  if agent_principal is null then
    return false;
  end if;

  return coalesce(
    public.has_capability(human_principal, p_resource_scope, p_permission)
    and public.has_capability(agent_principal, p_resource_scope, p_permission),
    false
  );
end;
$function$;

create or replace function vault_auth._validate_identity_binding()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  principal_kind_value public.principal_kind;
begin
  select p.kind into principal_kind_value
  from public.principals p
  where p.id = new.principal_id;

  if principal_kind_value is null then
    raise exception 'identity binding principal does not exist';
  end if;

  if new.identity_kind = 'auth_subject'
     and principal_kind_value <> 'human'::public.principal_kind then
    raise exception 'auth_subject must bind to a human principal';
  end if;

  if new.identity_kind = 'oauth_client'
     and principal_kind_value <> 'agent'::public.principal_kind then
    raise exception 'oauth_client must bind to an agent principal';
  end if;

  if new.binding_status = 'active' and new.review_status <> 'approved' then
    raise exception 'active identity binding must be approved';
  end if;

  if new.review_status = 'approved'
     and (new.reviewed_by is null or new.reviewed_at is null) then
    raise exception 'approved identity binding requires reviewer and review timestamp';
  end if;

  if tg_op = 'UPDATE' then
    new.updated_at := now();
  end if;

  return new;
end;
$function$;

create or replace function vault_auth._audit_identity_binding()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  row_value vault_auth.principal_identity_bindings;
  claims jsonb;
begin
  row_value := coalesce(new, old);
  claims := vault_auth._trusted_request_claims();

  insert into vault_auth.principal_identity_binding_audit (
    binding_id,
    operation,
    database_session_user,
    database_current_user,
    request_token_id,
    request_claims,
    identity_kind,
    issuer,
    identity_value,
    principal_id,
    old_row,
    new_row
  ) values (
    row_value.id,
    tg_op,
    session_user,
    current_user,
    coalesce(nullif(claims ->> 'jti', ''), nullif(claims ->> 'session_id', '')),
    claims,
    row_value.identity_kind,
    row_value.issuer,
    row_value.identity_value,
    row_value.principal_id,
    case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end,
    case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end
  );

  return coalesce(new, old);
end;
$function$;

create trigger principal_identity_bindings_validate
before insert or update on vault_auth.principal_identity_bindings
for each row execute function vault_auth._validate_identity_binding();

create trigger principal_identity_bindings_audit
after insert or update or delete on vault_auth.principal_identity_bindings
for each row execute function vault_auth._audit_identity_binding();

revoke all on all functions in schema vault_auth from public, anon, authenticated, service_role;
revoke all on all sequences in schema vault_auth from public, anon, authenticated, service_role;
revoke all on all tables in schema vault_auth from public, anon, authenticated, service_role;

grant usage on schema vault_auth to authenticated;
grant execute on function vault_auth.request_has_capability(text, public.capability_permission)
  to authenticated;

comment on table vault_auth.principal_identity_bindings is
  'Reviewed mappings from verified request identity tuples to active principals. Deployment data; never publish binding rows.';
comment on table vault_auth.principal_identity_binding_audit is
  'Append-only receipt for every identity-binding mutation, including trusted request claims and per-token/session identifier when available.';
comment on function vault_auth.request_has_capability(text, public.capability_permission) is
  'Fail-closed request capability check. Direct humans require a human grant; OAuth/MCP requests require intersecting human and agent grants.';
comment on function vault_auth._trusted_request_claims() is
  'Returns authenticated JWT claims only when session_user is authenticator. Administrative sessions fail closed even if they fabricate request.jwt.claims.';

-- Sovereign Vault migration 36
-- Non-semantic advisor cleanup for the private identity-binding table.
-- Adds no rows, grants, policies, functions, or public exposure.

create index principal_identity_bindings_created_by_idx
  on vault_auth.principal_identity_bindings(created_by);

create index principal_identity_bindings_reviewed_by_idx
  on vault_auth.principal_identity_bindings(reviewed_by);

create index principal_identity_bindings_supersedes_id_idx
  on vault_auth.principal_identity_bindings(supersedes_id);
