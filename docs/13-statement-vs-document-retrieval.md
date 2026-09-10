# Statement retrieval versus document retrieval — measured

WO-15 A2. Measured on a real extraction: six records, sixteen statements, every
span hash-verified against its source at write time.

**All examples below are abstracted.** The corpus is real business data. What is
reported is shapes and counts, never content — the same constraint `docs/12`
records, and it matters more here, because the statement layer's output is more
extractable than the document layer's.

---

## The three queries

| | document path | statement path | ratio |
|---|---|---|---|
| **Q1** composition question, answer contested *inside one record* | 2 items, **1097 chars** | 3 items, **139 chars** | 7.9× |
| **Q2** a derived figure two analyses disagree about | 2 items, **593 chars** | 2 items, **143 chars** | 4.1× |
| **Q3** "summarise this decision and why" | 3 items, **817 chars** | 6 items, **326 chars** | 2.5× |

Character ratios are the least interesting result on this page. They favour
statements everywhere, and they would favour statements for a layer that simply
truncated records.

---

## Q1 is the case that is not about degree

One record assigns the same component to two mutually exclusive categories and
then declares it a member of a third that denies both. It is a *correction*
record — it exists to fix an earlier misclassification — and it reads as
authoritative.

- **Document path:** returns the record. The contradiction is inside it. A
  reader gets one confident answer whose parts disagree, and retrieval has no
  mechanism to say so — not a weak signal, *no mechanism*. A record cannot
  report that it disagrees with itself.
- **Statement path:** returns three atomic claims and, separately, **3
  contradiction pairs with `locality = intra_record`**.

This is the one place the comparison is **capability rather than quality**. The
document path does not do this badly; it cannot do it at all. Every other row in
the table above is a system doing the same job better or worse.

The operational consequence: `intra_record` means an **authoring defect** — one
record is internally incoherent and no retrieval strategy rescues it.
`cross_record` means a **knowledge conflict**, where both claims may have been
correct when written. They need different fixes, so a path that cannot
distinguish them cannot route either.

---

## Where the document path wins, and it is not close

**Q3, and any question whose answer is a chain of reasoning.**

The statement path returned 6 claims in 326 characters. Every claim was
individually true, individually sourced, individually checkable — and the
*reasoning connecting them was in none of them*. The records contain a decision,
its cost basis, the alternative considered, the reason the alternative lost, and
the open question that remained. Extraction kept the assertions and discarded
the argument.

That is not a tuning problem. It follows from the extraction discipline: **"do
not extract what is not asserted."** A causal link between two facts is usually
not asserted anywhere; it is the shape of the paragraph. Extracting it would
mean inventing a claim the source does not make, which is the failure the rule
exists to prevent. The loss is *load-bearing*, not incidental.

So: for "what is true about X", statements win, sometimes categorically. For
"why did we decide X", documents win, and a statement layer that appeared to
win there would be one that had started confabulating connective tissue.

A comparison showing statements winning everything would be evidence the
comparison was wrong. This one does not.

---

## Two further limits

**Fewer characters is not automatically better.** Q3 returns 2.5× fewer
characters *and a worse answer*. Character precision is a proxy that stops
tracking quality exactly where the question stops being factual. Anyone using
these ratios to justify the layer should stop at Q1 and Q2.

**Neither path is a system of record.** Statements remain a derived projection.
Nothing may depend on a statement as authority; the source record is the claim,
and `statement_drift()` exists because a projection that has quietly stopped
matching its source is worse than no projection.

---

## What this justifies

The statement layer earns its place on **contested facts and figure
divergence**, and specifically on the intra-record case, which nothing else can
surface.

It does not replace document retrieval, and the honest deployment shape is both:
documents for context and reasoning, statements for "is this contested, and by
what?" A single retrieval surface that silently chose between them would be
choosing between two different questions.
