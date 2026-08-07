# pending/ — built but NOT approved, NOT applied

Migrations here are complete or partially complete artifacts awaiting an owner
decision. They are deliberately **not** in `sql/` because
`tests/replay_fresh_install.sh` globs `sql/*.sql`; filing an unapproved
migration there would make the replay harness prove something untrue about the
deployment.

Nothing in this directory has been applied to any deployment.

| File | Upstream | State |
|---|---|---|
| `A_wiki_supersession_ISSUE71.sql` | #71 | **Complete.** Dry-run end-to-end against the live database in a rolled-back transaction, 2026-08-07. All assertions passed, zero residue. |
| `B_retrieval_topology_ISSUE72.sql` | #72 | **Partial.** Part 1 (table + seed) dry-run tested. Part 2 (the `retrieve_context` envelope change) is a design note only — not written, not tested. |

## Before applying either

Re-run the preflight; the dry runs were point-in-time and the database has
changed since.

For A: confirm `wiki_pages_path_key` still exists, that there are still zero
duplicate active paths, and that no new inbound FK references `path`. A is
reversible only while zero duplicate active paths exist — once two versions
share a path, the original `UNIQUE(path)` cannot be restored.

For B: Part 2 must be built and tested first. Applying Part 1 alone creates a
topology table that nothing reads, which is harmless but achieves nothing.

## Why A includes a function

Upstream #71 describes the `UNIQUE(path)` constraint as the blocker. Verified
here that it is one of two: `enforce_bounded_status_transition` also rejects
wiki status changes, and its sanctioned-function list names only
`promote_memory` and `supersede_memory`, both memories-only. `wiki_pages` is
append-only in practice. Replacing the constraint alone would not have
restored supersession, so `supersede_wiki()` ships with it.
