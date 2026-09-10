-- 49_compliance_soft_claim_tier.sql
--
-- MIGRATION: 66_compliance_soft_claim_tier
--
-- Owner decision, 2026-08-09. Implemented, not proposed.
--
-- ══════════════════════════════════════════════════════════════════════════
-- THE GAP, MEASURED ON THE LIVE DEPLOYMENT
-- ══════════════════════════════════════════════════════════════════════════
-- The disease-claim detector keys on a HARD TREATMENT VERB adjacent to a named
-- condition: cure / treat / prevent / mitigate / diagnose and their inflections.
-- That is the statutory language, and against it the detector works.
--
-- It has no rule at all for the softer constructions that carry the same claim
-- in ordinary marketing copy. Measured directly:
--
--     "Treats depression."               2 findings   correct
--     "Prevents Alzheimer's disease."    2 findings   correct
--     "Treats insomnia."                 2 findings   correct
--     "Helps with depression."           0 findings   MISS
--     "Reduces symptoms of depression."  0 findings   MISS
--     "Helps with ADHD."                 0 findings   MISS
--     "Good for anxiety."                0 findings   MISS
--
-- "Helps with depression" is a disease claim. It passed clean.
--
-- The gap was invisible for a second reason worth recording: the coverage suite
-- that would have shown it emitted `*** FAIL ***` into a text column and named
-- no machine-readable verdict, so the runner scored it PASS? and the replay
-- reported CLEAN. A detector gap sat behind a reporting gap.
--
-- ══════════════════════════════════════════════════════════════════════════
-- THE DECISION: A SECOND TIER, NOT A WIDER FIRST TIER
-- ══════════════════════════════════════════════════════════════════════════
-- Widening tier one would have made every soft construction blocking, and soft
-- constructions are where legitimate structure/function copy lives -- "supports
-- a healthy stress response" must not block. So:
--
--   TIER 1  critical  hard treatment verb + named condition.  BLOCKS.
--                     Unchanged. This is the statutory language.
--   TIER 2  high      soft verb or prepositional construction + named
--                     condition.  FLAGGED FOR REVIEW, does not auto-block.
--
-- The asymmetry that decides the tuning: a false positive costs one human
-- review; a false negative ships. Tier 2 is therefore deliberately generous. It
-- will flag "not recommended for anxiety sufferers" and similar. That is the
-- intended cost.
--
-- SCOPE OF THIS FILE. It records what the system must SURFACE. It does not
-- decide what the regulation requires, and nothing here has been through legal
-- review -- the owner's sequencing is that legal confirms before launch, not
-- before implementation. The authority string carries the statutory reference
-- the tier is modelled on, not an opinion that this pattern is the law.
--
-- The condition alternation is deliberately IDENTICAL to tier one's. Two lists
-- of conditions would drift, and the failure mode of that drift is a condition
-- that blocks under one verb and passes under another -- which is exactly the
-- shape of the gap being closed here.

do $seed$
declare
  v_conditions text;
  v_soft       text;
  v_actor      uuid;
begin
  -- Reuse tier one's condition alternation verbatim, extracted from the live
  -- rule rather than retyped. Retyping it would fork the two lists on day one.
  select substring(pattern from '\)\\y\.\{0,40\}\\y\((.*)\)\\y$')
    into v_conditions
  from language_rules
  where status = 'current' and finding_kind = 'banned_language' and severity = 'critical'
    and pattern like '%diagnos%'
  limit 1;

  -- Two different absences, two different answers.
  --
  -- FOUND WHILE WRITING THIS: no file in sql/ seeds language_rules at all. The
  -- entire disease-claim ruleset -- tier one included -- exists only as
  -- deployment data. A fresh install from this repo has NO compliance detection
  -- whatsoever, and nothing says so; the replay reports clean because there is
  -- no rule to fail. That is the same class as the migration bodies: a control
  -- that exists in exactly one place. Recorded here rather than fixed, because
  -- seeding the statutory ruleset into a public repo is a decision about what
  -- this repo publishes, not a defect fix.
  --
  -- So: an EMPTY rules table is a fresh install with no seed, and extending a
  -- ruleset that does not exist is meaningless -- notice and do nothing. A
  -- NON-EMPTY table missing tier one is a broken deployment, and seeding tier
  -- two beside it would imply a first tier that is not there -- raise.
  if v_conditions is null then
    if not exists (select 1 from language_rules) then
      raise notice 'language_rules is empty: this is a fresh install with no rule seed. Tier 2 not seeded -- there is no tier 1 to extend. NOTE: no file in sql/ seeds these rules, so this install has no disease-claim detection at all.';
      return;
    end if;
    raise exception 'language_rules is populated but carries no tier-1 disease-claim rule. Refusing to seed tier 2 beside a missing tier 1, and refusing to hand-type the condition list -- two lists would drift, and the drift shows up as a condition that blocks under one verb and passes under another, which is the gap this file exists to close.';
  end if;

  v_soft :=
    '\y(help|helps|helped|helping|good for|great for|ideal for|perfect for|'
    || 'support|supports|supported|supporting|'
    || 'reduc(e|es|ed|ing)\s+(the\s+)?symptoms?\s+of|symptom relief for|relief from|'
    || 'eas(e|es|ed|ing)|sooth(e|es|ed|ing)|calm|calms|calmed|calming|'
    || 'manag(e|es|ed|ing)|improv(e|es|ed|ing)|address|addresses|addressed|addressing|'
    || 'target|targets|targeted|targeting|works? for|better for|aid for|aids with)'
    || '\y.{0,30}\y(' || v_conditions || ')\y';

  select id into v_actor from principals where kind = 'human' and active
   order by created_at, id limit 1;

  if exists (select 1 from language_rules
             where status='current' and severity='high' and finding_kind='banned_language'
               and pattern like '%good for%') then
    raise notice 'tier-2 soft-claim rule already present; nothing to do';
    return;
  end if;

  insert into language_rules
    (rule_type, pattern, scope, rationale, authority, finding_kind, severity, status,
     source_kind, source_ref, confidence, provenance_basis, citation,
     safe_context_pattern, owner, visibility)
  values
    ('banned_phrase', v_soft, 'global',
     'Soft-verb and prepositional disease claims. "Helps with depression" and "Good for anxiety" carry the same claim as "treats depression" and were returning zero findings. Tier 2: surfaced for human review rather than auto-blocked, because this construction space also contains legitimate structure/function copy. A false positive costs one review; a false negative ships.',
     'regulatory framework: DSHEA 21 U.S.C. 343(r)(6), FDA 21 CFR 101.93 -- tier modelled on the statute, NOT reviewed by counsel',
     'banned_language', 'high', 'current',
     'manual', 'WO-15 owner decision 2026-08-09', 0.80, 'human_direct',
     'owner decision recorded 2026-08-09; legal review scheduled before launch, not before implementation',
     -- Same safe context as tier one: the mandated disclaimer must not flag
     -- itself. It is a narrow exemption for one fixed sentence, not a general
     -- "a disclaimer cures a claim" rule -- it does not.
     '(?i)not intended to diagnose,?\s*treat,?\s*cure,?\s*or prevent any disease',
     v_actor, 'shared');

  raise notice 'tier-2 soft-claim rule seeded, reusing the tier-1 condition alternation';
end $seed$;
