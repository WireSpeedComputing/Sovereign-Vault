# Apply runbook: propose-then-promote

Covers `sql/26_propose_then_promote.sql` (upstream `sovereign-memory-core#46`
and `#47`) and its negative suite `tests/23_promotion_guards_negative.sql`.

**Status: this file is a procedure, not an action.** `sql/26` has not been
applied to any deployment. `sql/26` header lines 9–13 say so ("NOT YET APPLIED
to any deployment"), `STATUS.md` line 269 says so ("This file is in `sql/` but
the deployment does not have it"), and it is confirmed mechanically: grepping
`-- MIGRATION:` across `sql/` returns headers only for files 22, 23, 24, 25, 27
and 29. Files 26, 28 and 30 declare none, which `tests/migration_drift.sh`
lines 169–177 reads as not yet applied.

I did not run `tests/replay_fresh_install.sh` while writing this. Every claim
below about behaviour is read from the SQL, not observed on a running database.

---

## The one thing to decide before reading the rest

**Applying this means every decision record an agent writes needs a human to
promote it. Agents cannot promote their own work, and there is no way to grant
them that.**

Verified mechanism, three independent gates:

1. `enforce_insert_status_sanction()` (`sql/26` lines 53–63) raises on any
   `INSERT` at `status='current'` unless the session GUC `app.promoting` is
   `'on'`. It is wired as `BEFORE INSERT ON memories` at lines 73–76.
2. `promote_memory()` (`sql/26` lines 269–305) reads the promoting principal's
   `kind` and, at lines 281–283, raises `only human principals promote proposed
   rows` for anything that is not `'human'`.
3. `tests/23_promotion_guards_negative.sql` lines 95–101 assert exactly this:
   `ctl_agent_principal_cannot_promote` passes when an agent principal's call to
   `promote_memory()` is rejected.

The GUC is set only inside the definer functions. `sql/26` lines 38–44 are
explicit that this "closes the ACCIDENTAL path, not the deliberate one" — a
holder of `service_role` can arm the GUC and walk through, and
`tests/23` section D (lines 389–420) asserts that bypass still works so the
limit shows up in test output rather than only in prose.

### The friction is real and it lands on one person

Every agent-authored fact becomes a queue item. The queue has no ceiling and no
built-in surface:

- The only views in `sql/` are `memory_hot_ranked`, `deadlines_upcoming`
  (`sql/01_core.sql` lines 86, 123), `capability_grants_active`
  (`sql/02_principals.sql` line 55) and `import_cutover_scorecard`
  (`sql/06_import.sql` line 117). **None of them lists proposed rows.**
- `review_queue` (`sql/09_review_queue.sql` lines 26–43) exists but is not this.
  Its `kind` check constraint admits `contradiction`, `stale_state`,
  `duplicate_suspect`, `low_provenance`, `needs_confirmation`, and its header
  (lines 8–15) says it is "deliberately a real table, not a thin 'list of
  proposed rows' view", because "A proposed row and a contradiction are
  different things: a proposed row might simply be unreviewed, with nothing
  wrong with it." Nothing enqueues a plain proposed row into it.

So the reviewer's worklist is a query somebody has to write and keep running:

```sql
select id, left(content, 100) as content, source_kind, source_agent,
       provenance_basis, citation, workstream, owner, created_at
from memories
where status = 'proposed'
order by created_at;
```

That is the honest cost. It is not a one-time migration cost; it is a standing
demand on the owner's attention, proportional to how much the agents write.

### It is also correct

`tests/23` section B probes ten forbidden paths. `tests/23` lines 24–26 record
that at commit `161b835`, "nine forbidden paths probed, eight open". Without
`sql/26`, an agent can insert a row at `status='current'` declaring
`provenance_basis='decision_record'` with nothing verifying such a record exists
(`tests/23` lines 196–209, test `b7`), and it is authoritative immediately.

Both facts are true at once. Decide with both in view.

---

## Preflight

Run every check. Record the numbers — several of them are the only way to tell,
afterwards, whether something new went wrong or whether you are looking at a
pre-existing state.

### P1 — Confirm it is genuinely not applied, from both sides

Deployment side, read-only:

```sql
select version, name from supabase_migrations.schema_migrations order by version;
```

Expect no name containing `propose_then_promote`. Also confirm the objects are
absent:

```sql
select to_regclass('public.promoted_record_audit') as audit_table;   -- expect null
select tgname from pg_trigger
where tgname in ('trg_insert_status_sanction_memories',
                 'trg_artifact_promotable_memories',
                 'trg_artifact_promotable_wiki',
                 'trg_promoted_record_immutable_memories');           -- expect 0 rows
```

Repo side: save that output as `applied.tsv` (`version<TAB>name`) and run

```
./tests/migration_drift.sh applied.tsv
```

It must exit 0 before you start. Applying on top of an already-drifted
inventory means you will not be able to tell your change from the pre-existing
mismatch afterwards.

### P2 — Inventory every writer, because of the `status` default

**This is the item most likely to break production and the easiest to miss.**

`memories.status` is declared `record_status not null default 'current'`
(`sql/01_core.sql` line 26). I grepped `sql/` for any `ALTER COLUMN status` or
`SET DEFAULT` and found none — the default is still `'current'`.

Therefore, after this apply, **any `INSERT INTO memories` that omits the
`status` column is rejected**, because the column defaults to `'current'` and
the new trigger refuses that. The error text
(`sql/26` lines 58–61) talks about `status=current` even though the caller never
mentioned status, which makes it a confusing failure to diagnose from logs.

Every writer must be changed to insert explicitly at `status='proposed'` before
or with this apply. That includes anything that inserts via PostgREST or an edge
function.

**Blocker to name honestly:** this inventory cannot be completed from this
repository. There is no `supabase/functions` directory and no `.ts` or `.js`
file anywhere in the tree — I checked. `sql/29` lines 22–24 reference a deployed
`embed-retrieval-units` edge function whose source is not here. Whatever else
writes to `memories` on the deployment is likewise invisible from the repo. The
operator must enumerate the writers from the deployment side. Applying without
that enumeration is applying blind.

### P3 — Count what will become permanently `unaudited`

```sql
select count(*) from memories where status = 'current';
```

Record this number. Every one of those rows was promoted before
`promoted_record_audit` existed, so none has a receipt, and
`verify_promoted_integrity()` will report all of them as `unaudited` forever.
`sql/26` lines 227–230 state this is intended: "'unaudited' is expected and
honest for every row promoted BEFORE this file was applied… that is a real gap,
not a pass, and it is reported as its own state rather than folded into
'match'."

Without this number you cannot later distinguish "the expected legacy backlog"
from "something new stopped writing receipts".

### P4 — Measure the artifact-allowlist blast radius

`enforce_artifact_promotable()` (`sql/26` lines 93–111) requires any row with a
non-null `source_artifact_id` to reference a `raw_artifacts` row with
`action = 'import'`. It is wired `BEFORE INSERT OR UPDATE` on both `memories`
(line 117) and `wiki_pages` (line 122).

`BEFORE ... UPDATE` is the part with a live-data consequence. An **existing**
row whose source artifact is classified `hold`, `exclude`, `evidence`, or is
unclassified (`NULL`) becomes **un-updatable** after this apply — not just
un-insertable. Any later `UPDATE` to it, including an innocuous one like setting
`due_status='done'`, is rejected until the artifact is reclassified.

Count them first:

```sql
select action, count(*) from raw_artifacts group by action order by 1;

select count(*) as memories_that_will_lock
from memories m
where m.source_artifact_id is not null
  and not exists (select 1 from raw_artifacts r
                  where r.id = m.source_artifact_id and r.action = 'import');

select count(*) as wiki_pages_that_will_lock
from wiki_pages w
where w.source_artifact_id is not null
  and not exists (select 1 from raw_artifacts r
                  where r.id = w.source_artifact_id and r.action = 'import');
```

If either count is non-zero, decide before applying: reclassify those artifacts
to `import` if they genuinely are knowledge, or accept that those rows are
frozen. `sql/26` lines 82–91 explain why the rule is an allowlist rather than a
denylist — `action` is nullable by design, so `NULL` is the default state of
every landed artifact.

*(I have not run these queries. They are written from the schema, and
`memories.source_artifact_id` / `wiki_pages.source_artifact_id` are referenced
as existing columns by `sql/26` lines 97–101 and `tests/23` lines 119–124.)*

### P5 — Signature parity: this apply changes no public signature

Worth confirming explicitly, because `docs/08-contract-version-and-drift.md`
requires a pre-DDL instruction probe on any signature change, and this apply
does not need one.

| function | `sql/20` | `sql/26` | verdict |
|---|---|---|---|
| `promote_memory` | line 27, `(uuid, uuid)` | line 269, `(uuid, uuid)` | identical |
| `reject_memory` | line 61, `(uuid, uuid, text)` | line 382, `(uuid, uuid, text)` | identical |
| `supersede_memory` | lines 95–98, `(uuid, text, provenance_basis, text, uuid, text)` | lines 321–324, same | identical |

All three are `create or replace`; there is no `drop function` anywhere in
`sql/26`. Everything else the file adds is new
(`enforce_insert_status_sanction`, `enforce_artifact_promotable`,
`enforce_promoted_record_immutable`, `forbid_audit_mutation`,
`memory_authority_hash`, `verify_promoted_integrity`) and therefore additive.

Under `docs/08`'s proposed semver rule this is a MINOR bump, not MAJOR. No
existing caller's call shape breaks. The behaviour behind those calls does
change, which is what P2 is about.

### P6 — Prove the repo still builds, with this file in it

```
./tests/replay_fresh_install.sh
```

It applies `sql/*.sql` in numeric order and then runs every `tests/[0-9]*.sql`
that does not declare `REQUIRES-DEPLOYMENT` (lines 100–125).
`tests/23_promotion_guards_negative.sql` does not declare that opt-out, so it
runs; the replay script's comment at lines 90–99 records that an earlier version
of the loop wrongly skipped it and that the skip is now an explicit declaration
rather than a heuristic.

Requirement: `REPLAY CLEAN`, and `PASS 23_promotion_guards_negative.sql`. Note
what a green replay does **not** prove — the script says it itself at the end:
"a local replay cannot prove cloud-host default-privilege behavior on newly
created objects, nor extension placement."

`STATUS.md` (the paragraph beginning at line 266) records that these tests pass
on a fresh replay. Re-run it yourself; do not apply on the strength of a
recorded result.

### P7 — Name collision check

```sql
select proname, pg_get_function_identity_arguments(oid)
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and proname in ('enforce_insert_status_sanction','enforce_artifact_promotable',
                  'enforce_promoted_record_immutable','forbid_audit_mutation',
                  'memory_authority_hash','verify_promoted_integrity');
```

Expect zero rows. A pre-existing function under any of those names would be
silently replaced by `create or replace`.

### P8 — Restore point

Take a PITR checkpoint / note the recovery timestamp before applying. Read the
rollback section below first: several of the effects are not undone by dropping
objects, and a point-in-time restore is the only thing that actually reverses
them — at the cost of everything else written since.

---

## Apply

Apply the **whole file, unmodified, in one transaction**, as one named
migration. Suggested name: `NN_propose_then_promote` where `NN` is the next free
deployment migration number.

Do not split it. `sql/26` header lines 3–7 give the reason: `#46` controls how a
row becomes authoritative and `#47` controls what may happen to it afterwards,
and "Splitting them would put two halves of the same invariant in two migrations
that could be applied independently."

The file is re-runnable by construction: `create or replace function`,
`create table if not exists` (line 151), `create index if not exists`
(line 162), and `drop trigger if exists` before each `create trigger`
(lines 73, 115, 120, 173, 218).

The DDL logs itself. `trg_log_ddl_change` is an `ddl_command_end` event trigger
installed in `sql/01_core.sql` lines 197–198, so every statement lands in
`schema_changelog` without anyone remembering to record it.

### Immediately after: close the drift check

Add the header line to the repo file:

```
-- MIGRATION: NN_propose_then_promote
```

as line 3 of `sql/26_propose_then_promote.sql`, matching the placement in
`sql/22`, `sql/24`, `sql/25`, `sql/27`, `sql/29`.

This is not bookkeeping. `tests/migration_drift.sh` builds the applied set from
your tsv and the repo set from `-- MIGRATION:` headers, and reports anything
applied-but-not-declared under "applied but NOT committed" with `DRIFT=1`
(lines 128–138). Skip this step and the drift check goes red on your own apply.

Also update the header's status lines — lines 9–13 currently read "NOT YET
APPLIED to any deployment" and will be false.

---

## Post-apply verification

Run all of these. A green apply that you did not verify is the state this
project has repeatedly gotten burned by.

**V1 — the four triggers exist**

```sql
select t.tgname, c.relname, t.tgenabled
from pg_trigger t join pg_class c on c.oid = t.tgrelid
where t.tgname in ('trg_insert_status_sanction_memories',
                   'trg_artifact_promotable_memories',
                   'trg_artifact_promotable_wiki',
                   'trg_promoted_record_immutable_memories')
order by 1;
```

Expect 4 rows, all `tgenabled = 'O'`. `tgenabled` matters: `tests/23` line 336
disables one of these mid-test and re-enables it at line 338 — if a run of that
suite ever aborted between those lines on this database, the trigger would be
present but off.

**V2 — the audit table exists and is locked down**

```sql
select relrowsecurity from pg_class
where oid = 'public.promoted_record_audit'::regclass;      -- expect true

select grantee, privilege_type from information_schema.role_table_grants
where table_name = 'promoted_record_audit'
  and grantee in ('anon','authenticated');                 -- expect 0 rows
```

(`sql/26` lines 258–259 do the `enable row level security` and the revoke.)

**V3 — the receipt state matches the preflight count**

```sql
select state, count(*) from verify_promoted_integrity() group by state;
```

Expect `unaudited` equal to the P3 number, `mismatch` = 0, and `match` = 0 (no
row has been promoted through the new path yet). A `mismatch` on this first run
means a promoted row's authority-bearing fields do not agree with a receipt that
exists — investigate before proceeding, do not continue.

**V4 — the forbidden path is actually closed** (roll it back; it writes nothing)

```sql
begin;
insert into memories (content, source_kind, provenance_basis, status, owner, visibility)
values ('post-apply probe','manual','human_direct','current',
        '<an existing active human principal uuid>','shared');
rollback;
```

Expect the exception from `sql/26` lines 58–61. If this insert succeeds, the
trigger did not install and nothing else in this file is doing what you think.

**V5 — the sanctioned path still works** (also rolled back)

```sql
begin;
insert into memories (content, source_kind, provenance_basis, status, owner, visibility)
values ('post-apply probe 2','manual','human_direct','proposed',
        '<human principal uuid>','shared')
returning id \gset
select promote_memory(:'id', '<same human principal uuid>');
select status from memories where id = :'id';               -- expect 'current'
select count(*) from promoted_record_audit where record_id = :'id';  -- expect 1
rollback;
```

`tests/23` `b8` (lines 211–225) is the same assertion in the suite: a guard that
closes the forbidden paths by also closing the approved import path "has broken
the system rather than secured it".

**V6 — drift check reconciles again**

Re-export `applied.tsv` and re-run `./tests/migration_drift.sh applied.tsv`.
Exit 0 required. This is what confirms the header edit above landed correctly.

### On running `tests/23` against the deployment: don't, casually

The suite is wrapped `BEGIN … ROLLBACK` (lines 37, 442) and is self-contained,
so it leaves no rows behind. But line 336 executes

```sql
ALTER TABLE memories DISABLE TRIGGER trg_promoted_record_immutable_memories;
```

inside that transaction. That takes an `ACCESS EXCLUSIVE` lock on `memories`,
held until the rollback — blocking every reader and writer of the table for the
duration. On a live deployment that is a short outage of the main knowledge
table.

Run the suite on the replay cluster (P6), where it is free. If you must run it
against the deployment, do it in a maintenance window and know why.

---

## Rollback

Read this section before applying, not after. The honest summary is that the
**guards** are reversible in minutes and the **data effects** are not reversible
at all.

### Recommended rollback: drop the triggers, keep everything else

```sql
begin;
drop trigger if exists trg_insert_status_sanction_memories    on memories;
drop trigger if exists trg_artifact_promotable_memories       on memories;
drop trigger if exists trg_artifact_promotable_wiki           on wiki_pages;
drop trigger if exists trg_promoted_record_immutable_memories on memories;
commit;
```

That is the whole rollback. Four statements. The enforcement stops immediately;
`promote_memory()`, `reject_memory()` and `supersede_memory()` keep working, and
the audit receipts keep being written.

**Do not "restore the `sql/20` versions" of the three functions.** That looks
like the clean revert and it is a regression:

- `sql/20`'s `supersede_memory()` builds its successor row from the column list
  at lines 131–134: `content, workstream, tags, source_kind, source_agent,
  source_ref, provenance_basis, citation, status, supersedes, effective_from,
  recorded_at, metadata`. It does **not** carry `owner`, `visibility`, or
  `source_artifact_id`.
- `sql/26`'s version (lines 354–361) does carry all three.
- `memories.owner` has no default (`sql/14_owner_visibility_columns.sql` line
  19 adds it as a plain nullable FK; lines 7–11 say a default is deliberately
  not set because it is deployment-specific data). `memories.visibility` is
  `NOT NULL DEFAULT 'shared'` (line 20).

So reverting `supersede_memory()` means the successor to a **private** memory is
created with `visibility='shared'` and `owner=NULL`. With migration 39
(`sql/27`) applied, `refresh_retrieval_units()` projects that faithfully, and
`retrieve_context()` filters on the unit's copy via `is_owner_or_shared`
(`sql/21` line 161; `sql/14` line 38) — meaning the correction to a private
record becomes visible to every principal. That is a privacy regression
introduced by the rollback itself.

If for some reason you do restore the old function bodies: **drop
`trg_insert_status_sanction_memories` first.** `sql/26` lines 307–320 document
the bug — the `sql/20` version closes the `app.promoting` window before
inserting the successor, which lands at `status='current'`, so with the trigger
still installed legitimate supersession is blocked by the guard meant to stop
illegitimate promotion. `tests/23` `b9` (lines 232–244) is the regression test,
"Verified failing before the span was widened."

### Partial rollback: keep the audit, drop only the promotion friction

If the friction is the problem and the tamper audit is not, drop one trigger:

```sql
drop trigger if exists trg_insert_status_sanction_memories on memories;
```

What you keep: promoted-record immutability, the append-only receipt table,
`verify_promoted_integrity()`, and the artifact allowlist.

What you give back, precisely — these `tests/23` section B cases reopen:

| test | line | what becomes possible again |
|---|---|---|
| `b5_import_package_cannot_self_confer_authority` | 163–172 | insert at `current` from an import artifact, bypassing `promote_memory` |
| `b6_ingest_cannot_self_confer_authority` | 177–184 | same via `source_kind='ingest'`, no artifact at all |
| `b6b_manual_cannot_self_confer_authority` | 187–194 | same via `source_kind='manual'` |
| `b7_agent_cannot_self_certify_decision_record` | 200–209 | an agent row lands at `current` on an unverified `decision_record` claim |

What stays closed: `b1`–`b4` (lines 137–160) are enforced by
`trg_artifact_promotable_*`, a different trigger, and are unaffected. And a bare
`UPDATE … SET status='current'` is still refused by
`enforce_bounded_status_transition()` from `sql/13` lines 56–71, which predates
this work and is wired at `sql/13` lines 75–76. So a partial rollback is not a
return to pre-`sql/13` behaviour — the `UPDATE` path stays guarded; only the
`INSERT` path reopens.

### What rollback does not undo

Be clear-eyed about this list. None of it is fixed by dropping triggers.

1. **`promoted_record_audit` rows already written stay.** They are receipts of
   real promotions and should stay.

   A precise note on the "append-only" guard, because the obvious assumption is
   wrong: `forbid_audit_mutation()` is wired `BEFORE UPDATE OR DELETE … FOR EACH
   ROW` (`sql/26` lines 173–176). A row-level trigger does not fire on
   `TRUNCATE`, and `DROP TABLE` is DDL and unaffected by it. So the receipts can
   in fact be destroyed — just not by the `DELETE` an operator would reach for
   first. "Append-only" here means "no row can be edited or deleted
   individually", not "the evidence cannot be destroyed". Do not destroy it.

2. **Rows sitting at `proposed` that were never promoted stay `proposed`.**
   Dropping the triggers does not promote them, and nothing promotes them
   automatically. They remain invisible to retrieval —
   `retrieve_context()` filters `ru.record_status = 'current'` (`sql/21` line
   160). Each one needs a per-row decision: promote, reject, or leave. Count
   them before deciding rollback is cheap:

   ```sql
   select count(*), min(created_at), max(created_at)
   from memories where status = 'proposed';
   ```

3. **Metadata written onto promoted rows stays.** `promoted_by`, `promoted_at`
   and `actor_assurance` are merged into `metadata` (`sql/26` lines 288–290).
   Nothing removes them.

4. **Client changes do not roll themselves back.** Every writer you changed in
   P2 to insert at `status='proposed'` keeps doing that against a database with
   no promotion gate. Those rows will accumulate as `proposed` and never become
   current until someone promotes them or the clients are reverted too. Roll the
   clients back in the same window or accept a growing silent backlog.

5. **What was refused during the window is not recoverable.** In-place edits to
   promoted records were rejected (`sql/26` lines 195–214). If a person gave up
   rather than superseding, that edit does not exist anywhere.

6. **The deployment can never be made "as if never applied."** The audit rows,
   the proposed backlog, and the promotion metadata are permanent facts about
   that database. Point-in-time restore is the only true reversal, and it
   discards everything else written since the restore point too. That is a
   different decision from a rollback, and it should be made as one.

### The rollback that is not available

There is no setting, grant, or capability that lets an agent principal promote.
`promote_memory()` checks `kind <> 'human'` and raises (`sql/26` lines 281–283);
so do `reject_memory()` (lines 394–396) and `supersede_memory()` (lines 337–339).
Changing that is a schema change, not a configuration change, and it would
delete the property `#46` exists to establish.

If the friction proves unworkable, the available moves are: partial rollback
above, full trigger drop above, or building a review surface so the human's
promotion decision is cheap rather than removing the requirement that they make
it. There is no fourth option that keeps the guarantee and removes the work.
