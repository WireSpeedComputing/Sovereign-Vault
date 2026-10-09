-- 39_custody_field_locks.sql
-- MIGRATION: 51_custody_field_locks
-- Lock the original custody claim after recording: content, attribution,
-- provenance and temporal identity. Corrections create linked successors.
-- Lifecycle and authorization-input changes use their reviewed transitions.
-- Test a valid referenced replacement value as well as malformed values:
-- foreign-key rejection alone does not prove custody immutability.
-- Administrative credentials and trigger-control privileges require separate
-- review; a custody lock does not authenticate a request.

create or replace function enforce_custody_field_locks()
returns trigger language plpgsql as $fn$
declare v text := '';
begin
  if new.id               is distinct from old.id               then v := v||'id '; end if;
  if new.recorded_at      is distinct from old.recorded_at      then v := v||'recorded_at '; end if;
  if new.observed_at      is distinct from old.observed_at      then v := v||'observed_at '; end if;
  if new.effective_from   is distinct from old.effective_from   then v := v||'effective_from '; end if;
  if new.provenance_basis is distinct from old.provenance_basis then v := v||'provenance_basis '; end if;
  if new.citation         is distinct from old.citation         then v := v||'citation '; end if;
  if new.source_kind      is distinct from old.source_kind      then v := v||'source_kind '; end if;
  if new.source_agent     is distinct from old.source_agent     then v := v||'source_agent '; end if;
  if new.supersedes       is distinct from old.supersedes       then v := v||'supersedes '; end if;
  if new.content          is distinct from old.content          then v := v||'content '; end if;
  if v <> '' then
    raise exception 'custody fields are locked after recording (attempted: %). Corrections append a successor via supersede_memory(); they never rewrite the original claim.', btrim(v);
  end if;
  return new;
end; $fn$;

create trigger trg_custody_locks_memories
  before update on memories
  for each row execute function enforce_custody_field_locks();

comment on function enforce_custody_field_locks() is
  'Chain-of-custody field locking. Custody claims are immutable after recording; lifecycle and classification fields remain mutable so sanctioned transitions continue to work.';

-- NOT YET COVERED, stated so the gap is visible rather than assumed closed:
-- wiki_pages carries the same custody columns and has no equivalent trigger.
-- Applying one requires first verifying supersede_wiki() against it, the way
-- the memories transitions were verified here.
