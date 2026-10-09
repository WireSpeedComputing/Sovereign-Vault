# Field-lock conformance for upstream #66

> Source/fixture note: this document states portable contracts and test methods.
> It does not report a customer corpus, access configuration, or hosted execution.

## Source contract

`sql/39_custody_field_locks.sql` separates recorded custody claims from
lifecycle and classification operations. Provenance well-formedness at INSERT
time does not by itself prevent a later rewrite of the asserted actor, time,
basis, citation, content, or lineage.

A rejected mutation is evidence of a field lock only when the supplied value
would satisfy unrelated constraints. For a supersession-pointer control, use
a valid fabricated predecessor identifier; a missing foreign-key target tests
referential integrity instead of immutability.

## Proposed synthetic acceptance method

Create fabricated proposed/current records, valid actors, and a valid lineage
target. Attempt each locked-field change with otherwise valid input and assert
the intended guard rejects it. Pair this with legitimate promotion, rejection,
and successor creation, plus permitted lifecycle/classification updates.
Check the exact rejection cause rather than treating any SQL error as a pass.

These are proposed fixture requirements, not a report of a deployment's field
state or a claim that the cases were executed.

## Registry reconciliation

If a recorded actor label does not resolve to the current registry vocabulary,
reconciliation should add an explicit reviewed alias mapping. Rewriting the
historical actor field changes the custody claim and can conflict with field
locks. `sql/38_agent_surface_alias.sql` provides the source mechanism for
preserving recorded labels while resolving registry identity.

Conformance should verify the mapping without allowing the registry to rewrite
the evidence it is intended to interpret.

## Limits of the layer

Row-level field locks do not prove hash-chain continuity, independently held
checkpoints, or detection after an administrator disables enforcement. They also
do not cover statement-level destruction. #47's audit and the companion #66
table-level note describe separate questions. Report unimplemented or
unevaluated layers explicitly instead of treating their absence as conformance.
