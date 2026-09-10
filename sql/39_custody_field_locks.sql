-- 39_custody_field_locks.sql
--
-- MIGRATION: 51_custody_field_locks
--
-- Chain-of-custody field locking. Closes the protocol's PRINCIPAL requirement,
-- on which this deployment was at literal zero.
--
-- ══════════════════════════════════════════════════════════════════════════
-- WHAT WAS ACTUALLY TRUE BEFORE THIS
-- ══════════════════════════════════════════════════════════════════════════
-- Probed live rather than assumed. recorded_at, provenance_basis, source_agent
-- and content were ALL rewritable in place. `supersedes` only appeared
-- protected because the probe passed a UUID that failed a foreign key — that is
-- referential integrity, not a custody lock. Functionally, zero custody fields
-- were locked.
--
-- The exposure: anyone holding the shared service credential — which is every
-- agent — could silently rewrite WHO recorded something, WHEN, UNDER WHAT
-- AUTHORITY, and WHAT IT SAID. Provenance triggers validated that values were
-- well-formed AT WRITE and did nothing to prevent changing them afterward.
--
-- Stated generally, because it is the reusable lesson: enforcement at insert
-- without immutability after is not custody. It is a well-formedness check
-- wearing custody's clothes, and it reads as protection to anyone auditing the
-- trigger list rather than probing the behaviour.
--
-- ══════════════════════════════════════════════════════════════════════════
-- LOCKED vs MUTABLE, and why the split is not arbitrary
-- ══════════════════════════════════════════════════════════════════════════
-- LOCKED — the custody claim itself: identity; recorded, observed and effective
-- times; provenance basis; citation; source kind and agent; the supersession
-- pointer; and content. Corrections append a successor through
-- supersede_memory(); they never rewrite the original claim.
--
-- MUTABLE — lifecycle and classification: status, effective_to, due_date,
-- due_status, tags, workstream, owner, visibility, metadata, updated_at.
-- Locking these would break promotion, rejection, supersession and deadline
-- management.
--
-- That second list is the part worth testing rather than reasoning about. All
-- three sanctioned transitions were exercised against this trigger before it
-- was applied and again after: promote, supersede and reject all succeed, every
-- locked field is rejected, and lifecycle updates still work. A custody lock
-- that also froze lifecycle would look identical in a trigger listing and would
-- break the system silently at the first correction.
--
-- ══════════════════════════════════════════════════════════════════════════
-- ORDERING
-- ══════════════════════════════════════════════════════════════════════════
-- Agent attribution had to be resolved by MAPPING (previous migration) before
-- this landed, because afterwards source_agent cannot be rewritten even to
-- correct it. That is the intended property. Any registry correction must
-- happen before the locks, or be expressed as a mapping rather than an edit.

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
