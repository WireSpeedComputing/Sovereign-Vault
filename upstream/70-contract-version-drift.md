We worked #70 downstream. The output is a design document,
`docs/08-contract-version-and-drift.md`.

**Status: DESIGN. Nothing in it is implemented and nothing is applied.** No
function it describes exists in this repo or on any deployment. We are posting it
because the *evidence* half is worth upstreaming immediately even though the
mechanism half is not built: every claim about what the schema does **today** is
cited to the file and line it was read from, and every claim about what *should*
exist is marked as a proposal.

## This failure mode is not hypothetical. We have four instances

#70 describes a reviewed API correction leaving a deployment's live operating
instructions teaching a removed signature. We went looking for how often that has
actually happened here. Four instances, and they are not all the same shape:

**1. `supersede_memory()` lost its 5-argument form.** *Shipped.*
`sql/20_transition_concurrency_and_actor_custody.sql` line 147:
`drop function if exists supersede_memory(uuid, text, provenance_basis, text, text);`
The replacement takes six parameters. The drop was **deliberate** — the old form
recorded no actor, so every supersession through it was attributable to nobody,
and leaving it callable was considered and rejected. Consequence for #70: the old
call does not degrade, it **errors**. Any instruction teaching the five-argument
call became wrong at that line.

**2. `refresh_retrieval_units()` went from 3 to 4 return columns.** *Shipped, and
applied to a deployment.* `sql/27_retrieval_acl_drift_fix.sql` line 113 drops the
function, because `CREATE OR REPLACE` cannot widen a return type. Old shape
`(invalidated, projected_memories, projected_wiki)`; new shape `(invalidated,
repaired_acl_drift, projected_memories, projected_wiki)`. The file labels itself
"⚠ PUBLIC SIGNATURE CHANGE" and states the consequence in place: any runbook or
client destructuring the 3-column shape is stale as of that migration.

Worth recording *why* we did not dodge it: folding the repair count into
`invalidated` would have preserved the shape, and was rejected, because **a
repair indistinguishable from a no-op cannot answer "was anything actually
leaking?"** — the only question the change exists to answer. Sometimes the
compatible option defeats the purpose, which is exactly why #70's machinery is
needed rather than a policy of "don't change signatures".

**3. Embedding-backlog functions ran with no repo file.** *Reverse direction.*
`sql/29_retrieval_embedding_backlog.sql` was transcribed from the applied
definitions read back with `pg_get_functiondef()`, not retyped from a
description. Until it existed, a fresh install from this repo produced a database
where the deployed edge function returned **500 on a missing RPC** — while the
schema replayed clean and nothing said the pipeline was broken.

This one is a **different shape from 1 and 2**, and we think that is the
important observation for #70's design. Instances 1 and 2 are *repo changed,
instructions stale*. Instance 3 is *deployment changed, repo stale*. **A contract
version has to express both directions or it only solves half the problem.** It
was also the third time an applied migration had no repo file here, and every one
was caught by a human noticing, which does not scale.

**4. `retrieve_context()`'s envelope gains three keys and a third
`retrieval_status` value.** *Caught before shipping.*
`pending/B_retrieval_topology_ISSUE72.sql` — the #72 work — is a public signature
change to the most widely-used function in this schema. Any caller switching
exhaustively on `retrieval_status`, or validating the envelope against a closed
schema, breaks. Under the versioning rule below that is a MAJOR bump requiring
the pre-DDL probe. It is the **first of the four caught before it shipped rather
than after**, and it was caught only because #70 had already made us look.

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

**What we could not verify, stated plainly:** the claim that the deployed edge
function computes the vectors client-side rests on the file header and on the
fact that EXECUTE is granted only to the service role. **The edge function's
source is not in this repository** — there is no functions directory and no
TypeScript anywhere in the tree. So we verified that **SQL does not compute
embeddings**, which is what #70 forbids. We did not verify what the edge function
does, and we are not claiming to.

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
| MAJOR | a signature was removed, narrowed, or its result shape changed | instances 1, 2, 4 |
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

- **There is no `session_boot()` in this repo.** #70 says "expose that
  version/digest through `session_boot()` or another first-call introspection
  surface". That function does not exist here, so the document proposes
  `public.agent_contract()` rather than pretending to extend something. Related:
  #72 also assumes `session_boot()`. Whoever lands one first should probably own
  the shape.
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

We would rather post this as an evidence-backed design with four documented
instances than claim conformance we have not built.
