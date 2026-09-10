## Measured evidence for why this issue matters, from a live deployment

Downstream adopter report. We have the container-level model this issue describes as insufficient, and nothing else. Rather than assert that, here are the counts, taken read-only from a live deployment today.

**Correction first, because we were about to cite a wrong number.** Our internal note carried "roughly ten citations that resolve to nothing." That figure does not survive being measured. Under the strictest reading — a citation that names a specific target which is not in the store — it is **5**, not ten. Under the reading this issue actually cares about — a candidate that cannot be verified against the span that produced it — it is **66 of 285**, of which **53 contain nothing machine-readable at all**. Both real figures are below. A remembered number that nobody re-derives is how a document stops being evidence, so we are retiring ours.

### What the schema guarantees today

A trigger in `sql/03_provenance.sql` rejects any row whose provenance basis is not direct human statement unless it carries a non-empty citation. That constraint holds: **zero** rows in the governed table violate it. The citation column is free text.

The import path in `sql/06_import.sql` lands each source item verbatim into a raw-artifact table with a `payload_sha256` and a `(source_system, source_id)` uniqueness constraint, and normalized records carry a `source_artifact_id` foreign key back to it. That is precisely the *container plus payload hash* this issue names as the thing that does not preserve the context supporting each candidate.

### Where citations actually point

Governed records whose provenance basis is not direct human statement: **285**.

| linkage | rows |
|---|---|
| resolves by foreign key to a preserved source artifact (container + payload hash) | 219 |
| no artifact link; citation embeds an identifier in prose | 13 |
| no artifact link; citation contains no machine-resolvable token at all | 53 |

Of the 13 that embed an identifier in prose: **8** resolve to an existing governed record, **5 resolve to no row in the store**. The 53 remaining are free prose naming a working session and a date. They are truthful and completely unverifiable by machine.

The narrow slice this issue was raised against — agent-authored decision records — is **38 rows**: zero empty citations, one embedding an identifier (which resolves to nothing), **37 with no machine-resolvable locator**. The constraint is fully satisfied and the verification value is near zero. That gap is the entire argument for this issue, and we can now put a number on it rather than a worry.

### No locator or quote fields exist anywhere

We queried `information_schema.columns` across the public schema for anything matching `quote|offset|span|range|locator|turn|char_start|char_end|excerpt|hash`. Complete result set, four columns:

- the raw-artifact `payload_sha256` — container level;
- a retrieval unit's `exact_locator` and `source_content_hash`;
- a retrieval embedding's rendered-text hash;
- a source-freeze watermark hash.

**No quote column, no quote hash, no algorithm field, no offset or range, no message or turn metadata.** Not partially implemented — absent.

`exact_locator` is worth calling out explicitly because the name invites the wrong conclusion. It locates a governed row **inside this store** for retrieval; it is not a locator into an external source item. Live shape: 136 units, of which 127 are one-unit-per-record over the governed table, and 9 are sections of a single wiki page. So the only place sub-item granularity exists at all is wiki sectioning, and that is a projection of an already-governed row, not a span inside an import source. This issue's "synthetic validation includes one source item producing multiple candidates" case has never occurred here: measured maximum candidates per source artifact is **1**.

### Consequence, stated without softening

For 219 of 285 rows you can verify that the *container* is unaltered and cannot verify that the candidate reflects the span it claims. For 66 of 285 there is nothing to verify against at all. Offset or encoding drift in a source item would be undetectable in every one of those 285 rows, because nothing hashes a span.

A second-order effect worth flagging to anyone adopting the same container model: implementing this issue will break naive accounting that joins artifacts to candidates. Our own import scorecard counts artifacts across a join to the candidate table without `distinct`; it is correct today *only* because no artifact has ever produced two candidates. It is the intended one-to-many case that makes it wrong. Raised separately on #12.

### What we are not claiming

We have not implemented these fields, have not proposed names for them, and have not validated any candidate-level hashing scheme. This comment is evidence that the gap is real and how large it is, not a contribution toward closing it.
