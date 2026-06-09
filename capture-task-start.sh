#!/bin/zsh
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  print -u2 "Error: jq is required to write metadata.json. Install jq and retry."
  exit 1
fi

validate_log_root_override() {
  local log_root="$1"
  local intended_log_path="$2"
  local check_dir="$log_root"
  local log_git_root
  local relative_log_path

  while [[ ! -e "$check_dir" && "$check_dir" != "/" ]]; do
    check_dir="${check_dir:h}"
  done

  if ! log_git_root=$(git -C "$check_dir" rev-parse --show-toplevel 2>/dev/null); then
    return 0
  fi

  relative_log_path="${intended_log_path#$log_git_root/}"
  if git -C "$log_git_root" check-ignore -q -- "$relative_log_path"; then
    return 0
  fi

  print -u2 "Error: unsafe OPENCODEBENCH_LOG_ROOT: $log_root"
  print -u2 "Benchmark logs may contain prompts, diffs, metadata, local paths, and filenames."
  print -u2 "The resolved log path is inside a Git repository but is not ignored:"
  print -u2 "  $intended_log_path"
  print -u2 "Add an ignore rule for this log root or choose a path outside any Git repository."
  return 1
}

looks_like_opencodebench_root() {
  local candidate="$1"

  [[ -f "$candidate/capture-task-start.sh" ]] &&
    [[ -f "$candidate/capture-task-finish.sh" ]] &&
    [[ -f "$candidate/opencode-bench.sh" ]] &&
    [[ -f "$candidate/config/config.env.example" ]] &&
    [[ -f "$candidate/README.md" ]]
}

detect_opencodebench_root() {
  local search_dir="$1"

  while [[ "$search_dir" != "/" ]]; do
    if looks_like_opencodebench_root "$search_dir"; then
      print -r -- "$search_dir"
      return 0
    fi
    search_dir="${search_dir:h}"
  done

  return 1
}

default_log_root() {
  local script_dir="$1"
  local project_root
  local state_home

  if project_root="$(detect_opencodebench_root "$script_dir")"; then
    print -r -- "$project_root/.local/coding-agent-task-logs"
    return 0
  fi

  state_home="${XDG_STATE_HOME:-$HOME/.local/state}"
  state_home="${state_home/#\~/$HOME}"
  print -r -- "$state_home/opencodebench/coding-agent-task-logs"
}

repo="${1:-$PWD}"
prompt_file="${2:-}"
script_dir="${0:A:h}"

git_root=$(git -C "$repo" rev-parse --show-toplevel)
timestamp_start=$(date -u +%Y-%m-%dT%H-%M-%SZ)
session_start_time="$timestamp_start"
harness="${HARNESS:-opencode}"
harness_mode="${HARNESS_MODE:-${OPENCODEBENCH_HARNESS_MODE:-direct}}"
task_source="${TASK_SOURCE:-${OPENCODEBENCH_TASK_SOURCE:-manual}}"
agent_command_label="${AGENT_COMMAND_LABEL:-${OPENCODEBENCH_AGENT_COMMAND_LABEL:-${harness}-${harness_mode}}}"
launcher_used="${LAUNCHER_USED:-}"
opencode_executable_path="${OPENCODE_EXECUTABLE_PATH:-}"
tracking_harness="${TRACKING_HARNESS:-${OPENCODEBENCH_TRACKING_HARNESS:-}}"
execution_agent="${EXECUTION_AGENT:-${OPENCODEBENCH_EXECUTION_AGENT:-}}"
upstream_orchestrator="${UPSTREAM_ORCHESTRATOR:-${OPENCODEBENCH_UPSTREAM_ORCHESTRATOR:-}}"
orchestration_mode="${ORCHESTRATION_MODE:-${OPENCODEBENCH_ORCHESTRATION_MODE:-}}"
repo_detection_method="${REPO_DETECTION_METHOD:-${OPENCODEBENCH_REPO_DETECTION_METHOD:-}}"
working_directory="${WORKING_DIRECTORY:-${OPENCODEBENCH_WORKING_DIRECTORY:-$PWD}}"
downstream_agent="${DOWNSTREAM_AGENT:-${OPENCODEBENCH_DOWNSTREAM_AGENT:-}}"
downstream_agent_mode="${DOWNSTREAM_AGENT_MODE:-${OPENCODEBENCH_DOWNSTREAM_AGENT_MODE:-}}"
hermes_executable_path="${HERMES_EXECUTABLE_PATH:-}"
hermes_version="${HERMES_VERSION:-}"
hermes_profile="${HERMES_PROFILE:-}"
hermes_memory_mode="${HERMES_MEMORY_MODE:-${OPENCODEBENCH_HERMES_MEMORY_MODE:-}}"
hermes_memory_enabled="${HERMES_MEMORY_ENABLED:-}"
hermes_user_profile_enabled="${HERMES_USER_PROFILE_ENABLED:-}"
model="${MODEL:-${OPENCODE_MODEL:-unknown}}"
reasoning_level="${REASONING_LEVEL:-}"
git_head_before=$(git -C "$git_root" rev-parse HEAD)
git_branch_before=$(git -C "$git_root" branch --show-current)

safe_repo_name=$(printf '%s' "$(basename "$git_root")" | tr -c 'A-Za-z0-9._-' '-')
task_id="${timestamp_start}-${harness}-${safe_repo_name}"
opencodebench_session_id="$task_id"
opencodebench_project_id="$(basename "$git_root")"
opencodebench_repo_root="$git_root"
year=$(date -u +%Y)
month=$(date -u +%m)
if [[ -n "${OPENCODEBENCH_LOG_ROOT:-}" ]]; then
  log_root="${OPENCODEBENCH_LOG_ROOT:A}"
else
  log_root="$(default_log_root "$script_dir")"
fi
task_dir="$log_root/$year/$month/$task_id"
if [[ -n "${OPENCODEBENCH_LOG_ROOT:-}" ]]; then
  validate_log_root_override "$log_root" "$task_dir/metadata.json"
fi
opencodebench_task_dir="$task_dir"
opencodebench_git_commit_before="$git_head_before"

mkdir -p "$task_dir"

if [[ -n "$prompt_file" ]]; then
  cp "$prompt_file" "$task_dir/task.md"
else
  {
    print -r -- "# OpenCodeBench Session"
    print -r -- ""
    print -r -- "No startup prompt was provided. This session was captured from a normal OpenCode launch."
  } > "$task_dir/task.md"
fi

print -r -- "$git_head_before" > "$task_dir/git-head-before.txt"
print -r -- "$git_branch_before" > "$task_dir/git-branch-before.txt"
git -C "$git_root" status --short > "$task_dir/git-status-before.txt"
git -C "$git_root" diff > "$task_dir/git-diff-before.patch"
git -C "$git_root" diff --stat > "$task_dir/git-diff-stat-before.txt"
git -C "$git_root" diff --numstat > "$task_dir/git-diff-numstat-before.txt"
git_status_before=$(git -C "$git_root" status --short)

jq -n \
  --arg task_id "$task_id" \
  --arg timestamp "$timestamp_start" \
  --arg timestamp_start "$timestamp_start" \
  --arg session_start_time "$session_start_time" \
  --arg harness "$harness" \
  --arg harness_mode "$harness_mode" \
  --arg task_source "$task_source" \
  --arg agent_command_label "$agent_command_label" \
  --arg launcher_used "$launcher_used" \
  --arg opencode_executable_path "$opencode_executable_path" \
  --arg tracking_harness "$tracking_harness" \
  --arg execution_agent "$execution_agent" \
  --arg upstream_orchestrator "$upstream_orchestrator" \
  --arg orchestration_mode "$orchestration_mode" \
  --arg repo_detection_method "$repo_detection_method" \
  --arg working_directory "$working_directory" \
  --arg downstream_agent "$downstream_agent" \
  --arg downstream_agent_mode "$downstream_agent_mode" \
  --arg hermes_executable_path "$hermes_executable_path" \
  --arg hermes_version "$hermes_version" \
  --arg hermes_profile "$hermes_profile" \
  --arg hermes_memory_mode "$hermes_memory_mode" \
  --arg hermes_memory_enabled "$hermes_memory_enabled" \
  --arg hermes_user_profile_enabled "$hermes_user_profile_enabled" \
  --arg model_id "$model" \
  --arg reasoning_level "$reasoning_level" \
  --arg repo_path "$git_root" \
  --arg cwd "$PWD" \
  --arg git_root "$git_root" \
  --arg git_head_before "$git_head_before" \
  --arg git_branch_before "$git_branch_before" \
  --arg git_status_before "$git_status_before" \
  --arg git_status_short_before_path "$task_dir/git-status-before.txt" \
  --arg git_diff_patch_before_path "$task_dir/git-diff-before.patch" \
  --arg git_diff_stat_before_path "$task_dir/git-diff-stat-before.txt" \
  --arg git_diff_numstat_before_path "$task_dir/git-diff-numstat-before.txt" \
  --arg opencodebench_session_id "$opencodebench_session_id" \
  --arg opencodebench_project_id "$opencodebench_project_id" \
  --arg opencodebench_repo_root "$opencodebench_repo_root" \
  --arg opencodebench_task_dir "$opencodebench_task_dir" \
  --arg opencodebench_git_commit_before "$opencodebench_git_commit_before" \
  '{
    task_id: $task_id,
    timestamp: $timestamp,
    timestamp_start: $timestamp_start,
    session_start_time: $session_start_time,
    harness: $harness,
    harness_mode: $harness_mode,
    task_source: $task_source,
    agent_command_label: $agent_command_label,
    launcher_used: $launcher_used,
    opencode_executable_path: $opencode_executable_path,
    tracking_harness: $tracking_harness,
    execution_agent: $execution_agent,
    upstream_orchestrator: $upstream_orchestrator,
    orchestration_mode: $orchestration_mode,
    repo_detection_method: $repo_detection_method,
    working_directory: $working_directory,
    downstream_agent: $downstream_agent,
    downstream_agent_mode: $downstream_agent_mode,
    hermes_executable_path: $hermes_executable_path,
    hermes_version: $hermes_version,
    hermes_profile: $hermes_profile,
    hermes_memory_mode: $hermes_memory_mode,
    hermes_memory_enabled: $hermes_memory_enabled,
    hermes_user_profile_enabled: $hermes_user_profile_enabled,
    model_id: $model_id,
    reasoning_level: $reasoning_level,
    repo_path: $repo_path,
    cwd: $cwd,
    git_root: $git_root,
    git_commit: $git_head_before,
    git_branch: $git_branch_before,
    git_status: $git_status_before,
    git_head_before: $git_head_before,
    git_branch_before: $git_branch_before,
    git_status_short_before_path: $git_status_short_before_path,
    git_diff_patch_before_path: $git_diff_patch_before_path,
    git_diff_stat_before_path: $git_diff_stat_before_path,
    git_diff_numstat_before_path: $git_diff_numstat_before_path,
    "opencodebench.session_id": $opencodebench_session_id,
    "opencodebench.project_id": $opencodebench_project_id,
    "opencodebench.repo_root": $opencodebench_repo_root,
    "opencodebench.task_dir": $opencodebench_task_dir,
    "opencodebench.git_commit_before": $opencodebench_git_commit_before,
    opencodebench: {
      session_id: $opencodebench_session_id,
      project_id: $opencodebench_project_id,
      repo_root: $opencodebench_repo_root,
      task_dir: $opencodebench_task_dir,
      git_commit_before: $opencodebench_git_commit_before
    }
  }' > "$task_dir/metadata.json"

print -r -- "$task_dir"
