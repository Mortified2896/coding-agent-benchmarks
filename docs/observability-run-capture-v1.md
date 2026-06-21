# Observability run capture v1

Date: 2026-06-21

## Purpose

Run capture v1 adds a small metadata-only run spine to the local `observability` warehouse. It links task identity, agent/model metadata, Git before/after state, Langfuse trace/session IDs, Pi analysis IDs, and future GitHub IDs without modifying source systems.

## Schema overview

Migration path:

```text
db/migrations/002_observability_run_capture_v1.sql
```

Tables:

- `observability.runs` — one row per run, keyed by `run_id`, with task, project, agent, worker/model, status, timestamps, result summary, and metadata JSON.
- `observability.run_git_state` — one row per run with branch/commit before and after, dirty booleans, diff stat counts, commit count created, and final clean boolean.
- `observability.run_links` — existing v1 link table extended backward-compatibly with `source_type`, `source_id`, `link_confidence`, `notes`, and `updated_at`.

Indexes cover run lookup by task/project/agent/status/start time, links by source type and ID, and Git commits before/after.

## CLI

Script path:

```text
scripts/capture_run_metadata.py
```

The script reads only:

```text
/etc/hermes/pi_observability_postgres.env
PI_OBSERVABILITY_DATABASE_URL
```

It prints only sanitized database target metadata: database name, host type, user set/missing, and password set/missing.

Examples:

```bash
python3 scripts/capture_run_metadata.py start \
  --run-id test-run-001 \
  --task-id test-task \
  --task-name "Safe test run" \
  --task-type validation \
  --project coding-agent-benchmarks \
  --agent Pi \
  --repo-path /home/hermes/workspace/repos/coding-agent-benchmarks

python3 scripts/capture_run_metadata.py finish \
  --run-id test-run-001 \
  --status success \
  --result-summary "Safe validation completed."

python3 scripts/capture_run_metadata.py link \
  --run-id test-run-001 \
  --source-type langfuse_session \
  --source-id fake-session-id \
  --link-confidence manual

python3 scripts/capture_run_metadata.py show --run-id test-run-001
```

Supported commands: `migrate`, `start`, `finish`, `link`, and `show`.

## Semi-automated instrumented task wrapper

Script path:

```text
scripts/instrumented_task.py
```

Purpose: Phase C is now available as a small script-backed wrapper around `capture_run_metadata.py`. It reduces repeated prompt boilerplate while preserving explicit human/agent control over task start, finish, and safe external links.

Examples:

```bash
python3 scripts/instrumented_task.py begin \
  --task-id safe-task-id \
  --task-name "Short safe task name" \
  --task-type implementation \
  --project coding-agent-benchmarks \
  --agent Pi \
  --repo-path /home/hermes/workspace/repos/coding-agent-benchmarks

python3 scripts/instrumented_task.py active
python3 scripts/instrumented_task.py show

python3 scripts/instrumented_task.py link \
  --source-type langfuse_session \
  --source-id safe-session-id \
  --link-confidence manual

python3 scripts/instrumented_task.py finish \
  --status success \
  --result-summary "Short metadata-only result summary."
```

Commands:

- `begin` creates a generated `run_id` unless `--run-id` is supplied, calls `capture_run_metadata.py start`, and writes an active local context.
- `finish` reads the active context unless `--run-id` is supplied, calls `capture_run_metadata.py finish`, and clears the active context by default. Use `--keep-active` only when the local context should remain.
- `link` reads the active context unless `--run-id` is supplied and delegates to `capture_run_metadata.py link`.
- `show` reads the active context unless `--run-id` is supplied and delegates to the sanitized `show` output.
- `active` reports whether a local active context exists.
- `clear` removes only the local active context; it does not modify warehouse rows.

Active state file:

```text
${XDG_STATE_HOME:-~/.local/state}/coding-agent-benchmarks/instrumented_task_active.json
```

The state file stores only safe metadata such as `run_id`, repo path, creation timestamp, and task labels. It must not contain prompt text, transcript text, raw outputs, secrets, DB URLs, archive data, or other raw content. `begin` refuses to overwrite an existing active context unless `--force` is supplied.

Privacy boundaries are unchanged from v1: the wrapper never stores prompts, completions, transcripts, tool payloads, observation bodies, raw DB rows, raw Langfuse records, full diffs, archive data, secrets, tokens, passwords, or database URLs. It delegates all database writes to `capture_run_metadata.py` and prints only sanitized status lines.

Current limitations: this is not full Control Room, Hermes, or launcher automation. It does not auto-detect safe external IDs, auto-save Pi analysis, or infer task completion. Users must still decide when to begin, link, validate, and finish.

## Automatic Pi task entrypoint

Script path:

```text
scripts/run_instrumented_pi_task.py
```

Repo shim:

```text
bin/pi-task
```

Preferred global shims, installed outside git when desired:

```text
~/.local/bin/pi-task
~/.local/bin/ptask
```

Purpose: Phase C now includes an automatic task-entrypoint helper. It is a thin orchestration layer around `scripts/instrumented_task.py`: `pi-task "..."` starts metadata-only capture immediately, obtains the generated `run_id`, writes an instrumented prompt file outside the repository, and launches Pi with that file as the initial message using Pi's supported `@file` message argument. Future tasks no longer require remembering a separate `begin` step or a long observability prompt.

Preferred daily workflow:

```bash
pi-task "Add basic warehouse views"
# shorter equivalent, if ~/.local/bin/ptask is installed:
ptask "Add basic warehouse views"
```

Finish and inspect the active run:

```bash
pi-task finish --status success --result-summary "Short metadata-only result summary."
pi-task active
pi-task show
pi-task clear
```

Other examples:

```bash
pi-task --prompt-file /path/to/task.md --task-type validation
pi-task start --repo-path /path/to/repo --project my-project "Task body goes here."
pi-task link --source-type langfuse_session --source-id safe-session-id --link-confidence manual
bin/pi-task active
```

Supported commands: default `start` via `pi-task "..."`, explicit `start`, `prepare`, `active`, `show`, `link`, `finish`, `clear`, and `raw`.

How it differs from `instrumented_task.py`:

- `instrumented_task.py begin` starts capture and records active state, but the user/agent must still remember to paste run-capture instructions into the task.
- `run_instrumented_pi_task.py prepare` starts capture automatically and writes a generated instrumented prompt containing the original task, the `run_id`, no-OpenCode instruction, finish/reporting instructions, safe link instructions, and metadata-only privacy boundaries.
- Other commands delegate to `instrumented_task.py` so database writes and active-state semantics remain centralized.

Generated prompt files are written outside the repository by default:

```text
${XDG_STATE_HOME:-~/.local/state}/coding-agent-benchmarks/instrumented_prompts/<run_id>.md
```

By default `start` / `prepare` prints only the `run_id`, generated prompt file path, and launch mode, then execs `pi @<generated-prompt-file>` from the target repo. Pi's help documents `@files` as initial-message inputs, so this is the v1 automatic launch path. If launch should be skipped, use `--no-launch`; the helper then prints one exact manual command:

```bash
pi-task start --no-launch "Task body goes here."
# then run the printed: cd <repo> && pi '@<generated-prompt-file>'
```

The generated prompt contents are not printed by default. The generated state prompt may contain the user task prompt, so callers must not include secrets or database URLs in task text. The helper refuses obvious database URL and secret assignment patterns before writing the prompt file.

Defaults are intentionally simple: repo path is the current Git root when the command is run inside a Git repo, otherwise this repository; project defaults to the repo directory name; agent defaults to `Pi`; task type defaults to `general`.

Active-state behavior matches the semi-automated wrapper: if another run is active, `start` / `prepare` refuses to start a new task unless `--force` is supplied. It never silently overwrites active state. `finish` reads the active run when `--run-id` is not supplied, delegates capture finish, and clears active state through `instrumented_task.py`.

Raw Pi access remains available. The real `pi` binary is not replaced. Use `pi` directly for casual or emergency uninstrumented work, or `pi-task raw ...` as an explicit escape hatch that execs raw Pi without starting capture. Existing `p` / `pi-vm-session` tmux workflows are left unchanged.

Privacy boundaries are unchanged: metadata only. Do not store raw prompts, completions, transcripts, tool payloads, observation bodies, raw DB rows, raw Langfuse records, full diffs, DB URLs, env values, secrets, archive data, or credentials in Postgres or committed files. The prompt file is local XDG state, outside git tracking by default; it is not a warehouse record.

Current limitations: v1 does not auto-detect external IDs, auto-save Pi analysis IDs, infer task completion, alter the existing tmux `p` workflow, modify raw Langfuse archives, modify shell configuration, configure systemd/Hetzner, or clean up generated prompt files automatically.

## Git metadata captured

Git commands are run as `git -C <repo_path> ...`. V1 stores only:

- branch before/after;
- commit SHA before/after;
- dirty boolean before/after;
- file count, insertion count, deletion count from short diff stats;
- number of commits created between before and after;
- final clean/dirty boolean.

It does not store patches, full diffs, file contents, or untracked file contents.

## Privacy boundaries

Run capture v1 does not store raw prompts, completions, transcripts, tool payloads, observation bodies, full diffs, raw Langfuse records, archive data, secrets, tokens, API keys, passwords, or database URLs.

The helper output avoids raw DB rows and raw DB URLs. `show` reports only counts and a small sanitized status/project/agent summary.

## Validation performed

- Applied migration to explicit database target `pi_observability` using an admin role because schema changes required it.
- Verified the three run-capture tables are present.
- Verified eight expected indexes are present.
- Ran a safe test capture with `start`, `finish`, `link`, and `show`.
- Confirmed the test run row, Git state row, and link row existed.
- Confirmed zero forbidden raw-content columns in the run-capture tables for common raw-content names.
- Deleted the safe test run and related rows.
- Confirmed test-created row count returned to zero.

## Known limitations

- V1 is manual/CLI-driven and does not yet auto-wrap benchmark harness execution.
- Link confidence is simple text metadata.
- The `metadata` JSON column is available for safe metadata only; callers must not put raw content in it.
- GitHub enrichment is not implemented.

## Staged adoption plan

Run capture should move from prompt-controlled use to automation in stages. The immediate goal is to prove that metadata-only capture is useful on real tasks before investing in launchers or Control Room integration.

### Phase A: Prompt-driven run capture

Future serious task prompts should explicitly instruct Pi to:

- create or accept a stable `run_id`;
- call `scripts/capture_run_metadata.py start` before making changes;
- complete the task and validation;
- call `scripts/capture_run_metadata.py finish` after validation;
- link known Langfuse trace/session IDs, Pi session IDs, or Pi analysis IDs when available;
- include the `run_id` in the final report.

This keeps task boundaries under human/agent control while using the script as the durable metadata capture mechanism.

### Phase B: Reusable instrumented task prompt

Use the reusable snippet below for future Pi tasks so run capture instructions are not rewritten each time. The snippet can be pasted into serious task prompts until the workflow has enough real examples to justify more automation.

## Reusable instrumented task prompt snippet

```text
Run-capture workflow:
- Generate or use a stable run_id for this task, such as <task-slug>-YYYYMMDD-HHMM.
- Before changing files, run:
  python3 scripts/capture_run_metadata.py start \
    --run-id <run_id> \
    --task-id <safe-task-id> \
    --task-name "<short safe task name>" \
    --task-type <docs|code|validation|maintenance> \
    --project <project-name> \
    --agent Pi \
    --repo-path <absolute repo path>
- Complete the task and validation.
- After validation, run:
  python3 scripts/capture_run_metadata.py finish \
    --run-id <run_id> \
    --status <success|failed|partial> \
    --result-summary "<short metadata-only result summary>"
- If known and safe, link Langfuse trace IDs, Langfuse session IDs, or Pi analysis IDs with the link command.
- Include the run_id in the final report.
- Keep metadata-only boundaries: do not store or print transcripts, prompts, completions, tool payloads, raw DB rows, raw Langfuse records, secrets, archive data, or full diffs.
```

### Phase C: Semi-automated wrapper and automatic task entrypoint

Implemented/available: use `scripts/instrumented_task.py` for `begin`, `finish`, `link`, `show`, `active`, and `clear`. The wrapper reduces repeated prompt boilerplate and makes it harder to forget start/finish capture, while still preserving human/agent judgment about where a task begins, where validation ends, and which external IDs are safe and relevant to link.

Also implemented/available: use `scripts/run_instrumented_pi_task.py prepare` (or local shim `bin/pi-task prepare`) as the preferred v1 task entrypoint. It starts capture automatically, writes the generated instrumented prompt to local XDG state, and keeps finish/reporting instructions in the task flow.

### Phase D: Full automation

Full automation is the long-term endgame, not the immediate next task. Later, Control Room, Hermes, or the Pi launcher can:

- create `run_id` automatically;
- inject `run_id` into prompt/context;
- capture Git before/after state;
- link Langfuse trace/session IDs when known;
- ask `/save-analysis` to store the same `run_id`.

This should wait until several real tasks have been captured and reviewed with the Phase A/B workflow.

### Current recommendation

Use Phase C now for serious tasks: prefer `scripts/run_instrumented_pi_task.py prepare` for automatic run start and generated task instructions; use `scripts/instrumented_task.py` directly when lower-level manual control is needed. Do not build deeper launcher/Control Room automation until several real tasks have been captured, reviewed, and shown to produce useful warehouse joins.

## Next steps

- Add run envelope propagation in benchmark/Pi execution paths.
- Add automatic Langfuse trace/session link capture when safe IDs are available.
- Add read-only GitHub issue/PR enrichment in a later phase.
- Add reporting views once run links are populated consistently.
