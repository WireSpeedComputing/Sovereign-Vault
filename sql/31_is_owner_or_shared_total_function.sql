-- 31_is_owner_or_shared_total_function.sql
--
-- MIGRATION: 40_is_owner_or_shared_total_function
--
-- APPLIED to the deployment 2026-08-07 as migration 40, by ORIGIN, before the
-- RLS policy work began. Filed here after the fact; that ordering was wrong and
-- is noted rather than hidden.
--
-- ── THE DEFECT ─────────────────────────────────────────────────────────────
-- sql/14 defined the access predicate as:
--
--   SELECT p_row_owner = p_principal_id OR p_row_visibility = 'shared';
--
-- With a NULL owner and private visibility that evaluates to (NULL OR false),
-- which is NULL — not false. The predicate the entire visibility model rests on
-- could return NULL.
--
-- ── WHY IT HAD NOT CAUSED HARM ─────────────────────────────────────────────
-- Every existing call site places it in a WHERE clause, where NULL and false
-- both exclude the row, so it failed closed. And zero rows carried a NULL owner,
-- so the input never arose. Verified live before changing anything.
--
-- ── WHY IT COULD NOT WAIT ──────────────────────────────────────────────────
-- Written in a negated form the behaviour inverts:
--
--   IF NOT is_owner_or_shared(...) THEN RAISE ...   -- NOT NULL is NULL
--                                                   -- IF NULL does not fire
--                                                   -- the guard silently passes
--
-- RLS policy work (sql/30 and the pending policy migration) builds directly on
-- this predicate. A policy or trigger using the negated form would have failed
-- OPEN while reading as correct. Fixing it after policies existed would have
-- meant auditing every call site instead of one function.
--
-- ── THE GENERAL RULE THIS BELONGS TO ───────────────────────────────────────
-- Found the same day as a test-harness defect where a missing jsonb key
-- produced NULL, bool_and() ignored it, and 21 of 24 assertions passed against
-- a function that lacked the feature entirely. Same root cause, different
-- layer: SQL's three-valued logic turns an unchecked condition into a silent
-- pass.
--
-- The three layers, audited together:
--   assertions   vulnerable  -- NULL reads as pass through bool_and and FILTER
--   predicates   vulnerable  -- this defect
--   CHECK        NOT vulnerable here, but only because every governance CHECK
--                is paired with NOT NULL on the columns it reads. A CHECK
--                passes when its condition is NULL, so a CHECK is only as
--                strong as the NOT NULL beside it.
--
-- Rule to carry forward: a security predicate must be a TOTAL function, and a
-- CHECK constraint must be paired with NOT NULL on every column it reads.
--
-- ── DELIBERATELY NOT STRICT ────────────────────────────────────────────────
-- Marking this STRICT would return NULL whenever any argument is NULL, which is
-- precisely the defect being fixed. The NULL handling must be inside the body.
--
-- ── BEHAVIOUR CHANGE, CONFINED AND STRICTLY SAFER ──────────────────────────
--   ownerless + private : NULL -> false   (WHERE: unchanged. IF NOT: now fires.)
--   ownerless + shared  : true -> true    (unchanged)
--   owned, any case     : unchanged
-- No currently reachable behaviour changes. No access widens.
-- Verified after applying: retrieval returned 133 visible units for two
-- distinct principals, unchanged from before.

CREATE OR REPLACE FUNCTION public.is_owner_or_shared(
  p_row_owner      uuid,
  p_row_visibility visibility_level,
  p_principal_id   uuid
) RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public'
AS $function$
  SELECT coalesce(p_row_owner = p_principal_id, false)
      OR coalesce(p_row_visibility = 'shared', false);
$function$;

COMMENT ON FUNCTION public.is_owner_or_shared(uuid, visibility_level, uuid) IS
  'Total access predicate: always returns boolean, never NULL. Deliberately not STRICT, since STRICT would return NULL on any NULL argument and reintroduce the defect it fixes. Safe to use in negated form.';
