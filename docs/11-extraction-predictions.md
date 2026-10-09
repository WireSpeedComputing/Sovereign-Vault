# Planning extraction evaluation

This is a portable evaluation method. All examples below are synthetic.
It contains no measured customer dataset, extraction result or adopter profile.

Before inspecting an evaluation corpus, record testable expectations:

| Question | Synthetic retail example | Synthetic SaaS example |
| --- | --- | --- |
| Which records express stable facts? | A dated stock-adjustment rule | A versioned support procedure |
| Which records are instructions or coordination? | A request to recount a shelf | A request to investigate an incident |
| Which statements have a checkable source? | A synthetic receiving receipt | A synthetic release manifest |
| Which changes require history? | A replacement ordering threshold | A corrected retention setting |

Treat these as hypotheses. Do not infer facts from headings, workstream names,
author identities or writing style alone.

## Evaluation plan

1. Construct labeled synthetic records with stable IDs and source locators.
2. Include current, proposed, superseded and rejected records, with private and
   shared visibility and differing authorized scopes.
3. Write expected extraction behavior before examining the candidate output.
4. Evaluate subject, relation, object, effective time and provenance separately.
5. Include negation, uncertain statements, multiple facts, instructions and
   mixed fact/coordination text.
6. Check extraction under the same request-derived access boundary as retrieval.
   A privileged aggregate must not substitute for an authorized reader.
7. Keep real evaluation corpora and operating metrics private.

Record uncertainty explicitly. A suggested normalization is not canonical truth,
and an extracted assertion without resolvable provenance is not evidence-backed.
