"""Synthetic regression for the optional stale-backlog candidate; no live DB input.

Requires Docker and an already cached PostgreSQL 17+ image. Never pulls an image,
publishes a port, mounts host data or accepts a database connection string.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
IMAGE = os.environ.get("PGTEST_IMAGE", "postgres:17")
NONCE = uuid.uuid4().hex
NAME = "sv-backlog-stale-" + NONCE[:12]
LABEL = "backlog-stale-test-" + NONCE
FUNCTION = "public.retrieval_embedding_backlog(text,text,text,integer)"
checks = []
started = False


def command(args, body=None, expected=0):
    result = subprocess.run(args, input=body, capture_output=True, timeout=60)
    if result.returncode != expected:
        raise RuntimeError(result.stderr.decode(errors="replace")[:3000])
    return result.stdout


def sql(text, rejected=False):
    result = subprocess.run(
        ["docker", "exec", "-i", NAME, "psql", "-h", "/testpg", "-U", "postgres",
         "-d", "postgres", "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1"],
        input=text.encode(), capture_output=True, timeout=30,
    )
    if rejected:
        if result.returncode == 0:
            raise AssertionError("Expected database refusal")
        return result.stderr.decode(errors="replace")
    if result.returncode:
        raise RuntimeError(result.stderr.decode(errors="replace")[:3000])
    return result.stdout.decode().strip()


def check(name, value):
    checks.append({"name": name, "passed": bool(value)})
    if not value:
        raise AssertionError(name)


def rows():
    return json.loads(sql("select coalesce(jsonb_object_agg(unit_id::text,reason),'{}') "
                          "from public.retrieval_embedding_backlog();"))


def metadata():
    return json.loads(sql("""select jsonb_build_object(
      'owner',proowner,'acl',proacl::text,'definer',prosecdef,
      'volatility',provolatile,'config',proconfig,
      'args',pg_get_function_arguments(oid),'result',pg_get_function_result(oid),
      'anon',has_function_privilege('anon',oid,'execute'),
      'authenticated',has_function_privilege('authenticated',oid,'execute'),
      'service',has_function_privilege('service_role',oid,'execute'))
      from pg_proc where oid='public.retrieval_embedding_backlog(text,text,text,integer)'::regprocedure;"""))


def identifier(n):
    return f"00000000-0000-4000-8000-{n:012d}"


def main():
    global started
    baseline = (ROOT / "sql/29_retrieval_embedding_backlog.sql").read_text()
    candidate = (ROOT / "pending/retrieval_embedding_backlog_stale.sql").read_text()
    report = {"status": "FAIL", "scope": "synthetic isolated PostgreSQL only",
              "network": "none", "ports": [], "hostMounts": [],
              "liveConnections": 0, "inferenceCalls": 0}
    try:
        command(["docker", "image", "inspect", IMAGE])
        command(["docker", "run", "--detach", "--rm", "--pull=never", "--name", NAME,
                 "--label", "org.sovereign-vault.qualifier=" + LABEL, "--network", "none",
                 "--read-only", "--user", "postgres", "--cap-drop", "ALL", "--security-opt",
                 "no-new-privileges", "--memory", "512m", "--pids-limit", "128", "--tmpfs",
                 "/testpg:rw,noexec,nosuid,nodev,mode=1777", "--entrypoint", "/bin/sh", IMAGE,
                 "-c", "initdb -D /testpg/data -A trust -U postgres --no-locale >/testpg/init.log "
                 "&& exec postgres -D /testpg/data -c listen_addresses='' "
                 "-c unix_socket_directories='/testpg'"])
        started = True
        deadline = time.monotonic() + 20
        while True:
            ready = subprocess.run(["docker", "exec", NAME, "pg_isready", "-h", "/testpg",
                                    "-U", "postgres"], capture_output=True)
            if ready.returncode == 0:
                break
            if time.monotonic() > deadline:
                raise RuntimeError("Disposable database did not become ready")
            time.sleep(0.1)
        report["postgresVersion"] = sql("show server_version;")
        check("candidate refuses missing baseline without creating a function",
              "Unknown embedding backlog baseline" in sql(candidate, rejected=True)
              and sql("select to_regprocedure('" + FUNCTION + "') is null;") == "t")
        sql("""create schema extensions; create extension pgcrypto with schema extensions;
          create role anon nologin; create role authenticated nologin; create role service_role nologin;
          create table public.retrieval_units(id uuid primary key,rendered_text text,
            invalidated_at timestamptz,record_status text,generated_at timestamptz);
          create table public.retrieval_embeddings(id uuid primary key,retrieval_unit_id uuid,
            model_provider text,model_name text,model_version text,embedding text,
            rendered_text_hash text,stale_at timestamptz);
          insert into public.retrieval_units
          select ('00000000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,'synthetic text '||i,
            case when i=6 then '2020-01-02'::timestamptz end,
            case when i=7 then 'proposed' else 'current' end,
            '2020-01-01'::timestamptz+i*interval '1 second' from generate_series(1,8)i;
          insert into public.retrieval_embeddings
          select id,id,case when right(id::text,1)='8' then 'other' else 'supabase' end,
            'gte-small','1',case when right(id::text,1)='5' then null else 'synthetic-vector' end,
            case when right(id::text,1)='4' then repeat('0',64)
                 else encode(extensions.digest(rendered_text,'sha256'),'hex') end,
            case when right(id::text,1) in('3','6','7','8') then '2020-01-02'::timestamptz end
          from public.retrieval_units where right(id::text,1)<>'1';""")
        sql(baseline)
        check("original function reproduces the stale-only omission", identifier(3) not in rows())
        before = metadata()
        coverage_before = sql("select md5(pg_get_functiondef('public.retrieval_embedding_coverage(text,text,text)'::regprocedure));")
        data_before = sql("select md5(jsonb_agg(to_jsonb(e) order by id)::text) from retrieval_embeddings e;")
        sql(candidate)
        queued = rows()
        check("stale-only embedding is queued with explicit stale reason", queued.get(identifier(3)) == "stale")
        check("missing, drifted and null-vector behavior is retained",
              queued.get(identifier(1)) == "missing" and queued.get(identifier(4)) == "hash_drift"
              and queued.get(identifier(5)) == "hash_drift")
        check("current exact embedding and noncurrent units stay excluded",
              all(identifier(n) not in queued for n in [2, 6, 7]))
        check("model boundary is retained", queued.get(identifier(8)) == "missing"
              and json.loads(sql("select jsonb_agg(unit_id) from retrieval_embedding_backlog('other','gte-small','1',50) where reason='stale';")) == [identifier(8)])
        check("nonpositive and null work limits remain empty", all(sql(
              f"select count(*) from retrieval_embedding_backlog('supabase','gte-small','1',{limit});") == "0"
              for limit in ["0", "-1", "null"]))
        check("positive work limit preserves generation order", sql(
              "select unit_id from retrieval_embedding_backlog('supabase','gte-small','1',1);") == identifier(1))
        check("owner, ACL, security mode and signature remain exact", metadata() == before)
        check("coverage function remains byte exact", coverage_before == sql(
              "select md5(pg_get_functiondef('public.retrieval_embedding_coverage(text,text,text)'::regprocedure));"))
        check("candidate changes no vector/source data", data_before == sql(
              "select md5(jsonb_agg(to_jsonb(e) order by id)::text) from retrieval_embeddings e;"))
        check("anonymous and authenticated roles remain denied",
              not before["anon"] and not before["authenticated"] and before["service"]
              and "permission denied" in sql("set role anon;select * from retrieval_embedding_backlog();", rejected=True)
              and "permission denied" in sql("set role authenticated;select * from retrieval_embedding_backlog();", rejected=True))
        check("existing service role can read its bounded queue", sql(
              "set role service_role;select count(*) from retrieval_embedding_backlog();") == "5")
        sql(candidate)
        check("reapplying exact candidate is idempotent", rows() == queued and metadata() == before)
        sql("alter function " + FUNCTION + " security invoker;")
        check("unexpected security mode refuses without widening it",
              "Unknown embedding backlog baseline" in sql(candidate, rejected=True)
              and metadata()["definer"] is False)
        sql(baseline)
        changed = baseline.replace("or e.embedding is null", "or e.embedding is null or false", 1)
        sql(changed)
        check("unknown existing implementation is not overwritten",
              "Unknown embedding backlog baseline" in sql(candidate, rejected=True))
        sql(baseline)
        sql(candidate)
        sql("update retrieval_embeddings set stale_at=null where id='" + identifier(3) + "';")
        check("repaired exact embedding leaves backlog and counts as current",
              identifier(3) not in rows() and json.loads(sql(
              "select retrieval_embedding_coverage();"))["embedded_current"] == 2)
        report.update(status="PASS", passed=len(checks), checks=checks,
                      candidateSha256=hashlib.sha256(candidate.encode()).hexdigest())
    except Exception as error:
        report.update(errorType=type(error).__name__, error=str(error), checks=checks)
    finally:
        if started:
            actual = command(["docker", "inspect", NAME, "--format",
                              '{{index .Config.Labels "org.sovereign-vault.qualifier"}}']).decode().strip()
            if actual != LABEL:
                raise RuntimeError("Refusing to remove a container with different ownership")
            command(["docker", "rm", "-f", NAME])
            report["ownedContainerRemoved"] = True
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.output:
        args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
