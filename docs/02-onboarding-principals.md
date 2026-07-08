# Onboarding principals (template)

This is a template. Everything below uses placeholder people and example.com
addresses. Your actual principals, scopes, and grants are DEPLOYMENT DATA and
belong in your database (or your private ops notes) — never in this repo.
That rule is the point of the whole system: the repo holds schema and
enforcement; the database holds facts.

## Roster your deployment first

Before inserting anything, write down (privately) every human and agent that
will touch the store, and confirm the list is current. People leave.
A departed person must not appear in any grant you're about to insert, and
you should never repurpose a stale principal row for a new hire — deactivate
the old row (`active = false`, `deactivated_at = now()`), create a new one.

## Registration (template SQL)

```sql
-- A human with broad operational authority
insert into principals (kind, display_name, email, notes)
values ('human', 'Alex Example', 'alex@example.com', 'Operations lead')
returning id;  -- capture as :alex_id

-- A human with authority scoped to one domain
insert into principals (kind, display_name, email, notes)
values ('human', 'Blake Example', 'blake@example.com', 'Final authority on public-facing content')
returning id;  -- capture as :blake_id

-- Agents, formalized as principals. Use a stable agent_label per surface so
-- writes are attributable (matches the source_agent stamping convention).
insert into principals (kind, display_name, agent_label, notes) values
  ('agent', 'Primary working assistant (web)', 'AGENT-WEB', 'Main working instance'),
  ('agent', 'Desktop assistant', 'AGENT-DESKTOP', 'Secondary surface')
returning id;
```

## Capability scope: a worked example

The pattern that tends to work: one operator gets `admin` on everything
(formalizing existing reality, not expanding it), domain owners get `write`
on their lanes and `read` elsewhere, and agents get `propose` only — humans
promote proposals to current, per the provenance rules in
`sql/03_provenance.sql`.

| Principal | Resource scope | Permissions | Rationale |
|---|---|---|---|
| Alex | `table:*` | admin | Formalizes existing operator access |
| Blake | `workstream:content` | write | Owns that domain |
| Blake | everything else | read | Visibility without accidental edits outside the lane |
| AGENT-WEB | `workstream:*` | propose | Agents propose; humans promote |
| AGENT-WEB | `table:capability_grants` | (none) | Agents never self-grant or grant others |

## Sequencing

1. Confirm the Phase 1 acceptance tests (STATUS.md) pass on YOUR deployment
   before inserting any real grants — grants inside a system that isn't
   enforcing provenance and perimeter yet are decoration.
2. Insert human principals first, then agents.
3. Each domain owner reviews their own proposed scope before it's granted.
   A scope nobody signed off on is a guess, not a decision.
4. Grant, then immediately run `select * from perimeter_assert();` and
   `select * from capability_grant_audit order by changed_at desc limit 10;`
   to confirm the grants landed as intended and nothing unexpected opened up.
5. Run an observation window (two weeks is a reasonable default) with each
   new principal doing real reads and writes through their own identity
   before declaring multi-user complete.
