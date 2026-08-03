-- 22_wiki_pages_source_agent_parity.sql
--
-- Schema asymmetry found while writing the first agent-authored wiki page:
-- memories carries source_agent, wiki_pages did not. So an agent-authored
-- reference document had no field recording WHICH agent wrote it, and
-- attribution had to be smuggled into source_ref as free text.
--
-- That is an attribution hole in exactly the table meant to hold durable
-- reference documents, and it quietly undermines the provenance guarantees the
-- rest of the schema enforces: a page can satisfy every provenance trigger and
-- still not say who produced it.
--
-- Backfills from the source_ref smuggling where the pattern is unambiguous, so
-- no attribution already recorded is lost.

alter table wiki_pages add column source_agent text;

update wiki_pages
set source_agent = split_part(source_ref, ';', 1)
where source_agent is null
  and source_ref is not null
  and source_ref like 'origin-%';

comment on column wiki_pages.source_agent is
  'Which agent surface authored this row. Parity with memories.source_agent; absent it, agent-authored reference documents cannot be attributed.';
