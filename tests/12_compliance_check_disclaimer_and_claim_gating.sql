-- compliance_check() regression tests: disclaimer false-positive (blocker fix) and
-- missing_disclaimer over-firing on claim-free text. Run against a live deployment
-- with the standard disease-claim rule (a rule_type='banned_phrase' row whose pattern
-- matches a treatment-verb-near-disease-noun shape) and required disclaimer rule
-- (a rule_type='required_phrase' row requiring "not evaluated by the food and drug
-- administration") both present and status='current'.
--
-- Bug fixed: a banned_phrase disease-claim regex without lookbehind support (Postgres
-- has none) can match the shape of the FDA-mandated disclaimer sentence itself
-- ("...not intended to diagnose, treat, cure, or prevent any disease"), flagging the
-- one sentence regulation requires. Fixed via a nullable safe_context_pattern column:
-- strip known-safe boilerplate from a working copy of the text before testing a
-- banned_phrase/positioning_rule pattern against it.
--
-- Also fixed: missing_disclaimer firing on any disclaimer-free text, including
-- claim-free headlines. Now gated on the text actually being claim-bearing (a
-- banned_language/positioning finding fired, an ingredient_claims row matched
-- regardless of pass/fail, or an ingredient mention appears alongside a generic
-- benefit verb).

-- Test 1: disclaimer alone -> zero banned_language findings.
SELECT 'test_1_disclaimer_alone' AS test,
  (SELECT count(*) FROM compliance_check(
    'These statements have not been evaluated by the Food and Drug Administration. This product is not intended to diagnose, treat, cure, or prevent any disease.'
  ) WHERE finding_kind = 'banned_language') = 0 AS pass;

-- Test 2: compliant copy WITH disclaimer -> zero banned_language.
SELECT 'test_2_compliant_with_disclaimer' AS test,
  (SELECT count(*) FROM compliance_check(
    'This product supports focus and mental clarity. These statements have not been evaluated by the Food and Drug Administration. This product is not intended to diagnose, treat, cure, or prevent any disease.'
  ) WHERE finding_kind = 'banned_language') = 0 AS pass;

-- Test 3: disclaimer PLUS a real violation -> flags the real violation, not the disclaimer.
SELECT 'test_3_real_violation_with_disclaimer' AS test,
  (SELECT count(*) FROM compliance_check(
    'This product cures anxiety disorder. These statements have not been evaluated by the Food and Drug Administration. This product is not intended to diagnose, treat, cure, or prevent any disease.'
  ) WHERE finding_kind = 'banned_language') = 1 AS real_violation_flagged,
  (SELECT count(*) FROM compliance_check(
    'This product cures anxiety disorder. These statements have not been evaluated by the Food and Drug Administration. This product is not intended to diagnose, treat, cure, or prevent any disease.'
  ) WHERE finding_kind = 'missing_disclaimer') = 0 AS disclaimer_not_flagged;

-- Test 4: real disease claim, no disclaimer -> flags banned_language AND missing_disclaimer.
SELECT 'test_4_violation_no_disclaimer' AS test,
  (SELECT count(*) FROM compliance_check('This product cures anxiety and treats depression.') WHERE finding_kind = 'banned_language') >= 1 AS banned_language_fires,
  (SELECT count(*) FROM compliance_check('This product cures anxiety and treats depression.') WHERE finding_kind = 'missing_disclaimer') = 1 AS missing_disclaimer_fires;

-- Test 5 (Task 2): bare compliant headline, no claims -> zero findings at all.
SELECT 'test_5_claim_free_headline' AS test,
  (SELECT count(*) FROM compliance_check('Check out our new product launch this fall!')) = 0 AS pass;

-- Test 6 (Task 2): structure/function claim (ingredient + benefit verb), no disclaimer
-- -> missing_disclaimer still fires (a real claim, just missing the required disclaimer).
-- Substitute a real branded ingredient name from your own ingredients table for "<ingredient>".
SELECT 'test_6_claim_without_disclaimer' AS test,
  (SELECT count(*) FROM compliance_check('500mg of <ingredient> supports focus.') WHERE finding_kind = 'missing_disclaimer') = 1 AS pass;
