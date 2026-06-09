# OpenCodeBench

Lightweight local capture tooling for OpenCode execution.

OpenCodeBench launches a selected coding-agent CLI from a Git repository, records
pre-run Git metadata, appends `opencodebench.*` attributes to
`OTEL_RESOURCE_ATTRIBUTES`, waits for the CLI to exit, then records the final
Git status and diff.

It does not modify, alias, or bundle OpenCode or Hermes.

## Stage 1 scope

Stage 1 is a narrow proof slice: **it tracks OpenCode execution only**.

In scope (Stage 1):

- Tracking direct, user-driven `opencode run` invocations.
- Tracking Hermes-delegated `opencode run` invocations (Hermes as the upstream
  orchestrator, OpenCode as the worker).

Out of scope for Stage 1 (intentionally not implemented):

- A UI, dashboard, or comparison view.
- Export features or case-reconstruction tooling.
- A Desktop app launcher or manual repository attach flow.
- An `active-sessions.json` or other live session registry.
- Background watchers or generated-project detection.
- Pi, Hermes-as-orchestrator, Codex, or generic-agent dispatcher wrappers.
- A global `PATH` shim that shadows `opencode`.

Future stages may generalize the same tracking model to those surfaces, but
Stage 1 is intentionally narrow so the capture contract is stable before
broader wrappers are added.

## Tracked command

Use `opencodebench-opencode` for any tracked OpenCode work. Raw `opencode`
invocations remain untracked.

| Call form | Tracked? | Notes |
| --- | --- | --- |
| `opencode ...` | no | Use only for ad-hoc non-tracked use. |
| `opencodebench-opencode ...` | yes | The Stage 1 wrapper. |

Hermes should call `opencodebench-opencode` whenever it wants its OpenCode
worker execution to appear in an OpenCodeBench session log.

## Recommended usage

For a tracked OpenCode run targeted at a specific repository, prefer
`--dir` so the wrapper records the target repo, not the launch directory:

```sh
/Users/Jo/GitHub/coding-agent-benchmarks/opencodebench-opencode \
  run --dir /path/to/target-repo \
  -m opencode/mimo-v2.5-free \
  'Reply exactly OK and do not edit files.'
```

For implementation-style work, use a free implementation-tuned model:

```sh
/Users/Jo/GitHub/coding-agent-benchmarks/opencodebench-opencode \
  run --dir /path/to/target-repo \
  -m opencode/deepseek-v4-flash-free \
  'Implement the change described in the prompt.'
```

You can omit `--dir` and run from inside the target repo; the wrapper will
detect the repo from the current working directory. See "Repo detection" below
for the exact rules.

Simulated Hermes-delegated run (for tests and for documentation examples):

```sh
OPENCODEBENCH_UPSTREAM_ORCHESTRATOR=hermes \
  /Users/Jo/GitHub/coding-agent-benchmarks/opencodebench-opencode \
  run --dir /path/to/target-repo \
  -m opencode/mimo-v2.5-free \
  'Reply exactly OK and do not edit files.'
```

## Repo detection

The wrapper supports two repo-detection modes and records the chosen one in
`metadata.json` as `repo_detection_method`:

| Mode | When | Behavior |
| --- | --- | --- |
| `cwd_git_root` | No `--dir` flag | The wrapper uses the Git repo of its own current working directory. |
| `opencode_dir_git_root` | `--dir <path>` or `--dir=<path>` | The wrapper resolves that path, treats it as the repo-detection base, and walks up to its Git root. |

Rules:

- `--dir` is the preferred form for Hermes-driven calls and any cross-repo
  invocation. It removes the ambiguity of "which repo did the wrapper actually
  record?".
- Launching from outside any Git repository is allowed, as long as `--dir`
  points to an existing Git repository.
- If no `--dir` is present and the wrapper's current working directory is not
  inside a Git repository, the wrapper fails with a clear error before
  launching OpenCode.
- If `--dir` points at a path that does not exist or is not inside a Git
  repository, the wrapper fails with a clear error before launching OpenCode.
- The wrapper never runs `git init` and never selects a configured project on
  the user's behalf. It only tracks an already-existing Git repository.

When multiple `--dir` flags are present, the wrapper uses the last value
(matches typical CLI semantics). The wrapper rewrites a relative `--dir` to
its resolved absolute path before invoking OpenCode, so OpenCode's own
runtime `chdir` lands in the same place the wrapper validated.

## Environment caveat

A known issue on hosts where the Hermes shell inherits OpenCode server
environment variables: plain `opencode run ...` can fail with
`Error: Session not found` when the following are set:

- `OPENCODE_SERVER_PASSWORD`
- `OPENCODE_SERVER_USERNAME`

The wrapper handles this without exposing the values:

- For local non-attach runs (`opencode run ...`, `opencode [project]`, etc.)
  the wrapper unsets both variables in the child environment only. The parent
  shell is unaffected.
- For `opencode attach <url> ...` runs the wrapper preserves both variables
  so the user can still authenticate to a running OpenCode server.
- The wrapper never echoes or writes the values anywhere. Captured logs
  contain only the values that OpenCode and the harness themselves surface.

Raw `opencode` invocations (not run through the wrapper) still need the
workaround:

```sh
env -u OPENCODE_SERVER_PASSWORD -u OPENCODE_SERVER_USERNAME \
  opencode run -m opencode/mimo-v2.5-free 'Reply exactly OK and do not edit files.'
```

## Metadata

The wrapper writes a `metadata.json` per session and appends `opencodebench.*`
attributes to `OTEL_RESOURCE_ATTRIBUTES` for the launched harness process.

Additive fields recorded by the wrapper (Stage 1):

- `tracking_harness` — always `opencodebench` for wrapper-driven runs.
- `execution_agent` — the agent that actually ran, e.g. `opencode`.
- `upstream_orchestrator` — who invoked the wrapper, e.g. `none` or `hermes`.
- `orchestration_mode` — derived from the upstream orchestrator.
- `repo_detection_method` — `cwd_git_root` or `opencode_dir_git_root`.
- `working_directory` — the resolved directory used for repo detection.
- `git_root` — the Git root of the tracked repo.

Direct user run (default values):

| Field | Value |
| --- | --- |
| `harness` | `opencode` |
| `harness_mode` | `direct` |
| `upstream_orchestrator` | `none` |
| `task_source` | `user` |
| `orchestration_mode` | `none` |

Hermes-delegated run (when `OPENCODEBENCH_UPSTREAM_ORCHESTRATOR=hermes`):

| Field | Value |
| --- | --- |
| `harness` | `opencode` |
| `harness_mode` | `delegated` |
| `upstream_orchestrator` | `hermes` |
| `task_source` | `hermes_orchestrator` |
| `orchestration_mode` | `delegated_worker` |

See `docs/task-capture-wrapper.md` for the full metadata schema, the list of
captured files per session, and the OpenTelemetry attribute names.

## Privacy boundaries

Stage 1 captures Git state, diffs, and explicit metadata for the target
repository only. The wrapper does **not** capture:

- Raw Hermes memory, transcripts, profile data, configs, or auth files.
- `SOUL.md`, `MEMORY.md`, `USER.md`, `~/.hermes/config.yaml`, or `~/.hermes/.env`.
- OpenCode session transcripts or auth files.
- Full private remote URLs (only the local path is captured).

Captured log files may still contain prompts, diffs, metadata, local paths,
and filenames, so keep them ignored and private. The wrapper refuses to write
logs into a non-gitignored path inside a Git repository.

## Logs

By default, task logs are written under the detected OpenCodeBench project
checkout's local ignored log directory:

```text
<OpenCodeBench root>/.local/coding-agent-task-logs/YYYY/MM/<task_id>/
```

If the scripts are run from an installed or copied location where no
OpenCodeBench checkout can be detected, logs fall back to:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/opencodebench/coding-agent-task-logs/YYYY/MM/<task_id>/
```

Set `OPENCODEBENCH_LOG_ROOT` only if you explicitly want logs somewhere
else. If that path is inside a Git repository, it must be gitignored.

## Model routing

`docs/current-openbench-model-routing.md` lists the free OpenCode-accessible
models used for the current implementation work and the routing policy
applied to them. It is a working orientation sheet, not a benchmark
conclusion, and should be revised after real traces are collected.

## Install

Stage 1 does not require an install step. The wrapper, capture scripts, and
documentation are used directly from the project checkout. The `Desktop app`
and macOS launcher described in earlier revisions of this README are
intentionally not part of Stage 1.
