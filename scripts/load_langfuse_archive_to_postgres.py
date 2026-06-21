#!/usr/bin/env python3
"""Load Langfuse archive metadata into local Postgres observability schema.

Metadata-only: never stores raw records, input/output payloads, prompts, completions,
tool payloads, or observation bodies. Output is counts/status only.
"""
from __future__ import annotations

import argparse, gzip, hashlib, json, os, subprocess, sys, tempfile, uuid
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import urlparse, unquote
from typing import Any

IMPORTER_NAME = "langfuse-archive-metadata-loader"
IMPORTER_VERSION = "0.1.0"
DEFAULT_ARCHIVE_ROOT = Path("/home/hermes/archives/langfuse/raw")
OBJECTS = ("traces", "observations", "scores", "sessions")
ENV_FILES = [Path("/home/hermes/.pi/pi-langfuse.env"), Path("/home/hermes/.config/contained-runs/secrets.env")]
DB_ENV_NAMES = ("OBSERVABILITY_DATABASE_URL", "WAREHOUSE_DATABASE_URL", "PI_OBSERVABILITY_DATABASE_URL", "DATABASE_URL")
RAW_KEYS = {"input", "output", "prompt", "completion", "messages", "body", "payload", "request", "response"}


def eprint(*a: Any) -> None: print(*a, file=sys.stderr)
def q(v: Any) -> str:
    if v is None: return "NULL"
    return "'" + str(v).replace("'", "''") + "'"
def qi(v: Any) -> str: return "NULL" if v is None else str(int(v))
def qf(v: Any) -> str: return "NULL" if v is None else str(float(v))
def qb(v: Any) -> str: return "NULL" if v is None else ("TRUE" if bool(v) else "FALSE")
def qn(v: Any) -> str:
    if v is None or v == "": return "NULL"
    try: return str(float(v))
    except Exception: return "NULL"

def load_env_files() -> None:
    for p in ENV_FILES:
        if not p.exists(): continue
        try:
            for raw in p.read_text(errors="ignore").splitlines():
                s=raw.strip()
                if not s or s.startswith('#') or '=' not in s: continue
                k,v=s.split('=',1); k=k.strip(); v=v.strip().strip('"').strip("'")
                if k in DB_ENV_NAMES and k not in os.environ: os.environ[k]=v
        except OSError: pass

def db_url() -> str | None:
    load_env_files()
    for n in DB_ENV_NAMES:
        if os.environ.get(n): return os.environ[n]
    return None

def db_status(url: str | None) -> str: return "available" if url else "unavailable"

def psql_env(url: str) -> tuple[list[str], dict[str,str]]:
    u=urlparse(url); env=os.environ.copy()
    args=["psql", "-v", "ON_ERROR_STOP=1", "-X"]
    if u.hostname: args += ["-h", u.hostname]
    if u.port: args += ["-p", str(u.port)]
    if u.username: args += ["-U", unquote(u.username)]
    db=(u.path or "/").lstrip('/')
    if db: args += ["-d", unquote(db)]
    if u.password: env["PGPASSWORD"]=unquote(u.password)
    return args, env

def run_psql(url: str, sql: str) -> None:
    args, env = psql_env(url)
    with tempfile.NamedTemporaryFile("w", suffix=".sql", delete=False) as f:
        f.write(sql); name=f.name
    try:
        cp=subprocess.run(args+["-f", name], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if cp.returncode:
            raise RuntimeError("psql failed")
    finally:
        Path(name).unlink(missing_ok=True)

def sha256_file(p: Path) -> str:
    h=hashlib.sha256()
    with p.open('rb') as f:
        for b in iter(lambda:f.read(1024*1024), b''): h.update(b)
    return h.hexdigest()

def stable_uuid(*parts: Any) -> str: return str(uuid.uuid5(uuid.NAMESPACE_URL, "|".join(map(str, parts))))
def hval(v: Any) -> str | None: return hashlib.sha256(str(v).encode()).hexdigest() if v not in (None, "") else None

def day_path(root: Path, d: date) -> Path: return root / f"{d:%Y}" / f"{d:%m}" / f"{d:%d}"
def dates(args: argparse.Namespace) -> list[date]:
    if args.date: return [date.fromisoformat(args.date)]
    if not (args.start_date and args.end_date): raise SystemExit("Provide --date or --start-date and --end-date")
    s,e=date.fromisoformat(args.start_date),date.fromisoformat(args.end_date)
    out=[]
    while s<=e: out.append(s); s+=timedelta(days=1)
    return out

def valid_manifest(part: Path) -> dict[str,Any]:
    m=json.loads((part/"manifest.json").read_text())
    if m.get("schema_version") != 1 or not m.get("completed_successfully"): raise ValueError("invalid manifest")
    return m

def safe_meta(rec: dict[str,Any]) -> dict[str,Any]:
    md=rec.get('metadata') if isinstance(rec.get('metadata'), dict) else {}
    return {k:v for k,v in md.items() if k not in RAW_KEYS and not isinstance(v,(dict,list))}

def clean_hash(rec: dict[str,Any]) -> str:
    safe={k:v for k,v in rec.items() if k not in RAW_KEYS and k != 'metadata'}
    md=safe_meta(rec)
    if md: safe['metadata_safe']=md
    return hashlib.sha256(json.dumps(safe, sort_keys=True, default=str, separators=(',',':')).encode()).hexdigest()

def count_lines(p: Path) -> int:
    n=0
    with gzip.open(p,'rt',encoding='utf-8') as f:
        for _ in f: n+=1
    return n

def source_sql(run_id: str, root: Path, d: date, manifest: dict[str,Any]) -> tuple[str,dict[str,str]]:
    sql=[]; ids={}
    for obj in OBJECTS:
        info=manifest['objects'].get(obj,{})
        if info.get('status') != 'success': continue
        path=day_path(root,d)/info['file']; fid=stable_uuid('source', d, obj, str(path)) ; ids[obj]=fid
        sql.append(f"""INSERT INTO observability.source_archive_files
(id,archive_date,object_type,source_path,file_name,gzip_size_bytes,sha256,manifest_record_count,manifest_page_count,manifest_status,exporter_version,export_window_start,export_window_end,last_import_run_id)
VALUES ({q(fid)},{q(d)}, {q(obj)}, {q(str(path))}, {q(info['file'])}, {qi(info.get('gzip_size_bytes'))}, {q(info.get('sha256'))}, {qi(info.get('record_count'))}, {qi(info.get('page_count'))}, {q(info.get('status'))}, {q(manifest.get('exporter_version'))}, {q(manifest.get('export_window_start'))}, {q(manifest.get('export_window_end'))}, {q(run_id)})
ON CONFLICT (archive_date, object_type) DO UPDATE SET last_imported_at=now(), last_import_run_id=EXCLUDED.last_import_run_id, sha256=EXCLUDED.sha256, manifest_record_count=EXCLUDED.manifest_record_count;""")
    return "\n".join(sql), ids

def row_sql(obj: str, rec: dict[str,Any], d: date, fid: str, run_id: str) -> str:
    md=safe_meta(rec); ch=clean_hash(rec)
    if obj=='traces':
        return f"""INSERT INTO observability.langfuse_traces_meta(trace_id,archive_date,source_file_id,import_run_id,project_id,environment,timestamp,created_at,updated_at,name,html_path,latency,total_cost,session_id,metadata_session_id,user_id_hash,external_id_hash,model,provider,git_branch,git_commit,git_remote_host,git_remote_path,repo_identity,repo_owner,repo_name,repo_root_name,turn_count,tool_call_count,total_tools,total_tool_errors,tool_success_rate,session_had_errors,completed,source_type,metadata_source,tag_count,score_count,observation_count,content_hash)
VALUES ({q(rec.get('id'))},{q(d)},{q(fid)},{q(run_id)},{q(rec.get('projectId'))},{q(rec.get('environment'))},{q(rec.get('timestamp'))},{q(rec.get('createdAt'))},{q(rec.get('updatedAt'))},{q(rec.get('name'))},{q(rec.get('htmlPath'))},{qf(rec.get('latency'))},{qn(rec.get('totalCost'))},{q(rec.get('sessionId'))},{q(md.get('sessionId'))},{q(hval(rec.get('userId')))},{q(hval(rec.get('externalId')))},{q(md.get('model'))},{q(md.get('provider'))},{q(md.get('git_branch'))},{q(md.get('git_commit'))},{q(md.get('git_remote_host'))},{q(md.get('git_remote_path'))},{q(md.get('repo_identity'))},{q(md.get('repo_owner'))},{q(md.get('repo_name'))},{q(md.get('repo_root_name'))},{qi(md.get('turn_count'))},{qi(md.get('tool_call_count'))},{qi(md.get('totalTools'))},{qi(md.get('total_tool_errors'))},{qf(md.get('tool_success_rate'))},{qb(md.get('session_had_errors'))},{qb(md.get('completed'))},{q(md.get('source_type'))},{q(md.get('metadata_source'))},{qi(len(rec.get('tags') or []))},{qi(len(rec.get('scores') or []))},{qi(len(rec.get('observations') or []))},{q(ch)}) ON CONFLICT(trace_id) DO UPDATE SET import_run_id=EXCLUDED.import_run_id, source_file_id=EXCLUDED.source_file_id, content_hash=EXCLUDED.content_hash, imported_at=now();"""
    if obj=='observations':
        return f"""INSERT INTO observability.langfuse_observations_meta(observation_id,trace_id,archive_date,source_file_id,import_run_id,parent_observation_id,project_id,environment,type,name,level,status_message,start_time,end_time,completion_start_time,created_at,updated_at,latency,time_to_first_token,model,model_id,provider,finish_reason,request_id_hash,prompt_tokens,completion_tokens,total_tokens,calculated_input_cost,calculated_output_cost,calculated_total_cost,input_price,output_price,content_hash) VALUES ({q(rec.get('id'))},{q(rec.get('traceId'))},{q(d)},{q(fid)},{q(run_id)},{q(rec.get('parentObservationId'))},{q(rec.get('projectId'))},{q(rec.get('environment'))},{q(rec.get('type'))},{q(rec.get('name'))},{q(rec.get('level'))},{q(rec.get('statusMessage'))},{q(rec.get('startTime'))},{q(rec.get('endTime'))},{q(rec.get('completionStartTime'))},{q(rec.get('createdAt'))},{q(rec.get('updatedAt'))},{qf(rec.get('latency'))},{qf(rec.get('timeToFirstToken'))},{q(rec.get('model'))},{q(rec.get('modelId'))},{q(md.get('provider'))},{q(md.get('finishReason'))},{q(hval(md.get('requestId')))},{qi(rec.get('promptTokens'))},{qi(rec.get('completionTokens'))},{qi(rec.get('totalTokens'))},{qn(rec.get('calculatedInputCost'))},{qn(rec.get('calculatedOutputCost'))},{qn(rec.get('calculatedTotalCost'))},{qn(rec.get('inputPrice'))},{qn(rec.get('outputPrice'))},{q(ch)}) ON CONFLICT(observation_id) DO UPDATE SET import_run_id=EXCLUDED.import_run_id, source_file_id=EXCLUDED.source_file_id, content_hash=EXCLUDED.content_hash, imported_at=now();"""
    if obj=='scores':
        tr=rec.get('trace') if isinstance(rec.get('trace'),dict) else {}
        return f"""INSERT INTO observability.langfuse_scores_meta(score_id,trace_id,observation_id,archive_date,source_file_id,import_run_id,name,value,string_value,data_type,source,timestamp,created_at,updated_at,trace_environment,trace_tag_count,execution_trace_id,content_hash) VALUES ({q(rec.get('id'))},{q(rec.get('traceId'))},{q(rec.get('observationId'))},{q(d)},{q(fid)},{q(run_id)},{q(rec.get('name'))},{qn(rec.get('value'))},{q(rec.get('stringValue'))},{q(rec.get('dataType'))},{q(rec.get('source'))},{q(rec.get('timestamp'))},{q(rec.get('createdAt'))},{q(rec.get('updatedAt'))},{q(tr.get('environment'))},{qi(len(tr.get('tags') or []))},{q(rec.get('executionTraceId'))},{q(ch)}) ON CONFLICT(score_id) DO UPDATE SET import_run_id=EXCLUDED.import_run_id, source_file_id=EXCLUDED.source_file_id, content_hash=EXCLUDED.content_hash, imported_at=now();"""
    return f"""INSERT INTO observability.langfuse_sessions_meta(session_id,archive_date,source_file_id,import_run_id,project_id,environment,created_at,content_hash) VALUES ({q(rec.get('id'))},{q(d)},{q(fid)},{q(run_id)},{q(rec.get('projectId'))},{q(rec.get('environment'))},{q(rec.get('createdAt'))},{q(ch)}) ON CONFLICT(session_id) DO UPDATE SET import_run_id=EXCLUDED.import_run_id, source_file_id=EXCLUDED.source_file_id, content_hash=EXCLUDED.content_hash, imported_at=now();"""

def build_load_sql(root: Path, ds: list[date], force: bool) -> tuple[str, dict[str,int], str]:
    run_id=str(uuid.uuid4()); counts={o:0 for o in OBJECTS}; files=0; sql=["BEGIN;"]
    sql.append(f"INSERT INTO observability.import_runs(id,importer_name,importer_version,source_type,archive_root,status,force,date_start,date_end) VALUES ({q(run_id)},{q(IMPORTER_NAME)},{q(IMPORTER_VERSION)},'langfuse-archive',{q(str(root))},'running',{qb(force)},{q(min(ds))},{q(max(ds))});")
    for d in ds:
        part=day_path(root,d); m=valid_manifest(part); ssql, ids=source_sql(run_id,root,d,m); sql.append(ssql); files += len(ids)
        for obj,fid in ids.items():
            info=m['objects'][obj]; p=part/info['file']
            if sha256_file(p) != info.get('sha256'): raise ValueError(f"sha mismatch {d} {obj}")
            if count_lines(p) != int(info.get('record_count',0)): raise ValueError(f"count mismatch {d} {obj}")
            c=0
            with gzip.open(p,'rt',encoding='utf-8') as fh:
                for line in fh:
                    rec=json.loads(line); sql.append(row_sql(obj, rec, d, fid, run_id)); c += 1
            counts[obj]+=c
            sql.append(f"INSERT INTO observability.source_file_imports(import_run_id,source_file_id,object_type,imported_count) VALUES ({q(run_id)},{q(fid)},{q(obj)},{c}) ON CONFLICT(import_run_id,source_file_id) DO NOTHING;")
    sql.append(f"UPDATE observability.import_runs SET status='success', finished_at=now(), traces_count={counts['traces']}, observations_count={counts['observations']}, scores_count={counts['scores']}, sessions_count={counts['sessions']}, files_count={files} WHERE id={q(run_id)};")
    sql.append("COMMIT;")
    return "\n".join(sql), counts, run_id

def main() -> int:
    ap=argparse.ArgumentParser(); ap.add_argument('--date'); ap.add_argument('--start-date'); ap.add_argument('--end-date'); ap.add_argument('--dry-run', action='store_true'); ap.add_argument('--force', action='store_true'); ap.add_argument('--archive-root', default=str(DEFAULT_ARCHIVE_ROOT)); ap.add_argument('--migrate', action='store_true')
    args=ap.parse_args(); root=Path(args.archive_root); ds=dates(args); url=db_url()
    print(f"database: {db_status(url)}")
    print(f"archive_root: {'available' if root.exists() else 'unavailable'}")
    # validate manifests/files and print counts only
    totals={o:0 for o in OBJECTS}
    for d in ds:
        m=valid_manifest(day_path(root,d))
        for o in OBJECTS: totals[o]+=int(m['objects'].get(o,{}).get('record_count') or 0)
    print("planned_counts " + " ".join(f"{k}={v}" for k,v in totals.items()))
    if args.dry_run:
        print("dry_run: no database writes")
        return 0
    if not url: raise SystemExit("database unavailable")
    if args.migrate:
        run_psql(url, Path('db/migrations/001_observability_warehouse_v1.sql').read_text())
        print("migration: applied")
    sql, counts, _ = build_load_sql(root, ds, args.force)
    run_psql(url, sql)
    print("loaded_counts " + " ".join(f"{k}={v}" for k,v in counts.items()))
    return 0
if __name__ == '__main__': raise SystemExit(main())
