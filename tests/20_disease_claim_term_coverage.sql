-- tests/20_disease_claim_term_coverage.sql
--
-- REQUIRES-DEPLOYMENT: needs the seeded language_rules set
--
-- Marked deployment-only for the same reason tests/12 is: it asserts against
-- the seeded rule set, and a fresh replay cluster carries only part of it. Run
-- in a fresh cluster it reported three failures, two of which were missing
-- seeds rather than missing coverage -- a result that is worse than no result,
-- because it buries a real gap among artefacts.
--
-- IT WAS UNREADABLE UNTIL 2026-08-09. This file emits `*** FAIL ***` in a text
-- column and carried no SUITE_RESULT line, so the runner scored it `PASS?`,
-- left SUITE_FAILED untouched, and the run ended REPLAY CLEAN with exit 0. A
-- file written because a false negative reached a live deployment then spent
-- months in a state where its own failures could not be read. Verdict is now
-- derived below.
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

-- Materialised so the VERDICT below is derived from the same rows the human
-- reads, rather than recomputed from a duplicated term list that could drift
-- from it -- and rather than grepped back out of formatted text.
-- No ON COMMIT DROP: this file runs outside an explicit transaction, so each
-- statement autocommits and the table would be dropped before the next SELECT
-- could read it. The temp table dies with the psql session regardless.
CREATE TEMP TABLE t_cov AS
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

SELECT * FROM t_cov;

-- Expected: 16 rows, all PASS. Any FAIL is a live compliance gap, not a
-- test-authoring problem -- investigate the rule, not the test, first.

-- ══════════════════════════════════════════════════════════════════════════
-- DERIVED VERDICT
-- ══════════════════════════════════════════════════════════════════════════
-- The file emitted '*** FAIL ***' in a text column and named no verdict, so the
-- runner scored it PASS? and the run reported REPLAY CLEAN with exit 0. Written
-- because a false negative reached a live deployment; then left in a state where
-- its own failures could not be read.
SELECT CASE WHEN count(*) = 0 THEN 'SUITE_RESULT: PASS'
            ELSE 'SUITE_RESULT: FAIL' END AS verdict
FROM t_cov WHERE result <> 'PASS';
