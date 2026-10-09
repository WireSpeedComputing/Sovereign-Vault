# Business capability candidate

This is implementation source for review and isolated acceptance. The migration
in `pending/E_business_user_tools.sql` is not a statement of deployed state.
Engineering work: [#36](https://github.com/WireSpeedComputing/Sovereign-Vault/issues/36).
Related boundary and verification work: [#23](https://github.com/WireSpeedComputing/Sovereign-Vault/issues/23),
[#24](https://github.com/WireSpeedComputing/Sovereign-Vault/issues/24), and the
existing review handoff in [PR #27](https://github.com/WireSpeedComputing/Sovereign-Vault/pull/27).
The team/client profile belongs to
[User MCP #85](https://github.com/jryski/Supabase_user_MCP/issues/85).

## Platform responsibilities

The platform resolves the authenticated human and OAuth client, intersects their
scope permissions, filters current records, validates arguments, stages writes,
and records exact retry receipts. A model never selects a database, SQL function,
principal, role, or grant. The same fixed dispatcher can serve an ordinary
application, a small model, or a frontier model.

The readiness reducer performs bounded evidence and coverage checks without an
inference provider. It identifies blockers and missing information. It does not
approve publication or manufacture an approval from a clean findings list.
Stored text is untrusted evidence. It cannot change the caller's authority or
the dispatcher configuration.

## Source ownership

| Concern | Owning source | Integration responsibility |
| --- | --- | --- |
| Canonical records, RLS and staged-write receipts | `pending/E_business_user_tools.sql` | Business database owner |
| Live session and direct API read boundary | `pending/F_business_live_session.sql` | Business database/access-plane owners |
| Fixed tools and bounded responses | `contrib/business-platform/business-tools.mjs` | User MCP runtime owner |
| Deterministic evidence/readiness outcomes | `contrib/business-platform/business-readiness.mjs` | Business workflow owner |
| OAuth, upstream session validation and durable credential custody | User MCP runtime | Access-plane owner |
| Bindings, grants, sources and business approvals | Authorized deployment data plane | Authorized business administrators/reviewers |

Names in the last two rows are responsibilities, not automatic privileges.
Deployment principals and actual people belong in the authorized work/data
surfaces, not in this template.

## Fixed access contract

| Tool | Public RPC, with one `p_input jsonb` argument |
| --- | --- |
| `memory_search` | `authorized_business_memory_search_v1` |
| `memory_get` | `authorized_business_memory_get_v1` |
| `memory_append_observation` | `authorized_business_memory_append_observation_v1` |
| `memory_propose_change` | `authorized_business_memory_propose_change_v1` |

The registry is `BUSINESS_MCP_TOOLS`. Create a dispatcher with
`createBusinessToolDispatcher({ invokeRpc })`; supply a server-owned transport
that uses the authenticated user's Data API credential, validates the upstream
session, respects cancellation, and classifies failures with
`classifyBusinessRpcFailure`. The dispatcher sends only these four fixed RPCs
in `public`, with `{ p_input: validatedArguments }`. The transport configuration
and credential must never come from tool arguments. Register this exact registry
and call `dispatcher.callTool(name, arguments, { signal })` from MCP or a normal
application. Successful results expose `structuredContent.data`; every result
also carries the security-boundary warning.

Search covers current canonical memories and wiki pages, with deterministic
lexical ranking and question-token fallback. It reports its searched coverage,
truncation and remaining results. Get returns the exact content SHA-256 version
and provenance. Writes stage immutable evidence; retain the returned receipt
and replay identical input with the same key after an uncertain response.
Changed input requires a new key. There is no approval or promotion tool.

The bounded dispatcher permits four outstanding provider calls and a five-second
deadline. Request, provider-response and wrapped-result budgets are separate;
see `BUSINESS_TOOL_LIMITS`. Provider errors are classified by fixed codes, never
copied into stored evidence or represented as a missing record.

E adds `AS RESTRICTIVE` authenticated SELECT policies to both canonical tables.
They require the public no-argument boolean
`authorized_business_session_active_v1()` in addition to the existing row
predicates. The restrictive expressions explicitly require current status and
the composed owner/visibility plus human/client row predicate. The finite
runtime role also has restrictive current/row guards alongside its permissive
read enablement. An unrelated permissive PUBLIC policy cannot widen either
of these two canonical read paths. F binds the session gate to the actual
`auth.sessions` row, subject,
OAuth client and validity period. This narrows direct Data API reads as well as
the RPC profile: native clients need reviewed identity/client mappings and a
qualified client-bound session. Review those clients before applying E/F.
E alone denies these reads until the live-session gate is installed. Neither
candidate grants authenticated callers canonical DML or private-schema access.

## Deployment sequence

1. Verify the actual business repository, deployed source revision, database
   schema and runtime owner. Compare function bodies and table shapes, not just
   migration names. This candidate expects the canonical Sovereign Vault schema;
   an unrelated store is not a compatible target.
2. Reproduce the positive and denied paths in an isolated deployment using
   synthetic records and reviewed synthetic bindings. Reuse the existing
   identity/capability composition; do not expose privileged reporting RPCs to
   clients to make a test pass.
3. Configure a dedicated business OAuth application and a fixed business
   profile. Validate issuer, audience/resource, client and authenticated human.
   Check token expiry and the live upstream session, including revocation,
   before every operation. Never reuse another domain's client or credentials.
4. Review the additive migration, non-bypass role ownership, RLS, grants and
   private-schema exposure. Capture a restore point and exact rollback plan.
   Use the migration mechanism, not raw SQL execution, for hosted DDL.
5. Activate only the reviewed bindings and named scope grants. Install the
   fixed tools against the user's upstream token. Register the same signatures
   and descriptions that were tested; do not let the caller select RPCs.
6. Run real-client search → exact get → staged write → replay → readback, plus
   cross-user, cross-team, denied-client and revoked-session controls. Prove the
   direct API reaches RLS and is denied on writes. Anonymous failure alone is
   insufficient.
7. Add a request-bound, same-snapshot reader for business claim/evidence
   reports before wiring the readiness reducer to live data. The existing
   privileged audit functions stay private. Capture expected/evaluated counts,
   versions, coverage gaps and review receipts. A partial report must remain
   partial.

## Acceptance and limits

The JavaScript modules require no inference provider. Only the isolated SQL
fixtures require a test runtime. From a fresh checkout on a POSIX test host:

```sh
test_runtime=$(mktemp -d)
npm install --prefix "$test_runtime" --no-save @electric-sql/pglite@0.2.16
export BUSINESS_PGLITE_MODULE="$test_runtime/node_modules/@electric-sql/pglite/dist/index.js"
node tests/64_business_user_tools.mjs
node --experimental-test-isolation=none --test \
  tests/business-tools.test.mjs tests/business-client.test.mjs \
  tests/business-readiness.test.mjs
```

On Windows, set `BUSINESS_PGLITE_MODULE` to an absolute `file:///` URL for the
same installed module. The test fixture accepts an explicit runtime module and
does not depend on a developer's cache. The fixture reports its database version;
PGlite 0.2.16 exercises PostgreSQL 16.4, so separate PostgreSQL 17 acceptance is
required before a PostgreSQL 17 deployment. The ordinary-client suite executes
the real SQL search/get/staged-write/replay/readback path without a model.

For actual PostgreSQL 17, prepare the official `postgres:17` image locally and
run `bash tests/business-pg17-acceptance.sh` on a host with Node and Docker.
This generates the same synthetic identity/RLS slice, installs E/F with a
non-superuser migration controller, and checks read/replay/direct-read revocation.
Three separate-session controls verify bounded target-lock contention,
same-key write contention, and the proposal's SHARE lock against a competing
canonical update. Adversarial PUBLIC read policies and hidden scope/private/
lifecycle fixtures verify that unrelated permissive policies cannot widen the
candidate RPC or direct reads. The container has no network or host ports, uses temporary
data, and is removed when the run finishes. This is candidate-slice acceptance,
not a complete-schema replay or proof of a live OAuth client.

Positive controls pin known visible records and exact versions. Negative
controls cover hidden records, cross-scope access, unbound or revoked clients,
expired/deleted sessions, stale and unchanged corrections, direct canonical
writes, and malformed input. NULL tag elements are omitted in the read
projection while remaining values and their order are preserved.

Tests use synthetic records and execute the candidate boundary in an isolated
database. They do not establish live OAuth, complete-schema replay, migration
compatibility with a particular business deployment, or responsible human
approval of business assets.

Use `createBusinessReadinessReducer` only with a trusted, request-bound internal
reader result. Matching a principal in JSON is not authentication. Its input is
`business_readiness_snapshot_v1`, with four explicit check families
(`claim_catalogue`, `claim_evidence`, `finished_copy`, `launch_assets`), expected
and evaluated counts, findings, versioned source references and exact assets.
The reducer has no database, provider or write operation. It returns `blocked`,
`unknown`, or `human_review_required`; it never returns an approval. Do not
expose this snapshot as caller-supplied tool arguments.

Staged observations and change requests do not become canonical truth. Review
and promotion are a separate capability. A correction must cite the expected
current version; a stale or hidden target cannot be overwritten. A script can
carry out this workflow with zero model calls, but publishing consequential
content still requires an authorized approval bound to the exact asset version.

For long-lived sessions, retain durable encrypted grant/signing state and
refresh upstream credentials through the qualified broker. Avoid routine local
idle/absolute expiry where policy permits. Explicit revocation, expiry imposed
by the upstream identity provider, or failed session validation must still
remove authority.

## Public signature discipline

The candidate adds versioned tools/RPCs; it does not replace the public
administrative retrieval signature. Update the private runtime configuration,
tool registry and operating instructions together after deployment. Record the
exact source and migration digests in the private release receipt. See
`docs/08-contract-version-and-drift.md` and
`docs/09-apply-runbook-propose-then-promote.md` for existing contract and
application guidance; their historical status notes require fresh verification.
