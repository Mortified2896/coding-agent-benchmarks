#!/usr/bin/env python3
"""Capture metadata-only run spine rows for the local observability warehouse.

Never stores prompts, completions, transcripts, tool payloads, raw records, or full diffs.
Uses only /etc/hermes/pi_observability_postgres.env: PI_OBSERVABILITY_DATABASE_URL.
"""
from __future__ import annotations

import argparse, json, os, re, subprocess, sys, tempfile, uuid
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlparse

ENV_FILE = Path("/etc/hermes/pi_observability_postgres.env")
DB_KEY = "PI_OBSERVABILITY_DATABASE_URL"
MIGRATION = Path("db/migrations/002_observability_run_capture_v1.sql")


def q(v: Any) -> str:
    if v is None:
        return "NULL"
    return "'" + str(v).replace("'", "''") + "'"


def qb(v: Any) -> str:
    return "NULL" if v is None else ("TRUE" if bool(v) else "FALSE")


def qi(v: Any) -> str:
    if v is None:
        return "NULL"
    return str(int(v))


def load_db_url() -> str:
    if not ENV_FILE.exists():
        raise SystemExit("database_config: missing")
    for raw in ENV_FILE.read_text(errors="ignore").splitlines():
        s = raw.strip()
        if not s or s.startswith("#") or "=" not in s:
            continue
        k, v = s.split("=", 1)
        if k.strip() == DB_KEY:
            v = v.strip().strip('"').strip("'")
            if v:
                return v
    raise SystemExit("database_config: key_missing")


def db_meta(url: str) -> dict[str, str]:
    u = urlparse(url)
    return {
        "database": unquote((u.path or "/").lstrip("/")) or "missing",
        "host_type": "local" if (u.hostname in (None, "", "localhost", "127.0.0.1", "::1") or (u.hostname or "").startswith("/")) else "remote",
        "user": "set" if u.username else "missing",
        "password": "set" if u.password else "missing",
    }


def print_db_meta(url: str) -> None:
    m = db_meta(url)
    print(f"database_target database={m['database']} host_type={m['host_type']} user={m['user']} password={m['password']}")


def psql_args_env(url: str) -> tuple[list[str], dict[str, str]]:
    u = urlparse(url); env = os.environ.copy(); args = ["psql", "-v", "ON_ERROR_STOP=1", "-X", "-q", "-t", "-A"]
    if u.hostname: args += ["-h", u.hostname]
    if u.port: args += ["-p", str(u.port)]
    if u.username: args += ["-U", unquote(u.username)]
    db = unquote((u.path or "/").lstrip("/"))
    if not db: raise SystemExit("database_target: database_missing")
    args += ["-d", db]
    if u.password: env["PGPASSWORD"] = unquote(u.password)
    return args, env


def run_sql(url: str, sql: str, capture: bool = False) -> str:
    args, env = psql_args_env(url)
    with tempfile.NamedTemporaryFile("w", suffix=".sql", delete=False) as f:
        f.write(sql); name = f.name
    try:
        cp = subprocess.run(args + ["-f", name], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if cp.returncode:
            detail = "\n".join(line for line in cp.stderr.splitlines() if "password" not in line.lower())
            raise RuntimeError("psql failed" + (f": {detail}" if detail else ""))
        return cp.stdout.strip() if capture else ""
    finally:
        Path(name).unlink(missing_ok=True)


def git(repo: str, *args: str, check: bool = True) -> str:
    cp = subprocess.run(["git", "-C", repo, *args], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and cp.returncode:
        raise RuntimeError("git command failed")
    return cp.stdout.strip()


def git_state(repo: str) -> dict[str, Any]:
    branch = git(repo, "branch", "--show-current", check=False) or None
    commit = git(repo, "rev-parse", "HEAD")
    porcelain = git(repo, "status", "--porcelain", check=False)
    return {"repo_path": repo, "branch": branch, "commit": commit, "dirty": bool(porcelain)}


def diff_stats(repo: str, before: str | None, after: str | None) -> dict[str, int | None]:
    if not before or not after:
        return {"files": None, "insertions": None, "deletions": None, "commits": None}
    stat = git(repo, "diff", "--shortstat", before, after, check=False)
    files = insertions = deletions = 0
    m = re.search(r"(\d+) files? changed", stat); files = int(m.group(1)) if m else 0
    m = re.search(r"(\d+) insertions?", stat); insertions = int(m.group(1)) if m else 0
    m = re.search(r"(\d+) deletions?", stat); deletions = int(m.group(1)) if m else 0
    commits_s = git(repo, "rev-list", "--count", f"{before}..{after}", check=False)
    commits = int(commits_s) if commits_s.isdigit() else None
    return {"files": files, "insertions": insertions, "deletions": deletions, "commits": commits}


def cmd_migrate(args: argparse.Namespace, url: str) -> None:
    run_sql(url, MIGRATION.read_text())
    print("migration: applied")


def cmd_start(args: argparse.Namespace, url: str) -> None:
    st = git_state(args.repo_path)
    meta = json.dumps({}, separators=(",", ":"))
    sql = f"""
BEGIN;
INSERT INTO observability.runs(run_id,task_id,task_name,task_type,project,agent,worker_tool,model,reasoning_level,repo_path,started_at,status,metadata)
VALUES ({q(args.run_id)},{q(args.task_id)},{q(args.task_name)},{q(args.task_type)},{q(args.project)},{q(args.agent)},{q(args.worker_tool)},{q(args.model)},{q(args.reasoning_level)},{q(args.repo_path)},now(),{q(args.status or 'running')},{q(meta)}::jsonb)
ON CONFLICT(run_id) DO UPDATE SET task_id=EXCLUDED.task_id, task_name=EXCLUDED.task_name, task_type=EXCLUDED.task_type, project=EXCLUDED.project, agent=EXCLUDED.agent, worker_tool=EXCLUDED.worker_tool, model=EXCLUDED.model, reasoning_level=EXCLUDED.reasoning_level, repo_path=EXCLUDED.repo_path, status=EXCLUDED.status, updated_at=now();
INSERT INTO observability.run_git_state(run_id,repo_path,branch_before,commit_before,dirty_before,captured_at)
VALUES ({q(args.run_id)},{q(args.repo_path)},{q(st['branch'])},{q(st['commit'])},{qb(st['dirty'])},now())
ON CONFLICT(run_id) DO UPDATE SET repo_path=EXCLUDED.repo_path, branch_before=EXCLUDED.branch_before, commit_before=EXCLUDED.commit_before, dirty_before=EXCLUDED.dirty_before, captured_at=now();
COMMIT;
"""
    run_sql(url, sql)
    print(f"start: captured run_id={args.run_id} git_before=set dirty={'true' if st['dirty'] else 'false'}")


def cmd_finish(args: argparse.Namespace, url: str) -> None:
    row = run_sql(url, f"SELECT COALESCE(r.repo_path,''), COALESCE(g.commit_before,'') FROM observability.runs r LEFT JOIN observability.run_git_state g USING(run_id) WHERE r.run_id={q(args.run_id)};", True)
    if not row: raise SystemExit("run: missing")
    repo, before = (row.split("|", 1) + [""])[:2]
    if args.repo_path: repo = args.repo_path
    st = git_state(repo); ds = diff_stats(repo, before or None, st["commit"])
    clean = not st["dirty"]
    sql = f"""
BEGIN;
UPDATE observability.runs SET status={q(args.status)}, result_summary={q(args.result_summary)}, ended_at=now(), updated_at=now() WHERE run_id={q(args.run_id)};
UPDATE observability.run_git_state SET repo_path={q(repo)}, branch_after={q(st['branch'])}, commit_after={q(st['commit'])}, dirty_after={qb(st['dirty'])}, files_changed_count={qi(ds['files'])}, insertions={qi(ds['insertions'])}, deletions={qi(ds['deletions'])}, commit_count_created={qi(ds['commits'])}, final_git_status_clean={qb(clean)}, captured_at=now() WHERE run_id={q(args.run_id)};
COMMIT;
"""
    run_sql(url, sql)
    print(f"finish: captured run_id={args.run_id} status={args.status} git_after=set dirty={'true' if st['dirty'] else 'false'} diff_stats=set")


def cmd_link(args: argparse.Namespace, url: str) -> None:
    lid = str(uuid.uuid5(uuid.NAMESPACE_URL, f"run-link|{args.run_id}|{args.source_type}|{args.source_id}"))
    sql = f"""INSERT INTO observability.run_links(id,run_id,source_type,source_id,link_confidence,notes,link_type,external_system,external_id,confidence,source,created_at,updated_at)
VALUES ({q(lid)},{q(args.run_id)},{q(args.source_type)},{q(args.source_id)},{q(args.link_confidence)},{q(args.notes)},{q(args.source_type)},{q(args.source_type)},{q(args.source_id)},NULL,'capture_run_metadata',now(),now())
ON CONFLICT(id) DO UPDATE SET link_confidence=EXCLUDED.link_confidence, notes=EXCLUDED.notes, updated_at=now();"""
    run_sql(url, sql)
    print(f"link: upserted run_id={args.run_id} source_type={args.source_type}")


def cmd_show(args: argparse.Namespace, url: str) -> None:
    sql = f"""
SELECT 'run_exists=' || count(*) FROM observability.runs WHERE run_id={q(args.run_id)};
SELECT 'git_rows=' || count(*) FROM observability.run_git_state WHERE run_id={q(args.run_id)};
SELECT 'link_rows=' || count(*) FROM observability.run_links WHERE run_id={q(args.run_id)};
SELECT 'run_summary status=' || COALESCE(max(status),'missing') || ' project=' || COALESCE(max(project),'missing') || ' agent=' || COALESCE(max(agent),'missing') FROM observability.runs WHERE run_id={q(args.run_id)};
"""
    out = run_sql(url, sql, True)
    for line in out.splitlines():
        if line.strip(): print(line.strip())


def main() -> int:
    ap = argparse.ArgumentParser(); sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("migrate")
    s = sub.add_parser("start"); s.add_argument("--run-id", required=True); s.add_argument("--task-id"); s.add_argument("--task-name"); s.add_argument("--task-type"); s.add_argument("--project"); s.add_argument("--agent"); s.add_argument("--worker-tool"); s.add_argument("--model"); s.add_argument("--reasoning-level"); s.add_argument("--repo-path", required=True); s.add_argument("--status")
    f = sub.add_parser("finish"); f.add_argument("--run-id", required=True); f.add_argument("--status", required=True); f.add_argument("--result-summary"); f.add_argument("--repo-path")
    l = sub.add_parser("link"); l.add_argument("--run-id", required=True); l.add_argument("--source-type", required=True); l.add_argument("--source-id", required=True); l.add_argument("--link-confidence", default="manual"); l.add_argument("--notes")
    sh = sub.add_parser("show"); sh.add_argument("--run-id", required=True)
    args = ap.parse_args(); url = load_db_url(); print_db_meta(url)
    {"migrate": cmd_migrate, "start": cmd_start, "finish": cmd_finish, "link": cmd_link, "show": cmd_show}[args.cmd](args, url)
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
