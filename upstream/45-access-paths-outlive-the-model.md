Following the comment above. Having wired the capability model into a real read path — scope narrows visibility — we went looking for paths that were written *before* the model had a scope dimension.

Two of them, found the same day. Neither was written carelessly. **Both were correct when written and became wrong when the model beneath them gained a dimension.** That is the finding, and it suggests this issue's acceptance criteria are one clause short.

Files referenced:

| file | role |
|---|---|
| `sql/36_rls_policies.sql` | scope wired into row-level policies; `can_read_row()` / `can_read_row_as_request()` |
| `sql/37_rls_authenticated_select_and_lifecycle.sql` | the table grant that made the policies reachable, and the lifecycle defect it exposed |
| `sql/32_session_boot.sql` | the first-call orientation surface, `SECURITY DEFINER`, owner/visibility only |
| `tests/36_rls_policies_TEST.sh` | end-to-end policy suite driven through real request identity |
| `tests/32_session_boot.sql` | boot-surface suite, sections A (positive controls) / B (denials) / C (legitimate path) |

## Instance (a): the policy gated scope and visibility, but not lifecycle

With a real token and a grant on exactly one scope, the row-level policies returned a larger set than governed retrieval returned for the same principal. The difference was entirely records at the candidate status — the holding state for imported material and agent claims awaiting human promotion.

The policies were written against owner, visibility and scope. They were correct on all three. Lifecycle was a fourth dimension that the retrieval function applied and the policy did not, so the same principal with the same grant got different answers depending on which door they used — and a consuming model holding the result cannot tell which door it came through.

Two aggravations worth stating:

- The candidate status is not the only unfiltered one. `superseded` is corrected truth served as though current, and the explicitly-rejected status (wrong-domain imports, out-of-scope personal material, obsolete directives) would also have been served. Nothing in that last class happened to be in scope that day. That is luck, not a control.
- **Serving candidates through the same door as accepted fact defeats the promotion model entirely.** The governance layer was exhibiting the exact defect class it exists to prevent.

The method matters more than the fix, so: the expected counts were written down **before** the run. A correctly-scoped result looks like success. Committing to a number beforehand is what turned a plausible result into a failed assertion. Third finding from that technique in one day.

## Instance (b): the first surface a session calls is the one that ignores scope

This deployment has a first-call orientation surface — the boot envelope #72 asks for. It is `SECURITY DEFINER`, it admits or rejects the principal, and it applies the owner/visibility predicate to every block it returns.

It never consults capability at all.

Its own header comment says, in as many words, that content is filtered by the owner/visibility predicate only — *no second authorization path* — and explains that a second authorization path is how two surfaces end up disagreeing about who may see what. That reasoning was right. It was also written before scope was wired into anything, and the comment is now a description of the defect.

Measured live, read-only, against the active principals:

| | boot surface | scope-aware predicate |
|---|---|---|
| principals receiving the full readable set | 8 of 8 | 3 of 8 |
| principals receiving nothing | 0 of 8 | 5 of 8 |

**Live disagreement on 5 of 8 active principals.** The three that agree are the ones holding broad grants; the model is invisible on exactly the principals it was introduced for.

The severity is not the count. It is *which* path disagrees. A principal's opening context — the thing an agent reads before it does anything else, the thing that frames every subsequent decision in the session — is assembled by the one path that does not know scopes exist. A narrow-scope principal is handed a full-corpus orientation and then queries through a correctly-scoped door for the rest of the session. Nothing in the session ever reports a contradiction.

The fix in our case is one predicate substitution: `sql/36_rls_policies.sql` already defines `can_read_row(owner, visibility, workstream, principal_id)` — an explicit-principal, scope-aware predicate written specifically for definer functions to call — and the boot surface simply predates it. The cheapness of the fix is the point. Nothing here required a redesign; it required *knowing the path existed*.

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
- [ ] **The first surface a session calls is explicitly in scope.** Ours was not, and it is the surface that sets an agent's opening context for everything after it.
- [ ] **Derived projections are asserted to resolve authorization against the source row, not against their own copies of owner/visibility/scope.** A projection that carries denormalised access columns is a fifth path with a stale copy of the model in it.

The fourth bullet is the one we would most want in the spec. The first three catch the divergence once it exists. The fourth is the only one that catches it at the moment the model changes, which is the only moment at which the fix is one line.

Happy to contribute the cross-path agreement harness as a synthetic fixture — two principals, two scopes, one deliberately scope-blind path that the harness must catch — if that is useful here or in the offline verifier fixture.
