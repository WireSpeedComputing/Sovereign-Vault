# Draft comment for upstream sovereign-memory-core#44

**Status: DRAFT. Not posted.** Review before posting. Confirm nothing below
names a real identifier, workstream, principal, or deployment, and confirm the
"what we did not close" section is still accurate at the time of posting.

**Migration status downstream: written, replayed, NOT applied to any
deployment.**

---

We implemented #44 downstream and are offering the design and the DDL back, so
the issue can close against a real implementation rather than a description of
one.

Short version of our conformance:

| Acceptance criterion | Status |
| --- | --- |
| Domains can be declared | Yes — enum + policy table + two binding mechanisms |
| Financial/legal/medical/identity baseline represented | Yes, with per-domain evidence rules, not just labels |
| Write-time rejection tested | Yes — 35 assertions, negative + positive controls + legitimate-path |
| Docs updated | Design rationale lives in the migration header; limits are asserted in the test suite |

## The part of #44 that was already done, and the part that was not

Our provenance layer already had a registry naming which tables are
consequential and a trigger rejecting unsourced writes to any of them. That is
already generalized beyond a financial-only guard, and we think it satisfies
"generalize beyond financial-style provenance guards" on its own.

What it could not express is that facts differ in **kind**. The registry had one
knob per table, so every row in `memories` was held to the same evidentiary bar
— a lab result and a lunch preference are the same row shape to it. That is the
gap #44 actually names, and it is a taxonomy problem, not a coverage problem.

## The three design decisions we think are load-bearing

**1. Domain is a property of a row, resolved from three sources, and only one
of them is the writer.**

Table-level domain is the obvious model and it is wrong for the core tables.
`memories` and `wiki_pages` are the generic knowledge substrate; one table holds
every kind of fact a deployment knows. Declaring `memories` to be "the medical
table" is false, and declaring it to be no domain at all leaves #44 unanswered
for the only tables that ship.

But a per-row field the writer fills in is a **self-description**, and this repo
already established what to think of rules keyed on self-description when it
declined to key promotion guards on `source_kind`. A writer who does not want
the medical bar simply leaves the column null.

So we resolve in precedence order:

1. `provenance_registry.table_domain` — for a table wholly within one domain (a
   domain module's own tables, where the table-level claim is true).
2. `consequential_domain_binding (table_name, workstream) -> domain` — declared
   by the schema owner, not the writer. A row landing in a bound workstream is
   classified whether or not it says anything.
3. the row's own `consequential_domain` column — writer-declared, weakest.

1 and 2 are schema configuration; 3 is a claim. A deployment that has done its
declaration work does not depend on writers being honest. A deployment that has
declared nothing gets exactly the previous baseline and nothing worse.

**2. A row has at most one domain, and conflict is an error rather than a
silent override.**

A table can span domains; a single row cannot hold two. Multi-domain rows need a
"which requirement wins" rule and every version of it is either "the strictest",
which makes the label decorative, or "the writer picks", which is the
self-description hole again. When a higher-precedence source and the row
disagree we reject the write, because a silent override lets the writer see
success and reasonably believe the row is classified the way they said.

**3. `agent_authorship` constrains ENTRY, not promotion — and we shipped the
other version first.**

Our first draft enforced `source_kind='agent' AND status<>'proposed'` on INSERT
*and* UPDATE. All the negative tests were green. It also rejected the promotion
function itself, because promotion is an UPDATE setting an agent-sourced row to
`current` — so the guard meant to stop agents self-promoting instead stopped
*humans* from promoting agent proposals. A domain guard that makes agent-drafted
medical facts unreviewable has not secured the review loop, it has deleted it.

That failure is only visible if the suite contains a **legitimate-path** test.
We would suggest that as doctrine for guard work generally: a negative suite
with no positive path can go fully green on a guard that has bricked the system.

We also found, and did not fix here, that a successor row written by the
supersession function does not carry the classification forward — the function
builds its successor from a fixed column list. Left alone, a row-declared
classification survives exactly until the first correction and then silently
becomes null, with the *corrected* row — the one now current — held to the
weaker bar. Worse, workstream-bound rows re-resolve and survive, so the bug
would be invisible in precisely the deployments that had configured things
properly. We handle it in the trigger by inheriting from `new.supersedes` rather
than by patching the supersession function, so it also covers the wiki
supersession path and any successor-writing path added later.

## What we did not close, stated plainly

- **Content is not classified.** A plainly financial fact written into an
  unbound workstream with no declared domain is accepted on the baseline. This
  layer enforces classification that a schema owner declared or a writer
  volunteered; it does not detect it. Closing that is a model-in-the-loop
  problem, not a trigger. We assert it as a test so "#44: done" does not read
  as more than it is.
- **Policy can be weakened in place.** A missing policy row fails closed; an
  UPDATE that widens `allowed_basis` or clears `citation_required` does not.
  DELETE fails closed only because it leaves nothing to consult. We considered a
  no-loosening ratchet and rejected it: absolute, it makes a wrong baseline
  permanent and the table stops being policy; with an escape, the escape is the
  new hole.
- **We inherit the session-GUC bypass** from the propose-then-promote work
  rather than inventing a second sanction window. A caller holding the service
  role can arm it. We verified the bypass is *bounded* — an armed caller can
  skip propose-then-promote and still cannot write a medical fact on a decision
  record — and assert that as its own test, because otherwise the limit reads as
  larger than it is.
- **A composition defect between two of our own migrations**, which is worth
  reporting because we think it is upstream-shaped. The supersession function
  copies `source_kind` from the predecessor, so a successor is still
  `source_kind='agent'`; the agent-self-attestation guard then sees an agent row
  at `current` and refuses every basis except `decision_record`. Our medical and
  legal policies exclude `decision_record` by design. Net effect: an
  agent-proposed, human-promoted medical fact is **permanently uncorrectable**
  — the only basis one guard accepts for its successor is the one the other
  forbids. Two individually defensible rules composing into a dead end. The fix
  we think is right is that a correction authored by a human principal should
  not inherit the predecessor's `source_kind`, but that changes supersession
  semantics and its audit receipts, so we are raising it rather than doing it.

## The DDL

Generic. Substitute your own domains and baselines; the four below are defaults,
not doctrine.

```sql
-- ── taxonomy ──────────────────────────────────────────────────────────────
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

-- Baselines. 'human_direct' is removed from financial, legal and medical on
-- purpose: a stated figure is not a sourced figure. It is re-admitted for
-- identity, where a person stating who they are IS the primary source -- and
-- citation_required still applies, so the statement must say where it was made.
-- decision_record is excluded from legal and medical: a decision to read a
-- clause or a result a certain way is not the clause or the result, and
-- conflating them is how an internal interpretation gets cited as the source.
insert into consequential_domain_policy (domain, allowed_basis, citation_required, agent_authorship, rationale) values
 ('financial', array['decision_record','imported_artifact','source_document']::provenance_basis[], true, 'proposal_only', '...'),
 ('legal',     array['imported_artifact','source_document']::provenance_basis[],                   true, 'proposal_only', '...'),
 ('medical',   array['imported_artifact','source_document']::provenance_basis[],                   true, 'proposal_only', '...'),
 ('identity',  array['human_direct','source_document']::provenance_basis[],                        true, 'forbidden',     '...');

-- ── the three classification sources ──────────────────────────────────────
alter table provenance_registry
  add column table_domain consequential_domain
    references consequential_domain_policy(domain);

create table consequential_domain_binding (
  table_name  text not null references provenance_registry(table_name) on delete cascade,
  workstream  text not null check (workstream !~ '^\s*$'),
  domain      consequential_domain not null references consequential_domain_policy(domain),
  declared_at timestamptz not null default now(),
  declared_by uuid references principals(id),
  primary key (table_name, workstream)
);

alter table memories   add column consequential_domain consequential_domain;
alter table wiki_pages add column consequential_domain consequential_domain;

create index memories_consequential_domain_idx
  on memories (consequential_domain) where consequential_domain is not null;
create index wiki_pages_consequential_domain_idx
  on wiki_pages (consequential_domain) where consequential_domain is not null;

-- ── resolution ────────────────────────────────────────────────────────────
create or replace function resolve_consequential_domain(
  p_table_name text, p_workstream text, p_declared consequential_domain
) returns consequential_domain
language plpgsql stable security definer set search_path = public as $$
declare v_table_domain consequential_domain; v_bound consequential_domain;
begin
  select table_domain into v_table_domain
  from provenance_registry where table_name = p_table_name;

  if v_table_domain is not null then
    if p_declared is not null and p_declared <> v_table_domain then
      raise exception 'consequential domain conflict on %: table is declared wholly % but the row declares %',
        p_table_name, v_table_domain, p_declared;
    end if;
    return v_table_domain;
  end if;

  if p_workstream is not null then
    select domain into v_bound from consequential_domain_binding
    where table_name = p_table_name and workstream = p_workstream;
  end if;

  if v_bound is not null then
    if p_declared is not null and p_declared <> v_bound then
      raise exception 'consequential domain conflict on %: workstream "%" is bound to % but the row declares %',
        p_table_name, p_workstream, v_bound, p_declared;
    end if;
    return v_bound;
  end if;

  return p_declared;
end; $$;

-- ── enforcement ───────────────────────────────────────────────────────────
create or replace function enforce_consequential_domain()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_domain consequential_domain; v_old_domain consequential_domain;
  v_pol consequential_domain_policy%rowtype;
begin
  v_domain := resolve_consequential_domain(tg_table_name, new.workstream, new.consequential_domain);

  -- Ratchet: a classification may be added, never changed and never removed.
  -- Without this, every rule below is one UPDATE away from optional.
  -- null -> domain IS allowed: late classification is a strengthening, and
  -- refusing it would mean a deployment can never adopt this for what it holds.
  if tg_op = 'UPDATE' then
    v_old_domain := resolve_consequential_domain(tg_table_name, old.workstream, old.consequential_domain);
    if v_old_domain is not null and v_domain is distinct from v_old_domain then
      raise exception 'consequential domain is not editable once set (row %, % -> %); reclassification is a supersession, not an edit',
        new.id, v_old_domain, coalesce(v_domain::text,'NULL');
    end if;
  end if;

  -- Inherit on supersession. Keyed on new.supersedes rather than patched into
  -- the supersession functions, so every successor-writing path is covered
  -- including ones that have never heard of this file. Inheritance fills a
  -- blank; an explicitly declared successor domain still wins.
  if v_domain is null and new.supersedes is not null then
    execute format('select consequential_domain from %I where id = $1', tg_table_name)
      into v_domain using new.supersedes;
  end if;

  if v_domain is null then return new; end if;

  -- Materialize, so the ratchet has something to hold onto if the row's
  -- workstream later changes.
  new.consequential_domain := v_domain;

  select * into v_pol from consequential_domain_policy where domain = v_domain;
  if not found then
    -- FAIL CLOSED. If an undeclared domain read as unrestricted, deleting a
    -- policy row would be a one-statement disarm.
    raise exception 'domain % is not declared in consequential_domain_policy; refusing the write (row %)',
      v_domain, new.id;
  end if;

  if new.provenance_basis is null then
    raise exception 'row is in the % domain and requires a provenance_basis of % (row %)',
      v_domain, v_pol.allowed_basis, new.id;
  end if;

  if not (new.provenance_basis = any(v_pol.allowed_basis)) then
    raise exception 'row is in the % domain, which accepts provenance_basis % — got % (row %). %',
      v_domain, v_pol.allowed_basis, new.provenance_basis, new.id, v_pol.rationale;
  end if;

  if v_pol.citation_required and (new.citation is null or new.citation ~ '^\s*$') then
    raise exception 'row is in the % domain, which requires a non-empty citation for every basis including % (row %)',
      v_domain, new.provenance_basis, new.id;
  end if;

  if new.source_kind = 'agent' then
    if v_pol.agent_authorship = 'forbidden' then
      raise exception 'agent-authored rows are not permitted in the % domain (row %). %',
        v_domain, new.id, v_pol.rationale;
    end if;
    -- ENTRY rule only. Promotion of an agent proposal by a human is an UPDATE
    -- and is the review gate's business. The GUC exemption is the EXISTING
    -- propose-then-promote sanction window, reused so this adds no new bypass.
    if v_pol.agent_authorship = 'proposal_only'
       and tg_op = 'INSERT' and new.status <> 'proposed'
       and coalesce(current_setting('app.promoting', true), 'off') <> 'on' then
      raise exception 'an agent-authored % row must enter at status=proposed (row %, got %)',
        v_domain, new.id, new.status;
    end if;
  end if;

  return new;
end; $$;

-- Trigger names sort before the generic provenance trigger, so a classified
-- row gets the domain-specific message naming which bases the domain accepts,
-- rather than the generic one. Both reject; only the wording differs.
create trigger trg_consequential_domain_memories
  before insert or update on memories
  for each row execute function enforce_consequential_domain();
create trigger trg_consequential_domain_wiki
  before insert or update on wiki_pages
  for each row execute function enforce_consequential_domain();

revoke execute on function resolve_consequential_domain(text, text, consequential_domain)
  from anon, authenticated, public;
revoke execute on function enforce_consequential_domain() from anon, authenticated, public;
alter table consequential_domain_policy  enable row level security;
alter table consequential_domain_binding enable row level security;
revoke all on consequential_domain_policy  from anon, authenticated;
revoke all on consequential_domain_binding from anon, authenticated;
```

We also ship an operator function that reports, per (table, workstream), which
of the three sources classified the rows — `provenance_registry.table_domain`,
`consequential_domain_binding`, row-declared, or unclassified. Without it an
operator has to reconstruct the precedence order by hand to answer "is this
workstream covered", which is the question that actually gets asked.

## On the test suite

35 assertions in five sections, run against a fresh replay:

- **A — positive controls** over guards that predate this work, plus one
  inverse control asserting an ordinary write still *succeeds*. If A goes red
  the harness is not observing outcomes and nothing else in the file means
  anything. The inverse control matters: without it, a harness in which every
  insert failed for an unrelated reason shows all-green on every negative
  section.
- **B — unsourced consequential facts.** Nearly every case is one the previous
  baseline **accepts**; each says so in a comment. A negative suite that only
  re-proves the pre-existing provenance trigger would go green against an empty
  migration.
- **C — agent-authored consequential facts**, including the evasions:
  clearing the classification, swapping it, downgrading the basis or nulling
  the citation after insert, and laundering a classified row through
  supersession on both tables.
- **D — the legitimate path.** Proposal, human promotion, supersession, wiki
  creation. TRUE means the write *succeeded*. This is the section that caught
  the promotion bug above.
- **E — documented limits and one pre-existing defect.** TRUE means the known
  hole is still open. If an E test starts failing, enforcement changed and the
  docs now overstate the guarantees — a docs bug, not a test bug.

Where a domain rule is supposed to be the thing rejecting, the assertion checks
the **error text**, not merely that something was refused. That is not
decoration: two of our tests went red on the first run because the row was
rejected by an unrelated pre-existing guard, so the test would have passed while
proving nothing about the code under test. "Some trigger said no" is not
evidence.

Happy to open a PR against this repo with the migration and the suite if the
design above looks right to you.
