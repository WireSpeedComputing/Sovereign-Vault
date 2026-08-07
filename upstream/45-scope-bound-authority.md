We implemented #45 downstream. **Status: written, replays clean, NOT applied to
any deployment.**

- `sql/30_scope_bound_authority.sql` — scope grammar, registry, scope-bound cutover
- `tests/30_scope_bound_authority.sql` — 19 assertions
- `docs/05-scope-bound-authority.md` — the model and its open decisions
- `pending/D_scope_hierarchy.sql` + `pending/D_scope_hierarchy_TEST.sql` — declared
  containment, 14-case matrix, pending approval

## Read this first: the capability model is wired to NOTHING

We grepped all of `sql/`. **Nothing calls `has_capability()` or
`request_has_capability()`** — not one RLS policy, not one function, not one
view. Outside the definition sites, the only occurrences are a comment and an
exception-reason string.

So the authority model is currently **decorative**. Every property below — scope
validation, registry integrity, isolation — is real and testable *at the
capability layer*, and none of it constrains a single read or write of knowledge
today, because no read or write path consults it.

We are reporting this rather than quietly building on top, because a scope model
that nothing enforces will read as "scope-bound authority: done" in six months.
Concretely, `scope_authority_report()` returns `enforced = false` for every
scope, **hardcoded**, and the function comment says the hardcoding is not a
placeholder — reporting anything else would be a lie. It becomes a computed
column when the first policy consults capabilities.

This is the same shape as the #46 finding, one layer over: `promote_memory()`
looked like a chokepoint and was a convenience wrapper; `has_capability()` looks
like an authorization boundary and is an unreferenced function. We would suggest
that "is anything actually calling this?" belongs in the acceptance criteria for
any authority model, because it is not visible from the schema.

`tests/30` Section C is the honest half of the suite. #45 asks for tests proving
current and stale truth cannot leak across scopes. **Those tests cannot be
written yet**, and Section C asserts *why* rather than skipping it —
`c1_scope_authority_report_admits_nothing_is_enforced` and
`c2_a_granted_scope_still_constrains_no_reads`. Section C **fails the moment
enforcement lands**, which is the signal to come back and write the real
cross-scope leakage tests. Writing leakage tests against a model nothing
consults would produce a green suite proving only that two function calls return
different booleans.

## Conformance against the acceptance criteria

| #45 acceptance criterion | Status |
| --- | --- |
| Schema/docs represent scope | Yes — `scope_registry`, typed grammar, `docs/05` |
| Tests cover two distinct scopes | Yes — Section A, isolation in **both** directions |
| Cutover declaration is scope-bound | Yes — `scope_cutover` + `declare_scope_cutover()` |
| Stale/current truth cannot leak across scopes | **Cannot be tested yet** — see above; asserted as unenforced rather than claimed |

Section A proves isolation at the capability layer for two scopes in both
directions, across permissions: `a1`/`a3` hold their own scope, `a2`/`a4` are
denied on the other, `a5_permission_not_widened_within_scope`,
`a7_admin_implies_lesser_on_same_scope`, `a8_admin_does_not_cross_scopes`,
`a9_inactive_principal_loses_scope`.

## "Never global by default" is enforced by the type system, not by a rule

Scopes are `<kind>:<identifier>` with kinds `workstream | table | record |
domain`. **There is deliberately no `global` or `all` kind.** The cleanest way to
guarantee authority is never global by default is for the type system to have no
way to express it. Breadth is expressed as several scopes, and reads in the
audit trail as several scopes.

`b3_no_global_scope_kind_exists` and `b4_wildcard_scope_not_registrable` assert
this, so a later enum addition trips a test rather than passing review.

## The registry, and why silent fail-closed is still a defect

`resource_scope` was free text. A grant on `workstream:brnad` is syntactically
indistinguishable from `workstream:brand`. It inserts cleanly, reads back
cleanly, appears in every audit view, and **authorises nothing**.

Fail-closed is the right default, and this case is fail-closed. But **silent
fail-closed is still a defect**: the operator believes authority was granted and
has no signal otherwise. A registry with a foreign key turns a typo from a silent
no-op into an error at grant time — the only moment anyone is paying attention.

This is not hypothetical for us. We lost an afternoon to exactly this failure one
layer over, in the identity binding: `issuer` was written as a sensible-looking
label rather than the literal `iss` claim URL, and every binding silently failed
to resolve while looking perfectly healthy. Same class of bug — an unvalidated
string whose only symptom is having no effect. `b1_typo_scope_rejected_at_grant_time`
and `b2_malformed_scope_rejected`.

**Adoption warning:** the FK from `capability_grants.resource_scope` to
`scope_registry` is a **compatibility break**, not just a constraint. Any caller
granting an ad-hoc scope string now fails. It broke one of our own tests on first
run, which had granted an unregistered ad-hoc string. That breakage *is* the
feature working — but anything outside the repo that writes grants (an
onboarding script, a seeding job) breaks the same way, and should be found before
this is applied rather than after. It is safe to add the FK inline only because
this deployment has zero capability grants; on a deployment with grants, the
backfill of existing scopes *is* the migration.

## Wildcard semantics: pattern wildcards REJECTED, declared containment chosen

The prior identity review required wildcard semantics be a separate change.
`sql/30` makes exact matching a **decision rather than an omission** and points
at the mechanism; `pending/D_scope_hierarchy.sql` is the mechanism, shipping
separately and deliberately *after* exact-only has been in force, so nothing
silently widens between the two.

**Rejected: pattern wildcards** (`workstream:*`, LIKE, prefix, regex). Two
reasons, and we think the second is the stronger one:

1. A pattern grant is **authority over scopes that do not exist yet**. Grant
   `workstream:*` today and every workstream any future operator invents is
   retroactively covered by a grant nobody re-reviewed. The grant looks narrow in
   the audit trail — one row, one string — while its actual reach grows without a
   single further decision. That is "global by default" wearing a prefix, which
   is precisely what #45 exists to prevent.
2. **It destroys reviewability.** "Who can read `workstream:brand`?" stops being a
   query over grants and becomes a query over grants crossed with every pattern
   that might match, evaluated against a scope set that changes underneath you.

**Chosen: declared containment.** Scopes may name a parent, forming a tree. A
grant on an ancestor reaches a descendant **only if that ancestor declares
`confers_descendants`**. Resolution is over rows that exist, never over patterns.
Breadth stays available; the difference is that every scope a broad grant reaches
is a row somebody wrote on purpose, and adding a child is an explicit act that
visibly extends an existing grant — reviewable at the moment it happens, which is
the only moment it can be caught.

`scope_effective_grants(scope)` answers the review question directly and names
the **route** by which each principal has authority (`inherited_from` is null for
a direct grant). We treat this as a ship-blocker for containment: if you cannot
answer "who can read this, and how", containment is not reviewable and should not
ship.

### The surprise in it, stated up front rather than discovered

`confers_descendants` describes what a scope does **when granted**, not whether
it transmits when **traversed**. Given `brand` (confers) → `brand/social` (does
NOT confer) → `brand/social/x`, a grant on `brand` **does** reach
`brand/social/x`. Setting the flag false on the intermediate does not seal the
subtree.

This is deliberate — the alternative makes one column mean two different things
(confers when granted, transmits when traversed), and conflated flags are how
access control becomes unpredictable. But the surprise is real: an operator who
sets `confers_descendants = false` expecting to carve out a subtree **has not
done so, and nothing tells them.** Sealing, if ever wanted, needs its own column
and its own review, not a reinterpretation of this one.

It is pinned as `m03_conferring_root_reaches_grandchild_through_nonconferring`
in the 14-case matrix, so the behaviour is asserted rather than incidental. The
matrix exists because containment's failure modes live in the *combinations*, not
the individual rules — exact vs. ancestor grant, conferring vs. not, depth 1 vs.
2 vs. unrelated subtree, and direction. It covers upward (`m05`), sideways
(`m06`), cross-tree (`m07`), permission widening (`m08`), inactive principals
(`m09`), retired ancestors (`m10`), revocation (`m11`), and cycle termination
(`m14`).

## Scope-bound cutover

`scope_cutover` declares the vault is authoritative **for a named scope**,
replacing a prior source. This is a **different question** from the existing
import scorecard, which answers whether a *source* is fully accounted for. Those
get conflated easily and only the first one tells a user whether to trust a
workstream.

**A bug the tests caught, worth passing on:** the first draft keyed
`scope_cutover` on `(scope, declared_at)`. `now()` is transaction time, so two
declarations in one transaction collided on an identical timestamp, while two a
second apart — the actually-wrong case — were both accepted. The key was exactly
inverted relative to the invariant. Replaced with a surrogate key plus a partial
unique index on the real invariant: at most one *live* declaration per scope.
**Timestamps make bad keys.** `b8_cutover_supersedes_not_duplicates`.

## What is still open

- **Wiring capabilities to knowledge access.** This is *the* gap, and it is a
  design decision rather than a coding task, because retrieval already filters on
  owner/visibility. `docs/05` gives three options: scope **narrows** visibility,
  **replaces** it, or **unions** with it. Union is rejected outright — it can only
  widen access, and a model where adding an authority rule grants *more* access is
  not an authority model. We recommend narrowing: strictly more restrictive than
  today, fails closed, and can roll out scope by scope.
- **Rows with a null `workstream`.** Under the recommended option they become
  unreachable to everyone, so they need either a default scope or an explicit
  exemption. Naming it here because it is the kind of thing that gets discovered
  during a rollout instead of decided before one.
- **The agent half of the model is untestable today.** Authority for an
  agent-mediated request is the *intersection* of the human's grants and the
  agent's, but password-auth tokens carry no `client_id`, so the agent half
  cannot be exercised at all without an OAuth/MCP client flow. Related: tokens
  carry `session_id`, not `jti`, so any per-token revocation design must key on
  `session_id`.
- **Retiring a scope does not revoke grants on it.** Documented on the table
  comment rather than silently true.
