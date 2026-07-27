-- compliance_check(): team-facing compliance scan RPC.
-- v1 is SQL/regex pattern matching against language_rules + ingredient_claims +
-- product_ingredients. It does not need to be smart; it needs to be complete on
-- the rules it holds. The calling agent supplies the semantic judgment on top of
-- the surfaced findings. SECURITY DEFINER, revoked from anon/authenticated/public.

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
BEGIN
  -- 1. Presence-based rules: banned_phrase, positioning_rule (finding raised when pattern IS found)
  FOR r_rule IN
    SELECT lr.id, lr.pattern, lr.rationale, lr.replacement, lr.finding_kind AS fk, lr.severity AS sev
    FROM public.language_rules lr
    WHERE lr.status = 'current' AND lr.rule_type IN ('banned_phrase', 'positioning_rule')
  LOOP
    IF p_text ~* r_rule.pattern THEN
      finding_kind := r_rule.fk::text;
      matched_text := substring(p_text FROM '(?i)' || r_rule.pattern);
      rule_or_claim_id := r_rule.id;
      explanation := r_rule.rationale || CASE WHEN r_rule.replacement IS NOT NULL THEN ' Use instead: ' || r_rule.replacement ELSE '' END;
      severity := r_rule.sev::text;
      RETURN NEXT;
    END IF;
  END LOOP;

  -- 2. Absence-based rules: required_phrase / disclaimers (finding raised when pattern is NOT found)
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

  -- 3. Ingredient mentions -> authorized/prohibited claim cross-check
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
      IF r_claim.claim_status IN ('prohibited', 'retired') THEN
        finding_kind := 'unauthorized_claim';
        matched_text := r_claim.claim_text;
        rule_or_claim_id := r_claim.id;
        explanation := 'Claim status is ' || r_claim.claim_status || '. ' || coalesce(r_claim.condition, r_claim.authority, '');
        severity := 'high';
        RETURN NEXT;
      ELSIF r_claim.claim_status IN ('authorized', 'conditional') AND r_claim.min_dose_amount IS NOT NULL AND r_claim.min_dose_unit IS NOT NULL THEN
        -- Scope dose extraction to a window around THIS claim's mention, not the whole
        -- input -- otherwise a correct dose stated for one claim can mask a wrong dose
        -- stated for a different claim on the same ingredient sharing the same unit.
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
  END LOOP;

  RETURN;
END;
$function$;

REVOKE ALL ON FUNCTION public.compliance_check(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.compliance_check(text) FROM anon;
REVOKE ALL ON FUNCTION public.compliance_check(text) FROM authenticated;
