## Summary

SMP requires recording authorization/assurance-at-write, actor evidence, and
supersession links as locked custody fields. It does not appear to require that
any of it be **delivered to the consumer at the point of use**.

Running a real deployment against real agents, that gap turns out to matter more
than the recording requirement. Custody metadata that never reaches the
decision is audit-only: it protects the archive, not the answer.

## The concrete observation

Our governed retrieval returns, per result: exact locator, citation,
provenance basis, workstream, relevance scores, effective time, truncation flag.

It does **not** return:

- **assurance** — every actor claim in this deployment is recorded as
  `caller_asserted_unauthenticated`, because under a shared service credential a
  caller-supplied principal UUID proves the UUID belongs to an active human, not
  that the caller is that human. We record that honestly. The consuming model
  never sees it, so it cannot weight the claim.
- **asserting agent** — recorded on the row, absent from the payload.
- **supersession state** — whether this record has a successor, or superseded
  something. Filtering to current is correct, but a model cannot tell whether it
  is holding a long-settled fact or one corrected an hour ago.
- **contradiction** — if two returned records disagree, nothing says so. Our
  import path raises contradictions into a review queue at ingest; retrieval
  surfaces none of that.

Every one of those is recorded. None is delivered.

## Why this is a protocol concern rather than an implementation bug

A human consumer compensates by looking around: opening the audit view, checking
a timestamp, noticing two documents disagree. Those moves are cheap for a person
and expensive or impossible for a model, which sees exactly one assembled
payload and cannot cheaply re-query to establish trust.

So an implementation can be **fully conformant on recording** and still hand a
model an unqualified assertion. The model then treats a caller-asserted,
recently-contested record identically to a verified, long-settled one — which is
the exact failure custody metadata exists to prevent.

Stated as a rule: *if the retrieval contract does not carry assurance,
supersession state, and contradiction signals alongside content, custody
metadata cannot influence any decision made from that content.*

## Evidence from this deployment

- A verified defect where a resolver silently resolved nothing: every call
  returned a safe-looking negative, and the system appeared correct at every
  surface. Only forcing a positive result exposed it. A payload carrying
  assurance would have shown "unresolved" rather than an unqualified answer.
- Eight stale pricing records contradicting one confirmed current record. Caught
  at import by the review queue. Retrieval would have returned any of them as a
  bare fact with a valid-looking citation.
- A derived projection carrying its own stale copies of access metadata. Fixed,
  but it demonstrated that a consumer reading the projection had no way to know
  the copy diverged from source.

## Suggested requirement

Add a retrieval/context-assembly conformance requirement roughly of this shape:

1. Every returned assertion MUST carry its assurance level and asserting actor,
   not merely have them recorded.
2. Every returned assertion MUST indicate supersession state — whether it has a
   successor, and whether it superseded a predecessor.
3. A context assembly MUST signal known contradictions among returned
   assertions, or explicitly declare that contradiction detection was not
   performed. Silence must not be indistinguishable from "no contradictions."
4. Where any of the above cannot be determined, the payload MUST say so rather
   than omit the field. An absent field is read as "not applicable"; an explicit
   unknown is read as a caution.

Item 4 generalises a pattern this deployment has been repeatedly bitten by: an
empty or absent result being indistinguishable from a verified-clean one. It is
the same reasoning behind reporting evaluation status separately from findings.

## Adoption argument

This is the difference between a protocol that is auditable after an incident
and one that changes what a model does before the incident. An implementer can
satisfy the recording requirements today and gain no behavioural benefit
whatsoever, which makes the recording work feel like compliance overhead. Making
delivery normative is what converts custody from paperwork into something that
demonstrably improves answers — and that is the argument that makes adoption
attractive rather than dutiful.

Happy to contribute the payload shape and conformance fixtures from our
implementation once we have run it against real agents for a while.
