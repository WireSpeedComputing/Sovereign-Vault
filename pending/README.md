# pending/ — built but NOT approved, NOT applied

Migrations here are complete or partially complete artifacts awaiting an owner
decision. They are deliberately **not** in `sql/` because
`tests/replay_fresh_install.sh` globs `sql/*.sql`; filing an unapproved
migration there would make the replay harness prove something untrue about the
deployment.

Nothing in this directory has been applied to any deployment.

| File | Upstream | State |
|---|---|---|
| `B_retrieval_topology_ISSUE72.sql` | #72 | **Partial.** Part 1 (table + seed) dry-run tested. Part 2 (the `retrieve_context` envelope change) is a design note only — not written, not tested. |
| `C_retrieval_projection_refresh.sql` | — | **Complete, untested against a deployment.** Incremental per-row maintenance of the retrieval projection. Replay-tested only. |
| `D_scope_hierarchy.sql` | #45 | **Complete, replay-tested.** Declared containment for scopes — the separate change the prior identity review required. 14-case test matrix in `D_scope_hierarchy_TEST.sql`, all passing. Widens authority: read the review note in the header before applying. |

### Graduated

`A_wiki_supersession_ISSUE71.sql` was approved and applied as deployment
migration 37 on 2026-08-07. It now lives at `sql/24_wiki_supersession.sql`.
Upstream #71 is closed on this deployment.

## Before applying

Re-run the preflight; the dry runs were point-in-time and the database has
changed since.

For B: Part 2 must be built and tested first. Applying Part 1 alone creates a
topology table that nothing reads, which is harmless but achieves nothing.

For C: it replaces no existing object and adds triggers to `memories` and
`wiki_pages`. Confirm the deployment's projection is current (run
`refresh_retrieval_units()` once) *before* applying, or the triggers will
maintain a projection that was already stale — incremental maintenance corrects
nothing retroactively. See the file header.

## Why A includes a function

Upstream #71 describes the `UNIQUE(path)` constraint as the blocker. Verified
here that it is one of two: `enforce_bounded_status_transition` also rejects
wiki status changes, and its sanctioned-function list names only
`promote_memory` and `supersede_memory`, both memories-only. `wiki_pages` is
append-only in practice. Replacing the constraint alone would not have
restored supersession, so `supersede_wiki()` ships with it.

For D: this is a real widening of authority, not a refactor. Apply it, then add
child scopes one at a time and check `scope_effective_grants()` after each. A
scope tree built in one motion is a tree nobody reviewed. Note also that
`confers_descendants = false` on an intermediate does NOT seal a subtree — see
the header.
