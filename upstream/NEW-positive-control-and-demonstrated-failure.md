# Conformance criteria must require a positive control and a demonstrated failure

## Summary

Two failure shapes, opposite in form and identical in consequence:

1. **A criterion stated only as a denial is satisfied by a system that grants nothing to anyone.** "An unauthorized principal is denied" is true of a correctly-configured deployment and equally true of one where the identity path is broken, the grant never resolved, or the request never reached the thing under test.
2. **A check that cannot fail on the host it is running on reports success.** A check filtered on host-specific identifiers matches nothing on a host that lacks them, returns an empty result, and an empty result is the same shape as a clean one.

Both are certifiable. A conformance suite built from denial criteria and "does it run" will pass a system that enforces nothing and a check that verifies nothing, and it will pass them green.

This is a protocol-level requirement about the *shape* of criteria, not an implementation bug report. It is the companion to #74: that issue documents three-valued logic disabling assertions from underneath; this one documents assertions that were never capable of failing in the first place. Same outcome — a green suite that is evidence of nothing — reached without any NULL being involved.

## Shape 1 — denial-only criteria

### Proposed synthetic controls

In a fabricated two-principal/two-scope fixture, deliberately omit a required
identity-binding review field. Fixture creation must abort. If a broken harness
continues, every denial can pass because neither principal resolves. A valid
fixture must first show each principal receives its own expected row.

Separately revoke the fixture runtime's table SELECT privilege. The suite must
distinguish a privilege error from a row-policy denial; a request that never
reaches RLS cannot prove that RLS discriminates. The source paths are
`tests/36_rls_policies_TEST.sh` and
`sql/37_rls_authenticated_select_and_lifecycle.sql`.

These are deliberately broken fixture designs, not renamed deployment events
and not claims that the controls were executed.

### What fixed it

A positive control that runs **first** and gates the rest — in that file it is literally `SECTION 0: the harness can see anything at all`. One assertion — an authorized principal sees the one record they are unambiguously entitled to — placed ahead of every denial. Plus: fixture construction failure aborts the run rather than proceeding, because a partially-built fixture produces denials indistinguishable from a working deny-all. The same discipline appears as sections A (positive controls) and C (legitimate path) bracketing section B (denials) in the SQL suites.

Stated as a rule: **a denial result is only evidence if a grant result from the same fixture, in the same run, succeeded.**

## Shape 2 — checks that cannot fail

The inversion: a perimeter checker can filter on platform-specific role names,
extension names, or another host assumption without first confirming its scope.
`sql/28_perimeter_assert_signal.sql` is the relevant source surface to review.

A proposed synthetic control removes a required fixture role or host object and
requires an explicit unsupported/error outcome. If a checker instead filters on
the absent identifier, it may return zero findings while evaluating nothing.
The ordinary configured-host fixture must still pass. This is a method to run,
not an account of a hosted or local operational incident.

The general principle, and the reason this belongs in the spec rather than in a lint:

**Portability failures that produce ERRORS are safe, because they are visible. Portability failures that produce SILENCE are the dangerous class.** A conformance suite that only establishes "does it run on this host" will certify the silent ones. It will certify them most reliably on the hosts that differ most from the author's, which is the entire population the conformance suite exists to serve.

The same shape covers checks filtered on extension names, schema names, platform default privileges, or any identifier that is present in the author's environment by accident.

## Why denial-only and run-only criteria keep getting written

Because they are the honest instinct. Fail-closed is the right default and a denial test is the direct expression of it. The error is treating the denial as *sufficient*. A system that has failed closed on everything — broken identity, empty grants, unreachable policies, a check that matched nothing — is indistinguishable from a correct one under a suite that only asks what is refused.

This matters more for a custody protocol than for most software, because the whole value proposition is a claim about what a system will not do. A suite that cannot distinguish "will not do the wrong thing" from "will not do anything" cannot support that claim.

## A literal verdict is not an assertion result

A deliberately broken synthetic runner can print:

```sql
SELECT 'SUITE_RESULT: PASS' AS verdict;
```

If the consumer reads only that literal, false or NULL assertions cannot change
the verdict. A proposed mutation control replaces the protected predicate with
a known-broken version and requires the complete runner to fail for that cause.
The test must execute the mutation; a comment describing how to falsify it is
not execution evidence.

Likewise, a runner that prints unrecognized verdicts without counting them must
report incomplete coverage. An unresolved, unsupported, or skipped check cannot
be absorbed into an all-pass result. This is a generic runner contract, not an
incident report or a statement about an adopter's corpus.

## Proposed conformance criteria

- [ ] **Every denial criterion is paired with a grant criterion, in the same suite and against the same fixture.** An authorized principal is shown to *receive* exactly what they are entitled to. Where the spec states a criterion as "X must be rejected", it also states "Y must be accepted" over the same fixture.
- [ ] **The grant criteria gate the denial criteria.** A run whose positive controls fail must not report its denial results as evidence, and must not report conformance. Ordering is part of the requirement: positive controls run first.
- [ ] **Fixture construction failure aborts the run.** A suite that proceeds on a partially-constructed fixture reports denials that cannot be distinguished from a broken harness.
- [ ] **Every check ships with a deliberately broken input against which it is demonstrated to fail, and the conformance run executes that demonstration.** A gate that has never failed is evidence of nothing. This generalises the criterion already present in #40 — *synthetic regression cases fail for the intended reason* — from public-safety scanning to every check in the suite.
- [ ] **A check that fails for the wrong reason is a failure.** "Something went red" is not the same as "the check that owns this condition works". Where practical, each corruption case names the check expected to catch it.
- [ ] **Checks that filter on host-specific identifiers declare those identifiers and assert their presence before filtering.** Absence is a hard error, never an empty result. A check whose scope is empty on the current host reports UNSUPPORTED, not PASS.
- [ ] **Skipped checks are reported as SKIPPED, and any run containing a skip cannot report full conformance.** Exit status must distinguish *all defined criteria passed* from *all criteria that ran passed*.
- [ ] **The suite reports coverage separately from result**: criteria defined, criteria evaluated, criteria passed. Three numbers, always, so that a suite going quiet is visible as a drop in the second number rather than as continued success in the third.

## Relation to the offline verifier fixture (#48)

If a fixture is going to be the portable artifact by which third parties judge conformance, these constraints apply to it directly. Suggested additions to that fixture's contents:

- at least one **authorized-receive** case alongside the existing conflict / stale / held / excluded cases, so a verifier that denies everything fails the fixture rather than passing it;
- at least one case that exercises the verifier on a host **lacking** any platform-specific role, extension or default-privilege assumption, with the expected outcome being an explicit UNSUPPORTED rather than a pass;
- a declared expected-failure case: a fixture variant the verifier **must** reject, so that a verifier which reports SMP-complete unconditionally is detectable by running it.

Happy to contribute the positive-control ordering pattern, the coverage-vs-result reporting shape, and a synthetic host-identifier regression case if useful.
