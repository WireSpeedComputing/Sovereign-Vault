-- 62_supersede_by_existing.sql
--
-- MIGRATION: 77_supersede_by_existing
--
-- WO-19 Task D. The workaround existed because the operation did not.
--
-- ══════════════════════════════════════════════════════════════════════════
-- THE DEFECT, WHICH IS NOT THE ONE THAT WAS REPORTED
-- ══════════════════════════════════════════════════════════════════════════
-- Reported: ownership retrieval returns three current records, two of which
-- open with the word SUPERSEDED in their own content.
--
-- Actual: `supersede_memory(old_id, new_content, ...)` supersedes ONLY by
-- creating a new record. There is no way to say "this row is superseded by
-- that row, which already exists". The two ownership rows already had their
-- successor, so the only expressive tool available was English, and someone
-- reasonably used it -- editing content to announce obsolescence while
-- leaving status = 'current'.
--
-- Retrieval keys on status. Prose is not status. So all three came back, on
-- equity data, and the two obsolete ones are indistinguishable from the live
-- one to anything that does not read English.
--
-- A workaround in the data is a message about the schema. This migration reads
-- it as one.
--
-- ══════════════════════════════════════════════════════════════════════════
-- WHY A NEW COLUMN AND NOT THE EXISTING ONE
-- ══════════════════════════════════════════════════════════════════════════
-- `memories.supersedes` says "I supersede that row" -- it points BACKWARD from
-- successor to predecessor, and it is a single uuid.
--
-- The ownership case needs the opposite arity. ONE authoritative record
-- (3baf529c, the 2026-07-27 owner decision) supersedes TWO obsolete records.
-- A single `supersedes` uuid on the successor cannot hold two predecessors, so
-- the relationship is not expressible in the existing column no matter which
-- function writes it. That is the structural reason the workaround was prose
-- and not a missing convenience.
--
-- `superseded_by` on the OLD row carries the many-to-one direction naturally:
-- many predecessors may point at one successor. Both directions now exist and
-- they answer different questions.

alter table public.memories
  add column if not exists superseded_by uuid references public.memories(id);

comment on column public.memories.superseded_by is
  'Set when this row was superseded BY AN ALREADY-EXISTING row (migration 77). Complements `supersedes`, which points the other way and is written when supersede_memory() creates a successor. Many rows may point at one successor; that arity is why this column exists and why the relationship could not be expressed by writing to `supersedes` on the successor.';

create index if not exists idx_memories_superseded_by
  on public.memories(superseded_by) where superseded_by is not null;

-- ══════════════════════════════════════════════════════════════════════════
-- THE OPERATION
-- ══════════════════════════════════════════════════════════════════════════
-- Human-gated exactly like promote_memory() and supersede_memory(). The point
-- of this function is to retire a record on equity, pricing and formulation
-- data; it is not a convenience for an agent to tidy up behind itself.
create or replace function public.supersede_memory_by_existing(
  p_old_id           uuid,
  p_successor_id     uuid,
  p_acting_principal uuid,
  p_reason           text
) returns text
language plpgsql security definer set search_path to 'public' as $function$
declare
  v_old       memories%rowtype;
  v_successor memories%rowtype;
  v_kind      principal_kind;
  v_cursor    uuid;
  v_hops      int := 0;
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'a reason is required: this operation retires a record and the reason is the only account of why';
  end if;

  select * into v_old from memories where id = p_old_id for update;
  if not found then raise exception 'no memory with id %', p_old_id; end if;

  select * into v_successor from memories where id = p_successor_id for update;
  if not found then raise exception 'no successor memory with id %', p_successor_id; end if;

  if p_old_id = p_successor_id then
    raise exception 'a record cannot supersede itself (%)', p_old_id;
  end if;

  if v_old.status <> 'current' then
    raise exception 'can only supersede a current record (id % is %)', p_old_id, v_old.status;
  end if;

  -- The successor must itself be live. Pointing a retired record at another
  -- retired record produces a chain that resolves to nothing, which is worse
  -- than the prose it replaces: it LOOKS structured.
  if v_successor.status <> 'current' then
    raise exception 'successor % is %, not current -- retiring a record into a non-current successor resolves to nothing', p_successor_id, v_successor.status;
  end if;

  -- CYCLE GUARD. Walk the successor's own superseded_by chain; if it reaches
  -- the row being retired, the two would point at each other and
  -- memory_successor() would never terminate on real data.
  v_cursor := v_successor.superseded_by;
  while v_cursor is not null and v_hops < 64 loop
    if v_cursor = p_old_id then
      raise exception 'cycle: % is already (transitively) superseded by %', p_successor_id, p_old_id;
    end if;
    select superseded_by into v_cursor from memories where id = v_cursor;
    v_hops := v_hops + 1;
  end loop;
  if v_hops >= 64 then
    raise exception 'supersession chain from % exceeds 64 hops; refusing to add to it', p_successor_id;
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
    update memories set
      status        = 'superseded',
      superseded_by = p_successor_id,
      effective_to  = now(),
      updated_at    = now(),
      metadata      = metadata || jsonb_build_object(
        'superseded_by_record',    p_successor_id,
        'superseded_by_principal', p_acting_principal,
        'superseded_at',           now(),
        'supersede_reason',        p_reason,
        'supersede_mode',          'by_existing_record',
        'actor_assurance',         'caller_asserted_unauthenticated')
    where id = p_old_id and status = 'current';   -- expected state retained
    if not found then
      raise exception 'transition lost a race: memory % is no longer current', p_old_id;
    end if;
    set local app.promoting = 'off';
  exception when others then
    set local app.promoting = 'off';
    raise;
  end;

  return 'superseded by existing record ' || p_successor_id::text;
end; $function$;

comment on function public.supersede_memory_by_existing(uuid,uuid,uuid,text) is
  'Retire a current record by pointing it at an ALREADY-EXISTING current successor. Human-gated. The capability supersede_memory() lacks -- it can only supersede by CREATING a successor, which is why content-level "SUPERSEDED:" prose appeared on ownership and formulation rows instead. Refuses self-supersession, non-current successors, and cycles.';

revoke execute on function public.supersede_memory_by_existing(uuid,uuid,uuid,text)
  from anon, authenticated, public;

-- ══════════════════════════════════════════════════════════════════════════
-- RESOLUTION, DERIVED
-- ══════════════════════════════════════════════════════════════════════════
-- Walks to the authoritative record from any starting point, following either
-- supersession direction. Derived rather than stored: a stored "authoritative"
-- flag is the thing that drifts, and this project has been bitten by that four
-- times.
create or replace function public.memory_successor(p_id uuid)
returns uuid language plpgsql stable security definer set search_path to 'public' as $function$
declare v_cursor uuid := p_id; v_next uuid; v_hops int := 0;
begin
  loop
    select coalesce(m.superseded_by,
                    (select s.id from memories s where s.supersedes = m.id and s.status = 'current' limit 1))
      into v_next
    from memories m where m.id = v_cursor;
    exit when v_next is null or v_hops >= 64;
    v_cursor := v_next;
    v_hops := v_hops + 1;
  end loop;
  return v_cursor;
end; $function$;

comment on function public.memory_successor(uuid) is
  'The authoritative record reachable from p_id, following superseded_by forward and `supersedes` backward. Returns p_id itself when nothing supersedes it. Hop-capped at 64 so malformed data cannot hang a caller.';

-- ══════════════════════════════════════════════════════════════════════════
-- THE DETECTOR -- so the class is findable, not just this instance
-- ══════════════════════════════════════════════════════════════════════════
-- WO-19 said this would not be the only place the workaround was used, and it
-- was right: four rows, not two. The two ownership records it named, plus two
-- formulation records doing the same thing with "SUPERSEDED: consolidated
-- duplicate."
--
-- POSTGRES REGEX TRAP, found by this file's own test failing: `\b` is a
-- BACKSPACE character in Postgres regular expressions, not a word boundary.
-- The boundary metacharacter is `\y`. The first version of this detector used
-- `\b` throughout and therefore matched NOTHING, on any input, forever -- and
-- would have been read as "no other instances of the workaround exist". A
-- detector that cannot fire is worse than no detector, because someone acts on
-- its silence.
--
-- Finding those by remembering to grep is how the next four go unnoticed. This
-- function is the standing check. It reports SUSPECTS, not verdicts -- a record
-- may legitimately discuss supersession ("supersedes all prior pricing
-- records" is the authoritative pricing row saying what it replaced, and must
-- NOT be retired). Deciding is human work; surfacing is not.
create or replace function public.content_level_supersession_suspects()
returns table (
  id          uuid,
  workstream  text,
  marker      text,
  content_head text,
  has_structured_successor boolean
) language sql stable security definer set search_path to 'public' as $function$
  select m.id, m.workstream,
         case
           when m.content ~* '^\s*SUPERSEDED\y'        then 'opens with SUPERSEDED'
           when m.content ~* '^\s*OBSOLETE\y'          then 'opens with OBSOLETE'
           when m.content ~* '\ythis record is (now )?(superseded|obsolete|stale)\y'
                                                        then 'declares itself superseded'
           when m.content ~* '\yno longer (accurate|current|authoritative)\y'
                                                        then 'declares itself not current'
           else 'other'
         end,
         left(m.content, 160),
         m.superseded_by is not null
  from memories m
  where m.status = 'current'
    and (m.content ~* '^\s*SUPERSEDED\y'
      or m.content ~* '^\s*OBSOLETE\y'
      or m.content ~* '\ythis record is (now )?(superseded|obsolete|stale)\y'
      or m.content ~* '\yno longer (accurate|current|authoritative)\y')
  order by m.workstream nulls last, m.created_at;
$function$;

comment on function public.content_level_supersession_suspects() is
  'Current records whose CONTENT announces their own obsolescence -- the prose workaround for the operation migration 77 adds. Anchored at the start of the content on purpose: a record that merely MENTIONS supersession ("supersedes all prior pricing records") is usually the authoritative one and must not be retired. Suspects, not verdicts.';

revoke execute on function public.memory_successor(uuid) from anon, public;
revoke execute on function public.content_level_supersession_suspects() from anon, public;
