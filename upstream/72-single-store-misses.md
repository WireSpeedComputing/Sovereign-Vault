We built the retrieval-side half of #72. **Status: PENDING OWNER APPROVAL, NOT
APPLIED.**

- `pending/B_retrieval_topology_ISSUE72.sql` — Part 1 (topology table + seed),
  Part 2 (the envelope change)
- `pending/B_retrieval_topology_TEST.sql` — 24 assertions, all passing on a fresh
  PG17 replay with Part 1 applied

Part 1 was dry-run tested against the live database inside a rolled-back
transaction, zero residue. Neither part is applied.

## The design decision we think is the upstreamable one

Our first design note proposed a `global_completeness` boolean and left
`retrieval_status` alone. **We rejected that while building it**, and the reason
generalizes.

#72 item 3 requires that a single-store miss not render as "nothing found
everywhere". A boolean the caller may ignore does not achieve that. The existing
envelope **already reports `units_matched = 0` honestly** — the number was never
wrong. The failure mode is that **a correct number is read as a stronger claim
than it supports.** Adding another field a caller can skip reproduces the problem
one key over: now there are two honest values and the same unsupported inference
sitting on top of them.

So the coverage state is carried **in `retrieval_status` itself**, as a third
value:

| value | meaning |
| --- | --- |
| `not_evaluated` | nothing was searched — empty query, or no units visible to this principal |
| `evaluated` | searched, **and** every advertised store was reachable |
| `evaluated_partial_coverage` | searched what this runtime can reach; one or more advertised stores were **not** queried |

The property that makes this work: a caller that only knows the old vocabulary
sees an **unrecognised status** and must decide what to do. That is the correct
failure mode for a fail-closed contract. A caller that silently treats an unknown
status as `evaluated` was going to over-claim anyway — but now it is making that
choice explicitly, in its own code, rather than inheriting it from a field it
never read.

The general form: **if a claim must not be ignorable, it cannot be an additive
optional field. It has to go somewhere the caller is already forced to branch
on.** A new key is advisory by construction; a new enum value is breaking by
construction, and here breaking is the point.

## It applies to HITS as well as misses — deliberately

`evaluated_partial_coverage` is returned on a **successful** retrieval too, not
only on a zero-match one. Asserted as `a3_hit_under_partial_coverage_is_still_partial`.

This was a real fork in the design. Flipping to `evaluated` on a hit is tempting
— the query found something, coverage feels academic — and it is wrong: **finding
something locally is not evidence that nothing more exists elsewhere.** A status
that reported complete coverage whenever results were non-empty would teach
callers, correctly by observation, that a hit means the search was complete. Then
the one time it matters — a partial hit that misses the decisive record in an
unqueried store — the contract has already trained the caller to over-trust it.

Coverage is a property of **the search**, not of **the outcome**. Making the flag
outcome-dependent silently converts it into a different, useless flag.

## Conformance against the required contract

| #72 requirement | Status |
| --- | --- |
| 1. Deployment-neutral store identity/profile + topology + coverage at first call | **Partial** — exposed in the retrieval envelope; there is **no `session_boot()` in this repo** (see below) |
| 2. Distinguish `queried` / `not_queried` / `unreachable` / `unknown`; never imply a peer was searched | Yes — full four-value vocabulary, `b5_coverage_vocabulary_is_not_collapsed`, `b6_unreachable_peer_reported` |
| 3. Report exact stores queried; a single-store miss is not "nothing found everywhere" | Yes — the status value above, plus `unqueried_stores` |
| 4. Open/stale coordination tasks visible at boot with age/blocking metadata | **Not addressed** |
| 5. Canonical contract specifies fail-closed answer policy, retains read-only recovery | **Partial** — read-only recovery preserved (`b6b_unreachable_peer_does_not_break_local_read`); no canonical contract document exists here to specify it in |
| 6. Static client fallback identified as fallback, never authority | **Not addressed** — client-side |
| 7. #70 attestation still required | Agreed — and this change is itself a #70 case, see below |

Three implementation notes behind those:

**Topology is table-driven, not hardcoded in the function.** The schema stays
generic and publishable while the rows remain deployment data. Store keys in the
seed are deliberately generic labels rather than deployment identifiers, which is
what lets the migration file be published at all.

**Topology is read fresh on every call.** A store going unreachable must change
the **next answer**, not the next deployment.

**The local store's coverage is a fact about this call, not a static property.**
If nothing was evaluated then nothing was queried, and saying otherwise is the
same over-claim this work exists to remove. `b4_local_coverage_reflects_this_call`
and `b4b_local_coverage_is_queried_when_it_was` assert both directions.

**An empty topology table is not a claim of completeness — it is the absence of a
claim.** With no rows configured, completeness coalesces to true and a deployment
that never configured topology behaves exactly as it does today.
`b7_no_topology_configured_behaves_as_before`. This matters for adoption: the
migration is not a breaking change for anyone who does not use it.

## Privacy (item 4 of the acceptance list)

`retrieval_topology.notes` describes what each store **is** — that is deployment
intelligence, not routing information a caller needs. The envelope exposes
`store_key`, `store_role` and `coverage_state`, and **never** `notes`.

This is asserted rather than left to reviewer vigilance —
`c1_notes_never_reach_the_envelope` and `c1b_no_notes_key_in_any_store_entry`
(the second checks no store entry carries the key at all, not merely that its
value is absent) — because **a later `select *` refactor is exactly how such a
field escapes**. `c2_topology_does_not_vary_by_principal_visibility` covers the
cross-principal requirement.

## This is a MAJOR signature change, and we flagged it under #70 before shipping

Part 2 changes the most widely-used function in this schema. The envelope gains
three keys and `retrieval_status` gains a third value. Any caller switching
exhaustively on `retrieval_status`, or validating the envelope against a closed
schema, **breaks**.

Under our #70 versioning rule that is a MAJOR bump requiring a pre-DDL
instruction probe. It is the **fourth #70-class signature change identified in
this project and the first one caught before it shipped rather than after** —
which is the strongest argument we have that #70's machinery earns its cost.
Details in our comment on #70.

We note #72 states it outranks #70 in ordering. We agree on priority and would
add: this issue's own implementation is a live demonstration of why #70 cannot be
deferred indefinitely, because landing this correctly requires exactly the probe
#70 specifies.

## What we did not do

- **Not applied.** Pending owner approval.
- **With the current seed, the status is always `evaluated_partial_coverage`,**
  because three of the four advertised stores genuinely cannot be queried from
  here. That is the honest answer today, not a bug — but it means the plain
  `evaluated` branch is exercised **only by tests**
  (`a4_full_coverage_reports_plain_evaluated`), never by production traffic, and
  we would rather say so than let a green suite imply otherwise.
- **There is no `session_boot()` in this repo.** #72 items 1 and 4 assume a
  first-call introspection surface; #70 assumes the same one. Neither exists.
  Whoever lands it first should own the shape, or the two issues will produce two
  incompatible boot surfaces.
- **No client-side work.** Item 6 (static fallback identified as fallback, never
  authority) and item 3's client half are outside this migration entirely. The
  database can now *report* partial coverage; nothing forces a client to render
  it.
- **PostgreSQL 15 and 16 paths are untested.** The acceptance list requires
  fresh-install, reapply and upgrade paths on 15 and 16. Our replay harness runs
  PG17 only.
- **No synthetic two-store client fixtures.** The acceptance list asks for
  fixtures proving local hit, remote hit, partial miss, complete miss, unreachable
  peer, unknown topology and stale-task escalation. Our 24 assertions cover the
  database-side equivalents of most of these (`a1`–`a5`, `b6`, `d1`–`d5b`), but
  they are SQL-level tests against one store with a declared topology, **not
  two-store client fixtures**. Stale-task escalation is not covered at all.

Happy to open a PR if the status-value approach looks right — that is the
decision we would most want challenged before it becomes API.
