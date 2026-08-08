-- 34_hard_delete_guard.sql
--
-- MIGRATION: 52_hard_delete_guard
--
-- APPLIED 2026-08-08. Verified live: unarmed DELETE blocked, armed override
-- succeeds and writes a receipt, row removed. Closes a hole demonstrated in
-- the same session -- a plain DELETE on memories succeeded beforehand.
--
-- ***** NOT YET APPLIED to any deployment. *****
-- Declares no `-- MIGRATION:` header on purpose; tests/migration_drift.sh reads
-- that absence as "not yet applied".
--
-- ADOPT: sibling protocol repo sovereign-memory-core, `guard_hard_delete()`
-- (its sql/01_core.sql lines 361-375).
--
-- ── SOURCING NOTE ──────────────────────────────────────────────────────────
-- The work order cited upstream issue #5. Upstream #5 is CLOSED with the body
-- "This work is tracked privately" and states no requirements. Written against
-- the sibling's shipped guard instead. Flagged, not hidden.
--
-- ── THE DIFF, AND IT IS A HOLE ─────────────────────────────────────────────
-- This repo has an elaborate supersede-not-delete discipline:
--   * record_status carries 'superseded', 'retracted' and 'entered_in_error' —
--     three distinct ways to say "this is no longer authoritative" WITHOUT
--     destroying it (sql/01 line 12).
--   * sql/26 makes 'current' unreachable by direct INSERT and makes a promoted
--     row's authority-bearing fields immutable in place, with the error message
--     "Use supersede_memory() to correct it; that preserves the original and
--     attributes the correction."
--   * sql/20 adds actor custody to those transitions.
--   * promoted_record_audit is append-only, enforced by trigger, because "an
--     audit trail that can be edited is not one" (sql/26 line 183).
--
-- And then:
--
--   $ grep -rniE 'before delete|hard.delete|allow_delete' sql/ tests/ docs/
--   (no output)
--
-- Every one of those controls is on INSERT or UPDATE. A bare
-- `DELETE FROM memories WHERE id = ...` walks past all of them, destroys the
-- row, and leaves nothing behind — no receipt, no superseded predecessor, not
-- even a row in schema_changelog, which is an EVENT TRIGGER on
-- ddl_command_end and therefore never fires for DML.
--
-- The immutability guard in sql/26 is strictly weaker than it reads: a caller
-- who cannot rewrite a promoted record's content CAN delete it and insert a
-- replacement. verify_promoted_integrity() cannot detect that, because it is a
-- LEFT JOIN from `memories` — it reports on rows that exist. A deleted row is
-- reported by nothing at all. Deletion is the one mutation that erases its own
-- evidence.
--
-- ── DECISION: ADOPT ────────────────────────────────────────────────────────
-- Adopted, with a receipt table the sibling does not have. The sibling logs into
-- its general-purpose `audit_log`; this repo has no such table, and folding
-- delete receipts into promoted_record_audit would mean widening that table's
-- `event` CHECK constraint — modifying sql/26's object from a later file to
-- store a different kind of fact. A dedicated append-only table is cleaner and
-- keeps sql/26 untouched.
--
-- ── WHAT IS COVERED, AND WHAT IS DELIBERATELY NOT ──────────────────────────
-- COVERED: memories, wiki_pages. The custody substrate. Same two tables the
-- sibling covers.
--
-- NOT COVERED, and each omission is load-bearing rather than an oversight — a
-- guard that closed these would have broken the system, not secured it:
--
--   retrieval_units / retrieval_embeddings
--       sql/21's header calls these "DISPOSABLE DERIVED PROJECTIONS, rebuildable
--       at any time". Deleting and rebuilding them is the DESIGNED maintenance
--       path, and refresh_retrieval_units() exists to do exactly that. Guarding
--       them would break the repo's own embedding-model migration story.
--   memory_hot_staging
--       hot_touch() (sql/01 line 112, retained through sql/15) deletes the
--       staging row as the normal promote-from-staging step. Guarding it breaks
--       the attention layer on its happy path.
--   memory_hot_index
--       sql/15 removed destructive eviction from the write path already; the
--       cap now lives in the view. Nothing routinely deletes here, but it is a
--       derived attention index, not a record of fact.
--   review_queue, capability_grants, principals
--       Out of scope for a memory-custody delete guard, and capability_grants
--       already has its own audit trigger covering DELETE (sql/02 lines 117-119).
--
-- ── THE LIMIT, STATED PLAINLY ──────────────────────────────────────────────
-- `app.allow_delete` is a session GUC. Any caller holding service_role can arm
-- it and delete freely. This closes the ACCIDENTAL path — the stray DELETE, the
-- migration script with a bad WHERE clause, the agent that "cleans up" — not the
-- deliberate one. It is accident-prevention plus an audit surface, not
-- authentication. Exactly the same limit, in the same words, that sql/13, sql/20
-- and sql/26 already record for `app.promoting`, and it is asserted as a
-- DOCUMENTED LIMIT in tests/34 Section D so it appears in test output rather
-- than only in prose.
--
-- A superuser can additionally `ALTER TABLE ... DISABLE TRIGGER`. The receipt
-- table is the detection layer for that; prevention and detection are separate
-- on purpose, as in sql/26.

-- ══════════════════════════════════════════════════════════════════════════
-- PART 1 — the receipt table, append-only
-- ══════════════════════════════════════════════════════════════════════════
-- Written BEFORE the row goes, capturing enough to know what was destroyed:
-- the authority-bearing hash, the status it held, and its owner. Not the
-- content — a receipt table that stores the full text of every deleted row is a
-- second copy of the data with none of the visibility controls, which is how a
-- "safety" feature becomes the leak.

create table if not exists public.hard_delete_audit (
  id              bigint generated always as identity primary key,
  table_name      text not null,
  record_id       uuid not null,
  record_status   text,
  record_owner    uuid,
  content_sha256  text,
  db_user         text not null default current_user,
  actor_assurance text not null default 'caller_asserted_unauthenticated',
  deleted_at      timestamptz not null default now()
);

create index if not exists hard_delete_audit_lookup_idx
  on public.hard_delete_audit (table_name, record_id, deleted_at desc);

comment on table public.hard_delete_audit is
  'Receipts for hard deletes that were performed under the app.allow_delete override. Append-only. A row here means a record was destroyed rather than superseded; the content is deliberately NOT stored, only its hash.';

-- Append-only in the literal sense: the receipt table takes no UPDATE and no
-- DELETE. An audit trail that can be edited is not one (sql/26 line ~183).
--
-- NOT reused from sql/26. The first version of this file did attach sql/26's
-- forbid_audit_mutation() here, and the tests went green while the operator
-- experience was wrong: that function hardcodes the string
-- 'promoted_record_audit' in its message, so touching hard_delete_audit raised
-- "promoted_record_audit is append-only". An error naming a table the caller
-- never touched sends them to the wrong file. Caught by reading the SQLERRM in
-- the test's detail column, which is why these files print it. Two lines of
-- duplication is cheaper than a misleading error.
create or replace function public.forbid_hard_delete_audit_mutation()
returns trigger language plpgsql as $$
begin
  raise exception '%.% is append-only (attempted %)',
    tg_table_schema, tg_table_name, tg_op;
end; $$;

revoke all on function public.forbid_hard_delete_audit_mutation() from public, anon, authenticated;

drop trigger if exists trg_hard_delete_audit_append_only on public.hard_delete_audit;
create trigger trg_hard_delete_audit_append_only
  before update or delete on public.hard_delete_audit
  for each row execute function public.forbid_hard_delete_audit_mutation();

alter table public.hard_delete_audit enable row level security;
revoke all on public.hard_delete_audit from anon, authenticated;

-- ══════════════════════════════════════════════════════════════════════════
-- PART 2 — the guard
-- ══════════════════════════════════════════════════════════════════════════

create or replace function public.guard_hard_delete()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_hash text;
begin
  -- coalesce(current_setting(...,true),'off') <> 'on' is the fail-closed form:
  -- current_setting with missing_ok returns NULL when the GUC was never set, and
  -- `NULL <> 'on'` is NULL, which an IF would NOT fire on -- the guard would
  -- silently pass on precisely the fresh session it most needs to stop. The
  -- coalesce is what makes this total. Same three-valued-logic trap documented
  -- at length in sql/31_is_owner_or_shared_total_function.sql.
  if coalesce(current_setting('app.allow_delete', true), 'off') <> 'on' then
    raise exception
      'hard DELETE is blocked on %.% (row id: %). This repo supersedes rather than deletes: use supersede_memory() to correct a record, or set status to ''retracted'' or ''entered_in_error'' to withdraw it -- both preserve the row and its attribution. Administrative override, inside a transaction: SET LOCAL app.allow_delete = ''on'';',
      tg_table_schema, tg_table_name, old.id;
  end if;

  -- Override armed: allow it, but leave a receipt. memory_authority_hash()
  -- (sql/26) reads from `memories` by id and is useless here -- the row is about
  -- to be deleted but, being a BEFORE trigger, still exists, so it would work
  -- for memories and return NULL for wiki_pages. Hashing OLD directly is
  -- table-agnostic and does not depend on the row still being visible.
  v_hash := encode(digest(
              coalesce(old.content, '')       || E'\x1f' ||
              coalesce(old.source_kind::text, '') || E'\x1f' ||
              coalesce(old.source_agent, ''),  'sha256'), 'hex');

  insert into public.hard_delete_audit
    (table_name, record_id, record_status, record_owner, content_sha256)
  values
    (tg_table_name, old.id, old.status::text, old.owner, v_hash);

  return old;
end; $$;

comment on function public.guard_hard_delete() is
  'Blocks hard DELETE unless app.allow_delete is armed, and writes a receipt when it is. Closes the ACCIDENTAL delete path only -- a service_role caller can arm the GUC itself, exactly as documented for app.promoting in sql/13, sql/20 and sql/26.';

revoke all on function public.guard_hard_delete() from public, anon, authenticated;

drop trigger if exists trg_guard_hard_delete_memories on public.memories;
create trigger trg_guard_hard_delete_memories
  before delete on public.memories
  for each row execute function public.guard_hard_delete();

drop trigger if exists trg_guard_hard_delete_wiki on public.wiki_pages;
create trigger trg_guard_hard_delete_wiki
  before delete on public.wiki_pages
  for each row execute function public.guard_hard_delete();
