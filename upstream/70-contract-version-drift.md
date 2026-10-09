We worked #70 downstream. The output is a design document,
`docs/08-contract-version-and-drift.md`.

**Status: DESIGN. Nothing in it is implemented and nothing is applied.** No
function it describes exists in this repo or on any deployment. We are posting it
because the *evidence* half is worth upstreaming immediately even though the
mechanism half is not built: every claim about what the schema does **today** is
cited to the file and line it was read from, and every claim about what *should*
exist is marked as a proposal.

## Source-visible contract changes

These examples describe source signatures and review consequences, not a live
change log or adopter incident:

1. `sql/20_transition_concurrency_and_actor_custody.sql` removes the actor-free
   supersession form and requires an actor argument. Instructions teaching the
   removed signature need review; claimed actor identity is not authenticated
   identity merely because a UUID resolves.
2. `sql/27_retrieval_acl_drift_fix.sql` changes the projection-refresh return
   shape to include ACL repair. A caller that assumes the earlier tuple must
   migrate rather than silently fold repairs into another count.
3. `sql/29_retrieval_embedding_backlog.sql` defines client-facing work-list
   signatures. A fresh-source replay and an intended target's callable inventory
   must both be checked; either source or instructions can drift.
4. `sql/35_retrieval_topology.sql` adds coverage vocabulary to retrieval.
   Closed-schema clients and exhaustive status switches need explicit handling
   for partial coverage. See #72.

A contract check should represent drift in both directions without publishing
private instructions or target-specific execution history.

## Conformance evidence: embeddings are never computed in SQL

#70's search-and-write guidance says: *"Compute embeddings client-side only when
semantic retrieval is needed; never compute embeddings in SQL."* We read
`sql/29_retrieval_embedding_backlog.sql` in full and checked both function bodies
against that rule rather than taking the file's own comment as evidence.

**`retrieval_embedding_backlog(text, text, text, integer)`** — a single `select`,
`LANGUAGE sql`, `STABLE`, returning `(unit_id, rendered_text, text_hash,
reason)`. The only computation is a SHA-256 hex digest of the rendered text, used
twice: once as the returned `text_hash`, once compared against the stored hash to
detect that a stored vector no longer describes the current text. It contains no
vector expression, no vector cast, no call to any embedding function, and no
write to the embeddings table — it reads that table only through a `LEFT JOIN` to
discover whether a row exists and whether the embedding is null.

**`retrieval_embedding_coverage(text, text, text)`** — also a single `select`,
`STABLE`, returning one `jsonb` object: a model label, three counts, one boolean.
Every reference to `embedding` is a null test. Nothing writes; nothing constructs
a vector.

**Conclusion: both functions report *what needs embedding* and *what has been
embedded*. Neither produces a vector.** The design is that vectors are produced
client-side and written back, and the SQL side is deliberately a work-list.

**Provider boundary:** SQL work-list definitions do not prove what an external
embedding worker does. Qualify the actual worker source and runtime separately;
do not infer execution behavior from a grant or a migration comment.

## The design, in brief

**Three tiers, because "the agent-operations contract" could mean three things
with very different churn rates.**

- **Tier A — the public function contract (versioned).** Per function: name, full
  argument list (including parameter **names** and **defaults** — both are
  callable surface, since a PostgREST caller passes by name), result, security
  mode, volatility, `proconfig`/`search_path`, and sorted ACL. ACL is in the
  digest because a revoked grant changes who can call it, and that is contract.
- **Tier B — the PostgREST-reachable RPC surface**, versioned separately, because
  grants and reachability are independent axes here: a function can be granted and
  unreachable, or reachable and ungranted.
- **Tier C — the rest of the public schema**, explicitly *not* versioned by this
  digest.

**The bump rule, with the worked examples above:**

| bump | meaning | instance |
| --- | --- | --- |
| MAJOR | a signature was removed, narrowed, or its result shape changed | source examples 1, 2, 4 |
| MINOR | a signature was added; nothing existing changed | `retrieval_acl_drift()` in `sql/27` |
| PATCH | ACL, volatility or `search_path` changed without changing callability | the grant added in `sql/25` |

**Mismatch behaviour is split by consequence, per #70's "fail closed without
locking out read-only recovery":** authority-bearing operations (the promotion,
rejection and supersession functions, capability grant paths) **refuse**, with an
error naming the contract version and the mismatch. Read-only recovery surfaces
(retrieval, coverage reporting, drift detection, and the introspection call
itself) **stay available**. An agent working from stale instructions can still
read and still report; it cannot make anything authoritative.

**Two things must both be exposed, not one.** A version alone lets a deployment
claim conformance it does not have; a digest alone tells you *that* something
differs but not whether it is a widening or a break. The pre-DDL probe searches
the operator-supplied instruction corpus for the affected signatures and **blocks
the DDL, not the database** — it is an operator-safety gate, not a runtime one.

## Where this design is honest about not solving the problem

- **Boot integration requires source comparison.** `session_boot()` is in
  `sql/32_session_boot.sql`, with scope composition in `sql/45`. The separate
  `public.agent_contract()` proposal must align with that optional surface before
  adoption. #72's first-call topology contract needs the same integration review.
- **No canonical agent-operations contract document exists in this repo to
  version.** The Tier A/B digest works without one, but the prose contract #70
  assumes is not here.
- **The digest is signature-only and blind to body changes.** A rewritten body
  under an unchanged signature does not move it. That gap is covered by the
  canonicalizing definition check built for **#58** — the two checks are
  complements, not substitutes, and neither subsumes the other:

  | check | sees | blind to |
  | --- | --- | --- |
  | contract digest (#70) | signature, security mode, volatility, config, ACL | body changes |
  | canonical definition hash (#58) | body, plus everything above | comment-only drift; keyword-case and alias changes report as false drift |

- **The instruction corpus format is undefined**, because the live instruction
  surface is deployment data and is not in this repository. The operator defines
  the export; the probe defines only what it searches for. This is a deliberate
  boundary, not an omission — a probe that reached into deployment instructions
  itself would be holding exactly the data #70 says to keep out.
- **No degraded mode exists.** The mismatch behaviour above is a specification,
  not a description of running code.

This source/design note does not establish implementation, execution, or hosted
conformance of the proposed contract-version mechanism.
