-- 20_transition_concurrency_and_actor_custody.sql
--
-- Two defects found by an independent architecture review, both confirmed
-- against a live deployment before fixing.
--
-- DEFECT 1 -- lifecycle races. All three transition functions read a row's
-- status, then UPDATE it later, with no row lock and without retaining the
-- expected state in the UPDATE predicate. Two concurrent sessions can both
-- read 'proposed'; one promotes; the other then rejects, overwriting the
-- result. Not theoretical: a stuck idle-in-COMMIT session holding locks on
-- this table was observed on a live deployment the same day.
--
-- DEFECT 2 -- supersession had no actor custody at all. supersede_memory()
-- accepted no acting principal, did no active-human validation, and recorded
-- no actor, so every supersession was attributable to nobody. The actor is now
-- required and the old unaudited 5-argument form is DROPPED, not left callable.
--
-- On what the actor proves: a caller-supplied principal UUID demonstrates only
-- that the UUID belongs to an active human. It does not prove the caller IS
-- that human while clients share an unrestricted credential. That limit is now
-- written into the audit trail itself as actor_assurance =
-- 'caller_asserted_unauthenticated', so a later reader cannot mistake these
-- records for authenticated attribution. Deriving the actor from verified
-- per-request identity, and removing the public UUID parameter, is the real
-- fix and needs connection identity this schema does not yet have.

create or replace function promote_memory(p_id uuid, p_promoted_by uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_status record_status; v_kind principal_kind;
begin
  select status into v_status from memories where id = p_id for update;
  if not found then raise exception 'no memory with id %', p_id; end if;
  if v_status <> 'proposed' then
    raise exception 'memory % is %, only proposed rows can be promoted', p_id, v_status;
  end if;

  select kind into v_kind from principals where id = p_promoted_by and active;
  if not found then raise exception 'promoter % is not an active principal', p_promoted_by; end if;
  if v_kind <> 'human' then
    raise exception 'only human principals promote proposed rows (%: %)', p_promoted_by, v_kind;
  end if;

  begin
    set local app.promoting = 'on';
    update memories set status = 'current', updated_at = now(),
      metadata = metadata || jsonb_build_object(
        'promoted_by', p_promoted_by, 'promoted_at', now(),
        'actor_assurance', 'caller_asserted_unauthenticated')
    where id = p_id and status = 'proposed';
    if not found then
      raise exception 'transition lost a race: memory % is no longer proposed', p_id;
    end if;
    set local app.promoting = 'off';
  exception when others then
    set local app.promoting = 'off';
    raise;
  end;
  return 'promoted';
end; $$;

create or replace function reject_memory(p_id uuid, p_rejected_by uuid, p_reason text)
returns text language plpgsql security definer set search_path = public as $$
declare v_status record_status; v_kind principal_kind;
begin
  select status into v_status from memories where id = p_id for update;
  if not found then raise exception 'no memory with id %', p_id; end if;
  if v_status <> 'proposed' then
    raise exception 'memory % is %, only proposed rows can be rejected', p_id, v_status;
  end if;

  select kind into v_kind from principals where id = p_rejected_by and active;
  if not found then raise exception 'rejecter % is not an active principal', p_rejected_by; end if;
  if v_kind <> 'human' then
    raise exception 'only human principals reject proposed rows (%: %)', p_rejected_by, v_kind;
  end if;

  begin
    set local app.promoting = 'on';
    update memories set status = 'entered_in_error', effective_to = now(), updated_at = now(),
      metadata = metadata || jsonb_build_object(
        'rejected_by', p_rejected_by, 'rejected_at', now(), 'rejection_reason', p_reason,
        'actor_assurance', 'caller_asserted_unauthenticated')
    where id = p_id and status = 'proposed';
    if not found then
      raise exception 'transition lost a race: memory % is no longer proposed', p_id;
    end if;
    set local app.promoting = 'off';
  exception when others then
    set local app.promoting = 'off';
    raise;
  end;
  return 'rejected';
end; $$;

create or replace function supersede_memory(
  p_old_id uuid, p_new_content text, p_new_provenance_basis provenance_basis,
  p_new_citation text, p_acting_principal uuid, p_reason text default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare v_new_id uuid; v_old memories%rowtype; v_kind principal_kind;
begin
  select * into v_old from memories where id = p_old_id for update;
  if not found then raise exception 'no memory with id %', p_old_id; end if;
  if v_old.status <> 'current' then
    raise exception 'can only supersede a current record (id % is %)', p_old_id, v_old.status;
  end if;

  select kind into v_kind from principals where id = p_acting_principal and active;
  if not found then
    raise exception 'acting principal % is not an active principal', p_acting_principal;
  end if;
  if v_kind <> 'human' then
    raise exception 'only human principals supersede current rows (%: %)', p_acting_principal, v_kind;
  end if;

  begin
    set local app.promoting = 'on';
    update memories set status = 'superseded', effective_to = now(), updated_at = now(),
      metadata = metadata || jsonb_build_object(
        'superseded_by_principal', p_acting_principal, 'superseded_at', now(),
        'actor_assurance', 'caller_asserted_unauthenticated')
    where id = p_old_id and status = 'current';
    if not found then
      raise exception 'transition lost a race: memory % is no longer current', p_old_id;
    end if;
    set local app.promoting = 'off';
  exception when others then
    set local app.promoting = 'off';
    raise;
  end;

  insert into memories (
    content, workstream, tags, source_kind, source_agent, source_ref,
    provenance_basis, citation, status, supersedes, effective_from, recorded_at, metadata
  ) values (
    p_new_content, v_old.workstream, v_old.tags, v_old.source_kind, v_old.source_agent, v_old.source_ref,
    p_new_provenance_basis, p_new_citation, 'current', p_old_id, now(), now(),
    v_old.metadata || jsonb_build_object(
      'supersede_reason', p_reason,
      'supersede_actor', p_acting_principal,
      'actor_assurance', 'caller_asserted_unauthenticated')
  ) returning id into v_new_id;

  return v_new_id;
end; $$;

-- Remove the unaudited form so it cannot be called by accident.
drop function if exists supersede_memory(uuid, text, provenance_basis, text, text);

-- Concurrent supersession could otherwise produce two 'current' replacements
-- for the same predecessor, silently forking the record.
create unique index if not exists memories_one_current_successor_uq
  on memories (supersedes)
  where supersedes is not null and status = 'current';

revoke execute on function promote_memory(uuid, uuid) from anon, authenticated, public;
revoke execute on function reject_memory(uuid, uuid, text) from anon, authenticated, public;
revoke execute on function supersede_memory(uuid, text, provenance_basis, text, uuid, text)
  from anon, authenticated, public;
