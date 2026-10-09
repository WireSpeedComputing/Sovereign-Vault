# Repository issue source index — 2026-08-07

> Source/fixture note: this document states portable contracts and test methods.
> It does not report a customer corpus, access configuration, or hosted execution.

The dated filename preserves the public issue-reference context. The entries
below identify source and acceptance work; they do not assert the present status
of an issue or any deployed database.

| Issue | Portable contract and source |
| --- | --- |
| #8 — engine parity | `tests/replay_fresh_install.sh`, `tests/verify_restore.sh`, and `tests/canonicalize_inventory.py` distinguish successful replay, name inventory, and definition equivalence. Record actual engine/extension versions per run. |
| #13 — review queue | `sql/09_review_queue.sql` retains proposed contradictions and links incoming/existing references. Verify a candidate cannot overwrite a current row. |
| #9 — connection identity | `sql/23_identity_capability_enforcement.sql` and `sql/25_public_request_has_capability.sql` separate request-derived identity from administrative assertions. The public invoker boundary must preserve request-role provenance. |
| #11 — policies consuming identity | `sql/36_rls_policies.sql` and `sql/37_rls_authenticated_select_and_lifecycle.sql` consume row visibility, scope, and lifecycle. Verify actual grants and composed policies on the target before adoption. |
| #2 — coordination channel | Decide whether the generic memory substrate or a separate coordination table fits the intended content and lifecycle. Classification on raw artifacts does not automatically classify a memory row. Use synthetic short and long messages for capacity tests. |
| #12 — directive provenance | `sql/03_provenance.sql` distinguishes provenance bases and citation presence. Actor identity, directive authority, and source resolution require separate evidence; non-empty prose is not a verified locator. |
| #10 — extension placement | Inspect `pg_extension`, schema placement, version, and extension-owned privileges on the intended target. `sql/28_perimeter_assert_signal.sql` separates owned exposures and declared exceptions from extension internals. |

## Acceptance discipline

- Build a complete synthetic fixture and require an authorized positive before
  interpreting any denial as evidence.
- Verify mapped human/client identity through an actual request-role boundary;
  fabricated administrative claims must fail closed.
- Enumerate policy, RPC, view, projection, boot, and export paths. Compare
  authorized canonical identifiers instead of treating one path as the whole
  perimeter.
- Keep direct runtime DML closed unless an explicit reviewed workflow requires
  it. A privileged operational credential is not a substitute for request identity.
- Record what was inspected, what was executed, and what remains unverified.
  Source files and issue dispositions alone do not establish hosted state.

## Public reference convention

The #58 reference associated with restore work is an upstream issue number.
Cross-repository issue links should use an explicit owner/repository qualifier
so the same local number does not silently refer to a different issue.
