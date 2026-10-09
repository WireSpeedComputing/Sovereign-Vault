# Adopting the business platform

Sovereign Vault provides reusable knowledge governance and access tools for
different kinds of businesses. A customer does not need to make its own purpose
or data model public to adopt the platform.

## Three integration layers

| Layer | Shared public platform | Private deployment responsibility |
| --- | --- | --- |
| Foundation | Identity/capability composition, provenance, lifecycle, RLS, bounded tools | Identity bindings, grants, tenancy and approved connections |
| Business adapter | Versioned reader and workflow-policy contracts | Canonical tables, source mappings, rules and expected coverage |
| Application | Fixed tool registry and deterministic workflow reducer | User experience, integrations, reviewers and approved actions |

Optional domain modules are examples. They are not required categories,
a default customer profile or proof of any adopter's actual workflow.
Customer-specific adapters can live in private repositories or authorized
deployment configuration.

## Synthetic adoption examples

| Business type | Example workflow | Versioned evidence | Human decision |
| --- | --- | --- | --- |
| Retail chain | Review an inventory adjustment | Count sheet, receiving record, adjustment proposal | Approve the exact adjustment |
| SaaS platform | Review a release | Change record, regression result, release manifest | Authorize the exact release |
| Service business | Review a procedure change | Source policy, proposed procedure, review notes | Accept the exact new version |

Each uses the same request-bound tools and reducer. Server-owned configuration
defines check IDs, finding rules, severity floors and next actions.
An authorized reader binds the workflow and policy revision to the snapshot.
Stored text and callers cannot select policy or grant authority.

The outcome is `blocked`, `unknown` or `human_review_required`.
No findings does not mean approval, and an incomplete check does not mean pass.
Normal application code can perform these checks without an inference provider.

## Installation and compatibility

Choose an explicit, dependency-closed source profile and test it on a disposable
database. The historical cumulative replay includes domain examples.
Removing a domain file without checking later dependencies can break the schema.

The business access additions are review candidates described in
[PR #37](https://github.com/WireSpeedComputing/Sovereign-Vault/pull/37).
They require compatible canonical tables, reviewed human/client mappings,
and a qualified live-session boundary. They do not provide an automatic upgrade
for an arbitrary existing database.

Keep model choice outside authorization. Use verified user credentials for
ordinary client access; keep administration and promotion separate.

## Customer confidentiality

Do not publish adopter names, primary-customer labels, private repository links,
business purpose, source inventories, grants, operating metrics or incident
timelines in public source, history, issues, PRs, release notes or uploaded
artifacts. Review examples for indirect identification as well as literal names.

Preserve license and contributor attribution. Being an author or maintainer does
not identify a customer or confer authority inside a deployment.

Keep rollout receipts, live target qualification and actual workflow policy
in the private deployment record. Public validation should use synthetic fixtures
and portable claims.
