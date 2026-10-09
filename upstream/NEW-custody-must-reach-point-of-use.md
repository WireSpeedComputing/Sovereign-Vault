# Custody metadata at the point of use

> Source/fixture note: this document states portable contracts and test methods.
> It does not report a customer corpus, access configuration, or hosted execution.

## Contract gap to test

Recording authorization/assurance-at-write, actor evidence, and supersession
links is different from delivering them with the content a consumer receives.
A retrieval payload that omits those distinctions can turn a qualified custody
claim into an apparently unqualified fact.

Inspect the exact source projection for each consumer path. Citation, relevance,
effective time, and an exact locator do not substitute for:

- actor assurance, including an explicit caller-asserted or unknown state;
- the recorded asserting actor, with request-derived actor identity kept separate;
- visible supersession state and lineage;
- known contradictions, or an explicit statement that contradiction evaluation
  was not performed.

A caller-supplied principal UUID establishes neither the caller's identity nor
the authenticity of an assertion. That limitation follows from the API's
evidence, without describing any adopter's credential arrangement.

## Proposed synthetic method

Use fabricated records with different assurance levels, one current/superseded
pair, a known unresolved contradiction, and a projection whose copied access
metadata differs from its canonical source. Verify the authorized consumer
payload preserves each distinction while hiding inaccessible actors/records.
Compare a resolved identity with a deliberately unresolved one so a negative
result cannot masquerade as successful verification.

This is a proposed fixture design. It does not assert that these cases have
already been run or that a particular corpus contains them.

## Suggested requirement

1. Each returned assertion carries its recorded assurance and actor evidence,
   with an explicit unknown when the evidence is insufficient.
2. Supersession metadata resolves against readable canonical records. A hidden
   successor must not leak an identifier through a lineage field.
3. Context assembly reports known visible contradictions or an explicit
   not-evaluated state. Silence cannot mean that contradiction checks passed.
4. Truncation, missing evidence, and unqueried coverage remain explicit rather
   than being inferred away by a consuming model.

The same discipline applies to runtime answers and retrospective audit: a
field that was stored but never delivered cannot inform the consumer's decision.
