## Conformance assessment against this issue's acceptance criteria

Downstream adopter report. We built an export/clean-restore/verify pipeline for #58 and then read it back against #52's criteria line by line. Summary up front: **the comparison and probe halves of #52 are implemented and adversarially tested; the CLI, the product-state vocabulary, the portability lint, and the custody receipt are not implemented at all.** Details below, with what does not hold stated as prominently as what does.

Files referenced, all by path:

| file | role |
|---|---|
| `tests/sovereignty_proof.sh` | end-to-end harness (build source → export → restore → verify → prove the verifier can fail) |
| `tests/export_sovereign_package.sh` | read-only export |
| `tests/restore_sovereign_package.sh` | restore into a second cluster |
| `tests/verify_restore.sh` | 14 post-restore checks |
| `tests/prove_verifier_discriminates.sh` | 22 corruptions + 2 equivalence cases |
| `tests/sovereign_probes.sh` | 23 probes: positive / negative / conflict / stale / evidence |
| `tests/schema_inventory.sql`, `tests/canonicalize_inventory.py` | definition-level inventory and its canonical hash |
| `tests/release_manifest.sh` | package manifest + KNOWN LIMITATIONS |
| `docs/07-sovereignty-export-restore.md` | write-up, including the non-claims |

---

### What actually satisfies the issue

**§3 empty compatible restore target — satisfied, and independently evidenced.** `tests/sovereignty_proof.sh` unsets the source connection variables before invoking the restore, so a mistake in the restore script cannot silently talk back to the source. That is an assertion about shell state, so it is not the evidence; the evidence is that source and destination `pg_control_system().system_identifier` are read and compared, and the run dies if they are equal. "Restored into a second environment" stops being a claim about a variable name.

**§4 canonical governed-state comparison — satisfied in substance.** Deterministic per-table row hashes over every column of every row (checks A/B), per-locator evidence rows (C), lifecycle distribution (D), provenance basis and citation presence (E), supersession listings (F). Not byte-for-byte database equality. The hashing SQL that produced the baseline is **carried inside the package** and re-executed at the destination, so the destination answers the identical question rather than a re-typed equivalent.

**§5 structural invariants — mostly satisfied, one named gap (below).** Referential integrity for hot-index and staging rows, supersession orphans, forks, live predecessors, chain depth; required triggers, functions, RLS policies, grants, roles and extensions via check J; extension versions via J2.

**§6 functional probes — satisfied.** `tests/sovereign_probes.sh` runs 23 probes in all five categories, each inside a rolled-back transaction so the negative probes genuinely *attempt* the forbidden write rather than only reading. The suite runs at the source before export and at the destination after restore, and check K2 fails if the verdicts differ — a probe that passes in both places for different reasons is not evidence.

**Four of the issue's negative acceptance criteria are met by `tests/prove_verifier_discriminates.sh`.** Each case gets its own database cloned with `createdb --template`, one damage per clone, and the run fails both when a corruption goes undetected **and when it is caught by the wrong check** — "something went red" is not the same as "the check that owns this works". A control runs first: the pristine restore must pass, because a verifier that fails on everything catches nothing in particular.

- *missing trigger/function/RLS dependency fails verification* — a dropped guard trigger; a dropped index; a dropped constraint; `SECURITY DEFINER` flipped to invoker; a `search_path` removed from a definer function; RLS switched off.
- *an altered governed record fails canonical comparison* — a single field altered with the row count unchanged.
- *a resurrected erasure case fails verification* — see the caveat below; the analogue is a terminal `entered_in_error` row rewritten to `current`, caught by check D.
- *candidate/promoted mixing fails a probe* — `stale.superseded_source_has_no_live_unit` fails if any live retrieval unit points at a non-current record, which covers proposed-as-well-as-superseded leakage into the retrieval surface.

---

### Name-equality is not definition equivalence — and canonicalization is not semantic equivalence

This is the part worth taking from us, because we shipped the weaker thing first and it read as proof.

Our earlier `tests/replay_fresh_install.sh` established equivalence by listing object **names** filtered to non-extension objects. A reviewer was right that this proves much less than it appears to. All of the following pass a name check: a function with the right name and a rewritten body; an index with the right name over different columns; a trigger with the right name pointed at a different function; a table with the right name and a dropped constraint; a definer function silently flipped to invoker; a definer function with its `search_path` removed; a permissive RLS policy appearing where the model was deny-all. Every one of those is now in the corruption suite.

The obvious fix — hash `pg_get_functiondef()` — also fails, on a real pair in our tree. One projection-refresh function exists in two forms that are semantically identical and textually different (the applied migration carries a condensed body; the repo file keeps the rationale). Raw md5 differs; the canonical hash is the same. A raw-text check reports drift on that correct pair **forever**, and a checker that cries wolf gets muted, at which point it catches nothing.

So bodies are canonicalized before hashing — comments stripped, whitespace runs collapsed **outside** string literals and quoted identifiers, by a quote-aware tokenizer. Everything that is *not* the body is compared **exactly**: signature, return type, language, volatility, security mode, strictness, leakproofness, parallel safety, `proconfig` search path, ACL, owner, RLS flags, `reloptions`, enum labels, constraint/index/trigger/policy definitions, column types and defaults, comments-as-documentation.

**What that does not buy you, stated plainly:**

1. **It is not semantic equivalence.** Two bodies differing only in keyword case, alias names, or the order of commutative predicates hash **differently** and are reported as drift. The tool errs toward false positives, deliberately.
2. **Comment drift is invisible.** The flip side of stripping them. Documentation can rot without this noticing.
3. **Nested dollar-quoted blocks are opaque** and are not recursed into; such a pair reports drift.
4. **Whitespace is not always inert.** Inside literals it is preserved, but a procedural body assembling SQL from unquoted fragments across lines could in principle change meaning under collapse. No such construct exists in our tree; it is a limit of the technique, not an observed defect.
5. **Extension-owned objects are excluded** (`pg_depend.deptype='e'`). Comparing them compares the two *hosts*. Versions are compared separately; internals are not.
6. **Role names are host-specific.** A role map exists; using it is a **declaration** that two roles are the same principal, not evidence that they are.
7. **Behaviour depends on things outside every definition**: server settings, collation provider and version, extension versions, and the data.

All seven are asserted, not merely described: `canonicalize_inventory.py --self-test` runs eight cases in both directions — including "comment text changed → must hash SAME" and "keyword case changed → must hash DIFFERENT" — and it runs as check J0 *before* the comparison it validates. The documented limits cannot silently drift away from the implementation.

The end-to-end version of the same claim: the real projection-refresh body, condensed, with exactly **one ACL predicate deleted** (51 characters out of ~3500) must be CAUGHT by J; the same body condensed the way the applied migration condensed it must verify CLEAN. Sensitive to 51 characters of meaning, blind to 920 characters of formatting — both halves are tested, and the condensation is done with `sed`/`tr` rather than with the canonicalizer, so the tool is not grading its own homework.

---

### What does NOT satisfy this issue

**No CLI, and no product states.** There is no `smc backup` / `verify-exit` / `receipt verify`. These are shell scripts with positional arguments. Nothing emits `installed`, `backup_created`, `custody_verified`, `verification_failed`, or `verification_skipped`.

**The skip path currently fails your acceptance criterion.** `tests/sovereignty_proof.sh --skip-discrimination` prints a blunt paragraph saying the run does not establish that the verification works — and then exits **0**, with the same closing banner as a full pass. To anything reading exit status or parsing the tail, a skipped run is indistinguishable from a verified one. The reason is recorded only in human-readable prose. This is the criterion "`verification_skipped` records an explicit reason and cannot be confused with verified", and we do not meet it. We are reporting it rather than fixing it in this pass.

**No portability lint.** Nothing inspects the backup before restore for provider-specific RLS helpers, provider roles and grants, extension version/schema placement, PostgREST-coupled assumptions, or provider-managed objects. Extension inventory is compared *after* restore (check J2), which is a different thing: it detects skew, it does not warn you before you rely on the restore.

**No custody receipt.** The package carries a `manifest.json` written at **export** time with roughly a dozen fields — format, export timestamp, source server version, source commit and tree-clean flag, sql file count, schema object count, schema fingerprint, tables/rows hashed, locator count, file/byte counts, and a package sha256 over `CHECKSUMS.sha256`. Against this issue's §7 that is missing: receipt version and **result**, skip/failure reason, tool version, probe-suite version and hash, restore-target engine fingerprint, scope and authority epoch, canonical-view definition version, state counts by lifecycle, structural-invariant results, functional-probe results, machine-readable declared exclusions, and signer principal/method/signature. **The verification run emits no artifact at all** — only a transcript. Nothing is anchored to a checkpoint log. Declared exclusions exist, but as prose in `MANIFEST.md`, not as data.

**A sha256 is not a signature.** It detects corruption and casual tampering. Anyone who can rewrite the data file can rewrite the checksum file. Signing is not implemented.

**Supersession acyclicity is not independently verified.** Check F's recursive CTE seeds from rows where `supersedes is null`. A pure cycle has no such root, so it is never traversed and never appears. The orphan, fork, and live-predecessor invariants do not see it either. A cycle *introduced after export* is still caught, because the chain listing and the per-table content hashes are compared against the source baseline and the rows go missing from the listing — but a cycle **already present at export** would pass verification in both places. If you adopt this shape, add a standalone acyclicity assertion rather than relying on baseline comparison for it.

**There is no tombstone or erasure model to test.** Withdrawal is a terminal `record_status` value, not a separate tombstone row, so "tombstone non-resurrection" maps onto "a terminal status rewritten in place". That case is covered, but it is a narrower claim than the issue asks for.

**Candidate/promoted separation is by status value, not by structure.** Candidates are a lifecycle status, not a structurally separate field, view, or query path. The retrieval projection excludes non-current records and a probe fails if that stops being true — which is the behaviour the issue wants — but the *structural* separation §"Candidate and demo boundary" asks for is not there, and there is no separately named wholesale-droppable demo scope.

**The restore target is a locally `initdb`-ed cluster on a fixed port, not a pinned container image.** Reproducible enough for us; not the pinned target this issue specifies.

**This has only ever run on a synthetic fixture.** The live deployment's rows have never been through the pipeline. Everything above proves the *mechanism*. Two consequences we make the transcript say out loud rather than letting a green run imply otherwise: one terminal lifecycle value is unreachable — no sanctioned function produces it — so check D reports which enum values the fixture *never exercised* instead of asserting a count of zero as though absence were coverage; and one of the two governed tables has no promote path, so its lifecycle coverage is genuinely narrower.

**A local perimeter result is weaker than a hosted one.** Vanilla PostgreSQL does not apply the managed platform's default grants to its anon/authenticated roles, so those `ALTER DEFAULT PRIVILEGES` statements record nothing locally and a local perimeter count of zero proves less than the same number on a hosted project. The check says so in its own output.

**The restore runs with triggers disabled.** The guard that makes promotion meaningful would reject a bulk load of promoted rows, so `--disable-triggers` is required. Restoring is a trusted, superuser-equivalent operation; the verification afterwards is what re-establishes that the guards are present and armed. The restore itself is not guard-checked.

**Re-running the export produces a different package checksum.** Receipts record wall-clock time and successor rows get fresh identifiers. Checksums prove integrity *within* a run. This is not a reproducible-build claim.

---

### Two defects this work found in itself

Recorded because they are the failure class the issue is about, and both were found by guards that existed for unrelated reasons.

**The schema inventory truncated every object key to 63 characters.** A `UNION ALL` resolved the key column to PostgreSQL's `name` type from its first branch. Nineteen distinct constraints collapsed onto one key. It was caught only by a duplicate-key guard in the canonicalizer, which existed because a duplicate key would make the comparison ambiguous. Without that guard the comparison would have "passed" while comparing nineteen objects to each other.

**The hashing script changed the thing it measured.** The first version built results in a `CREATE TEMPORARY TABLE`. That is DDL, and there is an event trigger on `ddl_command_end`, so *measuring* the database wrote a row into the schema changelog. Source and destination each added exactly one row, so counts matched and content hashes differed — a failure with nothing to do with the restore. Both tempting fixes are wrong: excluding the changelog stops verifying the one table that records schema tampering, and disabling the event trigger during hashing hides the measurement instead of not making it. The measurement now emits no DDL at all.

---

### Bottom line

`tests/sovereignty_proof.sh`, `tests/verify_restore.sh`, `tests/canonicalize_inventory.py` and `docs/07` are a credible implementation of §3–§6 and of four of this issue's negative acceptance criteria, on a synthetic fixture, with the verifier's discrimination proven rather than assumed. They are **not** an implementation of the CLI surface, the product-state vocabulary, the portability lint, or the custody receipt in §7 — and the skip path as written can be mistaken for a pass by any machine reader. We would not describe this issue as satisfied.
