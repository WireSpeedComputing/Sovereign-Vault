-- 02_principals.sql
-- Sovereign Vault (business) — Phase 1: principals and capability grants
--
-- The personal core assumes one owner. A business does not. Every human and
-- every agent that touches this database is a row here, and every permission
-- is explicit, scoped, and reviewable — never implied by "they're on the team"
-- or "it's a trusted agent."
--
-- Design rule: access is a grant, not a role. Roles (Postgres roles, or
-- app-level "admin"/"member") are too coarse and too easy to forget about.
-- A capability_grant says exactly who, what resource, what permission, since
-- when, and until when.

create type principal_kind as enum ('human', 'agent', 'service');

create table principals (
  id            uuid primary key default gen_random_uuid(),
  kind          principal_kind not null,
  display_name  text not null,
  email         text,                     -- humans
  agent_label   text,                     -- agents: e.g. 'AGENT-WEB', 'AGENT-DESKTOP', 'agent-ci-runner'
  external_ref  text,                     -- e.g. auth provider subject, service account id
  active        boolean not null default true,
  deactivated_at timestamptz,
  notes         text,
  created_at    timestamptz not null default now()
);

create unique index principals_email_unique on principals (email) where email is not null;
create unique index principals_agent_label_unique on principals (agent_label) where agent_label is not null;

-- Resource scope is deliberately a text pattern, not a foreign key, so it can
-- point at a workstream ('workstream:brand'), a table ('table:memories'), a
-- specific row ('memory:<uuid>'), or a domain table this business adds later
-- ('table:supplier_orders'). The permission set stays small and composable.
create type capability_permission as enum ('read', 'propose', 'write', 'admin');

create table capability_grants (
  id            uuid primary key default gen_random_uuid(),
  principal_id  uuid not null references principals(id),
  resource_scope text not null,
  permissions   capability_permission[] not null,
  granted_by    uuid not null references principals(id),
  granted_at    timestamptz not null default now(),
  expires_at    timestamptz,
  revoked_at    timestamptz,
  revoked_by    uuid references principals(id),
  reason        text
);

create index on capability_grants (principal_id) where revoked_at is null;
create index on capability_grants (resource_scope) where revoked_at is null;

-- Convenience view: only currently-active grants (not expired, not revoked).
create view capability_grants_active with (security_invoker = true) as
  select * from capability_grants
  where revoked_at is null
    and (expires_at is null or expires_at > now());

-- has_capability(): the one function every RLS policy and every application
-- query should call. Never hand-roll "is this principal an admin" checks
-- elsewhere — they will drift from this definition.
create or replace function has_capability(
  p_principal_id uuid, p_resource_scope text, p_permission capability_permission
) returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from capability_grants_active
    where principal_id = p_principal_id
      and resource_scope = p_resource_scope
      and p_permission = any(permissions)
  )
  or exists (
    -- admin on a scope implies all lesser permissions on that scope
    select 1 from capability_grants_active
    where principal_id = p_principal_id
      and resource_scope = p_resource_scope
      and 'admin' = any(permissions)
  );
$$;

alter table principals        enable row level security;
alter table capability_grants enable row level security;
revoke all on principals, capability_grants from anon, authenticated;
revoke execute on function has_capability(uuid, text, capability_permission) from anon, authenticated, public;
alter function has_capability(uuid, text, capability_permission) set search_path = public;

-- Every capability_grants insert/update/delete is itself consequential —
-- log who granted what to whom outside the generic DDL changelog, since this
-- is data, not schema.
create table capability_grant_audit (
  id bigint generated always as identity primary key,
  changed_at timestamptz not null default now(),
  changed_by uuid,
  operation text not null,
  grant_id uuid,
  principal_id uuid,
  resource_scope text,
  permissions capability_permission[],
  detail jsonb
);

create or replace function audit_capability_grant()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into capability_grant_audit (operation, grant_id, principal_id, resource_scope, permissions, detail)
  values (
    tg_op,
    coalesce(new.id, old.id),
    coalesce(new.principal_id, old.principal_id),
    coalesce(new.resource_scope, old.resource_scope),
    coalesce(new.permissions, old.permissions),
    to_jsonb(coalesce(new, old))
  );
  return coalesce(new, old);
end; $$;

create trigger trg_audit_capability_grant
  after insert or update or delete on capability_grants
  for each row execute function audit_capability_grant();

alter table capability_grant_audit enable row level security;
revoke all on capability_grant_audit from anon, authenticated;
