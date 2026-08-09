-- tests/55_control_data_present.sql
--
-- B4 continued. Asserts that the control tables a checker READS are populated
-- on a fresh install, so that a gate cannot report clean merely because it has
-- nothing to evaluate.
--
-- ── THE CLASS THIS GUARDS ─────────────────────────────────────────────────
-- Two controls turned out to exist only as deployment data:
--   language_rules   the compliance detector had NO rules on a fresh install,
--                    and the replay reported clean because there was no rule
--                    left to fail
--   scope_registry   scope_authority_report() returned 0 rows, and row_scope()
--                    emitted a scope that was not registered, so the one scope
--                    the mapping guarantees could not be granted to anyone
--
-- Both were found by comparing a fresh install against the deployment rather
-- than by reading code. This suite is that comparison, made permanent for the
-- generic half -- the half that must be identical on every install.
--
-- It deliberately does NOT assert deployment vocabulary. Domain workstreams,
-- brand phrasings and actor aliases are Rule 0 material and belong to a
-- deployment; asserting them here would fail every install but ours, which is
-- the opposite of a portability check.

\set ON_ERROR_STOP on
begin;

create temporary table t_result(n int, name text, pass boolean, detail text);

-- 1. The reserved scope exists. row_scope() emits it unconditionally for any
--    row with no workstream, and capability_grants.resource_scope is FK-bound
--    to scope_registry -- so without this row the one scope the mapping is
--    guaranteed to produce cannot be granted to anybody.
insert into t_result
select 1, 'the reserved unclassified scope is registered',
  coalesce(exists (select 1 from scope_registry
                   where scope = 'workstream:unclassified' and retired_at is null), false),
  'row_scope(null) = ' || row_scope(null);

-- 2. And it is the scope row_scope() actually emits. Asserted as an equality
--    rather than two independent constants: if someone renames the reserved
--    scope in one place, this fails instead of the pair drifting quietly.
insert into t_result
select 2, 'the registered reserved scope is the one row_scope() emits',
  coalesce(exists (select 1 from scope_registry
                   where scope = row_scope(null) and retired_at is null), false),
  'a mismatch here means a record with no workstream maps to a scope nobody can hold';

-- 3. The regulatory compliance baseline is present. Not "some rules exist" --
--    the specific generic ones, by the authority that marks them generic.
insert into t_result
select 3, 'the regulatory compliance baseline is seeded',
  coalesce(count(*) >= 4, false),
  count(*)::text || ' rule(s) carrying a regulatory authority (expected at least 4)'
from language_rules
where status = 'current' and authority like 'regulatory framework:%';

-- 4. POSITIVE CONTROL, and the one that keeps 3 honest. A rule set can be
--    present and still detect nothing. This runs the detector rather than
--    counting rows.
insert into t_result
select 4, 'positive_control: the seeded rules actually detect a disease claim',
  coalesce((select count(*) from compliance_check('This product treats depression.')
            where finding_kind = 'banned_language' and severity = 'critical') > 0, false),
  'a seeded ruleset that detects nothing is the same failure as no ruleset';

-- 5. NEGATIVE CONTROL. Legitimate structure/function copy must stay silent, or
--    assertion 4 is satisfied by a detector that flags everything.
insert into t_result
select 5, 'negative_control: structure/function copy is not flagged',
  coalesce((select count(*) from compliance_check('Supports a healthy stress response.')
            where finding_kind = 'banned_language') = 0, false),
  'if this fails the detector is not discriminating, it is just noisy';

-- 6. A DOCUMENTED ABSENCE, asserted so it inverts when closed. agent_surface_alias
--    is empty on a fresh install and populated live. An empty alias map resolves
--    nothing, which is instance 5 on this project's list of checks reporting
--    success without checking. It stays deployment data because alias entries
--    name real actors -- but the emptiness is recorded here rather than left to
--    be rediscovered.
insert into t_result
select 6, 'KNOWN: the actor alias map is deployment data and is empty here',
  coalesce((select count(*) from agent_surface_alias) = 0, false),
  'if this fails, aliases are now seeded and this assertion should become a real check';

insert into t_result
select 99,'GUARD_no_null_assertions', coalesce(count(*)=0,false),
  count(*)::text||' assertion(s) evaluated to NULL' from t_result where pass is null;

select n, name, coalesce(pass,false) as pass, left(detail,74) as detail from t_result order by n;

select case when count(*) = 0 then 'SUITE_RESULT: PASS' else 'SUITE_RESULT: FAIL' end as verdict
from t_result where pass is not true;

rollback;
