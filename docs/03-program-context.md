# Program Context

_Status: repository orientation; not an implementation or deployment authority_
_Last reconciled: 2026-08-28_

## Repository role

`WireSpeedComputing/Sovereign-Vault` owns the **public, generic business-deployment schema and tests** for a multi-user Sovereign Memory deployment.

It is not:

- the implementation-neutral Sovereign Memory Protocol;
- the generic PostgreSQL reference runtime;
- a production database or migration archive;
- an MCP server, identity provider, agent runtime, or UI;
- a store for real principals, grants, customer records, credentials, or deployment identifiers.

The repository may adopt reviewed protocol semantics and reference-runtime patterns, but deployment-specific business policy remains here rather than flowing upward into the protocol or Core.

## Dependency direction

```text
Sovereign Memory Protocol
    ↓ meaning, claim limits, conformance semantics
Sovereign Memory Core and other reference profiles
    ↓ reusable PostgreSQL mechanisms and adversarial lessons
Sovereign Vault
    ↓ generic multi-user business schema and policy
Business deployment and exact migration archive
    ↓ real identities, data, credentials, approvals, and operating evidence
Applications, MCP capabilities, UIs, and agent runtimes
```

Dependencies are one-way. A deployment defect may be reduced to a generic Core or Protocol fixture, but real business policy and data must not be copied upward.

## Current status and blocker

The repository contains a substantial applied-and-tested schema, retrieval, lifecycle, provenance, perimeter, and import framework. Exact feature and verification details remain in [STATUS.md](../STATUS.md); this page does not supersede them.

The load-bearing unresolved boundary is **non-forgeable per-request identity**. A shared service credential plus caller-supplied principal identifier provides accident prevention and attribution assertions, not enforceable human-versus-agent identity. Public issue #23 tracks that class of problem.

`jryski/Supabase_user_MCP` is the adjacent public data-plane project for preserving a verified user/client context through bounded MCP tools, a fixed Supabase API surface, and PostgreSQL RLS. Its read-only identity/RLS acceptance is not yet a production capability and must not be described as closing this repository's deployment gate.

## Agent Access Integrity Boundary

The protocol repository is exploring an informative **Agent Access Integrity Boundary** for establishing a forward evidence boundary before a novel agent receives access to an existing system in situ.

That concept is peer-reviewed but not principal-accepted or normative. It does not prove pre-boundary correctness or provenance. If eventually accepted, this repository could implement a transactional-relational deployment profile while keeping mechanism-specific SQL outside the portable protocol.

## Adjacent repositories

- `jryski/sovereign-memory-protocol`: implementation-neutral semantics and conformance.
- `jryski/sovereign-memory-core`: PostgreSQL reference runtime and adversarial harness.
- `jryski/Supabase_user_MCP`: bounded user/agent MCP data-plane capabilities.
- Private deployment-owned repositories separately preserve exact migration bodies and recovery/provider-exit evidence. Their names, topology, and contents are intentionally not part of this public orientation.

## Claim limits

- Passing schema tests is not proof of a production deployment's current state.
- A repository migration name is not proof that the same bytes were applied remotely.
- RLS is not a substitute for verified identity and does not govern every non-row privilege or service path.
- Retrieval projections, embeddings, summaries, and indexes are rebuildable derived state, not independent authority.
- No issue, PR, CI run, or peer review grants deployment, credential, production-data, or merge authority by itself.
