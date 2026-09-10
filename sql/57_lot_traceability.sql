-- 57_lot_traceability.sql
--
-- MIGRATION: 72_lot_traceability
--
-- WO-16 Task D. Lot genealogy, so a recall is a query rather than an
-- archaeology project.
--
-- ══════════════════════════════════════════════════════════════════════════
-- THE TWO QUESTIONS THIS EXISTS TO ANSWER IN ONE QUERY EACH
-- ══════════════════════════════════════════════════════════════════════════
--   FORWARD   a supplier recalls ingredient lot X. Which finished lots contain
--             it, and who received them.
--   INVERSE   a consumer complains citing a bottle. Which ingredient lots are
--             implicated, and what else shares them.
--
-- Both are the same graph read in opposite directions, which is why the
-- genealogy is a table rather than a column on either end.
--
-- ══════════════════════════════════════════════════════════════════════════
-- SHIPPED EMPTY, DELIBERATELY
-- ══════════════════════════════════════════════════════════════════════════
-- No seed data, no examples, no plausible-looking history. A traceability
-- system containing invented lots is worse than none, because it will be
-- trusted -- and the moment it is queried in an actual recall, the invented
-- rows are indistinguishable from the real ones. The suite tests it with
-- synthetic fixtures inside a transaction that rolls back.
--
-- 21 CFR 111 requires batch records. This models them; it does not claim
-- compliance, which depends on what is actually recorded.

create table if not exists ingredient_lot (
  id                 uuid primary key default gen_random_uuid(),
  ingredient_id      uuid not null references ingredients(id),
  supplier_id        uuid references suppliers(id),
  supplier_lot_code  text not null check (btrim(supplier_lot_code) <> ''),

  -- The certificate of analysis for THIS lot. Nullable because a lot can be
  -- received before its COA arrives -- but that is a recordable gap, surfaced
  -- by lot_coa_gaps() below rather than hidden by a NOT NULL nobody can satisfy.
  coa_document_id    uuid references supplier_documents(id),

  quantity_received  numeric,
  quantity_unit      text,
  received_date      date,
  expiry_date        date,
  retest_date        date,

  status             record_status not null default 'proposed',
  supersedes         uuid references ingredient_lot(id),
  source_kind        source_kind not null,
  source_agent       text,
  source_ref         text,
  provenance_basis   provenance_basis not null,
  citation           text,
  recorded_at        timestamptz not null default now(),
  created_at         timestamptz not null default now(),

  constraint qty_has_unit check ((quantity_received is null) = (quantity_unit is null))
);
create unique index if not exists ingredient_lot_unique
  on ingredient_lot (ingredient_id, supplier_lot_code) where status = 'current';
create index if not exists idx_ingredient_lot_ingredient on ingredient_lot (ingredient_id);

comment on table ingredient_lot is
  'An incoming ingredient lot as received. supplier_lot_code is the supplier''s identifier, not ours -- a recall notice names their code, so storing only an internal id makes the forward trace start with a translation step nobody documented.';

create table if not exists finished_lot (
  id                 uuid primary key default gen_random_uuid(),
  product_id         uuid not null references products(id),
  lot_code           text not null check (btrim(lot_code) <> ''),
  manufacture_date   date,
  expiry_date        date,
  quantity_produced  numeric,
  quantity_unit      text,
  manufacturer_id    uuid references suppliers(id),

  status             record_status not null default 'proposed',
  supersedes         uuid references finished_lot(id),
  source_kind        source_kind not null,
  source_agent       text,
  source_ref         text,
  provenance_basis   provenance_basis not null,
  citation           text,
  recorded_at        timestamptz not null default now(),
  created_at         timestamptz not null default now()
);
create unique index if not exists finished_lot_unique
  on finished_lot (product_id, lot_code) where status = 'current';

comment on table finished_lot is
  'A finished-goods lot. lot_code is what appears on the bottle, because that is what a consumer complaint will cite.';

-- ── THE GENEALOGY ─────────────────────────────────────────────────────────
-- Many-to-many on purpose: one finished lot draws on several ingredient lots,
-- and one ingredient lot feeds several finished lots. Modelling either end as
-- a column would make one of the two directions unanswerable, and the recall
-- direction is the one that would have been lost.
create table if not exists finished_lot_component (
  id                 uuid primary key default gen_random_uuid(),
  finished_lot_id    uuid not null references finished_lot(id),
  ingredient_lot_id  uuid not null references ingredient_lot(id),
  quantity_used      numeric,
  quantity_unit      text,
  created_at         timestamptz not null default now(),
  constraint used_qty_has_unit check ((quantity_used is null) = (quantity_unit is null))
);
create unique index if not exists finished_lot_component_unique
  on finished_lot_component (finished_lot_id, ingredient_lot_id);
create index if not exists idx_flc_ingredient_lot on finished_lot_component (ingredient_lot_id);

comment on table finished_lot_component is
  'The genealogy edge: which ingredient lots went into which finished lot. Many-to-many, because modelling it as a column on either end makes one of the two trace directions unanswerable -- and the one that would be lost is the recall direction.';

create table if not exists lot_shipment (
  id                 uuid primary key default gen_random_uuid(),
  finished_lot_id    uuid not null references finished_lot(id),
  recipient_ref      text not null check (btrim(recipient_ref) <> ''),
  recipient_kind     text not null check (recipient_kind in
                       ('customer','retailer','distributor','sample','internal')),
  quantity_shipped   numeric,
  quantity_unit      text,
  shipped_date       date,
  carrier_ref        text,
  created_at         timestamptz not null default now()
);
create index if not exists idx_lot_shipment_lot on lot_shipment (finished_lot_id);

comment on table lot_shipment is
  'Outbound movement of a finished lot. recipient_ref is deliberately a reference rather than a name or address: the recall question is "who received this", and the answer belongs in whatever system already holds customer records.';

alter table ingredient_lot enable row level security;
alter table finished_lot enable row level security;
alter table finished_lot_component enable row level security;
alter table lot_shipment enable row level security;
revoke all on ingredient_lot, finished_lot, finished_lot_component, lot_shipment
  from anon, authenticated;

-- ══════════════════════════════════════════════════════════════════════════
-- FORWARD TRACE: supplier recalls ingredient lot X
-- ══════════════════════════════════════════════════════════════════════════
create or replace function recall_trace_forward(p_ingredient_lot_id uuid)
returns table (
  finished_lot_code  text,
  product            text,
  manufacture_date   date,
  recipient_ref      text,
  recipient_kind     text,
  quantity_shipped   numeric,
  shipped_date       date
) language sql stable security definer set search_path = public as $$
  select fl.lot_code, p.name, fl.manufacture_date,
         coalesce(s.recipient_ref, '(no shipment recorded)'),
         coalesce(s.recipient_kind, '-'),
         s.quantity_shipped, s.shipped_date
  from finished_lot_component flc
  join finished_lot fl on fl.id = flc.finished_lot_id and fl.status = 'current'
  join products p on p.id = fl.product_id
  left join lot_shipment s on s.finished_lot_id = fl.id
  where flc.ingredient_lot_id = p_ingredient_lot_id;
$$;

comment on function recall_trace_forward(uuid) is
  'Given a recalled ingredient lot: every finished lot containing it and every recipient. LEFT JOIN on shipment deliberately -- a finished lot that contains the recalled material but has no shipment recorded must still appear, as "(no shipment recorded)". An INNER JOIN would silently drop exactly the lots whose whereabouts are unknown, which are the ones a recall most needs to surface.';

-- ══════════════════════════════════════════════════════════════════════════
-- INVERSE TRACE: a complaint cites a bottle
-- ══════════════════════════════════════════════════════════════════════════
create or replace function recall_trace_inverse(p_product_id uuid, p_lot_code text)
returns table (
  ingredient          text,
  supplier_lot_code   text,
  supplier            text,
  coa_on_file         boolean,
  received_date       date,
  expiry_date         date,
  other_finished_lots int
) language sql stable security definer set search_path = public as $$
  -- sup.company, not sup.name: the suppliers table names the column `company`.
  -- Read back from information_schema rather than assumed -- the first draft
  -- guessed `name` and failed at apply.
  select i.name, il.supplier_lot_code, sup.company,
         (il.coa_document_id is not null),
         il.received_date, il.expiry_date,
         (select count(*)::int from finished_lot_component f2
          where f2.ingredient_lot_id = il.id and f2.finished_lot_id <> fl.id)
  from finished_lot fl
  join finished_lot_component flc on flc.finished_lot_id = fl.id
  join ingredient_lot il on il.id = flc.ingredient_lot_id
  join ingredients i on i.id = il.ingredient_id
  left join suppliers sup on sup.id = il.supplier_id
  where fl.status = 'current' and fl.product_id = p_product_id and fl.lot_code = p_lot_code;
$$;

comment on function recall_trace_inverse(uuid, text) is
  'Given a bottle: which ingredient lots are implicated, whether each has a COA on file, and how many OTHER finished lots share the same ingredient lot -- because the second question a complaint raises is always how far it spreads.';

-- ══════════════════════════════════════════════════════════════════════════
-- GAPS -- what a batch record is missing, reported rather than assumed clean
-- ══════════════════════════════════════════════════════════════════════════
create or replace function lot_traceability_gaps()
returns table (gap_kind text, detail text, lot_ref text) language sql stable
security definer set search_path = public as $$
  select 'ingredient_lot_without_coa', 'no certificate of analysis linked',
         i.name || ' lot ' || il.supplier_lot_code
  from ingredient_lot il join ingredients i on i.id = il.ingredient_id
  where il.status = 'current' and il.coa_document_id is null
  union all
  select 'finished_lot_without_components', 'no ingredient lots recorded: this lot cannot be traced backwards',
         p.name || ' lot ' || fl.lot_code
  from finished_lot fl join products p on p.id = fl.product_id
  where fl.status = 'current'
    and not exists (select 1 from finished_lot_component c where c.finished_lot_id = fl.id)
  union all
  select 'finished_lot_without_shipments', 'produced but no outbound movement recorded',
         p.name || ' lot ' || fl.lot_code
  from finished_lot fl join products p on p.id = fl.product_id
  where fl.status = 'current'
    and not exists (select 1 from lot_shipment s where s.finished_lot_id = fl.id);
$$;

comment on function lot_traceability_gaps() is
  'What the batch records are missing. Returns zero rows when there are no lots at all -- which is the current state and is NOT a clean bill of health, it is an empty system. Callers must distinguish "no gaps" from "nothing recorded"; lot_traceability_gaps() cannot, and says so here rather than implying otherwise.';

revoke execute on function recall_trace_forward(uuid) from anon, authenticated, public;
revoke execute on function recall_trace_inverse(uuid, text) from anon, authenticated, public;
revoke execute on function lot_traceability_gaps() from anon, authenticated, public;
