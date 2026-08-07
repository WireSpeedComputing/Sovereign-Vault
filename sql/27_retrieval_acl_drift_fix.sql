-- 27_retrieval_acl_drift_fix.sql
--
-- NOT YET APPLIED to any deployment.
--
-- Fixes ACL drift in the retrieval projection: a memory or wiki page whose
-- `visibility`, `owner` or `workstream` changes after projection keeps serving
-- the OLD access control through retrieval.
--
-- ── WHY A NEW FILE RATHER THAN AN EDIT TO sql/21 ───────────────────────────
-- The instruction was to fix refresh_retrieval_units(), which lives in sql/21.
-- Fixing the function, not the file: every prior correction in this repo lands
-- as a new numbered file doing CREATE OR REPLACE -- sql/13 fixes sql/03 and
-- sql/06, sql/18 fixes sql/12, sql/20 fixes sql/13. Editing sql/21 in place
-- would make the numbered file stop describing the migration that was actually
-- applied under that number, and would leave the owner without a delta to
-- apply to a deployment that already has the old function. This file IS that
-- delta.
--
-- ── THE DEFECT ─────────────────────────────────────────────────────────────
-- retrieval_units carries its own copies of owner / visibility / workstream,
-- and retrieve_context() filters on THOSE copies, not on the source row. The
-- original invalidation predicate compared only two things: is the source still
-- 'current', and does its CONTENT HASH still match. Access control was never
-- compared. So:
--
--   * setting a memory to visibility='private' did not invalidate its unit
--   * it did not update the unit either
--   * and re-running refresh_retrieval_units() did not repair it, because the
--     rescan applied the same hash-only rule
--
-- Verified on a clean PG17 replay of sql/00-26: after the switch to private, a
-- second principal still matched the row, both before AND after a full rescan,
-- with retrieval_units.visibility='shared' against memories.visibility='private'.
--
-- ── SEVERITY ───────────────────────────────────────────────────────────────
-- LATENT, not active, on the deployment. Owner-verified 2026-08-07: zero ACL
-- drift across the live units, because no memory's visibility or owner had ever
-- been changed after projection. Independently reconfirmed here against the
-- deployment before writing this file: 0 drifted of 120 memory-derived live
-- units. The mechanism is real and confirmed; it has never been triggered.
--
-- It goes live the first time anyone marks something private, which is what
-- founder onboarding does. Latency is a deadline, not a mitigation.
--
-- It also compounds with sql/26. Now that a promoted record's content is
-- immutable, the one accident that used to clear a stale unit -- someone
-- editing the text -- can no longer happen. Two individually-correct changes
-- combine into a worse outcome than either alone: without this file the drift
-- would be permanent for an affected row rather than eventually self-healing.

-- ══════════════════════════════════════════════════════════════════════════
-- The corrected rescan
-- ══════════════════════════════════════════════════════════════════════════
-- Three changes from the sql/21 version:
--
--   1. The invalidation predicate compares owner, visibility and workstream
--      alongside status and content hash. A drifted unit is now invalidated and
--      re-projected from the source, which is the repair path for units that
--      are ALREADY stale -- the incremental triggers in pending/C maintain
--      correctness going forward but cannot correct history.
--   2. It reports repaired_acl_drift separately from invalidated, so running it
--      tells you whether drift existed rather than silently absorbing it. A
--      repair that cannot be distinguished from a no-op is not evidence of
--      anything.
--   3. Embeddings attached to invalidated units are marked stale, so a vector
--      never outlives the unit it describes.

-- ⚠ PUBLIC SIGNATURE CHANGE — this is the second live instance of the failure
-- upstream #70 describes, and it is being recorded as such rather than slipped
-- through. refresh_retrieval_units() previously returned
--   (invalidated int, projected_memories int, projected_wiki int)
-- and now returns
--   (invalidated int, repaired_acl_drift int, projected_memories int, projected_wiki int)
--
-- CREATE OR REPLACE cannot widen a return type, so the old function must be
-- DROPPED. Any operating instruction, runbook or client that destructures the
-- 3-column shape is stale as of this migration. The first instance was
-- supersede_memory() losing its 5-argument form in sql/20; that one was dropped
-- rather than left callable for the same reason.
--
-- The alternative -- folding the drift count into `invalidated` to preserve the
-- shape -- was rejected. A repair that cannot be distinguished from a no-op
-- gives an operator no way to answer "was anything actually leaking?", which is
-- the only question this function is being changed to answer.
drop function if exists refresh_retrieval_units();

create function refresh_retrieval_units()
returns table (invalidated int, repaired_acl_drift int,
               projected_memories int, projected_wiki int)
language plpgsql security definer set search_path = public, extensions as $$
declare v_inv int := 0; v_acl int := 0; v_mem int := 0; v_wiki int := 0;
begin
  -- Count ACL drift BEFORE invalidating, so the number reported is the number
  -- that was actually wrong rather than whatever survived the sweep.
  select count(*) into v_acl
  from retrieval_units ru
  where ru.invalidated_at is null
    and (
      exists (select 1 from memories m
              where ru.source_relation = 'memories' and m.id = ru.source_id
                and m.status = 'current'
                and encode(digest(m.content,'sha256'),'hex') = ru.source_content_hash
                and (ru.owner      is distinct from m.owner
                  or ru.visibility is distinct from m.visibility
                  or ru.workstream is distinct from m.workstream))
      or
      exists (select 1 from wiki_pages w
              where ru.source_relation = 'wiki_pages' and w.id = ru.source_id
                and w.status = 'current'
                and encode(digest(w.content,'sha256'),'hex') = ru.source_content_hash
                and (ru.owner      is distinct from w.owner
                  or ru.visibility is distinct from w.visibility
                  or ru.workstream is distinct from w.workstream)));

  -- Invalidate anything whose source is gone, no longer current, whose content
  -- drifted, OR whose access control drifted. The ACL terms are the fix.
  update retrieval_units ru set invalidated_at = now()
  where ru.invalidated_at is null
    and not exists (
      select 1 from memories m
      where ru.source_relation = 'memories' and m.id = ru.source_id
        and m.status = 'current'
        and encode(digest(m.content,'sha256'),'hex') = ru.source_content_hash
        and ru.owner      is not distinct from m.owner
        and ru.visibility is not distinct from m.visibility
        and ru.workstream is not distinct from m.workstream
      union all
      select 1 from wiki_pages w
      where ru.source_relation = 'wiki_pages' and w.id = ru.source_id
        and w.status = 'current'
        and encode(digest(w.content,'sha256'),'hex') = ru.source_content_hash
        and ru.owner      is not distinct from w.owner
        and ru.visibility is not distinct from w.visibility
        and ru.workstream is not distinct from w.workstream
    );
  get diagnostics v_inv = row_count;

  insert into retrieval_units (source_relation, source_id, source_content_hash, unit_kind,
    ordinal, exact_locator, rendered_text, owner, visibility, workstream, record_status,
    effective_from, effective_to, provenance_basis, citation)
  select 'memories', m.id, encode(digest(m.content,'sha256'),'hex'), 'memory_atom',
    0, 'memories:'||m.id, m.content, m.owner, m.visibility, m.workstream, m.status,
    m.effective_from, m.effective_to, m.provenance_basis, m.citation
  from memories m
  where m.status = 'current'
    and not exists (select 1 from retrieval_units ru
      where ru.invalidated_at is null and ru.source_relation='memories'
        and ru.source_id = m.id and ru.ordinal = 0);
  get diagnostics v_mem = row_count;

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
  where w.status = 'current'
    and length(trim(s.section)) > 0
    and not exists (select 1 from retrieval_units ru
      where ru.invalidated_at is null and ru.source_relation='wiki_pages'
        and ru.source_id = w.id and ru.ordinal = s.ord::int);
  get diagnostics v_wiki = row_count;

  -- A vector describes a unit. When the unit dies the vector describes nothing
  -- live, so it must not keep looking current.
  update retrieval_embeddings e set stale_at = now()
  from retrieval_units ru
  where ru.id = e.retrieval_unit_id and e.stale_at is null
    and ru.invalidated_at is not null;

  return query select v_inv, v_acl, v_mem, v_wiki;
end; $$;

revoke execute on function refresh_retrieval_units() from anon, authenticated, public;

-- ══════════════════════════════════════════════════════════════════════════
-- Standing audit surface
-- ══════════════════════════════════════════════════════════════════════════
-- The repair is only trustworthy if drift is observable without running the
-- repair. This reports drift without mutating anything, so it is safe to call
-- from monitoring and safe to call before deciding whether a repair is needed.
create or replace function retrieval_acl_drift()
returns table (unit_id uuid, source_relation text, source_id uuid,
               unit_visibility visibility_level, source_visibility visibility_level,
               unit_owner uuid, source_owner uuid)
language sql stable security definer set search_path = public, extensions as $$
  select ru.id, ru.source_relation, ru.source_id,
         ru.visibility, m.visibility, ru.owner, m.owner
  from retrieval_units ru join memories m on m.id = ru.source_id
  where ru.invalidated_at is null and ru.source_relation = 'memories'
    and (ru.owner      is distinct from m.owner
      or ru.visibility is distinct from m.visibility
      or ru.workstream is distinct from m.workstream)
  union all
  select ru.id, ru.source_relation, ru.source_id,
         ru.visibility, w.visibility, ru.owner, w.owner
  from retrieval_units ru join wiki_pages w on w.id = ru.source_id
  where ru.invalidated_at is null and ru.source_relation = 'wiki_pages'
    and (ru.owner      is distinct from w.owner
      or ru.visibility is distinct from w.visibility
      or ru.workstream is distinct from w.workstream);
$$;

revoke execute on function retrieval_acl_drift() from anon, authenticated, public;

comment on function refresh_retrieval_units() is
  'Full rescan and repair of the retrieval projection. Invalidates units whose source left current, whose content drifted, OR whose owner/visibility/workstream drifted, then re-projects. repaired_acl_drift reports how many units were serving stale access control.';
comment on function retrieval_acl_drift() is
  'Read-only detection of retrieval units serving stale access control. Returns zero rows when the projection agrees with its sources.';
