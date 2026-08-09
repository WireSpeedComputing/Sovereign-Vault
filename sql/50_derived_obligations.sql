-- 46_derived_obligations.sql
--
-- NOT APPLIED to any deployment. Build-only. No MIGRATION: header until it is.
--
-- ############################################################
-- APPLY ORDER. Assumes, in order:
--   sql/40_task_board.sql            (tasks, task_referenceable, task_kind)
--   sql/49_task_board_policies.sql   (can_read_row composition on tasks)
-- ############################################################
--
-- ══════════════════════════════════════════════════════════════════════════
-- THE NON-GOAL, FIRST, BECAUSE EVERYTHING ELSE READS DIFFERENTLY WITHOUT IT
-- ══════════════════════════════════════════════════════════════════════════
-- THIS SYSTEM RECORDS OBLIGATIONS. IT DOES NOT DECIDE WHAT ANY REGULATION
-- REQUIRES.
--
-- Every rule in obligation_rules is a WRITTEN-DOWN READING of some external
-- source, made by a person, carrying that person's citation. The schema
-- guarantees that the reading is attributed, dated, confirmable and revisable.
-- It guarantees nothing whatsoever about the reading being correct.
--
-- Concretely, and these are not disclaimers, they are design constraints that
-- shaped the tables below:
--   * No rule is inferred. A rule exists because someone inserted a row.
--   * No rule is trusted by default. Seeded rules are marked
--     requires_confirmation and the read surface reports them as unconfirmed
--     until a named principal confirms them.
--   * No deadline is computed from a regulation. deadline_interval is a number
--     a person wrote next to a citation.
--   * Nothing here is legal advice, and a green board means "the duties someone
--     recorded are accounted for", never "you are compliant".
--
-- A system that quietly crossed from recording to deciding would look exactly
-- like this one with the citations dropped and requires_confirmation defaulted
-- to false. Both are asserted in tests/46 so the crossing cannot be silent.
--
-- ══════════════════════════════════════════════════════════════════════════
-- WHAT AN OBLIGATION IS, AND WHY IT IS NOT A TASK
-- ══════════════════════════════════════════════════════════════════════════
-- An action generates a duty that outlives it. You ship the reformulated
-- product (an action, completable, done); the duty to file a notification
-- within N days is created BY that action and is not discharged by it.
--
-- Modelling that duty as another task with a due date fails in one specific
-- way: the board would then contain two rows that look alike, and the one that
-- carries an external consequence would be closable by the same click as the one
-- that does not. So obligations are a separate table with a separate closure
-- path and separate rules:
--   * an obligation has a HARD deadline that cannot be edited (a deadline you
--     can move is a preference);
--   * an obligation cannot be closed without EVIDENCE, enforced by trigger;
--   * closing the originating TASK cannot close the obligation, and that is
--     structural rather than a convention -- see the closure path below;
--   * an obligation carries no lifecycle of its own beyond open -> closed, and
--     every closed state is terminal.
--
-- task_kind already reserves 'obligation' (sql/40) and says the model is not in
-- that file. This is that file.

-- ══════════════════════════════════════════════════════════════════════════
-- TYPES
-- ══════════════════════════════════════════════════════════════════════════
create type obligation_trigger as enum (
  'task_created',    -- the duty arises from the action being undertaken
  'task_completed'   -- the duty arises from the action being finished
);

create type obligation_status as enum (
  'open',
  'satisfied',   -- the duty was discharged; evidence describes how
  'waived',      -- a named principal determined it does not apply; evidence
                 -- describes on what basis. NOT a quiet dismissal.
  'void'         -- the originating action was reversed, so the duty never
                 -- attached; evidence describes the reversal.
);
-- All three non-open states are CLOSURES and all three require evidence. An
-- exception for 'waived' would be the whole hole: the path anyone takes when
-- they cannot produce the artifact is the path that must not be cheap.

-- ══════════════════════════════════════════════════════════════════════════
-- RULES ARE DATA
-- ══════════════════════════════════════════════════════════════════════════
-- A rule change is a ROW, not a migration. That is the requirement, and it is
-- also the only version that survives contact with reality: a reading of an
-- external source changes when the source changes or when someone reads it more
-- carefully, and neither event should need a deployment.
--
-- The matching grammar is deliberately small -- task kind, optional workstream,
-- and which event fires it. Small enough that a person reading a rule row can
-- predict exactly which actions it will attach to. A richer matcher (predicates
-- over arbitrary columns, an expression language) would make the rule table
-- programmable, and a programmable rule table is code that skipped review.
create table obligation_rules (
  id                  uuid primary key default gen_random_uuid(),
  rule_key            text not null unique check (btrim(rule_key) <> ''),
  description         text not null check (btrim(description) <> ''),

  -- MATCHING
  on_task_kind        task_kind not null,
  on_task_workstream  text,            -- null = any workstream
  generate_on         obligation_trigger not null,

  -- THE DUTY
  duty_title          text not null check (btrim(duty_title) <> ''),
  deadline_interval   interval not null check (deadline_interval > interval '0'),
  evidence_requirement text not null check (btrim(evidence_requirement) <> ''),

  -- THE BASIS. A rule with no citation is an opinion with a due date.
  authority           text not null check (btrim(authority) <> ''),
  citation            text not null check (btrim(citation) <> ''),

  -- CONFIRMATION. Defaults to true and RATCHETS: see the trigger below.
  requires_confirmation boolean not null default true,
  confirmed_by        uuid references principals(id),
  confirmed_at        timestamptz,

  declared_by         uuid not null references principals(id),
  created_at          timestamptz not null default now(),
  retired_at          timestamptz,

  constraint obligation_rules_confirmation_is_whole
    check ((confirmed_by is null) = (confirmed_at is null))
);

create index on obligation_rules (on_task_kind, generate_on) where retired_at is null;

comment on table obligation_rules is
  'Written-down readings of external requirements. Each row is one person''s reading, with a citation and an authority, and is marked requires_confirmation until a named principal ratifies it. A rule change is a row, not a migration. This table does not decide what any regulation requires -- see the non-goal at the top of sql/46.';

comment on column obligation_rules.requires_confirmation is
  'TRUE means the reading has not been ratified. It defaults to true and cannot be set back to true->false without a confirmation (see enforce_obligation_rule_confirmation_ratchet). Unconfirmed rules STILL GENERATE obligations -- suppressing them would trade visible uncertainty for an invisible missed duty -- and obligation_board reports basis_confirmed=false for every obligation resting on one.';

-- ── Confirmation ratchets ─────────────────────────────────────────────────
-- Same shape and same reason as tasks.requires_evidence in sql/40: a flag that
-- can be cleared is a flag that gets cleared by whoever is blocked by it.
-- Ratifying is confirming, not un-flagging. And a confirmation, once given, is
-- not withdrawable -- a reading someone later disagrees with is RETIRED, which
-- leaves the history intact, rather than un-confirmed, which erases it.
create or replace function enforce_obligation_rule_confirmation_ratchet()
returns trigger language plpgsql as $$
begin
  if old.requires_confirmation and not new.requires_confirmation then
    raise exception
      'obligation_rule %: requires_confirmation cannot be turned off. Ratify the reading by setting confirmed_by/confirmed_at, or retire the rule. Clearing the flag would leave every obligation derived from it reporting a confirmed basis it never had.',
      new.rule_key;
  end if;
  if old.confirmed_at is not null and new.confirmed_at is distinct from old.confirmed_at then
    raise exception
      'obligation_rule %: confirmed_at is immutable once set. A reading that turns out to be wrong is retired, not un-confirmed.',
      new.rule_key;
  end if;
  return new;
end; $$;

create trigger trg_obligation_rule_confirmation_ratchet
  before update on obligation_rules
  for each row execute function enforce_obligation_rule_confirmation_ratchet();

-- ══════════════════════════════════════════════════════════════════════════
-- OBLIGATIONS
-- ══════════════════════════════════════════════════════════════════════════
-- NOTE WHAT IS ABSENT: no owner, no visibility, no workstream, no citation.
--
-- Every one of those is available on the source task or the source rule, and
-- copying them here would rebuild the defect sql/36 documents at length: the
-- retrieval projection carried its own owner/visibility/workstream copies, a
-- copy went stale, and access was decided from a cache (ACL drift, migration
-- 39). An obligation is derived from a task in exactly the way a retrieval unit
-- is derived from a memory, so it resolves back to the task for visibility and
-- back to the rule for basis, and stores neither.
--
-- Cost: a join per row on every read. Accepted, for the same reason it was
-- accepted there.
create table obligations (
  id              uuid primary key default gen_random_uuid(),
  rule_id         uuid not null references obligation_rules(id),
  source_task_id  uuid not null references tasks(id),
  title           text not null check (btrim(title) <> ''),
  status          obligation_status not null default 'open',

  generated_at    timestamptz not null default now(),
  -- THE HARD DEADLINE. Immutable after insert; see the trigger below.
  due_at          timestamptz not null,

  closed_at       timestamptz,
  closed_by       uuid references principals(id),
  closure_note    text,

  constraint obligations_open_iff_not_closed
    check ((status = 'open') = (closed_at is null)),
  -- A duty whose deadline precedes its own generation is not a deadline, it is
  -- a typo that reads as permanently overdue. This is a CHECK and not a trigger
  -- because it must hold on INSERT too: the immutability trigger below only
  -- guards UPDATE, so a direct insert is the one place a nonsense window could
  -- enter. Both columns are NOT NULL, which is what makes the CHECK strong --
  -- a CHECK is only as strong as the NOT NULL beside it (sql/31).
  constraint obligations_deadline_after_generation check (due_at > generated_at),
  constraint obligations_closure_is_attributed
    check ((closed_at is null) = (closed_by is null)),
  -- one duty per (reading, action). Re-running the generator is a no-op.
  constraint obligations_one_per_rule_and_task unique (rule_id, source_task_id)
);

create index on obligations (source_task_id);
create index obligations_due_idx on obligations (due_at) where status = 'open';

comment on table obligations is
  'A duty derived from an action by a recorded rule. Carries a hard deadline that does not move, cannot be closed without evidence, and is NOT discharged by completing the task that generated it. Deliberately carries no owner/visibility/workstream/citation of its own: those resolve back to the source task and the source rule, because a derived table that caches its parent''s ACL is the defect migration 39 fixed.';

-- ── The terms of a duty do not change ─────────────────────────────────────
-- A deadline you can edit is a preference. The originating action and the
-- reading it came from are equally fixed: re-pointing an obligation at a
-- different task would let an inconvenient duty be re-parented onto something
-- already finished.
create or replace function enforce_obligation_terms_immutable()
returns trigger language plpgsql as $$
begin
  if new.due_at is distinct from old.due_at then
    raise exception
      'obligation %: due_at is immutable (% -> %). A deadline that can be pushed out is not a deadline. If the reading was wrong, retire the rule and void this obligation with evidence.',
      old.id, old.due_at, new.due_at;
  end if;
  if new.rule_id is distinct from old.rule_id
     or new.source_task_id is distinct from old.source_task_id
     or new.generated_at is distinct from old.generated_at then
    raise exception
      'obligation %: rule_id, source_task_id and generated_at are immutable. Re-parenting a duty onto another action is how a duty gets discharged by something that never addressed it.',
      old.id;
  end if;

  -- FOUND BY A DELIBERATELY-BROKEN RUN, not by review. With the evidence check
  -- removed from the closure trigger, a test that expected a direct UPDATE to be
  -- refused instead SUCCEEDED -- because the row was already closed, so
  -- `status` did not change, so trg_obligation_closure_path returned early and
  -- nothing else looked at the columns the UPDATE was actually rewriting.
  --
  -- The hole is narrow and real: on a closed obligation, closed_by, closed_at
  -- and closure_note could be rewritten outside close_obligation(). Those three
  -- ARE the audit trail of the closure. Rewriting who closed a duty and when,
  -- while the duty still reads as properly satisfied, is worse than reopening
  -- it -- reopening at least announces itself.
  if old.status <> 'open'
     and (new.closed_at is distinct from old.closed_at
          or new.closed_by is distinct from old.closed_by
          or new.closure_note is distinct from old.closure_note) then
    raise exception
      'obligation %: the closure record (closed_at, closed_by, closure_note) is immutable once the duty is closed. It is the attribution for the closure, and an attribution that can be rewritten afterwards is not one.',
      old.id;
  end if;

  return new;
end; $$;

create trigger trg_obligation_terms_immutable
  before update on obligations
  for each row execute function enforce_obligation_terms_immutable();

-- ══════════════════════════════════════════════════════════════════════════
-- EVIDENCE
-- ══════════════════════════════════════════════════════════════════════════
-- Evidence points at something. It is not a checkbox and it is not a sentence
-- saying the work was done -- description is required IN ADDITION to a referent,
-- never instead of one.
--
-- Three referent forms, and the third exists because the real world is not all
-- in this database: a registry-validated row, another task, or an external
-- reference such as a submission identifier. Whichever form, something outside
-- the act of closing has to be named.
create table obligation_evidence (
  id             uuid primary key default gen_random_uuid(),
  obligation_id  uuid not null references obligations(id),

  ref_table      text references task_referenceable(ref_table),
  ref_id         uuid,
  task_id        uuid references tasks(id),
  external_ref   text,

  description    text not null check (btrim(description) <> ''),
  recorded_by    uuid not null references principals(id),
  recorded_at    timestamptz not null default now(),

  constraint obligation_evidence_ref_pair_whole
    check ((ref_table is null) = (ref_id is null)),
  -- The point of the whole table. A row that names nothing is a checkbox.
  constraint obligation_evidence_names_something
    check (ref_table is not null
        or task_id is not null
        or (external_ref is not null and btrim(external_ref) <> ''))
);

create index on obligation_evidence (obligation_id);

comment on table obligation_evidence is
  'What was produced. Every row names a referent -- a registered row, another task, or an external identifier -- and carries a description in addition to it. Reuses task_referenceable so the set of citable tables is one registry, not two.';

-- ── COMPLETING THE ORIGINATING TASK CANNOT CLOSE THE OBLIGATION ───────────
-- This is the requirement that most needed to be structural rather than
-- observed. Three independent mechanisms, because any one of them alone is a
-- convention someone can walk around:
--
--   (1) THE SOURCE TASK IS NOT ADMISSIBLE AS ITS OWN EVIDENCE. Rejected at
--       write, below. "I did the thing" is exactly the claim the duty exists
--       because it does not settle.
--   (2) CLOSURE ONLY THROUGH close_obligation(). A direct UPDATE of status is
--       rejected by trigger, so no trigger on tasks -- present or future -- can
--       close an obligation as a side effect of a task transition.
--   (3) EVIDENCE MUST EXIST BEFORE THE STATUS MOVES, checked inside the same
--       statement that moves it.
--
-- (1) is the one that matters for the stated requirement, and it is worth being
-- exact about its scope: a DIFFERENT task is admissible evidence. "The
-- notification was filed" is a real task and a real artifact. Only the task that
-- GENERATED the duty is refused.
create or replace function enforce_obligation_evidence_not_source_task()
returns trigger language plpgsql as $$
declare v_source uuid; v_status obligation_status;
begin
  select o.source_task_id, o.status into v_source, v_status
    from obligations o where o.id = new.obligation_id;

  if new.task_id is not null and new.task_id = v_source then
    raise exception
      'obligation %: the task that generated this duty is not evidence that it was discharged. That is the entire reason the duty is a separate row -- completing the action was never what satisfies it. Cite the artifact the duty actually calls for.',
      new.obligation_id;
  end if;

  -- Evidence cannot be added to an already-closed obligation either. Otherwise
  -- the audit trail can be back-filled to justify a closure it did not support.
  if v_status <> 'open' then
    raise exception
      'obligation % is closed (%); evidence cannot be added after the fact.',
      new.obligation_id, v_status;
  end if;
  return new;
end; $$;

create trigger trg_obligation_evidence_not_source_task
  before insert or update on obligation_evidence
  for each row execute function enforce_obligation_evidence_not_source_task();

-- Evidence that supported a closure is not removable. Close-then-delete would
-- otherwise produce a satisfied obligation with nothing behind it, which is
-- worse than an open one: it reads as done.
create or replace function enforce_obligation_evidence_not_removable()
returns trigger language plpgsql as $$
declare v_status obligation_status;
begin
  select o.status into v_status from obligations o where o.id = old.obligation_id;
  if v_status is distinct from 'open' then
    raise exception
      'obligation % is closed (%); the evidence that supported the closure cannot be deleted.',
      old.obligation_id, v_status;
  end if;
  return old;
end; $$;

create trigger trg_obligation_evidence_not_removable
  before delete on obligation_evidence
  for each row execute function enforce_obligation_evidence_not_removable();

-- ══════════════════════════════════════════════════════════════════════════
-- THE ONLY CLOSURE PATH
-- ══════════════════════════════════════════════════════════════════════════
-- Same transaction-local GUC chokepoint the promotion functions use (sql/13,
-- sql/17, sql/20), with one difference: the flag carries the obligation's ID
-- rather than 'on', so a function closing one obligation cannot sweep others in
-- the same transaction.
--
-- ITS LIMIT, STATED: a GUC is a chokepoint marker, not a capability. Anyone who
-- can issue an UPDATE on this table can also issue `set local`. What it makes
-- impossible is ACCIDENTAL closure -- a trigger on tasks, a cascade, a bulk
-- update, an ORM save -- which is the failure mode this requirement is about.
-- The same boundary is already recorded for app.promoting, and it closes when
-- the ambient credential does, not with another trigger.
create or replace function enforce_obligation_closure_path()
returns trigger language plpgsql as $$
declare v_evidence int;
begin
  if new.status is not distinct from old.status then
    return new;
  end if;

  if old.status <> 'open' then
    raise exception
      'obligation % is already %, which is terminal. A closed duty is not reopened; a duty that turns out to still apply is a new obligation with its own deadline.',
      old.id, old.status;
  end if;

  if coalesce(current_setting('app.closing_obligation', true), '') <> old.id::text then
    raise exception
      'obligation %: status changes only through close_obligation(). A direct UPDATE is refused so that no trigger on tasks -- now or later -- can discharge a duty as a side effect of completing the action that created it.',
      old.id;
  end if;

  select count(*) into v_evidence
    from obligation_evidence e where e.obligation_id = old.id;

  if v_evidence = 0 then
    raise exception
      'obligation % cannot be closed with no evidence. This is the point: a duty that can be ticked off without an artifact manufactures assurance rather than recording it.',
      old.id;
  end if;

  return new;
end; $$;

create trigger trg_obligation_closure_path
  before update on obligations
  for each row execute function enforce_obligation_closure_path();

create or replace function close_obligation(
  p_obligation_id uuid,
  p_principal_id  uuid,
  p_status        obligation_status,
  p_note          text default null
) returns text language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  if p_status = 'open' then
    raise exception 'close_obligation requires a terminal status (satisfied, waived or void)';
  end if;
  if not exists (select 1 from principals where id = p_principal_id and active) then
    raise exception 'closer % is not an active principal', p_principal_id;
  end if;
  if not exists (select 1 from obligations where id = p_obligation_id) then
    raise exception 'obligation % does not exist', p_obligation_id;
  end if;

  -- The evidence requirement is enforced in the TRIGGER, not here, and that
  -- placement is deliberate: a check that lives only in the sanctioned function
  -- is a check that a second function will one day not have. Repeating it here
  -- would also make the trigger look optional.
  set local app.closing_obligation = '';
  perform set_config('app.closing_obligation', p_obligation_id::text, true);

  update obligations
     set status = p_status, closed_at = now(), closed_by = p_principal_id,
         closure_note = p_note
   where id = p_obligation_id;
  get diagnostics v_n = row_count;

  perform set_config('app.closing_obligation', '', true);

  if v_n <> 1 then
    raise exception 'obligation %: expected to close exactly 1 row, changed %',
      p_obligation_id, v_n;
  end if;
  return 'closed';
exception when others then
  perform set_config('app.closing_obligation', '', true);
  raise;
end; $$;

comment on function close_obligation(uuid, uuid, obligation_status, text) is
  'The only path that can change an obligation''s status. Requires an active principal and at least one evidence row (enforced by trg_obligation_closure_path, not here). Cannot be reached from a trigger on tasks, which is what makes "completing the action never discharges the duty" structural rather than a habit.';

-- ══════════════════════════════════════════════════════════════════════════
-- GENERATION
-- ══════════════════════════════════════════════════════════════════════════
-- INSERT ONLY. This function never updates or deletes an obligation, and that
-- is asserted from the catalog in tests/46 rather than trusted: the whole
-- requirement is that no path from a task can close a duty, and the generator
-- is the one path from a task that exists.
--
-- Unconfirmed rules DO fire. Recording an unratified duty and labelling it is
-- strictly better than silently not recording a duty that turns out to be real,
-- and "records rather than decides" points the same way. obligation_board
-- reports basis_confirmed=false for every obligation whose rule is unconfirmed.
create or replace function generate_obligations_for_task(
  p_task_id uuid, p_event obligation_trigger
) returns int language plpgsql security definer set search_path = public as $$
declare v_task tasks%rowtype; v_n int := 0;
begin
  select * into v_task from tasks where id = p_task_id;
  if not found then return 0; end if;

  insert into obligations (rule_id, source_task_id, title, due_at)
  select r.id, v_task.id, r.duty_title, now() + r.deadline_interval
    from obligation_rules r
   where r.retired_at is null
     and r.generate_on = p_event
     and r.on_task_kind = v_task.kind
     and (r.on_task_workstream is null
          or r.on_task_workstream is not distinct from v_task.workstream)
  on conflict (rule_id, source_task_id) do nothing;

  get diagnostics v_n = row_count;
  return v_n;
end; $$;

create or replace function trg_generate_obligations()
returns trigger language plpgsql as $$
begin
  if TG_OP = 'INSERT' then
    perform generate_obligations_for_task(new.id, 'task_created');
  elsif new.status = 'done' and old.status is distinct from 'done' then
    perform generate_obligations_for_task(new.id, 'task_completed');
  end if;
  return null;   -- AFTER trigger; return value is ignored
end; $$;

create trigger trg_tasks_generate_obligations
  after insert or update of status on tasks
  for each row execute function trg_generate_obligations();

-- ══════════════════════════════════════════════════════════════════════════
-- READ SURFACE
-- ══════════════════════════════════════════════════════════════════════════
-- basis_confirmed, overdue and evidence_count are all COMPUTED. None is stored.
-- A stored basis_confirmed would go stale the moment a rule is confirmed or
-- retired, and a staleness flag that is itself stale is worse than none -- the
-- same rule sql/40 applies to task references and migration 39 to the retrieval
-- projection.
--
-- Visibility resolves back to the SOURCE TASK through can_read_row(), the same
-- explicit-principal composition sql/45 gave task_board(). The obligation has no
-- ACL of its own to disagree with it.
create or replace function obligation_board(p_principal_id uuid)
returns table (obligation_id uuid, title text, status obligation_status,
               due_at timestamptz, overdue boolean, days_remaining numeric,
               source_task_id uuid, source_task_status task_status,
               rule_key text, authority text, citation text,
               basis_confirmed boolean, evidence_count bigint)
language sql stable security definer set search_path = public as $$
  select o.id, o.title, o.status, o.due_at,
         (o.status = 'open' and o.due_at < now()),
         round(extract(epoch from (o.due_at - now())) / 86400.0, 2),
         t.id, t.status,
         r.rule_key, r.authority, r.citation,
         -- The rule is read NOW, not copied at generation time.
         (not r.requires_confirmation) or (r.confirmed_at is not null),
         (select count(*) from obligation_evidence e where e.obligation_id = o.id)
    from obligations o
    join obligation_rules r on r.id = o.rule_id
    join tasks t on t.id = o.source_task_id
   where can_read_row(t.owner, t.visibility, t.workstream, p_principal_id)
   order by o.status, o.due_at;
$$;

comment on function obligation_board(uuid) is
  'Per-principal obligation board. basis_confirmed is computed from the rule on every read, never stored: an obligation generated by an unratified reading reports false, and starts reporting true the moment the reading is confirmed. Visibility resolves back to the source task via can_read_row(), the same composition the tasks_read policy uses, so the two cannot disagree.';

-- Catalog-level view of every write path from tasks into obligations. tests/46
-- asserts the set is exactly the generator, which is what makes "completing a
-- task cannot close a duty" a checked property instead of a claim.
create or replace function obligation_write_paths_from_tasks()
returns table (trigger_name text, function_name text,
               mentions_obligations boolean, mentions_update_or_delete boolean)
language sql stable security definer set search_path = public as $$
  select tg.tgname::text, p.proname::text,
         p.prosrc ilike '%obligation%',
         p.prosrc ilike '%obligation%'
           and (p.prosrc ilike '%update obligations%' or p.prosrc ilike '%delete from obligations%'
                or p.prosrc ilike '%close_obligation%')
    from pg_trigger tg
    join pg_proc p on p.oid = tg.tgfoid
   where tg.tgrelid = 'public.tasks'::regclass
     and not tg.tgisinternal;
$$;

comment on function obligation_write_paths_from_tasks() is
  'Enumerates every trigger on public.tasks and reports whether its function body touches obligations at all, and whether it does so with a write verb or by calling close_obligation. A source-text scan, so it is a tripwire and not a proof -- the proof is trg_obligation_closure_path, which refuses any status change that did not come through close_obligation. This exists so that a new trigger on tasks that reaches toward obligations shows up in a test run rather than in an audit.';

-- ══════════════════════════════════════════════════════════════════════════
-- SEEDED RULES
-- ══════════════════════════════════════════════════════════════════════════
-- Synthetic, generic, and every one marked requires_confirmation=true. They
-- exist to prove the mechanism carries a citation and an authority and refuses
-- to be relied upon before someone ratifies it -- NOT to state what any
-- regulation requires. Read the non-goal at the top of this file before
-- confirming any of them.
--
-- declared_by is left to the deployment: seeding rules against a principal that
-- does not exist yet would fail the FK, and inventing one would put a fabricated
-- attribution on a compliance artifact. The seed is therefore a function the
-- operator calls with their own principal id, which also makes "who put these
-- here" answerable.
create or replace function seed_obligation_rules(p_declared_by uuid)
returns int language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  if not exists (select 1 from principals where id = p_declared_by and active and kind = 'human') then
    raise exception 'seed_obligation_rules requires an active human principal';
  end if;

  insert into obligation_rules
    (rule_key, description, on_task_kind, on_task_workstream, generate_on,
     duty_title, deadline_interval, evidence_requirement, authority, citation,
     requires_confirmation, declared_by)
  values
   ('example.notify_after_change',
    'EXAMPLE ONLY, UNCONFIRMED. A reading that a change of this kind carries a notification duty with a fixed window. The window and the duty are placeholders.',
    'action', null, 'task_completed',
    'File the required notification for the completed change',
    interval '30 days',
    'The submission identifier issued by the receiving body, or the filed document itself.',
    'PLACEHOLDER AUTHORITY -- replace before confirming',
    'PLACEHOLDER CITATION -- replace before confirming',
    true, p_declared_by),
   ('example.retain_records_after_decision',
    'EXAMPLE ONLY, UNCONFIRMED. A reading that a recorded decision carries a duty to file the supporting record within a fixed window.',
    'decision', null, 'task_created',
    'File the record supporting this decision',
    interval '14 days',
    'The stored record, cited by id, or an external document reference.',
    'PLACEHOLDER AUTHORITY -- replace before confirming',
    'PLACEHOLDER CITATION -- replace before confirming',
    true, p_declared_by)
  on conflict (rule_key) do nothing;

  get diagnostics v_n = row_count;
  return v_n;
end; $$;

comment on function seed_obligation_rules(uuid) is
  'Inserts the example rules, attributed to the calling operator''s principal. Every seeded rule is requires_confirmation=true with placeholder authority and citation strings, so a board built on them reports basis_confirmed=false until someone replaces the placeholders and ratifies the reading. Seeding is not a claim about any regulation.';

-- ══════════════════════════════════════════════════════════════════════════
-- PERIMETER
-- ══════════════════════════════════════════════════════════════════════════
-- RLS enabled with NO policy -- deny-all -- and every privilege revoked from
-- anon and authenticated. Same posture sql/40 shipped and for the same reason:
-- nothing authenticated reads obligations yet, and adding a policy plus the
-- table grants it needs would widen the perimeter for a read that does not
-- exist. When an authenticated surface is wanted, the policy is the sql/45
-- pattern applied to the source task, and it is a reviewable change of its own.
--
-- Asserted in tests/46 rather than assumed: a deny-all table and a table with a
-- permissive policy look identical from here.
alter table obligation_rules     enable row level security;
alter table obligations          enable row level security;
alter table obligation_evidence  enable row level security;
revoke all on obligation_rules, obligations, obligation_evidence
  from anon, authenticated;

revoke execute on function close_obligation(uuid, uuid, obligation_status, text)
  from anon, authenticated, public;
revoke execute on function generate_obligations_for_task(uuid, obligation_trigger)
  from anon, authenticated, public;
revoke execute on function obligation_board(uuid) from anon, authenticated, public;
revoke execute on function obligation_write_paths_from_tasks() from anon, authenticated, public;
revoke execute on function seed_obligation_rules(uuid) from anon, authenticated, public;
revoke execute on function trg_generate_obligations() from anon, authenticated, public;
revoke execute on function enforce_obligation_closure_path() from anon, authenticated, public;
revoke execute on function enforce_obligation_terms_immutable() from anon, authenticated, public;
revoke execute on function enforce_obligation_evidence_not_source_task() from anon, authenticated, public;
revoke execute on function enforce_obligation_evidence_not_removable() from anon, authenticated, public;
revoke execute on function enforce_obligation_rule_confirmation_ratchet() from anon, authenticated, public;

-- ══════════════════════════════════════════════════════════════════════════
-- WHAT THIS DOES NOT DO
-- ══════════════════════════════════════════════════════════════════════════
-- 1. It does not notice a deadline passing. `overdue` is computed when someone
--    looks. Nothing here sends anything, and an obligation board nobody opens is
--    a filing cabinet. Scheduling is a separate concern and pretending otherwise
--    inside this file would be the most dangerous kind of completeness.
-- 2. It does not verify that evidence is ADEQUATE. It verifies that evidence
--    EXISTS, names something, and is not the originating task. Whether a
--    submission identifier is real is outside any trigger's reach.
-- 3. It does not decide what any regulation requires. Stated at the top, stated
--    again here, and asserted in tests/46 through the seeded rules'
--    requires_confirmation flag.
