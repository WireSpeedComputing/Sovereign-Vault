# Actionable checker contracts for upstream #40

> Source/fixture note: this document states portable contracts and test methods.
> It does not report a customer corpus, access configuration, or hosted execution.

A checker needs both sensitivity and a bounded, reviewable signal. A large
set of expected findings can hide a consequential exposure; an empty result can
also mean the host lacked the objects or roles the checker intended to inspect.

## Source mechanism

`sql/28_perimeter_assert_signal.sql` refines the perimeter assertion in
`sql/05_perimeter_assert.sql`:

1. Extension-owned objects are identifiable through `pg_depend.deptype = 'e'`.
   Compare repository-owned exposures separately from host extension internals;
   exclusion from this report does not itself approve an extension's privileges.
2. Deliberate exposures are declared records with object identity, grantee,
   reason, and timestamp. Match the full reviewed signature, including named
   parameters; do not silently authorize another overload or changed signature.
3. Review declared exceptions independently, including stale entries. Presence
   of a grant is different from correctness of the RLS or function behind it.

Private publication-sweep patterns belong in an external configuration, while
the reusable checker and fabricated examples remain public. Hard identifiers
and ordinary-word names need different matching rules to avoid both misses and
unactionable false positives.

## Proposed synthetic acceptance method

- Confirm required host roles exist before interpreting a zero-row perimeter
  result. Missing assumptions are unsupported/error states, not a clean result.
- Plant one unauthorized repository-owned exposure that must be reported.
- Include an extension-owned object and an ordinary shell keyword that must
  not be misclassified by their respective checker rules.
- Declare one exact reviewed signature, plus an unreviewed overload. Only the
  exact declaration may suppress a finding.
- Remove a required row guard behind a declared SELECT exception. The composed
  authorization check must fail even if the grant-presence report is unchanged.
- Record engine, extension, role/default-privilege profile, source revision,
  evaluated cases, and outcomes. Local host defaults do not establish hosted
  defaults.

These are proposed checks, not operational counts or a claim of execution.
The #40 acceptance criterion should require a failing positive control and a
similar input that must not fire, with both outcomes interpreted by the runner.
