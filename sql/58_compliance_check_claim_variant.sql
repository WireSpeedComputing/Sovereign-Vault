-- 58_compliance_check_claim_variant.sql
--
-- MIGRATION: 73_compliance_check_claim_variant
--
-- WO-17 Task E. compliance_check() is built for FINISHED COPY and produces
-- garbage on claim fragments.
--
-- ══════════════════════════════════════════════════════════════════════════
-- MEASURED BEFORE FIXING
-- ══════════════════════════════════════════════════════════════════════════
-- Running compliance_check() over the 61 stored claims produces 43 findings:
--
--   40  missing_disclaimer   critical   FALSE
--    2  unauthorized_claim   high       FALSE (self-referential)
--    1  banned_language      high       TRUE, and already handled
--
-- Two thirds noise, and the noisy two thirds are at the HIGHEST severity, so
-- they sort to the top of any report. The first person to run this concludes
-- the catalogue is broken and stops reading the output -- the cry-wolf failure
-- this project has already hit three times, most recently with a perimeter
-- checker whose noise got it ignored.
--
-- ══════════════════════════════════════════════════════════════════════════
-- WHY EACH IS WRONG, RATHER THAN JUST NOISY
-- ══════════════════════════════════════════════════════════════════════════
-- missing_disclaimer is a REQUIRED-PHRASE rule: it fires when text making a
-- structure/function claim does not carry the FDA disclaimer. That is correct
-- for a web page or a label. A claim RECORD is a fragment -- "supports working
-- memory" -- and the disclaimer belongs on the page that publishes it, not on
-- every row in a catalogue. Firing here is a unit error: the rule is being
-- applied to the wrong kind of object.
--
-- unauthorized_claim fires when text resembles a claim that is not authorized.
-- Applied to the claim catalogue it compares each claim against the catalogue
-- it is a member of, so a PROHIBITED row matches itself and reports that the
-- prohibition is an unauthorized claim. It is: that is what prohibited means.
-- The finding is true and useless.
--
-- Neither rule is wrong. Both are being asked the wrong question, which is why
-- this is a new function rather than a change to the rules -- weakening either
-- rule would break it for finished copy, which is the case it exists for.
--
-- ══════════════════════════════════════════════════════════════════════════
-- WHAT IS DELIBERATELY NOT SUPPRESSED
-- ══════════════════════════════════════════════════════════════════════════
-- banned_language findings are kept in full, at both tiers. A claim record
-- naming a disease is exactly the thing this catalogue must surface, and it is
-- how the metabolic-syndrome claim was found. Suppressing severity to reduce
-- noise would have hidden the one true finding among the forty false ones.

create or replace function compliance_check_claim(p_claim_text text)
returns table (
  finding_kind  text,
  matched_text  text,
  explanation   text,
  severity      text
) language sql stable security definer set search_path = public as $$
  select c.finding_kind, c.matched_text, c.explanation, c.severity
  from compliance_check(p_claim_text) c
  where c.finding_kind not in ('missing_disclaimer','unauthorized_claim');
$$;

comment on function compliance_check_claim(text) is
  'compliance_check for a CLAIM RECORD rather than finished copy. Omits missing_disclaimer (the disclaimer belongs on the page that publishes a claim, not on every catalogue row) and unauthorized_claim (comparing the catalogue against itself makes every prohibited row report itself). banned_language is kept in full at both tiers -- a claim record naming a disease is precisely what this must surface, and suppressing it to reduce noise would have hidden the one true finding among forty false ones. Use compliance_check() for anything that will be published.';

-- ══════════════════════════════════════════════════════════════════════════
-- The catalogue audit
-- ══════════════════════════════════════════════════════════════════════════
-- Skips prohibited rows as SUBJECTS. A prohibition's text is a description of
-- something we must not say; running it through a language checker asks whether
-- we may say the thing we have recorded that we may not say, which is not a
-- question. They are counted separately so the skip is visible rather than
-- silent -- a suppressed row that nobody knows was suppressed is how a real
-- finding disappears.
create or replace function claim_catalogue_audit()
returns table (
  ingredient    text,
  claim_status  text,
  severity      text,
  finding_kind  text,
  claim         text,
  matched       text
) language sql stable security definer set search_path = public as $$
  select i.name, ic.claim_status::text, f.severity, f.finding_kind,
         ic.claim_text, f.matched_text
  from ingredient_claims ic
  join ingredients i on i.id = ic.ingredient_id
  cross join lateral compliance_check_claim(ic.claim_text) f
  where ic.status = 'current'
    and ic.claim_status::text <> 'prohibited';
$$;

comment on function claim_catalogue_audit() is
  'Language findings against the non-prohibited claim catalogue. Zero rows means every claim we might actually use is clean under the current rules -- which is a statement about the rules as much as about the claims, and is not a substitute for reading them.';

create or replace function claim_catalogue_audit_coverage()
returns table (metric text, value text) language sql stable
security definer set search_path = public as $$
  select 'claims_examined',
         count(*)::text from ingredient_claims
    where status='current' and claim_status::text <> 'prohibited'
  union all
  select 'claims_skipped_as_prohibited',
         count(*)::text from ingredient_claims
    where status='current' and claim_status::text = 'prohibited'
  union all
  select 'findings', (select count(*)::text from claim_catalogue_audit());
$$;

comment on function claim_catalogue_audit_coverage() is
  'Examined, skipped and found -- three numbers, always. A suite going quiet shows up as a drop in the first number rather than as continued success in the third. Same discipline as the replay runner refusing to call an unscored suite clean.';

revoke execute on function compliance_check_claim(text) from anon, authenticated, public;
revoke execute on function claim_catalogue_audit() from anon, authenticated, public;
revoke execute on function claim_catalogue_audit_coverage() from anon, authenticated, public;
