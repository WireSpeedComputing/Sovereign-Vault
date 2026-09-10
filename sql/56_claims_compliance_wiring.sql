-- 56_claims_compliance_wiring.sql
--
-- MIGRATION: 71_claims_compliance_wiring
--
-- WO-16 Task E. Connects the claims data to the compliance checker so the
-- system can answer a question neither could answer alone: is this specific
-- claim authorized for this ingredient AT OUR DOSE, and does any prohibition
-- apply.
--
-- ══════════════════════════════════════════════════════════════════════════
-- THE DOSE CHECK IS THE POINT
-- ══════════════════════════════════════════════════════════════════════════
-- The language checker validates words against rules. It cannot see dose. The
-- claims sheet says the words are fine. So reading the claims sheet does not
-- catch this, and neither does running the copy through compliance_check:
--
--   one licence authorizes a memory and cognition claim at 2 g/day
--   the product formulates 1 g
--
-- The words are permitted. The dose is not. Only a structural comparison
-- between the authorizing condition and the formulation catches it, and that
-- comparison is what this file adds.
--
-- ══════════════════════════════════════════════════════════════════════════
-- WHY THIS READS THE LEGACY TABLE TOO
-- ══════════════════════════════════════════════════════════════════════════
-- sql/55 introduces claim_authorization, which is where claims belong going
-- forward. All 61 real claims are currently in ingredient_claims, and they
-- carry the dose conditions that make this check produce a finding TODAY.
--
-- Migrating them is deliberately NOT done here. Every one of those rows would
-- need its authorizing document re-identified -- ingredient_claims points at a
-- document through a column named substantiation_doc_id, so the migration is a
-- judgement about what each row's instrument actually was, and a judgement made
-- in bulk by a script is exactly the inference the hard rules forbid.
--
-- So the check unions both sources and labels which it came from. A finding
-- from the legacy table is still a finding.

-- ══════════════════════════════════════════════════════════════════════════
-- 1. Unified view of dose-conditioned claims
-- ══════════════════════════════════════════════════════════════════════════
create or replace view claim_dose_conditions as
  select 'claim_authorization'::text as source_table,
         ca.id as claim_id, ca.ingredient_id, ca.authorized_text as claim_text,
         ca.effect, ca.dose_min_amount, ca.dose_min_unit
  from claim_authorization ca
  where ca.status = 'current'
union all
  select 'ingredient_claims'::text,
         ic.id, ic.ingredient_id, ic.claim_text,
         case when ic.claim_status::text = 'prohibited' then 'prohibit' else 'permit' end,
         ic.min_dose_amount, ic.min_dose_unit
  from ingredient_claims ic
  where ic.status = 'current';

comment on view claim_dose_conditions is
  'Every dose-conditioned claim from both the new authorization table and the legacy ingredient_claims, labelled by source. The legacy rows are included because they hold the real conditions today; migrating them requires re-identifying each row''s authorizing instrument, which is a judgement, not a script.';

-- ══════════════════════════════════════════════════════════════════════════
-- 2. THE DOSE AUDIT
-- ══════════════════════════════════════════════════════════════════════════
-- Compares each authorized claim's dose condition against what the product
-- actually formulates. Reports four states, and the two negative ones are
-- deliberately distinct:
--   dose_ok             formulated >= required
--   DOSE_MISMATCH       formulated <  required. The words are permitted at a
--                       dose we do not use.
--   dose_uncomparable   a unit neither side can convert. NOT a pass.
--   no_dose_condition   the instrument imposed none. Also not a pass -- it
--                       means nothing here constrains the dose, which is worth
--                       seeing rather than hiding among the OKs.
create or replace function claim_dose_audit(p_product_id uuid default null)
returns table (
  verdict        text,
  ingredient     text,
  product        text,
  claim          text,
  formulated     text,
  required       text,
  source_table   text
) language sql stable security definer set search_path = public as $$
  select
    case
      when c.effect = 'prohibit' then 'prohibition'
      when c.dose_min_amount is null then 'no_dose_condition'
      when claim_dose_mg(c.dose_min_amount, c.dose_min_unit) is null
        or claim_dose_mg(pi.dose_amount, pi.dose_unit) is null then 'dose_uncomparable'
      when claim_dose_mg(pi.dose_amount, pi.dose_unit)
           < claim_dose_mg(c.dose_min_amount, c.dose_min_unit) then 'DOSE_MISMATCH'
      else 'dose_ok'
    end,
    i.name, p.name, c.claim_text,
    coalesce(pi.dose_amount::text || ' ' || pi.dose_unit, '(not formulated)'),
    coalesce(c.dose_min_amount::text || ' ' || c.dose_min_unit, '(no condition)'),
    c.source_table
  from claim_dose_conditions c
  join ingredients i on i.id = c.ingredient_id
  join product_ingredients pi on pi.ingredient_id = c.ingredient_id and pi.status = 'current'
  join products p on p.id = pi.product_id
  where p_product_id is null or pi.product_id = p_product_id;
$$;

comment on function claim_dose_audit(uuid) is
  'Compares each claim''s authorizing dose condition against the formulated dose. dose_uncomparable and no_dose_condition are reported as their own states rather than folded into dose_ok -- "we could not check" and "nothing constrained this" are not the same answer as "this is fine", and reporting them as fine is how a dose gap ships.';

-- ══════════════════════════════════════════════════════════════════════════
-- 3. COPY CHECK -- what the checker could not previously ask
-- ══════════════════════════════════════════════════════════════════════════
-- Given proposed copy: which permitted claim does it correspond to, does our
-- dose meet that claim's condition, and is any prohibition implicated.
--
-- Matching is deliberately conservative. It reports CANDIDATE correspondences
-- by shared significant vocabulary and never asserts that copy IS a claim --
-- a copy string that merely resembles an authorized claim is not authorized by
-- resemblance, and a matcher confident enough to say otherwise would be
-- manufacturing permission.
create or replace function claim_check_copy(p_copy text, p_product_id uuid default null)
returns table (
  finding_type text,
  severity     text,
  ingredient   text,
  detail       text,
  claim        text
) language sql stable security definer set search_path = public as $$
  -- (a) language rules: what the existing checker already says
  -- compliance_check returns (finding_kind, matched_text, rule_or_claim_id,
  -- explanation, severity). Column names read back from pg_get_function_result
  -- rather than assumed -- the first draft guessed `rationale` and would have
  -- failed at apply.
  select 'language_rule'::text, c.severity::text, null::text,
         c.finding_kind || ': ' || coalesce(c.explanation, ''), c.matched_text
  from compliance_check(p_copy) c

  union all

  -- (b) prohibitions implicated by shared vocabulary
  select 'prohibition_implicated', 'critical', i.name,
         'copy shares vocabulary with an active prohibition; a prohibition is a constraint, not a missing permission',
         cd.claim_text
  from claim_dose_conditions cd
  join ingredients i on i.id = cd.ingredient_id
  where cd.effect = 'prohibit'
    and exists (
      select 1 from regexp_split_to_table(lower(cd.claim_text), '\s+') t
      where length(t) >= 5 and position(t in lower(p_copy)) > 0)

  union all

  -- (c) candidate correspondence to a permitted claim, WITH the dose verdict
  select 'candidate_claim',
         case when da.verdict = 'DOSE_MISMATCH' then 'critical' else 'info' end,
         da.ingredient,
         case da.verdict
           when 'DOSE_MISMATCH' then 'AUTHORIZED WORDS, UNAUTHORIZED DOSE: formulated '
                                     || da.formulated || ', claim requires ' || da.required
           when 'dose_uncomparable' then 'dose condition could not be compared (unit not convertible)'
           when 'no_dose_condition' then 'no dose condition recorded on this claim'
           else 'dose condition met: formulated ' || da.formulated
         end,
         da.claim
  from claim_dose_audit(p_product_id) da
  where da.verdict <> 'prohibition'
    and (select count(*) from (
           select t from regexp_split_to_table(lower(da.claim), '\s+') t
           where length(t) >= 5
           intersect
           select t from regexp_split_to_table(lower(p_copy), '\s+') t
           where length(t) >= 5) x) >= 2;
$$;

comment on function claim_check_copy(text, uuid) is
  'Given proposed copy: language-rule findings, prohibitions whose vocabulary it shares, and CANDIDATE correspondences to permitted claims carrying the dose verdict. Candidates are proposals for a human, never a ruling that the copy is authorized -- copy that resembles an authorized claim is not authorized by resemblance. This system records claims; it does not approve copy.';

revoke execute on function claim_dose_audit(uuid) from anon, authenticated, public;
revoke execute on function claim_check_copy(text, uuid) from anon, authenticated, public;
revoke all on claim_dose_conditions from anon, authenticated;
