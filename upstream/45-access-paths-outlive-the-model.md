# Cross-path authorization agreement for upstream #45

> Source/fixture note: this document states portable contracts and test methods.
> It does not report a customer corpus, access configuration, or hosted execution.

Authorization changes can leave older access paths enforcing a previous model.
A path that checks owner/visibility may omit scope or lifecycle, while another
path applies all four. Agreement must be verified across consumers.

Files referenced:

| file | role |
|---|---|
| `sql/36_rls_policies.sql` | scope wired into row-level policies; `can_read_row()` / `can_read_row_as_request()` |
| `sql/37_rls_authenticated_select_and_lifecycle.sql` | the table grant that made the policies reachable, and the lifecycle defect it exposed |
| `sql/32_session_boot.sql` | the first-call orientation surface, `SECURITY DEFINER`, owner/visibility only |
| `tests/36_rls_policies_TEST.sh` | end-to-end policy suite driven through real request identity |
| `tests/32_session_boot.sql` | boot-surface suite, sections A (positive controls) / B (denials) / C (legitimate path) |

## Lifecycle agreement

A table policy that applies owner, visibility, and scope but omits lifecycle can
return proposed, superseded, or rejected rows through the same door as current
facts. Compare the exact canonical identifiers returned by direct table reads
and governed retrieval for the same request identity. Commit to expected fixture
identifiers before execution; a plausibly scoped result is not enough.

## First-call and projection agreement

A `SECURITY DEFINER` boot or ranking function, including the first-call surface
discussed in #72, must explicitly consume the
current row-access predicate because ownership may bypass table RLS. Review
`sql/45_session_boot_scope_composition.sql` and each downstream caller rather
than assuming the table policy applies inside every definer. Derived projections
must resolve authorization against canonical source rows before ranking/LIMIT.

Proposed fixture: use two fabricated principals, two scopes, distinct grants,
current and non-current rows, and one deliberately scope-blind path. Every valid
path must agree on readable identifiers; the deliberately broken path must be
detected. Include an empty-entitlement principal and a successful authorized
receive control. This describes a test to run and claims no existing execution.

## The generalisable claim

**A conformance criterion that checks only the canonical read path will certify a system with three disagreeing ones.**

The failure mode is not a careless implementer. It is temporal: an authorization model gains a dimension, and every access path written before that moment silently continues to enforce the previous model. The paths do not break, do not error, and do not disagree loudly. They return plausible, well-formed, incorrect sets. Each one is individually defensible against the model as it stood on the day it was written.

This is why "the policy is correct" is the wrong unit of verification. The unit is *agreement across paths*.

## Suggested addition to this issue's acceptance criteria

Current criteria are `Schema/docs represent scope` / `Tests cover two distinct scopes` / `Cutover declaration is scope-bound` / `Stale/current truth cannot leak across scopes`. All four are satisfiable by a system with a scope-blind boot surface, because all four describe the scoped path. Suggested additions:

- [ ] **Enumerate every path that reads governed records** — row-level policies, `SECURITY DEFINER` functions, views, materialised or derived projections, orientation/boot surfaces, export and backup paths, retrieval and ranking surfaces — and record the enumeration as an artifact, not as a claim.
- [ ] **For a fixed principal and a fixed corpus, every enumerated path returns the same set of record identifiers**, or declares in machine-readable form which dimension it deliberately does not apply and why. Silence is not a declaration; a path that omits a dimension without declaring it fails.
- [ ] **The agreement assertion runs against at least two principals whose entitlements differ, including one whose entitlement on some dimension is empty.** Agreement among paths that all return everything to everyone proves nothing — see the companion note on positive controls.
- [ ] **The authorization model carries a version, and each access path records the model version it was written against.** Conformance fails when any path's recorded version is older than the current model. This is what turns "someone must remember to re-check" into a check.
- [ ] **The first surface a session calls is explicitly in scope.** It sets an agent's opening context for everything after it.
- [ ] **Derived projections are asserted to resolve authorization against the source row, not against their own copies of owner/visibility/scope.** A projection that carries denormalised access columns is a fifth path with a stale copy of the model in it.

The fourth bullet is the one we would most want in the spec. The first three catch the divergence once it exists. The fourth is the only one that catches it at the moment the model changes, which is the only moment at which the fix is one line.

Happy to contribute the cross-path agreement harness as a synthetic fixture — two principals, two scopes, one deliberately scope-blind path that the harness must catch — if that is useful here or in the offline verifier fixture.
