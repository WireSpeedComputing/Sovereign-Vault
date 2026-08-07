-- tests/30_scope_bound_authority.sql
-- ADOPT: upstream sovereign-memory-core #45. Covers sql/30_scope_bound_authority.sql.
--
-- Every `pass` must be true.
--
-- ── WHAT THESE TESTS DO AND DO NOT PROVE ───────────────────────────────────
-- Section A proves scope ISOLATION at the capability layer: a principal granted
-- on one scope gets false on another, in both directions, for every permission.
--
-- Section C is the honest half. Upstream #45 asks for tests proving current and
-- stale truth cannot leak ACROSS scopes. Those tests cannot be written yet and
-- Section C asserts why: nothing in this schema calls has_capability(), so no
-- knowledge read path is scope-constrained at all. Section C fails the moment
-- that changes, which is the signal to come back and write the real
-- cross-scope leakage tests.
--
-- Writing scope-leakage tests against a model nothing consults would produce a
-- green suite that proves only that two function calls return different
-- booleans. That is the failure this project keeps naming.

BEGIN;

CREATE TEMP TABLE t(section text, test text, pass boolean, detail text) ON COMMIT DROP;

INSERT INTO principals (id,kind,display_name,email) VALUES
 ('11111111-1111-1111-1111-111111111111','human','Alpha owner','alpha@example.com'),
 ('22222222-2222-2222-2222-222222222222','human','Beta owner','beta@example.com'),
 ('44444444-4444-4444-4444-444444444444','human','Granter','granter@example.com');
INSERT INTO principals (id,kind,display_name,agent_label) VALUES
 ('33333333-3333-3333-3333-333333333333','agent','A1','A1');

INSERT INTO scope_registry (scope, kind, identifier, description, declared_by) VALUES
 ('workstream:alpha','workstream','alpha','Alpha workstream','44444444-4444-4444-4444-444444444444'),
 ('workstream:beta','workstream','beta','Beta workstream','44444444-4444-4444-4444-444444444444'),
 ('table:memories','table','memories','The memories relation','44444444-4444-4444-4444-444444444444');

INSERT INTO capability_grants (principal_id, resource_scope, permissions, granted_by) VALUES
 ('11111111-1111-1111-1111-111111111111','workstream:alpha','{read,propose}','44444444-4444-4444-4444-444444444444'),
 ('22222222-2222-2222-2222-222222222222','workstream:beta','{read,write}','44444444-4444-4444-4444-444444444444');


-- ══════════════════════════════════════════════════════════════════════════
-- SECTION A — TWO DISTINCT SCOPES, PROVEN NOT TO LEAK INTO EACH OTHER
-- ══════════════════════════════════════════════════════════════════════════

INSERT INTO t
SELECT 'A','a1_alpha_principal_has_own_scope',
  has_capability('11111111-1111-1111-1111-111111111111','workstream:alpha','read'),
  'granted read on alpha';

INSERT INTO t
SELECT 'A','a2_alpha_principal_denied_on_beta',
  NOT has_capability('11111111-1111-1111-1111-111111111111','workstream:beta','read'),
  'no grant on beta';

INSERT INTO t
SELECT 'A','a3_beta_principal_has_own_scope',
  has_capability('22222222-2222-2222-2222-222222222222','workstream:beta','read'),
  'granted read on beta';

INSERT INTO t
SELECT 'A','a4_beta_principal_denied_on_alpha',
  NOT has_capability('22222222-2222-2222-2222-222222222222','workstream:alpha','read'),
  'no grant on alpha -- isolation holds in both directions';

-- permission isolation within a held scope: alpha has read+propose, not write
INSERT INTO t
SELECT 'A','a5_permission_not_widened_within_scope',
  NOT has_capability('11111111-1111-1111-1111-111111111111','workstream:alpha','write'),
  'read+propose granted, write is not';

-- a scope nobody was granted returns false for everyone
INSERT INTO t
SELECT 'A','a6_ungranted_scope_denies_all',
  NOT has_capability('11111111-1111-1111-1111-111111111111','table:memories','read')
  AND NOT has_capability('22222222-2222-2222-2222-222222222222','table:memories','read'),
  'declared but ungranted scope authorises nobody';

-- admin implies lesser permissions ON THAT SCOPE ONLY -- the one place breadth
-- exists, and it must not cross scopes
DO $c$ BEGIN
  INSERT INTO capability_grants (principal_id, resource_scope, permissions, granted_by)
  VALUES ('11111111-1111-1111-1111-111111111111','table:memories','{admin}',
          '44444444-4444-4444-4444-444444444444');
  INSERT INTO t VALUES ('A','a7_admin_implies_lesser_on_same_scope',
    has_capability('11111111-1111-1111-1111-111111111111','table:memories','write'),
    'admin on a scope covers write on that scope');
  INSERT INTO t VALUES ('A','a8_admin_does_not_cross_scopes',
    NOT has_capability('11111111-1111-1111-1111-111111111111','workstream:beta','read'),
    'admin on table:memories confers nothing on workstream:beta');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('A','a7_admin_implies_lesser_on_same_scope',false,SQLERRM); END $c$;

-- deactivating a principal removes authority (sql/23 migration 34 behaviour,
-- asserted here because scope isolation is worthless if a stale principal keeps
-- its grants)
DO $c$ BEGIN
  UPDATE principals SET active=false, deactivated_at=now()
   WHERE id='22222222-2222-2222-2222-222222222222';
  INSERT INTO t VALUES ('A','a9_inactive_principal_loses_scope',
    NOT has_capability('22222222-2222-2222-2222-222222222222','workstream:beta','read'),
    'deactivated principal retains no capability');
  UPDATE principals SET active=true, deactivated_at=null
   WHERE id='22222222-2222-2222-2222-222222222222';
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('A','a9_inactive_principal_loses_scope',false,SQLERRM); END $c$;


-- ══════════════════════════════════════════════════════════════════════════
-- SECTION B — THE REGISTRY TURNS A SILENT NO-OP INTO A LOUD FAILURE
-- ══════════════════════════════════════════════════════════════════════════

-- B1: the typo case. Before the registry this inserted cleanly, read back
-- cleanly, appeared in every audit view, and authorised nothing.
DO $c$ BEGIN
  INSERT INTO capability_grants (principal_id, resource_scope, permissions, granted_by)
  VALUES ('11111111-1111-1111-1111-111111111111','workstream:brnad','{read}',
          '44444444-4444-4444-4444-444444444444');
  INSERT INTO t VALUES ('B','b1_typo_scope_rejected_at_grant_time',false,
    'a misspelled scope was accepted and authorises nothing');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b1_typo_scope_rejected_at_grant_time',true,SQLERRM); END $c$;

-- B2: malformed scope strings cannot be registered
DO $c$ BEGIN
  INSERT INTO scope_registry (scope, kind, identifier, description)
  VALUES ('workstream-alpha','workstream','alpha','missing the colon');
  INSERT INTO t VALUES ('B','b2_malformed_scope_rejected',false,'accepted');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b2_malformed_scope_rejected',true,SQLERRM); END $c$;

-- B3: there is no way to express a global scope. The enum has no such member,
-- so "never global by default" is enforced by the type system rather than by
-- everyone remembering.
DO $c$ BEGIN
  INSERT INTO scope_registry (scope, kind, identifier, description)
  VALUES ('global:all','global','all','everything');
  INSERT INTO t VALUES ('B','b3_no_global_scope_kind_exists',false,'a global scope was registered');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b3_no_global_scope_kind_exists',true,SQLERRM); END $c$;

-- B4: pattern wildcards do not match anything. Exact-only is in force until
-- declared containment lands; this asserts nothing silently widened in between.
DO $c$ BEGIN
  INSERT INTO scope_registry (scope, kind, identifier, description)
  VALUES ('workstream:*','workstream','*','wildcard attempt');
  INSERT INTO t VALUES ('B','b4_wildcard_scope_not_registrable',false,
    'a wildcard scope was registered');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b4_wildcard_scope_not_registrable',true,SQLERRM); END $c$;

-- B5: cutover requires a human, an active scope, and evidence
DO $c$ BEGIN
  PERFORM declare_scope_cutover('workstream:alpha','33333333-3333-3333-3333-333333333333','x');
  INSERT INTO t VALUES ('B','b5_agent_cannot_declare_cutover',false,'agent declared a cutover');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b5_agent_cannot_declare_cutover',true,SQLERRM); END $c$;

DO $c$ BEGIN
  PERFORM declare_scope_cutover('workstream:alpha','44444444-4444-4444-4444-444444444444','');
  INSERT INTO t VALUES ('B','b6_cutover_requires_evidence',false,'empty evidence accepted');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b6_cutover_requires_evidence',true,SQLERRM); END $c$;

DO $c$ BEGIN
  PERFORM declare_scope_cutover('workstream:nonexistent',
    '44444444-4444-4444-4444-444444444444','evidence');
  INSERT INTO t VALUES ('B','b7_cutover_requires_declared_scope',false,'undeclared scope accepted');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b7_cutover_requires_declared_scope',true,SQLERRM); END $c$;

-- B8: a second declaration supersedes rather than duplicating
DO $c$ BEGIN
  PERFORM declare_scope_cutover('workstream:alpha','44444444-4444-4444-4444-444444444444',
    'first cutover','legacy-notes');
  PERFORM declare_scope_cutover('workstream:alpha','44444444-4444-4444-4444-444444444444',
    'corrected cutover','legacy-notes');
  INSERT INTO t VALUES ('B','b8_cutover_supersedes_not_duplicates',
    (SELECT count(*)=1 FROM scope_cutover
      WHERE scope='workstream:alpha' AND superseded_at IS NULL),
    'exactly one live declaration');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b8_cutover_supersedes_not_duplicates',false,SQLERRM); END $c$;


-- ══════════════════════════════════════════════════════════════════════════
-- SECTION C — THE GAP, ASSERTED SO IT CANNOT BE FORGOTTEN
-- ══════════════════════════════════════════════════════════════════════════
-- These pass while the capability model is unwired. When one FAILS, something
-- started consulting capabilities and the real cross-scope leakage tests
-- upstream #45 asks for can finally be written. Treat a failure here as a
-- prompt, not a regression.

INSERT INTO t
SELECT 'C','c1_scope_authority_report_admits_nothing_is_enforced',
  bool_and(NOT enforced), 'every scope reports enforced=false'
FROM scope_authority_report();

INSERT INTO t
SELECT 'C','c2_a_granted_scope_still_constrains_no_reads',
  -- Alpha holds read on workstream:alpha and nothing on workstream:beta. If
  -- retrieval were scope-bound, a beta-workstream memory would be unreachable
  -- to them. It is not: retrieve_context filters on owner/visibility only.
  (retrieve_context('11111111-1111-1111-1111-111111111111','zzbeta canary')
     ->>'units_matched')::int >= 1,
  'beta-scoped knowledge is readable by an alpha-only principal';


-- fixture for c2: a shared memory tagged to the beta workstream
-- (created after the assertions above are inserted is too late, so it is here
-- and c2 is re-evaluated below)
DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility, workstream)
  VALUES ('zzbeta canary fact','manual','human_direct','proposed',
          '22222222-2222-2222-2222-222222222222','shared','beta') RETURNING id INTO v;
  PERFORM promote_memory(v,'22222222-2222-2222-2222-222222222222');
  PERFORM refresh_retrieval_units();
  UPDATE t SET pass = (retrieve_context('11111111-1111-1111-1111-111111111111','zzbeta canary')
                         ->>'units_matched')::int >= 1
   WHERE test = 'c2_a_granted_scope_still_constrains_no_reads';
EXCEPTION WHEN others THEN
  UPDATE t SET pass=false, detail=SQLERRM
   WHERE test='c2_a_granted_scope_still_constrains_no_reads'; END $c$;


SELECT section, test, pass, left(detail,64) AS detail FROM t ORDER BY section, test;

SELECT 'A_scope_isolation' AS summary, bool_and(coalesce(pass,false)) AS pass,
       count(*) FILTER (WHERE pass IS NOT TRUE)::text||' of '||count(*)::text||' failed' AS detail
FROM t WHERE section='A'
UNION ALL
SELECT 'B_registry_fails_loudly', bool_and(coalesce(pass,false)),
       count(*) FILTER (WHERE pass IS NOT TRUE)::text||' of '||count(*)::text||' failed'
FROM t WHERE section='B'
UNION ALL
SELECT 'C_gap_still_open_expected_true', bool_and(coalesce(pass,false)),
       count(*) FILTER (WHERE pass IS NOT TRUE)::text||' changed -- capabilities may now be wired'
FROM t WHERE section='C';

-- ── GUARD: an assertion that evaluated to NULL is NOT a pass ───────────────
-- Added after a discrimination run exposed this at every layer. A jsonb key
-- that does not exist yields NULL from ->>, so `(... ->> 'k') = 'v'` is NULL
-- rather than false; bool_and() IGNORES nulls, count(*) FILTER (WHERE NOT pass)
-- counts zero, and the replay runner greps for '| f' and sees a blank column.
-- 21 of 24 assertions in one file "passed" against a function that lacked the
-- feature entirely. Any NULL here is a broken assertion, not a passing one.
SELECT 'GUARD_no_null_assertions' AS summary,
       coalesce(bool_and(pass IS NOT NULL), true) AS pass,
       count(*) FILTER (WHERE pass IS NULL)::text||' assertion(s) evaluated to NULL' AS detail
FROM t;

-- ── EXPLICIT VERDICT ──────────────────────────────────────────────────────
-- The runner reads THIS line, not the formatted rows above. Grepping output
-- for '| f |' was wrong in both directions: it missed assertions that
-- evaluated to NULL (blank cell), and it invented failures in files that
-- legitimately print boolean `actual`/`expected` data columns. A test suite
-- must state its own verdict rather than have one inferred from its table
-- formatting.
SELECT CASE WHEN bool_and(coalesce(pass,false)) THEN 'SUITE_RESULT: PASS'
            ELSE 'SUITE_RESULT: FAIL' END AS verdict FROM t;

ROLLBACK;
