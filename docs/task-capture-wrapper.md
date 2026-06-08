# Coding-Agent Task Capture Wrapper

## Purpose

The task capture wrapper records enough local context to reconstruct normal OpenCode work as future benchmark cases.

It captures the Git starting point before OpenCode runs, launches the real installed `opencode` CLI, then captures final status and diff after OpenCode exits.

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
```

Optional overrides:

- `OPENCODEBENCH_REPO`: target repo for one invocation.
- `OPENCODEBENCH_LOG_ROOT`: optional log root. If unset, logs go under the detected OpenCodeBench project checkout's local ignored log directory. If no checkout can be detected from the script location, logs fall back to `${XDG_STATE_HOME:-$HOME/.local/state}/opencodebench/coding-agent-task-logs/`. If set inside a Git repository, the log path must be gitignored; OpenCodeBench refuses unsafe non-ignored Git log roots because logs may contain prompts, diffs, metadata, local paths, and filenames.
- `OPENCODE_BIN`: specific real OpenCode binary. If unset, the wrapper uses `command -v opencode`.

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

`metadata.json` includes the task ID, timestamps, launcher, resolved OpenCode executable path, model, reasoning level, repo path, cwd, starting Git SHA, branch, starting status, dirty-state artifact paths, finish time, final status, final diff summary, and artifact paths.

## OpenTelemetry Metadata

Before launching OpenCode, the wrapper appends these fields to `OTEL_RESOURCE_ATTRIBUTES`:

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
