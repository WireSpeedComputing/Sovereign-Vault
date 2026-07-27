-- Fixes two real defects found in compliance_check() (sql/12) via live testing, plus adds
-- honest coverage reporting.
--
-- BUG 1 (blocker): the disease-claim banned_phrase regex has no way to distinguish real
-- disease-claim language from the FDA-mandated disclaimer sentence itself ("...not intended
-- to diagnose, treat, cure, or prevent any disease"), which has the identical shape. Net
-- effect: the tool told users to remove the one sentence regulation requires. Postgres regex
-- has no lookbehind, so this is a function-logic fix, not a pattern tweak: a nullable
-- safe_context_pattern column on language_rules lets a rule declare known-safe boilerplate to
-- strip from a working copy of the input before testing that rule's pattern. A match that
-- only existed inside the stripped boilerplate disappears; a real violation elsewhere in the
-- same text survives, because it's tested against the same stripped copy.
--
-- BUG 2: missing_disclaimer fired on ANY input lacking the disclaimer, including
-- claim-free headlines and internal notes -- noise that trains users to ignore findings.
-- Fixed by gating it on the input actually being claim-bearing: a banned_language/
-- positioning finding fired, an ingredient_claims row matched regardless of pass/fail, or
-- an ingredient mention appears alongside a generic benefit verb.
--
-- HONEST COVERAGE: compliance_check() can only detect unauthorized claims or dose
-- mismatches for ingredients that actually have ingredient_claims rows. A clean result for
-- an ingredient with zero claim rows means "nothing to check," not "checked and passed."
-- compliance_coverage() reports, per ingredient, how much is actually checkable, so a green
-- compliance_check() result is never mistaken for more coverage than it has.

ALTER TABLE public.language_rules ADD COLUMN safe_context_pattern text;

CREATE OR REPLACE FUNCTION public.compliance_check(p_text text)
RETURNS TABLE(
  finding_kind text,
  matched_text text,
  rule_or_claim_id uuid,
  explanation text,
  severity text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  r_rule record;
  r_ing record;
  r_claim record;
  v_dose numeric;
  v_actual_dose numeric;
  v_pos int;
  v_window text;
  v_test_text text;
  v_claim_bearing boolean := false;
BEGIN
  -- 1. Presence-based rules: banned_phrase, positioning_rule (finding raised when pattern IS
  -- found in the text, with any safe_context_pattern instances stripped first).
  FOR r_rule IN
    SELECT lr.id, lr.pattern, lr.rationale, lr.replacement, lr.finding_kind AS fk, lr.severity AS sev, lr.safe_context_pattern AS safe_ctx
    FROM public.language_rules lr
    WHERE lr.status = 'current' AND lr.rule_type IN ('banned_phrase', 'positioning_rule')
  LOOP
    v_test_text := p_text;
    IF r_rule.safe_ctx IS NOT NULL THEN
      v_test_text := regexp_replace(p_text, r_rule.safe_ctx, ' ', 'gi');
    END IF;

    IF v_test_text ~* r_rule.pattern THEN
      finding_kind := r_rule.fk::text;
      matched_text := substring(v_test_text FROM '(?i)' || r_rule.pattern);
      rule_or_claim_id := r_rule.id;
      explanation := r_rule.rationale || CASE WHEN r_rule.replacement IS NOT NULL THEN ' Use instead: ' || r_rule.replacement ELSE '' END;
      severity := r_rule.sev::text;
      v_claim_bearing := true;
      RETURN NEXT;
    END IF;
  END LOOP;

  -- 2. Ingredient mentions -> authorized/prohibited claim cross-check. ANY match here means
  -- the text is making a claim (whether or not it passes), so it counts toward claim_bearing
  -- even when it doesn't itself produce a finding.
  FOR r_ing IN
    SELECT i.id, i.canonical_name, i.brand_name
    FROM public.ingredients i
    WHERE i.status = 'current'
      AND (p_text ILIKE '%' || i.canonical_name || '%'
           OR (i.brand_name IS NOT NULL AND p_text ILIKE '%' || i.brand_name || '%'))
  LOOP
    FOR r_claim IN
      SELECT ic.id, ic.claim_text, ic.claim_status, ic.condition, ic.authority, ic.min_dose_amount, ic.min_dose_unit, ic.product_id
      FROM public.ingredient_claims ic
      WHERE ic.status = 'current' AND ic.ingredient_id = r_ing.id AND p_text ILIKE '%' || ic.claim_text || '%'
    LOOP
      v_claim_bearing := true;

      IF r_claim.claim_status IN ('prohibited', 'retired') THEN
        finding_kind := 'unauthorized_claim';
        matched_text := r_claim.claim_text;
        rule_or_claim_id := r_claim.id;
        explanation := 'Claim status is ' || r_claim.claim_status || '. ' || coalesce(r_claim.condition, r_claim.authority, '');
        severity := 'high';
        RETURN NEXT;
      ELSIF r_claim.claim_status IN ('authorized', 'conditional') AND r_claim.min_dose_amount IS NOT NULL AND r_claim.min_dose_unit IS NOT NULL THEN
        v_dose := NULL;
        v_pos := position(lower(r_claim.claim_text) IN lower(p_text));
        IF v_pos > 0 THEN
          v_window := substring(p_text FROM greatest(1, v_pos - 60) FOR (length(r_claim.claim_text) + 120));
          SELECT max((m[1])::numeric) INTO v_dose
          FROM regexp_matches(v_window, '([0-9]+(?:\.[0-9]+)?)\s*' || r_claim.min_dose_unit, 'gi') AS m;
        END IF;

        v_actual_dose := NULL;
        SELECT pi.dose_amount INTO v_actual_dose
        FROM public.product_ingredients pi
        WHERE pi.ingredient_id = r_ing.id
          AND pi.status = 'current'
          AND (r_claim.product_id IS NULL OR pi.product_id = r_claim.product_id)
        LIMIT 1;

        IF v_dose IS NOT NULL THEN
          IF v_actual_dose IS NOT NULL AND abs(v_dose - v_actual_dose) > 0.01 THEN
            finding_kind := 'dose_mismatch';
            matched_text := v_dose || r_claim.min_dose_unit;
            rule_or_claim_id := r_claim.id;
            explanation := 'Stated dose ' || v_dose || r_claim.min_dose_unit || ' does not match the formulated dose ' || v_actual_dose || r_claim.min_dose_unit;
            severity := 'medium';
            RETURN NEXT;
          ELSIF v_dose < r_claim.min_dose_amount THEN
            finding_kind := 'dose_mismatch';
            matched_text := v_dose || r_claim.min_dose_unit;
            rule_or_claim_id := r_claim.id;
            explanation := 'Stated dose ' || v_dose || r_claim.min_dose_unit || ' is below the minimum authorized dose ' || r_claim.min_dose_amount || r_claim.min_dose_unit;
            severity := 'medium';
            RETURN NEXT;
          END IF;
        END IF;
      END IF;
    END LOOP;

    -- Generic fallback: an ingredient is mentioned alongside a generic benefit verb, even
    -- with no stored claim_text matching exactly -- still a claim being made.
    IF NOT v_claim_bearing AND p_text ~* '(support|promot|help|improv|boost|enhanc|reduc|increas|maintain)' THEN
      v_claim_bearing := true;
    END IF;
  END LOOP;

  -- 3. Absence-based rules: required_phrase / disclaimers. Only fires when the input is
  -- actually claim-bearing -- a claim-free headline/internal note returns clean.
  IF v_claim_bearing THEN
    FOR r_rule IN
      SELECT lr.id, lr.pattern, lr.rationale, lr.severity AS sev
      FROM public.language_rules lr
      WHERE lr.status = 'current' AND lr.rule_type = 'required_phrase'
    LOOP
      IF NOT (p_text ~* r_rule.pattern) THEN
        finding_kind := 'missing_disclaimer';
        matched_text := NULL;
        rule_or_claim_id := r_rule.id;
        explanation := r_rule.rationale;
        severity := r_rule.sev::text;
        RETURN NEXT;
      END IF;
    END LOOP;
  END IF;

  RETURN;
END;
$function$;

CREATE OR REPLACE FUNCTION public.compliance_coverage()
RETURNS TABLE(
  ingredient_name text,
  brand_name text,
  is_branded boolean,
  claim_rows integer,
  dose_checkable_claim_rows integer,
  coverage_status text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT
    i.name,
    i.brand_name,
    i.is_branded,
    count(ic.id)::integer AS claim_rows,
    count(ic.id) FILTER (WHERE ic.min_dose_amount IS NOT NULL)::integer AS dose_checkable_claim_rows,
    CASE
      WHEN count(ic.id) = 0 THEN 'not_checkable -- zero claim rows, compliance_check() cannot detect unauthorized or mis-dosed claims for this ingredient'
      WHEN count(ic.id) FILTER (WHERE ic.min_dose_amount IS NOT NULL) = 0 THEN 'claim_checkable_dose_not_checkable -- unauthorized-claim detection works, dose_mismatch cannot fire (no claim row states a minimum dose)'
      ELSE 'fully_checkable'
    END AS coverage_status
  FROM public.ingredients i
  LEFT JOIN public.ingredient_claims ic ON ic.ingredient_id = i.id AND ic.status = 'current'
  WHERE i.status = 'current'
  GROUP BY i.id, i.name, i.brand_name, i.is_branded
  ORDER BY i.is_branded DESC, i.name;
$function$;

REVOKE ALL ON FUNCTION public.compliance_coverage() FROM PUBLIC, anon, authenticated;
