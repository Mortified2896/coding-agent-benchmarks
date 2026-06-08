# Coding-Agent Task Capture Wrapper

## Purpose

The task capture wrappers record enough local context to reconstruct normal coding-agent work as future benchmark cases.

They capture the Git starting point before the harness runs, launch the real installed agent CLI, then capture final status and diff after the harness exits. The Desktop app is the recommended launcher for tracked runs because it resolves the configured target repo and starts the selected wrapper from that repo's Git root.

## Configuration

The wrapper can be run from inside any target Git repository:

```sh
./opencode-bench.sh
```

For launcher use, create:

```sh
~/.config/opencodebench/config.env
```

Example:

```sh
OPENCODEBENCH_DEFAULT_REPO="$HOME/GitHub/example-repo"
OPENCODEBENCH_HARNESS=opencode
OPENCODEBENCH_HARNESS_MODE=direct
OPENCODEBENCH_AGENT_COMMAND_LABEL=opencode-direct
OPENCODEBENCH_TASK_SOURCE=desktop_app
```

Hermes orchestrating OpenCode:

```sh
OPENCODEBENCH_DEFAULT_REPO="$HOME/GitHub/example-repo"
OPENCODEBENCH_HARNESS=hermes
OPENCODEBENCH_HARNESS_MODE=orchestrating-opencode
OPENCODEBENCH_DOWNSTREAM_AGENT=opencode
OPENCODEBENCH_HERMES_MEMORY_MODE=on
OPENCODEBENCH_AGENT_COMMAND_LABEL=hermes-orchestrating-opencode
OPENCODEBENCH_TASK_SOURCE=desktop_app
```

Optional overrides:

- `OPENCODEBENCH_REPO`: target repo for one invocation.
- `OPENCODEBENCH_HARNESS`: harness name. Supported values are `opencode` and `hermes`.
- `OPENCODEBENCH_HARNESS_MODE`: harness mode. Supported combinations are `opencode/direct` and `hermes/orchestrating-opencode`.
- `OPENCODEBENCH_DOWNSTREAM_AGENT`: downstream agent for orchestration modes. For Hermes orchestration, this must be `opencode`.
- `OPENCODEBENCH_HERMES_MEMORY_MODE`: Hermes memory mode. Only `on` is currently supported; memory-off benchmarking is intentionally not implemented yet.
- `OPENCODEBENCH_AGENT_COMMAND_LABEL`: stable command label for metadata, defaulting to `opencode-direct`.
- `OPENCODEBENCH_TASK_SOURCE`: capture source such as `desktop_app`, `cli`, or `manual`.
- `OPENCODEBENCH_LOG_ROOT`: optional log root. If unset, logs go under the detected OpenCodeBench project checkout's local ignored log directory. If no checkout can be detected from the script location, logs fall back to `${XDG_STATE_HOME:-$HOME/.local/state}/opencodebench/coding-agent-task-logs/`. If set inside a Git repository, the log path must be gitignored; OpenCodeBench refuses unsafe non-ignored Git log roots because logs may contain prompts, diffs, metadata, local paths, and filenames.
- `OPENCODE_BIN`: specific real OpenCode binary. If unset, the wrapper uses `command -v opencode`.
- `HERMES_BIN`: specific real Hermes binary. If unset, the wrapper uses `command -v hermes`.

Unsupported harness combinations fail clearly before launching an agent.

## Captured Files

Task logs are written by default to:

```text
<OpenCodeBench root>/.local/coding-agent-task-logs/YYYY/MM/<task_id>/
```

If the scripts are run from an installed or copied location where no
OpenCodeBench checkout can be detected, logs fall back to:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/opencodebench/coding-agent-task-logs/YYYY/MM/<task_id>/
```

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

`metadata.json` includes the task ID, timestamps, launcher, generic harness metadata, resolved agent executable path fields, model, reasoning level, repo path, cwd, starting Git SHA, branch, starting status, dirty-state artifact paths, finish time, final status, final diff summary, and artifact paths.

Generic harness fields include:

- `harness`
- `harness_mode`
- `task_source`
- `agent_command_label`
- `agent_exit_code`
- `downstream_agent`
- `downstream_agent_mode`

Existing OpenCode-specific fields are preserved for compatibility. For OpenCode direct runs, `agent_exit_code` equals `opencode_exit_code`.

Hermes orchestration fields include `hermes_executable_path`, `hermes_version`, `hermes_profile`, `hermes_memory_mode`, `hermes_memory_enabled`, `hermes_user_profile_enabled`, and `hermes_exit_code`. Hermes is treated as the main harness, and OpenCode is recorded as `downstream_agent=opencode`. The wrapper does not directly observe a downstream OpenCode exit code yet.

OpenCodeBench does not capture raw Hermes `SOUL.md`, `MEMORY.md`, `USER.md`, `config.yaml`, `.env`, auth files, session transcripts, or logs. Logs may still contain prompts, diffs, metadata, local paths, and filenames, so keep them ignored and private.

## OpenTelemetry Metadata

Before launching the harness, the wrapper appends these fields to `OTEL_RESOURCE_ATTRIBUTES`:

- `opencodebench.session_id`
- `opencodebench.project_id`
- `opencodebench.repo_root`
- `opencodebench.task_dir`
- `opencodebench.git_commit_before`

The values are also exported as `OPENCODEBENCH_*` environment variables.

## macOS Launcher

OpenCodeBench is a separate macOS launcher for this wrapper. It does not replace OpenCode, alias `opencode`, or bundle an OpenCode copy.

Install the launcher into `~/Applications`:

```sh
./install-opencodebench-macos.sh
```

The installer also copies the wrapper scripts to:

```text
~/.local/share/opencodebench/
```

Then launch `OpenCodeBench` from Spotlight, Raycast, Alfred, Finder, or:

```sh
open ~/Applications/OpenCodeBench.app
```

The app supports `OPENCODEBENCH_HARNESS=opencode` with `OPENCODEBENCH_HARNESS_MODE=direct` and `OPENCODEBENCH_HARNESS=hermes` with `OPENCODEBENCH_HARNESS_MODE=orchestrating-opencode`. Unsupported harness settings exit non-zero with a clear error.

## Inspect A Captured Log

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

## Limitations

- Exact pre-task SHA capture only happens when the wrapper is used.
- Dirty repositories are recorded but not automatically cleaned or stashed.
- Langfuse trace linking is not implemented yet.
- The scripts do not create a benchmark case automatically yet.
