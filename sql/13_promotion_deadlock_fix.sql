-- Promotion deadlock fix: promote_memory() performs its own sanctioned status-mutating
-- UPDATE, which was tripping the provenance guard meant to stop an agent from
-- self-attesting a row to "current" -- the guard could not distinguish the sanctioned
-- transition from a bare UPDATE attempting the same thing. Confirmed present: an
-- agent-sourced proposed row with provenance_basis in (imported_artifact, source_document)
-- could never be promoted through the sanctioned function.
--
-- Fix: a transaction-local GUC guard (app.promoting). promote_memory() sets it immediately
-- before, and resets it immediately after, its own guarded UPDATE -- wrapped in an
-- exception handler so the guard resets even if the UPDATE itself raises. SET LOCAL
-- persists for the remainder of the current TRANSACTION, not just one statement, so
-- resetting promptly (rather than leaving it set until transaction end) matters: without
-- the reset, a later bare UPDATE in the same multi-statement transaction as a successful
-- promotion would still see the guard armed.
--
-- HONEST LIMIT: under a single shared service-role key, this is accident-prevention and
-- audit, NOT identity enforcement. Any caller sharing that connection can set the same GUC
-- directly and bypass the human-principal check that precedes it in promote_memory(). Real
-- enforcement requires per-principal connection identity, which this does not provide.

CREATE OR REPLACE FUNCTION public.enforce_agent_cannot_self_attest()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  -- Rule 1 (unchanged, INSERT + UPDATE): agent-sourced rows cannot claim human_direct provenance.
  if new.source_kind = 'agent' and new.provenance_basis = 'human_direct' then
    raise exception
      'agent-sourced rows cannot claim human_direct provenance (row id: %). Use decision_record, imported_artifact, or source_document, and set status = proposed until a human promotes it.',
      new.id;
  end if;

  -- Rule 2: agent-sourced rows must be proposed unless provenance_basis = decision_record.
  -- INSERT: unchanged, always enforced (an agent cannot insert directly at current).
  -- UPDATE: the proposed->current transition is allowed ONLY when the promotion guard is
  -- set (i.e. only through promote_memory()). A bare UPDATE without the guard stays blocked.
  if new.source_kind = 'agent' and new.status = 'current' and new.provenance_basis is distinct from 'decision_record' then
    if TG_OP = 'UPDATE' and coalesce(current_setting('app.promoting', true), 'off') = 'on' then
      null; -- sanctioned promotion transition in progress, allow through
    else
      raise exception
        'agent-sourced rows must have status = proposed unless provenance_basis = decision_record (row id: %). Use promote_memory() to promote a proposed row.',
        new.id;
    end if;
  end if;

  return new;
end; $function$;

-- General bounded-status-mutation guard: deny ANY direct status mutation on memories/
-- wiki_pages -- regardless of source_kind -- outside the sanctioned functions (promote_memory,
-- supersede_memory, reject_memory). Same GUC, so a single guard set by any sanctioned
-- function covers both this check and the agent-specific rule above.
CREATE OR REPLACE FUNCTION public.enforce_bounded_status_transition()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if OLD.status is distinct from NEW.status then
    if coalesce(current_setting('app.promoting', true), 'off') <> 'on' then
      raise exception
        'direct status mutation on %.% is not permitted outside sanctioned functions (promote_memory, supersede_memory, reject_memory). row id: %, attempted % -> %',
        TG_TABLE_SCHEMA, TG_TABLE_NAME, NEW.id, OLD.status, NEW.status;
    end if;
  end if;
  return new;
end; $function$;

REVOKE ALL ON FUNCTION public.enforce_bounded_status_transition() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_bounded_status_memories BEFORE UPDATE ON public.memories FOR EACH ROW EXECUTE FUNCTION public.enforce_bounded_status_transition();
CREATE TRIGGER trg_bounded_status_wiki BEFORE UPDATE ON public.wiki_pages FOR EACH ROW EXECUTE FUNCTION public.enforce_bounded_status_transition();

CREATE OR REPLACE FUNCTION public.promote_memory(p_id uuid, p_promoted_by uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_status record_status; v_kind principal_kind;
begin
  select status into v_status from memories where id = p_id;
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
      metadata = metadata || jsonb_build_object('promoted_by', p_promoted_by, 'promoted_at', now())
    where id = p_id;
    set local app.promoting = 'off';
  exception when others then
    set local app.promoting = 'off';
    raise;
  end;

  return 'promoted';
end; $function$;

CREATE OR REPLACE FUNCTION public.supersede_memory(p_old_id uuid, p_new_content text, p_new_provenance_basis provenance_basis, p_new_citation text, p_reason text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_new_id uuid; v_old memories%rowtype;
begin
  select * into v_old from memories where id = p_old_id;
  if not found then raise exception 'no memory with id %', p_old_id; end if;
  if v_old.status <> 'current' then
    raise exception 'can only supersede a current record (id % is %)', p_old_id, v_old.status;
  end if;

  begin
    set local app.promoting = 'on';
    update memories set status = 'superseded', effective_to = now(), updated_at = now()
    where id = p_old_id;
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
    v_old.metadata || jsonb_build_object('supersede_reason', p_reason)
  ) returning id into v_new_id;

  return v_new_id;
end; $function$;
