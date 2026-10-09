# Accounting and probe contracts for upstream #12

> Source/fixture note: this document states portable contracts and test methods.
> It does not report a customer corpus, access configuration, or hosted execution.

## Accounting is not semantic readiness

`sql/06_import.sql` defines `import_cutover_scorecard`, grouped by source
system. Its named columns cover batches, expected counts, landed artifacts,
classification dispositions, pending normalization, and candidate status.
Its boolean readiness expression combines named conditions rather than hiding
a critical failure behind an aggregate percentage. Explicit hold/exclude/evidence
decisions must remain distinct from an artifact with no classification decision.

An accounting view does not establish that retrieval preserves conflicts,
denies unauthorized evidence, or excludes superseded facts. Those are separate
behavioral questions.

## Probe source and required result binding

`tests/sovereign_probes.sh` organizes positive, negative, conflict, stale-state,
and evidence-request cases. Negative cases attempt the forbidden write inside a
rolled-back transaction. `tests/verify_restore.sh` compares source and restored
probe verdicts. Read the current script for the case inventory; an implementation
description is not a current run receipt.

A portable readiness result should bind the exact probe-suite version/hash,
scope, cases defined/evaluated/passed, per-category verdicts, and any skipped or
unsupported case. Critical probes require all-pass semantics. A zero evaluated
count must not be presented as a clean result.

## Proposed synthetic scorecard controls

1. Land one fabricated artifact that produces two candidates. Assert artifact
   counts remain one and candidate counts become two. A joined `count(ra.id)`
   can inflate artifact counts; evaluate whether distinct counting is required.
2. Use multiple fabricated batches with differing expectations. Decide explicitly
   whether `expected_count` is per batch or a repeated whole-source watermark.
   Compare a cross-batch total against the expectation with the same meaning;
   `max(expected_count)` is not a sum of per-batch expectations.
3. Pair each critical negative with an authorized positive control and a
   deliberately broken implementation that must fail for the intended reason.
4. Exercise missing evidence, conflicting candidates, stale source versions,
   and a superseded record separately from import accounting.

These are proposed fixture cases, not renamed operational measurements and not
claims of execution. #11's one-to-many source-locator case belongs in the same
accounting fixture.

## Relevant portable surfaces

The retrieval envelope distinguishes evaluated from not-evaluated results;
review-queue records retain contradictions; projection drift checks compare
cached access metadata against canonical rows; provenance constraints require
citations. Connect those source contracts to explicit probe outcomes before
claiming a scope is ready.
