-- 60_claim_evidence_audit.sql
--
-- MIGRATION: 75_claim_evidence_audit
--
-- WO-17 Task C. The built-in red team. This does not confirm the citations are
-- fine; it assumes they are wrong and tries to prove it.
--
-- ══════════════════════════════════════════════════════════════════════════
-- THE CORE PRINCIPLE
-- ══════════════════════════════════════════════════════════════════════════
-- A citation that has not been resolved is not evidence. It is a claim about
-- evidence. A DOI nobody fetched, a PMID nobody read, a "study on file" that is
-- a supplier PDF -- each LOOKS like substantiation and provides none. That is
-- the sixteen-times-catalogued defect class of this project: something that
-- reports success without having verified.
--
-- So `never_attempted` is a CRITICAL finding here, not a neutral default. An
-- empty evidence field is honest; an unverified citation is not.
--
-- ══════════════════════════════════════════════════════════════════════════
-- WHAT SQL CAN AND CANNOT DO, STATED RATHER THAN BLURRED
-- ══════════════════════════════════════════════════════════════════════════
-- Resolution and retraction status require a network fetch. Postgres does not
-- make one, so this function CANNOT resolve anything itself. It reports the
-- stored verification state and treats absence as failure.
--
-- The fetching belongs to tests/verify_claim_evidence.sh, which writes back
-- resolution_status, resolved_title, retraction_status and last_verified_at.
-- The split is deliberate and is the honest architecture: a SQL function that
-- claimed to resolve DOIs would be the exact lie this file exists to catch.
--
-- Consequence worth being explicit about: running this auditor alone can never
-- turn a never_attempted row green. It can only ever report that nobody has
-- checked. Turning it green requires the verifier to have actually run.

create or replace function claim_evidence_audit(p_max_age_days int default 180)
returns table (
  severity     text,
  check_name   text,
  ingredient   text,
  identifier   text,
  finding      text
) language sql stable security definer set search_path = public as $$
  with e as (
    select ce.*, i.name as ingredient_name,
           (select claim_dose_mg(pi.dose_amount, pi.dose_unit)
            from product_ingredients pi
            where pi.ingredient_id = ce.ingredient_id and pi.status='current'
            limit 1) as formulated_mg
    from claim_evidence ce
    join ingredients i on i.id = ce.ingredient_id
    where ce.status = 'current'
  )
  -- RESOLUTION. Worse than an empty field, because it looks like substantiation.
  select 'critical', 'resolution', e.ingredient_name, e.identifier_type||':'||e.identifier,
         case coalesce(e.resolution_status,'never_attempted')
           when 'never_attempted' then 'NEVER RESOLVED: nobody has fetched this identifier. It is a claim about evidence, not evidence.'
           when 'not_found' then 'DEAD IDENTIFIER: fetched and returned nothing. A dead citation is worse than no citation.'
           when 'error' then 'RESOLUTION ERROR: the fetch failed and the state is unknown.'
         end
  from e where coalesce(e.resolution_status,'never_attempted') <> 'resolved'

  union all
  -- RETRACTION. The worst state in the table: a withdrawn paper holding up a
  -- live claim.
  select 'critical', 'retraction', e.ingredient_name, e.identifier_type||':'||e.identifier,
         'CITED PAPER IS ' || upper(e.retraction_status) ||
         ': a retracted or disputed study supporting a live claim is the worst state this table can hold.'
  from e where e.retraction_status in ('retracted','expression_of_concern')

  union all
  -- DOSE ADEQUACY. The underdosed-product theory is the most exploited in
  -- supplement class actions.
  select 'high', 'dose_adequacy', e.ingredient_name, e.identifier_type||':'||e.identifier,
         'STUDIED BELOW OUR DOSE: study used ' || e.dose_studied_amount || e.dose_studied_unit ||
         ', we formulate ' || e.formulated_mg || 'mg. A study at a lower dose does not support a claim at a higher one.'
  from e
  where e.dose_studied_amount is not null and e.formulated_mg is not null
    and claim_dose_mg(e.dose_studied_amount, e.dose_studied_unit) is not null
    and claim_dose_mg(e.dose_studied_amount, e.dose_studied_unit) < e.formulated_mg

  union all
  -- DOSE UNCOMPARABLE. Distinct from inadequate. Never a pass.
  select 'high', 'dose_uncomparable', e.ingredient_name, e.identifier_type||':'||e.identifier,
         'DOSE NOT COMPARABLE: studied dose is in a unit that cannot be converted. This is not a pass; it is an unanswered question.'
  from e
  where e.dose_studied_amount is not null
    and claim_dose_mg(e.dose_studied_amount, e.dose_studied_unit) is null

  union all
  -- INDEPENDENCE. Supplier-FUNDED is fine and normal. Supplier-PUBLISHED and
  -- unindexed is a different tier and must never be counted as independent.
  select
    case when e.independence_tier = 'marketing_material' then 'critical' else 'high' end,
    'independence', e.ingredient_name, e.identifier_type||':'||e.identifier,
    case e.independence_tier
      when 'supplier_published_unindexed' then 'SUPPLIER PDF, NOT INDEPENDENT: a brand owner''s own document is not independent substantiation and must not be counted as though it were. Supplier-funded is fine; supplier-published-and-unindexed is a different tier.'
      when 'marketing_material' then 'MARKETING MATERIAL CITED AS EVIDENCE: this is not a study.'
      else 'INDEPENDENCE UNKNOWN: not classified, so it cannot be counted as independent.'
    end
  from e
  where coalesce(e.independence_tier,'unknown') not in ('peer_reviewed_indexed','registered_trial')

  union all
  -- CONTENT MATCH. Only checkable once resolved; a heuristic on the fetched
  -- title, reported as a question rather than a verdict.
  select 'medium', 'content_match', e.ingredient_name, e.identifier_type||':'||e.identifier,
         'TITLE SHARES NO VOCABULARY WITH THE CLAIM: resolved title "' || e.resolved_title ||
         '" -- verify this study is about what we are citing it for.'
  from e
  join claim_authorization a on a.id = e.claim_authorization_id
  where e.resolution_status = 'resolved' and e.resolved_title is not null
    and not exists (
      select 1 from regexp_split_to_table(lower(e.resolved_title), '\s+') t
      where length(t) >= 5 and position(t in lower(a.authorized_text)) > 0)

  union all
  -- STALENESS. Re-verification is scheduled, not one-time.
  select 'medium', 'staleness', e.ingredient_name, e.identifier_type||':'||e.identifier,
         'LAST VERIFIED ' || extract(day from now() - e.last_verified_at)::int ||
         ' DAYS AGO: past the ' || p_max_age_days || '-day window. Links rot and papers are retracted after we cite them.'
  from e
  where e.last_verified_at is not null
    and now() - e.last_verified_at > (p_max_age_days || ' days')::interval

  union all
  -- OUTCOME. A study recorded as not supporting the claim is worth keeping --
  -- and worth flagging if anything is leaning on it.
  select 'high', 'outcome_direction', e.ingredient_name, e.identifier_type||':'||e.identifier,
         'CITED STUDY DOES NOT SUPPORT THE CLAIM (' || e.outcome_direction ||
         '): recorded honestly, but nothing should be resting on it.'
  from e where e.outcome_direction in ('contradicts','null_result');
$$;

comment on function claim_evidence_audit(int) is
  'Adversarial audit of our own evidence rows. Each check returns a FINDING, never a boolean. never_attempted is CRITICAL, not neutral: an empty evidence field is honest, an unverified citation is not. Cannot resolve identifiers itself -- Postgres makes no network calls -- so it reports stored verification state and treats absence as failure. Resolution belongs to tests/verify_claim_evidence.sh.';

-- Coverage, so a quiet auditor is distinguishable from a clean one.
create or replace function claim_evidence_audit_coverage()
returns table (metric text, value text) language sql stable
security definer set search_path = public as $$
  select 'evidence_rows_examined', count(*)::text from claim_evidence where status='current'
  union all
  select 'resolved', count(*)::text from claim_evidence
    where status='current' and resolution_status='resolved'
  union all
  select 'never_attempted', count(*)::text from claim_evidence
    where status='current' and coalesce(resolution_status,'never_attempted')='never_attempted'
  union all
  select 'findings', (select count(*)::text from claim_evidence_audit());
$$;

comment on function claim_evidence_audit_coverage() is
  'Examined, resolved, never-attempted, findings. Zero findings with zero rows examined is an EMPTY table, not a clean one, and these four numbers are what makes the difference visible.';

revoke execute on function claim_evidence_audit(int) from anon, authenticated, public;
revoke execute on function claim_evidence_audit_coverage() from anon, authenticated, public;
