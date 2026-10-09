-- 37_rls_authenticated_select_and_lifecycle.sql
-- MIGRATION: 48_authenticated_select_enables_rls_path
-- MIGRATION: 49_rls_policies_lifecycle_filter
-- SELECT grants let authenticated requests reach the row policies. Negative
-- controls also need a positive visible-row control; permission denial alone
-- cannot prove that an RLS predicate discriminates.
--
-- Canonical reads require current status plus request-derived scope/visibility.
-- Retrieval projections must be live and resolve to a current authorized source.
-- Reviewing proposed records requires a separate capability.

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
