# Sovereign Vault

A business-owned knowledge and operations platform built on Postgres. Retail
chains, SaaS platforms, service businesses and other organizations can use the
same foundation to record facts, preserve evidence, govern corrections and
control access. Ordinary applications and authorized AI tools use the same
contracts. Core authorization and deterministic workflow checks do not require
an inference provider.

## Public platform, private deployment

**Schema and portable implementation in the repository; customer data and
configuration in the authorized deployment.** This project does not designate
a primary customer or publish any adopter's purpose, roster, grants, source
inventory, operating state or deployment identifiers. Synthetic examples
illustrate contracts; they do not describe a customer's activity.

See [the adoption guide](docs/14-business-platform-adoption.md) for the boundary
between reusable platform features, optional domain modules and private
deployment adapters. Public issues, pull requests and release notes follow the
same boundary as source files.

## What the foundation provides

- Provenance and temporal history: facts retain sources and corrections
  supersede prior versions.
- Multiple human and application principals with explicit capabilities and
  request-derived identity.
- Database enforcement through RLS, restricted functions, custody rules and
  a perimeter report.
- Preserve-then-normalize imports, review queues and versioned evidence.
- Retrieval whose vector index is a regenerable cache, with source records
  remaining authoritative.

The [business access candidate](https://github.com/WireSpeedComputing/Sovereign-Vault/pull/37) adds four fixed
memory tools, staged-write receipts, live-session checks and a configurable
workflow reducer. It is implementation for review and isolated acceptance,
not a claim that any customer has deployed it.

## Source organization

| Path | Purpose |
| --- | --- |
| `sql/` | Cumulative implementation, including generic foundation and optional domain modules |
| `pending/` | Candidates excluded from automatic migration replay |
| `contrib/business-platform/` | Fixed client tools and deterministic workflow logic in candidate PR #37 |
| `tests/` | Executable synthetic acceptance and regression controls |
| `docs/01-architecture.md` | Identity, lifecycle and domain integration contract |
| `docs/02-onboarding-principals.md` | Placeholder onboarding templates |
| `docs/03-identity-capability-enforcement.md` | Identity and capability boundary |
| `docs/06-public-safety-checklist.md` | Publication checks for source and tracker text |
| `STATUS.md` | Source inventory and validation limits |

Supplier, claim and compliance files are optional reference modules. They are
not universal business policy and do not identify any adopter's use case.
Replacing a domain module requires checking its dependency closure; merely
skipping numbered files is not an installation procedure.

## Start with an isolated installation

1. Read the architecture and adoption guides and choose a source revision.
2. Reproduce that revision's acceptance on disposable Postgres with synthetic
   data. The historical `tests/replay_fresh_install.sh` replays the cumulative
   schema, including optional domain modules; it is not a minimal core installer.
3. Review the chosen installation profile, identity provider, client bindings,
   RLS and direct API exposure. Use `perimeter_report()` and require
   `evaluation_status = 'evaluated'` and `violation_count = 0`.
4. Keep real bindings, grants, source mappings and business policies in private
   deployment configuration. Test authorized and denied paths using the actual
   client before admitting live data.
5. Add your business schema and workflows through the documented contracts.

Fresh replay does not establish an upgrade path for an existing database.
Deployment owners must compare object definitions, plan rollback and qualify
their own installation. [STATUS.md](STATUS.md) distinguishes source validation
from live deployment evidence.

## License and architectural lineage

Licensed under Apache License 2.0. See [LICENSE](LICENSE), [NOTICE](NOTICE) and
[DCO.md](DCO.md). Public architectural influences are recorded in
[LINEAGE.md](LINEAGE.md), including
[jryski/sovereign-memory-core](https://github.com/jryski/sovereign-memory-core).
Legal attribution is independent of customer identity.
