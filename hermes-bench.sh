#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
config_file="${OPENCODEBENCH_CONFIG:-$HOME/.config/opencodebench/config.env}"

if [[ -f "$config_file" ]]; then
  source "$config_file"
fi

target_repo="${OPENCODEBENCH_REPO:-${OPENCODEBENCH_DEFAULT_REPO:-$PWD}}"
target_repo="${target_repo/#\~/$HOME}"

if ! git -C "$target_repo" rev-parse --show-toplevel >/dev/null 2>&1; then
  print -u2 "Error: target path is not inside a Git repository: $target_repo"
  print -u2 "Set OPENCODEBENCH_REPO or OPENCODEBENCH_DEFAULT_REPO in $config_file."
  exit 1
fi

repo_root="$(git -C "$target_repo" rev-parse --show-toplevel)"
opencodebench_harness="${OPENCODEBENCH_HARNESS:-hermes}"
opencodebench_harness_mode="${OPENCODEBENCH_HARNESS_MODE:-orchestrating-opencode}"
opencodebench_downstream_agent="${OPENCODEBENCH_DOWNSTREAM_AGENT:-opencode}"
opencodebench_downstream_agent_mode="${OPENCODEBENCH_DOWNSTREAM_AGENT_MODE:-delegated}"
opencodebench_agent_command_label="${OPENCODEBENCH_AGENT_COMMAND_LABEL:-hermes-orchestrating-opencode}"
opencodebench_task_source="${OPENCODEBENCH_TASK_SOURCE:-cli}"
opencodebench_hermes_memory_mode="${OPENCODEBENCH_HERMES_MEMORY_MODE:-on}"

if [[ "$opencodebench_harness" != "hermes" || "$opencodebench_harness_mode" != "orchestrating-opencode" ]]; then
  print -u2 "Error: unsupported OpenCodeBench harness: ${opencodebench_harness}/${opencodebench_harness_mode}"
  print -u2 "Currently supported by hermes-bench.sh: hermes/orchestrating-opencode."
  exit 1
fi

if [[ "$opencodebench_downstream_agent" != "opencode" ]]; then
  print -u2 "Error: unsupported downstream agent for Hermes orchestration: $opencodebench_downstream_agent"
  print -u2 "Currently supported downstream agent: opencode."
  exit 1
fi

if [[ "$opencodebench_hermes_memory_mode" != "on" ]]; then
  print -u2 "Error: unsupported Hermes memory mode: $opencodebench_hermes_memory_mode"
  print -u2 "Currently supported Hermes memory mode: on. Memory-off benchmarking is not implemented yet."
  exit 1
fi

hermes_bin="${HERMES_BIN:-}"
if [[ -z "$hermes_bin" ]]; then
  if command -v hermes >/dev/null 2>&1; then
    hermes_bin="$(command -v hermes)"
  else
    print -u2 "Error: hermes CLI not found in PATH."
    hermes_bin=""
  fi
fi

if [[ -n "$hermes_bin" && ! -x "$hermes_bin" ]]; then
  print -u2 "Error: resolved Hermes binary is not executable: $hermes_bin"
  hermes_bin=""
fi

case "$hermes_bin" in
  "$script_dir/hermes-bench.sh"|*"OpenCodeBench.app"*)
    print -u2 "Error: resolved Hermes binary points to the benchmark launcher instead of the real Hermes CLI: $hermes_bin"
    hermes_bin=""
    ;;
esac

hermes_version="unknown"
if [[ -n "$hermes_bin" ]]; then
  hermes_version="$({ "$hermes_bin" --version || true; } 2>/dev/null | head -n 1)"
  if [[ -z "$hermes_version" ]]; then
    hermes_version="unknown"
  fi
fi

hermes_profile="${HERMES_PROFILE:-${OPENCODEBENCH_HERMES_PROFILE:-}}"
if [[ -z "$hermes_profile" ]]; then
  hermes_profile="unknown"
fi

task_dir=$(HARNESS="$opencodebench_harness" HARNESS_MODE="$opencodebench_harness_mode" TASK_SOURCE="$opencodebench_task_source" AGENT_COMMAND_LABEL="$opencodebench_agent_command_label" LAUNCHER_USED=OpenCodeBench DOWNSTREAM_AGENT="$opencodebench_downstream_agent" DOWNSTREAM_AGENT_MODE="$opencodebench_downstream_agent_mode" HERMES_EXECUTABLE_PATH="$hermes_bin" HERMES_VERSION="$hermes_version" HERMES_PROFILE="$hermes_profile" HERMES_MEMORY_MODE=on HERMES_MEMORY_ENABLED=true HERMES_USER_PROFILE_ENABLED=true MODEL="${HERMES_MODEL:-unknown}" "$script_dir/capture-task-start.sh" "$repo_root")

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

hermes_exit_code=0
finished=0
finish_capture() {
  if [[ "$finished" -eq 0 ]]; then
    finished=1
    "$script_dir/capture-task-finish.sh" "$task_dir" "$hermes_exit_code" hermes >/dev/null || true
    print -r -- "OpenCodeBench task log directory: $task_dir"
  fi
}
trap finish_capture EXIT

set +e
if [[ -n "$hermes_bin" ]]; then
  cd "$repo_root"
  "$hermes_bin"
  hermes_exit_code=$?
else
  hermes_exit_code=127
fi
set -e

exit "$hermes_exit_code"
