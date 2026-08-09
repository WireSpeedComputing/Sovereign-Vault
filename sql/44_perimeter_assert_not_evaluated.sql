-- 49_perimeter_assert_not_evaluated.sql
--
-- MIGRATION: 58
-- MIGRATION: 59
-- MIGRATION: 60
--
-- Three applied migrations, one file, deliberately. 58 and 59 were broken
-- intermediate states and a fresh install must never apply them. Only the final
-- body below is correct. The mapping headers exist so the drift checker
-- reconciles; the history is recorded in prose rather than in replayable DDL.
--
-- ══════════════════════════════════════════════════════════════════════════
-- WHY THIS EXISTS — the defect, and why it compounds
-- ══════════════════════════════════════════════════════════════════════════
-- perimeter_assert() filters on the platform roles `anon` and `authenticated`.
-- On a host where those roles do not exist -- vanilla PostgreSQL, which is
-- exactly the provider-exit restore target -- the filters match nothing and the
-- function returns ZERO ROWS. It reports a clean perimeter on a database where
-- it verified nothing.
--
-- A provider-exit drill posed this as an open question: "if it fails closed the
-- runbook needs a re-snapshot step; if it fails open, that is a finding."
-- Answered before the drill rather than during it: **it fails open.**
--
-- It compounds. A restore rebuilds from this repository. While this fix existed
-- only inside the hosted database and not here, a restored vault would have
-- received the BROKEN checker -- on the host where it fails open. The fix for
-- the fail-open lived only in the place you would lose. That is the reason this
-- file exists at all, and it was found by a coupling hunt run on a genuine
-- vanilla host rather than by reading the source.
--
-- FIXED IN THE SCHEMA, NOT THE RUNBOOK. A runbook note saying "remember this
-- check is meaningless here" gets skipped by whoever is restoring at 2am under
-- pressure, which is the only time a restore actually happens.
--
-- SHAPE: the absence of evaluation is emitted as a FINDING. A companion status
-- function was rejected -- it reproduces the same problem one level up, needing
-- a consumer to remember to consult it. After this, an empty result means
-- genuinely clean and any non-empty result means look. The consumer needs no
-- new discipline.
--
-- ══════════════════════════════════════════════════════════════════════════
-- WHAT 58 AND 59 GOT WRONG — recorded because the failure is instructive
-- ══════════════════════════════════════════════════════════════════════════
-- 58 rewrote the function from inference and referenced perimeter_exception
-- columns that do not exist. It APPLIED CLEANLY -- plpgsql bodies are not
-- validated at creation, so a function referencing a missing column installs
-- fine and raises only on first call. That trap is documented elsewhere in this
-- repo and was walked into anyway.
--
-- 59 corrected the column names but was still a rewrite, and dropped exclusion
-- logic the original had: extension-owned object filtering, the schema-qualified
-- object_identity format the exception table actually stores, aclexplode()
-- against proacl rather than has_function_privilege(), and service_role
-- correctly not being inspected. Result: 309 findings where the answer is 0.
--
-- 60 restored the original body verbatim from sql/28 and added one conditional.
-- Two rewrites of a working security check without reading it; the original was
-- in this repository the whole time and took one command to fetch. Caught in
-- seconds only because a predicted number was stated before verifying.
--
-- Language changes from sql to plpgsql to allow the conditional. Signature,
-- columns and argument list unchanged.

create or replace function perimeter_assert()
returns table (
  category text,
  object_schema text,
  object_name text,
  grantee text,
  privilege text
) language plpgsql stable security definer set search_path = public as $$
declare
  v_missing text[];
begin
  select coalesce(array_agg(e order by e), '{}')
    into v_missing
  from unnest(array['anon','authenticated']) e
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

  -- Below: sql/28 verbatim.
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

  order by 1, 2, 3;
end; $$;

-- PORTABILITY NOTE for whoever restores this onto a vanilla host: this file must
-- survive application on a cluster where anon/authenticated do not exist. Any
-- REVOKE or GRANT naming those roles will abort before this function is created,
-- leaving the STALE fail-open version in place -- which is the worst possible
-- outcome and was observed during the coupling hunt. Keep role-dependent
-- statements out of this file.
