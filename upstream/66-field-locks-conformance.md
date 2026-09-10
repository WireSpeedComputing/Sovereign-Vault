Implemented field locking on a live deployment. Reporting the result, and one finding that seems worth folding into the conformance criteria.

## What was actually true before implementing

The deployment had provenance enforcement, temporal columns, supersede-not-delete discipline, and audited transitions. By inspection of the trigger list it looked custody-conformant.

Probed rather than assumed, and **every custody-semantic field was rewritable in place**:

```
recorded_at       MUTABLE
provenance_basis  MUTABLE
source_agent      MUTABLE
content           MUTABLE
supersedes        blocked  <- by a foreign key, not by a lock
```

That last line is the one worth dwelling on. The supersession pointer *appeared* protected, and it was not — the probe passed a value that failed referential integrity. Had the probe used a valid identifier it would have succeeded. A protection that only holds for malformed input is not a protection, and it reads as one in any audit that checks whether the write was rejected rather than why.

So functionally zero locked fields, in an implementation that satisfied every other custody requirement.

## The generalisable statement

**Enforcement at insert without immutability afterward is not custody.** It is a well-formedness check wearing custody's clothes.

The existing triggers validated that provenance basis, citation and actor were present and consistent *at write time*. Nothing prevented changing them afterward. Anyone holding the operational credential could silently rewrite who recorded something, when, under what authority, and what it said — leaving a record that satisfies every validation rule and describes an event that did not happen.

This is a distinct failure mode from missing provenance. Missing provenance is visible. Rewritten provenance is not, and it is *more* dangerous precisely because the record looks complete.

## What was implemented

Locked after recording: identity, recorded/observed/effective times, provenance basis, citation, source kind, source actor, supersession pointer, and content. Corrections append a successor; they never rewrite the original claim.

Deliberately left mutable: status, effective-to, deadline fields, tags, classification, owner, visibility, metadata. These are lifecycle and classification, not custody claims.

**That split is the part that needs testing rather than reasoning.** A lock that also froze lifecycle fields would look identical in a trigger listing and would break promotion, rejection and supersession at the first correction — silently, and only under a workflow nobody exercises during implementation. All three sanctioned transitions were exercised against the trigger before and after applying: each succeeds, every locked field is rejected, lifecycle updates still work.

## An ordering constraint worth adding to the criteria

Registry corrections must happen **before** locks land, or be expressed as mappings rather than edits.

Concretely: this deployment recorded actor identifiers in one vocabulary and registered actors in another, so attribution resolved to nothing across every attributed row — an unvalidated string that looked correct and joined to nothing. Discovered a day before implementing locks.

The tempting fix is to rewrite the recorded values. That is wrong twice over: it rewrites a recorded custody claim, and after locks land it is impossible anyway. The correct fix was an alias table mapping recorded identifiers to registered actors, leaving every original value untouched. **The registry adapts to the evidence, not the reverse.**

Suggested addition: conformance should require that any actor-registry reconciliation be expressible as a mapping, and should verify no implementation depends on rewriting recorded actor fields to achieve resolution.

## On the layered claims model

Layer one only, and layer one is what was just shown to be unenforced by default. No canonical custody-event bytes, no hash chaining, no checkpoints, no independent anchor. The four criteria about missing, reordered, duplicated or altered events are not merely unmet here — there is no event stream, so they are untestable rather than failing.

Worth stating in the spec that database-level field locking is necessary and clearly insufficient: it prevents rewriting a record in place, and does nothing about deleting one, or about a compromised operator with the ability to disable the trigger. The stronger claims genuinely need the chaining layer.

Happy to contribute the trigger, the lifecycle/custody split, and the transition-regression fixtures if useful.
