#!/usr/bin/env python3
"""Automatic Pi task entrypoint for metadata-only instrumented run capture."""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "scripts" / "instrumented_task.py"
STATE_ROOT = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state")) / "coding-agent-benchmarks"
ACTIVE_STATE = STATE_ROOT / "instrumented_task_active.json"
PROMPT_DIR = STATE_ROOT / "instrumented_prompts"
RUN_ID_RE = re.compile(r"run_id=([^\s]+)")
KNOWN_COMMANDS = {"start", "prepare", "active", "show", "finish", "link", "clear", "raw"}
FORBIDDEN_PROMPT_PATTERNS = [
    re.compile(r"postgres(?:ql)?://", re.IGNORECASE),
    re.compile(r"[A-Za-z_][A-Za-z0-9_]*(?:TOKEN|SECRET|PASSWORD|API_KEY|DATABASE_URL)\s*=", re.IGNORECASE),
]


def load_active() -> dict[str, Any] | None:
    if not ACTIVE_STATE.exists():
        return None
    try:
        data = json.loads(ACTIVE_STATE.read_text())
    except Exception as exc:
        raise SystemExit(f"active_state: unreadable path={ACTIVE_STATE} error={type(exc).__name__}")
    if not isinstance(data, dict) or not data.get("run_id"):
        raise SystemExit(f"active_state: invalid path={ACTIVE_STATE}")
    return data


def run_wrapper(args: list[str], *, capture: bool = False) -> str:
    cp = subprocess.run([sys.executable, str(WRAPPER), *args], cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if cp.returncode:
        detail = "\n".join(line for line in (cp.stderr or cp.stdout).splitlines() if line.strip())
        raise SystemExit(f"instrumented_task: failed cmd={args[0]}" + (f" detail={detail}" if detail else ""))
    if not capture:
        print(cp.stdout, end="")
    return cp.stdout


def git_root(path: Path) -> Path | None:
    cp = subprocess.run(["git", "-C", str(path), "rev-parse", "--show-toplevel"], text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return Path(cp.stdout.strip()).resolve() if cp.returncode == 0 and cp.stdout.strip() else None


def default_repo_path() -> Path:
    return git_root(Path.cwd()) or ROOT


def read_prompt(args: argparse.Namespace) -> str:
    if getattr(args, "prompt_file", None) and getattr(args, "prompt", None):
        raise SystemExit("start: use either positional prompt or --prompt-file, not both")
    if getattr(args, "prompt_file", None):
        prompt = Path(args.prompt_file).expanduser().resolve().read_text()
    elif getattr(args, "prompt", None):
        prompt = args.prompt
    else:
        raise SystemExit("start: missing task prompt positional argument or --prompt-file")
    for pattern in FORBIDDEN_PROMPT_PATTERNS:
        if pattern.search(prompt):
            raise SystemExit("start: prompt appears to contain a secret or database URL; refusing to write generated prompt")
    return prompt


def extract_run_id(output: str) -> str:
    m = RUN_ID_RE.search(output)
    if m:
        return m.group(1)
    state = load_active()
    if state:
        return str(state["run_id"])
    raise SystemExit("start: unable to determine generated run_id")


def write_instrumented_prompt(run_id: str, original_prompt: str) -> Path:
    PROMPT_DIR.mkdir(parents=True, exist_ok=True)
    path = PROMPT_DIR / f"{run_id}.md"
    if path.exists():
        raise SystemExit(f"start: prompt file already exists path={path}")
    content = f"""# Instrumented Pi task

Implementation run_id: `{run_id}`

## Required run-capture workflow

- Use Pi directly for this task. Do not delegate to OpenCode.
- The metadata-only run capture has already been started for run_id `{run_id}`.
- Complete the task and validation normally.
- If known and safe, link Langfuse trace IDs, Langfuse session IDs, Pi session IDs, or Pi analysis IDs with `pi-task link --source-type <safe_source_type> --source-id <safe_id> --link-confidence manual`.
- After validation, finish capture with `pi-task finish --status <success|failed|partial> --result-summary "<short metadata-only result summary>"`.
- Include run_id `{run_id}` in the final report.

## Privacy boundaries

Metadata only. Do not store or print raw prompts, completions, transcripts, tool payloads, observation bodies, raw DB rows, raw Langfuse records, full diffs, DB URLs, env values, secrets, archive data, or credentials. Do not modify raw Langfuse archives. Do not store prompts in Postgres.

## Original task

{original_prompt}
"""
    path.write_text(content)
    path.chmod(0o600)
    return path


def start(args: argparse.Namespace) -> int:
    existing = load_active()
    if existing and not args.force:
        print(f"active_state: exists run_id={existing['run_id']} path={ACTIVE_STATE}")
        print('Finish it with: pi-task finish --status success --result-summary "..."')
        print("Or clear local state only with: pi-task clear")
        return 2
    prompt = read_prompt(args)
    repo = Path(args.repo_path).expanduser().resolve() if args.repo_path else default_repo_path()
    project = args.project or repo.name
    task_name = args.task_name or (prompt.splitlines()[0][:80] if prompt.splitlines() else "Pi task")
    begin = ["begin", "--task-name", task_name, "--task-type", args.task_type, "--project", project, "--agent", args.agent, "--repo-path", str(repo)]
    if args.force:
        begin.append("--force")
    for opt in ("task_id", "model", "reasoning_level", "worker_tool"):
        val = getattr(args, opt, None)
        if val:
            begin += ["--" + opt.replace("_", "-"), val]
    run_id = extract_run_id(run_wrapper(begin, capture=True))
    prompt_path = write_instrumented_prompt(run_id, prompt)
    print(f"run_id={run_id}")
    print(f"prompt_file={prompt_path}")
    pi_bin = shutil.which("pi")
    if args.launch and pi_bin:
        print(f"launch=pi mode=interactive file_arg=@{prompt_path}")
        os.chdir(repo)
        os.execvp(pi_bin, [pi_bin, f"@{prompt_path}"])
    print("launch=skipped")
    print(f"next: cd {repo} && pi '@{prompt_path}'")
    return 0


def passthrough(args: argparse.Namespace) -> int:
    cmd = [args.cmd]
    if args.cmd in {"finish", "show"} and getattr(args, "run_id", None):
        cmd += ["--run-id", args.run_id]
    if args.cmd == "finish":
        cmd += ["--status", args.status]
        if args.result_summary:
            cmd += ["--result-summary", args.result_summary]
    elif args.cmd == "link":
        if args.run_id:
            cmd += ["--run-id", args.run_id]
        cmd += ["--source-type", args.source_type, "--source-id", args.source_id, "--link-confidence", args.link_confidence]
        if args.notes:
            cmd += ["--notes", args.notes]
    run_wrapper(cmd)
    return 0


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(description="Start and manage metadata-only instrumented Pi tasks")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("start", "prepare"):
        p = sub.add_parser(name, help="start capture, write prompt, and launch Pi by default")
        p.add_argument("prompt", nargs="?")
        p.add_argument("--prompt-file")
        p.add_argument("--repo-path")
        p.add_argument("--project")
        p.add_argument("--task-name")
        p.add_argument("--task-type", default="general")
        p.add_argument("--agent", default="Pi")
        p.add_argument("--task-id")
        p.add_argument("--model")
        p.add_argument("--reasoning-level")
        p.add_argument("--worker-tool")
        p.add_argument("--force", action="store_true")
        p.add_argument("--launch", dest="launch", action="store_true", default=True)
        p.add_argument("--no-launch", dest="launch", action="store_false")
    sub.add_parser("active")
    s = sub.add_parser("show"); s.add_argument("--run-id")
    f = sub.add_parser("finish"); f.add_argument("--run-id"); f.add_argument("--status", required=True); f.add_argument("--result-summary")
    l = sub.add_parser("link"); l.add_argument("--run-id"); l.add_argument("--source-type", required=True); l.add_argument("--source-id", required=True); l.add_argument("--link-confidence", default="manual"); l.add_argument("--notes")
    sub.add_parser("clear")
    r = sub.add_parser("raw", help="escape hatch: exec raw pi without instrumentation"); r.add_argument("pi_args", nargs=argparse.REMAINDER)
    return ap


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv and argv[0] not in KNOWN_COMMANDS and not argv[0].startswith("-"):
        argv = ["start", *argv]
    if argv and argv[0] == "--raw":
        argv = ["raw", *argv[1:]]
    args = build_parser().parse_args(argv)
    if args.cmd == "raw":
        pi_bin = shutil.which("pi") or "pi"
        os.execvp(pi_bin, [pi_bin, *args.pi_args])
    if args.cmd in {"start", "prepare"}:
        return start(args)
    return passthrough(args)


if __name__ == "__main__":
    raise SystemExit(main())
