#!/bin/zsh
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  print -u2 "Error: jq is required to update metadata.json. Install jq and retry."
  exit 1
fi

if [[ $# -lt 1 ]]; then
  print -u2 "Usage: capture-task-finish.sh <task_dir> [agent_exit_code] [agent_kind]"
  exit 1
fi

task_dir="$1"
agent_exit_code="${2:-}"
agent_kind="${3:-opencode}"
metadata_path="$task_dir/metadata.json"

if [[ ! -f "$metadata_path" ]]; then
  print -u2 "Error: metadata.json not found in task directory: $task_dir"
  exit 1
fi

repo=$(jq -r '.repo_path' "$metadata_path")
if [[ -z "$repo" || "$repo" == "null" ]]; then
  print -u2 "Error: repo_path missing from metadata.json"
  exit 1
fi

timestamp_end=$(date -u +%Y-%m-%dT%H-%M-%SZ)
status_after_path="$task_dir/git-status-after.txt"
diff_stat_path="$task_dir/git-diff-stat.txt"
diff_numstat_path="$task_dir/git-diff-numstat.txt"
diff_patch_path="$task_dir/git-diff.patch"
summary_path="$task_dir/summary.md"

git -C "$repo" status --short > "$status_after_path"
git -C "$repo" diff --stat > "$diff_stat_path"
git -C "$repo" diff --numstat > "$diff_numstat_path"
git -C "$repo" diff > "$diff_patch_path"
git_status_after=$(git -C "$repo" status --short)
git_diff_summary=$(git -C "$repo" diff --stat)

tmp_metadata=$(mktemp)
jq \
  --arg timestamp_end "$timestamp_end" \
  --arg session_finish_time "$timestamp_end" \
  --arg agent_exit_code "$agent_exit_code" \
  --arg agent_kind "$agent_kind" \
  --arg final_git_status "$git_status_after" \
  --arg final_git_diff_summary "$git_diff_summary" \
  --arg git_status_short_after_path "$status_after_path" \
  --arg git_diff_patch_path "$diff_patch_path" \
  --arg git_diff_stat_path "$diff_stat_path" \
  --arg git_diff_numstat_path "$diff_numstat_path" \
  '. + {
    timestamp_end: $timestamp_end,
    session_finish_time: $session_finish_time,
    agent_exit_code: $agent_exit_code,
    final_git_status: $final_git_status,
    final_git_diff_summary: $final_git_diff_summary,
    git_status_short_after_path: $git_status_short_after_path,
    git_diff_patch_path: $git_diff_patch_path,
    git_diff_stat_path: $git_diff_stat_path,
    git_diff_numstat_path: $git_diff_numstat_path
  } + (if $agent_kind == "hermes" then {hermes_exit_code: $agent_exit_code} else {opencode_exit_code: $agent_exit_code} end)' \
  "$metadata_path" > "$tmp_metadata"
mv "$tmp_metadata" "$metadata_path"

{
  print -r -- "# Coding-Agent Task Capture Summary"
  print -r -- ""
  print -r -- "- Task directory: \`$task_dir\`"
  print -r -- "- Repository: \`$repo\`"
  print -r -- "- Finished: \`$timestamp_end\`"
  if [[ -n "$agent_exit_code" ]]; then
    print -r -- "- Agent exit code: \`$agent_exit_code\`"
    if [[ "$agent_kind" == "hermes" ]]; then
      print -r -- "- Hermes exit code: \`$agent_exit_code\`"
    else
      print -r -- "- OpenCode exit code: \`$agent_exit_code\`"
    fi
  fi
  print -r -- "- Diff stat: \`git-diff-stat.txt\`"
  print -r -- "- Diff patch: \`git-diff.patch\`"
} > "$summary_path"

print -r -- "$task_dir"
