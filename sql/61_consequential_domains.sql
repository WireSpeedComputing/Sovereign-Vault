-- 61_consequential_domains.sql
-- MIGRATION: 56_consequential_domains
-- Optional declared consequential-domain reference module for upstream #44.
-- Resolve table declarations, reviewed workstream bindings and row assertions
-- with explicit precedence. Domain policy can tighten provenance and permitted
-- authorship; absence of a binding must not be represented as evaluated coverage.
-- The baseline domains and evidence rules are reference policy, not an adopter
-- inventory, operating report or universal business taxonomy.
-- Keep customer bindings, classifications and approvals private.

create type consequential_domain as enum ('financial', 'legal', 'medical', 'identity');

create table consequential_domain_policy (
  domain            consequential_domain primary key,
  allowed_basis     provenance_basis[] not null check (cardinality(allowed_basis) > 0),
  citation_required boolean not null default true,
  agent_authorship  text not null check (agent_authorship in ('proposal_only', 'forbidden')),
  rationale         text not null,
  declared_at       timestamptz not null default now(),
  declared_by       uuid references principals(id)
);

insert into consequential_domain_policy (domain, allowed_basis, citation_required, agent_authorship, rationale) values
 ('financial',
  array['decision_record','imported_artifact','source_document']::provenance_basis[],
  true, 'proposal_only',
  'A stated figure requires a checkable source. Financial facts trace to an invoice, an export, or an authorized recorded decision. Agents may propose and an authorized human promotes.'),
 ('legal',
  array['imported_artifact','source_document']::provenance_basis[],
  true, 'proposal_only',
  'A legal fact is what an instrument says, so its basis is the instrument. decision_record is excluded deliberately: a decision to treat a clause a certain way is not the clause, and conflating them is how an internal interpretation becomes cited as the contract.'),
 ('medical',
  array['imported_artifact','source_document']::provenance_basis[],
  true, 'proposal_only',
  'Same instrument rule as legal, for the same reason. Agent authorship is proposal_only rather than forbidden on purpose: summarizing a clinical document into a proposal is legitimate and useful work, and the human promotion gate is where it is checked. Forbidding it outright would push that work outside the vault, where nothing is enforced at all.'),
 ('identity',
  array['human_direct','source_document']::provenance_basis[],
  true, 'forbidden',
  'Identity is the substrate authorization keys on (sql/23 resolves capabilities through principal identity). An agent authoring a claim about who someone is can influence what it is itself permitted to do, so the loop is cut rather than reviewed. human_direct is re-admitted here, unlike the other three, because a person stating who they are IS the primary source for that fact -- and citation_required still applies, so the statement must say where it was made.');

-- Domain a table is wholly within. NULL means the table spans domains and
-- classification happens per row. NULL for memories and wiki_pages, forever:
-- see decision 1.
alter table provenance_registry
  add column table_domain consequential_domain
    references consequential_domain_policy(domain);

comment on column provenance_registry.table_domain is
  'Set only for tables where every row is in one domain (a domain module''s own tables). NULL for the generic knowledge tables, which classify per row.';

-- Schema-owner-declared workstream bindings. Empty at install: which
-- workstreams are consequential is a deployment fact, not a repo fact. The
-- table existing and being empty is the honest state, and Section D of the
-- test file asserts what that emptiness costs.
create table consequential_domain_binding (
  table_name  text not null references provenance_registry(table_name) on delete cascade,
  workstream  text not null check (workstream !~ '^\s*$'),
  domain      consequential_domain not null references consequential_domain_policy(domain),
  declared_at timestamptz not null default now(),
  declared_by uuid references principals(id),
  primary key (table_name, workstream)
);

-- ══════════════════════════════════════════════════════════════════════════
-- PART 2 — the row columns
-- ══════════════════════════════════════════════════════════════════════════
-- Nullable, and null is NOT "unclassified pending review" -- it is "no domain
-- claim was made or derived". The distinction matters: sql/06 makes the
-- opposite choice for raw_artifacts.action, where null means explicitly
-- unclassified and is therefore denied by an allowlist. Here null means the
-- baseline applies, because holding every general-knowledge memory to the
-- medical bar would make the vault unusable and the bar would be removed
-- within a week. A guard that gets switched off is worth less than a narrower
-- guard that stays on.

alter table memories   add column consequential_domain consequential_domain;
alter table wiki_pages add column consequential_domain consequential_domain;

create index memories_consequential_domain_idx
  on memories (consequential_domain) where consequential_domain is not null;
create index wiki_pages_consequential_domain_idx
  on wiki_pages (consequential_domain) where consequential_domain is not null;

-- ══════════════════════════════════════════════════════════════════════════
-- PART 3 — resolution
-- ══════════════════════════════════════════════════════════════════════════

create or replace function resolve_consequential_domain(
  p_table_name text,
  p_workstream text,
  p_declared   consequential_domain
) returns consequential_domain
language plpgsql stable security definer set search_path = public as $$
declare
  v_table_domain consequential_domain;
  v_bound        consequential_domain;
begin
  select table_domain into v_table_domain
  from provenance_registry where table_name = p_table_name;

  if v_table_domain is not null then
    if p_declared is not null and p_declared <> v_table_domain then
      raise exception
        'consequential domain conflict on %: the table is declared wholly % but the row declares % (provenance_registry.table_domain wins; the row must declare % or nothing)',
        p_table_name, v_table_domain, p_declared, v_table_domain;
    end if;
    return v_table_domain;
  end if;

  if p_workstream is not null then
    select domain into v_bound
    from consequential_domain_binding
    where table_name = p_table_name and workstream = p_workstream;
  end if;

  if v_bound is not null then
    if p_declared is not null and p_declared <> v_bound then
      raise exception
        'consequential domain conflict on %: workstream "%" is bound to domain % but the row declares % (the binding wins; the row must declare % or nothing)',
        p_table_name, p_workstream, v_bound, p_declared, v_bound;
    end if;
    return v_bound;
  end if;

  return p_declared;
end; $$;

revoke execute on function resolve_consequential_domain(text, text, consequential_domain)
  from anon, authenticated, public;

-- ══════════════════════════════════════════════════════════════════════════
-- PART 4 — enforcement
-- ══════════════════════════════════════════════════════════════════════════

create or replace function enforce_consequential_domain()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_domain     consequential_domain;
  v_old_domain consequential_domain;
  v_pol        consequential_domain_policy%rowtype;
begin
  v_domain := resolve_consequential_domain(tg_table_name, new.workstream, new.consequential_domain);

  -- Ratchet (decision 5): a resolved classification may be added, never
  -- changed and never removed.
  if tg_op = 'UPDATE' then
    v_old_domain := resolve_consequential_domain(tg_table_name, old.workstream, old.consequential_domain);
    if v_old_domain is not null and v_domain is distinct from v_old_domain then
      raise exception
        'consequential domain is not editable once set on %.% (row id: %, % -> %). Reclassification is a supersession, not an edit.',
        tg_table_schema, tg_table_name, new.id, v_old_domain,
        coalesce(v_domain::text, 'NULL');
    end if;
  end if;

  -- INHERITANCE ON SUPERSESSION (decision 6, below). Found while writing the
  -- test, not while writing the design: supersede_memory() (sql/26) builds its
  -- successor from a fixed column list that does not include
  -- consequential_domain. A row-declared classification therefore evaporated
  -- on the first correction — the successor came back unclassified, held to
  -- the baseline, looking healthy. Keyed on new.supersedes rather than patched
  -- into supersede_memory() so it also covers supersede_wiki() (sql/24) and
  -- any future successor-writing path, none of which know about this file.
  --
  -- Inheritance fills a blank; it does not override. An explicitly declared
  -- successor domain wins, because reclassification-by-supersession is exactly
  -- what decision 5 says the sanctioned reclassification path is.
  if v_domain is null and new.supersedes is not null then
    execute format('select consequential_domain from %I where id = $1', tg_table_name)
      into v_domain using new.supersedes;
  end if;

  if v_domain is null then
    return new;  -- no domain claim; sql/03 baseline is the whole rule
  end if;

  -- Materialize the resolved domain onto the row so a workstream-bound or
  -- table-bound row carries its classification explicitly from then on. The
  -- ratchet above depends on this: an unstamped row would re-resolve to null
  -- the moment its workstream changed.
  new.consequential_domain := v_domain;

  select * into v_pol from consequential_domain_policy where domain = v_domain;
  if not found then
    -- FAIL CLOSED. Reachable if a domain is added to the enum without a policy
    -- row, or a policy row is deleted while classified rows exist. The
    -- alternative -- treat an undeclared domain as unrestricted -- would make
    -- DELETE FROM consequential_domain_policy a one-statement disarm.
    raise exception
      'domain % is not declared in consequential_domain_policy; refusing the write on %.% (row id: %)',
      v_domain, tg_table_schema, tg_table_name, new.id;
  end if;

  if new.provenance_basis is null then
    raise exception
      '%.% row is in the % domain and requires a provenance_basis of % (row id: %)',
      tg_table_schema, tg_table_name, v_domain, v_pol.allowed_basis, new.id;
  end if;

  if not (new.provenance_basis = any(v_pol.allowed_basis)) then
    raise exception
      '%.% row is in the % domain, which accepts provenance_basis % — got % (row id: %). %',
      tg_table_schema, tg_table_name, v_domain, v_pol.allowed_basis,
      new.provenance_basis, new.id, v_pol.rationale;
  end if;

  if v_pol.citation_required and (new.citation is null or new.citation ~ '^\s*$') then
    raise exception
      '%.% row is in the % domain, which requires a non-empty citation for every provenance_basis including % (row id: %)',
      tg_table_schema, tg_table_name, v_domain, new.provenance_basis, new.id;
  end if;

  if new.source_kind = 'agent' then
    if v_pol.agent_authorship = 'forbidden' then
      raise exception
        'agent-authored rows are not permitted in the % domain on %.% (row id: %). %',
        v_domain, tg_table_schema, tg_table_name, new.id, v_pol.rationale;
    end if;

    -- ENTRY rule only (decision 4). Promotion of an agent proposal by a human
    -- is sql/26's gate, and it is an UPDATE. The GUC exemption is sql/26's
    -- existing sanction window, reused so this file adds no new bypass.
    if v_pol.agent_authorship = 'proposal_only'
       and tg_op = 'INSERT'
       and new.status <> 'proposed'
       and coalesce(current_setting('app.promoting', true), 'off') <> 'on' then
      raise exception
        'an agent-authored % row must enter at status=proposed on %.% (row id: %, got status=%). A human promotes it; the agent does not.',
        v_domain, tg_table_schema, tg_table_name, new.id, new.status;
    end if;
  end if;

  return new;
end; $$;

revoke execute on function enforce_consequential_domain() from anon, authenticated, public;

-- Trigger names sort before trg_enforce_provenance_*, so on a domain-classified
-- row this raises first and the operator sees the domain-specific message
-- rather than the generic one. Both reject; only the wording differs.
drop trigger if exists trg_consequential_domain_memories on memories;
create trigger trg_consequential_domain_memories
  before insert or update on memories
  for each row execute function enforce_consequential_domain();

drop trigger if exists trg_consequential_domain_wiki on wiki_pages;
create trigger trg_consequential_domain_wiki
  before insert or update on wiki_pages
  for each row execute function enforce_consequential_domain();

-- NOTE ON wiki_pages: it is gated here even though sql/26 deliberately left it
-- out of the INSERT status sanction. The reasoning is not inconsistent. sql/26
-- declined to gate ALL wiki inserts because wiki_pages defaults to
-- status='current' and has no promote_wiki(), so gating everything would make
-- the table uncreatable. This file gates only the rows that resolve to a
-- domain, which is nothing at install. The consequence is real and intended:
-- an agent-authored consequential wiki page must enter at 'proposed', and a
-- proposed wiki page currently has NO sanctioned promotion path. That is a
-- fail-closed dead end, and the fix is promote_wiki() -- already an open item
-- from sql/26 -- not relaxing this rule. An agent-authored medical wiki page
-- landing at 'current' because the promotion machinery was never built is the
-- worse of the two outcomes.

-- ══════════════════════════════════════════════════════════════════════════
-- PART 5 — operator surface
-- ══════════════════════════════════════════════════════════════════════════
-- What is classified, under what rule, and by which of the three sources.
-- Without this an operator has to reconstruct the resolution order by hand to
-- answer "is this workstream covered", which is the question that actually
-- gets asked.

create or replace function consequential_domain_coverage()
returns table (
  table_name  text,
  workstream  text,
  domain      consequential_domain,
  bound_by    text,
  row_count   bigint
) language sql stable security definer set search_path = public as $$
  with rows_seen as (
    select 'memories'::text   as tbl, workstream, consequential_domain from memories
    union all
    select 'wiki_pages'::text as tbl, workstream, consequential_domain from wiki_pages
  )
  select r.tbl, r.workstream, r.consequential_domain,
         case
           when pr.table_domain is not null then 'provenance_registry.table_domain'
           when b.domain is not null        then 'consequential_domain_binding'
           when r.consequential_domain is not null then 'row-declared (caller-asserted)'
           else 'unclassified — baseline provenance only'
         end,
         count(*)
  from rows_seen r
  left join provenance_registry pr on pr.table_name = r.tbl
  left join consequential_domain_binding b
         on b.table_name = r.tbl and b.workstream = r.workstream
  group by 1,2,3,4
  order by 1,2,3;
$$;

revoke execute on function consequential_domain_coverage() from anon, authenticated, public;

alter table consequential_domain_policy  enable row level security;
alter table consequential_domain_binding enable row level security;
revoke all on consequential_domain_policy  from anon, authenticated;
revoke all on consequential_domain_binding from anon, authenticated;
