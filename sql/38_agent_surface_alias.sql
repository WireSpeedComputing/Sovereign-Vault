-- 38_agent_surface_alias.sql
-- MIGRATION: 50_agent_surface_alias_resolution
-- Resolve recorded surface identifiers to reviewed principals through an
-- explicit many-to-one registry. Preserve original source_agent custody values;
-- missing attribution must not be fabricated through a backfill.
-- Alias rows, actual actors and review context remain private deployment data.

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
