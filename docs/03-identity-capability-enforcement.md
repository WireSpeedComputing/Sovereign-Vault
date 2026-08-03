# Identity and capability enforcement

## Security claim

The vault has two deliberately different access paths:

- **Authenticated runtime:** Supabase/PostgREST verifies a JWT, connects as
  `authenticator`, and assumes the `authenticated` role. Only this path may
  resolve a request to human and agent principals.
- **Administrative control plane:** direct Postgres, management connectors, and
  service credentials remain privileged administration. They are not mapped to
  a principal and do not produce authenticated attribution.

A shared credential is authority, not identity. A caller that can set
`request.jwt.claims` on a direct database session must still resolve to no
principal. The identity layer therefore checks `session_user = 'authenticator'`
before trusting claims. It does not use `current_user`: a `SECURITY DEFINER`
function changes `current_user` to its owner, while `session_user` preserves the
connection provenance.

## Principal construction

Bindings live in the private `vault_auth` schema:

- `(issuer, sub)` maps to an active human principal.
- `(issuer, client_id)` maps to an active agent principal.
- A direct human request requires the human's capability.
- A request carrying `client_id` requires both the human and agent capabilities.
  Effective authority is their intersection.

The schema permits only reviewed, active, in-window bindings to resolve. It
rejects human subjects mapped to non-human principals and OAuth clients mapped
to non-agent principals. Superseded, revoked, expired, unreviewed, and
deactivated bindings fail closed.

`client_id` identifies an agent surface, not one concurrent model instance.
Audit receipts therefore also capture `jti` when available, falling back to
`session_id`. A real token must be inspected before the first binding is
activated to confirm which issuer-controlled claim carries the OAuth client
identity.

## Exposure boundary

Both binding tables have RLS and `FORCE ROW LEVEL SECURITY` enabled with no
policies. This is intentional deny-all, reinforced by zero direct table
privileges for `anon`, `authenticated`, and `service_role`.

`authenticated` receives only:

- `USAGE` on `vault_auth`;
- `EXECUTE` on `vault_auth.request_has_capability(text, capability_permission)`.

It cannot select binding or audit rows and cannot execute the raw resolvers,
validation trigger, audit trigger, or token helper. If a future migration
grants a runtime role direct table privileges, this two-control boundary has
been weakened and must be reviewed again.

The `postgres` administrative role may bypass RLS. That is expected for the
control plane and is why it must never be described as an attributable runtime
identity.

## Capability behavior

`public.has_capability()` now requires an active principal. Deactivation takes
effect even if an unexpired grant row still exists.

Scope matching remains exact. Wildcard capability semantics are intentionally
not part of this change; they enlarge the authorization surface and require a
separate migration and test matrix.

## Repository/data split

This repository contains the generic protocol:

- private schema and table definitions;
- resolver and capability functions;
- triggers, privileges, indexes, and tests.

It must never contain real issuers, subjects, OAuth client IDs, principals,
bindings, grants, token IDs, project references, or personnel information.
Those are deployment data and must carry the deployment's review, citation,
provenance, workstream, and source-agent requirements.

## Activation gates

Applying `sql/23_identity_capability_enforcement.sql` creates zero bindings and
zero grants. Before activating the first binding:

1. Observe a real authenticated PostgREST request and confirm
   `session_user = 'authenticator'` while `current_user = 'authenticated'`.
2. Decode and verify a real signed Auth/OAuth token. Confirm the issuer,
   `sub`, issuer-controlled `client_id`, and `jti`/`session_id` behavior.
3. Create reviewed binding rows with full deployment provenance; never publish
   them in this repository.
4. Add the minimum exact-scope grants and test human/agent intersection.
5. Build a derived-identity retrieval entry point. Existing retrieval APIs that
   accept a caller-supplied principal UUID remain administrative/internal.
6. Re-run cross-principal denial, unknown-user, unknown-client, expired,
   superseded, deactivated, and administrative forged-claim tests.
7. Re-check that the two private tables retain zero policies and zero direct
   runtime-role privileges.

Do not expose broad table access merely because authentication exists. Start
with a narrowly scoped read-only RPC, observe it, and widen only through a
separately reviewed change.

## Verification

Run the repository replay and regression test:

```sh
./tests/replay_fresh_install.sh
```

The replay invokes `tests/22_identity_capability_enforcement.sql`
automatically after applying all schema files.

The regression covers:

- active versus deactivated principal capability;
- exact scopes with no implicit wildcard behavior;
- reviewed human and agent binding resolution;
- unknown, expired, superseded, and deactivated binding denial;
- human/agent capability intersection;
- administrative forged-claim denial returning `false`, never `NULL`;
- binding mutation audit receipts;
- full rollback with no persistent test identities, bindings, or grants.

Positive testing of the real PostgREST token path is deployment-specific and
cannot be replaced by setting JWT-shaped text in an administrative database
session.
