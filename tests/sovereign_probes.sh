#!/usr/bin/env bash
# tests/sovereign_probes.sh
#
# The positive / negative / conflict / stale-state / evidence-request probes
# upstream #58 requires, run identically against the SOURCE before export and
# against the DESTINATION after restore. Comparing the two transcripts is the
# point: "the negative probe was rejected after restore" is only evidence if the
# same probe was also rejected before.
#
# Each probe prints one line:
#   PROBE <name> <EXPECT:...> <RESULT:...> <PASS|FAIL>
# followed by indented detail. Exit 1 if any probe FAILs.
#
# ── EVERY PROBE RUNS INSIDE A ROLLED-BACK TRANSACTION ─────────────────────
# The negative probes have to ATTEMPT a forbidden write to prove it is refused.
# A probe that only reads cannot distinguish "the guard is there" from "the
# guard was dropped in the restore". So the writes are attempted for real and
# the transaction is rolled back, leaving both databases exactly as found --
# which is #58's "failure modes leave the source untouched".
#
# usage: sovereign_probes.sh <dbname>

set -uo pipefail
export LC_ALL="${LC_ALL:-C}"
DB="${1:-svsource}"
FAILED=0

# A human principal that certainly exists in the fixture; probes that need an
# actor resolve it dynamically so this file does not hardcode fixture UUIDs and
# quietly pass by matching nothing.
ACTOR="$(psql -d "$DB" -t -A -c "select id from principals where kind='human' and active order by created_at, id limit 1" 2>/dev/null)"

probe() {
  # probe <name> <expect-word> <sql>   -- prints result, sets FAILED on mismatch
  local name="$1" expect="$2" sql="$3"
  local out rc
  out=$(psql -d "$DB" -X -q -t -A -v ON_ERROR_STOP=1 <<SQLEOF 2>&1
set timezone='UTC'; set datestyle='ISO, YMD';
begin;
$sql
rollback;
SQLEOF
)
  rc=$?
  local result
  if [ $rc -eq 0 ]; then result="ACCEPTED"; else result="REJECTED"; fi
  local verdict="FAIL"
  if [ "$result" = "$expect" ]; then verdict="PASS"; else FAILED=1; fi
  echo "PROBE $name EXPECT:$expect RESULT:$result $verdict"
  printf '%s\n' "$out" | grep -E "ERROR|DETAIL|HINT|^[0-9]" | head -3 | sed 's/^/    /'
}

echo "== sovereign conformance probes (db=$DB, actor=$ACTOR) =="
echo

# ── POSITIVE ──────────────────────────────────────────────────────────────
probe positive.read_current_memories ACCEPTED \
  "do \$\$ begin
     if (select count(*) from memories where status='current') = 0 then
       raise exception 'no current memories: the vault restored empty';
     end if;
   end \$\$;"

probe positive.retrieve_context_envelope ACCEPTED \
  "do \$\$ declare v jsonb; begin
     v := retrieve_context('$ACTOR'::uuid, 'fixture', null, 8000, 20);
     if v->>'retrieval_status' is null then
       raise exception 'retrieve_context returned no envelope';
     end if;
     if (v->>'units_visible')::int = 0 then
       raise exception 'principal sees zero retrieval units after restore';
     end if;
   end \$\$;"

probe positive.propose_then_promote ACCEPTED \
  "insert into memories (id, content, provenance_basis, status, source_kind)
   values ('0f0f0f0f-0000-4000-8000-00000000000a','probe: proposed row','human_direct','proposed','manual');
   select promote_memory('0f0f0f0f-0000-4000-8000-00000000000a','$ACTOR'::uuid);"

# ── NEGATIVE ──────────────────────────────────────────────────────────────
probe negative.direct_insert_at_current REJECTED \
  "insert into memories (content, provenance_basis, status, source_kind)
   values ('probe: illegal direct current','human_direct','current','manual');"

probe negative.no_provenance REJECTED \
  "insert into memories (content, status, source_kind)
   values ('probe: no provenance','proposed','manual');"

probe negative.agent_self_attests_human_direct REJECTED \
  "insert into memories (content, provenance_basis, status, source_kind, source_agent)
   values ('probe: agent claims human_direct','human_direct','proposed','agent','AGENT-PROBE');"

probe negative.bare_status_mutation REJECTED \
  "update memories set status='superseded'
   where id = (select id from memories where status='current' order by id limit 1);"

probe negative.promoted_content_rewrite REJECTED \
  "update memories set content = content || ' TAMPERED'
   where id = (select id from memories where status='current' order by id limit 1);"

probe negative.audit_trail_is_append_only REJECTED \
  "delete from promoted_record_audit
   where id = (select id from promoted_record_audit order by id limit 1);"

probe negative.artifact_not_classified_import REJECTED \
  "insert into memories (content, provenance_basis, status, source_kind, source_artifact_id)
   values ('probe: from an evidence artifact','imported_artifact','proposed','imported_artifact',
           (select id from raw_artifacts where action = 'evidence' order by id limit 1));"

probe negative.grant_on_undeclared_scope REJECTED \
  "insert into capability_grants (principal_id, resource_scope, permissions, granted_by)
   values ('$ACTOR'::uuid, 'workstream:typo-not-declared', '{read}', '$ACTOR'::uuid);"

probe negative.non_human_promotes REJECTED \
  "insert into memories (id, content, provenance_basis, status, source_kind)
   values ('0f0f0f0f-0000-4000-8000-00000000000b','probe: promoted by an agent','human_direct','proposed','manual');
   select promote_memory('0f0f0f0f-0000-4000-8000-00000000000b',
     (select id from principals where kind='agent' and active order by id limit 1));"

# ── CONFLICT ──────────────────────────────────────────────────────────────
probe conflict.two_current_wiki_pages_same_path REJECTED \
  "insert into wiki_pages (path, title, content, provenance_basis, status, source_kind)
   select w.path, 'probe duplicate', 'probe body', 'human_direct', 'current', 'manual'
   from wiki_pages w where w.status='current' order by w.path limit 1;"

probe conflict.duplicate_source_artifact REJECTED \
  "insert into raw_artifacts (batch_id, source_system, source_id, payload, payload_sha256)
   select r.batch_id, r.source_system, r.source_id, '{}'::jsonb, 'x'
   from raw_artifacts r order by r.id limit 1;"

probe conflict.review_queue_holds_contradiction ACCEPTED \
  "do \$\$ begin
     if (select count(*) from review_queue where kind='contradiction' and resolution='pending') = 0 then
       raise exception 'no pending contradiction survived the restore';
     end if;
   end \$\$;"

# ── STALE STATE ───────────────────────────────────────────────────────────
probe stale.superseded_rows_are_not_current ACCEPTED \
  "do \$\$ begin
     if exists (select 1 from memories where status='superseded' and effective_to is null) then
       raise exception 'a superseded row has no effective_to: stale state is indistinguishable from current';
     end if;
     if not exists (select 1 from memories where status='superseded') then
       raise exception 'no superseded rows at all: the stale-state probe is vacuous';
     end if;
   end \$\$;"

probe stale.retrieval_acl_drift_is_zero ACCEPTED \
  "do \$\$ declare n int; begin
     select count(*) into n from retrieval_acl_drift();
     if n <> 0 then raise exception 'retrieval projection serves stale access control on % units', n; end if;
   end \$\$;"

probe stale.stale_embedding_is_visible ACCEPTED \
  "do \$\$ begin
     if (select count(*) from retrieval_embeddings where stale_at is not null) = 0 then
       raise exception 'no stale embedding present: the staleness probe is vacuous';
     end if;
   end \$\$;"

probe stale.superseded_source_has_no_live_unit ACCEPTED \
  "do \$\$ declare n int; begin
     select count(*) into n
     from retrieval_units ru join memories m on m.id = ru.source_id
     where ru.source_relation='memories' and ru.invalidated_at is null and m.status <> 'current';
     if n <> 0 then raise exception '% live retrieval units point at non-current memories', n; end if;
   end \$\$;"

# ── EVIDENCE REQUEST ──────────────────────────────────────────────────────
probe evidence.locator_resolves_to_a_record ACCEPTED \
  "do \$\$ declare r record; n int := 0; begin
     for r in select exact_locator, source_relation, source_id from retrieval_units
              where invalidated_at is null loop
       if r.source_relation = 'memories' then
         if not exists (select 1 from memories where id = r.source_id) then
           raise exception 'locator % points at a memory that does not exist', r.exact_locator;
         end if;
       else
         if not exists (select 1 from wiki_pages where id = r.source_id) then
           raise exception 'locator % points at a wiki page that does not exist', r.exact_locator;
         end if;
       end if;
       n := n + 1;
     end loop;
     if n = 0 then raise exception 'no live locators to resolve: the evidence probe is vacuous'; end if;
   end \$\$;"

probe evidence.doc_integrity_blessings_match ACCEPTED \
  "do \$\$ declare r record; begin
     for r in select path from doc_integrity loop
       if (select state from verify_doc_integrity(r.path)) <> 'match' then
         raise exception 'doc integrity for % is %', r.path,
           (select state from verify_doc_integrity(r.path));
       end if;
     end loop;
     if (select count(*) from doc_integrity) = 0 then
       raise exception 'no blessed docs: the integrity probe is vacuous';
     end if;
   end \$\$;"

probe evidence.promoted_integrity_matches ACCEPTED \
  "do \$\$ declare n int; begin
     select count(*) into n from verify_promoted_integrity() where state = 'mismatch';
     if n <> 0 then raise exception '% promoted records fail their content hash', n; end if;
     if (select count(*) from verify_promoted_integrity() where state='match') = 0 then
       raise exception 'no audited promotions at all: the integrity probe is vacuous';
     end if;
   end \$\$;"

probe evidence.citation_present_where_required ACCEPTED \
  "do \$\$ declare n int; begin
     select count(*) into n from memories
     where provenance_basis is distinct from 'human_direct'
       and (citation is null or length(trim(citation)) = 0);
     if n <> 0 then raise exception '% rows require a citation and have none', n; end if;
   end \$\$;"

echo
if [ "$FAILED" -ne 0 ]; then
  echo "PROBES FAILED"
  exit 1
fi
echo "ALL PROBES PASSED"
exit 0
