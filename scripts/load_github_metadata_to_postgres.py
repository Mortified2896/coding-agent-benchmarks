#!/usr/bin/env python3
"""Load safe GitHub metadata into the local observability warehouse."""
from __future__ import annotations

import argparse, hashlib, json, os, subprocess, sys, tempfile
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlparse

ENV_FILE = Path("/etc/hermes/pi_observability_postgres.env")
DB_ENV_NAME = "PI_OBSERVABILITY_DATABASE_URL"
MIGRATION = Path("db/migrations/003_observability_github_metadata_v1.sql")


def q(v: Any) -> str:
    if v is None or v == "": return "NULL"
    return "'" + str(v).replace("'", "''") + "'"
def qi(v: Any) -> str:
    try: return str(int(v)) if v is not None else "NULL"
    except Exception: return "NULL"
def qb(v: Any) -> str: return "NULL" if v is None else ("TRUE" if bool(v) else "FALSE")
def h(v: Any) -> str | None: return hashlib.sha256(str(v).encode()).hexdigest() if v not in (None, "") else None


def load_db_url() -> str | None:
    if ENV_FILE.exists():
        for raw in ENV_FILE.read_text(errors="ignore").splitlines():
            s = raw.strip()
            if not s or s.startswith("#") or "=" not in s: continue
            k, v = s.split("=", 1)
            if k.strip() == DB_ENV_NAME:
                os.environ.setdefault(DB_ENV_NAME, v.strip().strip('"').strip("'"))
    return os.environ.get(DB_ENV_NAME)


def describe_db(url: str | None) -> str:
    if not url: return "database: url=missing"
    u = urlparse(url); db = unquote((u.path or "/").lstrip("/")) or "missing"
    host_type = "local" if (u.hostname in (None, "", "localhost", "127.0.0.1", "::1")) else "remote"
    return f"database: url=set db={db} host_type={host_type} user={'set' if u.username else 'missing'} password={'set' if u.password else 'missing'}"


def psql_args(url: str) -> tuple[list[str], dict[str, str]]:
    u = urlparse(url); env = os.environ.copy(); args = ["psql", "-v", "ON_ERROR_STOP=1", "-X"]
    if u.hostname: args += ["-h", u.hostname]
    if u.port: args += ["-p", str(u.port)]
    if u.username: args += ["-U", unquote(u.username)]
    db = (u.path or "/").lstrip("/")
    if not db: raise RuntimeError("database name missing")
    args += ["-d", unquote(db)]
    if u.password: env["PGPASSWORD"] = unquote(u.password)
    return args, env


def run_psql(url: str, sql: str) -> None:
    args, env = psql_args(url)
    with tempfile.NamedTemporaryFile("w", suffix=".sql", delete=False) as f:
        f.write(sql); name = f.name
    try:
        cp = subprocess.run(args + ["-f", name], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if cp.returncode: raise RuntimeError("psql failed")
    finally:
        Path(name).unlink(missing_ok=True)


def gh_available() -> bool: return subprocess.run(["which", "gh"], stdout=subprocess.DEVNULL).returncode == 0
def auth_available() -> bool: return subprocess.run(["gh", "auth", "status"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def gh_json(args: list[str], paginate: bool = False) -> Any:
    cmd = ["gh", "api", "--method", "GET"] + (["--paginate", "--jq", ".[] | @json"] if paginate else []) + args
    cp = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if cp.returncode: raise RuntimeError("gh api failed")
    if paginate:
        return [json.loads(line) for line in cp.stdout.splitlines() if line.strip()]
    return json.loads(cp.stdout or "null")


def current_repo() -> str:
    cp = subprocess.run(["gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"], text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    if cp.returncode or not cp.stdout.strip(): raise RuntimeError("unable to determine current GitHub repo")
    return cp.stdout.strip()


def subject(msg: str | None) -> str | None: return msg.splitlines()[0][:500] if msg else None

def labels_json(labels: list[dict[str, Any]]) -> str:
    safe = [{"name": x.get("name"), "color": x.get("color")} for x in (labels or [])]
    return q(json.dumps(safe, separators=(",", ":"))) + "::jsonb"


def collect(repo: str, since: str | None) -> tuple[list[str], dict[str, int]]:
    sql = ["BEGIN;"]; counts = {"repositories":1,"commits":0,"issues":0,"pull_requests":0,"checks":0,"run_commit_links":0}
    r = gh_json([f"repos/{repo}"]); owner, name = repo.split("/", 1)
    sql.append(f"""INSERT INTO observability.github_repositories(repo_full_name,owner,name,github_id,default_branch,visibility,is_private,html_url,updated_at)
VALUES({q(repo)},{q(owner)},{q(name)},{qi(r.get('id'))},{q(r.get('default_branch'))},{q(r.get('visibility'))},{qb(r.get('private'))},{q(r.get('html_url'))},{q(r.get('updated_at'))})
ON CONFLICT(repo_full_name) DO UPDATE SET default_branch=EXCLUDED.default_branch, visibility=EXCLUDED.visibility, is_private=EXCLUDED.is_private, html_url=EXCLUDED.html_url, updated_at=EXCLUDED.updated_at, captured_at=now();""")
    params = ["-f", f"since={since}"] if since else []
    for c in gh_json([f"repos/{repo}/commits"] + params, True):
        sha = c.get("sha"); cm = (c.get("commit") or {})
        au, co = cm.get("author") or {}, cm.get("committer") or {}
        sql.append(f"""INSERT INTO observability.github_commits(repo_full_name,commit_sha,short_sha,author_name_hash,author_email_hash,author_date,committer_date,message_subject,html_url)
VALUES({q(repo)},{q(sha)},{q(sha[:12] if sha else None)},{q(h(au.get('name')))},{q(h(au.get('email')))},{q(au.get('date'))},{q(co.get('date'))},{q(subject(cm.get('message')))},{q(c.get('html_url'))})
ON CONFLICT(repo_full_name,commit_sha) DO UPDATE SET message_subject=EXCLUDED.message_subject, html_url=EXCLUDED.html_url, captured_at=now();"""); counts["commits"] += 1
    issue_args = [f"repos/{repo}/issues", "-f", "state=all"] + (["-f", f"since={since}"] if since else [])
    for it in gh_json(issue_args, True):
        if "pull_request" in it: continue
        sql.append(f"""INSERT INTO observability.github_issues(repo_full_name,issue_number,github_id,title,state,labels,created_at,updated_at,closed_at,html_url)
VALUES({q(repo)},{qi(it.get('number'))},{qi(it.get('id'))},{q(it.get('title'))},{q(it.get('state'))},{labels_json(it.get('labels') or [])},{q(it.get('created_at'))},{q(it.get('updated_at'))},{q(it.get('closed_at'))},{q(it.get('html_url'))})
ON CONFLICT(repo_full_name,issue_number) DO UPDATE SET title=EXCLUDED.title,state=EXCLUDED.state,labels=EXCLUDED.labels,updated_at=EXCLUDED.updated_at,closed_at=EXCLUDED.closed_at,captured_at=now();"""); counts["issues"] += 1
    for p in gh_json([f"repos/{repo}/pulls", "-f", "state=all"], True):
        if since and (p.get("updated_at") or "") < since: continue
        d = gh_json([f"repos/{repo}/pulls/{p.get('number')}"])
        sql.append(f"""INSERT INTO observability.github_pull_requests(repo_full_name,pr_number,github_id,title,state,merged,base_branch,head_branch,head_sha,created_at,updated_at,closed_at,merged_at,html_url)
VALUES({q(repo)},{qi(d.get('number'))},{qi(d.get('id'))},{q(d.get('title'))},{q(d.get('state'))},{qb(d.get('merged'))},{q((d.get('base') or {}).get('ref'))},{q((d.get('head') or {}).get('ref'))},{q((d.get('head') or {}).get('sha'))},{q(d.get('created_at'))},{q(d.get('updated_at'))},{q(d.get('closed_at'))},{q(d.get('merged_at'))},{q(d.get('html_url'))})
ON CONFLICT(repo_full_name,pr_number) DO UPDATE SET title=EXCLUDED.title,state=EXCLUDED.state,merged=EXCLUDED.merged,head_sha=EXCLUDED.head_sha,updated_at=EXCLUDED.updated_at,captured_at=now();"""); counts["pull_requests"] += 1
    for c in gh_json([f"repos/{repo}/commits"] + params, True)[:50]:
        sha = c.get("sha")
        if not sha: continue
        try: checks = gh_json([f"repos/{repo}/commits/{sha}/check-runs"])
        except RuntimeError: continue
        for cr in checks.get("check_runs", []):
            sql.append(f"""INSERT INTO observability.github_checks(repo_full_name,commit_sha,check_name,check_run_id,status,conclusion,started_at,completed_at,html_url)
VALUES({q(repo)},{q(sha)},{q(cr.get('name'))},{qi(cr.get('id'))},{q(cr.get('status'))},{q(cr.get('conclusion'))},{q(cr.get('started_at'))},{q(cr.get('completed_at'))},{q(cr.get('html_url'))})
ON CONFLICT(repo_full_name,commit_sha,check_name) DO UPDATE SET status=EXCLUDED.status,conclusion=EXCLUDED.conclusion,completed_at=EXCLUDED.completed_at,captured_at=now();"""); counts["checks"] += 1
    for col in ("commit_after", "commit_before"):
        sql.append(f"""INSERT INTO observability.run_github_commit_links(run_id,repo_full_name,commit_sha,link_source,link_confidence)
SELECT run_id,{q(repo)},{col},'run_git_state.{col}','conservative' FROM observability.run_git_state
WHERE {col} IS NOT NULL AND EXISTS (SELECT 1 FROM observability.github_commits c WHERE c.repo_full_name={q(repo)} AND c.commit_sha={col})
ON CONFLICT DO NOTHING;""")
    sql.append("COMMIT;"); return sql, counts


def main() -> int:
    ap = argparse.ArgumentParser(); ap.add_argument("--repo"); ap.add_argument("--since"); ap.add_argument("--dry-run", action="store_true"); ap.add_argument("--migrate", action="store_true")
    args = ap.parse_args(); url = load_db_url(); print(describe_db(url)); print(f"github_cli: {'available' if gh_available() else 'missing'}")
    if not gh_available(): raise SystemExit("Install/authenticate gh, then rerun.")
    print(f"github_auth: {'available' if auth_available() else 'missing'}")
    if not auth_available(): raise SystemExit("Run: gh auth login")
    repo = args.repo or current_repo(); print(f"repo: {repo}")
    if args.migrate and not args.dry_run:
        if not url: raise SystemExit("database URL missing")
        run_psql(url, MIGRATION.read_text()); print("migration: applied")
    sql, counts = collect(repo, args.since); print("planned_counts " + " ".join(f"{k}={v}" for k,v in counts.items()))
    if args.dry_run: print("dry_run: no database writes"); return 0
    if not url: raise SystemExit("database URL missing")
    run_psql(url, "\n".join(sql)); print("loaded_counts " + " ".join(f"{k}={v}" for k,v in counts.items()))
    return 0
if __name__ == "__main__": raise SystemExit(main())
