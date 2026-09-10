-- tests/12_compliance_check_disclaimer_and_claim_gating.sql
--
-- compliance_check() regression tests: disclaimer false-positive (blocker fix)
-- and missing_disclaimer over-firing on claim-free text.
--
-- ══════════════════════════════════════════════════════════════════════════
-- WHY THIS FILE NO LONGER DECLARES REQUIRES-DEPLOYMENT
-- ══════════════════════════════════════════════════════════════════════════
-- It used to, for two reasons that were both true when written and are not now:
--
--   1. it needed seeded compliance rules, and a fresh replay had an empty
--      language_rules table. sql/53 now seeds the regulatory baseline -- three
--      banned_phrase rules and the required_phrase disclaimer rule -- so a
--      fresh cluster has exactly what this file needs;
--   2. test 6 carried a literal `<ingredient>` placeholder that a human was
--      expected to substitute. Nobody ever did, because the file never ran.
--
-- The opt-out was therefore load-bearing for nothing, and it cost the whole
-- file: the runner printed SKIP and the top line still said REPLAY CLEAN. A
-- suite that is skipped is not a suite that passed, and for this file the
-- distinction hid six live regression tests over a compliance surface.
--
-- Test 6 now seeds its own ingredient rather than asking for a substitution.
-- NOTE THE COLUMN: compliance_check() matches ingredients on `canonical_name`
-- and `brand_name`, NOT on `name`. A fixture whose canonical_name does not
-- appear in the text under test produces zero findings and the test fails for
-- a reason that has nothing to do with the behaviour it covers. That mistake
-- was made while writing this and caught only by reading the function first.
--
-- ══════════════════════════════════════════════════════════════════════════
-- WHAT THE TESTS COVER
-- ══════════════════════════════════════════════════════════════════════════
-- Bug fixed: a banned_phrase disease-claim regex without lookbehind support
-- (Postgres has none) can match the shape of the FDA-mandated disclaimer
-- sentence itself ("...not intended to diagnose, treat, cure, or prevent any
-- disease"), flagging the one sentence regulation requires. Fixed via a
-- nullable safe_context_pattern column: strip known-safe boilerplate from a
-- working copy of the text before testing a banned_phrase/positioning_rule
-- pattern against it.
--
-- Also fixed: missing_disclaimer firing on any disclaimer-free text, including
-- claim-free headlines. Now gated on the text actually being claim-bearing.

\set ON_ERROR_STOP on
BEGIN;

CREATE TEMPORARY TABLE t_res(n int, name text, pass boolean, detail text) ON COMMIT DROP;

-- Fixture for test 6 only. canonical_name must appear in the text under test.
INSERT INTO ingredients (name, canonical_name, brand_name, is_branded, status,
                         source_kind, provenance_basis)
VALUES ('Suite12 Compound', 'suite12 compound', 'Suite12', true, 'current',
        'manual', 'human_direct');

-- Test 1: disclaimer alone -> zero banned_language findings.
INSERT INTO t_res
SELECT 1, 'disclaimer alone does not flag itself',
  (SELECT count(*) FROM compliance_check(
    'These statements have not been evaluated by the Food and Drug Administration. This product is not intended to diagnose, treat, cure, or prevent any disease.'
  ) WHERE finding_kind = 'banned_language') = 0,
  'banned_language count on the bare disclaimer';

-- Test 2: compliant copy WITH disclaimer -> zero banned_language.
INSERT INTO t_res
SELECT 2, 'compliant copy carrying the disclaimer is clean',
  (SELECT count(*) FROM compliance_check(
    'This product supports focus and mental clarity. These statements have not been evaluated by the Food and Drug Administration. This product is not intended to diagnose, treat, cure, or prevent any disease.'
  ) WHERE finding_kind = 'banned_language') = 0,
  'banned_language count on compliant copy';

-- Test 3: disclaimer PLUS a real violation -> flags the real violation, not the
-- disclaimer. This is the discrimination case: a checker that flagged the
-- disclaimer would also "catch" this one, so both halves are asserted.
INSERT INTO t_res
SELECT 3, 'a real violation is flagged and the disclaimer beside it is not',
  (SELECT count(*) FROM compliance_check(
    'This product cures anxiety disorder. These statements have not been evaluated by the Food and Drug Administration. This product is not intended to diagnose, treat, cure, or prevent any disease.'
  ) WHERE finding_kind = 'banned_language') = 1
  AND
  (SELECT count(*) FROM compliance_check(
    'This product cures anxiety disorder. These statements have not been evaluated by the Food and Drug Administration. This product is not intended to diagnose, treat, cure, or prevent any disease.'
  ) WHERE finding_kind = 'missing_disclaimer') = 0,
  'expect exactly 1 banned_language and 0 missing_disclaimer';

-- Test 4: real disease claim, no disclaimer -> flags both.
INSERT INTO t_res
SELECT 4, 'disease claim without a disclaimer flags both kinds',
  (SELECT count(*) FROM compliance_check('This product cures anxiety and treats depression.')
    WHERE finding_kind = 'banned_language') >= 1
  AND
  (SELECT count(*) FROM compliance_check('This product cures anxiety and treats depression.')
    WHERE finding_kind = 'missing_disclaimer') = 1,
  'expect >=1 banned_language and exactly 1 missing_disclaimer';

-- Test 5: bare compliant headline, no claims -> zero findings at all.
INSERT INTO t_res
SELECT 5, 'a claim-free headline produces no findings at all',
  (SELECT count(*) FROM compliance_check('Check out our new product launch this fall!')) = 0,
  'total finding count on a claim-free headline';

-- Test 6: structure/function claim (ingredient + benefit verb), no disclaimer
-- -> missing_disclaimer still fires. A real claim, just missing the disclaimer.
INSERT INTO t_res
SELECT 6, 'an ingredient claim without a disclaimer still fires missing_disclaimer',
  (SELECT count(*) FROM compliance_check('500mg of Suite12 Compound supports focus.')
    WHERE finding_kind = 'missing_disclaimer') = 1,
  'requires the seeded fixture ingredient to be matched by canonical_name';

-- Guard: a NULL assertion is not a pass. Assertions here are counts compared to
-- integers, which cannot go NULL -- but the guard costs nothing and this
-- project has been bitten by a blank cell reading as success.
INSERT INTO t_res
SELECT 99, 'GUARD_no_null_assertions', count(*) = 0,
  count(*)::text || ' assertion(s) evaluated to NULL' FROM t_res WHERE pass IS NULL;

SELECT n, name, coalesce(pass, false) AS pass, detail FROM t_res ORDER BY n;

-- ══════════════════════════════════════════════════════════════════════════
-- DERIVED VERDICT
-- ══════════════════════════════════════════════════════════════════════════
-- Derived from the assertion rows, never written as a literal. The file
-- previously printed six boolean columns and named no verdict, so the runner
-- could not score it; combined with the deployment opt-out it meant these six
-- regressions had never once been read by the harness.
SELECT CASE WHEN count(*) = 0 THEN 'SUITE_RESULT: PASS'
            ELSE 'SUITE_RESULT: FAIL' END AS verdict
FROM t_res WHERE pass IS NOT TRUE;

ROLLBACK;

-- Discrimination check for whoever maintains this: drop the safe_context_pattern
-- stripping from compliance_check and confirm tests 1, 2 and 3 fail. If they
-- still pass, this file is not testing what its header claims.
