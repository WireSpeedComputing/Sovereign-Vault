# Stale embedding repair candidate

`retrieval_embedding_coverage()` excludes embeddings with a non-null `stale_at`.
The historical backlog in `sql/29_retrieval_embedding_backlog.sql` does not enqueue
those rows unless their vector is also null or their rendered-text hash changed.
A current hash-matching vector can therefore remain stale indefinitely.

`pending/retrieval_embedding_backlog_stale.sql` is an optional repair candidate.
It adds stale rows to the existing model-filtered backlog, with reason `stale`.
The existing `missing` and `hash_drift` reasons, status filtering, generation
ordering, work limits, signature, owner, security mode and ACL remain unchanged.
Consumers must accept the additional reason before selecting this candidate.
The coverage function and historical sql/29 are unchanged.

This is source for review, not an applied migration or an automatic upgrade.
The candidate first checks the public baseline function body, or the identical
already-repaired body, and its security metadata. Unknown custom implementations
or missing functions fail before replacement. Compare definitions and qualify an
adapter explicitly when the guard refuses. The guard's SHA256 values describe
the public function source, not any deployment's migration ledger.

There are no grants, data changes, inference calls, vector deletions or repair
scheduling in this candidate. An existing authorized worker still performs any
later embedding work. Its input must remain bound to the exact rendered text
and model. A row leaves the backlog only when its embedding is current, non-null,
hash-matching and no longer stale.

## Synthetic verification

Run the executable fixture with Python 3 and Docker:

```sh
# Use an already cached PostgreSQL 17+ image. The harness never pulls an image.
PGTEST_IMAGE=postgres:17 python3 tests/retrieval_embedding_backlog_stale.py
```

PowerShell accepts the equivalent `$env:PGTEST_IMAGE = 'postgres:17'` followed by
`python tests/retrieval_embedding_backlog_stale.py`. `--output path.json` optionally
saves its machine-readable result.

The harness creates only a disposable, read-only-root container with a temporary
database, no network, no ports and no host mounts. It accepts no database URL or
live connection credentials and verifies container ownership before cleanup.
Its minimal synthetic tables exercise the actual public sql/29 function bodies
and the candidate. The placeholder vector column is sufficient for the nullness
checks under test; this does not test vector operators, full schema replay or RLS.

Seventeen checks passed on PostgreSQL 17.11: the original omission, stale repair,
unchanged missing/drift/null behavior, current/status/model/limit filtering,
unchanged signature/owner/ACL and coverage definition, no vector data changes,
ordinary-role denial, existing service-role execution, idempotence, missing or
unexpected baseline refusal, and disappearance from backlog after repair.

No production data, OAuth, hosted model, client connection or deployment acceptance
is claimed. For rollback, restore the original backlog function definition from
the selected public sql/29 revision after comparing metadata and preserving its
ACL. Rollback restores the omission, so it does not repair any stale rows.
