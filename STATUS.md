# Source status

This file describes reusable source and validation boundaries. It is not an
inventory of a customer's database, adoption timeline or operating condition.
Deployment receipts and incidents belong in private operations records.

## Implementation inventory

The cumulative `sql/` directory contains the knowledge foundation, identity
bindings, capability composition, RLS, lifecycle transitions, provenance,
import governance, retrieval, tasks and optional domain modules. File numbering
is a source organization convention, not an applied migration ledger.

Optional supplier, claim, evidence and compliance modules illustrate domain
integration. Their presence does not establish the purpose of any adopter.
A minimal installation must use an explicit dependency-closed profile; skipping
a few domain filenames in the cumulative replay can leave broken references.

The `pending/` directory contains unapplied candidates. In particular, the
business access work is documented in
[PR #37](https://github.com/WireSpeedComputing/Sovereign-Vault/pull/37).
It adds fixed request-bound memory tools, staged submissions, restrictive
canonical read guards and a live-session gate. Its deterministic readiness
reducer uses trusted workflow policy, rather than a built-in industry taxonomy.
Its explicit core manifest and whole-profile acceptance are part of that candidate;
the cumulative replay is a separate installation path.

## Reproducible checks

- `tests/replay_fresh_install.sh` exercises the cumulative schema on a
  disposable database with the required extensions. It includes optional
  domain modules.
- SQL tests and isolated business acceptance use synthetic fixtures and explicit
  positive and denied controls.
- The business candidate includes a model-free ordinary-client workflow and
  a separate PostgreSQL 17 acceptance harness. Read its documented scope before
  interpreting a pass.
- `perimeter_report()` reports evaluation status and violations together.
  A zero count from an unevaluated host is not an acceptance result.
- `contrib/rule0-sweep.generic.sh` checks configured patterns in source and
  history. Human review separately covers deployment prose and public tracker
  surfaces.

Exact tested revisions, commands, supported runtime versions and results belong
in the corresponding change's review receipt. A prior pass does not certify a
later revision.

## Deployment qualification

Source acceptance does not prove live OAuth, correct client bindings, a compatible
existing schema, an upgrade path, complete business evidence or human approval.
Check these against the actual private target before rollout.

Client paths must use verified request identity and finite capabilities.
Administrative credentials bypass ordinary RLS and must remain private.
Record lifecycle and provenance checks do not make a shared administrative
connection attributable to a human.

Domain adapters must obtain authorized rows, counts, source versions and
deliverable versions consistently. Missing coverage remains unknown. A clean
findings list is not an approval receipt. The platform requires a separate,
authorized transition for promotion or consequential action.

Current customer state, private defects, source inventories and usage reports
are intentionally absent from this public file. Maintainers preserve those
records in the appropriate private deployment system.
