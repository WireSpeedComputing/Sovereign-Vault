## Summary

SQL's three-valued logic can silently disable verification and enforcement at
three independent layers. We found instances at two of them on the same day, in
the same deployment, by accident — one in a test harness, one in a security
predicate. The third layer is safe in our schema only because of a pairing that
was never written down as a requirement.

This is a protocol-level hazard rather than an implementation bug: any store
built on these patterns is exposed unless the requirement is explicit.

## Layer 1 — assertions that pass without asserting

A test suite reported 24 of 24 passing. Run against a function that lacked the
feature entirely, only 3 failed. **21 assertions could not distinguish a working
implementation from a broken one.**

The chain, verified at each step on PostgreSQL 17:

```
'{"a":1}'::jsonb ->> 'missing'                     -> NULL
(... ->> 'missing') = 'expected'                   -> NULL   (not false)
NOT NULL::boolean                                  -> NULL
bool_and(x) over {true, NULL, true}                -> true   (NULLs ignored)
count(*) FILTER (WHERE NOT x) over the same        -> 0
```

A missing key yields NULL, the comparison yields NULL rather than false,
`bool_and()` ignores NULLs and reports success, and a `FILTER (WHERE NOT pass)`
counter records zero failures. If a runner then greps output for a literal `f`,
a NULL renders as a blank column and is invisible there too. The assertion
passes at every layer without ever having checked anything.

Corrected forms: `bool_and(coalesce(pass, false))` and
`FILTER (WHERE pass IS NOT TRUE)`.

## Layer 2 — security predicates that return NULL

An access predicate was defined as:

```sql
SELECT p_row_owner = p_principal_id OR p_row_visibility = 'shared';
```

With a NULL owner and private visibility this is `(NULL OR false)` = **NULL**,
not false.

This is harmless in every call site that places it in a `WHERE` clause, since
NULL and false both exclude the row — it fails closed. It becomes a silent
bypass the moment anyone writes the negated form:

```sql
IF NOT is_owner_or_shared(...) THEN RAISE EXCEPTION ...;  -- NOT NULL is NULL
                                                          -- IF NULL does not fire
                                                          -- the guard never runs
```

The danger is that the function is correct for existing callers and a trap for
the next one. We caught this immediately before adding row-level policies built
on the same predicate.

Note that marking such a function `STRICT` **reintroduces** the defect, since
STRICT returns NULL whenever any argument is NULL. The NULL handling has to be
inside the body.

## Layer 3 — CHECK constraints pass on NULL

A CHECK constraint is satisfied when its condition evaluates to NULL. So:

```sql
CHECK ((binding_status <> 'active') OR (review_status = 'approved'))
```

with `binding_status = 'active'` and a NULL `review_status` evaluates to
`(false OR NULL)` = NULL, and the constraint **passes** — defeating a
dual-control invariant.

In our schema this is unreachable, because every column those constraints read
is declared NOT NULL. That was the right decision, but it was made implicitly.
Stated as a requirement: **a CHECK constraint is only as strong as the NOT NULL
on the columns it reads.**

## The pattern underneath all three

In each case the check itself was correct. What failed was the thing consuming
its result:

- `bool_and()` consumed a NULL assertion and reported success
- a runner consumed a NULL as a blank cell and reported no failure
- a shell pipeline consumed a failing checker through `grep`, so the pipeline
  reported grep's exit status rather than the checker's, and a real leak was
  published

Three different consumers, same failure. **The gate is rarely the weak part; the
thing reading the gate is.** Worth stating explicitly in any conformance
guidance, because reviewers naturally scrutinise the check and not its caller.

## Suggested protocol requirements

1. Security predicates MUST be total functions — always boolean, never NULL —
   and MUST NOT be declared STRICT.
2. Every CHECK constraint expressing an invariant MUST be paired with NOT NULL
   on every column it reads, and conformance should verify the pairing rather
   than the constraint alone.
3. Test aggregates MUST treat NULL as failure: `coalesce(pass, false)` and
   `IS NOT TRUE`, never bare `NOT`.
4. Test runners MUST treat an absent or blank result as failure, not as absence
   of failure.
5. A verification suite SHOULD be periodically run against a known-broken
   implementation to prove it discriminates. A suite that has never failed is
   not evidence that the system is correct; it is evidence of nothing.

Item 5 is what surfaced this. The suite was green; running it against the
pre-fix function is what exposed that 21 of 24 assertions were inert.

## Reproduction

```sql
SELECT ('{"a":1}'::jsonb ->> 'missing') = 'x'          AS comparison,  -- NULL
       (NOT (('{"a":1}'::jsonb ->> 'missing') = 'x'))  AS negated,     -- NULL
       bool_and(v)                                     AS summary      -- true
FROM (VALUES (true), (NULL::boolean)) t(v);
```

Happy to contribute the corrected assertion helpers and the totality test
matrix if useful.
