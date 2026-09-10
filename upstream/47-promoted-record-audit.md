We implemented #47 downstream, in the same file as #46 —
`sql/26_propose_then_promote.sql` — deliberately. #46 controls how a row
*becomes* authoritative; #47 controls what may happen to it *after*. Splitting
them puts two halves of one invariant into two migrations that can be applied
independently, and the half-applied state is a system that gates promotion but
lets promoted rows be rewritten.

**Status: written, replays clean, NOT applied to any deployment.** Tests:
`tests/23_promotion_guards_negative.sql`, Section C (9 assertions).

## The policy decision #47 asks for

#47 asks whether promoted records are append-only, content-hash audited, or
both. Our answer is **both, scoped**, and the scoping is the part we would
defend:

- A `proposed` row is a **candidate**. Editing it is normal review work and stays
  unrestricted — that is what the review loop is *for*. Asserted as
  `c3_proposed_candidate_stays_editable`.
- A `current` row is a **promoted record**. Its authority-bearing fields become
  immutable in place: `content`, `provenance_basis`, `citation`, `source_kind`,
  `source_agent`. Corrections go through `supersede_memory()`, which preserves
  the original and attributes the correction.
- **Operational fields on a current row stay mutable**: embedding columns,
  hot-touch counters, due status, metadata, owner, visibility. Marking a deadline
  done is not a rewrite of what was promoted. Asserted as
  `c4_operational_fields_stay_mutable`.

Full append-only was **rejected**: it breaks legitimate supersession, which is
the existing correction discipline and is already attributed. An immutability
rule that removes the only sanctioned way to fix a wrong record does not protect
the record, it fossilizes the error.

This directly answers #47's "Docs distinguish candidate edits from
promoted-record edits" criterion — and it is enforced, not just documented, in
`enforce_promoted_record_immutable()`.

## The hashed tuple is not just the prose

`memory_authority_hash()` digests `content`, `provenance_basis`, `citation`,
`source_kind` and `source_agent`, field-separated. **A silent swap of the
citation is the same class of tamper as a silent rewrite of the content** — the
record still says something true and now claims a different basis for saying it.
`c2_promoted_citation_swap_rejected` covers exactly that, separately from the
content case, so the two cannot collapse into one.

## Prevention and detection are separate layers, on purpose

The guard **prevents** in-place rewriting. `promoted_record_audit` **detects** a
rewrite that got past the guard — a superuser with `ALTER TABLE ... DISABLE
TRIGGER`, or a caller who armed the session GUC themselves.

We built them as two layers because the guard's own bypass is documented (see
#46 — `app.promoting` is a session GUC and an unrestricted role can set it). A
prevention layer whose bypass you have written down in public needs a detection
layer behind it, or the documentation is just an advertisement for the hole.

`c7_bypassed_edit_is_detected` is the test that matters here: it arms the
bypass, performs the edit the guard would have refused, and asserts
`verify_promoted_integrity()` reports `mismatch`. That is #47's "silent edit
detection test".

The receipt table is itself append-only in the literal sense — it takes no
UPDATE and no DELETE (`forbid_audit_mutation()`), because an audit trail that
can be edited is not one. `c8_audit_table_is_append_only`.

## The part we think is most worth upstreaming: `unaudited` is its own state

`verify_promoted_integrity()` returns three states, never two:

| state | meaning |
| --- | --- |
| `match` | a receipt exists and the current hash equals it |
| `mismatch` | a receipt exists and the content has changed underneath it |
| `unaudited` | **no receipt exists — nothing can be said about this row** |

Every row promoted **before** this migration is `unaudited`, and that is the
honest answer for it. The tempting implementation folds `unaudited` into `match`
(no recorded hash, nothing contradicts, report clean) or into `mismatch` (no
recorded hash, cannot verify, report bad). Both are wrong in the same way:
**they convert absence of evidence into evidence**, in one direction or the
other.

Folding it into `match` is the dangerous one, because it means the day you apply
this migration, your entire existing corpus reports fully verified while
literally none of it has been. `c9_unaudited_row_reports_unaudited` pins this —
it constructs a current row with no receipt and asserts the verifier says
`unaudited`, not `match`.

This mirrors the vocabulary of our existing `verify_doc_integrity()` on purpose,
so an operator reads both surfaces the same way. It is the same principle the
retrieval envelope needs (see #72): a system must be able to distinguish
"checked and fine" from "not checked".

## What we did not close

- **The audit covers `memories`.** `promoted_record_audit` carries a
  `table_name` column and the artifact allowlist covers `wiki_pages`, but the
  immutability guard and the promotion receipts are memories-only, because
  `wiki_pages` has no `promote_wiki()` to write a receipt from. Wiki content
  drift remains covered by the separate `doc_integrity` / `bless_doc` path.
  Stated as an asymmetry rather than left for a reader to discover.
- **A hash is not a signature.** `promoted_record_audit` detects tampering by
  anyone who did not also rewrite the audit table. Anyone holding the role that
  can disable the trigger can also insert a fresh receipt. Signing is not
  implemented.
- **`actor_assurance` is `caller_asserted_unauthenticated` on every receipt**,
  and it says so in the column default rather than in a comment somewhere. A
  caller-supplied principal UUID proves the UUID belongs to an active human, not
  that the caller *is* that human, while clients share one credential. The
  receipts are attributable to a claimed actor, not an authenticated one, and we
  would rather the column say that forever than have a later reader assume
  otherwise.

Happy to open a PR with the migration and the suite.
