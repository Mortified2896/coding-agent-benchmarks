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

git -C "$repo" status --short > "$status_after_path" 2>/dev/null || true
git -C "$repo" diff --stat > "$diff_stat_path" 2>/dev/null || true
git -C "$repo" diff --numstat > "$diff_numstat_path" 2>/dev/null || true
git -C "$repo" diff > "$diff_patch_path" 2>/dev/null || true
git_status_after=$(git -C "$repo" status --short 2>/dev/null || true)
git_diff_summary=$(git -C "$repo" diff --stat 2>/dev/null || true)
git_numstat_body=$(git -C "$repo" diff --numstat 2>/dev/null || true)
git_name_only_body=$(git -C "$repo" diff --name-only 2>/dev/null || true)
git_is_repo="true"
if ! git -C "$repo" rev-parse --show-toplevel >/dev/null 2>&1; then
  git_is_repo="false"
fi

# Stage 2 Card 4: diff-size summary.
# files_changed = count of names in `git diff --name-only`.
# lines_added / lines_deleted = sum of the +/- columns from
#   `git diff --numstat`. Binary files print "- -" (dash) for both
#   columns; treat as 0 (binary files do not contribute line counts).
# working_tree_dirty_after = true iff `git status --porcelain` is non-empty
#   (covers both tracked modifications AND untracked files).
# diff_produced = true iff files_changed > 0.
# Non-Git repo: files_changed=0, lines_added=0, lines_deleted=0,
#   working_tree_dirty_after=null, diff_produced=false, diff_is_git_repo=false.
# We still want the sidecar files (git-status-after.txt, etc.) to be
# present even if empty so the layout is uniform across all tasks.
if [[ "$git_is_repo" == "true" ]]; then
  files_changed=$(printf '%s' "$git_name_only_body" | awk 'NF{c++} END{print c+0}')
  # Parse numstat: <added>\t<deleted>\t<path>. "-" means binary
  # (or rename copy, but in --numstat those still produce numbers).
  line_totals=$(printf '%s' "$git_numstat_body" | awk -F'\t' '
    NF < 2 { next }
    {
      a = ($1 == "-" ? 0 : $1 + 0)
      d = ($2 == "-" ? 0 : $2 + 0)
      add += a
      del += d
    }
    END { printf "%d %d", add+0, del+0 }
  ')
  lines_added=${line_totals%% *}
  lines_deleted=${line_totals##* }
  if [[ -n "$git_status_after" ]]; then
    working_tree_dirty_after="true"
  else
    working_tree_dirty_after="false"
  fi
  if [[ "$files_changed" -gt 0 ]]; then
    diff_produced="true"
  else
    diff_produced="false"
  fi
  diff_is_git_repo="true"
else
  files_changed=0
  lines_added=0
  lines_deleted=0
  working_tree_dirty_after="null"
  diff_produced="false"
  diff_is_git_repo="false"
fi

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
  --argjson files_changed "$files_changed" \
  --argjson lines_added "$lines_added" \
  --argjson lines_deleted "$lines_deleted" \
  --argjson working_tree_dirty_after "$working_tree_dirty_after" \
  --argjson diff_produced "$diff_produced" \
  --argjson diff_is_git_repo "$diff_is_git_repo" \
  '. + {
    timestamp_end: $timestamp_end,
    session_finish_time: $session_finish_time,
    finish_time: $finish_time,
    duration_seconds: $duration_seconds,
    exit_code: (if $exit_code == "" then null else ($exit_code | tonumber? // $exit_code) end),
    agent_exit_code: $agent_exit_code,
    files_changed: $files_changed,
    lines_added: $lines_added,
    lines_deleted: $lines_deleted,
    working_tree_dirty_after: $working_tree_dirty_after,
    diff_produced: $diff_produced,
    diff_is_git_repo: $diff_is_git_repo,
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
     }
   | .opencodebench += {
       diff_summary: {
         files_changed: $files_changed,
         lines_added: $lines_added,
         lines_deleted: $lines_deleted,
         working_tree_dirty_after: $working_tree_dirty_after,
         diff_produced: $diff_produced,
         is_git_repo: $diff_is_git_repo
       }
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
  if [[ "$diff_is_git_repo" == "true" ]]; then
    print -r -- "- Files changed: \`$files_changed\`"
    print -r -- "- Lines added: \`$lines_added\`"
    print -r -- "- Lines deleted: \`$lines_deleted\`"
    print -r -- "- Working tree dirty after: \`$working_tree_dirty_after\`"
    print -r -- "- Diff produced: \`$diff_produced\`"
  else
    print -r -- "- Diff summary: \`(non-Git repo, all fields null)\`"
  fi
} > "$summary_path"

print -r -- "$task_dir"
