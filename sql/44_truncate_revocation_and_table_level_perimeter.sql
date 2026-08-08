-- 44_truncate_revocation_and_table_level_perimeter.sql
--
-- MIGRATION: 62_truncate_revocation_and_table_level_perimeter
--
-- WO-14 Phase 1b. Confirmed by two independent reviews and re-verified here
-- against production before any change.
--
-- ══════════════════════════════════════════════════════════════════════════
-- THE DEFECT, AND WHY IT IS A CLASS RATHER THAN A GRANT
-- ══════════════════════════════════════════════════════════════════════════
-- Four mechanisms guard the custody substrate. Read as a list they are defence
-- in depth, and every one of them is FOR EACH ROW:
--
--   custody field locks          BEFORE UPDATE ... FOR EACH ROW   sql/39
--   bounded status transitions   BEFORE UPDATE ... FOR EACH ROW   sql/13
--   hard-delete guard + receipt  BEFORE DELETE ... FOR EACH ROW   sql/34
--   append-only audit tables     BEFORE UPDATE OR DELETE ... ROW  sql/26, sql/34
--
-- TRUNCATE is statement-level. A row-level trigger never fires for it. So one
-- statement defeats all four at once, leaves no receipt, and -- because the
-- delete-audit table is itself truncatable by the same privilege -- removes the
-- evidence that it happened.
--
-- We have been reasoning about immutability as though triggers were the
-- perimeter. Triggers are the perimeter only for ROW operations. TRUNCATE, DROP
-- and ALTER are table-level and pass straight through all of it.
--
-- ══════════════════════════════════════════════════════════════════════════
-- MEASURED BEFORE CHANGING ANYTHING
-- ══════════════════════════════════════════════════════════════════════════
-- 32 of 34 tables in public/vault_auth granted TRUNCATE to service_role --
-- including memories, wiki_pages, hard_delete_audit, capability_grants,
-- capability_grant_audit, principals, schema_changelog and perimeter_exception.
-- That is the credential every agent in this system runs under, so this is not
-- "a sufficiently privileged role could": it is the credential all automation
-- already holds.
--
-- The two exceptions are principal_identity_bindings and
-- principal_identity_binding_audit, which sql/35 already stripped to zero
-- access. The pattern this file applies is therefore not new to the codebase;
-- it is the identity tables' posture extended to everything else.
--
-- ══════════════════════════════════════════════════════════════════════════
-- NOBODY GRANTED IT, AND REVOKING IT ONCE WOULD NOT HOLD
-- ══════════════════════════════════════════════════════════════════════════
-- Read from pg_default_acl: the default privileges for tables created by the
-- schema owner in public are `arwdDxtm` to service_role. The `D` is TRUNCATE.
-- It arrives with CREATE TABLE. No migration granted it and no review would
-- have caught it, because nobody reads a default ACL as a grant.
--
-- So a one-time REVOKE fixes 32 tables and nothing else: the next migration
-- that creates a table silently re-introduces it. The ALTER DEFAULT PRIVILEGES
-- below is the actual fix; the REVOKE is the cleanup of what already exists.
-- Doing only the second is the shape of fix that looks complete and decays.
--
-- ══════════════════════════════════════════════════════════════════════════
-- VERIFIED THAT NOTHING LEGITIMATE USES IT
-- ══════════════════════════════════════════════════════════════════════════
-- One place in the codebase issues TRUNCATE: tests/restore_sovereign_package.sh
-- clears schema-seeded bootstrap rows before loading the payload, because the
-- package is authoritative for every row. It connects with a bare `psql -d`,
-- as the cluster owner -- not as service_role. Checked rather than assumed,
-- because "verify nothing legitimate used it" is the step that gets skipped and
-- turns a security fix into an outage.
--
-- ══════════════════════════════════════════════════════════════════════════
-- WHY perimeter_assert() DID NOT SEE THIS -- and it is not what was reported
-- ══════════════════════════════════════════════════════════════════════════
-- The finding was reported as "perimeter_assert examines row-level and function
-- grants only". Reading the applied definition, that is not the gap. It already
-- inspects TABLE grants, via information_schema.role_table_grants, and TRUNCATE
-- appears there like any other privilege.
--
-- The actual blind spot is the GRANTEE filter: `g.grantee in ('anon',
-- 'authenticated')`. The checker was built to answer "what is exposed to the
-- network", so it never looks at service_role at all. Every privilege held by
-- the credential all automation runs under is outside its field of view --
-- not just TRUNCATE.
--
-- Worth stating precisely, because fixing the reported gap (adding table-level
-- inspection) would have changed nothing: the inspection was already there.
--
-- ══════════════════════════════════════════════════════════════════════════
-- PRESERVES MIGRATIONS 58-60, WHICH HAVE NO REPO FILE
-- ══════════════════════════════════════════════════════════════════════════
-- perimeter_assert() was rewritten by migrations 58, 59 and 60 (another effort's
-- vendor-coupling fix) and NONE of them has a file in this repo. sql/28 is
-- therefore stale, and rebuilding this function from sql/28 would have silently
-- reverted the not_evaluated signal that makes an empty result trustworthy on a
-- host lacking the platform roles.
--
-- The body below was read back with pg_get_functiondef() from the live
-- deployment and extended, not reconstructed from the repo. Two individually
-- correct changes composing into a worse outcome is a pattern this project has
-- now hit three times; this is where the fourth would have been.
--
-- service_role is added to the expected-roles list, so on a host lacking it the
-- new category reports not_evaluated rather than an empty -- and therefore
-- clean-looking -- result. That is migration 60's discipline applied to the
-- check being added here rather than only to the one it already covered.

-- ══════════════════════════════════════════════════════════════════════════
-- 1. Stop the default from re-granting it
-- ══════════════════════════════════════════════════════════════════════════
alter default privileges in schema public
  revoke truncate on tables from service_role;
alter default privileges in schema vault_auth
  revoke truncate on tables from service_role;

-- ══════════════════════════════════════════════════════════════════════════
-- 2. Clean up the 32 that already carry it
-- ══════════════════════════════════════════════════════════════════════════
-- TRUNCATE only. DELETE stays: it is governed by the hard-delete guard, which
-- works and writes a receipt. Revoking DELETE would break the sanctioned
-- override path, which is a real capability with a real audit trail, in order
-- to defend against a hole that revoking TRUNCATE already closes.
revoke truncate on all tables in schema public from service_role;
revoke truncate on all tables in schema vault_auth from service_role;

-- ══════════════════════════════════════════════════════════════════════════
-- 3. perimeter_assert(): see the destructive table-level grants
-- ══════════════════════════════════════════════════════════════════════════
create or replace function public.perimeter_assert()
returns table (
  category text,
  object_schema text,
  object_name text,
  grantee text,
  privilege text
) language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  v_missing text[];
begin
  -- Expected-role check, from migration 60, now covering service_role too.
  select coalesce(array_agg(e order by e), '{}')
    into v_missing
  from unnest(array['anon','authenticated','service_role']) e
  where not exists (select 1 from pg_roles r where r.rolname = e);

  if array_length(v_missing, 1) is not null then
    return query
      select 'not_evaluated'::text,
             '-'::text,
             'perimeter cannot be evaluated on this host'::text,
             array_to_string(v_missing, ',')::text,
             ('expected runtime role(s) absent; grant filters matched nothing, so '
              || 'a zero result means NOT CHECKED rather than clean. Re-establish '
              || 'the runtime roles or re-snapshot the perimeter profile before '
              || 'trusting this output.')::text;
  end if;

  -- ── network exposure: unchanged from migration 60 ──────────────────────
  return query
  select 'table_grant'::text, g.table_schema::text, g.table_name::text,
         g.grantee::text, g.privilege_type::text
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

  select 'function_grant'::text, n.nspname::text,
         (p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')')::text,
         r.rolname::text, a.privilege_type::text
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  cross join lateral aclexplode(p.proacl) a
  join pg_roles r on r.oid = a.grantee
  where n.nspname = 'public'
    and r.rolname in ('anon', 'authenticated')
    and p.proacl is not null
    and not exists (
      select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
    and not exists (
      select 1 from perimeter_exception pe
      where pe.object_kind = 'function'
        and pe.object_identity =
            n.nspname||'.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')'
        and pe.grantee = r.rolname)

  union all

  -- ── NEW: destructive table-level privileges, ANY grantee but the owner ──
  -- Deliberately not limited to service_role and not limited to the tables we
  -- currently think are custody-bearing. The defect being fixed was a privilege
  -- nobody granted, held by a role nobody was looking at, on tables nobody had
  -- enumerated. A checker scoped to the instance would miss the next one for
  -- exactly the same reason this one was missed.
  -- The owner is resolved from pg_class.relowner, not from the grants view:
  -- information_schema.role_table_grants exposes grantor and grantee and has no
  -- table_owner column. Caught before apply; a grantor is whoever issued the
  -- grant, which is not the same question.
  select 'destructive_grant'::text, g.table_schema::text, g.table_name::text,
         g.grantee::text, g.privilege_type::text
  from information_schema.role_table_grants g
  join pg_namespace tn on tn.nspname = g.table_schema
  join pg_class tc on tc.relname = g.table_name and tc.relnamespace = tn.oid
  where g.table_schema in ('public','vault_auth')
    and g.privilege_type = 'TRUNCATE'
    and g.grantee <> pg_get_userbyid(tc.relowner)   -- owner cannot be revoked from
    and g.grantee <> 'PUBLIC'
    and not exists (
      select 1 from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      join pg_depend d on d.objid = c.oid and d.deptype = 'e'
      where n.nspname = g.table_schema and c.relname = g.table_name)
    and not exists (
      select 1 from perimeter_exception pe
      where pe.object_kind = 'table'
        and pe.object_identity = g.table_schema||'.'||g.table_name
        and pe.grantee = g.grantee
        and pe.reason like '%TRUNCATE%')     -- a table exception for READ must
                                             -- not silently excuse TRUNCATE

  order by 1, 2, 3;
end; $function$;

comment on function public.perimeter_assert() is
  'Reports grants to anon/authenticated on repo-owned objects in public, AND destructive table-level privileges (TRUNCATE) held by any non-owner role in public/vault_auth. Emits not_evaluated when an expected runtime role is absent, so an empty result means checked-and-clean rather than nothing-matched. Excludes extension-owned objects and declared exceptions; a read exception does not excuse a TRUNCATE grant. Pure SELECT -- never revokes, because an automatic revoke on a false positive takes down legitimate access.';
