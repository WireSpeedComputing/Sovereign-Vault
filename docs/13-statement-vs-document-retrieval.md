# Statement and document retrieval

This guide describes an evaluation method using synthetic cases. It contains
no measured customer corpus, operational contradiction or adopter statistics.

## Compare the question each path answers

A document preserves context, qualifications and reasoning. A statement
projection isolates assertions and can support explicit conflict detection.
Neither path replaces the authoritative source record.

| Synthetic question | Useful representation | Required evidence |
| --- | --- | --- |
| “When is Store North open?” | Dated schedule assertions | Authorized source spans and effective intervals |
| “Two release notes disagree; which version applies?” | Versioned assertions plus source documents | Exact versions, supersession and conflict locality |
| “Why was this support process changed?” | Full decision context | Source reasoning, alternatives and review receipt |

These are evaluation hypotheses, not measured performance claims.
Character savings alone cannot establish answer quality.

## Evaluation controls

Build a committed synthetic corpus with labeled assertions, negation,
uncertainty, intra-record conflicts, cross-record conflicts and a documented
decision. Verify source span hashes and apply the caller's authorization before
retrieval, counts or conflict reporting.

Compare correctness, retained qualifications, source resolvability, conflict
coverage and reasoning context. Do not invent a causal link merely because
two extracted statements appear together. Report missing extraction and
truncation as coverage gaps.

Statements are derived projections. Changed or superseded source versions
invalidate their currency; stale projections must not become authority.
Publish only reproducible synthetic results. Customer corpus descriptions,
metrics and operating incidents stay in private evaluation records.
