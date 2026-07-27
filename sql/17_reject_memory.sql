-- reject_memory(): the third leg of the propose/accept/reject/supersede bounded-API
-- pattern (sql/13 covers accept via promote_memory and correct via supersede_memory).
-- Rejects a proposed row outright rather than promoting it -- for a proposed fact that
-- turns out to be wrong or unwanted, not one that needs correcting-and-replacing (that's
-- supersede_memory's job, and only applies to already-current rows in any case).
--
-- Lands the row at 'entered_in_error' (a terminal record_status distinct from 'superseded',
-- since this was never true rather than true-then-corrected) and stamps who rejected it and
-- why, mirroring promote_memory's promoted_by/promoted_at stamp pattern. Uses the same
-- app.promoting transaction-local guard as the other two sanctioned functions (sql/13), with
-- the same exception-safe reset.

CREATE OR REPLACE FUNCTION public.reject_memory(p_id uuid, p_rejected_by uuid, p_reason text)
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
      metadata = metadata || jsonb_build_object('rejected_by', p_rejected_by, 'rejected_at', now(), 'rejection_reason', p_reason)
    where id = p_id;
    set local app.promoting = 'off';
  exception when others then
    set local app.promoting = 'off';
    raise;
  end;

  return 'rejected';
end; $function$;
