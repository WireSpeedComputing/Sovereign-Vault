# Source-locator contract for upstream #11

> Source/fixture note: this document states portable contracts and test methods.
> It does not report a customer corpus, access configuration, or hosted execution.

## Container integrity and candidate evidence are separate

`sql/03_provenance.sql` requires a non-empty citation for provenance bases
other than a direct human statement. A populated text field establishes that
a citation was supplied; it does not establish that the cited source exists or
supports the assertion.

`sql/06_import.sql` preserves raw artifacts with a payload hash and a
source-system/source-id identity. A candidate's `source_artifact_id` links to
the preserved container. That link and hash establish container identity and
integrity, not the exact span supporting each normalized assertion.

Later statement-source work is in `sql/42_statement_layer.sql`, with visibility
controls in `tests/52_statement_visibility_inheritance.sql`. Evaluate that optional layer by its
current source definitions; the historical absence of a field is not a claim
about a current installation. A retrieval unit's `exact_locator` identifies a
governed row or section for retrieval and must not be mistaken for proof of an
external source span.

## Proposed synthetic acceptance method

Use fabricated source text and assert each result separately:

- A non-empty citation naming a missing fixture target satisfies a presence
  check but must fail source resolution.
- A valid artifact link and container hash must not imply a verified quote.
- One fixture artifact produces multiple candidates with distinct locators;
  each candidate verifies its own quote, encoding, source version, and hash.
- Altering the source span, offset, encoding, or declared version invalidates
  verification even when a container identifier still resolves.
- Source evidence that is outside the request's authorized scope stays hidden.

These are test requirements, not a report that the tests have been executed.
Record the exact source revision and per-case outcome when running them.

## Accounting must tolerate one-to-many normalization

An artifact-to-candidate join can repeat an artifact when it yields multiple
candidates. Artifact accounting should count distinct artifact identities and
candidate accounting should count candidates separately. This connects #11 to
the scorecard/probe distinction in #12 without requiring any adopter metrics.
