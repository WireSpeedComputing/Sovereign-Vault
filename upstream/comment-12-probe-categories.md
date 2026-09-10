## What exists downstream, and what does not

Downstream adopter report, measured against a live deployment read-only rather than against a design.

### The accounting layer exists; it is not a probe layer

`sql/06_import.sql` defines `import_cutover_scorecard`, one row per source system, answering *is this source fully accounted for?* Columns: `batches`, `last_expected`, `landed`, `unclassified`, `to_import`, `import_pending`, `held`, `excluded`, `evidence`, `still_proposed`, and a boolean `sunset_ready`.

Applied result, three source systems on a live deployment:

| source | batches | expected (max) | landed | unclassified | to_import | excluded | evidence | still_proposed | sunset_ready |
|---|---|---|---|---|---|---|---|---|---|
| A | 1 | 92 | 0 | 0 | 0 | 0 | 0 | 0 | **false** |
| B | 3 | 39 | 84 | 84 | 0 | 0 | 0 | 0 | **false** |
| C | 1 | 408 | 408 | 0 | 170 | 49 | 189 | 74 | **false** |

Three sources, three `false`, three different reasons — nothing landed; everything landed but nothing classified; everything landed and classified but 74 rows still sitting proposed and unreviewed. That is the one part of this issue's guardrails the view genuinely meets: **`sunset_ready` is a boolean AND over named conditions, not a percentage.** No aggregate score can drown out a critical failure because there is no aggregate score. `held > 0` deliberately does *not* block — a hold is an explicit decision — while `unclassified > 0` does, because an unclassified artifact is an absence of decision.

That is the whole of what exists in SQL, and it is accounting, not probing. It counts artifacts. It cannot tell you whether the migrated system invents answers, flattens a conflict, serves a superseded fact, or drops evidence — which is exactly the problem statement in this issue.

### The probe categories are not in SQL

There is no enum, table, view, or function anywhere in our schema that defines `positive` / `negative` / `conflict` / `stale state` / `evidence request`. The categories exist only as **comment headers in a shell script**, `tests/sovereign_probes.sh` — 23 probes across the five categories, each run inside a rolled-back transaction so the negative probes actually attempt the forbidden write instead of merely reading. They run at a source before export and at a destination after restore, and `tests/verify_restore.sh` check K2 fails if the verdicts differ between the two.

Consequences, stated plainly:

- **Probe runs are not stored.** There is no run-history table. Nothing anchors a probe-suite version or hash.
- **The probes have never been run against the live deployment.** They run against a synthetic fixture in `tests/sovereignty_proof.sh`. Everything above is mechanism.
- **This issue's acceptance criterion "SQL and documentation define the probe categories" is not met.** Documentation is partly there (`docs/07-sovereignty-export-restore.md` §4, and the header of `tests/sovereign_probes.sh`); SQL is not there at all.
- **"Critical probes use all-pass readiness semantics"** is met inside the shell suite (any FAIL exits non-zero) and is met in shape by `sunset_ready`, but the two are unconnected: the scorecard's readiness flag does not consider probe outcomes, because it cannot see them.

### The substrate a SQL-level taxonomy could sit on

For anyone implementing this generically, these are the behaviours already expressible in SQL in our tree, and they map onto four of the five categories without inventing anything:

- **negative / unknown** — the governed retrieval entry point returns an envelope carrying `retrieval_status` (`evaluated` / `not_evaluated`), a `reason` (`no_retrieval_units_visible_to_principal`, `empty_query`), `units_visible`, `units_matched`, `units_returned`, and a `truncated` flag. "I found nothing, and here is which kind of nothing" is already a first-class result rather than an empty set — that is the shape a negative probe needs.
- **conflict** — a review queue with a `contradiction` kind and a pending resolution, so tensions are held visibly rather than resolved silently.
- **stale state** — a projection ACL-drift function returning the units whose access control has gone stale relative to their source rows, plus staleness markers on embeddings, plus the invariant that no live retrieval unit may point at a non-current record.
- **evidence request** — a trigger requiring a non-empty citation on every row whose provenance basis is not direct human statement, plus per-unit locators and content hashes.

What is missing is the binding: nothing names these as categories, nothing records that a given category was exercised, and nothing refuses readiness on a category failure.

### Two defects in the scorecard, found while checking this

Both verified against the view definition and against live data. Neither is currently producing a wrong answer; both are latent.

**1. `landed` double-counts when one source item yields more than one candidate.** The view is `import_batches LEFT JOIN raw_artifacts LEFT JOIN memories ON memories.source_artifact_id = raw_artifacts.id`, and then counts `count(ra.id)`. If an artifact produced two records, its row appears twice in the joined set and it is counted twice — and the same inflation hits `unclassified`, `to_import`, `held`, `excluded`, and `evidence`, all of which are `filter`ed counts over the same expression. Measured live: 492 artifacts, scorecard `landed` total 492, maximum records-per-artifact **1** — so the numbers agree today *only because the one-to-many case does not yet occur*. It starts lying the moment #11's "one source item producing multiple candidates" is implemented. The fix is `count(distinct ra.id)`.

**2. Readiness compares a cross-batch total to a single-batch expectation.** `sunset_ready` requires `count(ra.id) >= max(b.expected_count)`, grouping by source system — a total landed across *all* batches of a source against the *largest* expectation of any *one* of them. Whether that is wrong depends on whether `expected_count` restates the whole-source total on every batch or is per-batch. The column is aliased `last_expected`, which suggests the former was intended; but on the live deployment one source has three batches whose expectations differ and sum to 84 against a max of 39, which is consistent with the latter. Under per-batch semantics, three batches expecting 39 each with 50 landed would read `50 >= 39` → complete, while a third of the source was never imported. Raising it as a question rather than a verdict, since it turns on intent we cannot recover from the code.

### Bottom line

Of this issue's acceptance criteria: "scorecards do not hide critical failures behind aggregate percentages" is **met**, structurally, and we would recommend the boolean-AND-over-named-conditions shape to anyone else. "SQL and documentation define the probe categories" is **not met** — the categories are shell-script comments. "Synthetic validation covers positive, negative, stale-state, conflict, and evidence-request behavior" is **met on a fixture**, in 23 probes, and has never been exercised against a real migration.
