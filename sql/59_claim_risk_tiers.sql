-- 59_claim_risk_tiers.sql
--
-- MIGRATION: 74_claim_risk_tiers
--
-- WO-17 Task D. Three different answers to three different questions:
-- "FTC flag, lawsuit, or safe to put on the package."
--
-- ══════════════════════════════════════════════════════════════════════════
-- THIS IS A RISK SIGNAL FROM EVIDENCE CHARACTERISTICS. IT IS NOT LEGAL ADVICE.
-- ══════════════════════════════════════════════════════════════════════════
-- There is no legal team here -- three founders. That makes this boundary
-- matter MORE, not less. The honest framing: this assembles what a lawyer would
-- need and flags what a careful person should not say, so the founder making
-- the call does it with the facts in front of them. It does not make the call.
--
-- Because there is no lawyer to defer to, it must FAIL CONSERVATIVE. Where an
-- input is missing the tier is not PACKAGE_SAFE. Where wording deviates from an
-- authorization that is surfaced even if the meaning seems equivalent -- "seems
-- equivalent" is a judgement this system is not qualified to make, and neither
-- is a marketer under deadline.
--
-- ══════════════════════════════════════════════════════════════════════════
-- THE SHIELD IS THE FIELD THAT MATTERS DAY TO DAY
-- ══════════════════════════════════════════════════════════════════════════
-- Using a supplier's ingredient buys their substantiation ONLY while you use
-- their authorized wording. Deviate and you have left the shield: same
-- ingredient, same studies, now your claim and your liability.
--
--   VERBATIM_AUTHORIZED   supplier's exact wording, their dose and conditions.
--                         Maximum shield. Where the brand should live.
--   MODIFIED_AUTHORIZED   supplier permits the concept, we reworded it. Shield
--                         weakened, liability moved to us. The original is
--                         shown beside ours so the deviation is visible rather
--                         than argued about.
--   SELF_ASSERTED         no supplier authorization. Entirely our liability.
--                         Every generic ingredient is here.
--   NO_CLAIM              listed, nothing claimed.
--
-- NO_CLAIM IS A LEGITIMATE CHOICE AND THE SYSTEM TREATS IT AS ONE. An empty
-- claim set is not a gap to be filled. Listing an ingredient at its dose and
-- saying nothing about it carries zero claim risk; claiming it does something
-- is where risk begins. For a three-person company with no legal review, "we
-- put it in, here is the dose, we are not telling you what it does" is
-- defensible and frequently correct.

-- ══════════════════════════════════════════════════════════════════════════
-- 1. Evidence verification columns -- Task C writes these, Task D reads them
-- ══════════════════════════════════════════════════════════════════════════
alter table claim_evidence
  add column if not exists independence_tier text
    check (independence_tier is null or independence_tier in
      ('peer_reviewed_indexed','registered_trial','supplier_published_unindexed',
       'marketing_material','unknown')),
  add column if not exists resolution_status text
    check (resolution_status is null or resolution_status in
      ('resolved','not_found','error','never_attempted')),
  add column if not exists resolved_title text,
  add column if not exists last_verified_at timestamptz,
  add column if not exists retraction_status text
    check (retraction_status is null or retraction_status in
      ('none','retracted','corrected','expression_of_concern','unknown')),
  add column if not exists studied_finished_formulation boolean,
  add column if not exists chemical_form text;

comment on column claim_evidence.independence_tier is
  'Supplier-FUNDED is not disqualifying -- most ingredient research is. Supplier-PUBLISHED-and-unindexed is a different tier and must be labelled: a citation to a brand owner''s own PDF is not independent substantiation and must never be counted as though it were.';
comment on column claim_evidence.resolution_status is
  'Whether the identifier was actually fetched. never_attempted is the default state and is NOT a pass -- a citation nobody has resolved is a claim about evidence, not evidence.';
comment on column claim_evidence.last_verified_at is
  'Re-verification is scheduled, not one-time. Links rot and papers are retracted after we cite them, so a tier computed from a citation checked eight months ago is a claim about the past.';

-- Evidence is immutable once recorded; corrections append a successor. Same
-- discipline as the custody locks on memories, for the same reason: a
-- silently-edited evidence row makes every tier derived from it unfalsifiable.
create or replace function enforce_claim_evidence_immutable()
returns trigger language plpgsql as $$
declare v text := '';
begin
  if new.identifier      is distinct from old.identifier      then v := v||'identifier '; end if;
  if new.identifier_type is distinct from old.identifier_type then v := v||'identifier_type '; end if;
  if new.ingredient_id   is distinct from old.ingredient_id   then v := v||'ingredient_id '; end if;
  if new.outcome_direction is distinct from old.outcome_direction then v := v||'outcome_direction '; end if;
  if new.dose_studied_amount is distinct from old.dose_studied_amount then v := v||'dose_studied_amount '; end if;
  if v <> '' then
    raise exception 'claim_evidence is immutable once recorded (attempted: %). Corrections append a successor via supersedes; verification fields (resolution_status, retraction_status, last_verified_at) are the exception and may be updated by the auditor.', btrim(v);
  end if;
  return new;
end; $$;

drop trigger if exists trg_claim_evidence_immutable on claim_evidence;
create trigger trg_claim_evidence_immutable
  before update on claim_evidence
  for each row execute function enforce_claim_evidence_immutable();

-- ══════════════════════════════════════════════════════════════════════════
-- 2. OUR wording, beside theirs
-- ══════════════════════════════════════════════════════════════════════════
create table if not exists claim_usage (
  id                 uuid primary key default gen_random_uuid(),
  ingredient_id      uuid not null references ingredients(id),
  product_id         uuid references products(id),

  -- NULL means SELF_ASSERTED: we are saying it with nobody behind us.
  claim_authorization_id uuid references claim_authorization(id),

  -- Exactly what we intend to say. NOT NULL and non-empty: a claim record
  -- without its exact wording cannot be tiered, because the same evidence
  -- supports different tiers depending on phrasing.
  our_wording        text not null check (btrim(our_wording) <> ''),

  -- "Supports memory", "improves memory" and "clinically proven to improve
  -- memory" are three different exposures resting on identical studies.
  wording_strength   text not null check (wording_strength in
                       ('hedged_support','active_improvement','proof')),

  intended_surface   text,
  notes              text,

  status             record_status not null default 'proposed',
  supersedes         uuid references claim_usage(id),
  source_kind        source_kind not null,
  source_agent       text,
  provenance_basis   provenance_basis not null,
  recorded_at        timestamptz not null default now(),
  created_at         timestamptz not null default now()
);
create index if not exists idx_claim_usage_ingredient on claim_usage (ingredient_id);

comment on table claim_usage is
  'What WE intend to say, beside what the instrument authorizes. Separate from claim_authorization because the authorization is theirs and immutable; the wording is ours and is the thing under review. A claim_usage row with no authorization is SELF_ASSERTED and carries our liability entirely.';

alter table claim_usage enable row level security;
revoke all on claim_usage from anon, authenticated;

-- ══════════════════════════════════════════════════════════════════════════
-- 3. SHIELD STATUS -- derived
-- ══════════════════════════════════════════════════════════════════════════
create or replace function claim_shield_status(p_usage_id uuid)
returns text language sql stable security definer set search_path = public as $$
  select case
    when u.claim_authorization_id is null then 'SELF_ASSERTED'
    -- Whitespace and case are normalised; nothing else is. A reworded claim
    -- that "means the same" is MODIFIED, because deciding two phrasings are
    -- equivalent is exactly the judgement this system must not make.
    when lower(regexp_replace(btrim(u.our_wording), '\s+', ' ', 'g'))
       = lower(regexp_replace(btrim(a.authorized_text), '\s+', ' ', 'g'))
      then 'VERBATIM_AUTHORIZED'
    else 'MODIFIED_AUTHORIZED'
  end
  from claim_usage u
  left join claim_authorization a on a.id = u.claim_authorization_id
  where u.id = p_usage_id;
$$;

comment on function claim_shield_status(uuid) is
  'VERBATIM vs MODIFIED, decided by string comparison after whitespace and case normalisation and nothing else. Deliberately literal: any smarter comparison would be deciding that two phrasings mean the same thing, which is the judgement that moves liability from the supplier to us.';

-- ══════════════════════════════════════════════════════════════════════════
-- 4. RISK TIER -- derived, and it fails conservative
-- ══════════════════════════════════════════════════════════════════════════
create or replace function claim_risk_tier(p_usage_id uuid)
returns table (tier text, shield text, reasons text[], verification_age_days int)
language sql stable security definer set search_path = public as $$
  with u as (
    select cu.*, ca.authorized_text, ca.effect, ca.expires_at,
           ca.dose_min_amount, ca.dose_min_unit
    from claim_usage cu
    left join claim_authorization ca on ca.id = cu.claim_authorization_id
    where cu.id = p_usage_id
  ),
  formulated as (
    select claim_dose_mg(pi.dose_amount, pi.dose_unit) as mg
    from product_ingredients pi, u
    where pi.ingredient_id = u.ingredient_id and pi.status = 'current'
      and (u.product_id is null or pi.product_id = u.product_id)
    limit 1
  ),
  ev as (
    select
      count(*) filter (where e.status='current') as n_total,
      count(*) filter (where e.status='current' and e.resolution_status='resolved') as n_resolved,
      count(*) filter (where e.status='current' and e.retraction_status
                             in ('retracted','expression_of_concern')) as n_retracted,
      count(*) filter (where e.status='current'
                       and e.independence_tier in ('peer_reviewed_indexed','registered_trial')) as n_independent,
      count(*) filter (where e.status='current' and e.design in ('rct','crossover')
                       and coalesce(e.studied_finished_formulation, false) is not null) as n_human_trial,
      count(*) filter (where e.status='current'
                       and claim_dose_mg(e.dose_studied_amount, e.dose_studied_unit)
                           >= (select mg from formulated)) as n_dose_adequate,
      max(e.last_verified_at) as last_verified
    from claim_evidence e, u
    where e.ingredient_id = u.ingredient_id
      and (e.claim_authorization_id = u.claim_authorization_id or u.claim_authorization_id is null)
  )
  select
    case
      -- DO_NOT_USE first: nothing downstream can rescue these.
      when (select count(*) from compliance_check_claim((select our_wording from u))
            where severity='critical') > 0                         then 'DO_NOT_USE'
      when (select effect from u) = 'prohibit'                     then 'DO_NOT_USE'
      when ev.n_retracted > 0                                      then 'DO_NOT_USE'
      when (select expires_at from u) < current_date                then 'DO_NOT_USE'
      -- LAWSUIT_RISK: the underdosed-product theory is the most exploited in
      -- supplement class actions, so a dose gap outranks an evidence-quality gap.
      when ev.n_total > 0 and ev.n_dose_adequate = 0                then 'LAWSUIT_RISK'
      when (select dose_min_amount from u) is not null
           and (select mg from formulated) is not null
           and (select mg from formulated)
               < claim_dose_mg((select dose_min_amount from u),(select dose_min_unit from u))
                                                                   then 'LAWSUIT_RISK'
      -- FTC_FLAG: words permitted, evidence would not survive a substantiation
      -- demand. Includes the unverified case: never_attempted is not a pass.
      when ev.n_total = 0                                          then 'FTC_FLAG'
      when ev.n_resolved = 0                                       then 'FTC_FLAG'
      when ev.n_independent = 0                                    then 'FTC_FLAG'
      when (select wording_strength from u) = 'proof'
           and ev.n_independent < 2                                then 'FTC_FLAG'
      -- PACKAGE_SAFE requires everything above to have passed AND an
      -- authorization where one is possible. A SELF_ASSERTED claim never
      -- reaches PACKAGE_SAFE, by design: with no legal review, a claim nobody
      -- stands behind is not package-safe however good the literature is.
      when (select claim_authorization_id from u) is null           then 'FTC_FLAG'
      else 'PACKAGE_SAFE'
    end,
    claim_shield_status(p_usage_id),
    array_remove(array[
      case when ev.n_total = 0 then 'no evidence recorded' end,
      case when ev.n_total > 0 and ev.n_resolved = 0 then 'no citation has been resolved' end,
      case when ev.n_retracted > 0 then 'a cited paper is retracted or under concern' end,
      case when ev.n_independent = 0 and ev.n_total > 0 then 'no independent indexed evidence' end,
      case when ev.n_total > 0 and ev.n_dose_adequate = 0 then 'no study at or above our dose' end,
      case when (select claim_authorization_id from u) is null then 'self-asserted: no supplier authorization' end,
      case when claim_shield_status(p_usage_id) = 'MODIFIED_AUTHORIZED'
           then 'wording deviates from the authorized text: liability has moved to us' end,
      case when ev.last_verified is null then 'never verified' end
    ], null),
    case when ev.last_verified is null then null
         else extract(day from now() - ev.last_verified)::int end
  from ev;
$$;

comment on function claim_risk_tier(uuid) is
  'Derived risk signal, never stored. A stored tier would keep saying PACKAGE_SAFE after the paper supporting it was withdrawn -- deriving it means a retraction downgrades automatically. Fails conservative: a missing input never produces PACKAGE_SAFE, an unresolved citation is FTC_FLAG, and a self-asserted claim cannot reach PACKAGE_SAFE at all because with no legal review a claim nobody stands behind is not package-safe however good the literature is. NOT legal advice.';

-- ══════════════════════════════════════════════════════════════════════════
-- 5. THE REVIEW VIEW -- worth more than any tier label
-- ══════════════════════════════════════════════════════════════════════════
-- Final approval on public-facing content sits with one person. The system's
-- job is to make that decision informed rather than intuitive: authorized
-- wording, our wording, the dose comparison and the deviation flag, in one row.
create or replace function claim_review_sheet(p_product_id uuid default null)
returns table (
  ingredient        text,
  our_wording       text,
  authorized_wording text,
  shield            text,
  tier              text,
  formulated        text,
  required          text,
  reasons           text[],
  verified_days_ago int
) language sql stable security definer set search_path = public as $$
  select i.name, u.our_wording,
         coalesce(a.authorized_text, '(none -- self-asserted)'),
         t.shield, t.tier,
         coalesce(pi.dose_amount::text || ' ' || pi.dose_unit, '(not formulated)'),
         coalesce(a.dose_min_amount::text || ' ' || a.dose_min_unit, '(no condition)'),
         t.reasons, t.verification_age_days
  from claim_usage u
  join ingredients i on i.id = u.ingredient_id
  left join claim_authorization a on a.id = u.claim_authorization_id
  left join product_ingredients pi on pi.ingredient_id = u.ingredient_id and pi.status='current'
  cross join lateral claim_risk_tier(u.id) t
  where u.status in ('current','proposed')
    and (p_product_id is null or u.product_id = p_product_id or u.product_id is null);
$$;

comment on function claim_review_sheet(uuid) is
  'One row per intended claim: our wording, theirs, the dose comparison, the shield status and the tier with its reasons. Includes PROPOSED rows deliberately -- the point is to review them before they become current, and a review sheet showing only what is already approved reviews nothing.';

revoke execute on function claim_shield_status(uuid) from anon, authenticated, public;
revoke execute on function claim_risk_tier(uuid) from anon, authenticated, public;
revoke execute on function claim_review_sheet(uuid) from anon, authenticated, public;
