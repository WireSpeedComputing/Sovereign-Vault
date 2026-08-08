# Extraction predictions — written BEFORE reading the sample

WO-11 Task 2 requires predicting what extraction will find before looking. This
file is committed before any record content is read, so the predictions are
checkable rather than reconstructed afterwards. The standing discipline is
"state expected numbers before running, never after" — it has produced three
findings in this project that would otherwise have read as success.

What I know at the time of writing, from aggregate queries only (no content
read): 126 current memories, 291 total, 14 superseded, 6 supersession chains,
mean length 1,297 chars, max 9,191, 22 records over 2,000 chars. Workstream
distribution: unclassified 84, tech 23, capital 3, operations 3,
sovereign-vault 3, suppliers 3, compliance 2, formulation 2, marketing 1,
procurement 1. Roughly 38 agent-authored `decision_record` rows.

## Predicted yield

**1.5–3.0 statements per record, mean nearer 2, with high variance.** The
variance matters more than the mean: I expect a small number of dense records
(specs, pricing, composition) to produce 5–10, and a long tail producing 0–1.

**25–40% of records will yield ZERO statements.** This is the prediction I most
want to be right about, because the failure mode is the opposite. A large
fraction of this corpus is process and coordination — session handoffs, "next
steps", work-order acknowledgements, decision records about *what to do*. Those
contain almost no claims about the world. An extractor under pressure to produce
output will manufacture statements from them, and that is precisely the
confabulation this task is guarding against.

**If I come back reporting ~2 statements per record with almost no zero-yield
records, that is evidence of over-extraction, not of a rich corpus.**

## Where I expect to be tempted to over-extract

Named in advance so I can check myself against the list rather than rationalise
afterwards:

1. **Decisions read as facts.** "We decided to lock the formula at v3.9" asserts
   that a decision occurred, not that the formula is good, correct, or final.
   The extractable claim is about the decision, and it must not be flattened
   into a claim about the product.
2. **Intentions and plans read as facts.** "We will notify the FDA within 30
   days" is not "the FDA was notified." Future-tense commitments are not world
   states.
3. **Options under consideration.** "We could move to a 90-day cycle" asserts
   nothing. This is rule 2 of the discipline and the single most likely place to
   go wrong.
4. **Section headings and list labels.** Structurally prominent, semantically
   empty. "Pricing" is not a claim.
5. **Meta-claims about the repository.** "Migration 43 was applied" is a true
   assertion, but it is about our own process, not domain knowledge. I expect
   several and will extract them only where they are genuinely assertions of
   fact, marked as such, not silently mixed with domain claims.
6. **Restating the record's topic as a claim.** The laziest failure: a record
   about supplier terms yields "there are supplier terms."

## Predicted modality split

**Mostly `asserted`.** I expect `hedged` to be a genuine minority (10–20%) and
`attributed` to be rare (<10%) — this corpus is largely first-person operational
record-keeping rather than reporting of third-party claims. If `hedged` comes
back near zero, I should suspect I am flattening qualifiers rather than that the
corpus has none; operational notes are usually full of "roughly", "expected",
"should be".

## Predicted contradictions (Task 3 ground truth, stated now)

The work order names three classes. My specific expectations:

1. **Pricing.** Multiple figures for the same thing at different times, with one
   confirmed current. I expect at least one stale figure that is still stated
   flatly in a record that was never superseded — this is the case the document
   path cannot surface, because both records read as confident.
2. **Composition / formulation.** A summary document stating a composition that
   a primary spec contradicts. I expect the summary to be the more confident of
   the two, and the primary spec to be the correct one.
3. **Supersession pairs.** 6 supersession chains exist. Each chain where the
   correction changed a *claim* (rather than fixing a typo or adding detail)
   should produce a contradicting pair between the old and new statements. I
   expect fewer than 6 to qualify — some supersessions will be additive or
   editorial rather than corrective.

**The strongest test is class 1**, because supersession pairs are findable from
the `supersedes` column alone. Rediscovering those proves little. Finding a
contradiction between two records that are *both* `current` and neither of which
knows about the other is the thing the document model structurally cannot do.

## What would falsify the approach

- Extraction yields statements from process records at a similar rate to
  content records → the extractor is not distinguishing assertion from prose.
- Zero-yield rate near zero → over-extraction.
- The relation pass finds only supersession pairs and no cross-record
  contradictions → the layer reproduces what the `supersedes` column already
  told us and adds nothing.
- Statements that cannot be span-verified → the schema will reject them, so this
  would show up as extraction failures rather than bad data. That is by design.
