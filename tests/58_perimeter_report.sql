-- tests/58_perimeter_report.sql
--
-- WO-18 Task 2. Proves the migration-76 shape does what the concession says.
--
-- Three things have to be true, and the third is the one that motivated the
-- whole argument:
--
--   1. perimeter_assert() is violation-DETAIL: it reports a real violation when
--      one exists, and nothing when none does.
--   2. perimeter_report() reads `evaluated` with violation_count = 0 on a
--      healthy host, and counts a real violation when one is introduced.
--   3. on a host missing an expected platform role, perimeter_report() reads
--      `not_evaluated` with violation_count NULL -- NOT 0 -- so a caller gating
--      on `violation_count = 0` gets NULL, which is not true, and refuses.
--
-- ══════════════════════════════════════════════════════════════════════════
-- HOW SECTION C REACHES THE NOT-EVALUATED BRANCH
-- ══════════════════════════════════════════════════════════════════════════
-- By RENAMING a platform role inside the transaction and rolling back. Renames
-- are transactional DDL in Postgres, and dropping the role is not an option --
-- it owns grants and would fail, or would need a cascade nobody wants in a test.
--
-- This branch is the reason the argument happened and it is the one a parity
-- host cannot exercise, because a parity host that lacks the roles cannot tell
-- the difference between this branch firing and the whole schema being absent.
-- It is exercised here, on every replay, instead.
--
-- The rename is the LAST section on purpose: if it leaves anything behind, the
-- rollback is the only thing standing between this file and a broken cluster,
-- so nothing else depends on state after it.

\set ON_ERROR_STOP on
BEGIN;

CREATE TEMPORARY TABLE t_res(n int, name text, pass boolean, detail text) ON COMMIT DROP;

-- ── SECTION A: the healthy baseline ───────────────────────────────────────
INSERT INTO t_res
SELECT 1, 'A: report reads evaluated on a host with all platform roles',
       (SELECT evaluation_status FROM perimeter_report()) = 'evaluated',
       coalesce((SELECT evaluation_status FROM perimeter_report()), 'NULL');

INSERT INTO t_res
SELECT 2, 'A: report counts zero violations on a clean host',
       (SELECT violation_count FROM perimeter_report()) = 0,
       coalesce((SELECT violation_count::text FROM perimeter_report()), 'NULL');

-- objects_examined exists so that "zero violations" is accompanied by the size
-- of the search that produced it. Zero over zero is not a clean perimeter.
INSERT INTO t_res
SELECT 3, 'A: report states how many objects it examined, and it is not zero',
       (SELECT objects_examined FROM perimeter_report()) > 0,
       coalesce((SELECT objects_examined::text FROM perimeter_report()), 'NULL')
         || ' objects examined';

INSERT INTO t_res
SELECT 4, 'A: primitive returns zero rows on a clean host',
       (SELECT count(*) FROM perimeter_assert()) = 0,
       (SELECT count(*)::text FROM perimeter_assert()) || ' violation row(s)';

-- ── SECTION B: POSITIVE CONTROL -- introduce one real violation ───────────
-- Without this section, every assertion in A is satisfied by a checker that
-- returns nothing under all conditions, which is precisely the failure this
-- project keeps shipping.
CREATE TABLE t_perimeter_canary(id int primary key);
ALTER TABLE t_perimeter_canary ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON t_perimeter_canary TO anon;

INSERT INTO t_res
SELECT 10, 'B control: primitive REPORTS the deliberate grant',
       (SELECT count(*) FROM perimeter_assert()
         WHERE category = 'table_grant'
           AND object_name = 't_perimeter_canary'
           AND grantee = 'anon') = 1,
       coalesce((SELECT string_agg(category||'/'||object_name||'->'||grantee, '; ')
                 FROM perimeter_assert()), 'NOTHING REPORTED');

INSERT INTO t_res
SELECT 11, 'B control: report counts it, and still reads evaluated',
       (SELECT violation_count FROM perimeter_report()) = 1
       AND (SELECT evaluation_status FROM perimeter_report()) = 'evaluated',
       'status=' || coalesce((SELECT evaluation_status FROM perimeter_report()),'NULL')
       || ' count=' || coalesce((SELECT violation_count::text FROM perimeter_report()),'NULL');

INSERT INTO t_res
SELECT 12, 'B control: the violation detail is carried in the report payload',
       (SELECT violations FROM perimeter_report()) @> '[{"object_name":"t_perimeter_canary"}]'::jsonb,
       left(coalesce((SELECT violations::text FROM perimeter_report()),'NULL'), 120);

-- Remove the canary and prove the report goes clean again -- a checker stuck at
-- 1 would satisfy assertion 11 forever.
REVOKE SELECT ON t_perimeter_canary FROM anon;
DROP TABLE t_perimeter_canary;

INSERT INTO t_res
SELECT 13, 'B control: report returns to zero once the grant is removed',
       (SELECT violation_count FROM perimeter_report()) = 0,
       coalesce((SELECT violation_count::text FROM perimeter_report()),'NULL');

-- ── SECTION C: the not-evaluated branch ───────────────────────────────────
-- The branch the whole concession was about.
ALTER ROLE anon RENAME TO anon_hidden_for_suite58;

INSERT INTO t_res
SELECT 20, 'C: a missing platform role reads not_evaluated',
       (SELECT evaluation_status FROM perimeter_report()) = 'not_evaluated',
       coalesce((SELECT evaluation_status FROM perimeter_report()),'NULL')
       || ' missing=' || coalesce((SELECT array_to_string(roles_missing,',')
                                   FROM perimeter_report()),'NULL');

-- THE ASSERTION THIS FILE EXISTS FOR.
INSERT INTO t_res
SELECT 21, 'C: violation_count is NULL, not 0, when nothing could be checked',
       (SELECT violation_count FROM perimeter_report()) IS NULL,
       coalesce((SELECT violation_count::text FROM perimeter_report()),'NULL');

-- And the consequence: the sanctioned gate expression fails closed. `NULL = 0`
-- is NULL, which is not true, so a caller refuses rather than proceeding.
INSERT INTO t_res
SELECT 22, 'C: the gate expression is NOT TRUE on an unevaluated host',
       (SELECT coalesce((violation_count = 0) AND evaluation_status = 'evaluated', false)
        FROM perimeter_report()) IS NOT TRUE,
       'gate evaluated to '
       || coalesce((SELECT ((violation_count = 0) AND evaluation_status='evaluated')::text
                    FROM perimeter_report()),'NULL');

-- The primitive, meanwhile, returns ZERO rows here -- which is exactly why
-- nothing may gate on it. This assertion documents the fail-open rather than
-- fixing it, because the fix is "use the report".
INSERT INTO t_res
SELECT 23, 'C: primitive returns 0 rows on an unevaluated host (documents the fail-open)',
       (SELECT count(*) FROM perimeter_assert()) = 0,
       (SELECT count(*)::text FROM perimeter_assert())
       || ' rows -- a zero here means NOT CHECKED, not clean';

ALTER ROLE anon_hidden_for_suite58 RENAME TO anon;

INSERT INTO t_res
SELECT 24, 'C: the role rename is undone and the report reads evaluated again',
       (SELECT evaluation_status FROM perimeter_report()) = 'evaluated',
       coalesce((SELECT evaluation_status FROM perimeter_report()),'NULL');

INSERT INTO t_res
SELECT 99, 'GUARD_no_null_assertions', count(*) = 0,
       count(*)::text || ' assertion(s) evaluated to NULL' FROM t_res WHERE pass IS NULL;

SELECT n, name, coalesce(pass,false) AS pass, left(detail,70) AS detail FROM t_res ORDER BY n;

SELECT CASE WHEN count(*) = 0 THEN 'SUITE_RESULT: PASS'
            ELSE 'SUITE_RESULT: FAIL' END AS verdict
FROM t_res WHERE pass IS NOT TRUE;

ROLLBACK;

-- Discrimination check for whoever maintains this: change perimeter_report to
-- return 0 instead of NULL for violation_count on the not_evaluated branch and
-- confirm assertions 21 and 22 fail. If they still pass, this file is not
-- testing the thing the concession was about.
