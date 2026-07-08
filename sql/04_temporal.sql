-- 04_temporal.sql
-- Sovereign Vault (business) — Phase 1: temporal truth
--
-- "When we recorded it" and "when it was true" are different facts and
-- collapsing them loses information a business eventually needs (audits,
-- price-change history, headcount-over-time, "what did we believe on date X").
-- This adds that distinction to the generic knowledge tables and documents
-- the pattern for domain tables.
--
-- record_status (already defined in 01_core.sql) does the lifecycle:
--   proposed -> current -> superseded | retracted | entered_in_error
-- These columns do the calendar:
--   observed_at     when the fact became true in the world (may be unknown)
--   effective_from  when this record starts being the authoritative version
--   effective_to    when it stopped (null = still in effect)
--   recorded_at     when it was written to this database (system time, not
--                   editable — separate from created_at which already exists
--                   and is closer to "row created"; recorded_at is explicit
--                   about being the audit anchor)

alter table memories   add column observed_at    timestamptz;
alter table memories   add column effective_from timestamptz not null default now();
alter table memories   add column effective_to   timestamptz;
alter table memories   add column recorded_at    timestamptz not null default now();

alter table wiki_pages add column observed_at    timestamptz;
alter table wiki_pages add column effective_from timestamptz not null default now();
alter table wiki_pages add column effective_to   timestamptz;
alter table wiki_pages add column recorded_at    timestamptz not null default now();

create index on memories (effective_from, effective_to);
create index on wiki_pages (effective_from, effective_to);

-- supersede_record(): the ONLY sanctioned way to correct a current record.
-- Never UPDATE a current row's content directly — call this instead. It
-- closes out the old row's effective_to, inserts the replacement pointing
-- back via supersedes, and keeps both readable forever (nothing is deleted).
create or replace function supersede_memory(
  p_old_id uuid, p_new_content text, p_new_provenance_basis provenance_basis,
  p_new_citation text, p_reason text default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare v_new_id uuid; v_old memories%rowtype;
begin
  select * into v_old from memories where id = p_old_id;
  if not found then raise exception 'no memory with id %', p_old_id; end if;
  if v_old.status <> 'current' then
    raise exception 'can only supersede a current record (id % is %)', p_old_id, v_old.status;
  end if;

  update memories set status = 'superseded', effective_to = now(), updated_at = now()
  where id = p_old_id;

  insert into memories (
    content, workstream, tags, source_kind, source_agent, source_ref,
    provenance_basis, citation, status, supersedes, effective_from, recorded_at, metadata
  ) values (
    p_new_content, v_old.workstream, v_old.tags, v_old.source_kind, v_old.source_agent, v_old.source_ref,
    p_new_provenance_basis, p_new_citation, 'current', p_old_id, now(), now(),
    v_old.metadata || jsonb_build_object('supersede_reason', p_reason)
  ) returning id into v_new_id;

  return v_new_id;
end; $$;

revoke execute on function supersede_memory(uuid, text, provenance_basis, text, text) from anon, authenticated, public;
alter function supersede_memory(uuid, text, provenance_basis, text, text) set search_path = public;

-- Pattern note for domain tables (documented, not enforced here — domain
-- tables are bring-your-own-schema): give them the same four temporal
-- columns plus record_status, and write a supersede_<table>() function
-- following this shape rather than allowing direct UPDATE on current rows.
-- docs/01-architecture.md has the full template.
