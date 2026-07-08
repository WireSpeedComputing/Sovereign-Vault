-- 03_provenance.sql
-- Sovereign Vault (business) — Phase 1: provenance basis enforcement
--
-- Generalizes a provenance trigger from a live production deployment (built
-- after a fabricated figure was caught in agent-generated output) into a
-- reusable pattern for ANY consequential table, not just financial ones.
-- This is the hard gate for multi-user: multiple writers without enforced
-- fact-sourcing is not a verifiable source of truth, it's a shared guess.
--
-- The rule: every row in a table registered as "consequential" must declare
-- WHERE its facts came from. If the basis isn't a direct human statement,
-- it needs a citation. Agent-derived facts are never accepted as the basis
-- for a consequential record — an agent can propose, a human (or a decision
-- record with a human behind it) has to be the basis.

create type provenance_basis as enum (
  'human_direct',       -- a human said this, directly, in this session
  'decision_record',    -- traceable to a specific prior decision/memory row
  'imported_artifact',  -- from a file/document/export, with source_ref
  'source_document'     -- from an external document (contract, invoice, spec)
);

-- Add provenance columns to the two generic knowledge tables. Domain tables
-- this business adds later should include the same two columns and register
-- with provenance_registry (below) to get the same enforcement for free.
alter table memories   add column provenance_basis provenance_basis;
alter table memories   add column citation text;
alter table wiki_pages add column provenance_basis provenance_basis;
alter table wiki_pages add column citation text;

-- Registry of tables opted into provenance enforcement, so the trigger
-- function can be attached generically without hardcoding table names.
create table provenance_registry (
  table_name text primary key,
  requires_citation_unless text[] not null default array['human_direct']::text[],
  registered_at timestamptz not null default now(),
  registered_by uuid references principals(id)
);

insert into provenance_registry (table_name) values ('memories'), ('wiki_pages');

create or replace function enforce_provenance()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_exempt text[];
begin
  select requires_citation_unless into v_exempt
  from provenance_registry where table_name = tg_table_name;

  if v_exempt is null then
    -- table isn't registered; nothing to enforce
    return new;
  end if;

  if new.provenance_basis is null then
    raise exception 'provenance_basis is required on %.% (row id: %)',
      tg_table_schema, tg_table_name, new.id;
  end if;

  if not (new.provenance_basis::text = any(v_exempt)) and (new.citation is null or length(trim(new.citation)) = 0) then
    raise exception
      '%.% requires a non-empty citation when provenance_basis is not %  (row id: %, basis: %)',
      tg_table_schema, tg_table_name, v_exempt, new.id, new.provenance_basis;
  end if;

  return new;
end; $$;

create trigger trg_enforce_provenance_memories
  before insert or update on memories
  for each row execute function enforce_provenance();

create trigger trg_enforce_provenance_wiki
  before insert or update on wiki_pages
  for each row execute function enforce_provenance();

-- Agent-derived facts never satisfy provenance on their own. If an agent's
-- source_kind is 'agent', provenance_basis cannot be human_direct — force it
-- to declare an actual traceable source, and a proposed status until a human
-- promotes it.
create or replace function enforce_agent_cannot_self_attest()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.source_kind = 'agent' and new.provenance_basis = 'human_direct' then
    raise exception
      'agent-sourced rows cannot claim human_direct provenance (row id: %). Use decision_record, imported_artifact, or source_document, and set status = proposed until a human promotes it.',
      new.id;
  end if;
  if new.source_kind = 'agent' and new.status = 'current' and new.provenance_basis is distinct from 'decision_record' then
    -- Agents may only land directly at 'current' if backed by a specific
    -- decision record a human already made. Everything else starts proposed.
    raise exception
      'agent-sourced rows must have status = proposed unless provenance_basis = decision_record (row id: %)',
      new.id;
  end if;
  return new;
end; $$;

create trigger trg_agent_no_self_attest_memories
  before insert or update on memories
  for each row execute function enforce_agent_cannot_self_attest();

create trigger trg_agent_no_self_attest_wiki
  before insert or update on wiki_pages
  for each row execute function enforce_agent_cannot_self_attest();

revoke execute on function enforce_provenance() from anon, authenticated, public;
revoke execute on function enforce_agent_cannot_self_attest() from anon, authenticated, public;
alter table provenance_registry enable row level security;
revoke all on provenance_registry from anon, authenticated;
