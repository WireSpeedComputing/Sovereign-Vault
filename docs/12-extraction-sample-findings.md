# Extraction sample findings — 20 records, hand-checked

WO-11 Task 2. Written after extraction, against the predictions committed in
`docs/11-extraction-predictions.md` before any record was read.

**All examples in this file are abstracted.** The corpus is real business data
containing personal names, company identifiers, supplier relationships and
financial figures. Nothing from it is reproduced here, in any commit message, or
in any upstream contribution. Contradiction shapes are described structurally,
with placeholders. This constraint is permanent, not a courtesy: the statement
layer's output is *more* extractable than the document layer's, which makes
Rule 0 discipline harder and more important, not less.

## What was sampled, and how — including the flaw

19 distinct records, selected as: 8 matching pricing/cost terms, 6 matching
formulation/composition terms, 6 process-weighted, with overlap. Mean length
~900 chars, longest 2,926.

**The selection was not representative and that invalidates one prediction
rather than confirming it.** I selected toward the areas named as contradiction
ground truth — pricing and composition — which are exactly the content-dense
records. A prediction about the whole corpus cannot be tested against a sample
chosen for density. Recorded as a methodology error, not worked around.

## Predictions versus outcome

| Prediction | Outcome |
|---|---|
| 1.5–3.0 statements per record | **~6.3.** Falsified. |
| 25–40% of records yield zero | **0%.** Falsified. |
| `hedged` a genuine minority (10–20%) | Held, ~15%. |
| `attributed` rare (<10%) | Held, near zero. |
| Fewer than 6 supersession pairs qualify as corrections | **Held, and stronger than expected: only 2 of 6.** |

### Why the yield predictions were wrong, and what is actually true

Two causes, and they point in opposite directions.

**Sample bias (most of it).** Spec and financial records genuinely carry many
distinct claims. A formula record listing thirteen components at stated doses is
thirteen separately checkable assertions, not one. Extracting them separately is
correct — it is precisely the granularity that lets a query return one dose
instead of a 1,684-character record. High yield there is the feature.

**The corpus is pre-filtered (the rest).** I predicted 25–40% zero-yield from
process records. Searching specifically for process-shaped records returned
almost none that were content-free: the ones matching "session", "handoff",
"work order" were substantive decisions. The import pipeline already classifies
process material as `action='evidence'` and does not normalise it into
`memories`. The corpus was curated before I saw it.

So the zero-yield prediction was not merely wrong, it was **testing an
assumption that the import discipline had already made false.** That is a better
outcome than the prediction being right, and it is only visible because the
number was written down first.

**I am not treating ~6.3 as validated.** It is the density of the dense end of
the corpus. The honest figure for the full 126 records is unknown and the sample
cannot produce it.

## What was deliberately NOT extracted

Rule 2 is where a model confabulates hardest. The rejections, by class:

- **An explicit open question.** One record ends with a named unresolved
  question addressed to a person. It is the cleanest possible non-assertion and
  it was left alone. If a statement layer extracts questions as claims, every
  downstream contradiction check is polluted at the source.
- **Future commitments.** "Will be sent after the order is placed", "must be
  updated when X changes". These assert an intention or an obligation, not a
  world state. Where the obligation itself is the fact, it was extracted *as* an
  obligation, not as its own fulfilment.
- **Recommendations.** "Recommendation: get a quote from <person>" is advice,
  not a claim that the quote exists.
- **Plans presented as phases.** A record describing a phased rollout asserts
  that a plan was decided. It does not assert that the later phases have
  happened.
- **Directory and inventory listings.** The 2,926-character record is largely a
  file tree. It yielded **3** statements. Extracting sixty file paths as
  assertions would have been the single largest source of fake volume in this
  sample, and would have looked like a productive record.
- **Process narration and "LESSON:" paragraphs.** Meta-commentary about how work
  was done is not a claim about the domain.

The inventory record is the most useful data point here: **2,926 characters →
3 statements.** Record length does not predict claim density, and any extractor
tuned to produce output proportional to input is wrong.

## Contradictions found

Stated against the three classes predicted in `docs/11`.

### Class 1 — competing figures, both records `current` (FOUND, 2 instances)

Two records, neither superseded, neither aware of the other, give **different
values for the same derived quantity** — a crossover threshold computed in two
analyses weeks apart. One says "approximately A to B"; the other says
"approximately C", where C is outside the A–B range.

A second pair disagrees about **both the current state of an external document
and the correct value it should carry**: one record says the document still
carries a stale figure and names what it should be; another says the document
was already updated, to a third value different from either.

This is the class the document path structurally cannot surface. Both records
read as confident, both are `current`, and retrieval returns whichever matches
the query terms better. Nothing in the document model can say they disagree.

### Class 2 — composition: summary versus spec (FOUND, and better than predicted)

The strongest find in the sample is **an internal contradiction inside a single
record**.

One record classifies components into "X-ONLY", "Y-ONLY" and "SHARED" lists. One
component appears in **all three**. "Only in X", "only in Y" and "shared between
X and Y" cannot simultaneously hold. The record is a *correction* record — it
exists to fix an earlier misclassification — and it reads as authoritative.

A second record covering the same subject is internally consistent and disagrees
with the first record's "X-ONLY" list.

This matters more than a cross-record conflict because **the document path cannot
surface it even in principle.** Retrieval returns the record; the record contains
its own contradiction; a reader gets one confident answer whose parts disagree.
Only decomposition into separate claims makes the conflict expressible.

It is also not hypothetical harm: a different record in the same sample
documents a real incident where exactly this class of misclassification produced
an incorrect supplier document.

### Class 3 — superseded prior versions (NOT FOUND, and the prediction was wrong)

Predicted: older-version claims surviving as `current` and contradicting the
current version. **They do not exist in the corpus.** Every record mentioning the
prior version does so as *changes-from* history inside a current-version record,
which is correct and not contradictory.

Separately, **4 of the 6 supersession chains are tombstones** — the successor
says "superseded, see <id>" and carries no world-claim at all. Those yield zero
statements and produce no contradiction pair.

So supersession is a **much weaker** contradiction source than the work order
anticipated, and my own expectation of "fewer than 6" was still too generous.
The real value is entirely in classes 1 and 2 — conflicts between records that
do not know about each other, and inside records that read as authoritative.

## Consequences for the schema

The sample did not force a schema change. Two properties earned their place:

- **Span verification** rejected nothing during hand-extraction because
  extraction was manual and spans were taken from the source. Its value is for
  the automated pass, and it remains untested against an extractor that guesses.
  That test belongs to Task 2's continuation, not here.
- **`modality`** is doing real work. Hedged financial estimates ("approximately",
  "realistic range") sit beside flat assertions in the same record, and
  flattening them would manufacture confidence the source did not have.

One gap the sample revealed: there is currently **no relation kind for
"internally inconsistent within one source"**. `contradicts` between two
statements sharing a `derived_from` expresses it correctly, but nothing
distinguishes an intra-record contradiction from a cross-record one when
querying, and they mean different things operationally — one is an authoring
defect, the other is a knowledge conflict. Noted for Task 3 rather than patched
speculatively.

## Honest limits of this sample

- 19 of 126 current records, non-representative by construction.
- Extraction was mine, by hand. It has not been tested against an independent
  extractor, so extractor disagreement is unmeasured.
- No statements have been written to any database. This is analysis, not data.
- The full-corpus yield, and therefore the real cost of the layer, is unknown.
