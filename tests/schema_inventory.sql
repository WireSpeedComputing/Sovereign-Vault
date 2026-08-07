-- tests/schema_inventory.sql
--
-- Emits a DEFINITION-LEVEL inventory of every repo-owned object, one JSON
-- object per line, for tests/canonicalize_inventory.py to canonicalize and
-- hash. Used by export_sovereign_package.sh (source side) and verify_restore.sh
-- (destination side); the two outputs are compared object by object.
--
-- ── WHY THIS EXISTS AND WHAT IT REPLACES ───────────────────────────────────
-- tests/replay_fresh_install.sh establishes equivalence by listing object
-- NAMES filtered to non-extension objects. A reviewer correctly observed that
-- name-equality does not prove definition equivalence: a function with the
-- right name and a rewritten body, a table with the right name and a dropped
-- constraint, an index with the right name over different columns, a trigger
-- pointed at a different function -- all read as "present" to a name check.
--
-- This inventory therefore carries, per object: canonicalized definition,
-- signature, owner, security mode, volatility, search_path, grants, triggers,
-- policies, constraints, indexes, RLS flags, enum labels and comments.
--
-- ── SHAPE ──────────────────────────────────────────────────────────────────
--   {"cat": "...", "key": "...", "attrs": {...}, "def": "..."}
--
--   cat    object category
--   key    stable identity (schema-qualified, signature-qualified for functions)
--   attrs  scalar properties compared verbatim
--   def    free text canonicalized (comments stripped, whitespace collapsed)
--          before hashing -- see the canonicalizer for exactly what that can
--          and cannot prove.
--
-- ── EXCLUSIONS, STATED SO A GREEN RUN IS NOT OVER-READ ─────────────────────
-- Extension-owned objects (pg_depend deptype='e') are excluded, the same line
-- replay_fresh_install.sh and perimeter_assert() draw. Local Postgres installs
-- pgcrypto and vector into `public`; Supabase installs them into `extensions`.
-- Comparing them would compare the two HOSTS, not the two copies of this repo.
-- The cost: an extension version difference between source and destination is
-- invisible here. It is captured separately in the package's version metadata,
-- which is compared as its own check.

\pset format unaligned
\pset tuples_only on
\pset footer off
set timezone = 'UTC';
set datestyle = 'ISO, YMD';
set extra_float_digits = 3;

with
-- Namespaces this repo owns. Anything else is the host's business.
ns as (
  select oid, nspname from pg_namespace where nspname in ('public','vault_auth')
),
-- Objects created by an extension are the host's, not the repo's.
ext as (
  select objid from pg_depend where deptype = 'e'
),

-- ── schemas ────────────────────────────────────────────────────────────────
o_schema as (
  select 'schema'::text as cat, n.nspname::text as key,
         jsonb_build_object('owner', pg_get_userbyid(n2.nspowner)::text) as attrs,
         coalesce(array_to_string(array(
           select unnest(n2.nspacl)::text order by 1), ' '), '')::text as def
  from ns n join pg_namespace n2 on n2.oid = n.oid
),

-- ── enums / composite / domain types ───────────────────────────────────────
o_type as (
  select 'type'::text as cat, (n.nspname||'.'||t.typname)::text as key,
         jsonb_build_object('typtype', t.typtype::text, 'owner', pg_get_userbyid(t.typowner)::text) as attrs,
         coalesce((select string_agg(e.enumlabel::text, ',' order by e.enumsortorder)
                   from pg_enum e where e.enumtypid = t.oid), '')::text as def
  from pg_type t join ns n on n.oid = t.typnamespace
  where t.typtype in ('e','d','c')
    and not exists (select 1 from ext where ext.objid = t.oid)
    -- composite types auto-created for tables are covered by the table entry
    and (t.typtype <> 'c' or not exists (
      select 1 from pg_class c where c.reltype = t.oid and c.relkind <> 'c'))
),

-- ── relations: tables, views, matviews, sequences ──────────────────────────
o_rel as (
  select case c.relkind when 'r' then 'table' when 'v' then 'view'
                        when 'm' then 'matview' when 'S' then 'sequence'
                        when 'p' then 'partitioned_table' else c.relkind::text end as cat,
         (n.nspname||'.'||c.relname)::text as key,
         jsonb_build_object(
           'relkind', c.relkind::text,
           'owner', pg_get_userbyid(c.relowner)::text,
           'rls_enabled', c.relrowsecurity,
           'rls_forced', c.relforcerowsecurity,
           'persistence', c.relpersistence::text,
           'reloptions', coalesce(array_to_string(c.reloptions, ','), ''),
           'acl', coalesce(array_to_string(array(
                    select unnest(c.relacl)::text order by 1), ' '), '(default)'),
           'comment', coalesce(obj_description(c.oid, 'pg_class'), '')
         ) as attrs,
         case when c.relkind in ('v','m') then pg_get_viewdef(c.oid, true) else '' end as def
  from pg_class c join ns n on n.oid = c.relnamespace
  where c.relkind in ('r','v','m','S','p')
    and not exists (select 1 from ext where ext.objid = c.oid)
),

-- ── columns ────────────────────────────────────────────────────────────────
o_col as (
  select 'column'::text as cat,
         (n.nspname||'.'||c.relname||'.'||a.attname)::text as key,
         jsonb_build_object(
           'ordinal', a.attnum,
           'type', format_type(a.atttypid, a.atttypmod),
           'notnull', a.attnotnull,
           'identity', a.attidentity::text,
           'generated', a.attgenerated::text,
           'collation', coalesce((select cl.collname::text from pg_collation cl where cl.oid = a.attcollation), ''),
           'comment', coalesce(col_description(c.oid, a.attnum), '')
         ) as attrs,
         coalesce(pg_get_expr(ad.adbin, ad.adrelid), '') as def
  from pg_attribute a
  join pg_class c on c.oid = a.attrelid
  join ns n on n.oid = c.relnamespace
  left join pg_attrdef ad on ad.adrelid = c.oid and ad.adnum = a.attnum
  where a.attnum > 0 and not a.attisdropped
    and c.relkind in ('r','v','m','p')
    and not exists (select 1 from ext where ext.objid = c.oid)
),

-- ── constraints ────────────────────────────────────────────────────────────
o_con as (
  select 'constraint'::text as cat,
         (n.nspname||'.'||c.relname||'.'||con.conname)::text as key,
         jsonb_build_object('contype', con.contype::text, 'deferrable', con.condeferrable,
                            'validated', con.convalidated) as attrs,
         pg_get_constraintdef(con.oid, true) as def
  from pg_constraint con
  join pg_class c on c.oid = con.conrelid
  join ns n on n.oid = c.relnamespace
  where not exists (select 1 from ext where ext.objid = con.oid)
),

-- ── indexes ────────────────────────────────────────────────────────────────
o_idx as (
  select 'index'::text as cat, (i.schemaname||'.'||i.indexname)::text as key,
         jsonb_build_object('table', (i.schemaname||'.'||i.tablename)::text) as attrs,
         i.indexdef::text as def
  from pg_indexes i
  join ns n on n.nspname = i.schemaname
  where not exists (
    select 1 from pg_class ic join pg_namespace icn on icn.oid = ic.relnamespace
    join ext on ext.objid = ic.oid
    where icn.nspname = i.schemaname and ic.relname = i.indexname)
),

-- ── functions and procedures ───────────────────────────────────────────────
-- prosrc is used rather than pg_get_functiondef() so the canonicalizer sees the
-- body directly instead of a body wrapped in a dollar-quoted literal. Every
-- other property that pg_get_functiondef would have folded into that text --
-- signature, return type, language, volatility, security mode, strictness,
-- leakproofness, parallel safety, search_path, ACL, owner -- is carried
-- explicitly in attrs, where it is compared EXACTLY. Only the body is
-- canonicalized. That split is deliberate: whitespace in a body is noise,
-- whitespace in a security mode is not a thing.
o_fn as (
  select case p.prokind when 'p' then 'procedure' when 'a' then 'aggregate'
                        when 'w' then 'window' else 'function' end as cat,
         (n.nspname||'.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')')::text as key,
         jsonb_build_object(
           'owner', pg_get_userbyid(p.proowner)::text,
           'language', l.lanname::text,
           'returns', pg_get_function_result(p.oid),
           'arguments', pg_get_function_arguments(p.oid),
           'security_definer', p.prosecdef,
           'volatility', p.provolatile::text,
           'strict', p.proisstrict,
           'leakproof', p.proleakproof,
           'parallel', p.proparallel::text,
           'set_config', coalesce(array_to_string(p.proconfig, ' '), ''),
           'acl', coalesce(array_to_string(array(
                    select unnest(p.proacl)::text order by 1), ' '), '(default)'),
           'comment', coalesce(obj_description(p.oid, 'pg_proc'), '')
         ) as attrs,
         coalesce(p.prosrc, '') as def
  from pg_proc p
  join ns n on n.oid = p.pronamespace
  join pg_language l on l.oid = p.prolang
  where not exists (select 1 from ext where ext.objid = p.oid)
),

-- ── triggers ───────────────────────────────────────────────────────────────
o_trg as (
  select 'trigger'::text as cat,
         (n.nspname||'.'||c.relname||'.'||t.tgname)::text as key,
         jsonb_build_object('enabled', t.tgenabled::text, 'internal', t.tgisinternal) as attrs,
         pg_get_triggerdef(t.oid, true) as def
  from pg_trigger t
  join pg_class c on c.oid = t.tgrelid
  join ns n on n.oid = c.relnamespace
  where not t.tgisinternal
    and not exists (select 1 from ext where ext.objid = t.oid)
),

-- ── event triggers (not schema-scoped, but this repo owns one) ─────────────
o_evt as (
  select 'event_trigger'::text as cat, et.evtname::text as key,
         jsonb_build_object('event', et.evtevent, 'enabled', et.evtenabled::text,
                            'owner', pg_get_userbyid(et.evtowner)::text) as attrs,
         (select (n.nspname||'.'||p.proname)::text from pg_proc p
          join pg_namespace n on n.oid = p.pronamespace where p.oid = et.evtfoid) as def
  from pg_event_trigger et
  where not exists (select 1 from ext where ext.objid = et.oid)
),

-- ── row level security policies ────────────────────────────────────────────
-- Zero rows today, and that is itself a finding worth carrying: every table has
-- RLS ENABLED with no policy, which is deny-all for non-superusers. A restore
-- that silently gained a permissive policy would be a sovereignty break that a
-- row-count check would never see.
o_pol as (
  select 'policy' as cat,
         (pol.schemaname||'.'||pol.tablename||'.'||pol.policyname)::text as key,
         jsonb_build_object('permissive', pol.permissive, 'roles', pol.roles::text,
                            'command', pol.cmd) as attrs,
         coalesce(pol.qual,'')||' ||WITHCHECK|| '||coalesce(pol.with_check,'') as def
  from pg_policies pol
  join ns n on n.nspname = pol.schemaname
),

-- ── default privileges ─────────────────────────────────────────────────────
-- sql/07 is the file that exists because Supabase default-grants to
-- anon/authenticated. On vanilla Postgres its REVOKEs record nothing here,
-- because there was never a grant to revoke. An empty result is expected
-- locally and is NOT evidence the file works on a hosted project.
o_defacl as (
  select 'default_acl' as cat,
         (coalesce(n.nspname::text,'-')||'.'||d.defaclobjtype::text||'.'||pg_get_userbyid(d.defaclrole))::text as key,
         jsonb_build_object('objtype', d.defaclobjtype::text) as attrs,
         coalesce(array_to_string(array(select unnest(d.defaclacl)::text order by 1), ' '), '') as def
  from pg_default_acl d
  left join pg_namespace n on n.oid = d.defaclnamespace
),

-- ── extensions (recorded, not compared as repo objects) ────────────────────
o_ext as (
  select 'extension'::text as cat, e.extname::text as key,
         jsonb_build_object('version', e.extversion::text,
                            'schema', (select nspname::text from pg_namespace where oid = e.extnamespace)) as attrs,
         '' as def
  from pg_extension e
),

all_objs as (
  select * from o_schema union all select * from o_type   union all
  select * from o_rel    union all select * from o_col    union all
  select * from o_con    union all select * from o_idx    union all
  select * from o_fn     union all select * from o_trg    union all
  select * from o_evt    union all select * from o_pol    union all
  select * from o_defacl union all select * from o_ext
)
select jsonb_build_object('cat', cat, 'key', key, 'attrs', attrs, 'def', def)::text
from all_objs
order by cat, key;
