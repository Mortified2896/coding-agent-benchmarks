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
# Stage 2: sub-second wall-clock finish + finish_time field.
# Use date +%s.%N for accuracy, matching capture-task-start.sh.
finish_unix_seconds=$(date -u +%s.%N)
finish_time="$timestamp_end"
# Stage 2: duration_seconds = max(0, finish - start). Clamp to 0 to
# hide the small negative values that appear when clocks tick between
# the two `date` calls. start_unix_seconds is optional in old
# metadata.json files; treat missing as 0 and let the result be the
# elapsed-from-zero fallback so the field is always populated.
start_unix_seconds=$(jq -r '.opencodebench.timing.start_unix_seconds // 0' "$metadata_path")
# start_time_display: read from metadata.json (added by capture-task-start.sh).
# Fall back to timestamp_start / session_start_time for older metadata files
# written before Card 2, so the summary line is always populated.
start_time_display=$(jq -r '.start_time // .timestamp_start // .session_start_time // "unknown"' "$metadata_path")
duration_seconds=$(awk -v start="$start_unix_seconds" -v finish="$finish_unix_seconds" \
  'BEGIN { d = finish - start; if (d < 0) d = 0; printf "%.3f", d }')
# Stage 2: unified top-level exit_code. Source from the function
# argument ($agent_exit_code) — that's the wrapper's actual code, and
# it's known before the metadata is rewritten. Reading from the
# half-built metadata.json would race with this script's own merge and
# end up writing null. Empty $agent_exit_code means the wrapper didn't
# pass one (rare; trap may fire after signal) — write null in that case
# so downstream analysis can distinguish "exit 0" from "unknown".
exit_code="$agent_exit_code"
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
  --arg finish_time "$finish_time" \
  --argjson finish_unix_seconds "$finish_unix_seconds" \
  --argjson duration_seconds "$duration_seconds" \
  --arg agent_exit_code "$agent_exit_code" \
  --arg agent_kind "$agent_kind" \
  --arg exit_code "$exit_code" \
  --arg final_git_status "$git_status_after" \
  --arg final_git_diff_summary "$git_diff_summary" \
  --arg git_status_short_after_path "$status_after_path" \
  --arg git_diff_patch_path "$diff_patch_path" \
  --arg git_diff_stat_path "$diff_stat_path" \
  --arg git_diff_numstat_path "$diff_numstat_path" \
  '. + {
    timestamp_end: $timestamp_end,
    session_finish_time: $session_finish_time,
    finish_time: $finish_time,
    duration_seconds: $duration_seconds,
    exit_code: (if $exit_code == "" then null else ($exit_code | tonumber? // $exit_code) end),
    agent_exit_code: $agent_exit_code,
    final_git_status: $final_git_status,
    final_git_diff_summary: $final_git_diff_summary,
    git_status_short_after_path: $git_status_short_after_path,
    git_diff_patch_path: $git_diff_patch_path,
    git_diff_stat_path: $git_diff_stat_path,
    git_diff_numstat_path: $git_diff_numstat_path
  } + (if $agent_kind == "hermes" then {hermes_exit_code: $agent_exit_code} else {opencode_exit_code: $agent_exit_code} end)
   | .opencodebench.timing += {
       finish_unix_seconds: $finish_unix_seconds,
       duration_seconds: $duration_seconds
     }' \
  "$metadata_path" > "$tmp_metadata"
mv "$tmp_metadata" "$metadata_path"

{
  print -r -- "# Coding-Agent Task Capture Summary"
  print -r -- ""
  print -r -- "- Task directory: \`$task_dir\`"
  print -r -- "- Repository: \`$repo\`"
  print -r -- "- Started: \`$start_time_display\`"
  print -r -- "- Finished: \`$timestamp_end\`"
  print -r -- "- Duration: \`${duration_seconds}s\`"
  print -r -- "- Exit code: \`${exit_code:-unknown}\`"
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
