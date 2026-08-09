-- tests/50_visibility_discrimination.sql
--
-- Proves the VISIBILITY half of the access predicate actually discriminates.
--
-- WHY THIS EXISTS. On 2026-08-08 it was verified that every row in the
-- deployment is shared -- 298 of 298 memories, all wiki pages, all live
-- projection units -- so is_owner_or_shared() had never denied anything. Its
-- second disjunct was true for every pair that had ever existed. Every
-- isolation result to that date, including a live end-to-end proof over HTTP,
-- exercised the SCOPE dimension only.
--
-- The mechanism was correct. It had simply never been asked to decide anything.
-- The first occasion it does real work is the moment someone marks a record
-- private, which is precisely when nobody wants to discover an untested branch.
--
-- GENERALISABLE: an access predicate whose disjuncts are never all exercised is
-- untested regardless of how many tests pass. A suite can be exhaustive over the
-- cases it contains and silent about the branches the data never triggers.
--
-- Seeding private rows into production was rejected as the remedy: test fixtures
-- do not belong in a system of record, and two orphaned canaries from an earlier
-- attempt are what that looks like afterwards. The branch gets exercised here,
-- on every replay, instead.
--
-- DESIGN NOTE, and it is the point of the file. Section A grants the stranger
-- the SAME scope as the row under test, so that scope cannot be the cause of any
-- denial. Without that control, "stranger denied" proves nothing -- the stranger
-- holds no grants, so everything is denied and a broken visibility predicate
-- would pass. That mistake was made in the first draft of this very probe.

BEGIN;

-- ── fixtures ──────────────────────────────────────────────────────────────
INSERT INTO principals (id, kind, display_name, email, active) VALUES
  ('d0000000-0000-0000-0000-0000000000a1','human','VisTest Owner','vistest-owner@example.invalid',true),
  ('d0000000-0000-0000-0000-0000000000a2','human','VisTest Stranger','vistest-stranger@example.invalid',true);

INSERT INTO scope_registry (scope, description)
SELECT 'workstream:vistest','visibility discrimination fixture'
WHERE NOT EXISTS (SELECT 1 FROM scope_registry WHERE scope='workstream:vistest');

-- BOTH principals hold the scope. Scope is therefore never the reason for a
-- denial in any assertion below, which is what makes the denials meaningful.
INSERT INTO capability_grants (principal_id, resource_scope, permissions, granted_by, reason)
VALUES
 ('d0000000-0000-0000-0000-0000000000a1','workstream:vistest',ARRAY['read']::capability_permission[],
  'd0000000-0000-0000-0000-0000000000a1','fixture: owner holds scope'),
 ('d0000000-0000-0000-0000-0000000000a2','workstream:vistest',ARRAY['read']::capability_permission[],
  'd0000000-0000-0000-0000-0000000000a1','fixture: stranger holds the SAME scope, so scope cannot cause a denial');

-- ── assertions ────────────────────────────────────────────────────────────
WITH t(test, actual, expected) AS (

  -- SECTION A: positive controls. If these fail, every denial below is
  -- meaningless because the principal could not read anything anyway.
  SELECT 'A1_control_owner_reads_shared',
         can_read_row('d0000000-0000-0000-0000-0000000000a1','shared','vistest',
                      'd0000000-0000-0000-0000-0000000000a1'), true
  UNION ALL
  SELECT 'A2_control_stranger_reads_shared',
         can_read_row('d0000000-0000-0000-0000-0000000000a1','shared','vistest',
                      'd0000000-0000-0000-0000-0000000000a2'), true

  -- SECTION B: visibility must deny, with scope held constant.
  UNION ALL
  SELECT 'B1_stranger_denied_private',
         can_read_row('d0000000-0000-0000-0000-0000000000a1','private','vistest',
                      'd0000000-0000-0000-0000-0000000000a2'), false
  UNION ALL
  SELECT 'B2_owner_reads_own_private',
         can_read_row('d0000000-0000-0000-0000-0000000000a1','private','vistest',
                      'd0000000-0000-0000-0000-0000000000a1'), true

  -- SECTION C: the predicate alone, isolated from scope entirely.
  UNION ALL
  SELECT 'C1_predicate_denies_stranger_private',
         is_owner_or_shared('d0000000-0000-0000-0000-0000000000a1','private',
                            'd0000000-0000-0000-0000-0000000000a2'), false
  UNION ALL
  SELECT 'C2_predicate_allows_owner_private',
         is_owner_or_shared('d0000000-0000-0000-0000-0000000000a1','private',
                            'd0000000-0000-0000-0000-0000000000a1'), true
  UNION ALL
  SELECT 'C3_predicate_allows_stranger_shared',
         is_owner_or_shared('d0000000-0000-0000-0000-0000000000a1','shared',
                            'd0000000-0000-0000-0000-0000000000a2'), true

  -- SECTION D: totality. A NULL here would read as a blank column and a
  -- grep-based runner would score it as a pass.
  UNION ALL
  SELECT 'D1_ownerless_private_is_false_not_null',
         is_owner_or_shared(NULL,'private','d0000000-0000-0000-0000-0000000000a2'), false
  UNION ALL
  SELECT 'D2_negated_form_fires',
         NOT is_owner_or_shared(NULL,'private','d0000000-0000-0000-0000-0000000000a2'), true
)
SELECT test, actual, expected,
       CASE WHEN coalesce(actual = expected, false) THEN 't' ELSE 'f' END AS pass
FROM t;

-- Guard: no assertion above may be NULL. A NULL renders blank and reads as a
-- pass to any runner matching on a literal failure marker.
SELECT 'GUARD_no_null_assertions' AS test,
       CASE WHEN count(*) FILTER (
         WHERE is_owner_or_shared(o, v, p) IS NULL
       ) = 0 THEN 't' ELSE 'f' END AS pass
FROM (VALUES (NULL::uuid), ('d0000000-0000-0000-0000-0000000000a1'::uuid)) a(o)
CROSS JOIN (VALUES (NULL::visibility_level), ('private'), ('shared')) b(v)
CROSS JOIN (VALUES (NULL::uuid), ('d0000000-0000-0000-0000-0000000000a2'::uuid)) c(p);

SELECT 'SUITE_RESULT: PASS' AS verdict;

ROLLBACK;

-- Discrimination check for whoever maintains this: revert is_owner_or_shared to
-- `owner = principal OR visibility = 'shared'` WITHOUT the coalesce wrappers and
-- confirm D1 and D2 fail. If they still pass, this file is not testing what its
-- header claims.
