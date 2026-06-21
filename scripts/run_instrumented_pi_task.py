#!/usr/bin/env python3
"""Automatic Pi task entrypoint for metadata-only instrumented run capture.

This is a thin orchestration layer around scripts/instrumented_task.py. It starts
capture during task preparation, writes an instrumented prompt to local XDG state,
and delegates active/link/finish/clear operations to the existing wrapper.
"""
from __future__ import annotations

import argparse
import json
import os
import re
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
        err = "\n".join(line for line in cp.stderr.splitlines() if line.strip())
        out = "\n".join(line for line in cp.stdout.splitlines() if line.strip())
        detail = err or out
        raise SystemExit(f"instrumented_task: failed cmd={args[0]}" + (f" detail={detail}" if detail else ""))
    if not capture:
        print(cp.stdout, end="")
    return cp.stdout


def read_prompt(args: argparse.Namespace) -> str:
    if args.prompt_file and args.prompt:
        raise SystemExit("prepare: use either positional prompt or --prompt-file, not both")
    if args.prompt_file:
        prompt_path = Path(args.prompt_file).expanduser().resolve()
        prompt = prompt_path.read_text()
    elif args.prompt:
        prompt = args.prompt
    else:
        raise SystemExit("prepare: missing task prompt positional argument or --prompt-file")
    for pattern in FORBIDDEN_PROMPT_PATTERNS:
        if pattern.search(prompt):
            raise SystemExit("prepare: prompt appears to contain a secret or database URL; refusing to write generated prompt")
    return prompt


def extract_run_id(output: str) -> str:
    for line in output.splitlines():
        if line.startswith("begin: active run_id="):
            m = RUN_ID_RE.search(line)
            if m:
                return m.group(1)
    m = RUN_ID_RE.search(output)
    if m:
        return m.group(1)
    state = load_active()
    if state:
        return str(state["run_id"])
    raise SystemExit("prepare: unable to determine generated run_id")


def write_instrumented_prompt(run_id: str, original_prompt: str) -> Path:
    PROMPT_DIR.mkdir(parents=True, exist_ok=True)
    path = PROMPT_DIR / f"{run_id}.md"
    if path.exists():
        raise SystemExit(f"prepare: prompt file already exists path={path}")
    content = f"""# Instrumented Pi task

Implementation run_id: `{run_id}`

## Required run-capture workflow

- Use Pi directly for this task. Do not delegate to OpenCode.
- The metadata-only run capture has already been started for run_id `{run_id}`.
- Complete the task and validation normally.
- If known and safe, link Langfuse trace IDs, Langfuse session IDs, Pi session IDs, or Pi analysis IDs with:

```bash
python3 scripts/instrumented_task.py link --source-type <safe_source_type> --source-id <safe_id> --link-confidence manual
```

- After validation, finish capture with:

```bash
python3 scripts/instrumented_task.py finish --status <success|failed|partial> --result-summary "<short metadata-only result summary>"
```

- Include run_id `{run_id}` in the final report.

## Privacy boundaries

Metadata only. Do not store or print raw prompts, completions, transcripts, tool payloads, observation bodies, raw DB rows, raw Langfuse records, full diffs, DB URLs, env values, secrets, archive data, or credentials. Do not modify raw Langfuse archives. Do not store prompts in Postgres.

## Original task

{original_prompt}
"""
    path.write_text(content)
    try:
        path.chmod(0o600)
    except OSError:
        pass
    return path


def cmd_prepare(args: argparse.Namespace) -> int:
    existing = load_active()
    if existing and not args.force:
        print(f"active_state: exists run_id={existing['run_id']} path={ACTIVE_STATE}")
        print("Use finish, clear, or prepare --force before starting a new instrumented task.")
        return 2
    prompt = read_prompt(args)
    begin = ["begin", "--task-name", args.task_name, "--task-type", args.task_type, "--project", args.project, "--agent", args.agent, "--repo-path", str(Path(args.repo_path).resolve())]
    if args.force:
        begin.append("--force")
    for opt in ("task_id", "model", "reasoning_level", "worker_tool"):
        val = getattr(args, opt)
        if val:
            begin += ["--" + opt.replace("_", "-"), val]
    output = run_wrapper(begin, capture=True)
    run_id = extract_run_id(output)
    prompt_path = write_instrumented_prompt(run_id, prompt)
    print(f"run_id={run_id}")
    print(f"prompt_file={prompt_path}")
    print("next: start Pi with the generated prompt file contents; finish with scripts/instrumented_task.py finish after validation")
    print("launch=skipped reason=no reliable non-interactive Pi prompt-file launch mode implemented in v1")
    return 0


def cmd_passthrough(args: argparse.Namespace) -> int:
    cmd = [args.cmd]
    if args.cmd == "finish":
        if args.run_id:
            cmd += ["--run-id", args.run_id]
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


def main() -> int:
    ap = argparse.ArgumentParser(description="Automatic metadata-only Pi task entrypoint")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("prepare")
    p.add_argument("--task-name", required=True); p.add_argument("--task-type", required=True); p.add_argument("--project", required=True); p.add_argument("--agent", required=True); p.add_argument("--repo-path", required=True)
    p.add_argument("--task-id"); p.add_argument("--model"); p.add_argument("--reasoning-level"); p.add_argument("--worker-tool"); p.add_argument("--prompt-file"); p.add_argument("--force", action="store_true")
    p.add_argument("prompt", nargs="?")

    sub.add_parser("active")
    f = sub.add_parser("finish"); f.add_argument("--run-id"); f.add_argument("--status", required=True); f.add_argument("--result-summary")
    l = sub.add_parser("link"); l.add_argument("--run-id"); l.add_argument("--source-type", required=True); l.add_argument("--source-id", required=True); l.add_argument("--link-confidence", default="manual"); l.add_argument("--notes")
    sub.add_parser("clear")

    args = ap.parse_args()
    if args.cmd == "prepare":
        return cmd_prepare(args)
    return cmd_passthrough(args)


if __name__ == "__main__":
    raise SystemExit(main())
