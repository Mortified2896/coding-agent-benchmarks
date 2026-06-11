# Coding-Agent Task Capture Wrapper (Stage 1)

## Purpose

The Stage 1 capture wrapper records enough local context to reconstruct
normal OpenCode execution as future benchmark cases.

It captures the Git starting point before the harness runs, launches the
real installed OpenCode CLI, and then captures the final status and diff
after the harness exits.

The wrapper does not capture or replay Hermes session state, OpenCode
session transcripts, profile data, configs, or auth files. It captures
Git state and metadata for the target repository only.

## Tracked command

The Stage 1 wrapper is:

```text
./opencodebench-opencode
```

Use it for any tracked OpenCode work. Raw `opencode` invocations remain
untracked and should only be used for ad-hoc non-tracked work.

The wrapper passes its arguments through to the real OpenCode binary
unchanged, with two narrow exceptions:

1. `--dir <path>` is resolved to an absolute path before being passed
   through, so OpenCode's own runtime `chdir` (which is relative to the
   resolved repo root, not the caller's original `PWD`) lands in the
   same place the wrapper validated. See "Repo detection" below.
2. For non-attach runs, the wrapper unsets
   `OPENCODE_SERVER_PASSWORD` and `OPENCODE_SERVER_USERNAME` in the
   child environment only. See "Environment caveat" below.

The wrapper preserves OpenCode's exit code.

## Repo detection

The wrapper supports two repo-detection modes and records the chosen one
in `metadata.json` as `repo_detection_method`:

| Mode | When | Behavior |
| --- | --- | --- |
| `cwd_git_root` | No `--dir` flag | The wrapper uses the Git repo of its own current working directory. |
| `opencode_dir_git_root` | `--dir <path>` or `--dir=<path>` | The wrapper resolves that path, treats it as the repo-detection base, and walks up to its Git root. |

Rules:

- `--dir` is the preferred form for Hermes-driven calls and any
  cross-repo invocation. It removes the ambiguity of "which repo did
  the wrapper actually record?".
- Launching from outside any Git repository is allowed, as long as
  `--dir` points to an existing Git repository.
- If no `--dir` is present and the wrapper's current working directory
  is not inside a Git repository, the wrapper fails with a clear
  error before launching OpenCode.
- If `--dir` points at a path that does not exist or is not inside a
  Git repository, the wrapper fails with a clear error before
  launching OpenCode.
- The wrapper never runs `git init` and never selects a configured
  project on the user's behalf. It only tracks an already-existing
  Git repository.

When multiple `--dir` flags are present, the wrapper uses the last
value (matches typical CLI semantics).

## Environment caveat

A known issue on hosts where the Hermes shell inherits OpenCode server
environment variables: plain `opencode run ...` can fail with
`Error: Session not found` when both of the following are set:

- `OPENCODE_SERVER_PASSWORD`
- `OPENCODE_SERVER_USERNAME`

The wrapper handles this without exposing the values:

- For local non-attach runs (`opencode run ...`, `opencode [project]`,
  etc.) the wrapper unsets both variables in the child environment
  only. The parent shell is unaffected.
- For `opencode attach <url> ...` runs the wrapper preserves both
  variables so the user can still authenticate to a running OpenCode
  server.
- The wrapper never echoes or writes the values anywhere. Captured
  logs contain only the values that OpenCode and the harness
  themselves surface.

Raw `opencode` invocations (not run through the wrapper) still need
the workaround:

```sh
env -u OPENCODE_SERVER_PASSWORD -u OPENCODE_SERVER_USERNAME \
  opencode run -m opencode/mimo-v2.5-free 'Reply exactly OK and do not edit files.'
```

## Captured files

Task logs are written by default to:

```text
<OpenCodeBench root>/.local/coding-agent-task-logs/YYYY/MM/<task_id>/
```

If the scripts are run from an installed or copied location where no
OpenCodeBench checkout can be detected, logs fall back to:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/opencodebench/coding-agent-task-logs/YYYY/MM/<task_id>/
```

If `OPENCODEBENCH_LOG_ROOT` is set and points inside a Git repository,
the log path must be gitignored; the wrapper refuses unsafe
non-gitignored Git log roots because logs may contain prompts, diffs,
metadata, local paths, and filenames.

Start capture writes:

- `metadata.json`
- `task.md`
- `git-head-before.txt`
- `git-branch-before.txt`
- `git-status-before.txt`
- `git-diff-before.patch`
- `git-diff-stat-before.txt`
- `git-diff-numstat-before.txt`

Finish capture writes:

- `git-status-after.txt`
- `git-diff-stat.txt`
- `git-diff-numstat.txt`
- `git-diff.patch`
- `summary.md`

## Metadata schema

`metadata.json` includes the task ID, timestamps, launcher, harness
metadata, resolved agent executable path fields, model, reasoning
level, repo path, working directory, starting Git SHA, branch,
starting status, dirty-state artifact paths, finish time, final status,
final diff summary, and artifact paths.

The full set of fields written by the Stage 1 wrapper:

| Field | Source | Notes |
| --- | --- | --- |
| `task_id` | derived | `YYYY-MM-DDTHH-MM-SSZ-opencode-<repo-basename>`. |
| `timestamp` / `timestamp_start` / `session_start_time` | wrapper | UTC. |
| `harness` | `HARNESS` or wrapper default | `opencode` for the Stage 1 wrapper. |
| `harness_mode` | derived | `direct` (user) or `delegated` (Hermes). |
| `task_source` | derived | `user` or `hermes_orchestrator`. |
| `agent_command_label` | wrapper | `opencodebench-opencode`. |
| `launcher_used` | wrapper | `OpenCodeBench`. |
| `opencode_executable_path` | wrapper | Resolved absolute path to the real `opencode` binary. |
| `tracking_harness` | wrapper | `opencodebench`. |
| `execution_agent` | wrapper | `opencode`. |
| `upstream_orchestrator` | env / default | `none`, `hermes`, or `unknown`. |
| `orchestration_mode` | derived | `none`, `delegated_worker`, or `unknown`. |
| `repo_detection_method` | derived | `cwd_git_root` or `opencode_dir_git_root`. |
| `working_directory` | derived | The resolved directory used for repo detection. |
| `downstream_agent` | env / default | `opencode`. |
| `downstream_agent_mode` | env / default | Empty for Stage 1. |
| `model_id` | env (`MODEL` or `OPENCODE_MODEL`) | Recorded in `metadata.json`; the wrapper does not invoke the model itself. |
| `repo_path` / `git_root` | wrapper | The tracked repo's Git root. |
| `cwd` | wrapper | The wrapper's own current working directory. |
| `git_head_before` / `git_branch_before` / `git_status` | wrapper | Recorded before launching OpenCode. |
| `git_status_short_before_path` and `git_diff_*_before_path` | wrapper | Relative paths to the start-capture artifacts. |
| `opencodebench.session_id` / `opencodebench.project_id` / `opencodebench.repo_root` / `opencodebench.task_dir` / `opencodebench.git_commit_before` | wrapper | Convenience copies of the tracked fields, also exported as `OTEL_RESOURCE_ATTRIBUTES` and as `OPENCODEBENCH_*` env vars. |
| `opencodebench` (nested object) | wrapper | The same convenience fields, grouped. |
| `agent_exit_code` / `opencode_exit_code` | finish capture | Matches the real OpenCode process exit code. |
| `git_status_short_after_path` and `git_diff_*_path` | wrapper | Relative paths to the finish-capture artifacts. |
| `summary.md` | finish capture | Human-readable run summary. |
| `opencode_session_id` | finish capture | OpenCode internal session ID (`ses_*`), resolved from `~/.local/share/opencode/opencode.db` after OpenCode runs. `null` when skipped/not found/ambiguous/error. |
| `opencode_session_id_status` | finish capture | `resolved`, `not_found`, `ambiguous`, `skipped`, or `error`. |
| `opencode_session_id_source` | finish capture | `sqlite`, `log`, or `unset`. |
| `opencode_session_id_resolved_at` | finish capture | ISO-8601 timestamp of the DB lookup, or `null`. |
| `opencode_session_id_candidates` | finish capture | Number of candidate sessions when status is `ambiguous`; 0 otherwise. |
| `langfuse_trace_id` | finish capture | Always `null` (Langfuse trace ID resolution is deferred; trace join is via `opencodebench.session_id`). |
| `langfuse_trace_id_status` | finish capture | Always `skipped`. |
| `langfuse_trace_id_source` | finish capture | Always `unset`. |
| `langfuse_trace_id_resolved_at` | finish capture | Always `null`. |

Direct user run (default values):

```json
{
  "harness": "opencode",
  "harness_mode": "direct",
  "upstream_orchestrator": "none",
  "task_source": "user",
  "orchestration_mode": "none"
}
```

Hermes-delegated run (when `OPENCODEBENCH_UPSTREAM_ORCHESTRATOR=hermes`):

```json
{
  "harness": "opencode",
  "harness_mode": "delegated",
  "upstream_orchestrator": "hermes",
  "task_source": "hermes_orchestrator",
  "orchestration_mode": "delegated_worker"
}
```

## OpenTelemetry metadata

Before launching OpenCode, the wrapper appends these attributes to
`OTEL_RESOURCE_ATTRIBUTES`:

- `opencodebench.session_id`
- `opencodebench.project_id`
- `opencodebench.repo_root`
- `opencodebench.task_dir`
- `opencodebench.git_commit_before`

The same values are also exported as `OPENCODEBENCH_*` environment
variables for the launched OpenCode process.

## Privacy boundaries

OpenCodeBench does not capture raw Hermes `SOUL.md`, `MEMORY.md`,
`USER.md`, `config.yaml`, `.env`, auth files, session transcripts, or
logs. The wrapper does not capture full private remote URLs.

Captured logs may still contain prompts, diffs, metadata, local paths,
and filenames, so keep them ignored and private.

## Inspect a captured log

```sh
task_dir="<OpenCodeBench root>/.local/coding-agent-task-logs/YYYY/MM/<task_id>"
jq . "$task_dir/metadata.json"
cat "$task_dir/task.md"
cat "$task_dir/git-status-before.txt"
cat "$task_dir/git-diff-stat-before.txt"
cat "$task_dir/git-status-after.txt"
cat "$task_dir/git-diff-stat.txt"
```

Review the full before and after patches with:

```sh
less "$task_dir/git-diff-before.patch"
less "$task_dir/git-diff.patch"
```

## Stage 1 exclusions

The following are intentionally not implemented in Stage 1 and should
not be expected by users of the wrapper:

- A UI, dashboard, comparison view, or export feature.
- A Desktop app launcher or manual repository attach flow.
- An `active-sessions.json` or other live session registry.
- Background watchers or generated-project detection.
- Pi, Hermes-as-orchestrator, Codex, or generic-agent dispatcher wrappers.
- A global `PATH` shim that shadows `opencode`.

Future stages may generalize the same tracking model to those surfaces.
