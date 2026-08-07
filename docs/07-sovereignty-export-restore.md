# 07 — Sovereignty: export, clean restore, and what the proof does not establish

Upstream: [`jryski/sovereign-memory-core#58`](https://github.com/jryski/sovereign-memory-core/issues/58)
— *"Owning a Supabase project is not sufficient evidence of sovereignty."*

Run the whole thing:

```sh
./tests/sovereignty_proof.sh
```

Exit 0 means: the repo's own migration path rebuilt the schema in an empty
cluster, a package exported from it restored into a **different** cluster with
no reference to the original host, the restored copy matched the source at the
level of **definitions** rather than object names, and — the part that makes the
rest mean anything — the verifier was shown to fail on 22 deliberate
corruptions while correctly ignoring two semantically-equivalent reformats.

---

## 1. Why this exists, in one paragraph

A backup you have never restored is a belief. This repo already proved two
things: `tests/replay_fresh_install.sh` proves the schema **builds** from empty,
and `tests/migration_drift.sh` proves the repo is **complete** relative to a
deployment's migration inventory. Neither proves you can *leave*. #58 is the
exit test: take the data out, stand it up somewhere the original host cannot
reach, and demonstrate — not assert — that what came back is what went in.

## 2. The pieces

| file | what it does |
|---|---|
| `tests/sovereignty_proof.sh` | end-to-end harness: build source → export → restore → verify → prove the verifier can fail |
| `tests/sovereign_fixture.sql` | the disposable synthetic dataset. No real data, ever |
| `tests/export_sovereign_package.sh` | read-only export from a source database |
| `tests/restore_sovereign_package.sh` | restore into a second clean cluster (port 5462) |
| `tests/verify_restore.sh` | the 14 post-restore checks |
| `tests/prove_verifier_discriminates.sh` | corrupts the restore 22 ways and asserts each is caught |
| `tests/sovereign_probes.sh` | positive / negative / conflict / stale-state / evidence probes |
| `tests/schema_inventory.sql` | definition-level inventory of every repo-owned object |
| `tests/canonicalize_inventory.py` | canonicalizes and hashes it; `--self-test` pins its behaviour |
| `tests/release_manifest.sh` | checksums + the KNOWN LIMITATIONS section, generated *into the package* |

Two isolated clusters, deliberately disjoint from `replay_fresh_install.sh`
(5433) so everything can run concurrently:

| | port | data dir |
|---|---|---|
| source | 5461 | `/tmp/agentB_pgdata` |
| destination | 5462 | `/tmp/agentB_restore_pgdata` |

`export LC_ALL=C` is required — Homebrew PG17 on macOS aborts at startup with
*"postmaster became multithreaded during startup"* otherwise. Every script pins
it.

## 3. The package

```
manifest.json  MANIFEST.md  RESTORE.md  CHECKSUMS.sha256
meta/     versions, extensions, settings, git ref, per-file sha256 of every sql file
schema/   sql/ (a COPY of the migration path), inventory.jsonl, inventory.hashes.tsv,
          pg_dump_schema_reference.sql
data/     data.sql  (pg_dump --data-only --disable-triggers, plain SQL)
hashes/   table_hashes.tsv, _table_hashes.sql, evidence_locators.tsv,
          supersession_chains.tsv, lifecycle.tsv
probes/   source_probes.txt
```

Three decisions worth defending:

**The package carries a copy of `sql/*.sql`, not just their hashes.** A package
that requires you to already have the right checkout is a bookmark, not an exit
path. The repo is still hashed against the package so drift is *reported*, but
the restore does not depend on it.

**The restore applies the migration path, not `pg_dump`'s schema.** #58 asks
that the *supported* path be the thing proven. `pg_dump_schema_reference.sql`
ships as a cross-check; if the two disagree, that disagreement is a finding, not
a choice of which one to use.

**The payload is plain SQL.** A custom-format dump needs a compatible
`pg_restore` to even read. For an artifact whose entire purpose is "you can get
out", inspectability beats compactness.

## 4. The checks

| | check | catches |
|---|---|---|
| J0 | canonicalizer self-test | a comparison tool that cannot tell things apart |
| A | per-table row counts | rows added or removed |
| B | per-table content hashes | any changed character in any column |
| C | evidence locators, per row | a tampered locator, named individually |
| D | `record_status` distribution | a lifecycle state rewritten in place |
| E | provenance basis + citation | provenance stripped from a restored row |
| F | supersession chains | broken lineage, orphans, forks, live predecessors |
| G | attention / hot index | orphaned or corrupted hot-index state |
| H | `perimeter_assert()` + RLS flags | the perimeter opened during restore |
| I | `migration_drift.sh` | a migration the package claims but does not carry |
| J | **definition equivalence** | everything a name check cannot see |
| J2 | extension inventory | a version skew between hosts |
| K | 23 conformance probes | a guard that stopped guarding |
| K2 | probe verdicts vs the source | a probe passing for a different reason |

## 5. Check J, and the honest limits of it — read this part

### The problem with what came before

`tests/replay_fresh_install.sh` establishes equivalence by listing object
**names**, filtered to non-extension objects. A prior review correctly observed
that **name-equality does not prove definition equivalence.** All of these pass a
name check:

* a function with the right name and a rewritten body
* an index with the right name over different columns
* a trigger with the right name pointed at a different function
* a table with the right name and a dropped constraint
* a `SECURITY DEFINER` function silently flipped to `SECURITY INVOKER`
* a definer function with its `search_path` removed
* a permissive RLS policy appearing where the model was deny-all

Every one of those is in the corruption suite. Every one is caught by J and by
nothing else in some cases.

### Why raw text does not work either

The obvious fix — hash `pg_get_functiondef()` — fails on a real pair in this
repo. The deployed `refresh_retrieval_units()` and the version in `sql/27` are
**semantically identical and textually different**: the applied migration used a
condensed body, `sql/27` keeps the full rationale. Measured:

```
real body   4387 chars   raw md5 ff1acfd8cc7350c5ee49aaf9107f3275
condensed   3467 chars   raw md5 9280a0a986d057a46f288c8de47f9bff
canonical hash, both:    248f6ea45f51db4e05d7a7f8f3e048ec…
```

A raw-text check reports drift on that correct pair **forever**. A checker that
cries wolf gets muted, and then it catches nothing — the same failure `sql/28`
exists to undo for `perimeter_assert()`.

### What canonicalization actually does

Comments are stripped and whitespace runs are collapsed **outside string
literals and quoted identifiers**, by a quote-aware tokenizer that understands
`'…'` (with `''` escapes), `"…"`, `$tag$…$tag$`, `--` and nesting `/* */`.

Everything that is *not* the body is compared **exactly** — signature, argument
list, return type, language, volatility, security mode, strictness,
leakproofness, parallel safety, `search_path` (`proconfig`), ACL, owner, RLS
flags, `reloptions`, enum labels, constraint definitions, index definitions,
trigger definitions, policy expressions, column types, defaults, identity and
generated markers, and comments-as-documentation.

The split is the point: **whitespace in a body is noise; whitespace in a security
mode is not a thing.**

### What canonicalization does NOT prove

1. **It is not semantic equivalence.** Two bodies differing only in keyword
   case, alias names, or the order of commutative predicates hash **differently**
   and are reported as drift. The tool errs toward false positives. That
   direction is chosen deliberately — the alternative is missing a rewritten
   body.
2. **Comment drift is invisible.** The flip side of stripping them. A body whose
   only change is its commentary hashes identically, so documentation can rot
   without this noticing.
3. **Nested dollar-quoted blocks are opaque.** `prosrc` is canonicalized
   directly, so the body itself is never dollar-wrapped at this level; but a
   function embedding its own `$$…$$` has that block preserved verbatim rather
   than canonicalized, and such a pair would report drift.
4. **Whitespace is not always inert.** Inside literals it is preserved, but a
   plpgsql body that assembles SQL from unquoted fragments across lines could in
   principle change meaning under collapse. No such construct exists here; it is
   a limit of the technique, not an observed defect.
5. **Extension-owned objects are excluded** (`pg_depend.deptype='e'`), the same
   line `replay_fresh_install.sh` and `perimeter_assert()` draw. Local PostgreSQL
   installs `pgcrypto` and `vector` into `public`; Supabase installs them into
   `extensions`. Comparing them would compare the two *hosts*. Extension
   *versions* are compared separately (J2); extension *internals* are not.
6. **Role names are host-specific.** Owner and ACL strings carry role names.
   `SOVEREIGN_ROLE_MAP=src=dst` rewrites them, and using it is a **declaration**
   that two roles are the same principal — not evidence that they are.
7. **Behaviour depends on things outside every definition**: server settings,
   collation provider and version, extension versions, and the data itself.
   Those are captured elsewhere in the package and are not part of this hash.

All seven are asserted, not just described. `canonicalize_inventory.py
--self-test` runs eight cases in both directions — including "comment text
changed → must hash SAME" and "keyword case changed → must hash DIFFERENT" — so
the documented limitations cannot drift away from the implementation silently.

## 6. Proving the verifier can fail

Steps 1–4 of the harness produce the same green transcript whether the checks
work or not. That is not a hypothetical concern in this repo: the name-equality
replay comparison read as proof of definition equivalence, `perimeter_assert()`
returned two hundred rows of extension noise, and a secret sweep matched shell
builtins. All three looked green.

So `prove_verifier_discriminates.sh` clones the restored database 24 times with
`createdb --template`, applies **one** damage per clone, and asserts both that
the verification fails *and* that it fails on the **intended check** — a
corruption caught by the wrong check is scored FAIL, because "something went
red" is not the same as "the check that owns this works".

Damage is applied with `session_replication_role = replica` and
`event_triggers = off`: what a tamperer with superuser would do, and what keeps
each case isolated to one check. Without `event_triggers = off`, every DDL
corruption would also trip the row-count check via `schema_changelog`, and
"caught" would stop meaning anything.

A control runs first: **the pristine restore must pass.** A verifier that fails
on everything catches nothing in particular.

The 22 corruptions cover: a deleted row; a single altered field with the row
count unchanged; a tampered evidence locator; a lifecycle state rewritten in
place; an erased citation; a broken supersession chain; a corrupted hot index;
the perimeter opened to `anon`; a function body rewritten under the same name; a
dropped index; `SECURITY DEFINER` flipped to invoker; a dropped constraint; a
removed `search_path`; a dropped guard trigger; a sanctioned function that stops
checking the principal; a changed column type; a column default moved back to
`'current'`; RLS switched off; a trigger repointed at a different function;
`EXECUTE` granted to a third role (invisible to `perimeter_assert`); a permissive
RLS policy appearing where the model was deny-all; and **the real `sql/27` body,
condensed, with exactly one ACL predicate deleted** — 51 characters out of 3467.

Two equivalence cases run in the opposite direction and matter just as much: a
reformatted body with rewritten comments, and **the real `sql/27` body condensed
the way the applied migration condensed it**. Both must verify CLEAN. Sensitive
to 51 characters of meaning, blind to 920 characters of formatting — that is the
claim, and both halves are tested.

## 7. Two defects this work found in itself

Recorded because they are the exact failure class the work order is about.

**The inventory truncated every object key to 63 characters.** The `UNION ALL`
resolved its `key` column to PostgreSQL's `name` type from the first branch, so
`vault_auth.principal_identity_bindings.principal_identity_bindi…` was as much
key as any long object got. Nineteen distinct constraints collapsed onto one
key. It was caught by a duplicate-key guard in the canonicalizer that existed
only because a duplicate key would make the comparison silently ambiguous.
Without that guard the comparison would have "passed" while comparing nineteen
objects to each other.

**The hashing script changed the thing it measured.** The first version built
its results in a `CREATE TEMPORARY TABLE`. That is DDL, `sql/01` installs an
event trigger on `ddl_command_end`, and so *measuring* the database wrote a row
into `schema_changelog`. Source and destination each added exactly one row, so
row counts matched and content hashes differed — a failure with nothing to do
with the restore. The tempting fixes are both wrong: excluding `schema_changelog`
would stop verifying the one table that records schema tampering, and disabling
the event trigger during hashing hides the measurement instead of not making it.
The measurement now emits no DDL at all (`\gexec` over generated per-table
queries).

## 8. Everything this proof does not establish

The full list ships **inside every package** (`MANIFEST.md`, KNOWN LIMITATIONS)
so the person holding the package has it. Summarised:

* **This is a fixture, not the deployment.** It proves the mechanism. The live
  deployment's rows have never been through this pipeline. Running it against the
  deployment is a separate, still-outstanding act.
* **`record_status = 'retracted'` is unreachable.** No sanctioned function
  produces it; the enum value has no door into it. Check D reports it as
  *unexercised* rather than asserting a count of zero as though absence were
  coverage.
* **`wiki_pages` has no promote path**, so wiki lifecycle coverage is genuinely
  narrower than memory lifecycle coverage.
* **Embeddings are deterministic pseudo-vectors**, not model output. Vector
  columns, dimensions, uniqueness and staleness survive; an embedding *pipeline*
  is not tested.
* **No identity bindings.** `vault_auth.principal_identity_bindings` is empty,
  so identity resolution — the layer that would make the capability model
  enforcement rather than decoration — is untested here.
* **Supabase default privileges are not reproducible locally.** `sql/07` exists
  because Supabase default-grants to `anon`/`authenticated` on new objects in
  `public`; vanilla PostgreSQL does not, so those `ALTER DEFAULT PRIVILEGES`
  statements record nothing and a local `perimeter_assert()` of zero is **weaker
  evidence** than the same result on a hosted project.
* **PostgREST, edge functions, cron, storage and auth are out of scope.** The
  package restores a database. The deployed system also has an
  `embed-retrieval-units` edge function, a PostgREST surface, and Supabase Auth
  issuing the claims `vault_auth` resolves. A restored database is a restored
  system of record, not a restored product.
* **The restore path runs with triggers disabled.** `sql/26` makes
  `status='current'` unreachable by direct INSERT, so a `COPY` of promoted rows
  would be rejected by the guard that makes promotion meaningful.
  `--disable-triggers` is required. Restoring a package is a trusted,
  superuser-equivalent operation. The verification afterwards is what
  re-establishes that the guards are present and armed — the restore itself is
  not guard-checked.
* **The restored `schema_changelog` is the source's DDL history, not the
  destination's.** Correct for a restore (it is data, and the source is the
  system of record) but it means the restored changelog does not record the
  restore.
* **A sha256 is not a signature.** It detects corruption and casual tampering.
  Anyone who can rewrite `data/data.sql` can rewrite `CHECKSUMS.sha256`. Signing
  is not implemented.
* **Re-running the export produces a different package checksum.** Promotion and
  supersession receipts record wall-clock time and successors get fresh UUIDs.
  The fixture is deterministic in *structure*, not byte-identical run to run.
  Checksums prove integrity **within** a run; this is not a reproducible-build
  claim.

## 9. Open items

* Run the whole pipeline against a **privacy-safe slice of the real
  deployment**. Everything above is mechanism.
* Add a `promote_wiki()` so wiki lifecycle coverage matches memory lifecycle
  coverage, and either give `retracted` a door or remove it from the enum.
* Sign packages. A checksum answers "was this corrupted"; it does not answer
  "who made this".
* Prove the perimeter claim on a hosted project, where default privileges
  actually exist.
* Wire the proof into CI. It needs only PostgreSQL 17 + pgvector and takes
  roughly half a minute; nothing about it requires a cloud project or costs
  money.
