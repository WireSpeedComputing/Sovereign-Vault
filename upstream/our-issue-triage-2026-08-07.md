# Our-repo issue triage — 2026-08-07

Scope: issues filed against this repository (not upstream). Every disposition
below cites a file, a test, or a read-only query against the live deployment.
Claims that could not be verified are marked as such rather than asserted.

Read-only discipline for this pass: no migration applied, no SQL file touched,
no commit, no push, `STATUS.md` unmodified. Live inspection was `select`-only.

## Closed

### #8 — PG16 → PG17 test parity
Closed. `tests/replay_fresh_install.sh` stands up an isolated PG17 cluster and
applies every `sql/*.sql` from empty; `tests/verify_restore.sh` and
`tests/canonicalize_inventory.py` add definition-level comparison rather than
name-only equality.

Residual recorded on the issue and repeated here because it still matters: name
equality is not definition equivalence, and the replay runs a different pgvector
version than the deployment (see #10 below).

### #13 — Review queue
Closed. Verified by reading `sql/09_review_queue.sql`: contradictions land
`proposed` and a queue row links `incoming_ref`/`existing_ref` with `kind` and
`resolution`, so an incoming record cannot overwrite a confirmed one. Divergence
from the sibling pattern (narrower resolution vocabulary) is stated on the issue
rather than left silent.

## Left open, with the record corrected or sharpened

### #9 — Connection identity — DOWNGRADED, not closed
`blocking-multi-user` removed and moved to #11.

Verified live: the identity schema is deployed with all nine functions, and the
claims gate is `SECURITY INVOKER` while the other eight are `SECURITY DEFINER`.
That is the discriminator the design depends on, present as designed —
`SECURITY DEFINER` rewrites `current_user`, so a definer wrapper cannot tell a
real request from an administrative one.

Why the label moved: `select count(*) from pg_policies` returns **0** across
every schema. Multi-user is no longer blocked on identity resolution; it is
blocked on there being no policy to consume the resolved identity. The blocker
is #11.

What remains here is narrower than the title and is not a schema problem: the
shared administrative credential bypasses everything and agents hold it. That
closes by an operational change, not a migration.

### #11 — RLS enabled, no policies — UPDATE only, correctly still open
Re-verified independently this pass: **zero policies exist in the entire
database, in any schema.** Access works solely because the service role carries
`BYPASSRLS`. Policies are being designed but are not applied, so this stays open
per instruction — it closes when policies are applied, not when they are staged.

### #2 — Coordination channel — divergence NOT accepted as reasoned
The earlier disposition was heading to "close as divergence-accepted." Blocked
that, because the stated rationale is contradicted by the data.

The rationale claimed channel entries are "short and few" because substantive
documents live in wiki pages and the channel carries pointers. Measured live on
19 rows tagged `cross-instance-message` (2026-08-03 → 2026-08-07, 3 distinct
source agents):

- mean content length **5,219 characters**, longest **26,611**
- **zero rows under 1,000 characters**; seven over 4,000
- status split 15 `proposed` / 4 `current`

The channel carries the documents, not pointers. Additionally, `memories` has
**no classification column at all** — the `evidence` marker lives on
`raw_artifacts.action` (189 rows) — so the follow-up checkbox on that issue
cannot be done as written without a schema change.

What survives from the original rationale: coordination use is real
(`consensus-request`, `consensus-response`, `red-team-request` traffic across
three source agents), and inheriting provenance, temporal and access-control
columns is a genuine saving.

Narrowed to one open question: classification marker on `memories` (small schema
change) or a separate table (larger), given document-sized content. Answer to be
recorded in `LINEAGE.md`.

### #12 — Provenance for owner directives — open, now quantified
Live counts for the exact relay case (`provenance_basis='decision_record'`,
`source_kind='agent'`):

- 36 rows, 2026-07-10 → 2026-08-07, 3 distinct source agents
- **31 sit at `status='current'`** — carrying authority, not awaiting promotion
- all 36 have a citation; 33 cite a session in free text
- **none resolve**: no `raw_artifacts` id, no URL, exactly one UUID-shaped token
- of all 45 `decision_record` rows, 33 citations name the owner as source

The structural point, from reading `sql/03_provenance.sql`: the citation check
only requires non-empty text, and the status gate lets an agent land directly at
`current` **only** when the basis is `decision_record`. The one basis that grants
an agent unmediated authority is the one basis the schema cannot verify.

Linked to #9: option 2 in that issue's body (directives table gated on owner
identity) is the only listed option that closes it, and verified identity is the
prerequisite. Any fix now needs a backfill or re-attestation pass over 31
authority-bearing rows, not just a forward-looking rule.

### #10 — Extension in public — open, scope reduced
Live `pg_extension` join: `vector` 0.8.2 is in `public`; `pgcrypto` 1.3,
`uuid-ossp` 1.1 and `pg_stat_statements` 1.11 are already in `extensions`.

So the issue body's open question about `pgcrypto` resolves to **no** — `vector`
is the only extension in `public`, making remediation a single `ALTER EXTENSION`
rather than a sweep.

`sql/28_perimeter_assert_signal.sql` makes the finding **declarable** via
`perimeter_exception` rather than permanent noise — the check previously
returned ~200 findings on the deployment (nearly all pgvector internals) and zero
on local replay, which is why it was unusable. That does not relocate the
extension, which is what the issue asks for.

Version caveat worth carrying: replay runs pgvector 0.8.5 per #8's closure
comment, the deployment runs 0.8.2. A relocation exercised only on replay is not
exercised on the deployed version.

## Could not verify

- **The 2026-08-07 PostgREST two-principal test for #9.** The deployed function
  shapes and security modes were confirmed directly, but the granted-true /
  ungranted-false observation is carried from the existing issue comment; it was
  not re-executed this pass (it needs authenticated JWTs, not a read-only query).
- **`tests/replay_fresh_install.sh` results for #8.** Not run — fixed ports,
  concurrent agents would collide. The closure rests on reading the harness and
  on the prior recorded run.
- **pgvector 0.8.5 on replay.** Taken from #8's closure comment, not observed.

## Note on the record

`#58` in #8's closure comment is an upstream issue number. Rendered in this
public repo it links to a local number that means something else. Cross-repo
references should be written in `owner/repo#n` form, as the #11 comment does.
