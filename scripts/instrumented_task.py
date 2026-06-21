#!/usr/bin/env python3
"""Semi-automated metadata-only wrapper for run capture tasks.

Stores only safe active-run metadata in XDG state. Delegates database writes to
scripts/capture_run_metadata.py so privacy boundaries stay centralized.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
CAPTURE = ROOT / "scripts" / "capture_run_metadata.py"
STATE_PATH = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state")) / "coding-agent-benchmarks" / "instrumented_task_active.json"
SAFE_ID = re.compile(r"[^A-Za-z0-9_.:-]+")


def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def slug(value: str | None, default: str = "task") -> str:
    s = SAFE_ID.sub("-", (value or default).strip()).strip("-._:")
    return s[:80] or default


def generated_run_id(args: argparse.Namespace) -> str:
    base = slug(args.task_id or args.task_name or "instrumented-task")
    return f"{base}-{datetime.now().strftime('%Y%m%d-%H%M')}"


def load_state() -> dict[str, Any] | None:
    if not STATE_PATH.exists():
        return None
    try:
        data = json.loads(STATE_PATH.read_text())
    except Exception as exc:  # corrupted state should not expose contents
        raise SystemExit(f"active_state: unreadable path={STATE_PATH} error={type(exc).__name__}")
    if not isinstance(data, dict) or not data.get("run_id"):
        raise SystemExit(f"active_state: invalid path={STATE_PATH}")
    return data


def save_state(data: dict[str, Any]) -> None:
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    safe = {k: v for k, v in data.items() if v is not None}
    tmp = STATE_PATH.with_suffix(".tmp")
    tmp.write_text(json.dumps(safe, indent=2, sort_keys=True) + "\n")
    tmp.replace(STATE_PATH)
    try:
        STATE_PATH.chmod(0o600)
    except OSError:
        pass


def clear_state() -> None:
    STATE_PATH.unlink(missing_ok=True)


def run_capture(command: list[str]) -> None:
    cp = subprocess.run([sys.executable, str(CAPTURE), *command], cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if cp.returncode:
        err = "\n".join(line for line in cp.stderr.splitlines() if line.strip())
        raise SystemExit(f"capture_command: failed cmd={command[0]}" + (f" error={err}" if err else ""))
    for line in cp.stdout.splitlines():
        if line.strip():
            print(line.strip())


def run_id_from_arg_or_state(args: argparse.Namespace) -> str:
    if args.run_id:
        return args.run_id
    state = load_state()
    if not state:
        raise SystemExit("active_state: missing; supply --run-id")
    return str(state["run_id"])


def repo_from_state(default: str | None = None) -> str | None:
    state = load_state()
    if state:
        return state.get("repo_path")
    return default


def cmd_begin(args: argparse.Namespace) -> int:
    existing = load_state()
    if existing and not args.force:
        print(f"active_state: exists run_id={existing['run_id']} path={STATE_PATH}")
        print("Use finish, clear, or begin --force to replace the local active context.")
        return 2
    run_id = args.run_id or generated_run_id(args)
    repo_path = str(Path(args.repo_path).resolve())
    cmd = ["start", "--run-id", run_id, "--repo-path", repo_path]
    for opt in ("task_id", "task_name", "task_type", "project", "agent", "worker_tool", "model", "reasoning_level"):
        val = getattr(args, opt)
        if val:
            cmd += ["--" + opt.replace("_", "-"), val]
    run_capture(cmd)
    save_state({
        "run_id": run_id,
        "repo_path": repo_path,
        "created_at": now_iso(),
        "task_id": args.task_id,
        "task_name": args.task_name,
        "task_type": args.task_type,
        "project": args.project,
        "agent": args.agent,
        "worker_tool": args.worker_tool,
        "model": args.model,
        "reasoning_level": args.reasoning_level,
    })
    print(f"begin: active run_id={run_id} state_path={STATE_PATH}")
    print("Reminder: run finish after validation; keep result summaries metadata-only.")
    return 0


def cmd_finish(args: argparse.Namespace) -> int:
    run_id = run_id_from_arg_or_state(args)
    repo = args.repo_path or repo_from_state()
    cmd = ["finish", "--run-id", run_id, "--status", args.status]
    if args.result_summary:
        cmd += ["--result-summary", args.result_summary]
    if repo:
        cmd += ["--repo-path", repo]
    run_capture(cmd)
    print(f"finish: run_id={run_id} status={args.status} state_cleared={'false' if args.keep_active else 'true'}")
    if not args.keep_active:
        clear_state()
    return 0


def cmd_link(args: argparse.Namespace) -> int:
    run_id = run_id_from_arg_or_state(args)
    cmd = ["link", "--run-id", run_id, "--source-type", args.source_type, "--source-id", args.source_id, "--link-confidence", args.link_confidence]
    if args.notes:
        cmd += ["--notes", args.notes]
    run_capture(cmd)
    print(f"link: run_id={run_id} source_type={args.source_type} status=upserted")
    return 0


def cmd_show(args: argparse.Namespace) -> int:
    run_id = run_id_from_arg_or_state(args)
    run_capture(["show", "--run-id", run_id])
    print(f"show: run_id={run_id}")
    return 0


def cmd_active(args: argparse.Namespace) -> int:
    state = load_state()
    if not state:
        print(f"active_state: missing path={STATE_PATH}")
        return 1
    labels = " ".join(f"{k}={state[k]}" for k in ("task_id", "task_type", "project", "agent") if state.get(k))
    print(f"active_state: exists run_id={state['run_id']} path={STATE_PATH}" + (f" {labels}" if labels else ""))
    return 0


def cmd_clear(args: argparse.Namespace) -> int:
    state = load_state()
    if state:
        print(f"clear: removed active run_id={state['run_id']} path={STATE_PATH}")
    else:
        print(f"clear: no active state path={STATE_PATH}")
    clear_state()
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Metadata-only instrumented task wrapper")
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("begin"); b.add_argument("--run-id"); b.add_argument("--force", action="store_true"); b.add_argument("--repo-path", default=str(ROOT));
    for name in ("task-id", "task-name", "task-type", "project", "agent", "worker-tool", "model", "reasoning-level"):
        b.add_argument(f"--{name}")
    f = sub.add_parser("finish"); f.add_argument("--run-id"); f.add_argument("--status", required=True); f.add_argument("--result-summary"); f.add_argument("--repo-path"); f.add_argument("--keep-active", action="store_true")
    l = sub.add_parser("link"); l.add_argument("--run-id"); l.add_argument("--source-type", required=True); l.add_argument("--source-id", required=True); l.add_argument("--link-confidence", default="manual"); l.add_argument("--notes")
    sh = sub.add_parser("show"); sh.add_argument("--run-id")
    sub.add_parser("active")
    sub.add_parser("clear")
    args = ap.parse_args()
    return {"begin": cmd_begin, "finish": cmd_finish, "link": cmd_link, "show": cmd_show, "active": cmd_active, "clear": cmd_clear}[args.cmd](args)


if __name__ == "__main__":
    raise SystemExit(main())
