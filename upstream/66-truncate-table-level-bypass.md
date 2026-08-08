Second report from the same deployment as the field-lock comment above. The locks are applied and they hold. Probing what they do *not* cover produced something that belongs in this issue's conformance scope rather than in an implementation's tracker.

## Every enforcement mechanism here is row-level. What it protects against is not.

Four independent mechanisms guard the custody substrate. Read as a list, they are defence in depth:

| mechanism | wiring | file |
|---|---|---|
| custody field locks | `BEFORE UPDATE … FOR EACH ROW` | `sql/39_custody_field_locks.sql` |
| bounded status transitions | `BEFORE UPDATE … FOR EACH ROW` | `sql/13_promotion_deadlock_fix.sql` |
| hard-delete guard, writes a receipt when overridden | `BEFORE DELETE … FOR EACH ROW` | `sql/34_hard_delete_guard.sql` |
| append-only audit and receipt tables | `BEFORE UPDATE OR DELETE … FOR EACH ROW` | `sql/26_propose_then_promote.sql`, `sql/34_hard_delete_guard.sql` |

A governed record cannot be rewritten in place, cannot skip a lifecycle state, cannot be deleted without deliberately arming an override, and the override leaves a receipt. That is the whole perimeter, and every piece of it is `FOR EACH ROW`.

`TRUNCATE` fires none of them. It is statement-level; a row-level trigger never sees it. `DROP TABLE` and `ALTER TABLE … DISABLE TRIGGER` are DDL and are not constrained by any of the four either.

So one statement, from any role holding `TRUNCATE` on the table, destroys every governed record and defeats all four mechanisms at once. Nothing to arm, no receipt, and no row-level check anywhere in the perimeter that can observe it having happened afterwards.

Two details that make it worse rather than better:

- **The receipt tables are truncatable by the same privilege.** (This one also bears on #47, which asks whether promoted records are append-only, content-hash audited, or both — whichever is chosen, the audit store inherits this problem.) The delete-audit table exists precisely so that destruction is observable. It is protected by `BEFORE UPDATE OR DELETE … FOR EACH ROW`, exactly like the records it describes, so the same statement class that destroys the records also destroys the evidence that they were destroyed. "Append-only" in this design means *no row can be edited or deleted individually*. It does not mean the evidence cannot be destroyed, and it reads as though it does.
- **Referential integrity does not save you.** `TRUNCATE` against a table referenced by a foreign key fails and asks for `CASCADE`. `CASCADE` widens the blast radius; it does not prevent it. This is the same shape as the finding in the field-lock comment above — a protection that only holds for the malformed version of the attempt is not a protection, and it audits as one.

**Is the privilege actually held?** Queried rather than assumed, read-only, against the live deployment. Enumerating `TRUNCATE` from `information_schema.role_table_grants` over the governed tables and the receipt table returns, for each of them, the database owner and **the shared service role** — the credential every agent in this system runs under. It is not a stale grant and nobody granted it deliberately; it arrives with table creation on a hosted platform and is never the privilege anyone thinks to enumerate.

So the exposure is not theoretical for us and is unlikely to be theoretical for anyone else running the same shape: the single credential that all automation holds can destroy the governed corpus and its own delete-receipt table with two statements, defeating four triggers that were each individually verified to work.

The same class arrived once before, more visibly: prior to a default-privileges sweep (`sql/07_default_privileges.sql`), several objects created by earlier migrations carried the platform's default grant of the *full* privilege set — `SELECT/INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER` — to the network-facing roles. Those were found and revoked. They were found because a perimeter checker enumerates grants (`sql/28_perimeter_assert_signal.sql`) — and they were found as *read* exposure. `TRUNCATE` was in the list every time and was not what anyone was looking at.

## The generalisable claim

**A conformance criterion that verifies immutability by attempting row operations will certify a system whose immutability evaporates under one table-level statement.**

This is not a gap in a criterion's coverage; it is a gap in the *shape* of the criterion. This issue's first conformance bullet reads:

> In-place updates to every locked field fail through routine and service paths.

An implementation can satisfy that completely — ours does — while a single `TRUNCATE` removes the records the locked fields belong to. The criterion tests the operation an attacker would not choose.

The layered claims model in this issue is the right frame for the fix, and it already anticipates half of it: layer 1 is "database grants/constraints/append-only APIs for routine enforcement". Grants are named there and are doing no work in practice, because the enforcement everyone builds is triggers, and triggers are row-level. Layers 2–4 are what actually detect a table-level destruction, and they are the layers implementations defer.

## Suggested additions to the conformance scope

- [ ] For every table holding governed records or custody receipts, the roles holding `TRUNCATE` are enumerated and the set is empty apart from roles explicitly declared as break-glass. A run that cannot enumerate this **fails**; it does not skip.
- [ ] `TRUNCATE` attempted by a routine or service role fails. An implementation may satisfy this with a statement-level trigger or with privilege revocation — either is conformant, neither being present is not — and conformance asserts whichever mechanism is declared, by inspecting for it, not by inferring it from a successful `DELETE` rejection.
- [ ] Receipt, audit and checkpoint tables are covered by the same criterion as the records they describe, asserted **separately** for them. An evidence store destructible by the privilege it exists to observe is not evidence.
- [ ] Every row-level immutability criterion carries a statement-level companion. Suggested wording change: state the criteria as outcomes ("governed records cannot be destroyed or rewritten by a routine role") rather than as operations ("in-place updates fail"), so an implementation cannot pass by covering only the operations the criterion happens to name.
- [ ] `DROP TABLE` and `ALTER TABLE … DISABLE TRIGGER` are declared **out of scope for enforcement and in scope for detection**: conformance requires that an independently held checkpoint diverge after either, and requires the divergence to be *demonstrated on a corrupted fixture*, not asserted in prose. This is layer 3 earning its place rather than being deferred.

## One implementation note that may be worth borrowing

The gap above is recorded in our test suite (`tests/34_hard_delete_guard.sql`, section D, `limit_truncate_is_not_covered`) as a passing assertion that inverts when someone closes it: the test asserts that **no statement-level truncate trigger exists** on the guarded tables — `pg_trigger.tgtype & 32` over the guarded relations — with a detail string marked `KNOWN GAP`. It is asserted without executing a `TRUNCATE`, because running one would destroy the suite's own fixture to prove something inspectable.

The value is that the limit appears in test output rather than in a comment nobody reads, and the day someone adds the trigger, the suite goes red and forces the assertion to be rewritten as a real positive test. Documented limits rot; asserted limits do not.

Happy to contribute the statement-level trigger, the privilege enumeration query, and the inverting-limit test pattern as synthetic fixtures if useful.
