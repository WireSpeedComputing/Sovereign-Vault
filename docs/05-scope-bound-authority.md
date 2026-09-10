# Scope-bound authority

Upstream `sovereign-memory-core#45` requires authority to be declared per named
scope and never global by default. This describes how that works here, what it
does not yet cover, and the decisions behind both.

## The one thing to read first

**Nothing consults the capability model yet.** No RLS policy, no function, no
view calls `has_capability()` or `request_has_capability()`. Every property
below is real, tested, and constrains no read or write of knowledge today.

`scope_authority_report()` reports `enforced = false` for every scope, and that
column is hardcoded rather than computed — not as a placeholder, but because
reporting anything else would be a lie. It becomes a real column when the first
policy consults capabilities.

This is worth stating plainly because the layer looks finished. It is a
well-built lock, and there is no door in the frame yet.

## The layers

| layer | lives in | answers |
|---|---|---|
| identity resolution | `vault_auth` (sql/23) | which principal is this request? |
| scope semantics | `public` (sql/30) | does that principal hold this scope? |
| enforcement | *nothing yet* | should this query return this row? |

`vault_auth.request_has_capability()` resolves identity from the verified JWT
claims and then delegates every scope decision to `public.has_capability()`.
That delegation is the seam: scope semantics can change without touching the
identity layer, and vice versa. Nothing in `sql/30` or `pending/D` modifies
`vault_auth`.

## Human and agent authority are an intersection

For a direct human request (no `client_id` in the token), authority is the
human principal's grants.

For an agent-mediated request (OAuth/MCP, `client_id` present), authority is the
**intersection** of the human's grants and the agent's grants. An agent can
never exceed the human it acts for, and a human cannot be exceeded by tooling
they authorised.

Two consequences from live testing:

- **`issuer` must be the literal `iss` claim URL**, not a friendly label. A
  binding written with a label inserts cleanly, looks healthy in every view, and
  silently resolves nothing. This is the same failure class the scope registry
  exists to prevent one layer up.
- **Password-auth tokens carry no `client_id`.** The agent half of the model
  therefore cannot be exercised through password auth at all; it needs an
  OAuth/MCP client flow. Tokens carry `session_id`, not `jti`, so any
  per-token revocation or audit design must key on `session_id`.

## Scope grammar

`<kind>:<identifier>`, where kind is one of `workstream`, `table`, `record`,
`domain`.

**There is deliberately no `global` or `all` kind.** The cleanest way to
guarantee "never global by default" is for the type system to have no way to
express it. Breadth is expressed as several scopes, and reads in the audit trail
as several scopes.

Every scope must be registered in `scope_registry` before it can be granted;
`capability_grants.resource_scope` has a foreign key to it.

### Why the registry earns its complexity

`resource_scope` was free text. A grant on `workstream:brnad` is syntactically
indistinguishable from `workstream:brand` — it inserts cleanly, reads back
cleanly, appears in every audit view, and authorises nothing.

Fail-closed is correct, but **silent** fail-closed is still a defect: the
operator believes authority was granted. The registry turns a typo from a silent
no-op into an error at grant time, which is the only moment anyone is looking.

## Wildcard semantics: decided, shipped separately

The prior identity review required this be its own change; `sql/23` records
wildcards as "intentionally not implemented". `sql/30` makes exact matching a
decision rather than an omission. The mechanism is `pending/D_scope_hierarchy.sql`.

**Rejected: pattern wildcards** (`workstream:*`, LIKE, regex). A pattern grant is
authority over scopes that do not exist yet — anything a future operator names
under that prefix is retroactively covered by a grant nobody re-reviewed. It
also destroys reviewability: "who can read `workstream:brand`?" stops being a
query over grants and becomes a query over patterns evaluated against a scope
set that changes underneath you.

**Chosen: declared containment.** Scopes may name a parent, forming a tree. A
grant on an ancestor reaches a descendant only when that ancestor declares
`confers_descendants`. Containment resolves over rows that exist, never over
patterns, and `scope_effective_grants(scope)` answers the review question
directly, naming the route by which each principal has authority.

### The surprise in it

`confers_descendants` describes what a scope does **when granted**, not whether
it transmits when **traversed**. Given `brand` (confers) → `brand/social` (does
not confer) → `brand/social/x`, a grant on `brand` *does* reach
`brand/social/x`. Setting the flag false on the intermediate does not seal the
subtree.

This is deliberate — the alternative makes one column mean two things, and
conflated flags are how access control becomes unpredictable. But an operator
who sets `confers_descendants = false` expecting to carve out a subtree has not
done so, and nothing tells them. Sealing, if ever wanted, needs its own column
and its own review. Pinned as `m03` in the test matrix.

## Cutover declaration

`scope_cutover` declares that the vault is authoritative **for a named scope**,
replacing a prior source. This is a different question from
`import_cutover_scorecard` (sql/06), which answers whether a *source* is fully
accounted for. A founder needs the first one answered before trusting a
workstream.

`declare_scope_cutover()` requires an active human principal, an active declared
scope, and non-empty evidence, and supersedes any prior live declaration rather
than accumulating duplicates. `actor_assurance` carries the same caveat as
`sql/20`: a caller-supplied principal UUID proves the UUID belongs to an active
human, not that the caller *is* that human.

## What is still open

**Wiring capabilities to knowledge access.** This is the gap, and it is a design
decision rather than a coding task, because `retrieve_context()` already filters
on `owner`/`visibility`. Three options:

1. **Scope narrows visibility** — a row must pass the existing owner/visibility
   filter *and* the principal must hold the row's workstream scope. Strictly
   more restrictive than today; no existing access widens. Recommended.
2. **Scope replaces visibility** — capabilities become the only access rule.
   Cleanest model, but every current access path changes at once and anything
   missed becomes either an outage or a leak.
3. **Scope unions with visibility** — a row is readable if either permits.
   Rejected: it can only widen access, and a model where adding an authority
   rule grants more access is not an authority model.

Option 1 is recommended because it fails closed and can be rolled out scope by
scope. It also requires deciding what happens to rows whose `workstream` is
null — under option 1 they would become unreachable to everyone, so they need
either a default scope or an explicit exemption, and that choice should be made
deliberately rather than discovered.

**Agent-half testing.** Cannot be exercised until an OAuth/MCP client flow
exists, per the `client_id` finding above.
