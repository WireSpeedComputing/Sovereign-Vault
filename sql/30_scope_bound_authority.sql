-- 30_scope_bound_authority.sql
--
-- ADOPT: upstream sovereign-memory-core #45 — scope-bound authority.
-- NOT YET APPLIED to any deployment.
--
-- Designed AGAINST the deployed vault_auth layer (sql/23) and modifies none of
-- it. vault_auth.request_has_capability() resolves identity and then delegates
-- every scope decision to public.has_capability(). That delegation is the seam
-- this file works in: scope semantics live in public, identity resolution stays
-- in vault_auth, and neither has to know the other's internals.
--
-- ══════════════════════════════════════════════════════════════════════════
-- FINDING FIRST: THE CAPABILITY MODEL IS NOT WIRED TO ANYTHING
-- ══════════════════════════════════════════════════════════════════════════
-- Nothing in this repo calls has_capability() or request_has_capability().
-- Not one RLS policy, not one function, not one view. Grepped across all of
-- sql/: the only occurrences outside the definition sites are a comment and a
-- perimeter_exception reason string.
--
-- So the authority model is currently decorative. It is a well-built lock with
-- no door in the frame. Every property below -- scope validation, registry,
-- isolation -- is real and testable at the capability layer, and none of it
-- constrains a single read or write of knowledge today, because no read or
-- write path consults it.
--
-- This is the same shape as the #46 finding: promote_memory() looked like a
-- chokepoint and was a convenience wrapper. has_capability() looks like an
-- authorization boundary and is an unreferenced function. Recording it here
-- rather than quietly building on top, because a scope model that nothing
-- enforces will read as "scoped authority: done" in six months.
--
-- Wiring it is deliberately NOT in this file. It means deciding how capability
-- scope composes with the existing owner/visibility filter in retrieve_context()
-- -- whether scope narrows visibility, replaces it, or unions with it -- and
-- getting that wrong silently widens access. See docs/05-scope-bound-authority.md
-- for the three options and the recommendation.
--
-- ══════════════════════════════════════════════════════════════════════════
-- WHY A REGISTRY, AND WHY IT IS THE POINT
-- ══════════════════════════════════════════════════════════════════════════
-- resource_scope is free text. A grant on 'workstream:brnad' is syntactically
-- indistinguishable from one on 'workstream:brand'. It inserts cleanly, reads
-- back cleanly, appears in every audit view, and authorises nothing.
--
-- That is not hypothetical. This deployment lost an afternoon to exactly this
-- failure one layer over: an identity binding was written with
-- issuer='supabase_auth', a sensible-looking label rather than the literal iss
-- claim URL, and every binding silently failed to resolve while looking
-- perfectly healthy. Same class of bug -- an unvalidated string that only
-- reveals itself as wrong by producing no effect.
--
-- Fail-closed is the right default and both cases are fail-closed. But silent
-- fail-closed is still a defect: the operator believes authority was granted.
-- A registry with a foreign key turns a typo from a silent no-op into an error
-- at grant time, which is the only moment anyone is paying attention.

-- ── Scope grammar ──────────────────────────────────────────────────────────
-- <kind>:<identifier>, kinds enumerated.
--
-- There is deliberately NO 'global' or 'all' kind. Upstream #45 requires
-- authority declared per named scope, never global by default; the cleanest way
-- to guarantee that is for the type system to have no way to express it. An
-- operator who needs breadth grants several scopes, and that grant is legible
-- in the audit trail as several scopes.
create type scope_kind as enum (
  'workstream',  -- a stream of work: workstream:brand
  'table',       -- a whole relation: table:memories
  'record',      -- one row: record:<uuid>
  'domain'       -- a consequential domain (see sql/03 provenance_registry): domain:financial
);

create table scope_registry (
  scope         text primary key,
  kind          scope_kind not null,
  identifier    text not null,
  description   text not null,
  declared_by   uuid references principals(id),
  declared_at   timestamptz not null default now(),
  retired_at    timestamptz,
  constraint scope_registry_wellformed
    check (scope = kind::text || ':' || identifier),
  constraint scope_registry_identifier_shape
    check (identifier ~ '^[a-z0-9][a-z0-9_./-]*$')
);

comment on table scope_registry is
  'Every scope authority can be granted on. A scope must be declared here before it can be granted, so a typo fails at grant time instead of silently authorising nothing. Retiring a scope (retired_at) does not revoke grants on it -- see scope_cutover and the revocation note in docs/05.';

alter table scope_registry enable row level security;
revoke all on scope_registry from anon, authenticated;

create or replace function scope_parse_kind(p_scope text)
returns scope_kind language sql immutable as $$
  select case when position(':' in p_scope) > 0
              then split_part(p_scope, ':', 1)::scope_kind end;
$$;

create or replace function scope_parse_identifier(p_scope text)
returns text language sql immutable as $$
  select nullif(substring(p_scope from position(':' in p_scope) + 1), '');
$$;

revoke execute on function scope_parse_kind(text) from anon, authenticated, public;
revoke execute on function scope_parse_identifier(text) from anon, authenticated, public;

-- ── Bind grants to declared scopes ─────────────────────────────────────────
-- Safe to add HERE: the deployment has zero capability grants, verified before
-- writing this. On a deployment that had grants, this FK needs every existing
-- scope registered first, and that backfill is the migration -- not this
-- constraint.
--
-- ⚠ THIS IS A COMPATIBILITY BREAK, not just a constraint. Any caller granting
-- an ad-hoc scope string now fails. It broke a real test on first run:
-- tests/22_identity_capability_enforcement.sql granted 'test:scope', which is
-- both unregistered and not a valid kind. That test was updated to declare a
-- scope first -- its subject is identity-to-capability resolution, for which
-- the scope string was always arbitrary.
--
-- The breakage is the feature working. But anything outside this repo that
-- writes grants -- an onboarding script, a seeding job -- will break the same
-- way, and should be found before this is applied rather than after.
alter table capability_grants
  add constraint capability_grants_scope_declared
  foreign key (resource_scope) references scope_registry(scope);

-- ── Exact matching, stated as a decision rather than an omission ───────────
-- has_capability() matches resource_scope by equality. That is unchanged here,
-- and it is now DELIBERATE rather than incidental.
--
-- WILDCARD SEMANTICS -- DECIDED, IMPLEMENTED SEPARATELY.
-- The prior identity review required wildcard semantics be a separate change,
-- and sql/23 records it as "intentionally not implemented". That separation is
-- honoured: the decision is made here, the mechanism ships in its own file.
--
-- Decision: NOT pattern wildcards. Declared containment.
--   * Rejected: pattern matching ('workstream:*', LIKE, regex). A pattern grant
--     is authority over scopes that do not exist yet -- anything a future
--     operator names under that prefix is retroactively covered by a grant
--     nobody re-reviewed. That is "global by default" wearing a prefix.
--   * Chosen: scopes may declare a parent in the registry, forming a tree, and
--     a grant covers a descendant only when the ancestor explicitly declares
--     that it confers downward. Breadth stays possible, and every scope it
--     reaches is a row someone wrote on purpose.
-- Grammar, containment rules and the full test matrix:
-- pending/D_scope_hierarchy.sql. Exact-only remains in force until that lands,
-- so nothing here silently widens.
comment on function has_capability(uuid, text, capability_permission) is
  'Exact-scope capability check for active principals only. Scope matching is equality, deliberately: wildcard/pattern semantics are rejected in favour of declared containment (see pending/D_scope_hierarchy.sql). Administrative/service use only; authenticated requests go through public.request_has_capability().';

-- ── Scope-bound cutover declaration ────────────────────────────────────────
-- Upstream #45 asks for a cutover declaration bound to a scope. The existing
-- import_cutover_scorecard (sql/06) answers "is this SOURCE fully accounted
-- for?"; it says nothing about which scope the vault is now authoritative FOR.
-- Those are different questions and the second is the one a founder needs
-- answered before trusting a workstream.
create table scope_cutover (
  id                uuid primary key default gen_random_uuid(),
  scope             text not null references scope_registry(scope),
  declared_by       uuid not null references principals(id),
  declared_at       timestamptz not null default now(),
  source_system     text,      -- what this scope is authoritative INSTEAD OF
  evidence          text not null,
  actor_assurance   text not null default 'caller_asserted_unauthenticated',
  superseded_at     timestamptz
);

-- The real invariant is "at most one LIVE declaration per scope", not
-- uniqueness of (scope, declared_at). The first draft used the latter as a
-- primary key and a test caught it immediately: now() is transaction time, so
-- two declarations in one transaction collide on an identical timestamp while
-- two declarations a second apart -- the actually-wrong case -- were both
-- accepted. Timestamps make bad keys.
create unique index scope_cutover_one_live_uq
  on scope_cutover (scope) where superseded_at is null;

comment on table scope_cutover is
  'Declares that the vault is authoritative for a named scope, replacing a prior source. actor_assurance carries the same caveat as sql/20: a caller-supplied principal UUID proves the UUID belongs to an active human, not that the caller is that human.';

alter table scope_cutover enable row level security;
revoke all on scope_cutover from anon, authenticated;

create or replace function declare_scope_cutover(
  p_scope text, p_declared_by uuid, p_evidence text, p_source_system text default null
) returns text language plpgsql security definer set search_path = public as $$
declare v_kind principal_kind;
begin
  if not exists (select 1 from scope_registry where scope = p_scope and retired_at is null) then
    raise exception 'scope % is not a declared, active scope', p_scope;
  end if;

  select kind into v_kind from principals where id = p_declared_by and active;
  if not found then
    raise exception 'declarer % is not an active principal', p_declared_by;
  end if;
  if v_kind <> 'human' then
    raise exception 'only human principals declare a scope cutover (%: %)', p_declared_by, v_kind;
  end if;
  if p_evidence is null or length(trim(p_evidence)) = 0 then
    raise exception 'a cutover declaration requires evidence';
  end if;

  update scope_cutover set superseded_at = now()
   where scope = p_scope and superseded_at is null;

  insert into scope_cutover (scope, declared_by, source_system, evidence)
  values (p_scope, p_declared_by, p_source_system, p_evidence);
  return 'declared';
end; $$;

revoke execute on function declare_scope_cutover(text, uuid, text, text)
  from anon, authenticated, public;

create or replace function scope_authority_report()
returns table (scope text, kind scope_kind, cutover_declared boolean,
               declared_at timestamptz, source_system text,
               active_grants bigint, enforced boolean)
language sql stable security definer set search_path = public as $$
  select sr.scope, sr.kind,
         c.scope is not null,
         c.declared_at, c.source_system,
         (select count(*) from capability_grants_active g where g.resource_scope = sr.scope),
         -- Honest until a read path consults capabilities. See the finding at
         -- the top of sql/30: nothing calls has_capability(), so no scope is
         -- enforced regardless of how many grants exist.
         false
  from scope_registry sr
  left join scope_cutover c on c.scope = sr.scope and c.superseded_at is null
  where sr.retired_at is null;
$$;

comment on function scope_authority_report() is
  'Per-scope authority summary. enforced is hardcoded false and that is not a placeholder: no read or write path in this schema calls has_capability(), so no scope constrains anything yet. It becomes a real column when the first policy consults capabilities.';

revoke execute on function scope_authority_report() from anon, authenticated, public;
