-- 47_reclassify_transition.sql
--
-- MIGRATION: 63_reclassify_transition_and_authorization_input_locks
-- MIGRATION: 65_reclassify_record_cast_owner_and_visibility
--
-- WO-14 Phase 2a and 2b. Ruling already made by the owner; this implements it.
--
-- NUMBERING: this file deploys BEFORE sql/45 and sql/46, which are still being
-- written. The repo convention is numbering by deployment order, so a single
-- renumbering pass is owed once nothing is in flight. Recorded here rather than
-- renumbered mid-run, because renaming files another process is writing is how
-- one of them gets lost.
--
-- ══════════════════════════════════════════════════════════════════════════
-- WHY THE TRANSITION IS BUILT BEFORE THE CLASSIFICATION
-- ══════════════════════════════════════════════════════════════════════════
-- Classifying the unclassified records is the first bulk authorization change
-- this system will make. 84 current records move between capability scopes at
-- once. Running that through a direct UPDATE would establish -- by the largest
-- such change we will ever run -- that bulk authorization changes need no
-- audit. Done in this order the same 84 changes become auditable evidence
-- instead of an unattributed rewrite.
--
-- ══════════════════════════════════════════════════════════════════════════
-- WHY workstream IS THE SERIOUS ONE
-- ══════════════════════════════════════════════════════════════════════════
-- `owner` and `visibility` were already flagged as mutable under custody
-- locking. `workstream` is worse, and it is worse for a specific reason:
-- it is the scope input itself. row_scope(workstream) is what
-- can_read_row() resolves capability against, so changing a record's
-- workstream silently moves it between authorization scopes -- with no custody
-- event, no audit row, and no sanctioned transition -- while the CONTENT it
-- exposes is immutable.
--
-- The asymmetry is the whole point. This system spent considerable effort making
-- the claim unrewritable, and left the field that decides who can read the claim
-- editable by anyone with a database connection. An attacker who cannot change
-- what a record says can still change who is allowed to read it, which for most
-- purposes is the more useful capability.
--
-- All three route through ONE function. Three separate paths would drift, and
-- they are the same class of thing: inputs to an authorization decision.

-- ══════════════════════════════════════════════════════════════════════════
-- 1. The audit surface
-- ══════════════════════════════════════════════════════════════════════════
create table if not exists record_authorization_audit (
  id                uuid primary key default gen_random_uuid(),
  record_relation   text        not null check (record_relation in ('memories','wiki_pages')),
  record_id         uuid        not null,
  field             text        not null check (field in ('workstream','owner','visibility')),
  old_value         text,
  new_value         text,
  old_scope         text,
  new_scope         text,
  acting_principal  uuid        not null references principals(id),
  reason            text        not null check (btrim(reason) <> ''),
  changed_at        timestamptz not null default now()
);

comment on table record_authorization_audit is
  'Append-only record of every change to an authorization input (workstream, owner, visibility) on a governed record. One row per field per change, not one per call: a call that moves two fields is two facts, and collapsing them loses the ability to ask when a single field changed. old_scope/new_scope are denormalised deliberately -- they are what the access decision actually resolved to at the time, and recomputing them later from row_scope() would give the answer under today''s mapping rather than the one that applied.';

create index if not exists idx_record_auth_audit_record
  on record_authorization_audit (record_relation, record_id, changed_at desc);

alter table record_authorization_audit enable row level security;

-- Append-only, same shape as promoted_record_audit and hard_delete_audit.
create or replace function enforce_record_auth_audit_append_only()
returns trigger language plpgsql as $$
begin
  raise exception 'record_authorization_audit is append-only (attempted % on %). An audit you can edit is not an audit.',
    tg_op, coalesce(old.id::text, '?');
end; $$;

drop trigger if exists trg_record_auth_audit_append_only on record_authorization_audit;
create trigger trg_record_auth_audit_append_only
  before update or delete on record_authorization_audit
  for each row execute function enforce_record_auth_audit_append_only();

-- ══════════════════════════════════════════════════════════════════════════
-- 2. The sanctioned transition
-- ══════════════════════════════════════════════════════════════════════════
-- Payload is jsonb so that "absent" and "explicitly null" are distinguishable.
-- With plain nullable parameters, reclassifying a record back TO unclassified
-- -- which is NULL workstream -- is indistinguishable from not changing it, and
-- the correction path for a wrong classification would not exist. That is not a
-- hypothetical: classification is judgement, and some of it will be wrong.
create or replace function public.reclassify_record(
  p_relation          text,
  p_record_id         uuid,
  p_acting_principal  uuid,
  p_reason            text,
  p_changes           jsonb
) returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_kind        principal_kind;
  v_field       text;
  v_old         text;
  v_new         text;
  v_old_scope   text;
  v_new_scope   text;
  v_applied     integer := 0;
  v_exists      boolean;
begin
  if p_relation not in ('memories','wiki_pages') then
    raise exception 'reclassify_record: unsupported relation %', p_relation;
  end if;
  if p_changes is null or p_changes = '{}'::jsonb then
    raise exception 'reclassify_record: no changes supplied';
  end if;
  if btrim(coalesce(p_reason,'')) = '' then
    raise exception 'reclassify_record: a reason is required. An authorization change with no stated reason is exactly the unattributed rewrite this function exists to prevent.';
  end if;
  if p_changes - array['workstream','owner','visibility'] <> '{}'::jsonb then
    raise exception 'reclassify_record: only workstream, owner and visibility may be changed here (got %)',
      (select string_agg(k, ',') from jsonb_object_keys(p_changes - array['workstream','owner','visibility']) k);
  end if;

  -- Human-gated, identically to promote_memory/reject_memory. An agent may
  -- propose a classification; it may not enact one. Same reason a proposed row
  -- needs a human to promote it: the point of the gate is that a model cannot
  -- widen its own reach.
  select kind into v_kind from principals where id = p_acting_principal and active;
  if not found then
    raise exception 'reclassify_record: % is not an active principal', p_acting_principal;
  end if;
  if v_kind <> 'human' then
    raise exception 'reclassify_record: only human principals change authorization inputs (%: %)',
      p_acting_principal, v_kind;
  end if;

  execute format('select exists (select 1 from %I where id = $1)', p_relation)
    into v_exists using p_record_id;
  if not v_exists then
    raise exception 'reclassify_record: no % with id %', p_relation, p_record_id;
  end if;

  begin
    -- Same window mechanism as promote_memory, and reset in an exception
    -- handler for the same reason: a GUC left on turns a one-statement
    -- exemption into an open door for the rest of the transaction.
    set local app.reclassifying = 'on';

    foreach v_field in array array['workstream','owner','visibility'] loop
      continue when not (p_changes ? v_field);

      execute format('select %I::text from %I where id = $1', v_field, p_relation)
        into v_old using p_record_id;
      v_new := p_changes ->> v_field;

      continue when v_old is not distinct from v_new;

      if v_field = 'workstream' then
        v_old_scope := row_scope(v_old);
        v_new_scope := row_scope(v_new);
        -- The target scope must be a registered, unretired scope. Without this
        -- a typo silently creates a scope nobody holds, which reads as
        -- "correctly classified" and behaves as "invisible to everyone".
        if not exists (select 1 from scope_registry sr
                       where sr.scope = v_new_scope and sr.retired_at is null) then
          raise exception 'reclassify_record: % is not a registered scope. Declare it in scope_registry first -- an unregistered scope is one nobody can be granted, so the record would be readable by no one.',
            v_new_scope;
        end if;
      else
        v_old_scope := null;
        v_new_scope := null;
      end if;

      if v_field = 'owner' and v_new is not null
         and not exists (select 1 from principals where id = v_new::uuid) then
        raise exception 'reclassify_record: owner % is not a principal', v_new;
      end if;

      -- The cast belongs in the STATEMENT, not in the parameter. The first
      -- version coerced every value to text before binding it, so `set owner =
      -- $1` handed text to a uuid column and `set visibility = $1` handed text
      -- to visibility_level -- both raised at runtime. Only the workstream
      -- branch worked, because workstream is the one text column of the three.
      --
      -- It shipped as migration 63 and was caught by tests/52, the first test
      -- that ever asked this function to change a visibility. tests/47 covered
      -- every refusal and the workstream path, so two of the three fields this
      -- function exists to govern had a positive path that had never once run.
      -- A suite of denials plus one working case reads exactly like coverage.
      execute format('update %I set %I = $1::%s, updated_at = now() where id = $2',
                     p_relation, v_field,
                     case v_field when 'owner'      then 'uuid'
                                  when 'visibility' then 'visibility_level'
                                  else 'text' end)
        using v_new, p_record_id;

      insert into record_authorization_audit(
        record_relation, record_id, field, old_value, new_value,
        old_scope, new_scope, acting_principal, reason)
      values (p_relation, p_record_id, v_field, v_old, v_new,
              v_old_scope, v_new_scope, p_acting_principal, p_reason);

      v_applied := v_applied + 1;
    end loop;

    set local app.reclassifying = 'off';
  exception when others then
    set local app.reclassifying = 'off';
    raise;
  end;

  return v_applied;
end; $$;

-- The named signature from the work order. A thin wrapper, not a second path:
-- it calls the same function and therefore cannot drift from it.
create or replace function public.reclassify_record(
  p_record_id uuid, p_new_workstream text, p_acting_principal uuid, p_reason text
) returns integer
language sql security definer set search_path to 'public' as $$
  select public.reclassify_record('memories', p_record_id, p_acting_principal, p_reason,
                                  jsonb_build_object('workstream', p_new_workstream));
$$;

revoke all on function public.reclassify_record(text,uuid,uuid,text,jsonb) from public, anon, authenticated;
revoke all on function public.reclassify_record(uuid,text,uuid,text) from public, anon, authenticated;
grant execute on function public.reclassify_record(text,uuid,uuid,text,jsonb) to service_role;
grant execute on function public.reclassify_record(uuid,text,uuid,text) to service_role;

-- ══════════════════════════════════════════════════════════════════════════
-- 3. THE LOCK -- and it goes in the same file as the function on purpose
-- ══════════════════════════════════════════════════════════════════════════
-- "Verify the function still works after the lock" -- that ordering has bitten
-- this project twice. Shipping the lock in a later migration than the sanctioned
-- path leaves a window where the columns are locked and nothing can legitimately
-- change them, and the two-file version invites applying them alphabetically.
-- One file, one transaction, no window.
create or replace function enforce_authorization_input_locks()
returns trigger language plpgsql as $$
declare v text := '';
begin
  if coalesce(current_setting('app.reclassifying', true), 'off') = 'on' then
    return new;
  end if;
  if new.workstream is distinct from old.workstream then v := v||'workstream '; end if;
  if new.owner      is distinct from old.owner      then v := v||'owner ';      end if;
  if new.visibility is distinct from old.visibility then v := v||'visibility '; end if;
  if v <> '' then
    raise exception 'authorization inputs are locked (attempted: %). These decide WHO MAY READ this record. Change them through reclassify_record(), which requires a human principal and a stated reason and writes an audit row.', btrim(v);
  end if;
  return new;
end; $$;

drop trigger if exists trg_authorization_input_locks on memories;
create trigger trg_authorization_input_locks
  before update on memories
  for each row execute function enforce_authorization_input_locks();

drop trigger if exists trg_authorization_input_locks_wiki on wiki_pages;
create trigger trg_authorization_input_locks_wiki
  before update on wiki_pages
  for each row execute function enforce_authorization_input_locks();

comment on function enforce_authorization_input_locks() is
  'Blocks direct UPDATE of workstream, owner and visibility -- the three inputs to can_read_row(). Bypassed only inside the reclassify_record() window. This is accident prevention and an audit surface, NOT enforcement: anyone who can set app.reclassifying can set it. The enforcement claim is that the sanctioned path is the only one that leaves no anomaly, not that the GUC cannot be forged.';
