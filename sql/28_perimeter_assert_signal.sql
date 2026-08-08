-- 28_perimeter_assert_signal.sql
--
-- MIGRATION: 53_perimeter_exception_model
--
-- APPLIED 2026-08-08. perimeter_assert() on the deployment went from 242
-- findings to 0, with 6 declared exceptions, all confirmed still_present.
--
-- Makes perimeter_assert() actionable. It currently is not.
--
-- ── THE FINDING ────────────────────────────────────────────────────────────
-- Run against the deployment on 2026-08-07, perimeter_assert() returned close
-- to two hundred rows. All but ONE were pgvector extension internals --
-- vector_add, halfvec_cmp, l2_distance, sparsevec_out and their kin -- granted
-- EXECUTE to anon and authenticated. Supabase grants extension functions to
-- those roles when the extension is installed. That is not a decision this
-- schema made, is not a perimeter this schema controls, and revoking it would
-- break the vector type for every legitimate caller.
--
-- A local replay shows zero of these, because vanilla PostgreSQL does not apply
-- those default grants. So the check passed locally and was unusable in the one
-- environment it exists to protect -- and nobody noticed, because the signal it
-- produced there was two hundred rows of noise.
--
-- This lesson was already learned once, in the private pre-push secret sweep:
-- a case-insensitive pattern list matched shell builtins, produced false
-- positives on every script, and the fix was to split the patterns rather than
-- to keep a checker nobody could act on. "A checker that cries wolf gets
-- ignored." Same failure, different tool.
--
-- ── WHAT CHANGES ───────────────────────────────────────────────────────────
-- 1. Extension-owned objects are excluded. tests/replay_fresh_install.sh
--    already draws exactly this line when it lists "repo-owned functions"
--    (pg_depend deptype='e'); perimeter_assert simply never did.
-- 2. Deliberate exposures are DECLARED, in a table, with a reason -- not
--    hardcoded into the function body where they become invisible. An
--    undeclared exception buried in a WHERE clause is indistinguishable from a
--    bug, which is how exceptions rot.
-- 3. perimeter_exceptions_review() exists so the exception list is readable on
--    its own. An exception nobody re-reads is a permanent hole with a comment
--    attached.
--
-- The return signature of perimeter_assert() is UNCHANGED. This is deliberate
-- restraint: sql/27 already changes one public signature this work order, and
-- every such change invalidates operating instructions elsewhere (upstream #70).
-- One is a documented cost; two in the same batch is carelessness.

create table if not exists perimeter_exception (
  object_kind     text not null check (object_kind in ('function','table')),
  object_identity text not null,
  grantee         text not null,
  reason          text not null,
  declared_at     timestamptz not null default now(),
  primary key (object_kind, object_identity, grantee)
);

comment on table perimeter_exception is
  'Deliberate, reviewed exposures to anon/authenticated. Every row is a hole someone chose to leave open; the reason column is why. Read it during review -- perimeter_assert() suppresses these, so an unreviewed row here is an unreviewed hole.';

alter table perimeter_exception enable row level security;
revoke all on perimeter_exception from anon, authenticated;

insert into perimeter_exception (object_kind, object_identity, grantee, reason)
values (
  'function',
  -- Must match n.nspname||'.'||proname||'('||pg_get_function_identity_arguments(oid)||')'
  -- EXACTLY, parameter names included. Renaming a parameter therefore breaks the
  -- match and the finding reappears for review, which is the correct direction
  -- to fail: an exception that survives a signature change silently
  -- pre-authorises a function that is no longer the one that was reviewed.
  'public.request_has_capability(p_resource_scope text, p_permission capability_permission)',
  'authenticated',
  'Deliberate API entry point (deployment migration 38, sql/25). SECURITY INVOKER thin wrapper over vault_auth.request_has_capability, which authenticated already holds EXECUTE on; the wrapper adds no privilege and exists only because PostgREST does not expose the vault_auth schema. Invoker is load-bearing: it preserves session_user, which vault_auth._trusted_request_claims() uses to tell a real PostgREST request from an admin session.'
)
on conflict do nothing;

-- ── The three table grants that make the RLS policies operative ───────────
-- RLS filters ROWS; a table-level privilege controls whether the role may touch
-- the table at all. Without these three grants `authenticated` gets "permission
-- denied for table memories" and no policy can ever serve a row -- the model
-- would be installed and unreachable. Migration 48 (sql/37) issued them.
--
-- They are exposures and perimeter_assert is right to see them. What makes them
-- safe is not the grant, it is that each table carries a deny-by-default SELECT
-- policy resolving identity from verified JWT claims (sql/36). The grant opens
-- the door; the policy decides who walks through. Declared together here so a
-- future reader finds the pair rather than the half.
--
-- If any of these three tables ever loses its policy, this exception becomes a
-- real hole. perimeter_exceptions_review() reports presence, not correctness --
-- it cannot tell you the policy still exists. That check is pg_policies, and it
-- is asserted on every replay by the harness's "tables missing RLS" line.
insert into perimeter_exception (object_kind, object_identity, grantee, reason) values
 ('table','public.memories','authenticated',
  'Deliberate (migration 48, sql/37). Table-level SELECT is required for the memories_read policy in sql/36 to be reachable at all; without it authenticated is denied at the privilege layer and RLS never evaluates. Row access is decided by can_read_row_as_request(), which resolves the principal from verified JWT claims and requires read on the row workstream scope.'),
 ('table','public.wiki_pages','authenticated',
  'Deliberate (migration 48, sql/37). Same pairing as memories: the grant makes wiki_pages_read reachable, the policy decides the rows.'),
 ('table','public.retrieval_units','authenticated',
  'Deliberate (migration 48, sql/37). Same pairing. Note the retrieval_units policy resolves back to the SOURCE row rather than trusting the projection copies of owner/visibility/workstream, so this grant cannot serve a row the source would deny.')
on conflict do nothing;

create or replace function perimeter_assert()
returns table (
  category text,
  object_schema text,
  object_name text,
  grantee text,
  privilege text
) language sql stable security definer set search_path = public as $$
  -- Table/view grants to anon or authenticated in public schema.
  select 'table_grant'::text, g.table_schema, g.table_name, g.grantee, g.privilege_type
  from information_schema.role_table_grants g
  where g.table_schema = 'public'
    and g.grantee in ('anon', 'authenticated')
    and not exists (
      select 1 from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      join pg_depend d on d.objid = c.oid and d.deptype = 'e'
      where n.nspname = g.table_schema and c.relname = g.table_name)
    and not exists (
      select 1 from perimeter_exception pe
      where pe.object_kind = 'table'
        and pe.object_identity = g.table_schema||'.'||g.table_name
        and pe.grantee = g.grantee)

  union all

  -- Function execute grants to anon or authenticated. aclexplode() against
  -- pg_proc.proacl directly -- an earlier draft referenced a non-existent
  -- pg_proc_acl_expanded relation and failed on a real database (2026-07-07).
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
    -- Extension-owned: pgvector's grants are Supabase's default on install,
    -- not a perimeter this schema controls. Revoking them breaks the vector
    -- type for every legitimate caller.
    and not exists (
      select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
    and not exists (
      select 1 from perimeter_exception pe
      where pe.object_kind = 'function'
        and pe.object_identity =
            n.nspname||'.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')'
        and pe.grantee = r.rolname)

  order by 1, 2, 3;
$$;

comment on function perimeter_assert() is
  'Reports grants to anon/authenticated on repo-owned objects in public. Excludes extension-owned objects and rows declared in perimeter_exception. Pure SELECT -- never revokes, because an automatic revoke on a false positive takes down legitimate access. Zero rows is the expected steady state.';

create or replace function perimeter_exceptions_review()
returns table (object_kind text, object_identity text, grantee text,
               reason text, declared_at timestamptz, still_present boolean)
language sql stable security definer set search_path = public as $$
  select pe.object_kind, pe.object_identity, pe.grantee, pe.reason, pe.declared_at,
         case pe.object_kind
           when 'function' then exists (
             select 1 from pg_proc p
             join pg_namespace n on n.oid = p.pronamespace
             cross join lateral aclexplode(p.proacl) a
             join pg_roles r on r.oid = a.grantee
             where n.nspname||'.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')'
                   = pe.object_identity
               and r.rolname = pe.grantee)
           else exists (
             select 1 from information_schema.role_table_grants g
             where g.table_schema||'.'||g.table_name = pe.object_identity
               and g.grantee = pe.grantee)
         end
  from perimeter_exception pe;
$$;

comment on function perimeter_exceptions_review() is
  'Lists declared perimeter exceptions. still_present=false means the grant is gone and the exception should be deleted -- a stale exception silently pre-authorises a future re-grant.';

revoke execute on function perimeter_assert() from anon, authenticated, public;
revoke execute on function perimeter_exceptions_review() from anon, authenticated, public;
alter function perimeter_assert() set search_path = public;
