# Coding Agent Benchmarks

Lightweight local capture tooling for OpenCodeBench sessions.

OpenCodeBench launches the real installed `opencode` CLI, records pre-run Git metadata, injects `opencodebench.*` OpenTelemetry resource attributes, waits for OpenCode to exit, and then records the final Git status and diff.

It does not modify, alias, or bundle OpenCode.

## Install

```sh
./install-opencodebench-macos.sh
mkdir -p ~/.config/opencodebench
cp config/config.env.example ~/.config/opencodebench/config.env
```

Edit `~/.config/opencodebench/config.env` if you want the macOS launcher to open a default repository.

## Run

From inside any target repository:

```sh
./opencode-bench.sh
```

Or set the repo explicitly:

```sh
OPENCODEBENCH_REPO="/path/to/repo" ./opencode-bench.sh
```

The macOS app launcher reads `~/.config/opencodebench/config.env`, changes into `OPENCODEBENCH_DEFAULT_REPO`, and runs the installed wrapper from `~/.local/share/opencodebench`.

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

## Telemetry Metadata

`opencode-bench.sh` appends these fields to `OTEL_RESOURCE_ATTRIBUTES`:

- `opencodebench.session_id`
- `opencodebench.project_id`
- `opencodebench.repo_root`
- `opencodebench.task_dir`
- `opencodebench.git_commit_before`

The same values are also exported as `OPENCODEBENCH_*` environment variables for the launched OpenCode process.
