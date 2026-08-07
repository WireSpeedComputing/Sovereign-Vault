-- 25_propose_then_promote.sql
--
-- ADOPT: upstream sovereign-memory-core #46 (review/promotion guards) and #47
-- (promoted-record mutation audit). One file because they are one mechanism:
-- #46 controls how a row BECOMES authoritative, #47 controls what may happen to
-- it AFTER. Splitting them would put two halves of the same invariant in two
-- migrations that could be applied independently.
--
-- NOT YET APPLIED to any deployment. Filed in sql/ rather than pending/ because
-- the design is owner-decided (2026-08-07) and the negative suite in
-- tests/23_promotion_guards_negative.sql can only be demonstrated green by a
-- replay that includes it. STATUS.md records that the deployment does not yet
-- have this.
--
-- ── WHAT WAS OPEN ──────────────────────────────────────────────────────────
-- Probed against a clean PG17 replay of sql/00-22: all five forbidden paths #46
-- names were open, plus three more. Root cause was not a broken guard; it was
-- that no guard ran on the INSERT path at all.
--
--   * enforce_bounded_status_transition is BEFORE UPDATE only.
--   * enforce_agent_cannot_self_attest constrains only source_kind='agent'.
--   * promote_memory() was therefore a convenience wrapper, not a chokepoint:
--     any caller could INSERT status='current' directly and never touch it.
--   * memories.source_artifact_id was a bare FK, unconstrained with respect to
--     raw_artifacts.action, so hold/exclude/evidence artifacts normalized and
--     promoted cleanly through the sanctioned human gate.
--
-- ── THE FIX: PROPOSE-THEN-PROMOTE ──────────────────────────────────────────
-- status='current' becomes unreachable by direct INSERT. Everything lands
-- 'proposed'; the SECURITY DEFINER functions become the sole path to authority.
--
-- Deliberately NOT keyed on source_kind. source_kind is caller-declared, so any
-- rule keyed on it is bypassable by assertion — a caller who wants to skip an
-- agent rule simply declares 'manual'. The sanction model keys on the
-- transaction guard the definer functions set, which is at least a positive act
-- by a specific function rather than a self-description.
--
-- ── WHAT THIS IS AND IS NOT ────────────────────────────────────────────────
-- app.promoting is a session GUC. Anyone holding service_role can set it and
-- walk straight through every guard in this file. This closes the ACCIDENTAL
-- path, not the deliberate one. It is accident-prevention and an audit surface,
-- not enforcement — the same limit already recorded for actor_assurance in
-- sql/20 and for the GUC itself in sql/13, and it is stated the same way here so
-- no later reader mistakes these guards for authentication.
--
-- Real enforcement needs per-principal connection identity. That is the
-- vault_auth layer, not this file.

-- ══════════════════════════════════════════════════════════════════════════
-- PART 1 (#46) — status='current' is unreachable by direct INSERT
-- ══════════════════════════════════════════════════════════════════════════

create or replace function enforce_insert_status_sanction()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'current'
     and coalesce(current_setting('app.promoting', true), 'off') <> 'on' then
    raise exception
      'direct INSERT at status=current is not permitted on %.% (row id: %). Insert at status=proposed and use promote_memory(); supersession inserts its successor through supersede_memory().',
      tg_table_schema, tg_table_name, new.id;
  end if;
  return new;
end; $$;

revoke execute on function enforce_insert_status_sanction() from anon, authenticated, public;

-- memories ONLY, deliberately. wiki_pages is NOT gated here: it has no
-- promote_wiki(), its column default is status='current', and supersede_wiki()
-- (sql/23) only replaces an already-current page. Gating wiki INSERT would make
-- wiki_pages uncreatable with no sanctioned path to create one. Closing that
-- asymmetry needs a promote_wiki() first; recorded as an open item in STATUS.md
-- rather than shipped as a break.
drop trigger if exists trg_insert_status_sanction_memories on memories;
create trigger trg_insert_status_sanction_memories
  before insert on memories
  for each row execute function enforce_insert_status_sanction();


-- ══════════════════════════════════════════════════════════════════════════
-- PART 2 (#46) — only 'import'-classified artifacts may become knowledge
-- ══════════════════════════════════════════════════════════════════════════
-- ALLOWLIST, not denylist, and this is the whole point of the rule.
-- raw_artifacts.action is nullable BY DESIGN ("classification is explicit,
-- never defaulted", sql/06). NULL is therefore the default state of every
-- freshly landed artifact. A denylist keyed on hold/exclude/evidence ships
-- looking correct and leaves the single most common case wide open.
--
-- Enforced at INSERT, not at promotion, because #46's requirement is that an
-- evidence artifact cannot NORMALIZE into a memory fact at all — not merely
-- that it cannot later be promoted. A rejected normalization leaves nothing
-- behind to promote.

create or replace function enforce_artifact_promotable()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_action import_action;
begin
  if new.source_artifact_id is null then
    return new;   -- not artifact-derived; other guards apply
  end if;

  select action into v_action from raw_artifacts where id = new.source_artifact_id;

  if v_action is distinct from 'import' then
    raise exception
      '%.% may only derive from a raw_artifact classified action=''import'' (row id: %, artifact: %, artifact action: %). hold, exclude, evidence and unclassified artifacts are preserved and auditable but are not knowledge.',
      tg_table_schema, tg_table_name, new.id, new.source_artifact_id,
      coalesce(v_action::text, 'NULL (unclassified)');
  end if;

  return new;
end; $$;

revoke execute on function enforce_artifact_promotable() from anon, authenticated, public;

drop trigger if exists trg_artifact_promotable_memories on memories;
create trigger trg_artifact_promotable_memories
  before insert or update on memories
  for each row execute function enforce_artifact_promotable();

drop trigger if exists trg_artifact_promotable_wiki on wiki_pages;
create trigger trg_artifact_promotable_wiki
  before insert or update on wiki_pages
  for each row execute function enforce_artifact_promotable();


-- ══════════════════════════════════════════════════════════════════════════
-- PART 3 (#47) — promoted records are immutable in their authority-bearing
--                fields, and content-hash audited
-- ══════════════════════════════════════════════════════════════════════════
-- POLICY DECISION (upstream #47 asked for append-only, content-hash audited,
-- or both; this is both, scoped):
--
--   * A 'proposed' row is a CANDIDATE. Editing it is normal review work and
--     stays unrestricted — that is what the review loop is for.
--   * A 'current' row is a PROMOTED RECORD. Its authority-bearing fields
--     (content, provenance_basis, citation, source_kind, source_agent) become
--     immutable in place. Corrections go through supersede_memory(), which
--     preserves the original and links the replacement.
--   * Operational fields on a current row stay mutable: embedding, embed_*,
--     hot_touched, due_status, metadata, owner, visibility. Marking a deadline
--     done is not a rewrite of what was promoted.
--
-- Full append-only was rejected: it would break legitimate supersession, which
-- is the repo's existing correction discipline and is already attributed.
--
-- The guard PREVENTS in-place rewriting. The audit table DETECTS a rewrite that
-- got past the guard — a superuser with ALTER TABLE ... DISABLE TRIGGER, or a
-- caller who set app.promoting themselves. Prevention and detection are
-- separate layers on purpose, because the guard's own bypass is documented.

create table if not exists promoted_record_audit (
  id             bigint generated always as identity primary key,
  table_name     text not null,
  record_id      uuid not null,
  event          text not null check (event in ('promoted','superseded','rejected')),
  content_sha256 text not null,
  actor          uuid,
  actor_assurance text not null default 'caller_asserted_unauthenticated',
  recorded_at    timestamptz not null default now()
);

create index if not exists promoted_record_audit_lookup_idx
  on promoted_record_audit (table_name, record_id, recorded_at desc);

-- Append-only in the literal sense: the receipt table itself takes no UPDATE
-- and no DELETE. An audit trail that can be edited is not one.
create or replace function forbid_audit_mutation()
returns trigger language plpgsql as $$
begin
  raise exception 'promoted_record_audit is append-only (attempted % )', tg_op;
end; $$;

drop trigger if exists trg_promoted_record_audit_append_only on promoted_record_audit;
create trigger trg_promoted_record_audit_append_only
  before update or delete on promoted_record_audit
  for each row execute function forbid_audit_mutation();

-- The hashed tuple is the authority-bearing content, not just the prose: a
-- silent swap of citation or provenance_basis is the same class of tamper as a
-- silent rewrite of content.
create or replace function memory_authority_hash(p_id uuid)
returns text language sql stable security definer
set search_path = public, extensions as $$
  select encode(digest(
    coalesce(content,'') || '\x1f' ||
    coalesce(provenance_basis::text,'') || '\x1f' ||
    coalesce(citation,'') || '\x1f' ||
    coalesce(source_kind::text,'') || '\x1f' ||
    coalesce(source_agent,''), 'sha256'), 'hex')
  from memories where id = p_id;
$$;

revoke execute on function memory_authority_hash(uuid) from anon, authenticated, public;

create or replace function enforce_promoted_record_immutable()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- Only applies while the row IS promoted. A proposed row is a candidate, and
  -- the supersession transition (current -> superseded) is not a content edit.
  if old.status <> 'current' then return new; end if;
  if new.status is distinct from old.status then return new; end if;

  if new.content          is distinct from old.content
  or new.provenance_basis is distinct from old.provenance_basis
  or new.citation         is distinct from old.citation
  or new.source_kind      is distinct from old.source_kind
  or new.source_agent     is distinct from old.source_agent then
    raise exception
      'a promoted record is immutable in its authority-bearing fields (row id: %). Use supersede_memory() to correct it; that preserves the original and attributes the correction. Editing a proposed candidate is unrestricted -- this row is current.',
      new.id;
  end if;

  return new;
end; $$;

revoke execute on function enforce_promoted_record_immutable() from anon, authenticated, public;

drop trigger if exists trg_promoted_record_immutable_memories on memories;
create trigger trg_promoted_record_immutable_memories
  before update on memories
  for each row execute function enforce_promoted_record_immutable();

-- Detection surface. Mirrors verify_doc_integrity()'s shape deliberately: same
-- vocabulary ('match' / 'mismatch' / no-blessing vs unaudited) so an operator
-- reads both the same way.
--
-- 'unaudited' is expected and honest for every row promoted BEFORE this file
-- was applied. Those rows have no recorded hash, so nothing can be said about
-- them; that is a real gap, not a pass, and it is reported as its own state
-- rather than folded into 'match'.
create or replace function verify_promoted_integrity()
returns table (record_id uuid, state text, audited_sha256 text,
               current_sha256 text, audited_at timestamptz)
language sql stable security definer set search_path = public, extensions as $$
  with latest as (
    select distinct on (a.record_id)
           a.record_id, a.content_sha256, a.recorded_at
    from promoted_record_audit a
    where a.table_name = 'memories' and a.event = 'promoted'
    order by a.record_id, a.recorded_at desc
  )
  select m.id,
         case
           when l.content_sha256 is null then 'unaudited'
           when l.content_sha256 = memory_authority_hash(m.id) then 'match'
           else 'mismatch'
         end,
         l.content_sha256,
         memory_authority_hash(m.id),
         l.recorded_at
  from memories m
  left join latest l on l.record_id = m.id
  where m.status = 'current';
$$;

revoke execute on function verify_promoted_integrity() from anon, authenticated, public;

alter table promoted_record_audit enable row level security;
revoke all on promoted_record_audit from anon, authenticated;


-- ══════════════════════════════════════════════════════════════════════════
-- PART 4 — the sanctioned functions, updated
-- ══════════════════════════════════════════════════════════════════════════

-- promote_memory: unchanged in its checks; now also writes the promotion
-- receipt. The hash is taken AFTER the UPDATE so it records what was actually
-- promoted, not what was proposed.
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

  insert into promoted_record_audit (table_name, record_id, event, content_sha256, actor)
  values ('memories', p_id, 'promoted', memory_authority_hash(p_id), p_promoted_by);

  return 'promoted';
end; $$;

-- supersede_memory: BUG FIX plus the audit receipts.
--
-- THE BUG (found dry-running Part 1, and it would have shipped silently):
-- the previous version set app.promoting = 'off' immediately after the UPDATE
-- of the old row, and only THEN inserted the successor. That successor is
-- inserted at status='current' — so with Part 1's new BEFORE INSERT trigger in
-- place, the successor INSERT falls OUTSIDE the sanction window and legitimate
-- supersession is blocked by the guard meant to stop illegitimate promotion.
--
-- The GUC span is widened to cover the successor INSERT. Note this is the exact
-- inverse of the sql/13 fix, which narrowed the span because SET LOCAL persists
-- to end-of-transaction and was leaving the guard armed for later statements.
-- The span must be as wide as the sanctioned work and no wider; the reset stays
-- inside the exception handler so a failure cannot leave it armed.
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

    -- inside the window: this lands at status='current'
    insert into memories (
      content, workstream, tags, source_kind, source_agent, source_ref,
      provenance_basis, citation, status, supersedes, source_artifact_id,
      effective_from, recorded_at, owner, visibility, metadata
    ) values (
      p_new_content, v_old.workstream, v_old.tags, v_old.source_kind, v_old.source_agent,
      v_old.source_ref, p_new_provenance_basis, p_new_citation, 'current', p_old_id,
      v_old.source_artifact_id, now(), now(), v_old.owner, v_old.visibility,
      v_old.metadata || jsonb_build_object(
        'supersede_reason', p_reason,
        'supersede_actor', p_acting_principal,
        'actor_assurance', 'caller_asserted_unauthenticated')
    ) returning id into v_new_id;

    set local app.promoting = 'off';
  exception when others then
    set local app.promoting = 'off';
    raise;
  end;

  insert into promoted_record_audit (table_name, record_id, event, content_sha256, actor)
  values ('memories', p_old_id, 'superseded', memory_authority_hash(p_old_id), p_acting_principal),
         ('memories', v_new_id, 'promoted',   memory_authority_hash(v_new_id), p_acting_principal);

  return v_new_id;
end; $$;

-- reject_memory: receipt only; its transition is unaffected by Part 1.
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

  insert into promoted_record_audit (table_name, record_id, event, content_sha256, actor)
  values ('memories', p_id, 'rejected', memory_authority_hash(p_id), p_rejected_by);

  return 'rejected';
end; $$;

revoke execute on function promote_memory(uuid, uuid) from anon, authenticated, public;
revoke execute on function reject_memory(uuid, uuid, text) from anon, authenticated, public;
revoke execute on function supersede_memory(uuid, text, provenance_basis, text, uuid, text)
  from anon, authenticated, public;
revoke execute on function forbid_audit_mutation() from anon, authenticated, public;
