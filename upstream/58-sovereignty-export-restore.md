We built the export/restore proof for #58. One command:

```sh
./tests/sovereignty_proof.sh
```

Exit 0 means the repo's own migration path rebuilt the schema in an empty
cluster, a package exported from it restored into a **different** cluster with no
reference to the original host, the restored copy matched the source at the level
of **definitions rather than object names**, and the verifier was shown to fail
on 22 deliberate corruptions while correctly ignoring 2 semantically-equivalent
reformats. Full write-up: `docs/07-sovereignty-export-restore.md`.

## The correction that drove the whole design: name-equality is not definition equivalence

Our previous evidence of "the fresh build matches the deployment" was a
comparison of object **names**, filtered to non-extension objects. A reviewer
correctly observed that **name-equality does not prove definition equivalence.**
All of the following pass a name check cleanly:

- a function with the right name and a rewritten body
- an index with the right name over different columns
- a trigger with the right name pointed at a different function
- a table with the right name and a dropped constraint
- a `SECURITY DEFINER` function silently flipped to `SECURITY INVOKER`
- a definer function with its `search_path` removed
- a permissive RLS policy appearing where the model was deny-all

Every one of those is now in the corruption suite. Several are caught by the
definition check and by **nothing else** — notably `EXECUTE` granted to a third
role, which the perimeter check cannot see because it looks at `anon` and
`authenticated`; and a single permissive RLS policy, which converts the entire
access model without changing one row or one object name (every table here is
RLS-enabled with no policy, i.e. deny-all for non-superusers).

If your conformance story rests on comparing object inventories, this is the part
we would most want upstreamed.

## Why raw text does not work either — and the pair that proves it

The obvious fix is to hash `pg_get_functiondef()`. That **fails on a real pair in
this repo.** The deployed `refresh_retrieval_units()` and the version in
`sql/27_retrieval_acl_drift_fix.sql` are semantically identical and textually
different: the applied migration carried a condensed body, the repo file keeps
the full rationale. Measured:

```
real body   4387 chars   raw md5 differs
condensed   3467 chars   raw md5 differs
canonical hash: IDENTICAL
```

A raw-text check reports drift on that correct pair **forever**, and a checker
that cries wolf gets muted — after which it catches nothing. We have hit that
exact failure three separate times in this project (a perimeter check returning
two hundred rows of extension noise, a secret sweep matching shell builtins, and
this), so it is treated as a design constraint rather than a nuisance.

**What canonicalization does:** comments stripped and whitespace runs collapsed
**outside string literals and quoted identifiers**, by a quote-aware tokenizer
that understands `'…'` with `''` escapes, `"…"`, `$tag$…$tag$`, `--`, and nesting
`/* */`. Everything that is *not* the body is compared **exactly** — signature,
argument list, return type, language, volatility, security mode, strictness,
`search_path`, ACL, owner, RLS flags, enum labels, constraint definitions, index
definitions, trigger definitions, policy expressions, column types, defaults,
identity/generated markers.

The split is the whole point: **whitespace in a body is noise; whitespace in a
security mode is not a thing.**

## Proving the verifier can fail — this is the part that makes the rest mean anything

Steps 1–4 of the harness produce the same green transcript whether the checks
work or not. So `tests/prove_verifier_discriminates.sh` clones the restored
database once per case with `createdb --template`, applies **one** damage per
clone, and asserts both that verification fails **and that it fails on the
intended check** — a corruption caught by the wrong check is scored FAIL, because
"something went red" is not the same as "the check that owns this works". A
control runs first: the pristine restore must pass, since a verifier that fails
on everything catches nothing in particular.

Damage is applied with `session_replication_role = replica` and
`event_triggers = off` — what a tamperer with superuser would do, and what keeps
each case isolated. Without `event_triggers = off`, every DDL corruption would
*also* trip the row-count check via the DDL changelog, and "caught" would stop
meaning anything.

**The sensitivity claim, tested in both directions on the same real function
body.** Against the actual `refresh_retrieval_units()` — 4KB of plpgsql with nine
comment blocks — run through the entire verifier:

- condensed exactly the way the applied migration condensed it, semantics
  untouched → **must verify CLEAN**. That is 920 characters of pure formatting
  difference.
- the same condensed body with **one ACL predicate deleted** (`and ru.workstream
  is not distinct from m.workstream` — a single comparison, the exact defect
  `sql/27` exists to fix) → **must be CAUGHT**.

Blind to 920 characters of formatting, sensitive to one deleted predicate. Both
halves are asserted, because either alone is worthless: if it called the first
drift it would cry wolf on the real repo/deployment pair forever; if it called
the second clean it would miss the defect. The condensation is done with
`sed`/`tr`, deliberately **not** with our canonicalizer, so the tool is not
grading its own homework.

## The package, and three decisions in it

`manifest.json`, `MANIFEST.md`, `RESTORE.md`, `CHECKSUMS.sha256`, plus `meta/`
(versions, extensions, settings, git ref, per-file sha256), `schema/` (a copy of
the migration path, definition inventory, `pg_dump` schema reference), `data/`,
`hashes/` (per-table hashes, evidence locators, supersession chains, lifecycle),
`probes/`.

- **The package carries a copy of `sql/*.sql`, not just their hashes.** A package
  that requires you to already have the right checkout is a bookmark, not an exit
  path. The repo is still hashed against the package so drift is *reported*, but
  the restore does not depend on it.
- **The restore applies the migration path, not `pg_dump`'s schema.** #58 asks
  that the *supported* path be the thing proven. The `pg_dump` schema ships as a
  cross-check; if the two disagree, that disagreement is a **finding**, not a
  choice of which one to trust.
- **The payload is plain SQL.** A custom-format dump needs a compatible
  `pg_restore` to even read. For an artifact whose entire purpose is "you can get
  out", inspectability beats compactness.

14 post-restore checks (row counts, per-table content hashes, per-row evidence
locators, lifecycle distribution, provenance+citation, supersession chains,
attention index, perimeter+RLS, migration drift, definition equivalence,
extension inventory, 23 conformance probes, and probe verdicts compared against
the source so a probe cannot pass for a different reason). A canonicalizer
self-test runs **first**, because a comparison tool that cannot tell things apart
invalidates everything after it.

## Two defects this work found in itself

Recorded because they are the exact failure class #58 is about.

**The inventory truncated every object key to 63 characters.** A `UNION ALL`
resolved its key column to PostgreSQL's `name` type from the first branch, so
long object names were silently cut off and **nineteen distinct constraints
collapsed onto one key**. It was caught only by a duplicate-key guard in the
canonicalizer that existed because a duplicate key makes the comparison silently
ambiguous. Without that guard, the comparison would have "passed" while comparing
nineteen objects to each other.

**The hashing script changed the thing it measured.** The first version built
results in a `CREATE TEMPORARY TABLE`. That is DDL, an event trigger on
`ddl_command_end` logs DDL, and so *measuring* the database wrote a row into the
schema changelog. Source and destination each added one row, so counts matched
and content hashes differed — a failure with nothing to do with the restore. Both
tempting fixes are wrong: excluding the changelog stops verifying the one table
that records schema tampering, and disabling the event trigger during hashing
hides the measurement instead of not making it. The measurement now emits no DDL
at all.

## What this proof does NOT establish

The full list ships **inside every package** so the person holding it has the
caveats, not just the checksums. The ones we would not want a reader to miss:

- **This is a synthetic fixture, not the deployment.** It proves the mechanism.
  The live deployment's rows have never been through this pipeline. Running it
  against a privacy-safe slice of real data is a separate, still-outstanding act.
  Everything above is mechanism.
- **Canonicalization is not semantic equivalence.** Bodies differing only in
  keyword case, alias names, or the order of commutative predicates hash
  *differently* and report as drift. The tool errs toward false positives
  deliberately — the alternative is missing a rewritten body.
- **Comment drift is invisible**, the flip side of stripping comments.
  Documentation can rot without this noticing.
- **A sha256 is not a signature.** It detects corruption and casual tampering.
  Anyone who can rewrite the data file can rewrite the checksums file. Signing is
  not implemented.
- **The restore runs with triggers disabled**, and must: our promotion guard makes
  `status='current'` unreachable by direct INSERT, so a `COPY` of promoted rows
  would be rejected by the very guard that makes promotion meaningful. Restoring
  a package is a trusted, superuser-equivalent operation; the verification
  afterwards is what re-establishes that the guards are present and armed. The
  restore itself is not guard-checked.
- **A local perimeter result is weaker evidence than a hosted one.** Our
  default-privileges migration exists because the hosted platform default-grants
  to `anon`/`authenticated` on new objects in `public`; vanilla PostgreSQL does
  not, so those statements record nothing locally and a local zero-row perimeter
  result proves less than the same result on a hosted project.
- **PostgREST, edge functions, cron, storage and auth are out of scope.** The
  package restores a database. **A restored database is a restored system of
  record, not a restored product.**
- **Identity bindings are empty**, so identity resolution — the layer that would
  make the capability model enforcement rather than decoration (see #45) — is
  untested here.
- **One lifecycle state is unreachable.** No sanctioned function produces
  `record_status = 'retracted'`; the enum value has no door into it. The check
  reports it as *unexercised* rather than asserting a count of zero as though
  absence were coverage.
- **`wiki_pages` has no promote path**, so wiki lifecycle coverage is genuinely
  narrower than memory lifecycle coverage (same gap named in #46).
- **Re-running the export produces a different package checksum.** Receipts record
  wall-clock time and successors get fresh UUIDs. Checksums prove integrity
  *within* a run; this is not a reproducible-build claim.

## Against the acceptance criteria

| #58 acceptance | Status |
| --- | --- |
| Clean independent environment functional from package + repo alone | Yes — second cluster, no reference to the original host |
| No original hosted-project API or hidden state required after packaging | Yes |
| Post-restore conformance passes with documented receipts | Yes — 14 checks, receipts in the package |
| Failure modes leave source untouched, destination disposable | Yes — export is read-only; every corruption case is its own throwaway clone |
| Rerunnable in CI or a documented local harness | Local harness today. Needs only PostgreSQL 17 + pgvector, runs in about half a minute, needs no cloud project and costs nothing — **not yet wired into CI** |

Remaining open items on our side: run the pipeline against a privacy-safe slice
of real data; sign packages (a checksum answers "was this corrupted", not "who
made this"); prove the perimeter claim on a hosted project where default
privileges actually exist; and add a `promote_wiki()` so wiki lifecycle coverage
matches memory lifecycle coverage.
