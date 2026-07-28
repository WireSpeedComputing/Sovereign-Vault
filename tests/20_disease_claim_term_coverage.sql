-- tests/20_disease_claim_term_coverage.sql
--
-- Regression tests for disease-claim detection in compliance_check().
--
-- WHY THIS FILE EXISTS: a false-NEGATIVE was found on a live deployment where
-- "cures anxiety" returned zero findings. The condition alternation contained
-- "anxiety disorder" but not bare "anxiety", and the verb alternation omitted
-- "mitigate" -- explicit statutory language in DSHEA 21 U.S.C. 343(r)(6).
--
-- The bug survived TWO prior verification passes because both used COMPOUND
-- test sentences: "cures anxiety and treats depression" passes on the
-- depression clause, masking the anxiety gap entirely.
--
-- MANDATORY TEST DISCIPLINE, learned from that miss:
--   ONE claim term per test sentence. Never compound.
--   Every enumerated term gets an isolated positive test.
--   Every approved structure/function phrase gets an isolated negative test.
--
-- These tests assume a deployment has seeded language_rules with a
-- disease-claim ruleset. This repo does not ship seed rules (they are
-- deployment data); adapt the expectations to your own ruleset.

WITH t(label, txt, expect) AS (VALUES
 -- named-disease layer (expect critical findings)
 ('bare anxiety',        'This product cures anxiety.',              'FIRE'),
 ('mitigate + disease',  'This product mitigates heart disease.',    'FIRE'),
 ('depression',          'This product treats depression.',          'FIRE'),
 ('insomnia',            'This product cures insomnia.',             'FIRE'),
 ('possessive disease',  'This product prevents alzheimer''s.',      'FIRE'),
 ('acronym condition',   'This product treats adhd.',                'FIRE'),
 ('relieve verb',        'This product relieves migraines.',         'FIRE'),
 ('reverse verb',        'This product reverses diabetes.',          'FIRE'),
 -- implied-claim layer: verb + symptom, no disease named
 ('symptom: sleep',      'This product eliminates poor sleep.',      'FIRE'),
 ('symptom: brain fog',  'This product cures brain fog.',            'FIRE'),
 ('symptom: burnout',    'This product treats burnout.',             'FIRE'),
 -- approved structure/function framing must stay silent (false-positive guard)
 ('approved: supports',  'This supports focus.',                     'QUIET'),
 ('approved: calm mood', 'This supports a calm mood.',               'QUIET'),
 ('approved: promotes',  'This promotes healthy sleep.',             'QUIET'),
 -- disclaimer regressions: the FDA-mandated sentence contains the same verb
 -- and noun shapes as a violation and must never be flagged as one, while a
 -- real violation in the same text must still fire
 ('disclaimer alone',    'These statements have not been evaluated by the Food and Drug Administration. This product is not intended to diagnose, treat, cure, or prevent any disease.', 'QUIET'),
 ('violation+disclaimer','This product cures anxiety. This product is not intended to diagnose, treat, cure, or prevent any disease.', 'FIRE')
)
SELECT t.label, t.expect,
  (SELECT count(*) FROM compliance_check(t.txt) c
     WHERE c.finding_kind = 'banned_language') AS hits,
  CASE
    WHEN t.expect = 'FIRE'
     AND (SELECT count(*) FROM compliance_check(t.txt) c
            WHERE c.finding_kind = 'banned_language') > 0 THEN 'PASS'
    WHEN t.expect = 'QUIET'
     AND (SELECT count(*) FROM compliance_check(t.txt) c
            WHERE c.finding_kind = 'banned_language') = 0 THEN 'PASS'
    ELSE '*** FAIL ***'
  END AS result
FROM t;

-- Expected: 16 rows, all PASS. Any FAIL is a live compliance gap, not a
-- test-authoring problem -- investigate the rule, not the test, first.
