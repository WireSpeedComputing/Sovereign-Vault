-- 38_agent_surface_alias.sql
--
-- MIGRATION: 50_agent_surface_alias_resolution
--
-- Agent attribution resolved to nothing. Fixed by mapping, never by rewriting.
--
-- THE DEFECT. memories.source_agent records surface identifiers of the form
-- '<actor>-<surface>', while principals.agent_label holds short actor names.
-- They never join. Every attributed row resolved to no registered principal, so
-- attribution was free text that looked correct and meant nothing.
--
-- Same class as an identity binding written with a human-readable label instead
-- of the literal issuer URL: an unvalidated string that silently resolves to
-- nothing while every surface signal looks healthy. That one was caught only by
-- forcing a positive result; this one only by joining the two tables and
-- getting zero.
--
-- WHY MAPPING AND NOT RENAMING. Rewriting source_agent would rewrite a recorded
-- custody claim. Those values are what was actually recorded — the record is
-- correct and the registry was incomplete. Under chain-of-custody doctrine the
-- original claim is not editable, and the field locks in the next migration
-- make it structurally impossible. The registry adapts to the evidence, not the
-- reverse. Ordering matters: this had to land BEFORE the locks, because
-- afterwards source_agent cannot be rewritten even to correct it.
--
-- WHY A TABLE AND NOT MORE PRINCIPALS. One actor operates across multiple
-- surfaces or project contexts — two of the observed identifiers are the same
-- reviewer instance in different contexts. Minting a principal per surface
-- would fragment identity and make revocation per-surface rather than
-- per-actor. Many-to-one is the real shape.
--
-- NULL source_agent rows are bulk imports predating the convention. Not
-- backfilled: inventing attribution for records that never carried it would be
-- worse than an honest null.

create table agent_surface_alias (
  id                 uuid primary key default gen_random_uuid(),
  surface_identifier text not null unique,
  principal_id       uuid not null references principals(id),
  surface_note       text,
  status             record_status not null default 'current',
  registered_at      timestamptz not null default now(),
  registered_by      uuid references principals(id),
  citation           text not null
);

alter table agent_surface_alias enable row level security;
revoke all on agent_surface_alias from anon, authenticated;

-- Seed rows are deployment data and are not shipped here. Register the surface
-- identifiers your own deployment has actually recorded, discovered via:
--   select distinct source_agent from memories where source_agent is not null;

-- Returns NULL for an unregistered identifier rather than guessing. An
-- unresolvable attribution must be visible, not silently absorbed.
create or replace function resolve_source_agent(p_source_agent text)
returns uuid language sql stable set search_path = public as $$
  select a.principal_id from agent_surface_alias a
  where a.surface_identifier = p_source_agent and a.status = 'current';
$$;

-- Makes unresolvable attribution observable rather than something discovered
-- later by a join that quietly returns nothing.
create or replace function agent_attribution_coverage()
returns table (source_agent text, rows bigint, resolves boolean, principal text)
language sql stable set search_path = public as $$
  select m.source_agent, count(*),
         resolve_source_agent(m.source_agent) is not null,
         (select display_name from principals where id = resolve_source_agent(m.source_agent))
  from memories m
  where m.source_agent is not null
  group by m.source_agent
  order by count(*) desc;
$$;

revoke execute on function resolve_source_agent(text) from anon, authenticated, public;
revoke execute on function agent_attribution_coverage() from anon, authenticated, public;
