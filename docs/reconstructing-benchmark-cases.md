# Reconstructing Coding-Agent Benchmark Cases

## Scope

This copied historical investigation looked at how reliably normal day-to-day OpenCode, Hermes, Pi, and Langfuse usage can be converted into repeatable coding-agent benchmark cases.

This document predates the standalone extraction. Paths shown here are examples from the original investigation, not constraints of the standalone OpenCodeBench wrapper. The reusable workflow is documented in `README.md` and `docs/task-capture-wrapper.md`.

The workflow documentation and future lightweight tooling should live in the target repository being benchmarked. The existing Promptfoo MVP remains at `~/CodingAgentBenchmarks`. `/path/to/example-target-repo` is only an example benchmark target repository.

## What Currently Exists

`~/CodingAgentBenchmarks` contains a working local Promptfoo MVP:

- `promptfooconfig.yaml` defines two OpenCode SDK providers, `variant-a-opencode-sdk-local` and `variant-b-opencode-sdk-local`.
- `scripts/opencode_provider.js` launches OpenCode with `createOpencode({ directory: worktree })` and appends `Work only in this repository path: <worktree>` to the task prompt.
- `benchmark-cases/001-first-benchmark/` contains `task.md`, `verify.sh`, and `notes.md`.
- `results/variant-a/` and `results/variant-b/` contain run artifacts such as `run.log`, `promptfoo-output.json`, `git-status.txt`, `git-diff.patch`, `git-diff-stat.txt`, `git-diff-numstat.txt`, `check-output.txt`, `runtime.txt`, and `timestamp.txt`.
- `worktrees/variant-a/` and `worktrees/variant-b/` isolate benchmark variants.

The current MVP is good enough to run known benchmark cases once the starting repository state has already been chosen. It is not yet enough to create those cases automatically from prior real-world traces.

## Local Trace And Logging Sources

OpenCode global config exists at `~/.config/opencode/opencode.jsonc`:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "experimental": {
    "openTelemetry": true
  },
  "plugin": ["./plugin/load-langfuse-env.mjs", "opencode-plugin-langfuse"]
}
```

OpenCode also has a local env-loader plugin at `~/.config/opencode/plugin/load-langfuse-env.mjs`. It loads only `LANGFUSE_*` variables from `~/.config/opencode/langfuse.env` and logs whether the public and secret keys are configured. It does not add Git metadata.

OpenCode local storage exists at `~/.local/share/opencode/`:

- `opencode.db`
- `log/*.log`
- `storage/session_diff/*.json`
- `tool-output/*`

OpenCode session responses in Promptfoo output include useful fields:

- `info.path.cwd`
- `info.path.root`
- `info.modelID`
- `info.providerID`
- `info.agent`
- `info.mode`
- `info.time.created`
- `info.time.completed`
- `info.tokens`
- `info.sessionID`
- `parts[].snapshot`

OpenCode session diffs in `~/.local/share/opencode/storage/session_diff/` can contain file-level patch data, additions, deletions, and status. For example, the benchmark session diff for `ses_15cca013effessigY2c8rUnpwx` records a `README.md` patch with additions/deletions/status.

Pi config exists at `~/.pi/agent/settings.json`:

```json
{
  "defaultProvider": "openai-codex",
  "defaultModel": "gpt-5.5",
  "defaultThinkingLevel": "minimal",
  "enableInstallTelemetry": false,
  "packages": [
    {
      "source": "git:github.com/deflating/tau",
      "extensions": []
    },
    "npm:pi-langfuse"
  ]
}
```

Pi session logs exist under `~/.pi/agent/sessions/<cwd-encoded>/...jsonl`. They are very useful for reconstruction. They include:

- session timestamp
- session `cwd`
- `model_change` provider and model
- user prompt text
- assistant/tool messages
- tool calls and tool results
- final answer text
- model usage and response IDs

Pi logs currently do not consistently include the Git pre-task commit SHA or `git status --short` unless the task itself asked the agent to run those commands.

Hermes config exists at `~/.hermes/config.yaml`. Relevant observed fields include `agent.reasoning_effort: medium`, model/provider-related settings, logs under `~/.hermes/logs/`, sessions under `~/.hermes/sessions/`, and SQLite state files. Hermes logs show provider/model startup activity and session activity, but this inspection did not find a consistent built-in record of pre-task Git SHA/status for coding tasks.

Langfuse environment is configured for both OpenCode and Pi/PiWeb:

- OpenCode uses `~/.config/opencode/langfuse.env` loaded by the OpenCode env plugin.
- Pi/PiWeb uses `~/.langfuse-env` and wrapper scripts for PiWeb LaunchAgents.
- Existing Pi env settings include capture controls such as `LANGFUSE_CAPTURE_INPUTS`, `LANGFUSE_CAPTURE_OUTPUTS`, `LANGFUSE_CAPTURE_TOOL_IO`, `LANGFUSE_CAPTURE_SYSTEM_PROMPT`, and `LANGFUSE_CAPTURE_CWD`.

Secrets were not copied into this document.

## What Langfuse/OpenCode Already Captures

For OpenCode SDK benchmark runs, the saved Promptfoo result and local OpenCode data capture much of the execution envelope:

- Prompt text: yes, via Promptfoo input/output and OpenCode session content.
- Working directory: yes, via `info.path.cwd` and `info.path.root`.
- Repo path: indirectly yes for OpenCode if `cwd/root` is the repo or worktree root.
- Model/workflow: yes, via `modelID`, `providerID`, `agent`, and `mode`.
- Timestamps: yes, via OpenCode `time.created`/`time.completed`, Promptfoo run logs, and session logs.
- Final result: partly, via assistant final response and OpenCode session data.
- Diff summary: partly, via OpenCode local `storage/session_diff/*.json` and benchmark result artifacts.

For Pi sessions, local JSONL logs capture:

- Prompt text: yes.
- Working directory: yes, as `cwd` in the session record.
- Selected model: yes, through `model_change` and assistant message fields.
- Harness/tool: inferable as Pi from the log path and schema.
- Timestamps: yes.
- Tool calls/results: yes.
- Final answer: yes.

For Hermes, local logs and state exist, but this investigation did not establish a simple, consistent extraction path equivalent to Pi JSONL for all coding-task metadata. Hermes does expose config and logs, including reasoning effort, but the durable per-task benchmark fields still need an explicit capture standard.

## What Is Missing

The critical missing fields are Git pre-task identity and cleanliness:

- Exact Git commit SHA before task: not consistently captured by Langfuse/OpenCode/Pi/Hermes traces.
- Branch name before task: not consistently captured.
- `git status --short` before task: not consistently captured.
- Whether the repo was dirty before the task: not consistently captured unless the agent happened to inspect status.
- Final test/check command and result: not consistently captured unless the task or runner explicitly records it.
- A stable task ID tying together Langfuse trace, local agent session, repo path, start SHA, and output diff: not consistently present.

OpenCode `parts[].snapshot` is not a substitute for `git rev-parse HEAD`. It appears to identify an OpenCode/session snapshot, not the repository start commit.

## Is Exact Reconstruction Possible Today?

Exact benchmark reconstruction is only sometimes possible today.

It is possible when all of the following are true:

- The local agent session log still exists.
- The prompt text is present and complete.
- The session cwd maps cleanly to a Git repository.
- The repository history still contains the relevant commit.
- The repo was clean or its dirty state can be recovered from diffs/logs.
- The task timestamp can be matched to a unique Git commit with high confidence.

It is not reliably possible from Langfuse alone today because the traces do not consistently include the exact pre-task Git commit SHA, branch name, and dirty working tree status.

Answering the core questions directly:

- Does each trace include the exact Git commit SHA? No, not reliably.
- Does each trace include the repo path? Sometimes. OpenCode/Pi capture cwd/root locally; Langfuse may capture cwd depending on env/plugin settings, but this is not enough by itself.
- Does each trace include enough prompt text to become `task.md`? Often yes for Pi and OpenCode when input capture is enabled. This should still be verified per trace.
- Does each trace include enough metadata to know which model/workflow was used? Usually yes for OpenCode and Pi local logs; Hermes needs explicit normalization.
- What is missing? Pre-task `HEAD`, branch, dirty status, final check command/result, and a stable cross-system task ID.

## Best Fallback Method For Old Traces

For old traces without commit SHA, use a confidence-ranked recovery process:

1. Recover prompt/cwd/model/timestamp from local agent logs first.

   Use Pi JSONL logs, OpenCode `opencode.db`/logs/session diffs, Promptfoo outputs, and Hermes logs where available.

2. Map cwd to repo root.

   From the recorded cwd, run `git -C <cwd> rev-parse --show-toplevel` if the path still exists.

3. Estimate start commit by timestamp.

   Use `git -C <repo> log --before='<trace timestamp>' -1 --format='%H %cI %s'`.

4. Check whether the estimated commit is plausible.

   Compare files mentioned in tool calls, session diffs, or final diff against the tree at that commit.

5. Inspect reflog when timestamp alone is ambiguous.

   Use `git -C <repo> reflog --date=iso` to identify branch checkouts, resets, commits, and worktree movements around the trace timestamp.

6. Use local shell history only as supporting evidence.

   Shell history can reveal launch cwd, commands, and rough sequencing, but it is incomplete and not a primary source.

7. Use file modification timestamps as weak evidence.

   File mtimes can support a hypothesis but are not reliable enough to select a benchmark base by themselves.

8. Use final diffs to validate the recovered base.

   Apply or compare the recovered diff against the candidate base. If it does not apply cleanly or references files that differ substantially, mark the benchmark case as approximate.

Recommended confidence labels for reconstructed old cases:

- `exact`: pre-task SHA and dirty state are directly recorded.
- `high`: unique timestamp-derived SHA plus matching diff/tool evidence and clean repo assumption.
- `medium`: timestamp-derived SHA but incomplete dirty-state evidence.
- `low`: prompt exists but start state is ambiguous.
- `unusable`: prompt or repo path is missing.

## Practical Recovery Commands

Find Pi sessions for a repo:

```sh
ls ~/.pi/agent/sessions/--path-to-target-repo--/*.jsonl
ls ~/.pi/agent/sessions/--path-to-example-target-repo--/*.jsonl
```

Extract first session metadata from a Pi JSONL file:

```sh
jq -r 'select(.type == "session") | [.timestamp, .cwd, .id] | @tsv' session.jsonl
jq -r 'select(.type == "model_change") | [.timestamp, .provider, .modelId] | @tsv' session.jsonl
jq -r 'select(.type == "message" and .message.role == "user") | .message.content[]? | select(.type == "text") | .text' session.jsonl
```

Estimate the Git commit before a trace timestamp:

```sh
git -C /path/to/target-repo log --before='2026-06-06T14:19:48Z' -1 --format='%H %cI %s'
```

Inspect reflog around a time window:

```sh
git -C /path/to/target-repo reflog --date=iso
```

Inspect OpenCode session diffs:

```sh
ls ~/.local/share/opencode/storage/session_diff/
jq '.[] | {file, status, additions, deletions}' ~/.local/share/opencode/storage/session_diff/<session-id>.json
```

Inspect current benchmark artifacts:

```sh
ls ~/CodingAgentBenchmarks/results/variant-a
cat ~/CodingAgentBenchmarks/results/variant-a/run.log
cat ~/CodingAgentBenchmarks/results/variant-a/git-diff-stat.txt
```

## Recommended Future Logging Standard

Every future coding task that might become a benchmark should create a small local task record before and after the agent run.

Minimum fields:

- `task_id`
- `timestamp_start`
- `timestamp_end`
- `harness`: `opencode`, `hermes`, `pi`, `piweb`, or `promptfoo-opencode-sdk`
- `repo_path`
- `cwd`
- `git_root`
- `git_head_before`
- `git_branch_before`
- `git_status_short_before`
- `prompt_text`
- `model_provider`
- `model_id`
- `reasoning_level`
- `langfuse_trace_id` if available
- `local_session_id` if available
- `final_response_summary`
- `git_status_short_after`
- `git_diff_stat_after`
- `git_diff_patch_path`
- `check_command`
- `check_exit_code`
- `check_output_path`
- `notes`

Use files, not a database. A good default layout in a target repository is:

```text
<target repo>/docs/coding-agent-benchmarks/
<target repo>/tools/coding-agent-benchmarks/
<target repo>/.local/coding-agent-task-logs/YYYY/MM/<task-id>/
```

The `.local` directory should remain ignored if it stores raw prompts, diffs, logs, or private local paths. Curated docs and script sketches can be committed under `docs/` and `tools/`.

## Integration Options

Wrapper script before launching OpenCode:

- Best reliability for OpenCode CLI usage.
- Captures Git state before the agent starts, without relying on the model to remember.
- Can create a local JSON/Markdown task envelope and then launch OpenCode normally.
- Recommended as the primary minimal implementation.

Shell alias/function:

- Good low-friction interface around wrapper scripts.
- Easy to use for `ocbench "prompt"`, `pibench "prompt"`, or `hermesbench "prompt"`.
- Risk: users can bypass it.
- Recommended as a convenience layer, not the only logging mechanism.

Langfuse metadata enrichment:

- Useful to attach `repo_path`, `git_head_before`, branch, harness, model, and task ID to traces.
- Not sufficient alone because local diff/check artifacts still need files.
- Recommended after wrapper logging exists.

OpenCode custom instruction/profile rule:

- Useful as a reminder to capture status and final checks.
- Not reliable as the primary mechanism because it depends on model behavior.
- Recommended only as a backup reminder.

Hermes orchestration rule:

- Good if Hermes is the launcher/orchestrator for multiple harnesses.
- Can standardize task IDs and logging across agents.
- Slightly heavier than a shell wrapper.
- Recommended later if Hermes becomes the normal entrypoint.

Manual task note template:

- Useful for edge cases and quick repair of old traces.
- Too easy to forget.
- Recommended as fallback only.

## Recommended Minimal Implementation Plan

1. Add a small capture script in the target repository, for example `tools/coding-agent-benchmarks/capture-task-start.sh`.

   It should write `metadata.json`, `task.md`, `git-status-before.txt`, and `git-head-before.txt` into a timestamped local task directory.

2. Add a matching finish script, for example `tools/coding-agent-benchmarks/capture-task-finish.sh`.

   It should write `git-status-after.txt`, `git-diff-stat.txt`, `git-diff.patch`, optional check output, and a short `summary.md`.

3. Add one wrapper per harness only as needed.

   Start with OpenCode because OpenCode is already used by the benchmark MVP. Add Pi/Hermes wrappers later if they remain part of daily coding work.

4. Add optional Langfuse metadata enrichment only after local file logging works.

   The local task log should be the source of truth for reconstructing benchmark cases. Langfuse should link to it via `task_id`, not replace it.

5. Update the benchmark case creation workflow.

   A later script can convert a captured task folder into `benchmark-cases/<case-id>/task.md`, `metadata.json`, `base.patch` or `expected-diff-notes.md`, and `verify.sh`.

## Script Sketches For Next Step

Start-capture sketch:

```sh
#!/bin/zsh
set -euo pipefail

repo="${1:-$PWD}"
prompt_file="${2:-}"
harness="${HARNESS:-opencode}"
model="${MODEL:-unknown}"
reasoning="${REASONING_LEVEL:-}"

git_root=$(git -C "$repo" rev-parse --show-toplevel)
head_sha=$(git -C "$git_root" rev-parse HEAD)
branch=$(git -C "$git_root" branch --show-current)
timestamp=$(date -u +%Y-%m-%dT%H-%M-%SZ)
task_id="${timestamp}-${harness}-$(basename "$git_root")"
out="/path/to/target-repo/.local/coding-agent-task-logs/${task_id}"

mkdir -p "$out"

if [ -n "$prompt_file" ]; then
  cp "$prompt_file" "$out/task.md"
else
  ${EDITOR:-vi} "$out/task.md"
fi

git -C "$git_root" status --short > "$out/git-status-before.txt"

jq -n \
  --arg task_id "$task_id" \
  --arg timestamp_start "$timestamp" \
  --arg harness "$harness" \
  --arg repo_path "$git_root" \
  --arg cwd "$PWD" \
  --arg git_head_before "$head_sha" \
  --arg git_branch_before "$branch" \
  --arg model_id "$model" \
  --arg reasoning_level "$reasoning" \
  '{task_id:$task_id,timestamp_start:$timestamp_start,harness:$harness,repo_path:$repo_path,cwd:$cwd,git_head_before:$git_head_before,git_branch_before:$git_branch_before,model_id:$model_id,reasoning_level:$reasoning_level}' \
  > "$out/metadata.json"

printf '%s\n' "$out"
```

Finish-capture sketch:

```sh
#!/bin/zsh
set -euo pipefail

task_dir="$1"
repo=$(jq -r '.repo_path' "$task_dir/metadata.json")
check_command="${2:-}"

git -C "$repo" status --short > "$task_dir/git-status-after.txt"
git -C "$repo" diff --stat > "$task_dir/git-diff-stat.txt"
git -C "$repo" diff > "$task_dir/git-diff.patch"

exit_code=""
if [ -n "$check_command" ]; then
  set +e
  zsh -lc "cd ${(q)repo} && $check_command" > "$task_dir/check-output.txt" 2>&1
  exit_code=$?
  set -e
fi

tmp=$(mktemp)
jq \
  --arg timestamp_end "$(date -u +%Y-%m-%dT%H-%M-%SZ)" \
  --arg check_command "$check_command" \
  --arg check_exit_code "$exit_code" \
  '. + {timestamp_end:$timestamp_end, check_command:$check_command, check_exit_code:$check_exit_code}' \
  "$task_dir/metadata.json" > "$tmp"
mv "$tmp" "$task_dir/metadata.json"
```

OpenCode wrapper sketch:

```sh
#!/bin/zsh
set -euo pipefail

prompt_file="$1"
task_dir=$(HARNESS=opencode MODEL="${OPENCODE_MODEL:-unknown}" \
  /path/to/target-repo/tools/coding-agent-benchmarks/capture-task-start.sh "$PWD" "$prompt_file")

opencode < "$task_dir/task.md"

/path/to/target-repo/tools/coding-agent-benchmarks/capture-task-finish.sh "$task_dir" "${CHECK_COMMAND:-}"
```

## Recommendation

Do not rely on Langfuse alone for benchmark reconstruction. Keep Langfuse as the searchable trace and conversation observability layer, but make a tiny local file-based task envelope the source of truth for benchmark reconstruction.

The next implementation step should be a lightweight shell wrapper that captures pre-task Git state before launching OpenCode, then captures post-task diff/check artifacts afterward. Once that works, enrich Langfuse traces with the same `task_id`, `repo_path`, and `git_head_before` so cloud traces and local benchmark artifacts can be joined later.
