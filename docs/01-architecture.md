# Architecture

## Shared foundation and business adapters

The shared foundation governs identities, capabilities, knowledge, provenance,
history and bounded access. A business adapter supplies its own canonical
entities, source mappings and workflow policy. Optional domain modules in
`sql/` demonstrate patterns; they are not part of every business's policy.

A retail chain might track inventory adjustments and store operating notices.
A SaaS platform might track release evidence and support procedures. These are
synthetic illustrations of the same contracts, not descriptions of adopters.

## Identity and access contract

Resolve the authenticated human and application client from a verified request.
Bind external identities to internal principals through reviewed mappings and
intersect their capabilities. Never assume `auth.uid()` is an internal principal
ID and never accept a principal, role or grant from tool arguments.

Enable RLS, start with default-deny grants and review every exposed function.
Policies must compose ownership, visibility, scope and current lifecycle with
the request-derived authorization helpers. PostgreSQL combines permissive
policies with OR: use restrictive guards where every access path must satisfy
the same boundary. Administrative roles and SECURITY DEFINER ownership require
separate review.

The business access candidate narrows canonical reads with a live-session
gate and finite RPCs. See [its candidate contract](https://github.com/WireSpeedComputing/Sovereign-Vault/pull/37).
Do not copy a simplified policy example as a production authorization boundary.

## Contract for consequential domain records

1. Preserve source provenance and a locator that can be checked against an
   authorized source. A nonempty citation string alone does not prove evidence.
2. Distinguish observed time, effective interval and recorded time. Preserve the
   superseded record and link its successor.
3. Correct through a governed transition. Derive the actor from the request,
   lock and verify the exact current version, check scope and capability, preserve
   custody fields, and commit the old/new version changes atomically.
4. Separate a staged proposal from approval. An authorized review receipt binds
   to the exact proposed version and evidence version.
5. Keep direct canonical writes revoked for ordinary clients. Review INSERT,
   UPDATE, DELETE, TRUNCATE, ownership and function execution together.
6. Test visible and hidden records, wrong scopes, stale versions, replay,
   revocation and concurrent transitions. Run tests against the selected source
   profile and actual client boundary.

The generic provenance registry and lifecycle functions are implementation
references. Adding a new table also requires its own dependency, ownership and
RLS review; registering its name does not complete integration.

## Workflow intelligence

A trusted internal reader obtains authorized rows, expected/evaluated counts,
citations and exact versions in one consistent snapshot. Trusted server
configuration defines the workflow checks and severity floors. Stored record
text cannot add rules, lower severity, change authority or grant approval.

The deterministic reducer distinguishes blockers, missing information and
required human review. It has no model, network or write operation. Matching
scope fields in JSON is a consistency check, not authentication. A normal
application can perform the same workflow as an AI client.

## Deployment boundary

Keep customer principals, grants, source bindings, business policies and operating
receipts in private deployment systems. Keep portable schema, generic tool
contracts and clearly synthetic examples in the public platform.

An isolated replay proves only the selected source and test conditions.
Qualify identity-provider behavior, migration compatibility and all direct API
paths before a deployment. Shared administrative credentials remain control-plane
authority and cannot serve as ordinary user identity.
