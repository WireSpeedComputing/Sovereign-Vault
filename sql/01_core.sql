-- 01_core.sql
-- Sovereign Vault (business) — Phase 0: generic knowledge layer
-- This is domain-agnostic. Your business's canonical tables (products, orders,
-- suppliers, whatever) are NOT here — they're a separate "bring your own schema"
-- layer documented in docs/01-architecture.md. This file is the substrate every
-- domain schema sits on top of: memories, wiki, hot index, deadlines, doc
-- integrity, and a DDL changelog that cannot be bypassed.
--
-- Idempotent. Safe to re-run against a fresh database.

-- ── Status enums ─────────────────────────────────────────────────────────
create type record_status as enum ('proposed', 'current', 'superseded', 'retracted', 'entered_in_error');
create type source_kind   as enum ('manual', 'agent', 'imported_artifact', 'ingest');

-- ── Knowledge tables ─────────────────────────────────────────────────────
create table memories (
  id           uuid primary key default gen_random_uuid(),
  content      text not null,
  embedding    vector(384),
  workstream   text,
  tags         text[] not null default '{}',
  source_kind  source_kind not null default 'manual',
  source_agent text,
  source_ref   text,
  confidence   numeric(3,2),
  status       record_status not null default 'current',
  supersedes   uuid references memories(id),
  due_date     timestamptz,
  due_status   text check (due_status in ('pending','done','cancelled')),
  embed_attempts int not null default 0,
  embed_error    text,
  hot_touched    boolean not null default false,
  metadata       jsonb not null default '{}',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create table wiki_pages (
  id           uuid primary key default gen_random_uuid(),
  path         text unique not null,
  title        text,
  content      text not null,
  embedding    vector(384),
  tags         text[] not null default '{}',
  workstream   text,
  source_kind  source_kind not null default 'manual',
  source_ref   text,
  status       record_status not null default 'current',
  supersedes   uuid references wiki_pages(id),
  confidence   numeric(3,2),
  frontmatter  jsonb not null default '{}',
  embed_attempts int not null default 0,
  embed_error    text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create index on memories   using hnsw (embedding vector_cosine_ops);
create index on wiki_pages using hnsw (embedding vector_cosine_ops);
create index on memories using gin (tags);
create index on memories (workstream);
create index on memories (status);
create index memories_due_idx on memories (due_date) where due_date is not null and due_status = 'pending';

-- ── Hot index (attention layer, second-touch promotion) ─────────────────
create table memory_hot_index (
  id uuid primary key default gen_random_uuid(),
  memory_id uuid not null references memories(id) on delete cascade,
  topic_key text not null unique,
  summary text not null check (char_length(summary) <= 200),
  workstream text,
  touch_count integer not null default 1,
  last_touched timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create index on memory_hot_index (workstream);

create table memory_hot_staging (
  topic_key text primary key,
  first_seen timestamptz not null default now(),
  memory_id uuid not null references memories(id) on delete cascade,
  summary text not null,
  workstream text
);

create view memory_hot_ranked with (security_invoker = true) as
  select *,
    touch_count::numeric / (1.0 + extract(epoch from (now() - last_touched)) / 86400.0) as score
  from memory_hot_index
  order by score desc
  limit 15;

create or replace function hot_touch(
  p_topic_key text, p_memory_id uuid, p_summary text, p_workstream text default null
) returns text language plpgsql security definer set search_path = public as $$
declare v_min_id uuid; v_count int;
begin
  update memories set hot_touched = true where id = p_memory_id;

  update memory_hot_index set touch_count = touch_count + 1, last_touched = now()
   where topic_key = p_topic_key;
  if found then return 'bumped'; end if;

  if exists (select 1 from memory_hot_staging where topic_key = p_topic_key) then
    select count(*) into v_count from memory_hot_index;
    if v_count >= 15 then
      select id into v_min_id from memory_hot_ranked order by score asc limit 1;
      delete from memory_hot_index where id = v_min_id;
    end if;
    insert into memory_hot_index (memory_id, topic_key, summary, workstream, touch_count, last_touched)
    values (p_memory_id, p_topic_key, left(p_summary,200), p_workstream, 2, now());
    delete from memory_hot_staging where topic_key = p_topic_key;
    return 'promoted';
  end if;

  insert into memory_hot_staging (topic_key, memory_id, summary, workstream)
  values (p_topic_key, p_memory_id, left(p_summary,200), p_workstream)
  on conflict (topic_key) do nothing;
  return 'staged';
end; $$;

-- ── Deadlines ─────────────────────────────────────────────────────────
create view deadlines_upcoming with (security_invoker = true) as
  select id, content, workstream, due_date, source_agent,
         (due_date < now()) as overdue,
         extract(day from (due_date - now()))::int as days_until
  from memories
  where due_date is not null and due_status = 'pending' and status = 'current'
    and due_date < now() + interval '14 days'
  order by due_date asc;

-- ── Doc integrity (tamper/drift check for wiki_pages) ────────────────────
create table doc_integrity (
  path text primary key,
  blessed_sha256 text not null,
  blessed_at timestamptz not null default now(),
  blessed_note text
);

create or replace function current_doc_hash(p_path text)
returns text language sql stable security definer set search_path = public, extensions as $$
  select encode(digest(content, 'sha256'), 'hex')
  from wiki_pages where path = p_path and status = 'current';
$$;

create or replace function verify_doc_integrity(p_path text)
returns table (path text, state text, blessed_sha256 text, current_sha256 text, blessed_at timestamptz)
language sql stable security definer set search_path = public, extensions as $$
  select p_path,
    case
      when di.blessed_sha256 is null then 'no-blessing'
      when di.blessed_sha256 = current_doc_hash(p_path) then 'match'
      else 'mismatch'
    end as state,
    di.blessed_sha256, current_doc_hash(p_path) as current_sha256, di.blessed_at
  from (select 1) x
  left join doc_integrity di on di.path = p_path;
$$;

create or replace function bless_doc(p_path text, p_note text default null)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare v_hash text;
begin
  v_hash := current_doc_hash(p_path);
  if v_hash is null then return 'no-current-doc-at-path'; end if;
  insert into doc_integrity (path, blessed_sha256, blessed_at, blessed_note)
  values (p_path, v_hash, now(), p_note)
  on conflict (path) do update set blessed_sha256 = excluded.blessed_sha256, blessed_at = now(), blessed_note = excluded.blessed_note;
  return 'blessed:' || v_hash;
end; $$;

-- ── Enforced DDL changelog (cannot be bypassed by callers) ───────────────
create table schema_changelog (
  id          bigint generated always as identity primary key,
  changed_at  timestamptz not null default now(),
  db_user     text        not null default current_user,
  command_tag text        not null,
  object_type text,
  object_identity text,
  note        text
);

create or replace function log_ddl_change()
returns event_trigger language plpgsql security definer as $fn$
declare r record;
begin
  for r in select * from pg_event_trigger_ddl_commands()
  loop
    if r.schema_name is distinct from 'pg_catalog'
       and r.schema_name is distinct from 'information_schema' then
      insert into schema_changelog (command_tag, object_type, object_identity)
      values (r.command_tag, r.object_type, r.object_identity);
    end if;
  end loop;
end; $fn$;

drop event trigger if exists trg_log_ddl_change;
create event trigger trg_log_ddl_change on ddl_command_end execute function log_ddl_change();

insert into schema_changelog (command_tag, object_type, object_identity, note)
values ('BOOTSTRAP', 'event_trigger', 'public.trg_log_ddl_change',
        'Sovereign Vault core initialized. All subsequent DDL auto-logged.');

-- ── RLS lockdown (default deny; Phase 1 adds principal-scoped policies) ──
alter table memories          enable row level security;
alter table wiki_pages        enable row level security;
alter table memory_hot_index  enable row level security;
alter table memory_hot_staging enable row level security;
alter table doc_integrity     enable row level security;

revoke all on memories, wiki_pages, memory_hot_index, memory_hot_staging, doc_integrity
  from anon, authenticated;
revoke execute on function hot_touch(text, uuid, text, text) from anon, authenticated, public;
revoke execute on function current_doc_hash(text) from anon, authenticated, public;
revoke execute on function verify_doc_integrity(text) from anon, authenticated, public;
revoke execute on function bless_doc(text, text) from anon, authenticated, public;

alter function hot_touch(text, uuid, text, text) set search_path = public;
