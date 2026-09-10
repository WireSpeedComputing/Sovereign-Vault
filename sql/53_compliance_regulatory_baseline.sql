-- 53_compliance_regulatory_baseline.sql
--
-- MIGRATION: 68_compliance_regulatory_baseline
--
-- Owner decision, 2026-08-09. Closes the blocker recorded in sql/49: no file in
-- this repo seeded language_rules, so a fresh install had NO compliance
-- detection at all and reported a clean replay because there was no rule left
-- to fail. A control that exists in exactly one place, same class as the
-- migration bodies.
--
-- ══════════════════════════════════════════════════════════════════════════
-- THE SPLIT, AND WHERE THE SEAM ACTUALLY IS
-- ══════════════════════════════════════════════════════════════════════════
-- The ruleset was measured before splitting: 19 current rules, of which 4 carry
-- an `authority` naming a regulation. That is the seam, and it is a property of
-- the data rather than a judgement call applied to it.
--
-- SEEDED HERE -- generic regulatory scaffolding. Derived from public regulation,
-- needed by any dietary-supplement deployment, and contains no deployment data:
--
--   1. disease claims, tier 1     hard treatment verb + named condition
--   2. implied disease claims     disease verb + characteristic symptom
--   3. disease claims, tier 2     soft verb / preposition + named condition
--   4. the mandated disclaimer    required-phrase rule
--
-- NOT SEEDED -- deployment-specific, stays as data in the deployment:
--   * stale-figure rules naming our prices and SKUs
--   * retired brand phrasings ("clinical doses", "therapeutic dosing")
--   * positioning rules about how our products may be described
-- Those are ours, Rule 0 applies to them, and they would be wrong for anyone
-- else's deployment anyway.
--
-- This is what "example domain module" should mean: the module ships the part
-- that generalises and leaves the part that does not.
--
-- ══════════════════════════════════════════════════════════════════════════
-- WHAT THIS FILE DOES NOT CLAIM
-- ══════════════════════════════════════════════════════════════════════════
-- It is not legal advice and has not been through counsel. The `authority`
-- strings name the statute each rule is modelled on, which is a citation, not
-- an opinion that the pattern is the law. A deployment relying on these must
-- have them reviewed -- and the rationale on each row says what it is trying to
-- catch, so a reviewer can check the intent rather than reverse-engineer a
-- regex.
--
-- IDEMPOTENT. Existing deployments already carry these four rules; this file
-- must be a no-op there rather than a second copy. Keyed on a stable property
-- of each rule, not on id.
--
-- ONE CONDITION VOCABULARY. The named-condition alternation appears in two of
-- the four rules and is defined once below. Two hand-maintained copies of ~130
-- conditions fork, and the failure mode of that fork is a condition that blocks
-- under one verb and passes under another -- which is exactly the gap that
-- migration 66 was written to close.

do $baseline$
declare
  v_conditions text;
  v_symptoms   text;
  v_hard_verbs text;
  v_soft_verbs text;
  v_disclaimer constant text := '(?i)not intended to diagnose,?\s*treat,?\s*cure,?\s*or prevent any disease';
  v_seeded     int := 0;
begin
  -- owner/visibility are deliberately NOT set. FOUND WHILE WRITING THIS FILE:
  -- language_rules, ingredients, products and suppliers all carry owner and
  -- visibility columns on the live deployment that NO file in this repo
  -- creates. A fresh install produces those tables without them, so an INSERT
  -- naming those columns works against production and fails on a clean build.
  --
  -- The migration drift checker cannot see this: it compares migration
  -- INVENTORIES, not schema content, and says so in its own header -- a repo
  -- file whose body has drifted from the applied object still reads as present.
  -- Recorded as a finding rather than fixed here, because adding four columns
  -- to reconcile a schema is a separate change from seeding a ruleset.
  --
  -- Omitting them keeps this file portable across both shapes, which is the
  -- property that matters for a baseline meant to run on any deployment.

  v_conditions :=
    'disease|diseases|disorder|disorders|illness|illnesses|syndrome|anxiety|anxieties|'
    || 'depression|depressive|panic attacks?|ptsd|post-traumatic|bipolar|schizophrenia|ocd|'
    || 'adhd|autism|insomnia|sleep apnea|narcolepsy|dementia|alzheimer''?s?|parkinson''?s?|'
    || 'cognitive decline|cognitive impairment|memory loss|hypertension|high blood pressure|'
    || 'heart disease|arrhythmia|atrial fibrillation|stroke|atherosclerosis|high cholesterol|'
    || 'hyperlipidemia|diabetes|diabetic|prediabetes|obesity|metabolic syndrome|'
    || 'hypothyroid(ism)?|hyperthyroid(ism)?|insulin resistance|ibs|irritable bowel|ibd|'
    || 'crohn''?s?|colitis|celiac|gerd|acid reflux|ulcers?|arthritis|rheumatoid|lupus|'
    || 'fibromyalgia|multiple sclerosis|psoriasis|eczema|migraines?|seizures?|epilepsy|'
    || 'neuropathy|neuralgia|cancer|carcinoma|tumou?rs?|leukemia|lymphoma|osteoporosis|'
    || 'osteopenia|anemia|chronic fatigue syndrome|adrenal fatigue|erectile dysfunction|'
    || 'infertility|asthma|copd|emphysema|bronchitis|allerg(y|ies)|infections?|sepsis|'
    || 'hepatitis|cirrhosis|kidney disease|renal failure|glaucoma|macular degeneration|'
    || 'menopause|pms|pcos|endometriosis|acne|alopecia|gout|thrombosis|embolism|aneurysm|'
    || 'hiv|aids|covid|influenza';

  v_symptoms :=
    'symptoms?|pain|aches?|inflammation|fatigue|exhaustion|burnout|brain fog|mental fog|'
    || 'stress|mood swings|irritability|restlessness|sleeplessness|forgetfulness|overwhelm|'
    || 'low energy|poor sleep|poor focus';

  v_hard_verbs :=
    'cure|cures|cured|curing|treat|treats|treated|treating|diagnos(e|es|ed|ing)|'
    || 'prevent|prevents|prevented|preventing|mitigat(e|es|ed|ing)|alleviat(e|es|ed|ing)|'
    || 'reliev(e|es|ed|ing)|remed(y|ies|ied)|heal|heals|healed|healing|revers(e|es|ed|ing)|'
    || 'combat|combats|combating|combatting|fight|fights|fighting|eliminat(e|es|ed|ing)|'
    || 'eradicat(e|es|ed|ing)';

  v_soft_verbs :=
    'help|helps|helped|helping|good for|great for|ideal for|perfect for|'
    || 'support|supports|supported|supporting|'
    || 'reduc(e|es|ed|ing)\s+(the\s+)?symptoms?\s+of|symptom relief for|relief from|'
    || 'eas(e|es|ed|ing)|sooth(e|es|ed|ing)|calm|calms|calmed|calming|'
    || 'manag(e|es|ed|ing)|improv(e|es|ed|ing)|address|addresses|addressed|addressing|'
    || 'target|targets|targeted|targeting|works? for|better for|aid for|aids with';

  -- 1. TIER 1 -- named disease claim. Blocks.
  if not exists (select 1 from language_rules
                 where status='current' and finding_kind='banned_language'
                   and severity='critical' and pattern like '%diagnos%') then
    insert into language_rules
      (rule_type, pattern, scope, rationale, authority, finding_kind, severity, status,
       source_kind, source_ref, confidence, provenance_basis, citation,
       safe_context_pattern)
    values ('banned_phrase',
      '\y(' || v_hard_verbs || ')\y.{0,40}\y(' || v_conditions || ')\y', 'global',
      'DSHEA structure/function rule: a dietary supplement may not claim to diagnose, mitigate, treat, cure or prevent a disease. A hard treatment verb adjacent to a named condition is the construction the statute describes.',
      'regulatory framework: DSHEA 21 U.S.C. 343(r)(6), FDA 21 CFR 101.93',
      'banned_language','critical','current','manual','regulatory baseline (sql/53)',
      0.95,'human_direct','statutory text; not reviewed by counsel',
      v_disclaimer);
    v_seeded := v_seeded + 1;
  end if;

  -- 2. IMPLIED disease claim -- disease verb + characteristic symptom, no disease named.
  if not exists (select 1 from language_rules
                 where status='current' and finding_kind='banned_language'
                   and severity='high' and pattern like '%brain fog%') then
    insert into language_rules
      (rule_type, pattern, scope, rationale, authority, finding_kind, severity, status,
       source_kind, source_ref, confidence, provenance_basis, citation,
       safe_context_pattern, replacement)
    values ('banned_phrase',
      '\y(' || v_hard_verbs || ')\y.{0,30}\y(' || v_symptoms || ')\y', 'global',
      'Implied disease claim. FDA 21 CFR 101.93(g) treats claims about characteristic symptoms of a disease as disease claims even when no disease is named. High rather than critical because some phrasings are defensible in context and need human judgement, unlike a named-disease claim.',
      'regulatory framework: FDA 21 CFR 101.93(g) implied disease claim criteria',
      'banned_language','high','current','manual','regulatory baseline (sql/53)',
      0.85,'human_direct','statutory text; not reviewed by counsel',
      v_disclaimer,
      'a structure/function framing describing what the product supports rather than what it fixes');
    v_seeded := v_seeded + 1;
  end if;

  -- 3. TIER 2 -- soft verb / prepositional construction + named condition. Review.
  --    Migration 66 seeded this on the live deployment by reading tier 1 back.
  --    Here it is built from the same vocabulary, so a fresh install gets both
  --    tiers rather than a tier 2 that silently declines to seed.
  if not exists (select 1 from language_rules
                 where status='current' and finding_kind='banned_language'
                   and severity='high' and pattern like '%good for%') then
    insert into language_rules
      (rule_type, pattern, scope, rationale, authority, finding_kind, severity, status,
       source_kind, source_ref, confidence, provenance_basis, citation,
       safe_context_pattern)
    values ('banned_phrase',
      '\y(' || v_soft_verbs || ')\y.{0,30}\y(' || v_conditions || ')\y', 'global',
      'Soft-verb and prepositional disease claims. "Helps with depression" and "Good for anxiety" carry the same claim as "treats depression" and returned zero findings before this rule existed. Surfaced for human review rather than auto-blocked, because this construction space also contains legitimate structure/function copy. A false positive costs one review; a false negative ships.',
      'regulatory framework: DSHEA 21 U.S.C. 343(r)(6), FDA 21 CFR 101.93 -- tier modelled on the statute, NOT reviewed by counsel',
      'banned_language','high','current','manual','regulatory baseline (sql/53)',
      0.80,'human_direct','owner decision 2026-08-09; legal review before launch',
      v_disclaimer);
    v_seeded := v_seeded + 1;
  end if;

  -- 4. The mandated disclaimer, as a required phrase.
  if not exists (select 1 from language_rules
                 where status='current' and finding_kind='missing_disclaimer') then
    insert into language_rules
      (rule_type, pattern, scope, rationale, authority, finding_kind, severity, status,
       source_kind, source_ref, confidence, provenance_basis, citation)
    values ('required_phrase',
      'not (been )?evaluated by the food and drug administration', 'global',
      'FDA-required disclaimer for structure/function claims on dietary supplements. Must appear on labels and in marketing content making structure/function claims.',
      'regulatory framework: FDA 21 CFR 101.93(c)',
      'missing_disclaimer','critical','current','manual','regulatory baseline (sql/53)',
      0.95,'human_direct','statutory text; not reviewed by counsel');
    v_seeded := v_seeded + 1;
  end if;

  raise notice 'regulatory compliance baseline: % rule(s) seeded, % already present',
    v_seeded, 4 - v_seeded;
end $baseline$;
