# User-scoped MCP implementation handoff

Reference baseline: `530f891b2fcbe57afd88c1edb5f5eb7cf0bb24df`.
Prepared September 8, 2026. This is implementation guidance, not an applied
migration, a deployment audit, or an enterprise-readiness claim.

This document transfers reusable lessons from the
[User MCP project](https://github.com/jryski/Supabase_user_MCP). Adopt the
authorization and test patterns deliberately. Do not synchronize the personal
and business schemas, import a household role model, or copy deployment data.
The repository's **schema in the repo, data in the database** rule applies to
issue and PR bodies as well as files.

## First decision: establish verified request identity

Sovereign Vault already has principals, capability grants, provenance,
owner/visibility rules, lifecycle transitions, and governed retrieval. Reuse
those concepts. The open identity and capability-enforcement work in
[STATUS](../STATUS.md#known-open-risks) remains the first delivery gate.

An allowed request should satisfy:

```text
verified identity AND active principal AND permitted client
AND correct deployment/store boundary AND active capability
AND current resource visibility AND permitted operation
```

Choose and document one trusted identity path before exposing user tools:

- For Supabase Auth, resolve the verified issuer/subject to `principals.id`.
  Do not assume existing principal UUIDs equal Auth UUIDs. An email or display
  name is not an authorization key. `external_ref` alone is not a verified
  identity-mapping implementation.
- A gateway may use a shared connection pool, but every request must carry
  independently verified identity which the client cannot forge. Define how
  the database trusts that context, including audience, issuer, expiry,
  replay handling, and key rotation where signed assertions are used.
- A separately provisioned database-role approach is another option if the
  deployment can manage role lifecycle and least privilege. Record the
  operational tradeoff rather than combining incompatible approaches.

Do not expose a caller-selected principal UUID, editable user metadata, or an
arbitrary SQL session setting as proof of identity. An agent's delegated
authority is the intersection of its client's grant and the represented
principal's access. Workload identity must have an accountable owner.

## Map the existing schema before adding new tables

| Existing surface | Implementation requirement |
| --- | --- |
| `principals` | Verify identity binding and enforce active/deactivated state on every relevant path. |
| `capability_grants` / `has_capability()` | Define scope semantics, expiry, revocation, grant authority, and actual policy/RPC enforcement. Rows recording grants do not enforce them by themselves. |
| `owner`, `visibility` | Define the business meaning of shared and private. Owner orientation is not a complete tenant model. Do not assume shared means every customer or workspace. |
| `memories`, `wiki_pages`, domain tables | Inventory effective table grants, RLS, mutation rules, and downstream consumers. |
| Lifecycle transition RPCs | Preserve concurrency protection, provenance, and actor-custody labels until authenticated attribution is actually implemented. |
| Retrieval / hot index / deadlines | Apply the same visibility contract to content, locators, rankings, counts, and derived outputs. Define permission-change and cache-freshness behavior. |
| Grant audit and schema changelog | Attribute actions through the trusted identity path; avoid tokens and unnecessary record content in logs. |

`has_capability()` currently compares scope strings exactly. Examples such as
`table:*` and `workstream:*` in onboarding material must not be interpreted as
implemented wildcard expansion. Decide and test scope matching explicitly.
Do not mass-grant access to make an example policy run: table privileges and
RLS policies are separate gates.

## Delivery sequence and ownership

The role names below describe responsibilities, not deployment principals.
Record actual owners, assignments, project references, grants, and findings
in private deployment records. An implementation assistant cannot approve
its own privilege expansion; an independent reviewer should not silently
change policy while assessing it.

| Order | Responsible role | Deliverable | Exit evidence |
| --- | --- | --- | --- |
| 1 | Implementation owner + deployment owner | Exact deployed revision, schema/access-path inventory, identity decision, dependency map | Metadata-only inventory reconciled to source; unknowns listed; private findings routed appropriately |
| 2 | Business owner | Actor/client/store/resource/action matrix, sensitivity and sharing decisions | Explicit approval of the proposed access model; no invented business roles |
| 3 | Implementation owner | One low-sensitivity read operation behind verified identity and least privilege | Isolated replay, narrowly scoped migration proposal, positive/negative tests, rollback plan |
| 4 | Independent review owner | Adversarial API/MCP and client acceptance review | Actual tool events and database-role tests tied to the candidate commit; findings and retest results |
| 5 | Deployment owner | Canary and release decision | Recovery proven for that deployment; review accepted; unresolved risks explicitly assessed |

Start with one read-only domain workflow. The User MCP pilot demonstrates a
three-read-tool pattern; it does not supply business write capabilities or
establish compatibility with every Sovereign Vault RPC. Build an explicit
adapter with fixed operations and validated inputs. Do not expose arbitrary
SQL, table names, RPC names, URLs, grant editing, or schema administration.

Keep the administration MCP in a separate maintenance session with separate
credentials and project scope. Merely telling a model to prefer the data
connector is insufficient. A denied request must never trigger an automatic
retry through an administrative connection.

## Policy and access-path review

Inventory tables, views, function execution grants and owners, Storage,
Realtime, Edge Functions, background jobs, direct database connections,
exports, search projections, and caches. Check both intended access and
alternate paths under the actual application role.

Use `USING` for row visibility and `WITH CHECK` for proposed row values;
updates need both. Protect tenant/owner reassignment separately. Examine
existing permissive-policy composition before adding policies. Prefer
invoker semantics; justify each elevated function, qualify names, constrain
its search path, and grant only required execution rights. RLS does not
neutralize a superuser or a BYPASSRLS credential.

Map these requirements to current
[Supabase RLS guidance](https://supabase.com/docs/guides/database/postgres/row-level-security),
[function security guidance](https://supabase.com/docs/guides/database/functions),
and [API security guidance](https://supabase.com/docs/guides/api/securing-your-api).
Keep direct-API and non-PostgREST paths in scope; a gateway-only check is not
evidence that every route enforces the same rule.

## Required acceptance cases

Use synthetic principals, resources, and clients. Prove that the denied
fixture exists through a separate authorized control; a missing row alone
does not prove isolation. Tests must assert results and fail nonzero when an
assertion fails, rather than merely print a `false` column.

| Case | Required result |
| --- | --- |
| Authorized principal, correct client and store | Permitted bounded read |
| Other principal's private fixture | No content or existence disclosure outside the documented contract |
| Wrong issuer, client, or deployment; missing identity | Denied |
| Deactivated principal; expired/revoked membership or capability | Denied at the documented enforcement boundary |
| List, direct read, search, counts, rank, exports, derived data | Consistent visibility |
| Permission changes and cached sessions/results | No access beyond the documented revocation boundary |
| Owner/tenant reassignment and grant editing | Denied unless separately authorized and audited |
| Authorization service unavailable | Fail closed; no unlimited cached grant |
| Injection requesting administrative fallback | Administrative tool absent or denied; no credential escalation |
| Concurrent lifecycle operations | No lost transition, forked successor, or unaudited mutation |
| Empty or unavailable retrieval | Accurate status; no fabricated successful evaluation |

Document revocation timing, including requests already in progress. Fresh
request denial alone does not prove cancellation of in-flight work. Measure
policy query performance under representative data volumes and the actual
application role; synthetic correctness tests are not a scale benchmark.

## Client acceptance and credit use

Test each supported interface separately: Claude Code CLI, Claude Desktop
Chat, Cowork, and cloud connectors are distinct integration paths. A local
stdio bridge may suit Desktop Chat; cloud connectors cannot reach a
loopback-only service on a user's computer. Match OAuth callback host, path,
port, and resource exactly. Pin the bridge version and keep token caches
private; do not place service-role keys or login passwords in model prompts.

Use a low-cost model with extended reasoning off for bounded connector
checks. Inspect tool cards/events rather than pay for repeated narrative
reviews. Capture the actual model and effort used for each run; changing the
model later does not alter earlier evidence or billing.

The acceptance receipt must identify the source commit, migration content,
client/version, transport, authentication method, tools present and absent,
fixture controls, actual calls, expected and actual outcomes, limitations,
and reviewer. Keep deployment identifiers and raw private logs outside this
repository. Publish only a sanitized statement supported by retained evidence.

## Ready-to-use task briefs

**Implementation owner:** Read this handoff, STATUS, and the private deployment
inventory. Return the verified identity decision, schema-to-policy mapping,
one bounded read workflow, dependency-aware migration proposal, synthetic
tests, and recovery/rollback evidence. Separate implemented, locally tested,
deployed, and unverified claims. Stop if identity, tenant ownership, recovery,
or deployment revision is unknown. Do not expand production grants to pass a
demo.

**Independent review owner:** Review the exact proposed revision and privately
held deployment mapping. Check effective roles and every callable path;
execute positive and negative tests, including direct API and actual client
behavior. Return findings with reproducible synthetic evidence and a
release recommendation. Use private vulnerability reporting for sensitive
details. Do not certify enterprise readiness from test counts or an AI review
alone.

**Deployment owner:** Resolve the private roster, business sharing rules,
client approvals, and revocation target. Ensure the implementation and
review owners have explicitly acknowledged their tasks and evidence. Approve
the reviewed canary only after recovery and rollback are demonstrated for
this deployment. Expand by domain after observation, with writes reviewed as
a separate capability.

## Reporting and progress

Use a public PR for generic schema and documentation proposals, with no real
deployment identifiers or incident details. Use the repository's
[private vulnerability report form](https://github.com/WireSpeedComputing/Sovereign-Vault/security/advisories/new)
for sensitive findings. Private reports may later be published by maintainers,
so omit credentials and real business rows even there. If the private channel
is unavailable, retain the report privately; do not fall back to a public issue.

A task handoff is delivered when its artifact is accessible; it is accepted
when the named private owner acknowledges it; it is complete only when its
exit evidence passes. A PR or advisory alone does not launch an agent or
prove that a live migration was applied.
