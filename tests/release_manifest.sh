#!/usr/bin/env bash
# tests/release_manifest.sh
#
# Generate the release manifest for a sovereign export package: per-file
# checksums, a single package checksum, and a KNOWN LIMITATIONS section.
# Part of upstream sovereign-memory-core #58 ("Publish a release manifest with
# checksums and known limitations").
#
# Called by export_sovereign_package.sh; also runnable standalone to
# regenerate/refresh a manifest for an existing package directory.
#
#   usage: release_manifest.sh <package-dir>
#
# ── WHY THE LIMITATIONS SECTION IS IN THE SCRIPT AND NOT IN A DOC ──────────
# Because it must ship INSIDE the package. A limitations list that lives only
# in the repo is a limitations list the person holding the package -- the exact
# person the sovereignty claim is for -- does not have. It is written here, in
# the generator, so it cannot be omitted from a package by forgetting to copy
# a file.
#
# Every item below is a thing this proof genuinely does not establish. They are
# not caveats added for tone. If one of them stops being true, delete it here.

set -uo pipefail
export LC_ALL="${LC_ALL:-C}"

PKG="${1:-}"
[ -n "$PKG" ] && [ -d "$PKG" ] || { echo "usage: $0 <package-dir>" >&2; exit 2; }
PKG="$(cd "$PKG" && pwd)"

sha() { shasum -a 256 "$1" | awk '{print $1}'; }

# ── per-file checksums ────────────────────────────────────────────────────
# CHECKSUMS.sha256 and manifest.json/MANIFEST.md are excluded from their own
# contents -- a file cannot contain its own hash. The package checksum below
# covers CHECKSUMS.sha256 itself, so tampering with a file requires also
# rewriting the checksum file AND the package checksum, and the package
# checksum is what a verifier is told to compare.
( cd "$PKG" && find . -type f \
    ! -name CHECKSUMS.sha256 ! -name manifest.json ! -name MANIFEST.md \
    ! -name '*.err' \
    | LC_ALL=C sort | while IFS= read -r f; do
        printf '%s  %s\n' "$(shasum -a 256 "$f" | awk '{print $1}')" "${f#./}"
      done ) > "$PKG/CHECKSUMS.sha256"

FILE_COUNT=$(wc -l < "$PKG/CHECKSUMS.sha256" | tr -d ' ')
PKG_SHA=$(sha "$PKG/CHECKSUMS.sha256")
BYTES=$(cd "$PKG" && find . -type f -exec wc -c {} \; | awk '{s+=$1} END{print s+0}')

INV_FP="$(awk -F'\t' '$1=="FINGERPRINT"{print $2}' "$PKG/schema/inventory.hashes.tsv" 2>/dev/null)"
INV_N="$(awk -F'\t' '$1=="FINGERPRINT"{print $3}' "$PKG/schema/inventory.hashes.tsv" 2>/dev/null)"
TABLE_N="$(wc -l < "$PKG/hashes/table_hashes.tsv" 2>/dev/null | tr -d ' ')"
ROW_N="$(awk -F'\t' '{s+=$3} END{print s+0}' "$PKG/hashes/table_hashes.tsv" 2>/dev/null)"
LOC_N="$(wc -l < "$PKG/hashes/evidence_locators.tsv" 2>/dev/null | tr -d ' ')"
SQL_N="$(wc -l < "$PKG/meta/repo_sql_manifest.tsv" 2>/dev/null | tr -d ' ')"
GIT_COMMIT="$(awk -F= '/^git_commit=/{print $2}' "$PKG/meta/source_ref.txt" 2>/dev/null)"
GIT_CLEAN="$(awk -F= '/^git_tree_clean=/{print $2}' "$PKG/meta/source_ref.txt" 2>/dev/null)"
SRV="$(awk -F= '/^server_version=/{print $2}' "$PKG/meta/versions.txt" 2>/dev/null)"
EXPORTED="$(awk -F= '/^exported_at_utc=/{print $2}' "$PKG/meta/versions.txt" 2>/dev/null)"

# ── machine-readable manifest ─────────────────────────────────────────────
cat > "$PKG/manifest.json" <<JSONEOF
{
  "package_format": "sovereign-vault-export/1",
  "upstream_issue": "jryski/sovereign-memory-core#58",
  "exported_at_utc": "$EXPORTED",
  "source_server_version": "$SRV",
  "source_git_commit": "$GIT_COMMIT",
  "source_git_tree_clean": "$GIT_CLEAN",
  "sql_files": $SQL_N,
  "schema_objects": "$INV_N",
  "schema_fingerprint_sha256": "$INV_FP",
  "tables_hashed": $TABLE_N,
  "rows_hashed": $ROW_N,
  "evidence_locators": $LOC_N,
  "files": $FILE_COUNT,
  "bytes": $BYTES,
  "package_sha256": "$PKG_SHA",
  "package_sha256_is_over": "CHECKSUMS.sha256, which lists the sha256 of every other file in the package"
}
JSONEOF

# ── human-readable manifest, including KNOWN LIMITATIONS ──────────────────
cat > "$PKG/MANIFEST.md" <<MDEOF
# Sovereign Vault — Export Package Manifest

Upstream: jryski/sovereign-memory-core#58 (prove operational sovereignty).

| field | value |
|---|---|
| package format | \`sovereign-vault-export/1\` |
| exported at (UTC) | \`$EXPORTED\` |
| source server | \`$SRV\` |
| source commit | \`$GIT_COMMIT\` |
| source tree clean | \`$GIT_CLEAN\` |
| sql files carried | $SQL_N |
| schema objects | $INV_N |
| schema fingerprint | \`$INV_FP\` |
| tables hashed | $TABLE_N |
| rows hashed | $ROW_N |
| evidence locators | $LOC_N |
| files | $FILE_COUNT |
| bytes | $BYTES |
| **package checksum (sha256)** | \`$PKG_SHA\` |

The package checksum is the sha256 of \`CHECKSUMS.sha256\`, which itself lists the
sha256 of every other file. Verify with:

\`\`\`sh
cd <package> && shasum -a 256 -c CHECKSUMS.sha256 && shasum -a 256 CHECKSUMS.sha256
\`\`\`

## Contents

| path | what it is |
|---|---|
| \`meta/versions.txt\` | server/tool versions, encoding, collation, locale |
| \`meta/extensions.tsv\` | installed extensions with versions and schemas |
| \`meta/settings.tsv\` | server settings that affect how data renders or hashes |
| \`meta/source_ref.txt\` | repo commit, branch, and any uncommitted files |
| \`meta/repo_sql_manifest.tsv\` | per-file sha256 of every \`sql/*.sql\` |
| \`schema/sql/\` | **a copy of those files** — the package restores without the repo |
| \`schema/inventory.jsonl\` | definition-level inventory of every repo-owned object |
| \`schema/inventory.hashes.tsv\` | canonicalized per-object hashes + fingerprint |
| \`schema/pg_dump_schema_reference.sql\` | cross-check only, **not** the restore path |
| \`data/data.sql\` | \`pg_dump --data-only --disable-triggers\` payload |
| \`hashes/table_hashes.tsv\` | per-table row count + content sha256 |
| \`hashes/_table_hashes.sql\` | the exact SQL that produced them, so the destination re-runs it byte-identically |
| \`hashes/evidence_locators.tsv\` | per-locator row hashes, so a mismatch names the record |
| \`hashes/supersession_chains.tsv\` | materialized supersession lineage |
| \`probes/source_probes.txt\` | conformance probe transcript taken at the source |

## Restore

See \`RESTORE.md\`. Summary: create an empty PostgreSQL cluster, apply
\`schema/sql/*.sql\` in numeric order, load \`data/data.sql\`, then run
\`verify_restore.sh\`.

---

## KNOWN LIMITATIONS

**Read this before treating a green verification as proof of sovereignty.**
Each item is something this package genuinely does not establish.

### About the data

1. **This is a fixture, not the deployment.** The package was produced against
   \`tests/sovereign_fixture.sql\`, a disposable synthetic dataset. It proves the
   export/restore/verify MECHANISM works. It does not prove that the live
   deployment's particular rows survive a round trip, because the live rows have
   never been through this pipeline. Running this against the deployment is a
   separate, still-outstanding act.
2. **\`record_status = 'retracted'\` is never exercised.** No sanctioned function
   reaches that state; the enum value has no door into it. The lifecycle check
   verifies the four states that occur and reports \`retracted\` as unexercised
   rather than asserting a count of zero as though that were coverage.
3. **Embeddings are deterministic pseudo-vectors, not model output.** Vector
   columns, dimensions, uniqueness and staleness flags are verified. Nothing
   here shows that a real embedding pipeline survives a restore.
4. **No identity bindings.** \`vault_auth.principal_identity_bindings\` is empty,
   so identity resolution — the layer that would make the capability model
   enforcement rather than decoration — is untested by this package.

### About the schema comparison

5. **Canonicalization is not semantic equivalence.** Function bodies are
   compared after stripping comments and collapsing whitespace outside string
   literals. Two bodies that differ only in keyword case, alias names, or the
   order of commutative predicates will be reported as DRIFT even though they
   behave identically. The check errs loud, not quiet. (It has to canonicalize
   at all because \`refresh_retrieval_units()\` as deployed and as written in
   \`sql/27\` are semantically identical and textually different — a raw-text
   check reports drift on that correct pair forever.)
6. **Comment drift is invisible.** The flip side of item 5: a body whose only
   change is its commentary hashes identically. Documentation can rot without
   this check noticing.
7. **Extension-owned objects are excluded.** Local PostgreSQL installs
   \`pgcrypto\` and \`vector\` into \`public\`; Supabase installs them into
   \`extensions\`. Comparing them would compare the two hosts rather than the two
   copies of the vault. Extension VERSIONS are recorded in
   \`meta/extensions.tsv\` and compared separately, but extension internals are
   not.
8. **Role names are host-specific.** Owner and ACL strings carry role names. A
   restore onto a host with different role names needs \`--role-map\`, and using
   it is a DECLARATION that two roles are the same principal — not evidence.

### About what a local restore cannot reach

9. **Supabase default privileges are not reproducible locally.** \`sql/07\` exists
   because Supabase default-grants to \`anon\`/\`authenticated\` on new objects in
   \`public\`. Vanilla PostgreSQL does not, so those \`ALTER DEFAULT PRIVILEGES\`
   statements record nothing and \`perimeter_assert()\` returning zero locally is
   weaker evidence than the same result on a hosted project. This is the same
   limit \`tests/replay_fresh_install.sh\` already states.
10. **PostgREST, edge functions, cron, storage and auth are out of scope.** The
    package restores a DATABASE. The deployed system also has an
    \`embed-retrieval-units\` edge function, a PostgREST API surface, and
    Supabase Auth issuing the claims \`vault_auth\` resolves. None of that is in
    the package and none of it is verified. A restored database is a restored
    system of record, not a restored product.
11. **The restore path runs with triggers disabled.** \`sql/26\` makes
    \`status='current'\` unreachable by direct INSERT, so a \`COPY\` of promoted rows
    would be rejected by the guard that makes promotion meaningful.
    \`pg_dump --disable-triggers\` is therefore required. Restoring a package is a
    TRUSTED, superuser-equivalent operation; it is not a path an untrusted
    caller can use to smuggle rows past review, but it does mean the restore
    itself is not guard-checked. The verification after it is what re-establishes
    that the guards are present and armed.
12. **Package checksums are not signatures.** A sha256 detects accidental
    corruption and casual tampering. It does not establish who produced the
    package. Anyone who can rewrite \`data/data.sql\` can rewrite
    \`CHECKSUMS.sha256\` too. Signing is not implemented.
13. **Re-running the export produces a different package checksum.** Promotion
    and supersession receipts record wall-clock time and the successor rows get
    fresh UUIDs, so the fixture is deterministic in structure but not
    byte-identical run to run. Checksums prove integrity WITHIN a run; they are
    not a reproducible-build claim.
MDEOF

# ── restore instructions, shipped inside the package ──────────────────────
cat > "$PKG/RESTORE.md" <<'MDEOF'
# Restoring this package into a clean environment

These instructions assume nothing about the original host. No Supabase project,
no API key, no network access to the source is required or used.

## 0. Verify the package before trusting it

```sh
cd <package>
shasum -a 256 -c CHECKSUMS.sha256      # every file matches its recorded hash
shasum -a 256 CHECKSUMS.sha256         # compare to package_sha256 in manifest.json
```

If either fails, stop. A package that does not match its own checksums is not
evidence of anything.

## 1. Requirements

Read `meta/versions.txt` and `meta/extensions.tsv`. You need:

* PostgreSQL of at least the recorded `server_version_num`
* every extension listed in `meta/extensions.tsv`, at a compatible version
  (`pgcrypto` for `digest()`, `vector` for the embedding columns)
* `psql`

You do NOT need `pg_restore` — the payload is plain SQL on purpose.

## 2. Create an empty database

Use a cluster with nothing in it. The scripted path is
`tests/restore_sovereign_package.sh`, which builds a throwaway cluster on its
own port and data directory so it cannot touch anything already running.

```sh
createdb svrestore
```

## 3. Apply the schema

Apply `schema/sql/*.sql` in numeric order. This is the supported migration
path, and it is deliberately what gets applied rather than
`schema/pg_dump_schema_reference.sql` — the point of the proof is that the
repository's own migration path rebuilds the database.

```sh
for f in schema/sql/*.sql; do
  psql -d svrestore -v ON_ERROR_STOP=1 -q -f "$f" || { echo "FAILED: $f"; break; }
done
```

`pg_dump_schema_reference.sql` is carried as a cross-check. If the two disagree,
that disagreement is a finding, not a choice of which to use.

## 4. Load the data

```sh
psql -d svrestore -v ON_ERROR_STOP=1 -q -f data/data.sql
```

The payload was dumped with `--disable-triggers` and re-enables them at the end.
This requires superuser on the destination. See KNOWN LIMITATIONS item 11 for
why it is necessary and what it costs.

## 5. Verify

```sh
./tests/verify_restore.sh <package> [dbname]
```

This compares row counts, per-table content hashes, evidence locators,
lifecycle state, provenance, supersession chains and attention/hot-index
integrity against the package; re-runs the conformance probes; runs
`perimeter_assert()` and the migration drift check in the restored environment;
and compares the full definition-level schema inventory — signatures, ownership,
security mode, search paths, grants, triggers, policies, constraints and indexes,
with function bodies canonicalized — rather than object names.

A verification that only ever printed OK proves nothing, so a companion script
deliberately damages a restored fixture — one damage per clone — and asserts
that each corruption is caught by the check that owns it, while a
semantically-equivalent reformat of a function body is correctly ignored:

```sh
./tests/prove_verifier_discriminates.sh <package> <dbname>
```

Or run both, end to end, from an empty machine:

```sh
./tests/sovereignty_proof.sh
```
MDEOF

echo "   manifest  : $FILE_COUNT files, package sha256 $PKG_SHA"
exit 0
