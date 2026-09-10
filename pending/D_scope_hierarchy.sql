-- PENDING OWNER APPROVAL — NOT APPLIED
--
-- Declared containment for scopes. The separate change upstream #45 and the
-- prior identity review both require wildcard semantics to be.
--
-- sql/23 records wildcard matching as "intentionally not implemented".
-- sql/30 makes exact matching a decision rather than an omission and points
-- here. This file is the mechanism. It ships separately, and deliberately after
-- exact-only has been in force, so no scope silently widens between the two.
--
-- ══════════════════════════════════════════════════════════════════════════
-- THE DECISION, AND WHAT WAS REJECTED
-- ══════════════════════════════════════════════════════════════════════════
-- REJECTED: pattern wildcards -- 'workstream:*', LIKE, regex, prefix matching.
--
-- A pattern grant is authority over scopes that DO NOT EXIST YET. Grant
-- 'workstream:*' today and every workstream any future operator invents is
-- retroactively covered by a grant nobody re-reviewed. The grant looks narrow
-- in the audit trail -- one row, one scope string -- while its actual reach
-- grows without a single further decision. That is "global by default" wearing
-- a prefix, which is precisely what #45 exists to prevent.
--
-- It also cannot be reviewed. "Who can read workstream:brand?" stops being a
-- query over grants and becomes a query over grants crossed with every pattern
-- that might match, evaluated against a scope set that changes underneath you.
--
-- CHOSEN: declared containment.
--
--   * A scope may name a parent, forming a tree.
--   * A parent covers its descendants ONLY if it declares confers_descendants.
--   * Containment is resolved over rows that exist, never over patterns.
--
-- Breadth stays available. The difference is that every scope a broad grant
-- reaches is a row somebody wrote on purpose, and adding a new child is an
-- explicit act that visibly extends an existing grant -- reviewable at the
-- moment it happens, which is the only moment it can be caught.
--
-- ══════════════════════════════════════════════════════════════════════════
-- WHY THIS IS STILL A SIGNIFICANT WIDENING, AND MUST BE REVIEWED AS ONE
-- ══════════════════════════════════════════════════════════════════════════
-- confers_descendants is a real transfer of authority. A grant on
-- 'workstream:brand' with a conferring parent reaches 'workstream:brand/social'
-- and everything later filed beneath it. The mitigation is that the reach is
-- enumerable at any instant (scope_effective_grants below) and that extending
-- it requires inserting a child row under a conferring parent -- an act the
-- audit trail records.
--
-- Do not apply this file at the same time as first populating the scope tree.
-- Apply it, then add children one at a time, checking scope_effective_grants
-- after each. A tree built in one motion is a tree nobody reviewed.

alter table scope_registry
  add column parent_scope text references scope_registry(scope),
  add column confers_descendants boolean not null default false;

-- A scope cannot be its own ancestor. Cheap guard against the obvious cycle;
-- deeper cycles are prevented by the recursive resolver's depth cap below.
alter table scope_registry
  add constraint scope_registry_no_self_parent check (parent_scope is distinct from scope);

comment on column scope_registry.confers_descendants is
  'When true, a grant on this scope also authorises every descendant. Default false: breadth is opt-in per scope, declared once, and visible as a column rather than implied by a pattern. It does NOT block inheritance passing through this scope -- see the note in the migration file.';

-- ── A SEMANTIC CHOICE WITH A SURPRISE IN IT, STATED UP FRONT ──────────────
-- confers_descendants describes what a scope does WHEN GRANTED. It does not
-- describe what happens when inheritance passes THROUGH it.
--
-- Given brand (confers=true) > brand/social (confers=FALSE) > brand/social/x,
-- a grant on brand DOES reach brand/social/x. The false on the intermediate
-- does not seal the subtree.
--
-- This is deliberate. The alternative -- a non-conferring node blocking the
-- chain -- would make one column mean two different things (confers when
-- granted, transmits when traversed), and conflated flags are how access
-- control becomes unpredictable.
--
-- But the surprise is real: an operator who sets confers_descendants=false on
-- brand/social expecting to carve it out of a broad grant has not done so, and
-- nothing tells them. If sealing is ever wanted it needs its own column
-- (blocks_inheritance) and its own review, NOT a reinterpretation of this one.
-- Asserted as m03 in the test matrix so the behaviour is pinned rather than
-- incidental.

-- Ancestors of a scope, nearest first. Depth-capped: a cycle in parent_scope
-- would otherwise recurse forever, and a capability check that hangs is an
-- outage. The cap is high enough that no legitimate tree reaches it.
create or replace function scope_ancestors(p_scope text)
returns table (scope text, depth int, confers_descendants boolean)
language sql stable security definer set search_path = public as $$
  with recursive up as (
    select sr.scope, sr.parent_scope, 0 as depth, sr.confers_descendants
    from scope_registry sr where sr.scope = p_scope and sr.retired_at is null
    union all
    select sr.scope, sr.parent_scope, up.depth + 1, sr.confers_descendants
    from scope_registry sr
    join up on sr.scope = up.parent_scope
    where sr.retired_at is null and up.depth < 32
  )
  select up.scope, up.depth, up.confers_descendants from up where up.depth > 0;
$$;

revoke execute on function scope_ancestors(text) from anon, authenticated, public;

-- Replaces the exact-only check. An exact grant still wins first; containment
-- is consulted only when there is no exact grant, so the common path is
-- unchanged and the broad path is the exception.
create or replace function has_capability(
  p_principal_id uuid, p_resource_scope text, p_permission capability_permission
) returns boolean language sql stable security definer set search_path = '' as $$
  select
    exists (
      select 1
      from public.principals p
      join public.capability_grants_active g on g.principal_id = p.id
      where p.id = p_principal_id and p.active
        and g.resource_scope = p_resource_scope
        and (p_permission = any(g.permissions)
          or 'admin'::public.capability_permission = any(g.permissions)))
    or exists (
      select 1
      from public.principals p
      join public.capability_grants_active g on g.principal_id = p.id
      join public.scope_ancestors(p_resource_scope) a on a.scope = g.resource_scope
      where p.id = p_principal_id and p.active
        and a.confers_descendants
        and (p_permission = any(g.permissions)
          or 'admin'::public.capability_permission = any(g.permissions)));
$$;

-- The review surface. "Who can read workstream:brand, and by what route?" must
-- be answerable as a query, or containment is not reviewable and should not
-- ship. inherited_from is null for an exact grant.
create or replace function scope_effective_grants(p_scope text)
returns table (principal_id uuid, display_name text, permissions capability_permission[],
               inherited_from text)
language sql stable security definer set search_path = public as $$
  select g.principal_id, p.display_name, g.permissions, null::text
  from capability_grants_active g
  join principals p on p.id = g.principal_id and p.active
  where g.resource_scope = p_scope
  union all
  select g.principal_id, p.display_name, g.permissions, a.scope
  from capability_grants_active g
  join principals p on p.id = g.principal_id and p.active
  join scope_ancestors(p_scope) a on a.scope = g.resource_scope
  where a.confers_descendants;
$$;

revoke execute on function scope_effective_grants(text) from anon, authenticated, public;

comment on function scope_effective_grants(text) is
  'Every principal with authority on a scope and how they got it. inherited_from names the conferring ancestor, or is null for a direct grant. If this cannot be run, containment cannot be reviewed.';
