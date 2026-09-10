-- 37_rls_authenticated_select_and_lifecycle.sql
--
-- MIGRATION: 48_authenticated_select_enables_rls_path
-- MIGRATION: 49_rls_policies_lifecycle_filter
--
-- Two applied migrations, filed together because the second only exists
-- because of what the first made testable.
--
-- ══════════════════════════════════════════════════════════════════════════
-- 48 — the grant that switches the policies on
-- ══════════════════════════════════════════════════════════════════════════
-- RLS filters rows; a table privilege decides whether a role may touch the
-- table at all. `authenticated` had no SELECT, so an authenticated request got
-- "permission denied" and the policies never ran. They were installed, correct,
-- and provably discriminating — and could not serve a row to anyone.
--
-- That also meant any test asserting "an ungranted user sees zero rows" passed
-- TRIVIALLY, for the wrong reason. A negative result proves nothing when the
-- request never reached the thing being tested.
--
-- Applied only after confirming the blast radius: exactly two auth users
-- existed, both disposable test accounts, neither holding any capability grant;
-- the other human principals had no auth account at all and could not reach the
-- path. SELECT only — writes continue through the sanctioned definer functions,
-- and a write privilege here would create a second write path.
--
-- ══════════════════════════════════════════════════════════════════════════
-- 49 — the defect that grant exposed
-- ══════════════════════════════════════════════════════════════════════════
-- With a real JWT and a grant on exactly one scope, the policies returned 35
-- rows where governed retrieval returned 31. The difference was 12 rows at
-- status='proposed'.
--
-- The policies gated scope and visibility but not LIFECYCLE:
--   * 'proposed' means NOT YET ACCEPTED AS TRUE — the holding state for
--     imported candidates and agent claims awaiting human promotion. Serving it
--     through the same door as accepted fact defeats the promotion model.
--   * 'entered_in_error' is explicitly REJECTED content — wrong-domain imports,
--     personal material, obsolete directives. None was in scope that day, so
--     nothing leaked, but the policy would have served it.
--   * 'superseded' is corrected truth, readable as though current.
--
-- The deeper problem was DIVERGENCE BETWEEN ACCESS PATHS. retrieve_context
-- filtered to current; the table policy did not. Same principal, same grant,
-- different answers depending on which door was used — and a consuming model
-- cannot tell which it is holding. The governance layer exhibiting the exact
-- defect class it exists to prevent.
--
-- HOW IT WAS FOUND, because the method matters more than the fix: the expected
-- counts were stated BEFORE the run. 35 rows of correctly-scoped data looks
-- like success; committing to 23 beforehand turned a plausible result into a
-- failed assertion. Third finding from that technique in one day.
--
-- Review access for candidates is deliberately NOT added here. A human
-- reviewing proposed records is a real need and a DIFFERENT capability than
-- read. Conflating them is how this defect happened.

grant select on public.memories        to authenticated;
grant select on public.wiki_pages      to authenticated;
grant select on public.retrieval_units to authenticated;

drop policy if exists memories_read on public.memories;
create policy memories_read on public.memories
  for select to authenticated
  using (status = 'current'
     and public.can_read_row_as_request(owner, visibility, workstream));

drop policy if exists wiki_pages_read on public.wiki_pages;
create policy wiki_pages_read on public.wiki_pages
  for select to authenticated
  using (status = 'current'
     and public.can_read_row_as_request(owner, visibility, workstream));

-- Still resolves to the SOURCE row rather than trusting the projection's own
-- copies, and now also requires the unit itself to be live: an invalidated unit
-- describes a row that is no longer projected and must not be served.
drop policy if exists retrieval_units_read on public.retrieval_units;
create policy retrieval_units_read on public.retrieval_units
  for select to authenticated
  using (
    invalidated_at is null
    and record_status = 'current'
    and case source_relation
      when 'memories' then exists (
        select 1 from public.memories m
        where m.id = retrieval_units.source_id
          and m.status = 'current'
          and public.can_read_row_as_request(m.owner, m.visibility, m.workstream))
      when 'wiki_pages' then exists (
        select 1 from public.wiki_pages w
        where w.id = retrieval_units.source_id
          and w.status = 'current'
          and public.can_read_row_as_request(w.owner, w.visibility, w.workstream))
      else false
    end
  );

-- Verified through a real JWT over PostgREST after applying: zero grants -> []
-- with HTTP 200; one scope granted -> 23 memories, 1 wiki page, 31 units, all
-- in scope, none of the 84 unclassified rows; revoked -> denied.
