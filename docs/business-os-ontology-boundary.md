# Business OS ontology boundary

This note says which Business OS concepts may appear in Sovereign Vault's
public schema and docs, and which stay in HOUSE, in the VAULT data plane, or
in other repositories.

Primary Users have allowed this docs-only write-up. AI-MEMORY-ATLAS remains
the architecture owner. This file is a boundary. It is not an architecture
decision, a schema change, or a custody design.

## The one thing to read first

**This plane publishes names and contracts. Records stay in a data plane.**

The README states the rule this repository lives by: schema in the repo, data
in the database. `docs/06-public-safety-checklist.md` is the publication rule
that sits on top of that split. A portable claim about what the schema can
express belongs in this plane. A fact about a person, a household, a running
deployment, or a business's own records stays out of it.

"Business OS" is not a new object in the schema. In this note it means the
business-side concepts a deployment records: operational facts, decisions,
team authority, and domain records. This repository already publishes generic
machinery for how those facts are stored, sourced, corrected, and authorized,
and a contract for domain tables the business brings itself. It does not
publish a particular business's ontology as data.

## Terms

Three uses of "vault" already exist in this repository. This note keeps them
apart.

| Term | Meaning in this note |
|---|---|
| Public schema/docs plane | This git repository: DDL, enforcement functions, tests, templates, and docs. |
| Product and schema names | "Sovereign Vault", the `vault_auth` schema, and the `import_zone` value `vault`. These are names in the public plane. |
| VAULT data plane | The database a deployment runs. Rows live there. |
| HOUSE | Household and other personal-domain records, and the household ontology that describes them. |
| Other repos | Public siblings that already own a different trust model or a different domain. This note does not move their work. |

`sql/06_import.sql` declares `import_zone` as the enum `house`, `vault`,
`hold`, `evidence`, a label on a raw artifact. That enum is a name in the
public schema. It is not this boundary, and it is not permission to commit
the artifact it labels. This note does not give those four values a new
meaning.

## Concepts that may appear in this plane

These may appear as schema, as empty or placeholder templates, or as doctrine.
They may not appear as a real roster, a real grant, or a real record.

| Concept | Already public on main | What may appear here |
|---|---|---|
| Generic knowledge substrate: memories, wiki pages, hot index, deadlines, document integrity, DDL changelog | README; `docs/01-architecture.md` | The domain-agnostic layer: how facts are stored. |
| Provenance, temporal truth, supersession, record lifecycle (`proposed`, `current`, and the terminal statuses) | `docs/01-architecture.md`; `docs/04-record-lifecycle.md` | The contract for recording, correcting, and sourcing a fact. |
| Principals, capability grants, exact scopes (`workstream`, `table`, `record`, `domain`), identity-binding protocol | README; `docs/02-onboarding-principals.md`; `docs/03-identity-capability-enforcement.md`; `docs/05-scope-bound-authority.md` | Kinds, grammar, and placeholder people such as the examples in `docs/02`. |
| Import mechanics: preserve-then-normalize, batches, raw artifacts, human promotion | README (`sql/06_import.sql`) | The mechanism. Payloads stay out. |
| Consequential-domain kinds | `sql/61_consequential_domains.sql` | The declared kinds `financial`, `legal`, `medical`, and `identity` as enforcement categories. |
| Example domain module | README; `docs/01-architecture.md` (`sql/10`–`sql/12`) | An illustration of the bring-your-own-schema contract. The README tells a reader to skip or replace it. |

`docs/01-architecture.md` already draws the line inside the business side.
The generic layer owns how facts get recorded, corrected, sourced, and who
may touch them. Products, orders, suppliers, customers, and whatever else a
business tracks are that business's domain layer. Forcing those tables into
this repository would turn "bring your own schema" into a shared opinion
about someone else's business.

## Concepts that stay in HOUSE

Household and personal-domain concepts stay in HOUSE.

`LINEAGE.md` leaves personal-domain schemas, including household and homelab
schemas, out of this repository entirely, and it rejects a single-owner
assumption. `docs/10-sibling-pattern-adoption.md` records two concrete
divergences already made on that basis: this schema does not import a
household messaging table, and it does not identify people as a fixed pair of
household members. Principals are rows in a deployment database
(`docs/02-onboarding-principals.md`).

A public program route outside this repository sends household reference
architecture to [Household OS](https://github.com/jryski/Household-OS)
(`ROUTES.md` in `WireSpeedComputing/sovereign-ai-os`). This note does not
copy that ontology here, and it does not decide how HOUSE is deployed.

Live household records and other personal-domain records stay in the HOUSE
data plane. `docs/06-public-safety-checklist.md` already treats a household
detail as personal information that does not belong in a publication.

## Concepts that stay in the VAULT data plane

Business records stay in the VAULT data plane: the deployment database the
README describes. This git tree holds the schema that creates that database.

That includes:

- Real principals, grants, scopes, issuers, subjects, OAuth client
  identifiers, bindings, and token identifiers
  (`docs/03-identity-capability-enforcement.md`,
  `docs/02-onboarding-principals.md`).
- Personnel facts, project identifiers, incidents, and anything else that
  describes a real deployment (README, "The rule this repo lives by").
- Domain rows a business actually tracks. `docs/01-architecture.md` leaves
  those tables to the deployment that owns them.
- Records classified under a consequential-domain kind. The kind may be
  named in `sql/61_consequential_domains.sql`. The financial, legal, medical,
  or identity record itself stays in the database.
- Counts, digests, receipts, and narratives of a running system
  (`docs/06-public-safety-checklist.md`).

`docs/06-public-safety-checklist.md` is the checklist for keeping those
facts out of issues, pull requests, and docs even when no secret string is
present.

## Concepts that stay in other repos

- The personal, single-principal knowledge layer stays in
  [sovereign-memory-core](https://github.com/jryski/sovereign-memory-core).
  The README and `LINEAGE.md` describe this repository as a new repo with a
  different trust model, not a fork, and not a parity target.
- Household ontology stays with the household sibling named above, not in
  this business schema (`LINEAGE.md`, `docs/10-sibling-pattern-adoption.md`).
- A RAG framework, an agent framework, and a UI stay out of this repository.
  The README lists those as deliberately absent. This note does not assign
  them to a new owner and does not pull them in.

Generic business reference remains the public role of this repository.
Business-specific records remain in the deployment database.

## Explicit non-goals

- AI-MEMORY-ATLAS remains the architecture owner. This note does not decide
  schema shape, custody, or a structural split between HOUSE and VAULT.
  Issue #6 is the existing public design review of a HOUSE/VAULT zone split.
  It stays that review's question. This note does not answer it.
- No SQL, no migrations, no schema or contract changes, and no custody or
  architecture implementation.
- No private, household, personal, or financial payloads in this plane.
  Naming the consequential-domain kind `financial` is not permission to
  commit financial records. Placeholder people in
  `docs/02-onboarding-principals.md` stay placeholders.
- The example module in `sql/10`–`sql/12` is not a canonical Business OS
  ontology.
- The `import_zone` labels `house` and `vault` are not the HOUSE and VAULT
  data planes, and they are not a license to store those planes in git.
- This note refers to the human principal as Primary Users.
- Publishing this note does not merge it, does not lift a hold, and does not
  replace independent review. Issue #30 still expects an independent
  reviewer before any docs merge.

## Sources on main

- README.md — schema/data rule, personal-versus-business split, example
  domain module, what this repository deliberately omits.
- LINEAGE.md — household and homelab schemas left out; not a fork of the
  personal core.
- docs/01-architecture.md — generic layer versus bring-your-own domain layer.
- docs/02-onboarding-principals.md — roster and grants are deployment data.
- docs/03-identity-capability-enforcement.md — repository/data split for
  identity bindings.
- docs/04-record-lifecycle.md — candidate versus promoted record.
- docs/05-scope-bound-authority.md — scope grammar without a global scope.
- docs/06-public-safety-checklist.md — what must not be published.
- docs/10-sibling-pattern-adoption.md — household messaging and household
  member identity not imported.
- sql/06_import.sql — `import_zone` enum as it exists today.
- sql/61_consequential_domains.sql — consequential-domain kinds as they
  exist today.
