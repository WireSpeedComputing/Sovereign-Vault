-- 45_task_board_policies.sql
--
-- NOT APPLIED to any deployment. Build-only. No MIGRATION: header until it is.
--
-- ############################################################
-- APPLY ORDER. Assumes, in order:
--   sql/36_rls_policies.sql   (can_read_row / can_read_row_as_request / row_scope)
--   sql/37_rls_authenticated_select_and_lifecycle.sql  (the lifecycle narrowing
--                                                       and the table grants)
--   sql/40_task_board.sql     (tasks, task_references, task_dependencies)
--   sql/43_session_boot_scope_composition.sql   (migration 61 -- composes the
--       same can_read_row() rule into session_boot and the owner-scoped
--       wrappers. Nothing here redefines it; this file is the RLS half of the
--       same composition and must not drift from it.)
--   sql/44_truncate_revocation_and_table_level_perimeter.sql  (migration 62 --
--       perimeter_assert() gained the destructive_grant category and TRUNCATE
--       is revoked from service_role. The table grants below are SELECT only,
--       so they are visible to the table_grant category and invisible to the
--       new one, which is the intended shape.)
-- It DROPS AND RECREATES task_board(uuid) with one additional output column.
-- A `create or replace` cannot change a function's return type, so this is a
-- drop, and any view or function built on the old signature breaks loudly here
-- rather than quietly returning the old shape.
-- ############################################################
--
-- ══════════════════════════════════════════════════════════════════════════
-- WHAT THIS CLOSES
-- ══════════════════════════════════════════════════════════════════════════
-- sql/40 shipped the task board with RLS enabled and NO policy — deny-all,
-- reachable only through service_role — and said so on purpose. It also shipped
-- task_board(), a SECURITY DEFINER function that filters on is_owner_or_shared
-- ALONE. Definer functions bypass RLS. So the moment a policy is added to
-- `tasks` without touching task_board(), the two access paths disagree: the
-- table serves scope-narrowed rows and the function serves everything the owner
-- predicate allows.
--
-- That is not a hypothetical. It is migration 49 (sql/37) exactly: the table
-- policy and retrieve_context() diverged on lifecycle, same principal, same
-- grant, different answers depending on which door was used. Adding the policy
-- and leaving the function alone would reproduce that defect on a new table
-- while looking like the fix for it. Migration 61 (sql/43) made the same
-- correction for session_boot and the owner-scoped wrappers; this file makes it
-- for the board.
--
-- So this file does three things and none of them is optional:
--   1. policies on tasks / task_references / task_dependencies, composed from
--      the SAME predicate sql/36 wired, not a new one;
--   2. the table grants without which the policies cannot serve a row at all
--      (sql/37's migration 48 lesson — a policy with no table privilege is a
--      test that passes for the wrong reason);
--   3. task_board() rebuilt on the explicit-principal form of the same rule, so
--      the definer door and the table door answer the same question.
--
-- ══════════════════════════════════════════════════════════════════════════
-- THE COMPOSITION, WRITTEN ONCE
-- ══════════════════════════════════════════════════════════════════════════
-- A row is readable iff it passes BOTH:
--   1. the owner/visibility predicate (is_owner_or_shared), and
--   2. read on the row's workstream scope (has_capability / row_scope).
-- Both are already composed, in one place, by:
--   can_read_row(owner, visibility, workstream, principal)   -- explicit actor
--   can_read_row_as_request(owner, visibility, workstream)   -- request identity
-- Nothing below re-derives that composition. Where a new decision is needed it
-- is expressed as a call to one of those two, never as a fresh AND of the parts.
-- That is the same instruction migration 61 followed, and the reason both files
-- can be read as one model rather than two that happen to agree today.
--
-- ══════════════════════════════════════════════════════════════════════════
-- LIFECYCLE: DELIBERATELY NOT NARROWED, AND THAT IS A DECISION
-- ══════════════════════════════════════════════════════════════════════════
-- sql/37 added `status = 'current'` to the memories and wiki_pages policies
-- because 'proposed' means NOT YET ACCEPTED AS TRUE and serving it through the
-- same door as accepted fact defeats the promotion model.
--
-- task_status is not that lifecycle and sql/40 says so explicitly: tasks are not
-- promoted, not superseded, not citable as fact. `done` and `cancelled` are
-- history, not rejected content, and a board that hides completed work hides the
-- record of what was done. So there is NO status filter on `tasks`, on purpose.
--
-- The risk of a silent later "hardening" that adds one is real, so it is
-- asserted from the other side: tests/45 requires a done task and a cancelled
-- task to remain VISIBLE to an in-scope owner. If someone adds a lifecycle
-- filter here, that test fails and the reasoning above gets re-read.

-- ══════════════════════════════════════════════════════════════════════════
-- RESOLVING BACK TO THE SOURCE, NOT TO A COPY
-- ══════════════════════════════════════════════════════════════════════════
-- sql/36 explains why the retrieval_units policy does not read the projection's
-- own owner/visibility/workstream columns: those are copies, a copy went stale
-- once already (ACL drift, migration 39), and a policy written against a cache
-- is an authorization decision made from a cache.
--
-- The same shape exists here, one indirection over. A task_references row is a
-- pointer at a record in another table. It carries no ACL columns at all — so
-- the temptation is not "trust the copy", it is the worse version: govern the
-- pointer by the TASK alone and never ask about the thing pointed at. Then a
-- principal who can read a task can enumerate the ids of records they hold no
-- scope for, and the reference row is the enumeration.
--
-- So a task_references row resolves BOTH ways, to two source rows:
--   * the task it belongs to, and
--   * the record it points at,
-- and both must be readable under the composed rule. Nothing about the referent
-- is inferred from the reference row.
--
-- The referent lookup is enumerated, exactly like sql/36's CASE, and the default
-- branch is DENY. task_referenceable is a registry and registering a table there
-- is a row, not a migration — which is the right property for the reference
-- MODEL and the wrong one for the reference PERIMETER. If the policy read the
-- registry, adding a row to it would silently widen what `authenticated` can
-- enumerate. It cannot: a table not enumerated below yields zero rows here and
-- its references are invisible. That limit is asserted in tests/45 rather than
-- left as a comment, because a fail-closed gap still surprises whoever hits it.

-- ── One enumeration, resolved from the referent's own row ──────────────────
-- Returns the referent's live ACL triple, or NO ROWS. Both callers below use
-- EXISTS, so "no rows" is deny in both, and there is exactly one place that
-- knows how to find a referent's owner/visibility/workstream.
create or replace function public.task_referent_acl(p_ref_table text, p_ref_id uuid)
returns table (ref_owner uuid, ref_visibility visibility_level, ref_workstream text)
language sql stable security definer set search_path = public as $$
  select m.owner, m.visibility, m.workstream
    from public.memories m
   where p_ref_table = 'memories' and m.id = p_ref_id and m.status = 'current'
  union all
  select w.owner, w.visibility, w.workstream
    from public.wiki_pages w
   where p_ref_table = 'wiki_pages' and w.id = p_ref_id and w.status = 'current';
$$;

comment on function public.task_referent_acl(text, uuid) is
  'The referent lookup for task references, enumerated in ONE place so the policy and task_board() cannot drift apart. Returns no rows for an unenumerated ref_table or a non-current referent, and every caller uses EXISTS, so absence is denial. Registering a table in task_referenceable does NOT widen this: adding a branch here is a separate, reviewable act.';

revoke all on function public.task_referent_acl(text, uuid)
  from public, anon, authenticated;

-- ── The two forms of the reference decision ───────────────────────────────
-- Same split, same reasons, as can_read_row / can_read_row_as_request.
create or replace function public.task_reference_readable(
  p_ref_table text, p_ref_id uuid, p_principal_id uuid
) returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.task_referent_acl(p_ref_table, p_ref_id) a
    where public.can_read_row(a.ref_owner, a.ref_visibility, a.ref_workstream, p_principal_id)
  );
$$;

create or replace function public.task_reference_readable_as_request(
  p_ref_table text, p_ref_id uuid
) returns boolean language sql stable security definer
set search_path = public, vault_auth as $$
  select exists (
    select 1 from public.task_referent_acl(p_ref_table, p_ref_id) a
    where public.can_read_row_as_request(a.ref_owner, a.ref_visibility, a.ref_workstream)
  );
$$;

-- EXISTS is already total: it returns true or false, never NULL. Said out loud
-- because sql/36 needed an explicit coalesce for the same reason in a different
-- construction, and "this one is fine" should be a checked claim, not a habit.

revoke all on function public.task_reference_readable(text, uuid, uuid)
  from public, anon, authenticated;
revoke all on function public.task_reference_readable_as_request(text, uuid)
  from public, anon;
grant execute on function public.task_reference_readable_as_request(text, uuid)
  to authenticated;

-- ══════════════════════════════════════════════════════════════════════════
-- DECLARE THE NEW EXPOSURES
-- ══════════════════════════════════════════════════════════════════════════
-- perimeter_assert() (sql/28, extended by migration 62) flags every grant to
-- `authenticated` on a repo-owned object in public — table grants and function
-- grants both. Four new ones are required for the policies to be evaluable at
-- all. Declaring them keeps the checker at zero findings, which is the only
-- state in which a REAL finding is visible.
--
-- All three table exceptions are for SELECT. Migration 62 added a
-- destructive_grant category that deliberately refuses to accept a read
-- exception as cover for TRUNCATE, so none of these reasons mentions TRUNCATE
-- and none of them can be stretched to excuse one.
insert into perimeter_exception (object_kind, object_identity, grantee, reason) values
 ('function',
  'public.task_reference_readable_as_request(p_ref_table text, p_ref_id uuid)',
  'authenticated',
  'The reference-side half of the task_references policy. SECURITY DEFINER, returns a boolean decision and no data, resolves identity from verified JWT claims rather than any caller-supplied argument, and denies for any ref_table it does not enumerate. authenticated must hold EXECUTE or the policy cannot be evaluated.'),
 ('table','public.tasks','authenticated',
  'SELECT only. RLS filters rows; a table privilege decides whether the role may touch the table at all. Without SELECT here the tasks_read policy can never serve a row and any test asserting "an ungranted principal sees nothing" passes for the wrong reason -- migration 48''s finding, reproduced deliberately here as a grant rather than rediscovered later. Writes stay on the definer path.'),
 ('table','public.task_references','authenticated',
  'SELECT only. Same reason as public.tasks. The row is deny-by-default and readable only when BOTH the owning task and the referenced record are readable under the composed rule.'),
 ('table','public.task_dependencies','authenticated',
  'SELECT only. Same reason as public.tasks. An edge is readable only when both endpoint tasks are.')
on conflict do nothing;

grant select on public.tasks             to authenticated;
grant select on public.task_references   to authenticated;
grant select on public.task_dependencies to authenticated;

-- task_referenceable is deliberately NOT granted. It is perimeter metadata: it
-- names every table a task may point at, and the reference policy denies any
-- table it does not enumerate anyway, so exposing the registry would publish the
-- shape of the schema for no read that depends on it.

-- ══════════════════════════════════════════════════════════════════════════
-- POLICIES
-- ══════════════════════════════════════════════════════════════════════════
-- SELECT only, matching sql/36 and sql/37. Writes continue through the
-- sanctioned definer path; an INSERT or UPDATE policy here would create a second
-- write path beside the transition and evidence triggers in sql/40, which is
-- precisely how promote_memory came to look like a chokepoint while nothing
-- gated INSERT.

drop policy if exists tasks_read on public.tasks;
create policy tasks_read on public.tasks
  for select to authenticated
  using (public.can_read_row_as_request(owner, visibility, workstream));

-- A reference resolves to two sources and needs both.
--
-- The task side is expressed as a subquery on public.tasks rather than by
-- copying the predicate: tasks_read then also applies to that subquery, so the
-- two can never disagree even if one is edited. Belt and braces on purpose --
-- the predicate is repeated explicitly as well, so the policy still reads
-- correctly to someone who does not know RLS nests. The redundancy is load
-- bearing and was measured: weakening tasks_read alone leaves this policy and
-- the dependency policy below correctly closed, which is exactly the
-- independence the duplication buys.
drop policy if exists task_references_read on public.task_references;
create policy task_references_read on public.task_references
  for select to authenticated
  using (
    exists (
      select 1 from public.tasks t
      where t.id = task_references.task_id
        and public.can_read_row_as_request(t.owner, t.visibility, t.workstream))
    and public.task_reference_readable_as_request(
          task_references.ref_table, task_references.ref_id)
  );

-- An edge names two tasks. Serving it on the strength of one endpoint leaks the
-- id and the existence of the other.
drop policy if exists task_dependencies_read on public.task_dependencies;
create policy task_dependencies_read on public.task_dependencies
  for select to authenticated
  using (
    exists (
      select 1 from public.tasks t
      where t.id = task_dependencies.task_id
        and public.can_read_row_as_request(t.owner, t.visibility, t.workstream))
    and exists (
      select 1 from public.tasks b
      where b.id = task_dependencies.depends_on
        and public.can_read_row_as_request(b.owner, b.visibility, b.workstream))
  );

-- ══════════════════════════════════════════════════════════════════════════
-- ABSENCE MUST NOT READ AS PERMISSION
-- ══════════════════════════════════════════════════════════════════════════
-- The reference policy hides a reference whose referent is out of scope. Taken
-- alone that is a new failure of this project's signature kind: a task carrying
-- a 'constraint' reference — "this work must not contradict record X" — would
-- render to an under-scoped principal as a task with NO constraints. Nothing
-- errors. The constraint has not been withheld, it has been made invisible, and
-- invisible reads as absent.
--
-- Fail-closed on the enumeration is still right: an id you cannot read is
-- information about a record you cannot read. So the count is surfaced instead
-- of the identity. task_board() below reports how many of a task's references
-- the principal cannot resolve, and a task with an unresolvable SUBJECT or
-- CONSTRAINT is NOT actionable for that principal.
--
-- Evidence and context references do not gate actionability: 'context' is
-- informative by definition and 'evidence' points at proof of completion, which
-- is not an input to doing the work. They are still counted, so the number is
-- never silently zero.

drop function if exists public.task_board(uuid);

create function public.task_board(p_principal_id uuid)
returns table (task_id uuid, title text, status task_status, kind task_kind,
               priority int, due_date timestamptz, assigned_to uuid,
               stale_references bigint, unreadable_references bigint,
               blocking_open bigint, actionable boolean)
language sql stable security definer set search_path = public as $$
  select t.id, t.title, t.status, t.kind, t.priority, t.due_date, t.assigned_to,
         (select count(*) from task_reference_state(t.id) s
           where s.state in ('stale','missing')),
         -- Every reference the principal cannot resolve, whatever its role. The
         -- number is visible; the ids are not.
         (select count(*) from task_references tr
           where tr.task_id = t.id
             and not task_reference_readable(tr.ref_table, tr.ref_id, p_principal_id)),
         (select count(*) from task_dependencies d join tasks bt on bt.id = d.depends_on
           where d.task_id = t.id and bt.status not in ('done','cancelled')),
         -- Actionable means: workable now, resting on nothing stale, blocked by
         -- nothing open, and with every reference that governs the work
         -- actually readable by this principal.
         t.status in ('open','in_progress')
         and (select count(*) from task_dependencies d join tasks bt on bt.id = d.depends_on
               where d.task_id = t.id and bt.status not in ('done','cancelled')) = 0
         and (select count(*) from task_reference_state(t.id) s
               where s.state in ('stale','missing')) = 0
         and (select count(*) from task_references tr
               where tr.task_id = t.id
                 and tr.ref_role in ('subject','constraint')
                 and not task_reference_readable(tr.ref_table, tr.ref_id, p_principal_id)) = 0
  from tasks t
  -- THE CHANGE THAT MATTERS: the definer door now asks the same question the
  -- table door asks. Previously is_owner_or_shared alone, which after the
  -- policies above would have served strictly more than the table. Same
  -- correction migration 61 made to session_boot, same predicate.
  where can_read_row(t.owner, t.visibility, t.workstream, p_principal_id)
  order by t.priority, t.due_date nulls last;
$$;

comment on function public.task_board(uuid) is
  'Per-principal board. Applies the SAME composed rule as the tasks_read policy -- owner/visibility AND capability scope -- via can_read_row(), the explicit-principal form. It previously filtered on is_owner_or_shared alone; leaving it that way alongside the policies would have reproduced migration 49 (definer path and table path disagreeing for the same principal) on a new table. unreadable_references is the count of references whose referent this principal cannot read: the ids stay hidden, the number does not, so a withheld constraint never renders as no constraint.';

revoke execute on function public.task_board(uuid) from anon, authenticated, public;

-- ══════════════════════════════════════════════════════════════════════════
-- WHAT THIS DOES NOT CLOSE
-- ══════════════════════════════════════════════════════════════════════════
-- 1. service_role carries BYPASSRLS. Every policy here is invisible to it, and
--    the deployment's own tooling uses that key. Identical to the boundary
--    recorded at the foot of sql/36; it closes when the service-role key stops
--    being the ambient credential, not with another policy. Migration 62
--    narrowed what that credential can DESTROY, not what it can read.
--
-- 2. task_reference_state(uuid) takes no principal and applies no access check.
--    It is SECURITY DEFINER and revoked from anon, authenticated and PUBLIC, so
--    the only callers are service_role and task_board(). It is left that way
--    deliberately: task_board needs the STALENESS of every reference, including
--    ones the principal cannot read, or a task resting on a superseded record
--    the principal cannot see would render as actionable. The count crosses the
--    boundary; the identity does not. If that function is ever granted to
--    authenticated it becomes an enumeration oracle. tests/45 asserts the
--    revocation so the grant cannot be added quietly.
--
-- 3. Write paths are unpoliced by RLS because they are unreachable: no INSERT,
--    UPDATE, DELETE or TRUNCATE privilege is granted to authenticated on any of
--    these tables. That is a privilege posture, not a policy one, and it is
--    asserted in tests/45 — a policy model that silently gained a write path
--    would otherwise look identical to this one.
