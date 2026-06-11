#!/usr/bin/env bash
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' "Error: jq is required to update metadata.json. Install jq and retry." >&2
  exit 1
fi

if [[ $# -lt 1 ]]; then
  printf '%s\n' "Usage: capture-task-finish.sh <task_dir> [agent_exit_code] [agent_kind]" >&2
  exit 1
fi

task_dir="$1"
agent_exit_code="${2:-}"
agent_kind="${3:-opencode}"
metadata_path="$task_dir/metadata.json"

if [[ ! -f "$metadata_path" ]]; then
  printf '%s\n' "Error: metadata.json not found in task directory: $task_dir" >&2
  exit 1
fi

repo=$(jq -r '.repo_path' "$metadata_path")
if [[ -z "$repo" || "$repo" == "null" ]]; then
  printf '%s\n' "Error: repo_path missing from metadata.json" >&2
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

# ============================================================
# OpenCode session ID resolution
# Resolves opencode_session_id from ~/.local/share/opencode/opencode.db
# after the worker finishes. This is the strong join key from
# OpenCodeBench metadata to OpenCode's internal session DB.
# ============================================================
opencode_session_merge='{"opencode_session_id":null,"opencode_session_id_status":"skipped","opencode_session_id_source":"unset","opencode_session_id_resolved_at":null,"opencode_session_id_candidates":0}'
langfuse_merge='{"langfuse_trace_id":null,"langfuse_trace_id_status":"skipped","langfuse_trace_id_source":"unset","langfuse_trace_id_resolved_at":null}'

_oc_db="${HOME}/.local/share/opencode/opencode.db"
if [[ "$agent_kind" != "opencode" ]]; then
  opencode_session_merge='{"opencode_session_id":null,"opencode_session_id_status":"skipped","opencode_session_id_source":"unset","opencode_session_id_resolved_at":null,"opencode_session_id_candidates":0}'
elif [[ -f "$_oc_db" && -r "$_oc_db" ]] && command -v python3 >/dev/null 2>&1; then
  _oc_resolved_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  _oc_raw=$(export OC_DB="$_oc_db" OC_REPO="$repo" OC_START="$start_unix_seconds" OC_FINISH="$finish_unix_seconds"; python3 -c '
import json, sqlite3, os

db = os.environ["OC_DB"]
rp = os.environ["OC_REPO"]
ss = float(os.environ.get("OC_START", "0"))
fs = float(os.environ.get("OC_FINISH", "0"))

if ss <= 0:
    ss = max(0.0, fs - 3600.0)
start_ms = int(ss * 1000) - 30000
finish_ms = int(fs * 1000) + 30000
if start_ms < 0:
    start_ms = 0

try:
    rp_real = os.path.realpath(rp)
except Exception:
    rp_real = rp

try:
    conn = sqlite3.connect(db)
    cur = conn.cursor()
    cur.execute(
        "SELECT id, directory, parent_id, agent FROM session "
        "WHERE directory IS NOT NULL AND time_created >= ? AND time_created <= ? "
        "ORDER BY time_created",
        (start_ms, finish_ms)
    )
    root_ids = []
    build_ids = []
    all_ids = []
    for row in cur.fetchall():
        d = row[1]
        if d is None:
            continue
        try:
            d_real = os.path.realpath(d)
        except Exception:
            d_real = d
        if d_real == rp_real or d_real == rp or d == rp_real or d == rp:
            all_ids.append(row[0])
            if row[2] is None:
                root_ids.append(row[0])
                if row[3] in (None, "build"):
                    build_ids.append(row[0])
    conn.close()
    ids = build_ids if build_ids else root_ids if root_ids else all_ids
    if len(ids) == 0:
        print(json.dumps({"s": "nf", "c": 0}))
    elif len(ids) == 1:
        print(json.dumps({"s": "ok", "id": ids[0], "c": 1}))
    else:
        print(json.dumps({"s": "am", "c": len(ids)}))
except Exception:
    print(json.dumps({"s": "er", "c": 0}))
' 2>/dev/null) || _oc_raw='{"s":"er","c":0}'

  _oc_s=$(printf '%s' "$_oc_raw" | jq -r '.s // "er"')
  case "$_oc_s" in
    ok)
      _oc_id=$(printf '%s' "$_oc_raw" | jq -r '.id // ""')
      _oc_cnt=$(printf '%s' "$_oc_raw" | jq -r '.c // 0')
      opencode_session_merge=$(jq -n \
        --arg id "$_oc_id" \
        --arg resolved_at "$_oc_resolved_at" \
        --argjson cnt "$_oc_cnt" \
        '{opencode_session_id:$id,opencode_session_id_status:"resolved",opencode_session_id_source:"sqlite",opencode_session_id_resolved_at:$resolved_at,opencode_session_id_candidates:$cnt}')
      ;;
    nf)
      opencode_session_merge='{"opencode_session_id":null,"opencode_session_id_status":"not_found","opencode_session_id_source":"sqlite","opencode_session_id_resolved_at":null,"opencode_session_id_candidates":0}'
      ;;
    am)
      _oc_cnt=$(printf '%s' "$_oc_raw" | jq -r '.c // 0')
      opencode_session_merge=$(jq -n \
        --argjson cnt "$_oc_cnt" \
        '{opencode_session_id:null,opencode_session_id_status:"ambiguous",opencode_session_id_source:"sqlite",opencode_session_id_resolved_at:null,opencode_session_id_candidates:$cnt}')
      ;;
    *)
      opencode_session_merge='{"opencode_session_id":null,"opencode_session_id_status":"error","opencode_session_id_source":"sqlite","opencode_session_id_resolved_at":null,"opencode_session_id_candidates":0}'
      ;;
  esac
  unset OC_DB OC_REPO OC_START OC_FINISH
else
  if [[ ! -f "$_oc_db" ]]; then
    opencode_session_merge='{"opencode_session_id":null,"opencode_session_id_status":"not_found","opencode_session_id_source":"sqlite","opencode_session_id_resolved_at":null,"opencode_session_id_candidates":0}'
  else
    opencode_session_merge='{"opencode_session_id":null,"opencode_session_id_status":"error","opencode_session_id_source":"sqlite","opencode_session_id_resolved_at":null,"opencode_session_id_candidates":0}'
  fi
fi

tmp_metadata=$(mktemp)
jq \
  --argjson opencode_session_merge "$opencode_session_merge" \
  --argjson langfuse_merge "$langfuse_merge" \
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
  '. + $opencode_session_merge + $langfuse_merge + {
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
        },
        opencode_session_id: $opencode_session_merge.opencode_session_id,
        opencode_session_id_status: $opencode_session_merge.opencode_session_id_status,
        opencode_session_id_source: $opencode_session_merge.opencode_session_id_source,
        opencode_session_id_resolved_at: $opencode_session_merge.opencode_session_id_resolved_at,
        opencode_session_id_candidates: $opencode_session_merge.opencode_session_id_candidates,
        langfuse_trace_id: $langfuse_merge.langfuse_trace_id,
        langfuse_trace_id_status: $langfuse_merge.langfuse_trace_id_status,
        langfuse_trace_id_source: $langfuse_merge.langfuse_trace_id_source,
        langfuse_trace_id_resolved_at: $langfuse_merge.langfuse_trace_id_resolved_at
      }' \
  "$metadata_path" > "$tmp_metadata"
mv "$tmp_metadata" "$metadata_path"

{
  printf '%s\n' "# Coding-Agent Task Capture Summary"
  printf '%s\n' ""
  printf '%s\n' "- Task directory: \`$task_dir\`"
  printf '%s\n' "- Repository: \`$repo\`"
  printf '%s\n' "- Started: \`$start_time_display\`"
  printf '%s\n' "- Finished: \`$timestamp_end\`"
  printf '%s\n' "- Duration: \`${duration_seconds}s\`"
  printf '%s\n' "- Exit code: \`${exit_code:-unknown}\`"
  if [[ -n "$agent_exit_code" ]]; then
    printf '%s\n' "- Agent exit code: \`$agent_exit_code\`"
    if [[ "$agent_kind" == "hermes" ]]; then
      printf '%s\n' "- Hermes exit code: \`$agent_exit_code\`"
    else
      printf '%s\n' "- OpenCode exit code: \`$agent_exit_code\`"
    fi
  fi
  printf '%s\n' "- Diff stat: \`git-diff-stat.txt\`"
  printf '%s\n' "- Diff patch: \`git-diff.patch\`"
  if [[ "$diff_is_git_repo" == "true" ]]; then
    printf '%s\n' "- Files changed: \`$files_changed\`"
    printf '%s\n' "- Lines added: \`$lines_added\`"
    printf '%s\n' "- Lines deleted: \`$lines_deleted\`"
    printf '%s\n' "- Working tree dirty after: \`$working_tree_dirty_after\`"
    printf '%s\n' "- Diff produced: \`$diff_produced\`"
  else
    printf '%s\n' "- Diff summary: \`(non-Git repo, all fields null)\`"
  fi
} > "$summary_path"

printf '%s\n' "$task_dir"
