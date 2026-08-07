-- PENDING OWNER APPROVAL — NOT APPLIED
--
-- Incremental maintenance of the retrieval projection.
--
-- ── THE PROBLEM ────────────────────────────────────────────────────────────
-- `retrieval_units` is a derived projection built by refresh_retrieval_units(),
-- which is a full rescan invoked by hand. Nothing calls it automatically. Six
-- memories written by other sessions were invisible to retrieve_context() until
-- someone ran the refresh manually — the rows existed, were current, and were
-- simply not in the projection.
--
-- That failure is silent by construction. retrieve_context() reports
-- units_visible and units_matched honestly, but it can only report on units that
-- exist; a memory that was never projected is indistinguishable from one that
-- does not exist. The envelope's whole purpose is to make "nothing found"
-- distinguishable from "nothing searched", and an unmaintained projection
-- defeats it one layer down.
--
-- pg_cron is not installed, so a schedule is not available. A full rescan on
-- every write is also not acceptable. This maintains the projection per-row.
--
-- ── A DISCLOSURE DEFECT FOUND WHILE BUILDING THIS ──────────────────────────
-- refresh_retrieval_units() invalidates a live unit only when its source stops
-- being 'current' or its CONTENT HASH drifts. It never compares owner,
-- visibility or workstream. So changing a memory from visibility='shared' to
-- 'private' does not invalidate its projected unit and does not update it — the
-- unit keeps visibility='shared', and retrieve_context() filters on the UNIT's
-- copy of that column, not the source row's.
--
-- VERIFIED on a clean PG17 replay of sql/00-25, using only sql/21's own
-- documented maintenance path:
--
--   shared, after refresh          -> H2 matches the row        (expected)
--   set visibility='private'       -> H2 STILL matches the row  (leak)
--   run refresh_retrieval_units()  -> H2 STILL matches the row  (rescan does
--                                     not fix it)
--   retrieval_units.visibility = 'shared' while memories.visibility = 'private'
--
-- The full rescan does not repair it because the rescan has the same hash-only
-- invalidation rule. There is currently NO operation that closes this except
-- editing the memory's text.
--
-- This is live on the deployment now and is independent of this file. It also
-- interacts badly with sql/25: now that a promoted record's content is
-- immutable, the one accident that used to clear a stale unit -- someone
-- editing the text -- can no longer happen, so the leak is permanent for the
-- affected row rather than eventually self-healing.
--
-- This file fixes it for rows that change AFTER it is applied, by syncing the
-- metadata columns explicitly. It does NOT retroactively correct units that are
-- already stale; run refresh_retrieval_units() first and see the closing note.
-- Flagged in STATUS.md as its own defect and needing an owner decision.
--
-- ── SCOPE ──────────────────────────────────────────────────────────────────
-- Per-row, not a rescan: each trigger call touches only the units belonging to
-- the row that changed. Incremental maintenance corrects nothing retroactively —
-- run refresh_retrieval_units() ONCE before applying this, or the triggers will
-- faithfully maintain a projection that was already stale.

create or replace function sync_retrieval_units(p_relation text, p_id uuid)
returns void language plpgsql security definer
set search_path = public, extensions as $fn$
begin
  if p_relation = 'memories' then

    -- 1. invalidate live units whose source is gone, no longer current, or drifted
    update retrieval_units ru set invalidated_at = now()
    where ru.invalidated_at is null
      and ru.source_relation = 'memories' and ru.source_id = p_id
      and not exists (
        select 1 from memories m
        where m.id = p_id and m.status = 'current'
          and encode(digest(m.content,'sha256'),'hex') = ru.source_content_hash);

    -- 2. sync metadata on units that survived. This is the leak fix: these
    --    columns can change without the content hash changing, and
    --    retrieve_context() filters on the UNIT's copy of them.
    update retrieval_units ru set
      owner = m.owner, visibility = m.visibility, workstream = m.workstream,
      record_status = m.status, effective_from = m.effective_from,
      effective_to = m.effective_to, provenance_basis = m.provenance_basis,
      citation = m.citation
    from memories m
    where m.id = p_id
      and ru.source_relation = 'memories' and ru.source_id = p_id
      and ru.invalidated_at is null
      and (ru.owner            is distinct from m.owner
        or ru.visibility       is distinct from m.visibility
        or ru.workstream       is distinct from m.workstream
        or ru.record_status    is distinct from m.status
        or ru.effective_from   is distinct from m.effective_from
        or ru.effective_to     is distinct from m.effective_to
        or ru.provenance_basis is distinct from m.provenance_basis
        or ru.citation         is distinct from m.citation);

    -- 3. project the row if it is current and has no live unit
    insert into retrieval_units (source_relation, source_id, source_content_hash, unit_kind,
      ordinal, exact_locator, rendered_text, owner, visibility, workstream, record_status,
      effective_from, effective_to, provenance_basis, citation)
    select 'memories', m.id, encode(digest(m.content,'sha256'),'hex'), 'memory_atom',
      0, 'memories:'||m.id, m.content, m.owner, m.visibility, m.workstream, m.status,
      m.effective_from, m.effective_to, m.provenance_basis, m.citation
    from memories m
    where m.id = p_id and m.status = 'current'
      and not exists (select 1 from retrieval_units ru
        where ru.invalidated_at is null and ru.source_relation = 'memories'
          and ru.source_id = m.id and ru.ordinal = 0);

  elsif p_relation = 'wiki_pages' then

    -- A wiki page splits into N sections and N can change, so a changed page
    -- invalidates all of its live units and re-projects. Still per-row: the
    -- blast radius is one page, not the table.
    update retrieval_units ru set invalidated_at = now()
    where ru.invalidated_at is null
      and ru.source_relation = 'wiki_pages' and ru.source_id = p_id
      and not exists (
        select 1 from wiki_pages w
        where w.id = p_id and w.status = 'current'
          and encode(digest(w.content,'sha256'),'hex') = ru.source_content_hash);

    update retrieval_units ru set
      owner = w.owner, visibility = w.visibility, workstream = w.workstream,
      record_status = w.status, effective_from = w.effective_from,
      effective_to = w.effective_to, provenance_basis = w.provenance_basis,
      citation = w.citation
    from wiki_pages w
    where w.id = p_id
      and ru.source_relation = 'wiki_pages' and ru.source_id = p_id
      and ru.invalidated_at is null
      and (ru.owner            is distinct from w.owner
        or ru.visibility       is distinct from w.visibility
        or ru.workstream       is distinct from w.workstream
        or ru.record_status    is distinct from w.status
        or ru.effective_from   is distinct from w.effective_from
        or ru.effective_to     is distinct from w.effective_to
        or ru.provenance_basis is distinct from w.provenance_basis
        or ru.citation         is distinct from w.citation);

    insert into retrieval_units (source_relation, source_id, source_content_hash, unit_kind,
      ordinal, exact_locator, rendered_text, owner, visibility, workstream, record_status,
      effective_from, effective_to, provenance_basis, citation)
    select 'wiki_pages', w.id, encode(digest(w.content,'sha256'),'hex'), 'wiki_section',
      s.ord::int, 'wiki:'||w.path||'#'||s.ord, s.section, w.owner, w.visibility,
      w.workstream, w.status, w.effective_from, w.effective_to, w.provenance_basis, w.citation
    from wiki_pages w
    cross join lateral (
      select section, row_number() over () as ord
      from regexp_split_to_table(w.content, E'\n(?=#{1,6}[[:space:]])') as section
    ) s
    where w.id = p_id and w.status = 'current'
      and length(trim(s.section)) > 0
      and not exists (select 1 from retrieval_units ru
        where ru.invalidated_at is null and ru.source_relation = 'wiki_pages'
          and ru.source_id = w.id and ru.ordinal = s.ord::int);
  end if;

  -- An embedding belongs to a unit. When the unit is invalidated the vector no
  -- longer describes anything live, so mark it stale rather than leaving a row
  -- that looks current. retrieve_context() already joins live units only, so
  -- this is hygiene and honest reporting, not a correctness fix.
  update retrieval_embeddings e set stale_at = now()
  from retrieval_units ru
  where ru.id = e.retrieval_unit_id and e.stale_at is null
    and ru.invalidated_at is not null
    and ru.source_relation = p_relation and ru.source_id = p_id;
end; $fn$;

revoke execute on function sync_retrieval_units(text, uuid) from anon, authenticated, public;

create or replace function trg_sync_retrieval()
returns trigger language plpgsql security definer set search_path = public as $fn$
begin
  if tg_op = 'DELETE' then
    perform sync_retrieval_units(tg_table_name, old.id);
    return old;
  end if;
  perform sync_retrieval_units(tg_table_name, new.id);
  return new;
end; $fn$;

revoke execute on function trg_sync_retrieval() from anon, authenticated, public;

-- AFTER, not BEFORE: the projection must reflect the committed row, and
-- sync_retrieval_units re-reads the source table rather than trusting NEW.
--
-- The UPDATE trigger carries a WHEN clause so ordinary operational writes --
-- embedding backfill, hot_touch, due_status -- do not re-run the projection.
-- Without it every embedding write would re-sync, which is the rescan cost this
-- file exists to avoid, just spread out.

drop trigger if exists trg_sync_retrieval_memories_ins on memories;
create trigger trg_sync_retrieval_memories_ins
  after insert on memories for each row
  when (new.status = 'current')
  execute function trg_sync_retrieval();

drop trigger if exists trg_sync_retrieval_memories_upd on memories;
create trigger trg_sync_retrieval_memories_upd
  after update on memories for each row
  when (old.status           is distinct from new.status
     or old.content          is distinct from new.content
     or old.owner            is distinct from new.owner
     or old.visibility       is distinct from new.visibility
     or old.workstream       is distinct from new.workstream
     or old.provenance_basis is distinct from new.provenance_basis
     or old.citation         is distinct from new.citation
     or old.effective_from   is distinct from new.effective_from
     or old.effective_to     is distinct from new.effective_to)
  execute function trg_sync_retrieval();

drop trigger if exists trg_sync_retrieval_memories_del on memories;
create trigger trg_sync_retrieval_memories_del
  after delete on memories for each row
  execute function trg_sync_retrieval();

drop trigger if exists trg_sync_retrieval_wiki_ins on wiki_pages;
create trigger trg_sync_retrieval_wiki_ins
  after insert on wiki_pages for each row
  when (new.status = 'current')
  execute function trg_sync_retrieval();

drop trigger if exists trg_sync_retrieval_wiki_upd on wiki_pages;
create trigger trg_sync_retrieval_wiki_upd
  after update on wiki_pages for each row
  when (old.status           is distinct from new.status
     or old.content          is distinct from new.content
     or old.owner            is distinct from new.owner
     or old.visibility       is distinct from new.visibility
     or old.workstream       is distinct from new.workstream
     or old.provenance_basis is distinct from new.provenance_basis
     or old.citation         is distinct from new.citation
     or old.effective_from   is distinct from new.effective_from
     or old.effective_to     is distinct from new.effective_to)
  execute function trg_sync_retrieval();

drop trigger if exists trg_sync_retrieval_wiki_del on wiki_pages;
create trigger trg_sync_retrieval_wiki_del
  after delete on wiki_pages for each row
  execute function trg_sync_retrieval();

-- refresh_retrieval_units() is deliberately KEPT. It is the repair tool for a
-- projection that drifted while these triggers were absent, disabled, or being
-- applied, and it is how a chunking change is rolled out across every row. The
-- triggers keep it from being load-bearing; they do not replace it.
--
-- NOT ADDRESSED HERE: refresh_retrieval_units() has the same metadata-blind
-- invalidation rule described in the header, so a full rescan still will not
-- correct a stale visibility. Fixing the rescan is a change to sql/21 and
-- belongs with the owner's decision on that file, not folded in here.
