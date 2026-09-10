-- 61_perimeter_report.sql
--
-- MIGRATION: 76_perimeter_report
--
-- WO-18 Task 2. Implements the design the reviewing session ruled for and
-- this one conceded. Codenames are Rule 0 identifiers and do not belong in a
-- public repo; the sweep caught this line before it was pushed.
--
-- ══════════════════════════════════════════════════════════════════════════
-- WHAT WAS WRONG WITH THE SHIPPED DESIGN
-- ══════════════════════════════════════════════════════════════════════════
-- Migration 44 made perimeter_assert() emit a `not_evaluated` ROW when the
-- expected platform roles are absent, so that a role-less host could not read
-- as clean. The intent was right and the placement was wrong.
--
-- perimeter_assert()'s contract is "every row I return is a violation". Putting
-- a status row inside that result set means:
--
--   * `select count(*) from perimeter_assert()` returns 1 on a host where
--     NOTHING WAS CHECKED, and 1 on a host with exactly one real violation.
--     Two entirely different facts, one number.
--   * a caller filtering by category -- `where category = 'table_grant'` --
--     gets zero rows on an unevaluated host and reads it as clean. That is the
--     original fail-open, reintroduced one level down.
--   * "I found nothing" and "I could not look" are the two answers a perimeter
--     check must never conflate, and that design conflated them for any caller
--     that counts.
--
-- ══════════════════════════════════════════════════════════════════════════
-- THE SHAPE
-- ══════════════════════════════════════════════════════════════════════════
-- 1. perimeter_assert() is RESTORED to violation-only. Same signature, same
--    three checks, minus the status row. It remains the violation-DETAIL
--    primitive, which is what tests/46 legitimately consumes when it asserts
--    that a specific deliberate exposure is reported.
--
-- 2. perimeter_report() is the SANCTIONED ENTRY POINT. One row, carrying the
--    evaluation status separately from the findings, so the two questions have
--    two answers.
--
-- WHY violation_count IS NULL AND NOT 0 WHEN UNEVALUATED. It is the only value
-- that fails closed by construction: `violation_count = 0` evaluates to NULL,
-- which is not true, so any caller gating on it refuses rather than proceeds.
-- Returning 0 would hand a clean answer to precisely the host that could not
-- produce one, which is the bug this migration exists to remove.
--
-- ══════════════════════════════════════════════════════════════════════════
-- THE PART THAT IS NOT OPTIONAL
-- ══════════════════════════════════════════════════════════════════════════
-- Restoring the primitive WITHOUT migrating callers is worse than leaving the
-- rejected design in place: the replay harness asserts count(*) = 0 against the
-- primitive, and a violation-only primitive returns 0 rows on a role-less host,
-- which is the original fail-open verbatim. Every counting caller moves to
-- perimeter_report() in this same change. The callers migrated are listed in
-- STATUS.md alongside this migration number.

-- ── 1. RESTORE THE PRIMITIVE ──────────────────────────────────────────────
create or replace function public.perimeter_assert()
returns table(category text, object_schema text, object_name text,
              grantee text, privilege text)
language plpgsql stable security definer set search_path to 'public' as $function$
begin
  -- No expected-role check here any more. A role-less host makes every filter
  -- below match nothing, so this function returns zero rows -- which is why it
  -- MUST NOT be the thing anyone gates on. perimeter_report() carries that.

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

  -- ── destructive table-level privileges, ANY grantee but the owner ───────
  -- Deliberately not limited to service_role and not limited to the tables we
  -- currently think are custody-bearing. The defect being fixed was a privilege
  -- nobody granted, held by a role nobody was looking at, on tables nobody had
  -- enumerated. The owner is resolved from pg_class.relowner, not from the
  -- grants view: information_schema.role_table_grants has no table_owner
  -- column, and a grantor is a different question.
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
  'VIOLATION DETAIL ONLY. Every row returned is a violation. Returns zero rows on a host where the expected platform roles are absent, because the filters match nothing -- so a zero here does NOT mean clean and nothing may gate on it. Gate on perimeter_report(). Restored to this contract by migration 76 after migration 44 put a not_evaluated status row inside the result set, which made count(*) return 1 for "nothing was checked" and 1 for "one real violation".';

-- ── 2. THE SANCTIONED ENTRY POINT ─────────────────────────────────────────
create or replace function public.perimeter_report()
returns table(
  evaluation_status  text,
  expected_roles     text[],
  roles_present      text[],
  roles_missing      text[],
  categories_checked text[],
  objects_examined   int,
  violation_count    int,
  checker_version    text,
  violations         jsonb
)
language plpgsql stable security definer set search_path to 'public' as $function$
declare
  v_expected text[] := array['anon','authenticated','service_role'];
  v_present  text[];
  v_missing  text[];
  v_objects  int;
begin
  select coalesce(array_agg(e order by e), '{}') into v_present
  from unnest(v_expected) e
  where exists (select 1 from pg_roles r where r.rolname = e);

  select coalesce(array_agg(e order by e), '{}') into v_missing
  from unnest(v_expected) e
  where not exists (select 1 from pg_roles r where r.rolname = e);

  -- What the three checks actually scan, so a zero violation count is
  -- accompanied by the size of the search that produced it. Zero violations
  -- over zero objects is not the same claim as zero over four hundred.
  select (select count(*) from pg_class c
          join pg_namespace n on n.oid = c.relnamespace
          where n.nspname in ('public','vault_auth') and c.relkind = 'r'
            and not exists (select 1 from pg_depend d
                            where d.objid = c.oid and d.deptype = 'e'))
       + (select count(*) from pg_proc p
          join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'public'
            and not exists (select 1 from pg_depend d
                            where d.objid = p.oid and d.deptype = 'e'))
    into v_objects;

  if array_length(v_missing, 1) is not null then
    -- NOT EVALUATED. violation_count is NULL, not 0 -- see the header. A caller
    -- gating on `violation_count = 0` gets NULL, which is not true, and refuses.
    return query select
      'not_evaluated'::text, v_expected, v_present, v_missing,
      array['table_grant','function_grant','destructive_grant']::text[],
      v_objects, null::int, 'perimeter_report/1 (migration 76)'::text,
      null::jsonb;
    return;
  end if;

  return query select
    'evaluated'::text, v_expected, v_present, v_missing,
    array['table_grant','function_grant','destructive_grant']::text[],
    v_objects,
    (select count(*)::int from perimeter_assert()),
    'perimeter_report/1 (migration 76)'::text,
    (select coalesce(jsonb_agg(to_jsonb(pa)), '[]'::jsonb) from perimeter_assert() pa);
end; $function$;

comment on function public.perimeter_report() is
  'SANCTIONED PERIMETER ENTRY POINT (migration 76). One row. Gate on evaluation_status = ''evaluated'' AND violation_count = 0 -- both, never violation_count alone. On a host missing any expected platform role, evaluation_status is not_evaluated and violation_count is NULL rather than 0, so the gate fails closed instead of reading a role-less host as clean. objects_examined is reported so that zero violations over zero objects is distinguishable from zero over a real search. perimeter_assert() remains available as violation detail and must not be gated on.';

revoke execute on function public.perimeter_report() from anon, authenticated, public;

-- No changelog insert here. schema_changelog is populated by the DDL event
-- trigger and has no `migration` column -- it records changed_at, db_user,
-- command_tag, object_type, object_identity, note. A hand-written insert
-- naming a migration number would have failed on apply, and was in the first
-- draft of this file. Checked against the catalogue before applying rather
-- than after.
