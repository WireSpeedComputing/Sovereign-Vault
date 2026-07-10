-- 09_review_queue.sql
-- Sovereign Vault (business) — Phase 1 addition: review queue
--
-- Owner directive: imports run oldest-to-newest, contradictions never
-- overwrite an existing current row, and a confirmation queue is required
-- schema — not an ad hoc pattern left to each import script to invent.
--
-- This is deliberately a real table, not a thin "list of proposed rows"
-- view. A proposed row and a contradiction are different things: a proposed
-- row might simply be unreviewed, with nothing wrong with it. A
-- contradiction means an incoming fact conflicts with something already
-- current, and a human has to decide which version of the truth wins — the
-- import process itself never gets to decide that. The queue exists to hold
-- that decision open until a human closes it, with both sides of the
-- conflict linked so the reviewer doesn't have to go hunting for context.
--
-- incoming_ref / existing_ref are deliberately polymorphic (a plain uuid
-- plus a companion *_kind column) rather than a foreign key, because the
-- incoming side can be a raw artifact mid-import or an already-normalized
-- memory/wiki row, and the existing side can be either a memory or a wiki
-- page. A single foreign key can't point at three different tables; the
-- *_kind column documents which table to look in instead.
--
-- Idempotent. Safe to re-run.

create table review_queue (
  id             uuid primary key default gen_random_uuid(),
  kind           text not null check (kind in (
                   'contradiction', 'stale_state', 'duplicate_suspect',
                   'low_provenance', 'needs_confirmation'
                 )),
  incoming_ref   uuid,
  incoming_kind  text check (incoming_kind in ('raw_artifact', 'memory', 'wiki_page')),
  existing_ref   uuid,
  existing_kind  text check (existing_kind in ('memory', 'wiki_page')),
  detail         text not null,
  raised_by      uuid not null references principals(id),
  resolution     text not null default 'pending' check (resolution in (
                   'pending', 'confirmed', 'rejected', 'superseded_old', 'merged'
                 )),
  resolver       uuid references principals(id),
  resolved_at    timestamptz,
  created_at     timestamptz not null default now()
);

create index on review_queue (resolution) where resolution = 'pending';
create index on review_queue (kind);

alter table review_queue enable row level security;
revoke all on review_queue from anon, authenticated;
