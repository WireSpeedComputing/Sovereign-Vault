## A checker-design failure worth building into this issue's acceptance criteria

Downstream adopter report. This is not about the file-scanning scope of this issue directly; it is about a property any safety gate needs and that two of ours independently lacked. Offered because the second instance cost us a real leak and the first one had already taught the lesson.

### The observation

A grant-perimeter assertion — the function that answers "is anything in this schema exposed to the platform's unauthenticated and authenticated roles" — returned **242 findings** when run against a hosted deployment, and **zero** when run against a local replay of the same migrations.

The local zero was not a better result. It was the absence of the thing being measured. A managed PostgreSQL platform grants EXECUTE on extension-owned functions to its default roles when an extension is installed; vanilla PostgreSQL does not. So all but one of the 242 findings were vector-extension internals — arithmetic, comparison, distance and I/O functions — that the schema did not grant, does not control, and cannot revoke without breaking the extension for every legitimate caller.

The result: the check passed in the environment where it was developed and was unusable in the one environment it exists to protect. Nobody noticed, because what it produced there was 242 rows of noise, and 242 rows of noise reads as "that tool is broken" rather than "that tool found something". One real finding was sitting inside it.

**We had already learned this exact lesson and did not transfer it.** Our private pre-publication secret sweep used a case-insensitive pattern list that matched ordinary shell keywords, so it produced false positives on every script in the repository. The fix there was to split the pattern classes — hard identifiers case-insensitive, name-like tokens case-sensitive — rather than to keep a checker nobody could act on. Same failure, different tool, months apart. That is why we think it belongs in an acceptance criterion rather than in a postmortem.

### What made it actionable

Three changes, in `sql/28_perimeter_assert_signal.sql` against `sql/05_perimeter_assert.sql`:

1. **Exclude what the schema does not own.** Extension-owned objects are filtered by `pg_depend.deptype = 'e'`. Our fresh-install replay already drew exactly this line when it enumerated repo-owned functions; the perimeter check simply never did. Two tools, one boundary, one of them not using it.
2. **Declare deliberate exposures in a table, with a written reason — never in the function body.** An exception hardcoded into a `WHERE` clause is indistinguishable from a bug six months later, which is how exceptions rot. Ours is a table keyed on object kind, object identity and grantee, with a mandatory reason column and a declaration timestamp. The identity string must match the fully-qualified signature **including parameter names**, so renaming a parameter breaks the match and the finding reappears for review. That is the correct direction to fail: an exception that survives a signature change silently pre-authorises a function nobody reviewed.
3. **Make the exception list readable on its own**, via a review function that reports, per declared exception, whether the exposure is still present. An exception nobody re-reads is a permanent hole with a comment attached.

One restraint worth copying: the return signature of the assertion function was left **unchanged**. Every public signature change invalidates operating instructions elsewhere, and one such change was already being made in the same batch. One is a documented cost; two is carelessness.

### Applied result

After the change, on the same hosted deployment: **0 findings, 6 declared exceptions, every one confirmed still present** by the review function. Re-verified read-only today: still 0 findings, still 6 exceptions, and no table in the public schema without row-level security enabled.

We are **not** claiming the perimeter is safe. We are claiming the number is now a signal. Specifically:

- The review function reports **presence, not correctness**. It cannot tell you that the policy which makes a granted table safe still exists. Three of the six exceptions are table-level SELECT grants that are only defensible because each table also carries a deny-by-default policy resolving identity from verified claims. If a policy is ever dropped, those exceptions become real holes and the review function will still say "still present" — because it is. That is a separate assertion, and it has to be run.
- **A zero from a local run remains weaker evidence than a zero from a hosted one**, for the same reason the 242 existed: the default-grant behaviour that creates the exposure does not exist locally. Any CI gate built on this needs to say which environment it ran in, or its green means nothing.
- The 242 figure is the recorded pre-migration count. Current state we re-verified directly; the pre-migration state no longer exists to re-measure.

### Suggested acceptance criterion

For any safety gate this issue produces: **the regression fixtures must include at least one case that fails for the intended reason *and* at least one case that must NOT fire.** A checker is only useful if both directions are pinned. Ours failed twice on the second direction — a pattern list that matched shell builtins, and a perimeter check that matched extension internals — and in both cases the false-positive volume, not a false negative, is what made the tool stop being used. A gate that cries wolf is functionally identical to a gate that is switched off, and it looks green the whole time.
