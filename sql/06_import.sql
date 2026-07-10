-- 06_import.sql
-- Sovereign Vault (business) — import framework: preserve-then-normalize
--
-- The pattern: when adopting knowledge from an external system (a memory
-- service, a wiki export, a vendor dump, chat exports), NEVER transform on
-- the way in. Land the raw payload verbatim first, content-hashed, with its
-- source identity intact. Normalize into the knowledge tables as a second,
-- repeatable step that points back at the raw artifact. If normalization is
-- wrong, you re-run it from the preserved raw — you never re-fetch, and you
-- never lose what the source actually said.
--
-- Imported rows land as status='proposed' with provenance_basis =
-- 'imported_artifact' and a citation pointing at the raw artifact. A human
-- (or a human-reviewed flagging pass) promotes to 'current'. Agents cannot
-- promote — that's enforced by 03_provenance.sql already.

-- Classification (adopted from the author's personal-core methodology,
-- docs/07-source-import-cutover.md): every landed artifact gets an explicit
-- action, not a binary normalize/skip. 'evidence' matters most: process
-- records like model-to-model messages, migration logs, and scratchpads are
-- preserved and auditable but must NOT automatically become user memory.
create type import_action as enum ('import', 'hold', 'exclude', 'evidence');
create type import_zone   as enum ('house', 'vault', 'hold', 'evidence');

-- ── Freeze / watermark control ───────────────────────────────────────────
-- Prevent the prior source from changing invisibly during export. Record
-- the source's high-water marks BEFORE export; reconciliation is against
-- these numbers, not against a moving target.
create table source_freeze (
  id            uuid primary key default gen_random_uuid(),
  source_system text not null,
  batch_id      uuid,                    -- FK added after import_batches exists
  freeze_mode   text not null check (freeze_mode in ('hard_freeze','watermark','dual_write','read_only')),
  frozen_at     timestamptz not null default now(),
  actor         uuid,                    -- principal who declared the freeze
  source_count  integer,
  source_max_ts timestamptz,
  source_hash   text,
  notes         text
);

-- ── Batches: one row per import run ─────────────────────────────────────
create table import_batches (
  id            uuid primary key default gen_random_uuid(),
  source_system text not null,          -- e.g. 'mcp-memory-service', 'obsidian-wiki', 'csv-export'
  description   text,
  started_at    timestamptz not null default now(),
  completed_at  timestamptz,
  initiated_by  uuid references principals(id),
  expected_count integer,               -- how many artifacts the source reported
  landed_count   integer,               -- how many actually landed (set at completion)
  notes         text
);

-- ── Raw artifacts: the preserved verbatim payloads ───────────────────────
create table raw_artifacts (
  id            uuid primary key default gen_random_uuid(),
  batch_id      uuid not null references import_batches(id),
  source_system text not null,
  source_id     text not null,          -- the artifact's identity IN THE SOURCE (its hash, path, primary key)
  payload       jsonb not null,         -- the artifact, verbatim, as structured data
  payload_sha256 text not null,         -- hash of the canonical payload text, computed at landing
  fetched_at    timestamptz not null default now(),
  normalized_at timestamptz,            -- set when a normalization pass has consumed this artifact
  action        import_action,          -- null until classified; classification is explicit, never defaulted
  zone          import_zone,
  action_reason text,
  reviewed_by   uuid,
  reviewed_at   timestamptz,
  unique (source_system, source_id)     -- re-running an import cannot double-land an artifact
);

alter table source_freeze add constraint source_freeze_batch_fk
  foreign key (batch_id) references import_batches(id);

create index on raw_artifacts (batch_id);
create index on raw_artifacts (source_system) where normalized_at is null;
create index on raw_artifacts (action) where action is not null;

-- ── Linkage: knowledge rows remember which raw artifact they came from ───
alter table memories   add column source_artifact_id uuid references raw_artifacts(id);
alter table wiki_pages add column source_artifact_id uuid references raw_artifacts(id);

-- ── Promotion: the human gate ────────────────────────────────────────────
-- promote_memory() is how a proposed (typically imported) memory becomes
-- current. It exists so promotion is a deliberate act with an actor
-- recorded, not a casual UPDATE.
create or replace function promote_memory(p_id uuid, p_promoted_by uuid)
returns text language plpgsql security definer set search_path = public as $$
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

  update memories set status = 'current', updated_at = now(),
    metadata = metadata || jsonb_build_object('promoted_by', p_promoted_by, 'promoted_at', now())
  where id = p_id;
  return 'promoted';
end; $$;

revoke execute on function promote_memory(uuid, uuid) from anon, authenticated, public;

-- ── Cutover scorecard ────────────────────────────────────────────────────
-- One view answering: is a given source fully accounted for? A source is
-- ready for sunset when every landed artifact is either normalized or
-- explicitly skipped with a reason, counts reconcile against what the source
-- reported, and nothing proposed from it has been sitting unreviewed.
create view import_cutover_scorecard with (security_invoker = true) as
select
  b.source_system,
  count(distinct b.id)                                        as batches,
  max(b.expected_count)                                       as last_expected,
  count(ra.id)                                                as landed,
  count(ra.id) filter (where ra.action is null)               as unclassified,
  count(ra.id) filter (where ra.action = 'import')            as to_import,
  count(ra.id) filter (where ra.action = 'import'
                         and ra.normalized_at is null)        as import_pending,
  count(ra.id) filter (where ra.action = 'hold')              as held,
  count(ra.id) filter (where ra.action = 'exclude')           as excluded,
  count(ra.id) filter (where ra.action = 'evidence')          as evidence,
  count(m.id)  filter (where m.status = 'proposed')           as still_proposed,
  -- Sunset requires: everything landed, everything classified, every
  -- 'import' normalized, nothing proposed left unreviewed, and holds are
  -- deliberate (held > 0 does NOT block sunset -- holds are an explicit
  -- decision -- but unclassified does).
  (count(ra.id) >= coalesce(max(b.expected_count), 0)
   and count(ra.id) filter (where ra.action is null) = 0
   and count(ra.id) filter (where ra.action = 'import'
                              and ra.normalized_at is null) = 0
   and count(m.id) filter (where m.status = 'proposed') = 0)  as sunset_ready
from import_batches b
left join raw_artifacts ra on ra.batch_id = b.id
left join memories m on m.source_artifact_id = ra.id
group by b.source_system;

-- ── Lockdown ─────────────────────────────────────────────────────────────
alter table import_batches enable row level security;
alter table raw_artifacts  enable row level security;
alter table source_freeze  enable row level security;
revoke all on import_batches, raw_artifacts, source_freeze from anon, authenticated;
alter function promote_memory(uuid, uuid) set search_path = public;
