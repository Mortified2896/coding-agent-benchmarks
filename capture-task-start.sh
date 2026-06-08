#!/bin/zsh
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  print -u2 "Error: jq is required to write metadata.json. Install jq and retry."
  exit 1
fi

repo="${1:-$PWD}"
prompt_file="${2:-}"

git_root=$(git -C "$repo" rev-parse --show-toplevel)
timestamp_start=$(date -u +%Y-%m-%dT%H-%M-%SZ)
session_start_time="$timestamp_start"
harness="${HARNESS:-opencode}"
launcher_used="${LAUNCHER_USED:-}"
opencode_executable_path="${OPENCODE_EXECUTABLE_PATH:-}"
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
  log_root="$git_root/.local/coding-agent-task-logs"
fi
task_dir="$log_root/$year/$month/$task_id"
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
  --arg launcher_used "$launcher_used" \
  --arg opencode_executable_path "$opencode_executable_path" \
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
    launcher_used: $launcher_used,
    opencode_executable_path: $opencode_executable_path,
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
