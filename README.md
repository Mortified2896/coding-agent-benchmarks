# Coding Agent Benchmarks

Lightweight local capture tooling for OpenCodeBench sessions.

OpenCodeBench launches a selected coding-agent harness from a Git repository root, records pre-run Git metadata, injects `opencodebench.*` OpenTelemetry resource attributes, waits for the harness to exit, and then records the final Git status and diff.

It does not modify, alias, or bundle OpenCode or Hermes.

## Install

```sh
./install-opencodebench-macos.sh
mkdir -p ~/.config/opencodebench
cp config/config.env.example ~/.config/opencodebench/config.env
```

Edit `~/.config/opencodebench/config.env` if you want the macOS launcher to open a default repository. The Desktop app is the recommended launcher for tracked runs because it starts a fresh captured session from the configured repository root.

## Run

From inside any target repository:

```sh
./opencode-bench.sh
```

Or set the repo explicitly:

```sh
OPENCODEBENCH_REPO="/path/to/repo" ./opencode-bench.sh
```

The macOS app launcher reads `~/.config/opencodebench/config.env`, resolves `OPENCODEBENCH_REPO` or `OPENCODEBENCH_DEFAULT_REPO` to its Git root, changes into that root, and runs the installed wrapper from `~/.local/share/opencodebench`.

The supported harnesses are OpenCode direct and Hermes orchestrating OpenCode.

OpenCode direct:

```sh
OPENCODEBENCH_HARNESS=opencode
OPENCODEBENCH_HARNESS_MODE=direct
OPENCODEBENCH_AGENT_COMMAND_LABEL=opencode-direct
OPENCODEBENCH_TASK_SOURCE=desktop_app
```

Hermes orchestrating OpenCode:

```sh
OPENCODEBENCH_HARNESS=hermes
OPENCODEBENCH_HARNESS_MODE=orchestrating-opencode
OPENCODEBENCH_DOWNSTREAM_AGENT=opencode
OPENCODEBENCH_HERMES_MEMORY_MODE=on
OPENCODEBENCH_AGENT_COMMAND_LABEL=hermes-orchestrating-opencode
OPENCODEBENCH_TASK_SOURCE=desktop_app
```

For Hermes orchestration, Hermes is treated as the main harness. OpenCode is recorded as `downstream_agent=opencode`; the wrapper does not directly observe a downstream OpenCode exit code yet. Hermes memory stays on by default. Memory-off benchmarking is intentionally not implemented yet.

## Logs

By default task logs are written under the detected OpenCodeBench project
checkout's local ignored log directory:

```text
<OpenCodeBench root>/.local/coding-agent-task-logs/YYYY/MM/<task_id>/
```

If the scripts are run from an installed or copied location where no
OpenCodeBench checkout can be detected, logs fall back to the user state
directory:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/opencodebench/coding-agent-task-logs/YYYY/MM/<task_id>/
```

Set `OPENCODEBENCH_LOG_ROOT` only if you explicitly want logs somewhere else.
If that path is inside a Git repository, it must be gitignored. OpenCodeBench
refuses unsafe non-ignored Git log roots because logs may contain prompts,
diffs, metadata, local paths, and filenames.

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

`metadata.json` preserves the original OpenCode fields and also records generic harness metadata:

- `harness`
- `harness_mode`
- `task_source`
- `agent_command_label`
- `agent_exit_code`
- `downstream_agent`
- `downstream_agent_mode`

For OpenCode runs, `agent_exit_code` matches the existing `opencode_exit_code` field.

For Hermes runs, `agent_exit_code` matches `hermes_exit_code`. Hermes metadata includes available safe fields such as `hermes_executable_path`, `hermes_version`, `hermes_profile`, `hermes_memory_mode`, `hermes_memory_enabled`, and `hermes_user_profile_enabled`. OpenCodeBench does not capture raw Hermes memory, profile, config, session transcript, auth, env, or log contents.

## Telemetry Metadata

The wrappers append these fields to `OTEL_RESOURCE_ATTRIBUTES`:

- `opencodebench.session_id`
- `opencodebench.project_id`
- `opencodebench.repo_root`
- `opencodebench.task_dir`
- `opencodebench.git_commit_before`

The same values are also exported as `OPENCODEBENCH_*` environment variables for the launched harness process.
