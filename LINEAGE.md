# Architectural lineage

Sovereign Vault is an independently maintained multi-user business platform.
Public architectural influences include
[jryski/sovereign-memory-core](https://github.com/jryski/sovereign-memory-core),
a personal knowledge-layer design. This attribution describes design influence,
not a customer, deployment or shared operating environment.

## Patterns carried forward

- Separate generic knowledge governance from business domain schemas.
- Enforce provenance in the database.
- Preserve prior versions when correcting facts.
- Treat vector retrieval as a regenerable projection.
- Preserve imported sources before normalization.
- Separate ownership from visibility.
- Apply read-side ranking limits without deleting canonical history.
- Reject whitespace-only required values.
- Distinguish a citation string from a resolvable source locator.

## Adaptations for multiple users

Principals, reviewed identity bindings and finite capabilities replace
single-owner assumptions. Authorization derives from the verified request;
an actor identifier supplied by a client is not authority.

Provenance is registry-driven so different consequential domain tables can
participate. Temporal fields distinguish when a fact was observed, effective
and recorded. Governed transitions protect custody and prior versions.

The perimeter covers both relation grants and function execution. A complete
evaluation result is required before treating the absence of reported
violations as meaningful.

Business tools stage observations and proposed changes separately from canonical
truth. A deployment can configure its own workflow checks without changing
the shared tool registry or assigning approval to a model.

## Independent evolution

Patterns transfer through explicit review. This project does not assume schema
parity, automatic upstream merges or one business domain. Public example modules
are optional references; customer adapters and policies remain private.

[NOTICE](NOTICE) preserves legal attribution. No private customer data, deployment
timeline, incident narrative or operating metrics are needed to explain these
architectural choices.
