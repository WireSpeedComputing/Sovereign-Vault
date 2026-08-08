-- 42_statement_layer.sql
--
-- NOT APPLIED to any deployment. Build-and-prove, per WO-11.
--
-- ══════════════════════════════════════════════════════════════════════════
-- STATEMENTS ARE A DERIVED PROJECTION. SOURCE RECORDS STAY CANONICAL.
-- ══════════════════════════════════════════════════════════════════════════
-- Every row in `statements` is rebuildable from `memories` by re-running an
-- extraction. Nothing in this file makes a statement authoritative, and nothing
-- else in the schema is permitted to depend on one yet. That is deliberate and
-- reversible: the model gets proven against real data before anything rests on
-- it, and promoting statements to canonical is a later migration with a real
-- decision behind it.
--
-- Same doctrine as retrieval_units: mutable derived state, declared rebuildable,
-- carrying a hash of what it was derived from so drift is detectable.
--
-- ══════════════════════════════════════════════════════════════════════════
-- THE ATTRIBUTION PROBLEM, AND WHY TWO CUSTODY LINKS
-- ══════════════════════════════════════════════════════════════════════════
-- A model extracts "MOQ is 4,000 units per SKU" from a human-authored record.
-- Who asserted that?
--
--   Not the human. They wrote a paragraph. They asserted the paragraph, in
--   their words, with their hedges and context. They did not assert this
--   sentence, and holding them to it is putting words in their mouth.
--
--   Not the model. It never observed a purchase order. It has no basis for the
--   fact and cannot acquire one by reading.
--
-- The resolution is that a statement carries TWO DIFFERENT CLAIMS, made by two
-- different parties, and they must not be collapsed:
--
--   THE WORLD-CLAIM  -- "MOQ is 4,000 units."
--                       Asserted by the SOURCE RECORD. Its provenance_basis,
--                       its citation, its author, its custody. Inherited whole;
--                       a statement can never be better-sourced than the record
--                       it came from.
--
--   THE FIDELITY-CLAIM -- "this text expresses that claim, at this span."
--                       Asserted by the EXTRACTION EVENT. Model, version,
--                       prompt digest, actor, timestamp. This is a claim about
--                       TEXT, not about the world, and it is the only thing the
--                       extractor is competent to assert.
--
-- Both are recorded, separately, and statement_attribution() returns both. There
-- is deliberately NO single "author" column, because any such column would be
-- wrong in one direction or the other, and the wrong version reads as fact.
--
-- The failure this design exists to prevent: a statement layer that launders
-- machine inference into apparent fact. A row saying "MOQ is 4,000 units"
-- attributed to a human who never wrote that sentence is worse than no
-- statement layer, because it is confidently citable and false about custody.

-- ── Modality ──────────────────────────────────────────────────────────────
-- Hedging is preserved, not normalised away. "Probably X" is not "X", and an
-- extractor that flattens the difference is manufacturing confidence that was
-- not in the source.
--
-- There is deliberately NO 'speculative' member. Speculation, options under
-- consideration and questions are NOT EXTRACTED AT ALL. Giving them an enum
-- value would make "we could raise prices" storable as a statement, and
-- everything downstream -- contradiction detection especially -- would treat it
-- as a claim about the world. The absence of the value is the enforcement.
create type statement_modality as enum (
  'asserted',    -- flat claim: "the formula is locked at v3.9"
  'hedged',      -- qualified: "approximately", "expected to", "around"
  'attributed'   -- the source reports someone else's claim: "the supplier says X"
);

-- ── The extraction event: custody for the fidelity-claim ──────────────────
create table statement_extractions (
  id               uuid primary key default gen_random_uuid(),
  method           text not null check (method in ('model','human','hybrid')),
  actor_principal  uuid not null references principals(id),
  model_name       text,
  model_version    text,
  prompt_digest    text,
  ruleset_version  text not null,
  started_at       timestamptz not null default now(),
  finished_at      timestamptz,
  source_selector  text not null,
  records_examined int,
  statements_kept  int,
  statements_rejected int,
  notes            text,
  -- A model extraction must say which model. "extracted by a model" with no
  -- version is not custody, it is a shrug -- and it makes the run
  -- unreproducible, which is the whole point of recording it.
  constraint extraction_model_identified
    check (method <> 'model' or (model_name is not null and model_version is not null
                                 and prompt_digest is not null))
);

comment on table statement_extractions is
  'One row per extraction run. Carries the FIDELITY-claim custody: who or what asserted that a given span expresses a given claim. Never carries custody for the claim about the world -- that belongs to the source record.';

alter table statement_extractions enable row level security;
revoke all on statement_extractions from anon, authenticated;

-- ── statements ────────────────────────────────────────────────────────────
create table statements (
  id                  uuid primary key default gen_random_uuid(),
  claim               text not null check (btrim(claim) <> ''),
  modality            statement_modality not null,

  -- exactly one source record. NOT NULL + FK is the enforcement; a statement
  -- with no source is an assertion by the extractor about the world, which is
  -- the thing this whole design refuses to allow.
  derived_from        uuid not null references memories(id),
  source_content_hash text not null,

  -- span into the source, 1-based and inclusive at both ends. Verified against
  -- the live source at write time (see the trigger below) -- rule 4 of the
  -- extraction discipline, "if you cannot point at where it came from, do not
  -- extract it", enforced rather than trusted.
  span_start          int not null check (span_start >= 1),
  span_end            int not null,
  quote_hash          text not null,

  extraction_id       uuid not null references statement_extractions(id),
  extraction_confidence numeric(3,2) check (extraction_confidence between 0 and 1),

  -- inherited from the source, copied so the projection is queryable without a
  -- join, and re-derived on rebuild. NOT independent: a statement can never
  -- carry a better basis than its source.
  inherited_basis     provenance_basis not null,
  workstream          text,
  owner               uuid references principals(id),
  visibility          visibility_level not null default 'shared',

  effective_from      timestamptz,
  effective_to        timestamptz,
  retracted_at        timestamptz,
  retraction_reason   text,

  created_at          timestamptz not null default now(),

  constraint statements_span_ordered check (span_end >= span_start),
  constraint statements_retraction_has_reason
    check ((retracted_at is null) = (retraction_reason is null))
);

-- NOTE: statements deliberately has NO citation column.
-- "No statement may claim evidence it does not link" is enforced by making
-- evidence inexpressible except as a statement_evidence row. A free-text
-- citation field would let a statement assert support it never linked, and
-- nothing would catch it -- exactly the defect upstream #11 describes, where a
-- citation resolves to nothing.

create index on statements (derived_from);
create index on statements (workstream);
create index on statements (extraction_id);
create index statements_active_idx on statements (id) where retracted_at is null;
create index statements_claim_fts_idx on statements using gin (to_tsvector('english', claim));

comment on table statements is
  'DERIVED PROJECTION over memories. Rebuildable; nothing may depend on a statement as authority yet. Carries two custody links: derived_from (the world-claim, inherited from the source record) and extraction_id (the fidelity-claim, asserted by the extractor). See statement_attribution().';

-- ── Span verification: the claim must actually point somewhere ────────────
-- Recomputes the quote from the live source and compares hashes. An extractor
-- that invents a span, or points at a plausible-but-wrong offset, is rejected
-- at write. Without this, span offsets are decoration: nothing would ever read
-- them, and a wrong one would never surface.
create or replace function enforce_statement_span()
returns trigger language plpgsql security definer
set search_path = public, extensions as $$
declare v_content text; v_quote text; v_hash text; v_src_hash text;
begin
  select content into v_content from memories where id = new.derived_from;
  if v_content is null then
    raise exception 'statement % has no resolvable source record %', new.id, new.derived_from;
  end if;

  if new.span_end > length(v_content) then
    raise exception
      'statement % span [%,%] runs past the end of source % (length %)',
      new.id, new.span_start, new.span_end, new.derived_from, length(v_content);
  end if;

  v_quote := substring(v_content from new.span_start for (new.span_end - new.span_start + 1));
  v_hash  := encode(digest(v_quote, 'sha256'), 'hex');
  if v_hash is distinct from new.quote_hash then
    raise exception
      'statement % quote_hash does not match the source span [%,%]. The span must be the exact text the claim was read from -- a span that does not verify is not evidence, it is a guess with coordinates.',
      new.id, new.span_start, new.span_end;
  end if;

  v_src_hash := encode(digest(v_content, 'sha256'), 'hex');
  if new.source_content_hash is distinct from v_src_hash then
    raise exception
      'statement % records source_content_hash % but source % currently hashes to %. Extract against the current record, or the statement is born stale.',
      new.id, left(new.source_content_hash,12), new.derived_from, left(v_src_hash,12);
  end if;

  return new;
end; $$;

create trigger trg_statement_span
  before insert or update on statements
  for each row execute function enforce_statement_span();

-- ── Evidence: many-to-many, with a quote hash ─────────────────────────────
-- Upstream #11 asks for candidate source locators and quote hashes. This is
-- that, built where it is load-bearing: a statement's support is a row with an
-- exact locator and the hash of the supporting span, so "cites nothing
-- resolvable" becomes a query rather than a discovery.
create table statement_evidence (
  id             uuid primary key default gen_random_uuid(),
  statement_id   uuid not null references statements(id) on delete cascade,
  evidence_kind  text not null check (evidence_kind in
                   ('source_span','raw_artifact','external_document','wiki_page','other_record')),
  exact_locator  text not null check (btrim(exact_locator) <> ''),
  quote          text,
  quote_hash     text,
  ref_table      text,
  ref_id         uuid,
  note           text,
  recorded_at    timestamptz not null default now(),
  -- a quote and its hash travel together or not at all; a hash with no quote
  -- cannot be re-verified by a reader, and a quote with no hash cannot be
  -- checked against drift
  constraint statement_evidence_quote_pair
    check ((quote is null) = (quote_hash is null))
);

create index on statement_evidence (statement_id);
create index on statement_evidence (ref_table, ref_id);

alter table statement_evidence enable row level security;
revoke all on statement_evidence from anon, authenticated;

comment on table statement_evidence is
  'Statement-to-evidence, many-to-many, with an exact locator and a quote hash. The only way a statement can claim support: there is no citation column on statements, so unlinked evidence is inexpressible rather than merely discouraged.';

-- ── Relations ─────────────────────────────────────────────────────────────
-- Directional by default. `contradicts` is the exception and the decision is
-- made ONCE here rather than left to each writer.
create type statement_relation_kind as enum (
  'supports',    -- A gives reason to believe B                      DIRECTIONAL
  'contradicts', -- A and B cannot both be true                      SYMMETRIC
  'refines',     -- A is a more precise version of B                 DIRECTIONAL
  'supersedes',  -- A replaces B as the current claim                DIRECTIONAL
  'depends_on'   -- A is only meaningful if B holds                  DIRECTIONAL
);

create table statement_relations (
  id             uuid primary key default gen_random_uuid(),
  from_statement uuid not null references statements(id) on delete cascade,
  to_statement   uuid not null references statements(id) on delete cascade,
  relation_kind  statement_relation_kind not null,

  -- a relation is itself an assertion, so it carries its own custody. "These
  -- two claims conflict" is a judgement someone or something made, and an
  -- unattributed one is indistinguishable from a fact.
  asserted_by_extraction uuid references statement_extractions(id),
  asserted_by_principal  uuid references principals(id),
  method         text not null check (method in ('model','human','rule')),
  confidence     numeric(3,2) check (confidence between 0 and 1),
  rationale      text not null check (btrim(rationale) <> ''),
  recorded_at    timestamptz not null default now(),
  retracted_at   timestamptz,

  constraint relation_distinct_statements check (from_statement <> to_statement),
  -- SYMMETRY, DECIDED ONCE: contradicts is stored exactly once, in canonical
  -- uuid order. Storing both directions invites them to disagree -- one
  -- retracted, one not -- and then "is there a contradiction?" has two answers.
  -- Read it through statement_conflicts(), which returns both directions.
  constraint contradicts_canonical_order
    check (relation_kind <> 'contradicts' or from_statement < to_statement),
  -- an assertion with no asserter is not attributable
  constraint relation_has_asserter
    check (asserted_by_extraction is not null or asserted_by_principal is not null)
);

create unique index statement_relations_unique
  on statement_relations (from_statement, to_statement, relation_kind)
  where retracted_at is null;

create index on statement_relations (to_statement);

alter table statement_relations enable row level security;
revoke all on statement_relations from anon, authenticated;

alter table statements enable row level security;
revoke all on statements from anon, authenticated;

-- ── Attribution: the whole point, as a function ───────────────────────────
-- Returns BOTH custody links. There is no single-author view and there will not
-- be one: any caller wanting "who said this" must confront the fact that the
-- world-claim and the fidelity-claim have different owners.
create or replace function statement_attribution(p_statement_id uuid)
returns table (
  claim                text,
  modality             statement_modality,
  world_claim_source   uuid,
  world_claim_basis    provenance_basis,
  world_claim_author   text,
  world_claim_status   record_status,
  fidelity_method      text,
  fidelity_actor       uuid,
  fidelity_model       text,
  fidelity_prompt_digest text,
  fidelity_asserted_at timestamptz,
  source_drifted       boolean,
  evidence_count       bigint
) language sql stable security definer set search_path = public, extensions as $$
  select s.claim, s.modality,
         m.id, s.inherited_basis,
         coalesce(m.source_agent, m.source_kind::text),
         m.status,
         e.method, e.actor_principal,
         nullif(concat_ws(' ', e.model_name, e.model_version), ''),
         e.prompt_digest, e.started_at,
         -- computed, never stored: a stored staleness flag goes stale itself,
         -- which is the defect migration 39 fixed in the retrieval projection
         (encode(digest(m.content,'sha256'),'hex') is distinct from s.source_content_hash),
         (select count(*) from statement_evidence ev where ev.statement_id = s.id)
  from statements s
  join memories m on m.id = s.derived_from
  join statement_extractions e on e.id = s.extraction_id
  where s.id = p_statement_id;
$$;

comment on function statement_attribution(uuid) is
  'The two-custody answer. world_claim_* describes who asserted the fact and on what basis (the source record). fidelity_* describes who asserted that this text expresses that claim (the extraction). Deliberately no single author field: collapsing these is how a statement layer launders machine inference into apparent fact.';

-- ── Read surfaces ─────────────────────────────────────────────────────────
create or replace function statement_state(p_statement_id uuid)
returns table (statement_id uuid, state text, source_status record_status, detail text)
language sql stable security definer set search_path = public, extensions as $$
  select s.id,
         case
           when s.retracted_at is not null then 'retracted'
           when m.id is null then 'orphaned'
           when encode(digest(m.content,'sha256'),'hex') is distinct from s.source_content_hash
             then 'stale_source'
           when m.status <> 'current' then 'source_' || m.status::text
           else 'live'
         end,
         m.status,
         case
           when encode(digest(m.content,'sha256'),'hex') is distinct from s.source_content_hash
             then 'source record changed after extraction; re-extract before relying on this'
           when m.status <> 'current'
             then 'source record is no longer current'
           else null
         end
  from statements s left join memories m on m.id = s.derived_from
  where s.id = p_statement_id;
$$;

-- Symmetric relations read in both directions. Storage is canonical; reading is
-- not, because a caller asking "what conflicts with X" should not have to know
-- which side of a uuid comparison X landed on.
create or replace function statement_conflicts(p_statement_id uuid)
returns table (other_statement uuid, other_claim text, rationale text,
               method text, confidence numeric, other_source uuid)
language sql stable security definer set search_path = public as $$
  select case when r.from_statement = p_statement_id then r.to_statement else r.from_statement end,
         o.claim, r.rationale, r.method, r.confidence, o.derived_from
  from statement_relations r
  join statements o
    on o.id = case when r.from_statement = p_statement_id then r.to_statement else r.from_statement end
  where r.relation_kind = 'contradicts'
    and r.retracted_at is null
    and (r.from_statement = p_statement_id or r.to_statement = p_statement_id);
$$;

-- Rebuild honesty: which statements no longer match their source.
create or replace function statement_drift()
returns table (statement_id uuid, derived_from uuid, claim text, reason text)
language sql stable security definer set search_path = public, extensions as $$
  select s.id, s.derived_from, s.claim,
         case when m.id is null then 'source record deleted'
              when encode(digest(m.content,'sha256'),'hex') is distinct from s.source_content_hash
                then 'source content changed since extraction'
              else 'source no longer current: ' || m.status::text end
  from statements s left join memories m on m.id = s.derived_from
  where s.retracted_at is null
    and (m.id is null
         or encode(digest(m.content,'sha256'),'hex') is distinct from s.source_content_hash
         or m.status <> 'current');
$$;

revoke execute on function statement_attribution(uuid) from anon, authenticated, public;
revoke execute on function statement_state(uuid) from anon, authenticated, public;
revoke execute on function statement_conflicts(uuid) from anon, authenticated, public;
revoke execute on function statement_drift() from anon, authenticated, public;
revoke execute on function enforce_statement_span() from anon, authenticated, public;

-- ── Access model ──────────────────────────────────────────────────────────
-- No policies here, same as the task board. Statements inherit owner/visibility
-- from their source and will reuse can_read_row_as_request() when policies are
-- written; inventing a parallel path for a projection would reproduce the ACL
-- divergence that migration 39 existed to fix. Until then: RLS enabled, no
-- policy, deny-all, service_role only.
