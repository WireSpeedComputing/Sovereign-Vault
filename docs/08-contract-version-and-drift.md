# Contract version and instruction drift

**Status: DESIGN, with one runnable prototype.** No *SQL* function described
below exists in this repo or on any deployment, and nothing here has been
applied. The single exception is the extraction-and-search half of the Part 4
probe, which exists as `contrib/predll-signature-probe.sh` with its own
positive-control test; Part 4 marks precisely how much of itself that covers.

Every claim about what the schema *does today* is cited to the file and line it
was read from; every claim about what *should* exist is marked as a proposal.

Adopts upstream `sovereign-memory-core#70`.

## The failure

A migration corrects a public function. The migration is right. The
deployment's live operating instructions still teach the old signature, and a
fresh agent follows them the moment it boots. Repository CI cannot see those
instructions — they are private deployment data — so nothing catches it.

This is not hypothetical here. It has happened **four** times in this repo, and
each instance is recorded below with the file and line it was read from.

Instances 1–3 are applied to a deployment. Instance 4 is written, tested, and
**not applied** — it sits in `pending/`. It is listed anyway, and listed last,
because it is the only one of the four that the design in this document **would
not catch**, and a design is better judged against the case it misses than
against the three it was derived from.

## Four confirmed instances

### 1. `supersede_memory()` lost its 5-argument form

`sql/20_transition_concurrency_and_actor_custody.sql`

- Line 147: `drop function if exists supersede_memory(uuid, text, provenance_basis, text, text);`
- Lines 13–16 give the rationale: supersession "accepted no acting principal,
  did no active-human validation, and recorded no actor, so every supersession
  was attributable to nobody. The actor is now required and the old unaudited
  5-argument form is DROPPED, not left callable."
- The replacement at lines 95–98 takes six parameters
  `(uuid, text, provenance_basis, text, uuid, text)`.

Any instruction teaching the five-argument call became wrong at that line. The
drop was deliberate — leaving it callable was considered and rejected — so the
old call does not degrade, it errors.

### 2. `refresh_retrieval_units()` went from 3 to 4 return columns

`sql/27_retrieval_acl_drift_fix.sql`, applied as deployment migration 39
(`20260807182313`, header line 5).

- Lines 96–107 label this explicitly: "⚠ PUBLIC SIGNATURE CHANGE — this is the
  second live instance of the failure upstream #70 describes". The old shape
  was `(invalidated int, projected_memories int, projected_wiki int)`; the new
  one is `(invalidated int, repaired_acl_drift int, projected_memories int,
  projected_wiki int)`.
- Line 113: `drop function if exists refresh_retrieval_units();` — line 103
  explains why a drop was unavoidable: "CREATE OR REPLACE cannot widen a return
  type".
- The old 3-column shape is confirmed present in the prior file:
  `sql/21_governed_retrieval.sql` line 84,
  `returns table (invalidated int, projected_memories int, projected_wiki int)`.

Line 106 states the consequence in the file itself: "Any operating instruction,
runbook or client that destructures the 3-column shape is stale as of this
migration."

### 3. The embedding-backlog functions ran with no repo file

`sql/29_retrieval_embedding_backlog.sql`

- Header lines 4–7: applied as deployment migration
  `36_retrieval_embedding_backlog` (`20260807145802`), and "Transcribed from the
  applied definitions read back with `pg_get_functiondef()`, not retyped from a
  description."
- Lines 26–31: "Until this file existed, a fresh install from this repo produced
  a database where that edge function returns 500 on a missing RPC. The schema
  would look complete and replay clean; the embedding pipeline would simply be
  broken, and nothing in the repo said so… this file was the third instance of
  applied-without-a-file, after Migrations A and B."

`tests/migration_drift.sh` was built in response. Its own header, lines 8–18,
names all three: Migration A (#71), Migration B (#72), and
`36_retrieval_embedding_backlog`, and says "Every one was caught by a human
noticing. That does not scale."

This third instance is a different shape from the first two. Instances 1 and 2
are *repo changed, instructions stale*. Instance 3 is *deployment changed, repo
stale*. A contract version has to be able to express both directions or it only
solves half the problem.

### 4. `retrieve_context()` gained a third `retrieval_status` value

`pending/B_retrieval_topology_ISSUE72.sql` — **NOT APPLIED to any deployment.**

- Header lines 1 and 14–18: filed under `PENDING OWNER APPROVAL — DO NOT APPLY`.
  Part 2 is recorded there as `BUILT AND TESTED 2026-08-07`, with assertions in
  `pending/B_retrieval_topology_TEST.sql`, "all passing on a fresh PG17 replay
  with Part 1 applied. NOT applied."
- Lines 19–21 label it in the file itself: "⚠ PART 2 IS A PUBLIC SIGNATURE
  CHANGE to the most widely-used function in this schema. The envelope gains
  three keys and retrieval_status gains a THIRD VALUE. Any caller that switches
  exhaustively on retrieval_status … "
- Lines 83–86 enumerate the new domain: `not_evaluated`, `evaluated`, and the
  new `evaluated_partial_coverage`. Lines 208–211 are the `case` that emits it.
- The old two-value domain is confirmed in `sql/21_governed_retrieval.sql`
  line 215, and in `tests/21_transition_custody_and_retrieval.sql` lines 76 and
  81, which assert `= 'not_evaluated'` and `= 'evaluated'`.

Line 91 states the breakage directly: "A caller that silently treats an unknown
status as 'evaluated' was already wrong."

### Why instance 4 is the important one

Instances 1 and 2 move `pg_get_function_result`. Instance 3 moves the whole
function into existence. All three are visible to the Tier A digest designed in
Part 2.

**Instance 4 moves nothing the digest reads.** Compared line by line against
`sql/21_governed_retrieval.sql`:

| Tier A element | `sql/21` | `pending/B` | differs? |
|---|---|---|---|
| `proname` | `retrieve_context` | `retrieve_context` | no |
| `pg_get_function_arguments` | `(uuid, text, vector(384) default null, int default 8000, int default 20)`, same parameter names — `sql/21` lines 139–144 | identical — `pending/B` lines 114–119 | no |
| `pg_get_function_result` | `jsonb` (line 145) | `jsonb` (line 120) | **no** |
| `prosecdef` | `security definer` (line 146) | `SECURITY DEFINER` (line 121) | no |
| `provolatile` | unspecified → `volatile` | unspecified → `volatile` | no |
| `proconfig` | `search_path = public, extensions` | identical | no |
| ACL | `revoke execute … from anon, authenticated, public` (lines 243–244) | identical (lines 258–259) | no |

There is no `drop function` in the file — it is a `CREATE OR REPLACE`
(line 114).

So the contract digest specified in Part 2 is **byte-identical before and
after**, and `contract_version` would not bump unless a human noticed by hand.
The thing that changed is the value domain of a string field *inside* a `jsonb`
return value, and `jsonb` is structurally opaque to every element of the tuple.

The general statement is worth making plainly, because it is not specific to
this function:

> **Any function returning `jsonb` has an unversioned contract under this
> design.** The digest pins the envelope's existence, never its shape. A key
> added, a key removed, or an enumerated value widened are all invisible.

`retrieve_context()` is, by this file's own description, "the most widely-used
function in this schema", and it returns `jsonb` deliberately — `sql/21` header
line 19: "a jsonb envelope, never a bare rowset". The design's blind spot is
therefore centred exactly on its most-used surface. That is not an argument
against the digest; it is an argument against reporting a green digest as
"contract unchanged". See "What this digest deliberately cannot see" below,
which this instance turns from a theoretical caveat into a demonstrated one.

## What `migration_drift.sh` already covers, and what it does not

Read from `tests/migration_drift.sh`:

- It reconciles migration **inventories** — which `-- MIGRATION:` names the repo
  declares against which names the deployment has run (lines 99–160).
- Lines 24–30 state its own limit: "This compares migration INVENTORIES, not
  schema content. A repo file whose body has drifted from the applied object
  still shows as present here."
- Lines 78–83: it never connects to a deployment. The operator does the read.
  "a drift checker that holds production credentials is a bigger risk than the
  drift it detects."
- Lines 50–64: migrations at or before the baseline in
  `tests/migration_baseline.txt` (`20260729174800`) are out of scope, because
  the historical many-to-one mapping was never recorded and reconstructing it
  from names "would be a guess dressed up as an inventory".

Nothing in this repo compares a *signature* against anything. That gap is what
the rest of this document designs.

## Part 1 — What gets versioned

`#70` says "the canonical agent-operations contract". Three different things
could be meant, and they have very different churn rates, so this design
separates them.

### Tier A — the public function contract (versioned)

For every function in schema `public` not owned by an extension, the tuple:

| element | source | why |
|---|---|---|
| name | `p.proname` | |
| full argument list | `pg_get_function_arguments(p.oid)` | includes parameter **names** and **default values**; both are callable surface — `retrieval_embedding_backlog` has four defaulted parameters (`sql/29` lines 49–54) and a PostgREST caller passes them by name |
| result | `pg_get_function_result(p.oid)` | this is exactly what changed in instance 2 |
| security mode | `p.prosecdef` | |
| volatility | `p.provolatile` | |
| config | `p.proconfig` | the `search_path` setting |
| ACL | sorted `aclexplode(p.proacl)` | a revoked grant changes who can call it, which is contract |

The "not owned by an extension" filter is the same line
`tests/replay_fresh_install.sh` already draws for "repo-owned functions"
(line 74: `not exists (select 1 from pg_depend d where d.objid=p.oid and
d.deptype='e')`). Reusing it means the two tools agree on what "ours" means.

### Tier B — the PostgREST-reachable RPC surface (versioned separately)

Verified by reading every `grant execute` in `sql/`: there are exactly two, and
only one of them is in `public`.

- `sql/23_identity_capability_enforcement.sql` line 51 grants
  `public.has_capability(uuid, text, public.capability_permission)`.
- `sql/25_public_request_has_capability.sql` lines 58–60 revoke all and then
  grant `public.request_has_capability(text, capability_permission)` to
  `authenticated`.
- `sql/23` line 391 grants `vault_auth.request_has_capability(...)`, but
  `sql/25` header lines 13–17 record that `vault_auth` is deliberately not a
  configured Data API schema, so "The inner function was therefore granted and
  unreachable at the same time."

Everything else in `sql/` carries an explicit `revoke execute … from anon,
authenticated, public`.

Tier B is tiny and changes rarely. It is versioned on its own because a client
outside the database can only break against Tier B, and a version number that
bumps every time an internal definer function gains a parameter will be ignored
by exactly the people it is for.

### Tier C — the rest of the public schema (NOT versioned here)

Tables, columns, types, triggers, policies, indexes. Deliberately excluded. It
changes for reasons that do not affect any caller, and a version that bumps on
every index is noise. Drift there is the job of `perimeter_assert()` and of the
definition-level restore check that `tests/migration_drift.sh` lines 24–30 hand
off to the other half of upstream #58.

### A gap that has to be named

Issue #70 says "`docs/03-agent-operations.md` remains the sanitized
implementation contract."

**That file does not exist in this repository.** `docs/` contains
`01-architecture.md`, `02-onboarding-principals.md`,
`03-identity-capability-enforcement.md`, `04-record-lifecycle.md`,
`05-scope-bound-authority.md`. `03` is a different document with a colliding
number.

So the canonical prose contract #70 assumes is not present here under that name,
and this design cannot version it. What it *can* version is the installed
function contract (Tier A/B), which is derived from the database rather than
from a document and is therefore never out of date with itself. If a canonical
`agent-operations` document is later written in this repo, it gets a
`doc_integrity` blessing (the mechanism already exists — `bless_doc()`,
`current_doc_hash()`, `verify_doc_integrity()` in `sql/01_core.sql` lines
133–170) and its blessed hash joins the envelope in Part 3.

## Part 2 — How the digest is computed

### The case that forces canonicalization

`sql/27_retrieval_acl_drift_fix.sql` header lines 7–28, "REPO vs APPLIED:
EQUIVALENT, NOT IDENTICAL". The applied migration 39 and this repo file
describe the same function. The header lists what was checked after the apply,
not assumed: signature matches, security mode matches, volatility matches,
search_path matches, ACL matches — and "body — semantically identical, textually
condensed — DIFFERS".

Line 23 states the consequence directly: "But `md5(pg_get_functiondef())`
differs, and that matters… a definition-level restore check comparing raw text
will flag this pair as drifted forever."

A raw-text digest of function bodies is therefore not a candidate. It would
report drift on `refresh_retrieval_units()` on every run, forever, on a
deployment that is correct. Line 27 names the outcome: "it becomes another
checker that cries wolf."

### The rule

**The contract digest is computed over the canonical tuple in Part 1 Tier A. It
does not include the function body.**

```
canonical_line(f) :=
  proname || U+001F ||
  pg_get_function_arguments(oid) || U+001F ||
  pg_get_function_result(oid) || U+001F ||
  (prosecdef ? 'definer' : 'invoker') || U+001F ||
  provolatile || U+001F ||
  coalesce(array_to_string(proconfig, ','), '') || U+001F ||
  sorted(grantee || ':' || privilege_type from aclexplode(proacl))

contract_digest := sha256(
  array_to_string(
    sorted_C(canonical_line(f) for f in tier_A),
    E'\n'))
```

Notes that are load-bearing rather than decorative:

- **Sort under the `C` collation**, not the database's. `LC_ALL=C` is already
  pinned for the same class of reason in `tests/replay_fresh_install.sh`
  (lines 20–26) and `tests/migration_drift.sh` (line 67). A digest whose value
  depends on the server's locale is not a digest.
- **`aclexplode` output must be sorted**, because `proacl` array order is not
  stable across grant/revoke sequences that end in the same state.
- **`pg_get_function_arguments` is the deliberate choice over
  `pg_get_function_identity_arguments`.** Identity arguments give types only.
  Parameter names and defaults are part of what a PostgREST caller sends. If a
  parameter is renamed, every named-argument caller breaks and an
  identity-arguments digest stays green.

### What this digest deliberately cannot see

Body changes. A rewrite of `retrieve_context()`'s ranking that keeps the same
signature does not move the digest.

**Instance 4 is exactly this case, and it is not a rewrite of ranking — it is a
public contract break.** The envelope gains three keys and `retrieval_status`
gains a third value, while every element of the Tier A tuple stays identical.
So "body change" and "harmless" are not synonyms, and this section was
originally written as though they were. What the digest cannot see is not
merely *implementation*; it is **everything about the shape of a `jsonb`
return**, which for this schema is the primary caller-facing contract.

Two consequences that have to be carried forward rather than filed as a caveat:

1. A green digest means *the callable surface did not move*. It does not mean
   *callers are safe*. Any report that renders it as "contract unchanged" is
   overclaiming, and `agent_contract()` in Part 3 must not phrase it that way.
2. Semver (below) cannot be driven off the digest for `jsonb`-returning
   functions. Instance 4 is a MAJOR change — a caller switching exhaustively on
   `retrieval_status` breaks — and the digest offers no signal at all. For those
   functions the version bump is a purely human obligation, which is the weakest
   possible control and should be named as such rather than assumed.

This is a real hole and it is accepted knowingly, because the alternative is the
permanent false positive proved by `sql/27`. The body belongs to a separate,
canonicalizing definition-level check — normalize whitespace, strip comments,
then compare — which is the restore-verification half of upstream #58 and is not
this mechanism. Two checks with clean, stated boundaries beat one check that
does both badly and is muted within a week.

**That other half now exists**, and it closes this hole rather than leaving it
theoretical: `tests/canonicalize_inventory.py`, driven by `tests/verify_restore.sh`.
It was built independently and in parallel with this document, so the two were
reconciled after the fact rather than designed together — worth knowing, because
they arrived at the same boundary from opposite directions.

Proven on the same `sql/27` case that motivates the exclusion here: the real
condensed body (920 characters of formatting difference) hashes identical, while
that same body with **one ACL predicate deleted** (51 characters of meaning)
hashes different and is caught. Raw `md5` differs in both cases, which is exactly
why raw text is unusable.

So the division of labour is:

| check | sees | blind to |
|---|---|---|
| contract digest (this doc) | signature, security mode, volatility, config, ACL | body changes — **including `jsonb` envelope shape and enumerated value domains, i.e. instance 4** |
| canonical definition hash (`#58`) | body, plus everything above | comment-only drift; keyword-case and alias changes report as false drift |

Instance 4 would be caught by the canonical definition hash, since the body
genuinely changed. But it would be reported as *body drift*, indistinguishable
from a whitespace-surviving refactor, and `#58`'s check is a restore-time and
audit-time check rather than a pre-DDL gate. So the break is detectable after
the fact and by the wrong tool, which is close enough to "not caught" that it
should be recorded as a gap rather than as coverage.

Neither subsumes the other. The digest is cheap enough to run on every call and
stable enough to pin a contract version; the definition hash is a restore-time
and audit-time check. Both are asserted against their own limitations —
`canonicalize_inventory.py --self-test` covers 8 cases in both directions,
including the two documented failure modes.

### Version and digest are both required

A digest detects that something changed. It cannot say whether the change is
breaking. So the envelope carries both:

- `contract_digest` — computed, mechanical, detects the unintended.
- `contract_version` — a semver string, set by a human in the migration that
  changes the surface, communicating intent.

Proposed semver rule, derived from the instances above rather than from
convention:

| bump | meaning | worked example |
|---|---|---|
| MAJOR | a signature was removed, narrowed, or its result shape changed — **including the shape or value domain of a `jsonb` envelope** | instance 1 (`sql/20` line 147), instance 2 (`sql/27` line 113), instance 4 (`pending/B` lines 19–21) |
| MINOR | a signature was added; nothing existing changed | `retrieval_acl_drift()` added in `sql/27` line 215 |
| PATCH | ACL, volatility, or `search_path` changed without changing callability | `sql/25`'s grant to `authenticated` |

A MAJOR bump is the trigger for the Part 4 probe. A digest change with no
version change is itself a finding: it means the surface moved without anyone
declaring it, which is instance 3's shape.

## Part 3 — First-call introspection

### There is no `session_boot()`

> **⚠ THIS SECTION IS STALE AS OF WO-09.** An untracked
> `sql/32_session_boot.sql` appeared in the working tree while this document was
> being revised, defining
> `create or replace function public.session_boot(p_principal_id uuid)` at line
> 108. It is owned by concurrent work, is not committed, and was not reviewed
> here, so the section below is left exactly as it was written rather than
> half-corrected. **Re-verify before relying on any of it.** If that file lands,
> the proposed `agent_contract()` is an extension of an existing first-call
> surface, not a new one, and the reachability argument changes accordingly.
>
> Recording this rather than quietly rewriting the paragraph, because a document
> about instructions going stale against a moving schema should demonstrate the
> failure honestly when it happens to itself.

`#70` says "Expose that version/digest through `session_boot()` or another
first-call introspection surface."

I grepped the entire repository tree for `session_boot`. **The only occurrences
are prose references in comments** — `sql/14_owner_visibility_columns.sql`
lines 2 and 45, describing what the `owner` column is for ("whose working set a
row belongs to for session-boot orientation purposes"). There is no such
function, in `sql/`, `pending/`, `tests/` or `docs/`.

So this is a new surface, not an extension of an existing one, and nothing below
should be read as "add a field to the boot call".

### Proposed `public.agent_contract()`

Returns a single `jsonb` envelope. Shape borrowed from two things already in the
repo so an operator reads it the same way they read what they already have:

- `retrieve_context()` returns "a jsonb envelope, never a bare rowset"
  (`sql/21_governed_retrieval.sql` header line 19; envelope at lines 214–238),
  with an explicit `retrieval_status` of `evaluated` / `not_evaluated` and a
  `reason`.
- `verify_doc_integrity()` uses a three-state vocabulary `no-blessing` /
  `match` / `mismatch` (`sql/01_core.sql` lines 149–157), and
  `verify_promoted_integrity()` uses `unaudited` / `match` / `mismatch`
  (`sql/26_propose_then_promote.sql` lines 243–247). `sql/26` lines 227–230 say
  why the third state exists: "'unaudited' is expected and honest… that is a
  real gap, not a pass, and it is reported as its own state rather than folded
  into 'match'."

Proposed fields:

```
{
  "contract_version":    "2.0.0",
  "contract_digest":     "<sha256 hex>",
  "digest_algorithm":    "sha256/canonical-signature-v1",
  "digest_scope":        "tier_a_public_function_contract",
  "rpc_surface_digest":  "<sha256 hex over tier B only>",

  "instruction_state":   "match" | "mismatch" | "unattested",
  "instruction_digest_expected": "<sha256 hex or null>",

  "profile": {
    "propose_then_promote":   true | false,
    "promoted_record_audit":  true | false,
    "retrieval_acl_repair":   true | false,
    "embedding_backlog_rpc":  true | false,
    "capability_enforcement": "declared_not_enforced"
  },

  "degraded":        true | false,
  "degraded_reason": "<string or null>"
}
```

`instruction_state = 'unattested'` is the third state and it means *no operator
has ever registered an expected instruction digest for this deployment*. It must
never render as `match`. That is the same discipline `sql/26` applies to
pre-migration rows.

### Why the `profile` block is not optional

`#70` requires "Document profile introspection so agents do not assume identical
boot signatures across deployments." Two installs of *this repo* genuinely
differ today:

- `sql/26_propose_then_promote.sql` header lines 9–13: "NOT YET APPLIED to any
  deployment."
- Confirmed mechanically: grepping `-- MIGRATION:` across `sql/` returns headers
  for files 22, 23, 24, 25, 27, 29 only. Files 26, 28 and 30 declare none, which
  `tests/migration_drift.sh` lines 169–177 reads as "repo files declaring no
  migration (not yet applied)".

So a replay built by `tests/replay_fresh_install.sh` has
`promoted_record_audit`; the deployment does not. An agent that assumes both is
wrong on one of them. `profile` is how it finds out without guessing from an
error.

`"capability_enforcement": "declared_not_enforced"` is included for the same
reason `scope_authority_report()` hardcodes `enforced = false`.
`docs/05-scope-bound-authority.md` lines 9–16 explain that choice: "Nothing
consults the capability model yet… that column is hardcoded rather than
computed — not as a placeholder, but because reporting anything else would be a
lie."

### Reachability is the trap

The function is useless if a fresh agent cannot call it before it knows
anything. Two things must be true, and one of them has burned this project
already:

1. It must live in `public`. `sql/25` header lines 13–17 record a function that
   was granted to `authenticated` and still unreachable, because it lived in
   `vault_auth`, which is deliberately not a configured Data API schema.
2. It must be explicitly granted, and that grant must be declared as a
   `perimeter_exception`. `STATUS.md` lines 139–147 record that
   `perimeter_assert()` moved deliberate exposures "into a declared
   `perimeter_exception` table with a reason, rather than hardcoding them into
   the function body where they become indistinguishable from bugs", and that
   exactly one exception is currently seeded:
   `public.request_has_capability` to `authenticated`.

An `agent_contract()` grant would be the second such exception, and it should be
argued for on its own terms rather than slipped in.

### What it must not return

Per #70's boundary: no deployment identifiers, no principal names, no private
paths, no instruction content. Digests and booleans only. The `profile` block
names capabilities, not customers.

## Part 4 — The pre-DDL probe

### What it does

Given a pending `.sql` file and an operator-supplied corpus of live operating
instructions, refuse to let the DDL be applied while any instruction still
teaches a signature the DDL removes or reshapes.

### Credential posture

The probe never connects to a deployment and never reads private instruction
stores itself. The operator exports the instruction corpus to local text and
passes a path, exactly as `tests/migration_drift.sh` takes `applied.tsv`
(lines 73–85). Its stated reason applies unchanged: "a drift checker that holds
production credentials is a bigger risk than the drift it detects." It also
keeps live content out of the public repository, which #70's boundary requires.

### What it extracts from the pending DDL

1. **Explicit drops.** Every `drop function` target. Both confirmed instances
   are visible this way: `sql/20` line 147 and `sql/27` line 113.
2. **Silent reshapes.** Every `create [or replace] function` whose
   `pg_get_function_result` would differ from the installed one. This needs the
   installed contract, so the probe reads the Tier A snapshot from Part 1 — not
   the live database.
3. **Argument-list narrowing.** A `create or replace` that drops a defaulted
   parameter changes `pg_get_function_arguments` without any `drop function`
   line to grep for.

### What it searches for

For each affected signature, three pattern families, because an instruction can
name the old contract three different ways:

- **The bare name** — `supersede_memory`, `refresh_retrieval_units`. High recall,
  high noise; used to build the candidate set, not to block on its own.
- **Name with arity or argument list** — a call site with five arguments to
  `supersede_memory`.
- **The old result-column names in combination** — for instance 2, a passage
  mentioning `invalidated` and `projected_memories` *without*
  `repaired_acl_drift` is destructuring the dead 3-column shape. This is the
  pattern that catches a runbook that never writes the function name on the same
  line as the columns.

### What it blocks

Any hit blocks the apply and prints file, line, matched pattern, and which
signature it belongs to. It blocks the **DDL**, not the database. The deployment
is untouched and stays fully functional; the operator either updates the
instructions first or overrides with a recorded reason.

Silence is not a pass. If the corpus path is empty, unreadable, or older than
the last instruction edit, the probe exits *unattested* and blocks, for the same
reason `unaudited` is not folded into `match`.

### Instance 4 defeats all three extraction rules

Run the three rules above against `pending/B_retrieval_topology_ISSUE72.sql`:

1. **Explicit drops** — there are none. Confirmed: no `drop function` anywhere
   in the file.
2. **Silent reshapes** — `pg_get_function_result` is `jsonb` before and after.
   No difference to detect.
3. **Argument-list narrowing** — the argument list is character-identical.

The probe extracts nothing, searches for nothing, and reports clean on a file
that its own header calls a "PUBLIC SIGNATURE CHANGE".

A fourth extraction rule is therefore required, and it is weaker than the other
three because it cannot be derived from catalog metadata:

4. **Declared envelope-domain changes.** A `create or replace` whose new body
   introduces a `jsonb` key or an enumerated string value that the previous body
   did not emit. Detecting this mechanically means diffing the string literals
   reachable from `jsonb_build_object` between two bodies — doable, noisy, and
   not something a signature probe should pretend to do well.

The honest interim is a declaration: a migration that changes an envelope
**must** say so in its header, and the probe blocks on a `create or replace` of
a `jsonb`-returning function that carries no such declaration. That converts an
undetectable break into a required sentence, which is a real control even though
it is not a mechanical one. `pending/B` already writes that sentence
unprompted (lines 19–21), so the convention is being followed by hand today and
the probe would only be making it mandatory.

### What it cannot do

It greps text. An instruction that describes the old behaviour in prose without
naming an identifier — "the refresh returns three counts" — will not be found.
Stating that here so a green probe run is not over-read, in the same spirit as
`tests/migration_drift.sh` lines 185–187: "NOTE: inventory only… a file present
but stale still reads as clean here."

It also cannot see instance 4's class without rule 4 above, and rule 4 depends
on a human writing a header line.

### Prototype status

`contrib/predll-signature-probe.sh` implements the **extraction and search**
half of this design and nothing else: it parses drop/create targets out of a
pending `.sql` file, derives the three pattern families, and searches an
operator-supplied instruction corpus. It does not read a Tier A snapshot, so
rule 2 (silent reshapes) is limited to what the DDL text itself reveals, and it
does not implement rule 4.

It has its own positive control — `contrib/predll-signature-probe.test.sh` —
which proves it flags an instruction file teaching a removed signature and does
**not** flag an unrelated one. The rest of this document remains design only.

## Part 5 — Post-migration receipt and mismatch behaviour

**Design only. No degraded mode exists in this schema today.**

#70 requires a post-migration compatibility receipt and a defined mismatch
behaviour: "warn and fail closed for affected authority-bearing operations
without locking the principal out of read-only recovery."

The proposed split, using this repo's own vocabulary for which operations are
authority-bearing:

| class | examples verified in repo | behaviour on `instruction_state = 'mismatch'` |
|---|---|---|
| authority-bearing | `promote_memory()`, `reject_memory()`, `supersede_memory()` (`sql/20` lines 27, 61, 95), capability grant paths | refuse, with an error naming the contract version and the mismatch |
| read-only recovery | `retrieve_context()` (`sql/21` line 139), `retrieval_embedding_coverage()` (`sql/29` line 85), `retrieval_acl_drift()` (`sql/27` line 215), `agent_contract()` itself | stay available |

The dividing line is not arbitrary: it is the same line `sql/26` already draws
between a candidate and a promoted record (`docs/04-record-lifecycle.md`). An
agent working from stale instructions can still read and still report; it cannot
make anything authoritative.

The receipt itself is `agent_contract()`'s output captured at the end of the
migration and stored alongside the migration record.

## Conformance evidence — embeddings are never computed in SQL

#70's search-and-write guidance says: "Compute embeddings client-side only when
semantic retrieval is needed; never compute embeddings in SQL."

I read `sql/29_retrieval_embedding_backlog.sql` in full and checked both
function bodies against that rule.

**`retrieval_embedding_backlog(text, text, text, integer)`** — lines 49–79.
Its body is a single `select` (LANGUAGE sql, STABLE). It returns
`(unit_id, rendered_text, text_hash, reason)`. The only computation in it is
`encode(digest(ru.rendered_text,'sha256'),'hex')` — a SHA-256 hex digest used
twice: once as the returned `text_hash` (line 62) and once compared against
`e.rendered_text_hash` to detect that a stored vector no longer describes the
current text (line 75). It selects `ru.rendered_text` and hands it out. It
contains no vector expression, no vector cast, no call to any embedding
function, and no `INSERT`/`UPDATE` of `retrieval_embeddings`. It reads
`retrieval_embeddings` only through a `LEFT JOIN` to discover whether a row
exists and whether `e.embedding is null` (lines 65–74).

**`retrieval_embedding_coverage(text, text, text)`** — lines 85–115. Also a
single `select` (LANGUAGE sql, STABLE), returning one `jsonb` object built by
`jsonb_build_object`. Its four values are: a model label string, three counts
(`live_units`, `embedded_current`, `backlog`), and one boolean
(`semantic_recall_available`). Every reference to `embedding` is a null test —
`e.embedding is not null` (line 105) and `where embedding is not null`
(line 111). Nothing writes, and nothing constructs a vector.

**Conclusion.** Both functions only report *what needs embedding* and *what has
been embedded*. Neither produces a vector.

The file states the same claim about itself at lines 40–44: "Note what these
functions do NOT do: they never compute an embedding. They report what needs
embedding and what has been embedded. Vectors are produced client-side by the
edge function and written back." My reading of the bodies agrees with that
statement — I did not take the comment as the evidence.

**What I could not verify.** The claim that the deployed
`embed-retrieval-units` edge function computes the vectors client-side and
writes them back rests on the file's own header (lines 22–24) and on `sql/29`'s
grant of EXECUTE to `service_role` only (lines 123–126). The edge function's
source is not in this repository — there is no `supabase/functions` directory
and no TypeScript anywhere in the tree. So I verified that **SQL does not
compute embeddings**, which is what #70 forbids. I did not verify what the edge
function does, and this document does not claim to.

## Open items this design does not resolve

- No canonical `agent-operations` contract document exists in this repo to
  version (see Part 1). The Tier A/B digest works without one; the prose
  contract #70 assumes does not exist here.
- The digest is signature-only. Body drift needs the separate canonicalizing
  definition check, which is upstream #58's restore half and is unbuilt.
- The probe's instruction corpus format is undefined, because the live
  instruction surface is deployment data and is not in this repository. The
  operator defines the export; the probe defines only what it searches for.
- No degraded mode exists. Part 5 is a specification, not a description.
- **The digest is blind to `jsonb` envelope shape**, which is instance 4 and is
  the single largest hole in this design. Every caller-facing function in this
  schema that returns an envelope — `retrieve_context()`,
  `retrieval_embedding_coverage()`, `agent_contract()` itself — has an
  unversioned contract under Part 2. Rule 4 in Part 4 is the proposed partial
  mitigation and it depends on a human writing a header line.
- **`pending/README.md` contradicts `pending/B_retrieval_topology_ISSUE72.sql`
  about instance 4's status.** The README's table says Part 2 is "a design note
  only — not written, not tested"; the file header says "BUILT AND TESTED
  2026-08-07 (WO-08 Task 8)" with a passing test file. The file is the later and
  more specific record, and `pending/B_retrieval_topology_TEST.sql` exists, so
  the README is stale. Not corrected here because this document does not own
  `pending/`. Worth noting that this is the same failure the whole document is
  about — an index describing a thing it no longer matches — reproduced inside
  the repo's own documentation.
