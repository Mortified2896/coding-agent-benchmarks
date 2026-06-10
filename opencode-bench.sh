#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname -- "$0")" && pwd)"
config_file="${OPENCODEBENCH_CONFIG:-$HOME/.config/opencodebench/config.env}"

if [[ -f "$config_file" ]]; then
  source "$config_file"
fi

target_repo="${OPENCODEBENCH_REPO:-${OPENCODEBENCH_DEFAULT_REPO:-$PWD}}"
target_repo="${target_repo/#\~/$HOME}"

if ! git -C "$target_repo" rev-parse --show-toplevel >/dev/null 2>&1; then
  printf '%s\n' "Error: target path is not inside a Git repository: $target_repo" >&2
  printf '%s\n' "Set OPENCODEBENCH_REPO or OPENCODEBENCH_DEFAULT_REPO in $config_file." >&2
  exit 1
fi

repo_root="$(git -C "$target_repo" rev-parse --show-toplevel)"
opencodebench_harness="${OPENCODEBENCH_HARNESS:-opencode}"
opencodebench_harness_mode="${OPENCODEBENCH_HARNESS_MODE:-direct}"
opencodebench_agent_command_label="${OPENCODEBENCH_AGENT_COMMAND_LABEL:-opencode-direct}"
opencodebench_task_source="${OPENCODEBENCH_TASK_SOURCE:-cli}"

if [[ "$opencodebench_harness" != "opencode" || "$opencodebench_harness_mode" != "direct" ]]; then
  printf '%s\n' "Error: unsupported OpenCodeBench harness: ${opencodebench_harness}/${opencodebench_harness_mode}" >&2
  printf '%s\n' "Currently supported: opencode/direct." >&2
  exit 1
fi

opencode_bin="${OPENCODE_BIN:-}"
if [[ -z "$opencode_bin" ]]; then
  if command -v opencode >/dev/null 2>&1; then
    opencode_bin="$(command -v opencode)"
  else
    printf '%s\n' "Error: opencode CLI not found in PATH." >&2
    opencode_bin=""
  fi
fi

if [[ -n "$opencode_bin" && ! -x "$opencode_bin" ]]; then
  printf '%s\n' "Error: resolved OpenCode binary is not executable: $opencode_bin" >&2
  opencode_bin=""
fi

case "$opencode_bin" in
  "$script_dir/opencode-bench.sh"|*"OpenCodeBench.app"*)
    printf '%s\n' "Error: resolved OpenCode binary points to the benchmark launcher instead of the real OpenCode CLI: $opencode_bin" >&2
    opencode_bin=""
    ;;
esac

task_dir=$(HARNESS="$opencodebench_harness" HARNESS_MODE="$opencodebench_harness_mode" TASK_SOURCE="$opencodebench_task_source" AGENT_COMMAND_LABEL="$opencodebench_agent_command_label" LAUNCHER_USED=OpenCodeBench OPENCODE_EXECUTABLE_PATH="$opencode_bin" MODEL="${OPENCODE_MODEL:-unknown}" "$script_dir/capture-task-start.sh" "$repo_root")

metadata_path="$task_dir/metadata.json"
opencodebench_session_id="$(basename "$task_dir")"
opencodebench_project_id="$(jq -r '.opencodebench.project_id // (.repo_path | split("/")[-1]) // "unknown"' "$metadata_path")"
opencodebench_repo_root="$(jq -r '.opencodebench.repo_root // .repo_path // empty' "$metadata_path")"
opencodebench_task_dir="$(jq -r '.opencodebench.task_dir // empty' "$metadata_path")"
opencodebench_git_commit_before="$(jq -r '.opencodebench.git_commit_before // .git_head_before // .git_commit // empty' "$metadata_path")"

if [[ -z "$opencodebench_git_commit_before" ]]; then
  opencodebench_git_commit_before="$(git -C "$opencodebench_repo_root" rev-parse HEAD 2>/dev/null || true)"
fi

export OPENCODEBENCH_SESSION_ID="$opencodebench_session_id"
export OPENCODEBENCH_PROJECT_ID="$opencodebench_project_id"
export OPENCODEBENCH_REPO_ROOT="$opencodebench_repo_root"
export OPENCODEBENCH_TASK_DIR="$opencodebench_task_dir"
export OPENCODEBENCH_GIT_COMMIT_BEFORE="$opencodebench_git_commit_before"

otel_escape_value() {
  jq -rn --arg value "$1" '$value | @uri'
}

opencodebench_otel_attributes="$(
  printf 'opencodebench.session_id=%s,opencodebench.project_id=%s,opencodebench.repo_root=%s,opencodebench.task_dir=%s,opencodebench.git_commit_before=%s' \
    "$(otel_escape_value "$OPENCODEBENCH_SESSION_ID")" \
    "$(otel_escape_value "$OPENCODEBENCH_PROJECT_ID")" \
    "$(otel_escape_value "$OPENCODEBENCH_REPO_ROOT")" \
    "$(otel_escape_value "$OPENCODEBENCH_TASK_DIR")" \
    "$(otel_escape_value "$OPENCODEBENCH_GIT_COMMIT_BEFORE")"
)"

if [[ -n "${OTEL_RESOURCE_ATTRIBUTES:-}" ]]; then
  export OTEL_RESOURCE_ATTRIBUTES="${OTEL_RESOURCE_ATTRIBUTES},${opencodebench_otel_attributes}"
else
  export OTEL_RESOURCE_ATTRIBUTES="$opencodebench_otel_attributes"
fi

opencode_exit_code=0
finished=0
finish_capture() {
  if [[ "$finished" -eq 0 ]]; then
    finished=1
    "$script_dir/capture-task-finish.sh" "$task_dir" "$opencode_exit_code" >/dev/null || true
    printf '%s\n' "OpenCodeBench task log directory: $task_dir"
  fi
}
trap finish_capture EXIT

set +e
if [[ -n "$opencode_bin" ]]; then
  cd "$repo_root"
  "$opencode_bin"
  opencode_exit_code=$?
else
  opencode_exit_code=127
fi
set -e

exit "$opencode_exit_code"
