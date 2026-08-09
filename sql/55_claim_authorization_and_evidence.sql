-- 55_claim_authorization_and_evidence.sql
--
-- MIGRATION: 70_claim_authorization_and_evidence
--
-- WO-16 Task B. Separates the two citations the requirement names and the
-- current schema conflates.
--
-- ══════════════════════════════════════════════════════════════════════════
-- THE CONFLATION, MEASURED
-- ══════════════════════════════════════════════════════════════════════════
-- ingredient_claims has ONE reference: substantiation_doc_id. All 61 current
-- claims populate it, and every one of them points at a supplier document --
-- a claims sheet or a trademark licence. Those are AUTHORIZATION instruments.
-- The column is named for substantiation and contains authorization, so the
-- schema cannot currently express either question:
--
--   AUTHORIZATION   which document grants the right to say this.
--                   Contractual. Answers "may we say it."
--   SUBSTANTIATION  which studies support it, at what dose, in what
--                   population. Scientific. Answers "can we defend it."
--
-- They fail INDEPENDENTLY and both failures are expensive. A supplier can
-- permit language its own studies do not support at our dose -- which is
-- already true here, see the dose check below. A well-studied effect can be
-- unusable because no agreement grants the trademark.
--
-- ══════════════════════════════════════════════════════════════════════════
-- WHAT IS ENFORCED STRUCTURALLY, NOT BY CONVENTION
-- ══════════════════════════════════════════════════════════════════════════
-- 1. NEVER INFER A CLAIM. authorized_text is NOT NULL and non-empty, and it is
--    the exact language the instrument uses. There is no column for a
--    normalised, improved or generalised version, because a schema that offers
--    one invites filling it, and an invented claim here becomes copy on a
--    label.
--
-- 2. EVIDENCE NEEDS A RESOLVABLE IDENTIFIER. claim_evidence has no free-text
--    citation column at all. identifier_type and identifier are NOT NULL and
--    CHECK-constrained to PMID / DOI / registry shape. A free-text citation is
--    the problem this table exists to fix -- the same reason the statement
--    layer refuses a citation column and forces an evidence row.
--
-- 3. PROHIBITIONS ARE FIRST CLASS. `effect` is permit or prohibit. A licence
--    that forbids anti-aging language is not the absence of a permission; it
--    is an active constraint, and a schema that can only express permission
--    cannot record it. Two such rows already exist in ingredient_claims,
--    distinguishable only by reading the prose.
--
-- 4. STATUS IS DERIVED, NEVER STORED. ingredient_claims.claim_status is a
--    stored column carrying authorized/conditional/prohibited today. A stored
--    status drifts from the facts under it, and this project has been bitten
--    by that four times -- the retrieval_units ACL copies, the hot-index
--    workstream copy, the statement authorization copies, and a coverage
--    report whose `enforced` column read false while the policies enforced.
--
-- 5. DOSE IS STRUCTURAL. A claim authorized at 2g/day is a DIFFERENT claim
--    from the same words at 1g. Stored as numbers with units, never as prose,
--    so a machine can compare them to what we actually formulate.
--
-- This system RECORDS claims. It does not approve copy. Final approval on
-- public-facing content is a human's.

-- ══════════════════════════════════════════════════════════════════════════
-- 1. AUTHORIZATION -- the permitting (or prohibiting) instrument
-- ══════════════════════════════════════════════════════════════════════════
create table if not exists claim_authorization (
  id                  uuid primary key default gen_random_uuid(),
  ingredient_id       uuid not null references ingredients(id),

  -- Which document. NOT NULL: an authorization with no instrument is an
  -- assertion by whoever typed it, which is exactly what this table refuses.
  supplier_document_id uuid not null references supplier_documents(id),
  instrument_type     text not null check (instrument_type in
                        ('tmla','claims_sheet','marketing_agreement','licence_exhibit',
                         'supplier_letter','regulatory_correspondence','other')),

  -- permit or prohibit. Prohibitions are rows, not absences.
  effect              text not null check (effect in ('permit','prohibit')),

  -- THE EXACT LANGUAGE. Quoted from the instrument, not paraphrased.
  authorized_text     text not null check (btrim(authorized_text) <> ''),

  -- Conditions the instrument imposes. All structural.
  dose_min_amount     numeric,
  dose_min_unit       text,
  dose_max_amount     numeric,
  dose_max_unit       text,
  timing_condition    text,     -- e.g. "before sleep" -- prose only because the
                                -- instrument's own condition is prose; it is
                                -- never used for a machine comparison
  co_formulation_required text,
  required_disclaimer text,
  prohibited_adjacent_language text,

  territory           text,
  effective_from      date,
  expires_at          date,

  -- provenance, matching every other governed table here
  status              record_status not null default 'proposed',
  supersedes          uuid references claim_authorization(id),
  source_kind         source_kind not null,
  source_agent        text,
  source_ref          text,
  provenance_basis    provenance_basis not null,
  citation            text,
  recorded_at         timestamptz not null default now(),
  created_at          timestamptz not null default now(),

  constraint dose_min_has_unit check ((dose_min_amount is null) = (dose_min_unit is null)),
  constraint dose_max_has_unit check ((dose_max_amount is null) = (dose_max_unit is null)),
  -- A prohibition with a dose condition is almost certainly a mis-entered
  -- permission: "you may not say X" does not come with a dose at which you may.
  constraint prohibition_has_no_dose check (effect <> 'prohibit' or dose_min_amount is null)
);

create index if not exists idx_claim_auth_ingredient on claim_authorization (ingredient_id);
create index if not exists idx_claim_auth_document on claim_authorization (supplier_document_id);

comment on table claim_authorization is
  'The instrument that permits or prohibits a claim. Contractual, not scientific -- it answers "may we say it". authorized_text is the exact language the document uses; there is deliberately no column for a normalised version, because an invented claim here becomes copy on a label.';

alter table claim_authorization enable row level security;
revoke all on claim_authorization from anon, authenticated;

-- ══════════════════════════════════════════════════════════════════════════
-- 2. EVIDENCE -- studies, with a resolvable identifier or nothing
-- ══════════════════════════════════════════════════════════════════════════
create table if not exists claim_evidence (
  id                  uuid primary key default gen_random_uuid(),
  ingredient_id       uuid not null references ingredients(id),

  -- Optional link to a specific authorization. Evidence can exist for an
  -- ingredient with no authorization at all -- that is the
  -- substantiated-but-unauthorized state, and it is worth recording.
  claim_authorization_id uuid references claim_authorization(id),

  identifier_type     text not null check (identifier_type in ('pmid','doi','registry')),
  identifier          text not null check (btrim(identifier) <> ''),

  -- Shape-checked so a placeholder cannot masquerade as a citation. This does
  -- not prove the identifier RESOLVES -- see the honest limit below.
  constraint identifier_shape check (
    (identifier_type = 'pmid'     and identifier ~ '^[0-9]{1,9}$') or
    (identifier_type = 'doi'      and identifier ~ '^10\.[0-9]{4,9}/[^\s]+$') or
    (identifier_type = 'registry' and identifier ~ '^(NCT[0-9]{8}|ISRCTN[0-9]{8}|[A-Z]{2,10}[0-9-]{4,20})$')
  ),

  dose_studied_amount numeric,
  dose_studied_unit   text,
  population          text,
  duration_days       int,
  design              text check (design is null or design in
                        ('rct','crossover','open_label','observational','meta_analysis',
                         'animal','in_vitro','review','other')),

  -- A study that does NOT support the claim is still worth recording, with
  -- that stated. Selecting only supportive studies is how a substantiation
  -- file becomes a marketing file.
  outcome_direction   text not null check (outcome_direction in
                        ('supports','null_result','contradicts','mixed')),
  outcome_note        text,

  status              record_status not null default 'proposed',
  supersedes          uuid references claim_evidence(id),
  source_kind         source_kind not null,
  source_agent        text,
  source_ref          text,
  provenance_basis    provenance_basis not null,
  citation            text,
  recorded_at         timestamptz not null default now(),
  created_at          timestamptz not null default now(),

  constraint dose_studied_has_unit check ((dose_studied_amount is null) = (dose_studied_unit is null))
);

create index if not exists idx_claim_evidence_ingredient on claim_evidence (ingredient_id);
create index if not exists idx_claim_evidence_auth on claim_evidence (claim_authorization_id);
create unique index if not exists claim_evidence_unique_identifier
  on claim_evidence (ingredient_id, identifier_type, identifier)
  where status = 'current';

comment on table claim_evidence is
  'Studies supporting or failing to support a claim. Scientific, not contractual -- it answers "can we defend it". There is deliberately NO free-text citation column: a citation that resolves to nothing is the defect this table exists to prevent, so an identifier is mandatory and shape-checked. HONEST LIMIT: shape is not resolution. A well-formed PMID that points at nothing passes this constraint; verifying it resolves needs a network call this schema does not make.';

alter table claim_evidence enable row level security;
revoke all on claim_evidence from anon, authenticated;

-- ══════════════════════════════════════════════════════════════════════════
-- 3. DOSE COMPARISON -- unit-aware, and it refuses rather than guesses
-- ══════════════════════════════════════════════════════════════════════════
-- Converts to milligrams for comparison. Returns NULL for a unit it does not
-- know, and every caller treats NULL as "cannot compare" rather than as "no
-- problem" -- an unknown unit silently comparing as zero would turn a dose
-- mismatch into a pass, which is the whole failure this check exists to catch.
create or replace function claim_dose_mg(p_amount numeric, p_unit text)
returns numeric language sql immutable as $$
  select case lower(btrim(p_unit))
           when 'mg'  then p_amount
           when 'g'   then p_amount * 1000
           when 'gram' then p_amount * 1000
           when 'grams' then p_amount * 1000
           when 'mcg' then p_amount / 1000.0
           when 'ug'  then p_amount / 1000.0
           else null
         end;
$$;

comment on function claim_dose_mg(numeric, text) is
  'Normalises a dose to milligrams. Returns NULL for an unrecognised unit -- callers must treat NULL as "cannot compare", never as "no constraint". IU is deliberately absent: IU is compound-specific and converting it generically would produce a confident wrong number.';

-- ══════════════════════════════════════════════════════════════════════════
-- 4. STATUS -- DERIVED. Never a column.
-- ══════════════════════════════════════════════════════════════════════════
-- Reports one state per (ingredient, authorization) with the formulated dose
-- taken from product_ingredients, so the answer reflects what we actually make
-- rather than what someone recorded about it.
create or replace function claim_status_report(p_product_id uuid default null)
returns table (
  ingredient      text,
  product         text,
  effect          text,
  claim           text,
  status          text,
  formulated_mg   numeric,
  required_mg     numeric,
  evidence_count  int,
  detail          text
) language sql stable security definer set search_path = public as $$
  with auth as (
    select ca.*, i.name as ingredient_name
    from claim_authorization ca
    join ingredients i on i.id = ca.ingredient_id
    where ca.status = 'current'
  ),
  formulated as (
    select pi.ingredient_id, pi.product_id, p.name as product_name,
           claim_dose_mg(pi.dose_amount, pi.dose_unit) as mg
    from product_ingredients pi
    join products p on p.id = pi.product_id
    where pi.status = 'current'
      and (p_product_id is null or pi.product_id = p_product_id)
  ),
  ev as (
    select claim_authorization_id, count(*) filter (where outcome_direction = 'supports') as n_support
    from claim_evidence where status = 'current' group by 1
  )
  select a.ingredient_name, f.product_name, a.effect, a.authorized_text,
         case
           when a.effect = 'prohibit'                              then 'prohibited'
           when a.expires_at is not null and a.expires_at < current_date then 'expired'
           when a.dose_min_amount is not null
                and claim_dose_mg(a.dose_min_amount, a.dose_min_unit) is null
                                                                   then 'dose_uncomparable'
           when a.dose_min_amount is not null and f.mg is not null
                and f.mg < claim_dose_mg(a.dose_min_amount, a.dose_min_unit)
                                                                   then 'dose_mismatch'
           when coalesce(ev.n_support, 0) = 0                      then 'authorized_but_unsubstantiated'
           else 'authorized_and_substantiated'
         end,
         f.mg,
         claim_dose_mg(a.dose_min_amount, a.dose_min_unit),
         coalesce(ev.n_support, 0)::int,
         case
           when a.effect = 'prohibit' then 'active constraint, not a missing permission'
           when a.dose_min_amount is not null and f.mg is not null
                and f.mg < claim_dose_mg(a.dose_min_amount, a.dose_min_unit)
             then 'the words are permitted; the dose is not'
           when coalesce(ev.n_support, 0) = 0
             then 'no supporting study recorded with a resolvable identifier'
           else null
         end
  from auth a
  left join formulated f on f.ingredient_id = a.ingredient_id
  left join ev on ev.claim_authorization_id = a.id;
$$;

comment on function claim_status_report(uuid) is
  'Derived claim status. Never stored: a stored status drifts from the facts beneath it. dose_uncomparable is a distinct state from dose_mismatch on purpose -- "we could not compare these units" must never be reported as "this is fine".';

revoke execute on function claim_status_report(uuid) from anon, authenticated, public;
revoke execute on function claim_dose_mg(numeric, text) from anon, authenticated, public;
