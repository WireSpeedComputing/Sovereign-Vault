-- tests/31_total_predicate_null_safety.sql
--
-- Proves the access predicate is TOTAL: always boolean, never NULL, including
-- in negated form. Written after a defect where it returned NULL for an
-- ownerless private row, which is harmless in a WHERE clause and a silent
-- bypass in `IF NOT`.
--
-- Discipline note: every assertion below is written so a NULL result reads as
-- FAILURE, not as a blank that a grep-based runner mistakes for a pass. That is
-- not incidental — the same three-valued-logic defect this file tests for also
-- lived in the test harness, where 21 of 24 assertions passed against a
-- function that lacked the feature entirely.

BEGIN;

WITH p AS (
  SELECT '11111111-1111-1111-1111-111111111111'::uuid AS me,
         '22222222-2222-2222-2222-222222222222'::uuid AS other
),
t(test, actual, expected) AS (
  SELECT 'ownerless_private_is_false',      is_owner_or_shared(NULL,    'private', me), false FROM p
  UNION ALL
  SELECT 'ownerless_shared_is_true',        is_owner_or_shared(NULL,    'shared',  me), true  FROM p
  UNION ALL
  SELECT 'owner_reads_own_private',         is_owner_or_shared(me,      'private', me), true  FROM p
  UNION ALL
  SELECT 'other_private_denied',            is_owner_or_shared(other,   'private', me), false FROM p
  UNION ALL
  SELECT 'other_shared_allowed',            is_owner_or_shared(other,   'shared',  me), true  FROM p
  UNION ALL
  SELECT 'both_null_is_false',              is_owner_or_shared(NULL,    NULL,      me), false FROM p
  UNION ALL
  SELECT 'null_principal_private_is_false', is_owner_or_shared(other,   'private', NULL), false FROM p
  UNION ALL
  -- the case that motivated the fix: negation must fire, not vanish
  SELECT 'negated_ownerless_private_fires', NOT is_owner_or_shared(NULL,'private', me), true  FROM p
)
SELECT test,
       actual,
       expected,
       -- coalesce so a NULL actual reports FAIL rather than a blank cell
       CASE WHEN coalesce(actual = expected, false) THEN 't' ELSE 'f' END AS pass
FROM t;

-- Totality guard: no invocation may return NULL under any combination.
SELECT 'GUARD_no_null_assertions' AS test,
       CASE WHEN count(*) FILTER (
              WHERE is_owner_or_shared(o, v, pr) IS NULL
            ) = 0 THEN 't' ELSE 'f' END AS pass
FROM (VALUES (NULL::uuid), ('11111111-1111-1111-1111-111111111111'::uuid)) a(o)
CROSS JOIN (VALUES (NULL::visibility_level), ('private'), ('shared')) b(v)
CROSS JOIN (VALUES (NULL::uuid), ('11111111-1111-1111-1111-111111111111'::uuid)) c(pr);

ROLLBACK;

-- Expected: every pass column 't'. A blank pass column is itself a failure of
-- the harness, not an inconclusive result.
