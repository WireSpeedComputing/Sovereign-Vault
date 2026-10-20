# Security policy

Sovereign Vault is a business knowledge and operations platform whose database enforces identity, capability, RLS and custody rules. Reports that would let a principal read, write or approve outside its capabilities, defeat the perimeter report, corrupt history or custody, or leak an adopter's private configuration are in scope. Before posting anything public, read the [public-safety checklist](docs/06-public-safety-checklist.md).

## Report a vulnerability privately

Use this repository's private vulnerability reporting form:
<https://github.com/WireSpeedComputing/Sovereign-Vault/security/advisories/new>

If the form is unavailable, email <jryski@gmail.com> instead.

Do not put exploit details, credentials, tokens, private hostnames or real
personal, household, business or customer records in a public issue, pull
request, discussion or CI log. Use synthetic examples and redacted output.

Where you can, include:

- the affected commit, tag or file;
- preconditions and the trust boundary involved;
- a minimal reproduction using synthetic data;
- demonstrated and likely impact;
- whether secrets or personal data were exposed; and
- a proposed mitigation, if known.

## Supported versions

No production release of Sovereign Vault is supported. `main` and tagged pre-releases
are maintained on a best-effort basis.

## Other components

Each repository in the program has its own private reporting form. If the issue
is in another component, report it there. The
[program map](https://github.com/WireSpeedComputing/sovereign-ai-os) lists
every component.

