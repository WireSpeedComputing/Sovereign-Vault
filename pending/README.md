# Candidate migrations

Files here are excluded from the cumulative `sql/*.sql` replay. Their presence
does not authorize application or describe a customer's deployment state.
Qualify the selected target, exact source, ownership, grants, rollback and
acceptance before applying a candidate.

| File | Source purpose | Integration state |
| --- | --- | --- |
| `D_scope_hierarchy.sql` | Explicit declared scope containment | Held design candidate; review authority widening before adoption |
| `D_scope_hierarchy_TEST.sql` | Synthetic hierarchy controls | Acceptance companion, not a migration |
| `F_agent_registry_integrity_BLOCKED.sql` | Agent-registry integrity candidate | Blocked candidate; read its preconditions |
| `F_agent_registry_integrity_TEST.sql` | Synthetic integrity controls | Acceptance companion, not a migration |

The additive business access candidates are available in
[PR #37](https://github.com/WireSpeedComputing/Sovereign-Vault/pull/37):

| Exact filename | Purpose | Application constraint |
| --- | --- | --- |
| `E_business_user_tools.sql` | Four request-bound tools, restrictive reads and immutable staged submissions | PostgreSQL 16/17 candidate; E alone denies canonical client reads until the live-session gate is qualified |
| `F_business_live_session.sql` | Actual Supabase live-session binding | Requires compatible Auth session metadata, reviewed client identity and session custody |

Use exact filenames and source digests. Letter prefixes are historical
organization labels, not a unique migration identifier or apply order.

## Related implemented patterns

Wiki supersession, retrieval topology, scope/visibility composition and projection
refresh are represented in `sql/24`, `sql/35`, `sql/36` and `sql/41`.
Those source locations do not establish their installation on any deployment.

## Application discipline

Capture target definitions and compare content, rather than migration names.
Dependency closure must be explicit. Refresh projections only through their
reviewed path, and test positive as well as denied access.

Scope containment can widen authority. Add reviewed containment and grants
deliberately; a scope's `confers_descendants` flag concerns its grant semantics,
not a universal subtree seal.

Keep source, index, tests and versioned integration instructions consistent.
Record actual deployment decisions and receipts privately.
