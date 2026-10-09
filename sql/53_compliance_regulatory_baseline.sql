-- 53_compliance_regulatory_baseline.sql
-- MIGRATION: 68_compliance_regulatory_baseline
-- Optional regulated-product reference module, not universal business policy.
-- Public-regulation-derived detection patterns provide reproducible reference
-- rules. Deployment-specific wording, prices, products and decisions stay
-- private and are not seeded by this module.
--
-- Review suitability for the selected jurisdiction and workflow. Authority
-- citations describe the modeled source, not an approval or legal conclusion.
-- Stable rule properties make repeated installation idempotent.

do $baseline$
declare
  v_conditions text;
  v_symptoms   text;
  v_hard_verbs text;
  v_soft_verbs text;
  v_disclaimer constant text := '(?i)not intended to diagnose,?\s*treat,?\s*cure,?\s*or prevent any disease';
  v_seeded     int := 0;
begin
  -- Owner/visibility are left to the optional domain parity module. Seeding
  -- these reference rules does not assign a customer owner or permission.

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

  -- 3. TIER 2 -- soft verb/prepositional construction plus named condition.
  -- Build from the same reference vocabulary as tier 1.

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
