#!/usr/bin/env bash
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' "Error: jq is required to write metadata.json. Install jq and retry." >&2
  exit 1
fi

validate_log_root_override() {
  local log_root="$1"
  local intended_log_path="$2"
  local check_dir="$log_root"
  local log_git_root
  local relative_log_path

  # bash equivalent of zsh's "${var:h}" (parent directory). dirname returns
  # "." for a path with no slash, and "/" for "/" itself, so the loop guard
  # above ("$check_dir" != "/") is still correct.
  while [[ ! -e "$check_dir" && "$check_dir" != "/" ]]; do
    check_dir="$(dirname -- "$check_dir")"
  done

  if ! log_git_root=$(git -C "$check_dir" rev-parse --show-toplevel 2>/dev/null); then
    return 0
  fi

  relative_log_path="${intended_log_path#$log_git_root/}"
  if git -C "$log_git_root" check-ignore -q -- "$relative_log_path"; then
    return 0
  fi

  printf '%s\n' "Error: unsafe OPENCODEBENCH_LOG_ROOT: $log_root" >&2
  printf '%s\n' "Benchmark logs may contain prompts, diffs, metadata, local paths, and filenames." >&2
  printf '%s\n' "The resolved log path is inside a Git repository but is not ignored:" >&2
  printf '%s\n' "  $intended_log_path" >&2
  printf '%s\n' "Add an ignore rule for this log root or choose a path outside any Git repository." >&2
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
      printf '%s\n' "$search_dir"
      return 0
    fi
    # bash equivalent of zsh's "${var:h}" (parent directory).
    search_dir="$(dirname -- "$search_dir")"
  done

  return 1
}

# Stage 2.5: resolve the Hermes user prompt from safe sources.
# Returns via global variables: hermes_user_prompt_text, hermes_user_prompt_source.
# Privacy boundary: does NOT read messages[*], run journal, turn journal,
# ~/.hermes/.env, ~/.hermes/config.yaml, ~/.hermes/auth.json,
# ~/.hermes/SOUL.md, ~/.hermes/MEMORY.md, ~/.hermes/USER.md, or ~/.hermes/state.db.
resolve_hermes_user_prompt() {
  hermes_user_prompt_text=""
  hermes_user_prompt_source="unavailable"

  # 1. "env" source: OPENCODEBENCH_HERMES_USER_PROMPT (direct text) or
  #    OPENCODEBENCH_HERMES_USER_PROMPT_PATH (file path)
  if [[ -n "${OPENCODEBENCH_HERMES_USER_PROMPT:-}" ]]; then
    hermes_user_prompt_text="${OPENCODEBENCH_HERMES_USER_PROMPT}"
    hermes_user_prompt_source="env"
    return 0
  fi
  if [[ -n "${OPENCODEBENCH_HERMES_USER_PROMPT_PATH:-}" && -r "${OPENCODEBENCH_HERMES_USER_PROMPT_PATH}" ]]; then
    hermes_user_prompt_text=$(cat "${OPENCODEBENCH_HERMES_USER_PROMPT_PATH}")
    hermes_user_prompt_source="env"
    return 0
  fi

  # 2. "session_json_pending" source: WebUI session JSON pending_user_message
  #    with liveness check on pending_started_at
  if [[ -n "${HERMES_WEBUI_STATE_DIR:-}" && -n "$hermes_session_id" ]]; then
    local session_json="${HERMES_WEBUI_STATE_DIR}/sessions/${hermes_session_id}.json"
    if [[ -f "$session_json" && -r "$session_json" ]]; then
      local msg_valid started_valid
      msg_valid=$(jq -e '.pending_user_message | type == "string" and length > 0' "$session_json" 2>/dev/null || true)
      started_valid=$(jq -e '.pending_started_at | type == "number"' "$session_json" 2>/dev/null || true)
      if [[ "$msg_valid" == "true" && "$started_valid" == "true" ]]; then
        local live_ok=0
        if [[ "${OPENCODEBENCH_HERMES_USER_PROMPT_LIVENESS:-}" == "off" ]]; then
          live_ok=1
        else
          local pending_started_at window now delta
          pending_started_at=$(jq -r '.pending_started_at' "$session_json")
          window="${OPENCODEBENCH_HERMES_USER_PROMPT_WINDOW_SECONDS:-60}"
          now=$(date -u +%s)
          delta=$(( now - pending_started_at ))
          if (( delta <= window )); then
            live_ok=1
          fi
        fi
        if [[ "$live_ok" -eq 1 ]]; then
          hermes_user_prompt_text=$(jq -r '.pending_user_message' "$session_json")
          hermes_user_prompt_source="session_json_pending"
          return 0
        fi
      fi
    fi
  fi

  # 3. "unavailable" — anything else. No fallback reads.
  return 0
}

# Stage 2.6: resolve Hermes orchestrator metadata from the WebUI session JSON.
# This is the fallback resolver used when capture-task-start.sh is called
# directly (without the wrapper). When called through opencodebench-opencode,
# the wrapper pre-populates HERMES_ORCHESTRATOR_* env vars and this function
# is skipped.
resolve_hermes_orchestrator_metadata() {
  if [[ "${OPENCODEBENCH_SKIP_HERMES_ORCHESTRATOR:-}" == "1" ]]; then
    return 0
  fi

  # Stage 2.7: normalize a reasoning-level string (bash-compatible)
  _horml_normalize_27() {
    local s="${1:-}"
    # Trim leading/trailing whitespace
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    # Lowercase
    s="$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')"
    # Spaces to underscores
    s="${s// /_}"
    printf '%s' "$s"
  }

  local session_json=""
  if [[ -n "${HERMES_WEBUI_STATE_DIR:-}" && -n "${HERMES_SESSION_ID:-}" ]]; then
    session_json="${HERMES_WEBUI_STATE_DIR}/sessions/${HERMES_SESSION_ID}.json"
  fi

  # Stage 2.7: resolve reasoning level via a 4-step precedence chain.
  _horml_effort_raw=""
  _horml_state_db_readable=0
  _horml_webui_raw=""
  if [[ -n "${HERMES_HOME:-}" && -n "${HERMES_SESSION_ID:-}" && -f "${HERMES_HOME}/state.db" ]]; then
    _horml_effort_raw=$(sqlite3 -separator $'\t' "${HERMES_HOME}/state.db" \
      "SELECT json_extract(model_config, '\$.reasoning_config.effort') \
       FROM sessions WHERE id = '${HERMES_SESSION_ID}' LIMIT 1;" 2>/dev/null || true)
    if [[ -n "$_horml_effort_raw" && "$_horml_effort_raw" != $'\t' ]]; then
      _horml_state_db_readable=1
    fi
  fi

  if [[ "${OPENCODEBENCH_SKIP_HERMES_REASONING:-}" == "1" ]]; then
    hermes_orchestrator_reasoning_level="unavailable"
    hermes_orchestrator_reasoning_level_source="skipped"
    hermes_orchestrator_reasoning_level_raw=""
    return 0
  fi

  if [[ -z "$session_json" || ! -f "$session_json" || ! -r "$session_json" ]]; then
    # Stage 2.7: try state.db before giving up
    if [[ -n "${OPENCODEBENCH_HERMES_REASONING_LEVEL:-}" ]]; then
      hermes_orchestrator_reasoning_level=$(_horml_normalize_27 "$OPENCODEBENCH_HERMES_REASONING_LEVEL")
      hermes_orchestrator_reasoning_level_source="env_override"
      hermes_orchestrator_reasoning_level_raw="$_horml_effort_raw"
    elif [[ "$_horml_state_db_readable" == "1" ]]; then
      hermes_orchestrator_reasoning_level=$(_horml_normalize_27 "$_horml_effort_raw")
      hermes_orchestrator_reasoning_level_source="state_db"
      hermes_orchestrator_reasoning_level_raw="$_horml_effort_raw"
    fi
    local _has_hermes=0 _v
    for _v in HERMES_SESSION_ID HERMES_HOME HERMES_WEBUI_STATE_DIR \
              HERMES_KANBAN_BOARD HERMES_INTERACTIVE HERMES_PROFILE \
              HERMES_SESSION_PLATFORM HERMES_SESSION_CHAT_ID; do
      # bash equivalent of zsh's "${(P)_v:-}" — indirect expansion through
      # the variable whose name is the value of _v, treating unset as empty.
      if [[ -n "${!_v:-}" ]]; then _has_hermes=1; break; fi
    done
    if [[ "$_has_hermes" -eq 1 ]]; then
      hermes_orchestrator_capture_source="env"
    fi
    return 0
  fi

  local projection
  projection=$(jq -c '{session_id, model, model_provider, profile, source_label,
    session_source, raw_source, is_cli_session, workspace,
    worktree_path, worktree_repo_root, worktree_branch, personality,
    context_engine, compression_anchor_mode}' "$session_json" 2>/dev/null) || return 0

  hermes_orchestrator_session_id=$(jq -r '.session_id // ""' <<<"$projection")
  hermes_orchestrator_model=$(jq -r '.model // ""' <<<"$projection")
  hermes_orchestrator_model_provider=$(jq -r '.model_provider // ""' <<<"$projection")
  hermes_orchestrator_profile=$(jq -r '.profile // ""' <<<"$projection")

  local sl ss rs
  sl=$(jq -r '.source_label // ""' <<<"$projection")
  ss=$(jq -r '.session_source // ""' <<<"$projection")
  rs=$(jq -r '.raw_source // ""' <<<"$projection")
  if [[ -n "$sl" && "$sl" != "null" ]]; then
    hermes_orchestrator_source_label="$sl"
  elif [[ -n "$ss" && "$ss" != "null" ]]; then
    hermes_orchestrator_source_label="$ss"
  elif [[ -n "$rs" && "$rs" != "null" ]]; then
    hermes_orchestrator_source_label="$rs"
  fi

  hermes_orchestrator_is_cli_session=$(jq -r '.is_cli_session // false' <<<"$projection")
  hermes_orchestrator_workspace=$(jq -r '.workspace // ""' <<<"$projection")
  hermes_orchestrator_worktree_path=$(jq -r '.worktree_path // null' <<<"$projection")

  # Stage 2.7 precedence chain.
  if [[ -n "${OPENCODEBENCH_HERMES_REASONING_LEVEL:-}" ]]; then
    hermes_orchestrator_reasoning_level=$(_horml_normalize_27 "$OPENCODEBENCH_HERMES_REASONING_LEVEL")
    hermes_orchestrator_reasoning_level_source="env_override"
    hermes_orchestrator_reasoning_level_raw="$_horml_effort_raw"
  elif [[ "$_horml_state_db_readable" == "1" ]]; then
    hermes_orchestrator_reasoning_level=$(_horml_normalize_27 "$_horml_effort_raw")
    hermes_orchestrator_reasoning_level_source="state_db"
    hermes_orchestrator_reasoning_level_raw="$_horml_effort_raw"
  else
    local ce cam
    ce=$(jq -r '.context_engine // ""' <<<"$projection")
    cam=$(jq -r '.compression_anchor_mode // ""' <<<"$projection")
    if [[ -n "$ce" && "$ce" != "null" ]]; then
      _horml_webui_raw="$ce"
      hermes_orchestrator_reasoning_level="$ce"
    elif [[ -n "$cam" && "$cam" != "null" ]]; then
      _horml_webui_raw="$cam"
      hermes_orchestrator_reasoning_level="$cam"
    fi
  fi

  # Stage 2.7: post-process the WebUI-chain case
  if [[ "$hermes_orchestrator_reasoning_level_source" == "unavailable" && "$hermes_orchestrator_reasoning_level" != "unavailable" ]]; then
    hermes_orchestrator_reasoning_level_source="webui_session_json"
    hermes_orchestrator_reasoning_level_raw="${_horml_webui_raw:-}"
    hermes_orchestrator_reasoning_level=$(_horml_normalize_27 "$hermes_orchestrator_reasoning_level")
  fi

  local _has_hermes=0 _v
  for _v in HERMES_SESSION_ID HERMES_HOME HERMES_WEBUI_STATE_DIR \
            HERMES_KANBAN_BOARD HERMES_INTERACTIVE HERMES_PROFILE \
            HERMES_SESSION_PLATFORM HERMES_SESSION_CHAT_ID; do
    # bash equivalent of zsh's "${(P)_v:-}" — see comment above.
    if [[ -n "${!_v:-}" ]]; then _has_hermes=1; break; fi
  done
  if [[ "$_has_hermes" -eq 1 ]]; then
    hermes_orchestrator_capture_source="env"
  else
    hermes_orchestrator_capture_source="session_json"
  fi
}

default_log_root() {
  local script_dir="$1"
  local project_root
  local state_home

  if project_root="$(detect_opencodebench_root "$script_dir")"; then
    printf '%s\n' "$project_root/.local/coding-agent-task-logs"
    return 0
  fi

  state_home="${XDG_STATE_HOME:-$HOME/.local/state}"
  state_home="${state_home/#\~/$HOME}"
  printf '%s\n' "$state_home/opencodebench/coding-agent-task-logs"
}

repo="${1:-$PWD}"
prompt_file="${2:-}"
# bash equivalent of zsh's "${0:A:h}" — absolute path of the script's
# directory, symlinks resolved (matching zsh :A semantics via readlink -f).
script_dir="$(cd "$(dirname -- "$(readlink -f -- "$0")")" && pwd)"

git_root=$(git -C "$repo" rev-parse --show-toplevel)
timestamp_start=$(date -u +%Y-%m-%dT%H-%M-%SZ)
session_start_time="$timestamp_start"
# Stage 2: cleaner start-time field. Use date +%s.%N for sub-second
# precision (supported on macOS and Linux) so duration_seconds in
# capture-task-finish.sh is accurate, not just integer seconds. The
# .%N fractional component is parsed as a decimal in capture-task-finish.sh.
start_unix_seconds=$(date -u +%s.%N)
start_time="$timestamp_start"
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
# Stage 2.5: 8 new hermes context env vars
hermes_session_id="${HERMES_SESSION_ID:-}"
hermes_session_chat_id="${HERMES_SESSION_CHAT_ID:-}"
hermes_session_platform="${HERMES_SESSION_PLATFORM:-unknown}"
hermes_home="${HERMES_HOME:-}"
hermes_webui_state_dir="${HERMES_WEBUI_STATE_DIR:-}"
hermes_kanban_board="${HERMES_KANBAN_BOARD:-}"
hermes_interactive="null"
if [[ "${HERMES_INTERACTIVE:-}" == "1" ]]; then
  hermes_interactive="true"
elif [[ "${HERMES_INTERACTIVE:-}" == "0" ]]; then
  hermes_interactive="false"
fi
# Stage 2.6: 11 hermes_orchestrator_* vars passed from the wrapper
hermes_orchestrator_session_id="${HERMES_ORCHESTRATOR_SESSION_ID:-}"
hermes_orchestrator_model="${HERMES_ORCHESTRATOR_MODEL:-}"
hermes_orchestrator_model_provider="${HERMES_ORCHESTRATOR_MODEL_PROVIDER:-}"
hermes_orchestrator_profile="${HERMES_ORCHESTRATOR_PROFILE:-}"
hermes_orchestrator_source_label="${HERMES_ORCHESTRATOR_SOURCE_LABEL:-unavailable}"
hermes_orchestrator_is_cli_session="${HERMES_ORCHESTRATOR_IS_CLI_SESSION:-false}"
hermes_orchestrator_workspace="${HERMES_ORCHESTRATOR_WORKSPACE:-}"
hermes_orchestrator_worktree_path="${HERMES_ORCHESTRATOR_WORKTREE_PATH:-null}"
hermes_orchestrator_reasoning_level="${HERMES_ORCHESTRATOR_REASONING_LEVEL:-unavailable}"
hermes_orchestrator_reasoning_level_source="${HERMES_ORCHESTRATOR_REASONING_LEVEL_SOURCE:-unavailable}"
hermes_orchestrator_reasoning_level_raw="${HERMES_ORCHESTRATOR_REASONING_LEVEL_RAW:-}"
hermes_orchestrator_capture_source="${HERMES_ORCHESTRATOR_CAPTURE_SOURCE:-none}"

# Stage 2.6: resolve orchestrator metadata from session JSON if not provided
# via env vars (e.g., when capture-task-start.sh is called directly).
if [[ -z "${HERMES_ORCHESTRATOR_SESSION_ID:-}" ]]; then
  resolve_hermes_orchestrator_metadata
fi

# hermes_capture_source: "env" if any HERMES_* env is non-empty, else "none"
hermes_capture_source="none"
if [[ -n "${HERMES_SESSION_ID:-}" || -n "${HERMES_SESSION_CHAT_ID:-}" || -n "${HERMES_SESSION_PLATFORM:-}" || -n "${HERMES_HOME:-}" || -n "${HERMES_WEBUI_STATE_DIR:-}" || -n "${HERMES_KANBAN_BOARD:-}" || -n "${HERMES_EXECUTABLE_PATH:-}" || -n "${HERMES_VERSION:-}" || -n "${HERMES_PROFILE:-}" || -n "${HERMES_MEMORY_MODE:-}" || -n "${HERMES_MEMORY_ENABLED:-}" || -n "${HERMES_USER_PROFILE_ENABLED:-}" || -n "${HERMES_INTERACTIVE:-}" ]]; then
  hermes_capture_source="env"
fi
model="${MODEL:-${OPENCODE_MODEL:-unknown}}"
reasoning_level="${REASONING_LEVEL:-}"

# Stage 2 Card 3: task_type env-var passthrough.
# Allowed values (case-insensitive, normalized to lowercase, trimmed):
#   implementation, debugging, review, docs, investigation,
#   refactor, validation, architecture.
# bash-portable case-insensitive "value in indexed array" check.
# Replaces zsh's ${array[(Ie)value]} subscript flag. Returns 0
# (success/true) when the lowercased needle is found in the
# lowercased haystack, 1 otherwise. The caller is expected to have
# already lowercased the needle (we do that for task_type above).
_opencodebench_task_type_in_list() {
  local needle="$1"
  local _att
  for _att in "${allowed_task_types[@]}"; do
    if [[ "${_att,,}" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

# Missing/empty: task_type="unspecified" (do not crash, do not warn).
# Unknown value: record the raw value AND warn to stderr (do not coerce).
# This is a fail-loud design — bad data is worse than no data only when
# you don't notice. The set is intentionally small and explicit so the
# taxonomy is easy to slice on.
allowed_task_types=(
  implementation debugging review docs investigation
  refactor validation architecture
)
task_type_raw="${OPENCODEBENCH_TASK_TYPE:-}"
task_type=""
task_type_status="unset"
if [[ -n "$task_type_raw" ]]; then
  task_type="$(printf '%s' "$task_type_raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
  if [[ -z "$task_type" ]]; then
    # Whitespace-only input — treat like unset, not like an unknown value.
    task_type="unspecified"
    task_type_status="empty"
  elif _opencodebench_task_type_in_list "$task_type"; then
    task_type_status="valid"
  else
    # Unknown value: keep the raw (lowercased) value so downstream
    # analysis can see what was attempted, and warn loudly.
    printf '%s\n' "Warning: OPENCODEBENCH_TASK_TYPE='$task_type_raw' (normalized: '$task_type') is not in the allowed set." >&2
    printf '%s\n' "Allowed values: ${allowed_task_types[*]}" >&2
    printf '%s\n' "Recording the raw value verbatim; downstream analysis should treat this as unknown." >&2
    task_type_status="unknown"
  fi
else
  task_type="unspecified"
fi
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
  # bash equivalent of zsh's "${var:A}" — canonical absolute path. Guarded
  # so a non-existent or already-relative path still produces a useful
  # result rather than crashing readlink.
  log_root="$(readlink -f -- "${OPENCODEBENCH_LOG_ROOT}" 2>/dev/null || printf '%s' "${OPENCODEBENCH_LOG_ROOT}")"
else
  log_root="$(default_log_root "$script_dir")"
fi
task_dir="$log_root/$year/$month/$task_id"
if [[ -n "${OPENCODEBENCH_LOG_ROOT:-}" ]]; then
  validate_log_root_override "$log_root" "$task_dir/metadata.json"
fi
opencodebench_task_dir="$task_dir"
opencodebench_git_commit_before="$git_head_before"
# Stage 2: nest timing fields under opencodebench.timing so the top-level
# metadata.json keeps the Stage 1 additive shape. start_unix_seconds is a
# number (--argjson) so duration_seconds in capture-task-finish.sh can do
# numeric subtraction without parsing a stringified float.
opencodebench_start_unix_seconds="$start_unix_seconds"

mkdir -p "$task_dir"

if [[ -n "$prompt_file" ]]; then
  cp "$prompt_file" "$task_dir/task.md"
else
  {
    printf '%s\n' "# OpenCodeBench Session"
    printf '%s\n' ""
    printf '%s\n' "No startup prompt was provided. This session was captured from a normal OpenCode launch."
  } > "$task_dir/task.md"
fi

printf '%s\n' "$git_head_before" > "$task_dir/git-head-before.txt"
printf '%s\n' "$git_branch_before" > "$task_dir/git-branch-before.txt"
git -C "$git_root" status --short > "$task_dir/git-status-before.txt"
git -C "$git_root" diff > "$task_dir/git-diff-before.patch"
git -C "$git_root" diff --stat > "$task_dir/git-diff-stat-before.txt"
git -C "$git_root" diff --numstat > "$task_dir/git-diff-numstat-before.txt"
git_status_before=$(git -C "$git_root" status --short)

# Stage 2.5: resolve Hermes user prompt
resolve_hermes_user_prompt

# Stage 2.5: worker prompt from the wrapper env (set by opencodebench-opencode)
worker_prompt="${OPENCODEBENCH_WORKER_PROMPT:-}"
worker_prompt_source="unavailable"
if [[ -n "$worker_prompt" ]]; then
  worker_prompt_source="argv"
fi

# Stage 2.5: write sidecar files and compute hashes
hermes_user_prompt_path=""
hermes_user_prompt_sha256=""
hermes_user_prompt_chars=0
if [[ "$hermes_user_prompt_source" != "unavailable" && -n "$hermes_user_prompt_text" ]]; then
  printf '%s' "$hermes_user_prompt_text" > "$task_dir/hermes_user_prompt.md"
  hermes_user_prompt_path="hermes_user_prompt.md"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    hermes_user_prompt_sha256=$(shasum -a 256 "$task_dir/hermes_user_prompt.md" | awk '{print $1}')
  else
    hermes_user_prompt_sha256=$(sha256sum "$task_dir/hermes_user_prompt.md" | awk '{print $1}')
  fi
  hermes_user_prompt_chars=$(wc -c < "$task_dir/hermes_user_prompt.md" | tr -d ' ')
fi

worker_prompt_path=""
worker_prompt_sha256=""
worker_prompt_chars=0
if [[ "$worker_prompt_source" != "unavailable" && -n "$worker_prompt" ]]; then
  printf '%s' "$worker_prompt" > "$task_dir/worker_prompt.md"
  worker_prompt_path="worker_prompt.md"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    worker_prompt_sha256=$(shasum -a 256 "$task_dir/worker_prompt.md" | awk '{print $1}')
  else
    worker_prompt_sha256=$(sha256sum "$task_dir/worker_prompt.md" | awk '{print $1}')
  fi
  worker_prompt_chars=$(wc -c < "$task_dir/worker_prompt.md" | tr -d ' ')
fi

jq -n \
  --arg task_id "$task_id" \
  --arg timestamp "$timestamp_start" \
  --arg timestamp_start "$timestamp_start" \
  --arg session_start_time "$session_start_time" \
  --arg start_time "$start_time" \
  --argjson opencodebench_start_unix_seconds "$opencodebench_start_unix_seconds" \
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
  --arg task_type "$task_type" \
  --arg task_type_status "$task_type_status" \
  --arg task_type_raw "$task_type_raw" \
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
  --arg hermes_session_id "$hermes_session_id" \
  --arg hermes_session_chat_id "$hermes_session_chat_id" \
  --arg hermes_session_platform "$hermes_session_platform" \
  --arg hermes_home "$hermes_home" \
  --arg hermes_webui_state_dir "$hermes_webui_state_dir" \
  --arg hermes_kanban_board "$hermes_kanban_board" \
  --argjson hermes_interactive "$hermes_interactive" \
  --arg hermes_capture_source "$hermes_capture_source" \
  --arg hermes_user_prompt_source "$hermes_user_prompt_source" \
  --arg hermes_user_prompt_path "$hermes_user_prompt_path" \
  --arg hermes_user_prompt_sha256 "$hermes_user_prompt_sha256" \
  --argjson hermes_user_prompt_chars "$hermes_user_prompt_chars" \
  --arg worker_prompt_source "$worker_prompt_source" \
  --arg worker_prompt_path "$worker_prompt_path" \
  --arg worker_prompt_sha256 "$worker_prompt_sha256" \
  --argjson worker_prompt_chars "$worker_prompt_chars" \
  --arg hermes_orchestrator_session_id "$hermes_orchestrator_session_id" \
  --arg hermes_orchestrator_model "$hermes_orchestrator_model" \
  --arg hermes_orchestrator_model_provider "$hermes_orchestrator_model_provider" \
  --arg hermes_orchestrator_profile "$hermes_orchestrator_profile" \
  --arg hermes_orchestrator_source_label "$hermes_orchestrator_source_label" \
  --argjson hermes_orchestrator_is_cli_session "$hermes_orchestrator_is_cli_session" \
  --arg hermes_orchestrator_workspace "$hermes_orchestrator_workspace" \
  --arg hermes_orchestrator_worktree_path "$hermes_orchestrator_worktree_path" \
  --arg hermes_orchestrator_reasoning_level "$hermes_orchestrator_reasoning_level" \
  --arg hermes_orchestrator_reasoning_level_source "$hermes_orchestrator_reasoning_level_source" \
  --arg hermes_orchestrator_reasoning_level_raw "$hermes_orchestrator_reasoning_level_raw" \
  --arg hermes_orchestrator_capture_source "$hermes_orchestrator_capture_source" \
  '{
    task_id: $task_id,
    timestamp: $timestamp,
    timestamp_start: $timestamp_start,
    session_start_time: $session_start_time,
    start_time: $start_time,
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
    task_type: $task_type,
    task_type_status: $task_type_status,
    task_type_raw: (if $task_type_raw == "" then null else $task_type_raw end),
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
    hermes_session_id: $hermes_session_id,
    hermes_session_chat_id: $hermes_session_chat_id,
    hermes_session_platform: $hermes_session_platform,
    hermes_home: $hermes_home,
    hermes_webui_state_dir: $hermes_webui_state_dir,
    hermes_kanban_board: $hermes_kanban_board,
    hermes_interactive: $hermes_interactive,
    hermes_capture_source: $hermes_capture_source,
    hermes_user_prompt_source: $hermes_user_prompt_source,
    hermes_user_prompt_path: (if $hermes_user_prompt_path == "" then null else $hermes_user_prompt_path end),
    hermes_user_prompt_sha256: (if $hermes_user_prompt_sha256 == "" then null else $hermes_user_prompt_sha256 end),
    hermes_user_prompt_chars: $hermes_user_prompt_chars,
    worker_prompt_source: $worker_prompt_source,
    worker_prompt_path: (if $worker_prompt_path == "" then null else $worker_prompt_path end),
    worker_prompt_sha256: (if $worker_prompt_sha256 == "" then null else $worker_prompt_sha256 end),
    worker_prompt_chars: $worker_prompt_chars,
    hermes_orchestrator_session_id: $hermes_orchestrator_session_id,
    hermes_orchestrator_model: $hermes_orchestrator_model,
    hermes_orchestrator_model_provider: $hermes_orchestrator_model_provider,
    hermes_orchestrator_profile: $hermes_orchestrator_profile,
    hermes_orchestrator_source_label: $hermes_orchestrator_source_label,
    hermes_orchestrator_is_cli_session: $hermes_orchestrator_is_cli_session,
    hermes_orchestrator_workspace: $hermes_orchestrator_workspace,
    hermes_orchestrator_worktree_path: (if $hermes_orchestrator_worktree_path == "" or $hermes_orchestrator_worktree_path == "null" then null else $hermes_orchestrator_worktree_path end),
    hermes_orchestrator_reasoning_level: $hermes_orchestrator_reasoning_level,
    hermes_orchestrator_reasoning_level_source: $hermes_orchestrator_reasoning_level_source,
    hermes_orchestrator_reasoning_level_raw: (if $hermes_orchestrator_reasoning_level_raw == "" then null else $hermes_orchestrator_reasoning_level_raw end),
    hermes_orchestrator_capture_source: $hermes_orchestrator_capture_source,
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
      git_commit_before: $opencodebench_git_commit_before,
      task_type: $task_type,
      task_type_status: $task_type_status,
      timing: {
        start_unix_seconds: $opencodebench_start_unix_seconds
      },
      orchestrator: {
        session_id: $hermes_orchestrator_session_id,
        model: $hermes_orchestrator_model,
        model_provider: $hermes_orchestrator_model_provider,
        profile: $hermes_orchestrator_profile,
        source_label: $hermes_orchestrator_source_label,
        is_cli_session: $hermes_orchestrator_is_cli_session,
        workspace: $hermes_orchestrator_workspace,
        worktree_path: (if $hermes_orchestrator_worktree_path == "" or $hermes_orchestrator_worktree_path == "null" then null else $hermes_orchestrator_worktree_path end),
        reasoning_level: $hermes_orchestrator_reasoning_level,
        reasoning_level_source: $hermes_orchestrator_reasoning_level_source,
        reasoning_level_raw: (if $hermes_orchestrator_reasoning_level_raw == "" then null else $hermes_orchestrator_reasoning_level_raw end),
        capture_source: $hermes_orchestrator_capture_source
      },
      trace: {
        hermes_user_prompt: (if $hermes_user_prompt_source == "unavailable" then null else {
          source: $hermes_user_prompt_source,
          sha256: $hermes_user_prompt_sha256,
          chars: $hermes_user_prompt_chars,
          sidecar: $hermes_user_prompt_path
        } end),
        worker_prompt: (if $worker_prompt_source == "unavailable" then null else {
          source: $worker_prompt_source,
          sha256: $worker_prompt_sha256,
          chars: $worker_prompt_chars,
          sidecar: $worker_prompt_path
        } end)
      }
    }
  }' > "$task_dir/metadata.json"

printf '%s\n' "$task_dir"
