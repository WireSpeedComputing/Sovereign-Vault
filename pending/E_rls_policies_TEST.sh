#!/usr/bin/env bash
# Tests for pending/E_rls_policies.sql.
#
# A SHELL script, not a .sql file, and that is the whole point.
#
# RLS policies apply to `authenticated`, and vault_auth._trusted_request_claims()
# returns claims ONLY when session_user = 'authenticator'. Verified before
# writing this:
#
#   SET ROLE authenticator   -> current_user=authenticator, session_user=<login>
#   connect AS authenticator -> current_user=authenticator, session_user=authenticator
#
# So a psql script using SET ROLE cannot reach the claims path at all. Every row
# would be denied, every negative assertion would pass, and the suite would
# report a working policy model while having tested nothing. That is the exact
# shape of failure this project keeps finding, and it is why this file opens its
# own connections as a real login role, the way PostgREST does.
#
# Usage:
#   ./pending/E_rls_policies_TEST.sh            # uses port 5481
# Requires PG17 + pgvector. Stands up its own isolated cluster; touches nothing
# shared with tests/replay_fresh_install.sh.

set -uo pipefail
export LC_ALL="${LC_ALL:-C}"

PORT="${E_TEST_PORT:-5481}"
PGDATA_DIR=/tmp/e_rls_pgdata
SOCK_DIR=/tmp/e_rls_sock
DB=erls
REPO="$(cd "$(dirname "$0")/.." && pwd)"

cleanup() { pg_ctl -D "$PGDATA_DIR" stop -m fast >/dev/null 2>&1 || true; rm -rf "$PGDATA_DIR" "$SOCK_DIR"; }
trap cleanup EXIT

rm -rf "$PGDATA_DIR" "$SOCK_DIR"; mkdir -p "$SOCK_DIR"
initdb -D "$PGDATA_DIR" >/tmp/e_rls_initdb.log 2>&1 || { echo "initdb FAILED"; exit 1; }
pg_ctl -D "$PGDATA_DIR" -o "-p $PORT -k $SOCK_DIR -c listen_addresses=''" \
  -l /tmp/e_rls_server.log start >/dev/null || { echo "server start FAILED"; cat /tmp/e_rls_server.log; exit 1; }
sleep 2
export PGHOST="$SOCK_DIR" PGPORT="$PORT"
createdb "$DB" || exit 1

echo "== building schema =="
for f in $(ls "$REPO"/sql/*.sql | sort); do
  psql -d "$DB" -v ON_ERROR_STOP=1 -q -f "$f" >/dev/null 2>&1 \
    || { echo "FAILED applying $(basename "$f")"; exit 1; }
done
for f in "$REPO/pending/B_retrieval_topology_ISSUE72.sql" "$REPO/pending/E_rls_policies.sql"; do
  psql -d "$DB" -v ON_ERROR_STOP=1 -q -f "$f" >/dev/null 2>/tmp/e_rls_apply.err \
    || { echo "FAILED applying $(basename "$f")"; cat /tmp/e_rls_apply.err; exit 1; }
done
echo "  schema + pending/B + pending/E applied"

# authenticator is a LOGIN role, exactly as PostgREST connects.
psql -d "$DB" -q -c "
  do \$\$ begin
    if not exists (select 1 from pg_roles where rolname='authenticator') then
      create role authenticator login noinherit;
    end if;
  end \$\$;
  grant authenticated to authenticator;
  grant usage on schema public to authenticated;
  grant select on public.memories, public.wiki_pages, public.retrieval_units to authenticated;
" >/dev/null

echo "== fixtures =="
if ! psql -d "$DB" -v ON_ERROR_STOP=1 -q <<'SQL' >/dev/null 2>/tmp/e_rls_fixture.err
insert into principals (id,kind,display_name,email) values
 ('aaaa0000-0000-0000-0000-00000000000a','human','Alice','alice@example.test'),
 ('bbbb0000-0000-0000-0000-00000000000b','human','Bob','bob@example.test'),
 ('cccc0000-0000-0000-0000-00000000000c','human','Granter','g@example.test');

insert into scope_registry (scope,kind,identifier,description,declared_by) values
 ('workstream:alpha','workstream','alpha','Alpha','cccc0000-0000-0000-0000-00000000000c'),
 ('workstream:beta','workstream','beta','Beta','cccc0000-0000-0000-0000-00000000000c'),
 ('workstream:unclassified','workstream','unclassified','Reserved scope for rows with no workstream','cccc0000-0000-0000-0000-00000000000c');

-- Alice: alpha + unclassified. Bob: beta only.
insert into capability_grants (principal_id,resource_scope,permissions,granted_by) values
 ('aaaa0000-0000-0000-0000-00000000000a','workstream:alpha','{read}','cccc0000-0000-0000-0000-00000000000c'),
 ('aaaa0000-0000-0000-0000-00000000000a','workstream:unclassified','{read}','cccc0000-0000-0000-0000-00000000000c'),
 ('bbbb0000-0000-0000-0000-00000000000b','workstream:beta','{read}','cccc0000-0000-0000-0000-00000000000c');

-- reviewed_by/reviewed_at are REQUIRED for an approved binding
-- (vault_auth._validate_identity_binding). The first draft of this fixture
-- omitted them; the insert failed, no identity resolved, and every negative
-- assertion below passed while the positive control failed. That is what
-- Section 0 exists to catch -- a broken claims path is indistinguishable from
-- a working deny-all if you only assert denials.
--
-- issuer is the LITERAL iss claim URL, not a friendly label. A label inserts
-- cleanly and silently resolves nothing.
insert into vault_auth.principal_identity_bindings
 (identity_kind,issuer,identity_value,principal_id,binding_status,review_status,
  created_by,reviewed_by,reviewed_at,reason,citation,provenance_basis,workstream,
  source_agent) values
 ('auth_subject','https://example.test/auth/v1','alice-sub','aaaa0000-0000-0000-0000-00000000000a',
  'active','approved','cccc0000-0000-0000-0000-00000000000c',
  'cccc0000-0000-0000-0000-00000000000c',now(),'test','test','human_direct','alpha','test-harness'),
 ('auth_subject','https://example.test/auth/v1','bob-sub','bbbb0000-0000-0000-0000-00000000000b',
  'active','approved','cccc0000-0000-0000-0000-00000000000c',
  'cccc0000-0000-0000-0000-00000000000c',now(),'test','test','human_direct','beta','test-harness');

-- rows: alpha shared, beta shared, unclassified shared, alice-private alpha
do $$ declare v uuid; begin
  insert into memories (content,source_kind,provenance_basis,status,owner,visibility,workstream)
  values ('zzalpha shared fact','manual','human_direct','proposed',
          'aaaa0000-0000-0000-0000-00000000000a','shared','alpha') returning id into v;
  perform promote_memory(v,'aaaa0000-0000-0000-0000-00000000000a');

  insert into memories (content,source_kind,provenance_basis,status,owner,visibility,workstream)
  values ('zzbeta shared fact','manual','human_direct','proposed',
          'bbbb0000-0000-0000-0000-00000000000b','shared','beta') returning id into v;
  perform promote_memory(v,'bbbb0000-0000-0000-0000-00000000000b');

  insert into memories (content,source_kind,provenance_basis,status,owner,visibility)
  values ('zznull workstream fact','manual','human_direct','proposed',
          'aaaa0000-0000-0000-0000-00000000000a','shared') returning id into v;
  perform promote_memory(v,'aaaa0000-0000-0000-0000-00000000000a');

  insert into memories (content,source_kind,provenance_basis,status,owner,visibility,workstream)
  values ('zzalice private alpha','manual','human_direct','proposed',
          'aaaa0000-0000-0000-0000-00000000000a','private','alpha') returning id into v;
  perform promote_memory(v,'aaaa0000-0000-0000-0000-00000000000a');
end $$;
select * from refresh_retrieval_units();
SQL
then
  # A fixture that fails silently is how Section 0 came to fail twice: no
  # identity resolves, every denial assertion passes, and the suite looks
  # almost-green. Fail here instead.
  echo "FIXTURE SETUP FAILED -- aborting rather than reporting misleading passes"
  cat /tmp/e_rls_fixture.err
  exit 1
fi

PASS=0; FAIL=0
# as_user <sub> <sql>  -- connects as the authenticator LOGIN role and presents
# claims, which is the only way the vault_auth claims path is reachable.
as_user() {
  local sub="$1"; shift
  psql -U authenticator -d "$DB" -t -A -c "
    set role authenticated;
    select set_config('request.jwt.claims',
      '{\"role\":\"authenticated\",\"sub\":\"$sub\",\"iss\":\"https://example.test/auth/v1\"}', true);
    $*" 2>&1 | tail -1
}
chk() { # chk <name> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "  ok   $1"; PASS=$((PASS+1));
  else echo "  FAIL $1 (expected '$2' got '$3')"; FAIL=$((FAIL+1)); fi
}

echo
echo "== SECTION 0: the harness can see anything at all =="
# Without this, every negative below passes because nothing is visible for
# reasons unrelated to policy -- a broken claims path looks identical to a
# working deny-all.
chk "alice sees her own alpha row (control)" "1" \
  "$(as_user alice-sub "select count(*) from memories where content='zzalpha shared fact';")"

echo
echo "== SECTION A: cross-principal and cross-scope isolation =="
chk "bob cannot read alpha-scoped row" "0" \
  "$(as_user bob-sub "select count(*) from memories where content='zzalpha shared fact';")"
chk "alice cannot read beta-scoped row" "0" \
  "$(as_user alice-sub "select count(*) from memories where content='zzbeta shared fact';")"
chk "bob sees his own beta row" "1" \
  "$(as_user bob-sub "select count(*) from memories where content='zzbeta shared fact';")"
chk "alice private row not visible to bob (even if he held alpha)" "0" \
  "$(as_user bob-sub "select count(*) from memories where content='zzalice private alpha';")"

echo
echo "== SECTION B: null workstream reachable ONLY via the reserved scope =="
chk "alice (holds unclassified) sees null-workstream row" "1" \
  "$(as_user alice-sub "select count(*) from memories where content='zznull workstream fact';")"
chk "bob (no unclassified grant) does not" "0" \
  "$(as_user bob-sub "select count(*) from memories where content='zznull workstream fact';")"

echo
echo "== SECTION C: the projection cannot serve what the source denies =="
chk "bob sees no alpha units via retrieval_units" "0" \
  "$(as_user bob-sub "select count(*) from retrieval_units where rendered_text like 'zzalpha%';")"
chk "alice does see her alpha unit" "1" \
  "$(as_user alice-sub "select count(*) from retrieval_units where rendered_text like 'zzalpha shared%';")"

# The divergence test that matters: poison the projection's OWN columns so they
# disagree with the source, then confirm the policy still follows the source.
# A policy written against the unit's copies would leak here -- that is the
# defect class that already occurred once as ACL drift.
psql -d "$DB" -q -c "update retrieval_units set workstream='beta', visibility='shared'
                     where rendered_text like 'zzalpha shared%';" >/dev/null
chk "poisoned projection row still denied to bob" "0" \
  "$(as_user bob-sub "select count(*) from retrieval_units where rendered_text like 'zzalpha shared%';")"
chk "poisoned projection row still visible to alice" "1" \
  "$(as_user alice-sub "select count(*) from retrieval_units where rendered_text like 'zzalpha shared%';")"
psql -d "$DB" -q -c "select * from refresh_retrieval_units();" >/dev/null

echo
echo "== SECTION D: revocation and deactivation take effect immediately =="
psql -d "$DB" -q -c "update capability_grants set revoked_at=now()
  where principal_id='aaaa0000-0000-0000-0000-00000000000a' and resource_scope='workstream:alpha';" >/dev/null
chk "revoking a grant removes access within one query" "0" \
  "$(as_user alice-sub "select count(*) from memories where content='zzalpha shared fact';")"
psql -d "$DB" -q -c "update capability_grants set revoked_at=null
  where principal_id='aaaa0000-0000-0000-0000-00000000000a' and resource_scope='workstream:alpha';" >/dev/null
chk "restoring the grant restores access (control)" "1" \
  "$(as_user alice-sub "select count(*) from memories where content='zzalpha shared fact';")"

psql -d "$DB" -q -c "update principals set active=false where id='aaaa0000-0000-0000-0000-00000000000a';" >/dev/null
chk "deactivating a principal removes access" "0" \
  "$(as_user alice-sub "select count(*) from memories where content='zzalpha shared fact';")"
psql -d "$DB" -q -c "update principals set active=true where id='aaaa0000-0000-0000-0000-00000000000a';" >/dev/null

echo
echo "== SECTION E: unresolved identity fails closed =="
chk "unknown jwt subject sees nothing" "0" \
  "$(as_user nobody-sub "select count(*) from memories;")"
chk "no claims at all sees nothing" "0" \
  "$(psql -U authenticator -d "$DB" -t -A -c "set role authenticated; select count(*) from memories;" 2>&1 | tail -1)"

echo
echo "== SECTION F: DOCUMENTED LIMIT -- service_role still bypasses everything =="
# Passes while the bypass exists. Reads backwards on purpose: if it ever FAILS,
# the ambient-credential problem was solved and every doc claiming otherwise is
# now wrong.
psql -d "$DB" -q -c "grant select on public.memories to service_role;" >/dev/null
LIMIT_COUNT=$(psql -d "$DB" -t -A -c "set role service_role; select count(*) from memories;" 2>&1 | tail -1)
if [ "$LIMIT_COUNT" -ge 1 ] 2>/dev/null; then
  echo "  ok   limit_service_role_still_bypasses_rls (saw $LIMIT_COUNT rows)"; PASS=$((PASS+1))
else
  echo "  FAIL limit_service_role_still_bypasses_rls -- docs now overstate the limit"; FAIL=$((FAIL+1))
fi

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || { echo "RLS TEST SUITE FAILED"; exit 1; }
echo "RLS TEST SUITE PASSED"
