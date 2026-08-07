-- tests/31_consequential_domains.sql
-- ADOPT: upstream sovereign-memory-core #44 (consequential domains).
-- Covers sql/31_consequential_domains.sql.
--
-- Run against a FRESH database (tests/replay_fresh_install.sh). Self-contained:
-- creates its own principals and domain bindings, and rolls back.
--
-- ── HOW TO READ A RESULT ────────────────────────────────────────────────────
-- Every `pass` must be TRUE. What TRUE MEANS differs by section, so read the
-- section header before concluding anything.
--
-- A — POSITIVE CONTROL over guards that predate this file. TRUE = rejected.
--     If any A goes false the harness is not detecting rejections at all and
--     B/C prove nothing. A negative suite with no control is how a project
--     ends up with tests that pass and prove nothing.
-- B — #44 UNSOURCED CONSEQUENTIAL FACTS. TRUE = rejected.
-- C — #44 AGENT-AUTHORED CONSEQUENTIAL FACTS. TRUE = rejected.
-- D — THE LEGITIMATE PATH. TRUE = the write SUCCEEDED. A domain guard that
--     turns B and C green by making review impossible has broken the system,
--     not secured it.
-- E — DOCUMENTED LIMITS. TRUE = the known hole is still open, on purpose.
--     If an E test starts FAILING, enforcement changed and sql/31's header now
--     overstates its own limits — a docs bug, not a test bug.
--
-- ── WHAT MAKES B AND C MEANINGFUL ──────────────────────────────────────────
-- Nearly every B/C case is one the sql/03 baseline ACCEPTS. That is the point:
-- a test that only re-proves enforce_provenance() would go green against an
-- empty sql/31. Each case notes what the baseline does with it. The two that
-- are also caught by a pre-existing guard say so rather than taking credit.
--
-- Several B/C assertions check the ERROR TEXT, not just that something was
-- refused. "Some trigger said no" is not evidence the domain layer ran — a
-- typo'd column name also raises. Where the domain guard is supposed to be the
-- one rejecting, the assertion says which message it expects.
--
-- ── ON PRIVILEGE CONTEXT ────────────────────────────────────────────────────
-- Same as tests/23: these run as superuser, RLS is bypassed, and that is a
-- faithful model rather than a cheat. memories and wiki_pages have RLS on with
-- zero policies and all privileges revoked, so every production write arrives
-- via service_role or a SECURITY DEFINER function. Triggers are the layer that
-- actually executes, and triggers fire for superusers too.

BEGIN;

CREATE TEMP TABLE t(section text, test text, pass boolean, detail text) ON COMMIT DROP;

INSERT INTO principals (id,kind,display_name,email) VALUES
 ('11111111-1111-1111-1111-111111111111','human','H1','h1@example.com');
INSERT INTO principals (id,kind,display_name,agent_label) VALUES
 ('33333333-3333-3333-3333-333333333333','agent','A1','A1');

-- Schema-owner-declared bindings. Deliberately NOT seeded by sql/31: which
-- workstreams are consequential is a deployment fact. These three stand in for
-- a deployment that has done its declaration work.
INSERT INTO consequential_domain_binding (table_name, workstream, domain, declared_by) VALUES
 ('memories',  'finance-ops','financial','11111111-1111-1111-1111-111111111111'),
 ('memories',  'people-ops', 'identity', '11111111-1111-1111-1111-111111111111'),
 ('memories',  'clinical',   'medical',  '11111111-1111-1111-1111-111111111111'),
 ('wiki_pages','clinical',   'medical',  '11111111-1111-1111-1111-111111111111'),
 ('wiki_pages','finance-ops','financial','11111111-1111-1111-1111-111111111111');


-- ══════════════════════════════════════════════════════════════════════════
-- SECTION A — POSITIVE CONTROL over pre-sql/31 guards. All must be TRUE.
-- None of these rows carry a domain, so none of them touch the new code path.
-- They exist to prove this file can observe a rejection at all.
-- ══════════════════════════════════════════════════════════════════════════

DO $c$ BEGIN
  INSERT INTO memories (content, source_kind, status, owner, visibility, workstream)
  VALUES ('no basis','manual','proposed','11111111-1111-1111-1111-111111111111','shared','misc');
  INSERT INTO t VALUES ('A','ctl_null_provenance_basis_rejected',false,'accepted');
EXCEPTION WHEN others THEN INSERT INTO t VALUES ('A','ctl_null_provenance_basis_rejected',true,SQLERRM); END $c$;

DO $c$ BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility, workstream)
  VALUES ('no citation','manual','source_document','proposed','11111111-1111-1111-1111-111111111111','shared','misc');
  INSERT INTO t VALUES ('A','ctl_missing_citation_rejected',false,'accepted');
EXCEPTION WHEN others THEN INSERT INTO t VALUES ('A','ctl_missing_citation_rejected',true,SQLERRM); END $c$;

DO $c$ BEGIN
  INSERT INTO memories (content, source_kind, source_agent, provenance_basis, status, owner, visibility, workstream)
  VALUES ('agent claims human','agent','A1','human_direct','proposed','11111111-1111-1111-1111-111111111111','shared','misc');
  INSERT INTO t VALUES ('A','ctl_agent_human_direct_rejected',false,'accepted');
EXCEPTION WHEN others THEN INSERT INTO t VALUES ('A','ctl_agent_human_direct_rejected',true,SQLERRM); END $c$;

DO $c$ BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility, workstream)
  VALUES ('direct to current','manual','human_direct','current','11111111-1111-1111-1111-111111111111','shared','misc');
  INSERT INTO t VALUES ('A','ctl_direct_insert_at_current_rejected',false,'accepted');
EXCEPTION WHEN others THEN INSERT INTO t VALUES ('A','ctl_direct_insert_at_current_rejected',true,SQLERRM); END $c$;

DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility, workstream)
  VALUES ('candidate','manual','human_direct','proposed','11111111-1111-1111-1111-111111111111','shared','misc')
  RETURNING id INTO v;
  PERFORM promote_memory(v,'33333333-3333-3333-3333-333333333333');
  INSERT INTO t VALUES ('A','ctl_agent_principal_cannot_promote',false,'accepted');
EXCEPTION WHEN others THEN INSERT INTO t VALUES ('A','ctl_agent_principal_cannot_promote',true,SQLERRM); END $c$;

-- The inverse control. Every other A case proves a rejection is visible; this
-- one proves an ACCEPTANCE is visible. Without it, a harness in which every
-- insert failed for an unrelated reason would show all-green in A, B and C.
DO $c$ BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility, workstream)
  VALUES ('ordinary unclassified fact','manual','human_direct','proposed',
          '11111111-1111-1111-1111-111111111111','shared','misc');
  INSERT INTO t VALUES ('A','ctl_baseline_write_still_accepted',true,'accepted as expected');
EXCEPTION WHEN others THEN INSERT INTO t VALUES ('A','ctl_baseline_write_still_accepted',false,SQLERRM); END $c$;


-- ══════════════════════════════════════════════════════════════════════════
-- SECTION B — #44: UNSOURCED CONSEQUENTIAL FACTS. All must be TRUE.
-- ══════════════════════════════════════════════════════════════════════════

-- B1: a financial fact on a bare human statement. THE motivating case: sql/03's
-- header says the original trigger was built after a fabricated figure reached
-- production output, and a fabricated figure arrives exactly like this.
-- BASELINE ACCEPTS THIS — human_direct is in requires_citation_unless, so
-- enforce_provenance() waves it through with no citation at all.
DO $c$ BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility, workstream)
  VALUES ('Q3 supplier spend was 412,000','manual','human_direct','proposed',
          '11111111-1111-1111-1111-111111111111','shared','finance-ops');
  INSERT INTO t VALUES ('B','b1_financial_bare_human_statement_rejected',false,
    'a stated figure became a financial fact with no source');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b1_financial_bare_human_statement_rejected',
    SQLERRM LIKE '%financial domain%', SQLERRM); END $c$;

-- B2: same, but the writer supplies a citation. Still rejected: for financial
-- the objection is to the BASIS, not the missing citation. A citation attached
-- to a remembered statement is a citation of the statement.
-- BASELINE ACCEPTS THIS.
DO $c$ BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, citation, status, owner, visibility, workstream)
  VALUES ('Q3 supplier spend was 412,000','manual','human_direct','said in standup 2026-08-01','proposed',
          '11111111-1111-1111-1111-111111111111','shared','finance-ops');
  INSERT INTO t VALUES ('B','b2_financial_human_direct_with_citation_still_rejected',false,
    'human_direct accepted for a financial fact');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b2_financial_human_direct_with_citation_still_rejected',
    SQLERRM LIKE '%financial domain%', SQLERRM); END $c$;

-- B3: a medical fact sourced to an internal decision rather than a document.
-- This is the domain DIFFERENTIATION test: decision_record is a perfectly good
-- basis for a financial fact and is not one for a medical fact. If sql/31 were
-- a single global rule instead of per-domain policy, this could not be true
-- while D2 (agent medical proposal accepted) also holds.
-- BASELINE ACCEPTS THIS.
DO $c$ BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, citation, status, owner, visibility, workstream)
  VALUES ('patient is cleared for the trial','manual','decision_record','decision:2026-07-14 review','proposed',
          '11111111-1111-1111-1111-111111111111','shared','clinical');
  INSERT INTO t VALUES ('B','b3_medical_decision_record_rejected',false,
    'an internal decision became a medical fact');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b3_medical_decision_record_rejected',
    SQLERRM LIKE '%medical domain%', SQLERRM); END $c$;

-- B4: no basis at all on a domain row. Baseline also rejects this; kept because
-- the ORDER matters — the domain trigger sorts before enforce_provenance, so
-- the operator must get the domain-specific message telling them WHICH bases
-- this domain accepts, not the generic one.
DO $c$ BEGIN
  INSERT INTO memories (content, source_kind, status, owner, visibility, workstream)
  VALUES ('unsourced clinical claim','manual','proposed',
          '11111111-1111-1111-1111-111111111111','shared','clinical');
  INSERT INTO t VALUES ('B','b4_domain_row_without_basis_rejected',false,'accepted');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b4_domain_row_without_basis_rejected',
    SQLERRM LIKE '%medical domain and requires a provenance_basis%', SQLERRM); END $c$;

-- B5: THE BINDING TEST, and the most important one in the file. The row
-- declares NO domain. The writer said nothing, cooperated with nothing, and is
-- still classified — because the workstream binding is schema-owner
-- configuration, not a self-description. Every other B case could be evaded by
-- a writer who simply omits the domain column; this one cannot.
-- BASELINE ACCEPTS THIS (human_direct needs no citation).
DO $c$ BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility, workstream)
  VALUES ('J. Rivera is the authorized signatory','manual','human_direct','proposed',
          '11111111-1111-1111-1111-111111111111','shared','people-ops');
  INSERT INTO t VALUES ('B','b5_workstream_binding_classifies_undeclared_row',false,
    'undeclared row escaped its workstream binding');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b5_workstream_binding_classifies_undeclared_row',
    SQLERRM LIKE '%identity domain, which requires a non-empty citation%', SQLERRM); END $c$;

-- B6: row-declared domain with no binding anywhere. The weakest source, but it
-- must still bite when used. BASELINE ACCEPTS THIS.
DO $c$ BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, consequential_domain,
                        status, owner, visibility, workstream)
  VALUES ('the signatory is whoever holds the key','manual','human_direct','identity','proposed',
          '11111111-1111-1111-1111-111111111111','shared','misc');
  INSERT INTO t VALUES ('B','b6_row_declared_domain_enforced',false,'accepted');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b6_row_declared_domain_enforced',
    SQLERRM LIKE '%identity domain, which requires a non-empty citation%', SQLERRM); END $c$;

-- B7: a writer in a bound workstream declaring a DIFFERENT domain. Rejected
-- rather than silently overridden: silent override would let this insert
-- succeed and leave the writer believing the row is classified the way they
-- said it was.
DO $c$ BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, citation, consequential_domain,
                        status, owner, visibility, workstream)
  VALUES ('dosage schedule','manual','source_document','protocol v2 p4','financial','proposed',
          '11111111-1111-1111-1111-111111111111','shared','clinical');
  INSERT INTO t VALUES ('B','b7_binding_conflict_rejected',false,
    'row-declared domain silently overrode the workstream binding');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b7_binding_conflict_rejected',
    SQLERRM LIKE '%consequential domain conflict%', SQLERRM); END $c$;

-- B8: table-level domain. Registered for `memories` only for the duration of
-- this block — the DO block is a subtransaction, so the registry UPDATE is
-- rolled back with the failed INSERT. The explicit reset after the block covers
-- the case where the INSERT wrongly SUCCEEDS and the block commits.
DO $c$ BEGIN
  UPDATE provenance_registry SET table_domain='financial' WHERE table_name='memories';
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility, workstream)
  VALUES ('anything at all','manual','human_direct','proposed',
          '11111111-1111-1111-1111-111111111111','shared','unbound-workstream');
  INSERT INTO t VALUES ('B','b8_table_domain_classifies_every_row',false,
    'table_domain did not reach a row in an unbound workstream');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b8_table_domain_classifies_every_row',
    SQLERRM LIKE '%financial domain%', SQLERRM); END $c$;
UPDATE provenance_registry SET table_domain=NULL WHERE table_name='memories';

-- B9: FAIL-CLOSED. A domain with no policy row must refuse writes, not permit
-- them. If an undeclared domain read as unrestricted, then
-- `DELETE FROM consequential_domain_policy` would be a one-statement disarm of
-- this entire file and would leave every classified row looking fine.
--
-- READ E5 BEFORE GENERALIZING FROM THIS. Fail-closed holds for a MISSING
-- policy. It does not hold for a WEAKENED one, and the difference is one verb.
DO $c$ BEGIN
  DELETE FROM consequential_domain_binding WHERE domain='legal';
  DELETE FROM consequential_domain_policy  WHERE domain='legal';
  INSERT INTO memories (content, source_kind, provenance_basis, citation, consequential_domain,
                        status, owner, visibility, workstream)
  VALUES ('clause 7 permits termination','manual','source_document','MSA p12','legal','proposed',
          '11111111-1111-1111-1111-111111111111','shared','misc');
  INSERT INTO t VALUES ('B','b9_undeclared_domain_fails_closed',false,
    'a domain with no policy row was treated as unrestricted');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('B','b9_undeclared_domain_fails_closed',
    SQLERRM LIKE '%not declared in consequential_domain_policy%', SQLERRM); END $c$;


-- ══════════════════════════════════════════════════════════════════════════
-- SECTION C — #44: AGENT-AUTHORED CONSEQUENTIAL FACTS. All must be TRUE.
-- ══════════════════════════════════════════════════════════════════════════

-- C1: an agent authoring an identity claim. Not "must be reviewed" — refused.
-- Identity is what sql/23 resolves capabilities through, so an agent that can
-- write identity facts can influence what it is itself permitted to do. The
-- loop is cut rather than put in a queue.
-- BASELINE ACCEPTS THIS: source_kind='agent' with a non-human_direct basis and
-- status='proposed' satisfies enforce_agent_cannot_self_attest() completely.
--
-- The basis is source_document, which the identity policy ALLOWS. The first
-- version used imported_artifact and went red: the row was refused, but by the
-- basis rule, so the test proved nothing about agent authorship. That is the
-- error-text assertion doing its job — "something said no" was not enough.
DO $c$ BEGIN
  INSERT INTO memories (content, source_kind, source_agent, provenance_basis, citation,
                        status, owner, visibility, workstream)
  VALUES ('H1 holds admin on table:*','agent','A1','source_document','export:roles.csv','proposed',
          '11111111-1111-1111-1111-111111111111','shared','people-ops');
  INSERT INTO t VALUES ('C','c1_agent_identity_authorship_forbidden',false,
    'an agent authored an identity fact');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('C','c1_agent_identity_authorship_forbidden',
    SQLERRM LIKE '%not permitted in the identity domain%', SQLERRM); END $c$;

-- C2: an agent-authored financial WIKI page, on the one basis the baseline lets
-- an agent publish with. Two facts have to line up for this to be a real hole,
-- and the first draft of this test got the second one wrong:
--   * sql/26 does NOT gate wiki_pages inserts. wiki_pages defaults to
--     status='current' and has no promote_wiki(), so gating it would make the
--     table uncreatable. Correct, and the reason this path exists.
--   * sql/03's enforce_agent_cannot_self_attest() DOES apply to wiki_pages, and
--     forces agent rows to 'proposed' — EXCEPT when provenance_basis =
--     'decision_record'. That carve-out is the hole. The first draft used
--     source_document and went red because sql/03 rejected it first; the
--     comment claimed no existing guard touched this, and the comment was
--     wrong. Only decision_record isolates what sql/31 adds.
-- So: baseline accepts this row at status='current', authoritative, agent-
-- written, on a self-declared decision record. sql/31 refuses it.
DO $c$ BEGIN
  INSERT INTO wiki_pages (path, title, content, source_kind, source_agent, provenance_basis,
                          citation, workstream)
  VALUES ('/finance/spend','Spend','agent-written spend summary',
          'agent','A1','decision_record','decision: none actually exists','finance-ops');
  INSERT INTO t VALUES ('C','c2_agent_financial_wiki_cannot_land_current',false,
    'agent-authored financial wiki page landed at status=current');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('C','c2_agent_financial_wiki_cannot_land_current',
    SQLERRM LIKE '%must enter at status=proposed%', SQLERRM); END $c$;

-- C3: an agent inserting a financial memory straight at 'current' on a basis
-- that is NOT decision_record. DOUBLE-COVERED — sql/03's agent rule catches it
-- before sql/31 sees it, and sql/26's status sanction would too. Not evidence
-- for sql/31 on its own, and the assertion accordingly does not check for the
-- domain message. Kept because the three guards can be applied independently.
DO $c$ BEGIN
  INSERT INTO memories (content, source_kind, source_agent, provenance_basis, citation,
                        status, owner, visibility, workstream)
  VALUES ('agent-computed revenue figure','agent','A1','imported_artifact','export:ledger.csv','current',
          '11111111-1111-1111-1111-111111111111','shared','finance-ops');
  INSERT INTO t VALUES ('C','c3_agent_financial_cannot_enter_at_current',false,'accepted');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('C','c3_agent_financial_cannot_enter_at_current',true,SQLERRM); END $c$;

-- C4: the escape hatch. An agent proposes a legitimate medical row, then clears
-- its classification so the next write is held to the baseline. Without the
-- ratchet, every requirement in Section B is one UPDATE away from optional.
DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO memories (content, source_kind, source_agent, provenance_basis, citation,
                        status, owner, visibility, workstream)
  VALUES ('lab value from report','agent','A1','imported_artifact','report:LAB-8891','proposed',
          '11111111-1111-1111-1111-111111111111','shared','clinical')
  RETURNING id INTO v;
  UPDATE memories SET consequential_domain=NULL, workstream='misc' WHERE id=v;
  INSERT INTO t VALUES ('C','c4_classification_cannot_be_cleared',false,
    'domain cleared on an existing row');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('C','c4_classification_cannot_be_cleared',
    SQLERRM LIKE '%not editable once set%', SQLERRM); END $c$;

-- C5: same ratchet, sideways. Reclassifying medical -> financial in place would
-- swap the evidence rule under a row that was already accepted under the old one.
DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, citation, consequential_domain,
                        status, owner, visibility, workstream)
  VALUES ('imaging result','manual','source_document','report:MRI-4','medical','proposed',
          '11111111-1111-1111-1111-111111111111','shared','misc')
  RETURNING id INTO v;
  UPDATE memories SET consequential_domain='financial' WHERE id=v;
  INSERT INTO t VALUES ('C','c5_classification_cannot_be_swapped',false,'domain swapped in place');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('C','c5_classification_cannot_be_swapped',
    SQLERRM LIKE '%not editable once set%', SQLERRM); END $c$;

-- C6: LAUNDERING THROUGH SUPERSESSION. supersede_memory() takes the new basis
-- and citation as parameters and does not copy consequential_domain, so before
-- the inheritance rule in sql/31 a financial row could be "corrected" into an
-- unclassified human_direct row with no citation — and that successor is the
-- one that ends up current. The predecessor is preserved and attributed, which
-- makes it look audited. This is the quietest hole in the file and the reason
-- the inheritance rule keys on new.supersedes.
DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, citation, consequential_domain,
                        status, owner, visibility, workstream)
  VALUES ('invoice total 41,200','manual','source_document','invoice INV-77','financial','proposed',
          '11111111-1111-1111-1111-111111111111','shared','misc')
  RETURNING id INTO v;
  PERFORM promote_memory(v,'11111111-1111-1111-1111-111111111111');
  PERFORM supersede_memory(v,'invoice total 412,000','human_direct',NULL,
                           '11111111-1111-1111-1111-111111111111','correction');
  INSERT INTO t VALUES ('C','c6_supersession_cannot_launder_domain',false,
    'successor dropped the classification and landed current unsourced');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('C','c6_supersession_cannot_launder_domain',
    SQLERRM LIKE '%financial domain%', SQLERRM); END $c$;


-- C7: evidence downgrade after the fact. C4 and C5 stop the CLASSIFICATION
-- being edited; nothing so far stops the EVIDENCE being edited underneath a
-- classification that stays put. Insert a medical row on a document, then swap
-- the basis to a decision record. The row keeps its medical label and loses the
-- thing the label was supposed to guarantee.
DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, citation,
                        status, owner, visibility, workstream)
  VALUES ('dosage per protocol','manual','source_document','protocol v2 p4','proposed',
          '11111111-1111-1111-1111-111111111111','shared','clinical')
  RETURNING id INTO v;
  UPDATE memories SET provenance_basis='decision_record', citation='decision:x' WHERE id=v;
  INSERT INTO t VALUES ('C','c7_evidence_cannot_be_downgraded_after_insert',false,
    'basis swapped to one the medical policy forbids, classification intact');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('C','c7_evidence_cannot_be_downgraded_after_insert',
    SQLERRM LIKE '%medical domain%', SQLERRM); END $c$;

-- C8: the same move against the citation. sql/16's CHECK constraint rejects an
-- EMPTY citation, so an attacker would not use one — they would use NULL, which
-- CHECK treats as satisfied and which the sql/03 baseline permits for any
-- exempt basis. Only the domain policy's citation_required stands here.
DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, citation,
                        status, owner, visibility, workstream)
  VALUES ('dosage per protocol','manual','source_document','protocol v2 p4','proposed',
          '11111111-1111-1111-1111-111111111111','shared','clinical')
  RETURNING id INTO v;
  UPDATE memories SET citation=NULL WHERE id=v;
  INSERT INTO t VALUES ('C','c8_citation_cannot_be_nulled_after_insert',false,
    'citation removed from a medical row');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('C','c8_citation_cannot_be_nulled_after_insert',
    SQLERRM LIKE '%requires a non-empty citation%', SQLERRM); END $c$;

-- C9: C6 again, against wiki_pages and supersede_wiki() (sql/24). This is the
-- reason the inheritance rule keys on new.supersedes instead of being patched
-- into supersede_memory(): supersede_wiki() has its own fixed column list,
-- omits consequential_domain the same way, and has never heard of sql/31.
-- A fix inside supersede_memory() would have left this path open and looking
-- identical from the outside.
DO $c$ BEGIN
  INSERT INTO wiki_pages (path, title, content, source_kind, provenance_basis, citation,
                          consequential_domain, workstream)
  VALUES ('/legal/msa','MSA','term is 24 months','manual','source_document','MSA p3','legal','misc');
  PERFORM supersede_wiki('/legal/msa','MSA','term is 36 months','human_direct',NULL,
                         '11111111-1111-1111-1111-111111111111','amended');
  INSERT INTO t VALUES ('C','c9_wiki_supersession_cannot_launder_domain',false,
    'wiki successor dropped the classification and landed current unsourced');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('C','c9_wiki_supersession_cannot_launder_domain',
    SQLERRM LIKE '%legal domain%', SQLERRM); END $c$;


-- ══════════════════════════════════════════════════════════════════════════
-- SECTION D — THE LEGITIMATE PATH. TRUE means the write SUCCEEDED.
-- ══════════════════════════════════════════════════════════════════════════

-- D1: a properly sourced financial fact proposes and promotes, and comes out
-- the far side STAMPED with the domain the binding resolved — not merely
-- unrejected.
DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, citation,
                        status, owner, visibility, workstream)
  VALUES ('Q3 supplier spend was 412,000','manual','source_document','invoice bundle 2026-Q3','proposed',
          '11111111-1111-1111-1111-111111111111','shared','finance-ops')
  RETURNING id INTO v;
  PERFORM promote_memory(v,'11111111-1111-1111-1111-111111111111');
  INSERT INTO t VALUES ('D','d1_sourced_financial_fact_promotes',
    (SELECT status='current' AND consequential_domain='financial' FROM memories WHERE id=v),
    'promoted and stamped financial by the binding');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('D','d1_sourced_financial_fact_promotes',false,SQLERRM); END $c$;

-- D2: THE REGRESSION TEST FOR DESIGN DECISION 4, and it was written after the
-- bug rather than before. The first draft enforced agent_authorship on UPDATE
-- as well as INSERT — which rejected promote_memory() itself, because
-- promotion is an UPDATE setting an agent-sourced row to 'current'. Sections B
-- and C were all green with that version. The guard meant to stop agents
-- self-promoting instead stopped humans from promoting agent proposals, which
-- does not secure the review loop, it deletes it.
DO $c$ DECLARE v uuid; BEGIN
  INSERT INTO memories (content, source_kind, source_agent, provenance_basis, citation,
                        status, owner, visibility, workstream)
  VALUES ('lab value 5.2 mmol/L from report LAB-8891','agent','A1','imported_artifact',
          'report:LAB-8891','proposed','11111111-1111-1111-1111-111111111111','shared','clinical')
  RETURNING id INTO v;
  PERFORM promote_memory(v,'11111111-1111-1111-1111-111111111111');
  INSERT INTO t VALUES ('D','d2_agent_medical_proposal_is_promotable_by_a_human',
    (SELECT status='current' AND consequential_domain='medical' FROM memories WHERE id=v),
    'agent proposed, human promoted, classification intact');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('D','d2_agent_medical_proposal_is_promotable_by_a_human',false,SQLERRM); END $c$;

-- D3: supersession of a medical row still works. The successor is inserted at
-- status='current' inside sql/26's app.promoting window, and the successor's
-- basis and citation are re-checked against the medical policy on the way in —
-- correction is not a way around the evidence rule.
--
-- This was originally written with an AGENT-sourced predecessor, and it went
-- red. That is not a sql/31 failure and the test was moved rather than
-- weakened: see E4, which asserts the pre-existing defect it found.
DO $c$ DECLARE v uuid; v_new uuid; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, citation,
                        status, owner, visibility, workstream)
  VALUES ('lab value 5.2','manual','imported_artifact','report:LAB-9002','proposed',
          '11111111-1111-1111-1111-111111111111','shared','clinical')
  RETURNING id INTO v;
  PERFORM promote_memory(v,'11111111-1111-1111-1111-111111111111');
  v_new := supersede_memory(v,'lab value 5.4','source_document','report:LAB-9002 rev B',
                            '11111111-1111-1111-1111-111111111111','transcription fix');
  INSERT INTO t VALUES ('D','d3_supersession_of_medical_row_still_works',
    (SELECT status='current' AND consequential_domain='medical' FROM memories WHERE id=v_new)
    AND (SELECT status='superseded' FROM memories WHERE id=v),
    'successor current and still medical');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('D','d3_supersession_of_medical_row_still_works',false,SQLERRM); END $c$;

-- D4: the inheritance rule from the C6 side. Here the workstream is UNBOUND, so
-- the successor cannot be re-resolved from configuration — the only thing that
-- can keep it classified is inheritance from its predecessor. If this returns
-- an unclassified successor, C6 passed for the wrong reason (some other guard)
-- and row-declared classification does not survive a correction.
DO $c$ DECLARE v uuid; v_new uuid; BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, citation, consequential_domain,
                        status, owner, visibility, workstream)
  VALUES ('contract term is 24 months','manual','source_document','MSA p3','legal','proposed',
          '11111111-1111-1111-1111-111111111111','shared','misc')
  RETURNING id INTO v;
  PERFORM promote_memory(v,'11111111-1111-1111-1111-111111111111');
  v_new := supersede_memory(v,'contract term is 36 months','source_document','MSA amendment 1 p1',
                            '11111111-1111-1111-1111-111111111111','amended');
  INSERT INTO t VALUES ('D','d4_successor_inherits_row_declared_domain',
    (SELECT consequential_domain='legal' AND status='current' FROM memories WHERE id=v_new),
    'successor still legal in an unbound workstream');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('D','d4_successor_inherits_row_declared_domain',false,SQLERRM); END $c$;

-- D5: a properly sourced consequential WIKI page is still creatable. C2 gates
-- agent-authored ones; if it had gated all of them, wiki_pages would be
-- uncreatable in any bound workstream, which is the failure mode sql/26 named
-- when it declined to gate wiki inserts at all.
DO $c$ BEGIN
  INSERT INTO wiki_pages (path, title, content, source_kind, provenance_basis, citation, workstream)
  VALUES ('/clinical/protocol-human','Protocol','human-authored clinical protocol summary',
          'manual','source_document','protocol v2','clinical');
  INSERT INTO t VALUES ('D','d5_human_authored_consequential_wiki_still_works',
    (SELECT consequential_domain='medical' AND status='current'
       FROM wiki_pages WHERE path='/clinical/protocol-human'),
    'created and stamped medical');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('D','d5_human_authored_consequential_wiki_still_works',false,SQLERRM); END $c$;

-- D6: the operator surface answers the question operators actually ask —
-- "which of the three sources classified this row" — rather than making them
-- reconstruct the resolution order by hand.
DO $c$ BEGIN
  INSERT INTO t VALUES ('D','d6_coverage_view_attributes_the_binding',
    (SELECT bound_by='consequential_domain_binding'
       FROM consequential_domain_coverage()
      WHERE table_name='memories' AND workstream='finance-ops' AND domain='financial'),
    'coverage names the binding as the source');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('D','d6_coverage_view_attributes_the_binding',false,SQLERRM); END $c$;


-- ══════════════════════════════════════════════════════════════════════════
-- SECTION E — DOCUMENTED LIMITS. TRUE means the known hole is STILL OPEN.
-- Read the header before concluding anything from these.
-- ══════════════════════════════════════════════════════════════════════════

-- E1: THE LIMIT THAT MATTERS. A plainly financial fact, written into a
-- workstream nobody bound, declaring no domain, is accepted on a bare human
-- statement with no citation. sql/31 does not classify content; it enforces
-- classification that a schema owner declared or a writer volunteered. A
-- deployment that has declared nothing gets exactly the sql/03 baseline.
-- Closing this is content classification — a model-in-the-loop problem, not a
-- trigger — and pretending otherwise would be the more dangerous outcome,
-- because "#44: done" would then mean less than it appears to.
DO $c$ BEGIN
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility, workstream)
  VALUES ('we owe the supplier about 412,000','manual','human_direct','proposed',
          '11111111-1111-1111-1111-111111111111','shared','random-notes');
  INSERT INTO t VALUES ('E','limit_unbound_workstream_gets_baseline_only',true,
    'KNOWN LIMIT: an undeclared financial fact in an unbound workstream is accepted');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('E','limit_unbound_workstream_gets_baseline_only',false,
    'enforcement changed -- sql/31 now understates itself: '||SQLERRM); END $c$;

-- E2: the inherited sql/26 limit. app.promoting is a session GUC; a caller
-- holding service_role can arm it and insert an agent-authored consequential
-- row straight at current. sql/31 REUSES that window rather than inventing a
-- second one, so it adds no new bypass — but it inherits this one, and that is
-- worth saying in test output rather than only in a header comment.
--
-- financial + decision_record, not medical + source_document as first written:
-- sql/03's agent rule blocks every agent basis EXCEPT decision_record on its
-- own, GUC or no GUC, so any other combination goes red for a reason that has
-- nothing to do with the limit under test. The limit is real but narrower than
-- the first draft implied, and it is only reachable in a domain whose policy
-- admits decision_record at all.
DO $c$ BEGIN
  PERFORM set_config('app.promoting','on',true);
  INSERT INTO memories (content, source_kind, source_agent, provenance_basis, citation,
                        status, owner, visibility, workstream)
  VALUES ('self-armed agent financial fact','agent','A1','decision_record','decision:x','current',
          '11111111-1111-1111-1111-111111111111','shared','finance-ops');
  PERFORM set_config('app.promoting','off',true);
  INSERT INTO t VALUES ('E','limit_self_armed_guc_permits_agent_current_insert',true,
    'KNOWN LIMIT: agent-authored medical row reached current while the GUC was armed');
EXCEPTION WHEN others THEN
  PERFORM set_config('app.promoting','off',true);
  INSERT INTO t VALUES ('E','limit_self_armed_guc_permits_agent_current_insert',false,
    'enforcement changed -- sql/26 and sql/31 now overstate the limit: '||SQLERRM); END $c$;

-- E3: the evidence rules still apply inside that window. The GUC is a sanction
-- on the STATUS transition, and it would be easy to assume it disarms sql/31
-- wholesale. It does not: an armed caller can bypass propose-then-promote and
-- still cannot write a medical fact on a decision_record. TRUE here means the
-- limit in E2 is bounded, which is the only reason E2 is tolerable.
DO $c$ BEGIN
  PERFORM set_config('app.promoting','on',true);
  BEGIN
    INSERT INTO memories (content, source_kind, provenance_basis, citation,
                          status, owner, visibility, workstream)
    VALUES ('armed but unsourced clinical claim','manual','decision_record','decision:x','current',
            '11111111-1111-1111-1111-111111111111','shared','clinical');
    PERFORM set_config('app.promoting','off',true);
    INSERT INTO t VALUES ('E','limit_is_bounded_evidence_rules_survive_the_guc',false,
    'the GUC disarmed the evidence rules too -- E2 is much worse than documented');
  EXCEPTION WHEN others THEN
    PERFORM set_config('app.promoting','off',true);
    INSERT INTO t VALUES ('E','limit_is_bounded_evidence_rules_survive_the_guc',
      SQLERRM LIKE '%medical domain%', SQLERRM);
  END;
END $c$;

-- E4: A PRE-EXISTING DEFECT, FOUND BY THIS WORK AND NOT CAUSED BY IT.
-- TRUE means the defect is still there.
--
-- An agent-sourced row that a human promoted cannot be superseded unless the
-- CORRECTION's basis is 'decision_record'. supersede_memory() (sql/26) copies
-- source_kind from the predecessor, so the successor is still source_kind=
-- 'agent'; sql/03's enforce_agent_cannot_self_attest() then sees an agent row
-- at status='current' and refuses everything except decision_record. The human
-- who is actually making the correction is a parameter of the function and is
-- not consulted.
--
-- This has nothing to do with domains — it is reachable on the pre-sql/31
-- schema for any agent-sourced memory. But sql/31 makes it BITE, because
-- 'medical' and 'legal' exclude decision_record by policy. An agent-proposed,
-- human-promoted medical fact is therefore permanently uncorrectable: the only
-- basis sql/03 will accept for its successor is the one the medical policy
-- forbids. Two individually defensible rules composing into a dead end.
--
-- FIXED, after this test found it. The fix is in supersede_memory(): a
-- correction authored by a human principal no longer inherits the predecessor's
-- source_kind. The successor is recorded as manual with the predecessor's
-- authorship preserved in metadata (corrected_from_source_kind /
-- corrected_from_source_agent), which is truthful -- supersede_memory already
-- refuses any actor that is not an active human.
--
-- This assertion was originally written the other way round, asserting the
-- defect was PRESENT, and it went red the moment sql/26 was corrected. That is
-- the behaviour a limit-assertion should have: it does not quietly agree with
-- whatever the code now does.
DO $c$ DECLARE v uuid; v2 uuid; BEGIN
  INSERT INTO memories (content, source_kind, source_agent, provenance_basis, citation,
                        status, owner, visibility, workstream)
  VALUES ('agent-proposed clinical value','agent','A1','imported_artifact','report:LAB-7','proposed',
          '11111111-1111-1111-1111-111111111111','shared','clinical')
  RETURNING id INTO v;
  PERFORM promote_memory(v,'11111111-1111-1111-1111-111111111111');
  v2 := supersede_memory(v,'corrected clinical value','source_document','report:LAB-7 rev B',
                         '11111111-1111-1111-1111-111111111111','transcription fix');
  INSERT INTO t VALUES ('E','fixed_agent_sourced_medical_row_is_correctable',
    (SELECT source_kind='manual' AND metadata->>'corrected_from_source_kind'='agent'
       FROM memories WHERE id=v2),
    'human correction succeeds and records true authorship');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('E','fixed_agent_sourced_medical_row_is_correctable',false,
    'still uncorrectable: '||SQLERRM);
END $c$;


-- E5: THE ASYMMETRY B9 DOES NOT COVER, and the one that most invites a wrong
-- conclusion. TRUE means the hole is still open.
--
-- B9 shows that DELETING a policy row fails closed. It is tempting to read that
-- as "the policy table is safe". It is not. A policy row can be UPDATED into
-- permissiveness — allowed_basis widened, citation_required cleared — and
-- every subsequent write sails through while the domain label, the binding,
-- and consequential_domain_coverage() all continue to look exactly as healthy
-- as they did before. DELETE fails closed only because it leaves nothing to
-- consult; UPDATE leaves something to consult and makes it say yes.
--
-- Not closed here, deliberately. A ratchet forbidding loosening is either
-- absolute — in which case a wrong baseline can never be corrected and the
-- table stops being policy — or it has an escape, in which case the escape is
-- the new hole. And it would be the same shape as app.promoting: a guard whose
-- own bypass is a statement away, presented as enforcement. The honest answer
-- for a service_role-holding caller is the one sql/26 already gives, and the
-- useful answer is an audit surface on this table, which is a separate change.
DO $c$ BEGIN
  UPDATE consequential_domain_policy
     SET allowed_basis = array['human_direct']::provenance_basis[], citation_required = false
   WHERE domain = 'medical';
  INSERT INTO memories (content, source_kind, provenance_basis, status, owner, visibility, workstream)
  VALUES ('unsourced clinical claim','manual','human_direct','proposed',
          '11111111-1111-1111-1111-111111111111','shared','clinical');
  INSERT INTO t VALUES ('E','limit_policy_can_be_weakened_in_place',true,
    'KNOWN LIMIT: medical policy widened by UPDATE, then an unsourced clinical fact was accepted');
EXCEPTION WHEN others THEN
  INSERT INTO t VALUES ('E','limit_policy_can_be_weakened_in_place',false,
    'enforcement changed -- sql/31 now understates itself: '||SQLERRM); END $c$;
UPDATE consequential_domain_policy
   SET allowed_basis = array['imported_artifact','source_document']::provenance_basis[],
       citation_required = true
 WHERE domain = 'medical';


-- ── Results ────────────────────────────────────────────────────────────────
SELECT section, test, pass, left(detail,72) AS detail FROM t ORDER BY section, test;

SELECT 'A_controls' AS summary, bool_and(coalesce(pass,false)) AS pass,
       count(*) FILTER (WHERE pass IS NOT TRUE)::text||' of '||count(*)::text||' failed' AS detail
FROM t WHERE section='A'
UNION ALL
SELECT 'B_44_unsourced_consequential_rejected', bool_and(coalesce(pass,false)),
       count(*) FILTER (WHERE pass IS NOT TRUE)::text||' of '||count(*)::text||' still OPEN'
FROM t WHERE section='B'
UNION ALL
SELECT 'C_44_agent_authored_consequential_rejected', bool_and(coalesce(pass,false)),
       count(*) FILTER (WHERE pass IS NOT TRUE)::text||' of '||count(*)::text||' still OPEN'
FROM t WHERE section='C'
UNION ALL
SELECT 'D_legitimate_path_intact', bool_and(coalesce(pass,false)),
       count(*) FILTER (WHERE pass IS NOT TRUE)::text||' of '||count(*)::text||' BROKEN by the guard'
FROM t WHERE section='D'
UNION ALL
SELECT 'E_documented_limits_still_present', bool_and(coalesce(pass,false)),
       count(*) FILTER (WHERE pass IS NOT TRUE)::text||' of '||count(*)::text||' changed -- update the docs'
FROM t WHERE section='E';

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

ROLLBACK;
