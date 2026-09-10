# Record lifecycle: candidate vs promoted record

What may be done to a knowledge row depends on its `status`, and the rules are
not the same at each stage. This distinction existed in the schema before it
existed in the documentation, which is how it came to be enforced
inconsistently.

## The two stages that matter

A row at `status='proposed'` is a **candidate**. It is work in progress. It has
been written down but nothing yet claims it is true.

A row at `status='current'` is a **promoted record**. Something in the system
now treats it as authoritative: retrieval returns it, deadline views surface it,
downstream domain logic reads it as fact.

The other statuses are terminal. `superseded` means it was true and has been
replaced. `entered_in_error` means it was never true. `retracted` means it was
withdrawn.

## What is allowed at each stage

| | candidate (`proposed`) | promoted record (`current`) |
|---|---|---|
| Edit `content` | yes, freely | **no** — supersede instead |
| Edit `provenance_basis`, `citation` | yes, freely | **no** — supersede instead |
| Edit `source_kind`, `source_agent` | yes, freely | **no** — supersede instead |
| Edit `embedding`, `embed_attempts`, `embed_error` | yes | yes |
| Edit `due_status`, `hot_touched`, `metadata` | yes | yes |
| Edit `owner`, `visibility` | yes | yes |
| Change `status` | only via `promote_memory()` / `reject_memory()` | only via `supersede_memory()` |
| Delete | discouraged; use `reject_memory()` | no |

Editing a candidate is the review loop doing its job. Editing a promoted record
in place is a silent rewrite of something the system already told someone was
true — there is no receipt, no predecessor, and no way for a reader to know the
text changed. That is why the two cases are governed differently.

Corrections to a promoted record go through `supersede_memory()`, which
preserves the original at `superseded`, links the replacement via `supersedes`,
records the acting principal, and writes an audit receipt for both rows.

## Reaching `current`

`status='current'` is unreachable by direct `INSERT`. Rows land `proposed` and
reach `current` only through `promote_memory()` (which requires an active human
principal) or as the successor row inside `supersede_memory()`.

Before `sql/26_propose_then_promote.sql` this was not true: `promote_memory()`
was a convenience wrapper rather than a chokepoint, and any caller could insert
an authoritative row directly. See `tests/23_promotion_guards_negative.sql`.

Artifact-derived rows carry one extra rule: a row with a non-null
`source_artifact_id` must reference a `raw_artifacts` row classified
`action='import'`. `hold`, `exclude`, `evidence` and unclassified (`NULL`)
artifacts are preserved and auditable but are not knowledge. The rule is an
allowlist rather than a denylist because `action` is nullable by design, so
`NULL` — not any of the three named classes — is the default state of every
freshly landed artifact.

## What the guards prove, and what they do not

Every guard described here is a trigger keyed on `app.promoting`, a session GUC
that the sanctioned `SECURITY DEFINER` functions set around their own writes.

**Anyone holding `service_role` can set that GUC themselves and walk through all
of it.** These guards close the accidental path — a script that forgets to call
`promote_memory()`, an import pass that normalizes the wrong artifact class, a
caller who edits a promoted row without realising what it was. They do not close
the deliberate path, and they are not authentication.

This is the same limit already recorded for `actor_assurance` in `sql/20`: a
caller-supplied principal UUID proves the UUID belongs to an active human, not
that the caller *is* that human. Real enforcement needs per-principal connection
identity — the `vault_auth` layer — not another trigger.

`tests/23_promotion_guards_negative.sql` section D asserts these bypasses still
work, so the limit appears in test output rather than only in prose. If a
section D test starts failing, the enforcement story changed and this document
is now wrong.

## Detecting what the guards missed

`promote_memory()`, `supersede_memory()` and `reject_memory()` each write a
content hash to `promoted_record_audit`, which is append-only (its own trigger
refuses `UPDATE` and `DELETE`). `verify_promoted_integrity()` compares every
`current` row against its recorded hash and reports one of:

- `match` — the row is what was promoted
- `mismatch` — the row changed after promotion, which given the guard above
  means something bypassed it
- `unaudited` — no receipt exists, so nothing can be said about this row

`unaudited` is the honest answer for every row promoted before `sql/26` was
applied. It is reported as its own state rather than folded into `match`,
because silence about a row must never read as a clean bill of health.

---

## Row-level locks do not survive a table-level operation

**Every custody mechanism in this system is row-level, and the guarantees they
provide end exactly where row operations end.** This section exists because that
sentence was true for months and was written down nowhere, while the
documentation above described immutability in terms that invited a stronger
reading than the implementation supports.

The four mechanisms, and their wiring:

| mechanism | trigger timing | file |
|---|---|---|
| custody field locks | `BEFORE UPDATE ... FOR EACH ROW` | `sql/39` |
| bounded status transitions | `BEFORE UPDATE ... FOR EACH ROW` | `sql/13` |
| hard-delete guard, writes a receipt | `BEFORE DELETE ... FOR EACH ROW` | `sql/34` |
| append-only audit tables | `BEFORE UPDATE OR DELETE ... FOR EACH ROW` | `sql/26`, `sql/34` |

`TRUNCATE` is a statement-level operation. **No row-level trigger fires for it.**
One `TRUNCATE` therefore defeats all four at once: it destroys every governed
record, arms no override, writes no receipt, and leaves no row for any
row-level check to inspect afterwards. `DROP TABLE` and
`ALTER TABLE ... DISABLE TRIGGER` are DDL and are not constrained by any of them
either.

The sharpest form of the problem was that `hard_delete_audit` — the table whose
entire purpose is to make destruction observable — was itself truncatable by the
same privilege. Evidence destructible by the privilege it exists to observe is
not evidence.

### What is now true, and what is still not

`TRUNCATE` has been revoked from `service_role` across `public` and `vault_auth`
(migration 62), and the default privileges that were silently re-granting it on
every `CREATE TABLE` have been altered so new tables do not inherit it.
`perimeter_assert()` gained a `destructive_grant` category that reports
`TRUNCATE` held by any non-owner role, so a re-introduction is visible rather
than latent.

**Still true, and not fixed by any of that:**

- The table **owner** can always `TRUNCATE`, `DROP` and `ALTER`. Ownership is not
  a grant and cannot be revoked from. Anyone holding the owner role holds the
  ability to remove the entire substrate, and no row-level mechanism can observe
  it.
- A platform-owned default privilege entry, owned by a role we are not a member
  of, still grants the full privilege set — including `TRUNCATE` — to the
  network-facing roles for any table created *by that role* in `public`. Our
  migrations do not create tables as that role, so no current table is affected.
  We cannot alter that entry, and it is recorded here rather than in a runbook
  because it is a standing property of the host, not a task.
- Detection of a table-level destruction is not a database-level control at all.
  It requires an independently held checkpoint that diverges afterwards — which
  is what the export/restore package is for, and why an archive nobody has
  restored from is not a control either.

### The rule to carry

**Immutability claims must name the operations they hold against.** "A promoted
record cannot be altered" is false as written; "a promoted record cannot be
altered or deleted by a row operation from a routine or service role" is true
and is the claim the mechanisms support. Where this documentation makes an
immutability claim, it should be read with that qualifier, and any conformance
criterion phrased as "in-place updates fail" is satisfiable by a system whose
records can be destroyed wholesale.
