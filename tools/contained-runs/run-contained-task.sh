#!/usr/bin/env bash
set -euo pipefail

harness_version="0.1.0"
usage() { cat >&2 <<'USAGE'
Usage: run-contained-task.sh --task <task-folder> --run <run-name> --model <model-name> --reasoning <reasoning-level> --command <command> [--network|--baserow-network] [--baserow-database <name>] [--allow-production-baserow]
USAGE
exit 64; }

task=""; run=""; model=""; reasoning=""; cmd=""; network=0; baserow_network=0; baserow_database=""; allow_production=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) task="${2:-}"; shift 2 ;;
    --run) run="${2:-}"; shift 2 ;;
    --model) model="${2:-}"; shift 2 ;;
    --reasoning) reasoning="${2:-}"; shift 2 ;;
    --command) cmd="${2:-}"; shift 2 ;;
    --network) network=1; shift ;;
    --baserow-network) baserow_network=1; shift ;;
    --baserow-database) baserow_database="${2:-}"; shift 2 ;;
    --allow-production-baserow) allow_production=1; shift ;;
    *) usage ;;
  esac
done
[[ -n "$task" && -n "$run" && -n "$model" && -n "$reasoning" && -n "$cmd" ]] || usage
[[ -d "$task/input" ]] || { printf 'Missing task input dir: %s/input\n' "$task" >&2; exit 1; }
if [[ "$baserow_database" == "Learn Chinese Like A Baby" && "$allow_production" -ne 1 ]]; then
  printf 'Refusing to target production Baserow database without --allow-production-baserow: %s\n' "$baserow_database" >&2
  exit 65
fi

runtime=""
if command -v podman >/dev/null 2>&1; then runtime=podman
elif command -v docker >/dev/null 2>&1; then runtime=docker
else
  /bin/bash "$(dirname "$0")/check-runtime.sh" || true
  exit 2
fi

repo_root=$(git -C "$(dirname "$0")/../.." rev-parse --show-toplevel 2>/dev/null || pwd)
git_commit_before=$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || printf 'unknown')
abs_task=$(cd "$task" && pwd)
input_dir="$abs_task/input"
output_dir="$abs_task/runs/$run"
mkdir -p "$output_dir"
abs_output=$(cd "$output_dir" && pwd)
start_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
metadata_tmp=$(mktemp)
secrets_file="/home/hermes/.config/contained-runs/secrets.env"

runtime_args=(run --rm --security-opt no-new-privileges --cap-drop ALL -v "$input_dir:/benchmark/input:ro" -v "$abs_output:/benchmark/output:rw" -w /benchmark/output)
if [[ "$baserow_network" -eq 1 ]]; then
  if ! "$runtime" network exists contained-runs-baserow >/dev/null 2>&1; then
    printf 'Missing Podman network: contained-runs-baserow. Start Baserow test stack first.\n' >&2
    exit 2
  fi
  runtime_args+=(--network contained-runs-baserow -e BASEROW_BASE_URL=http://baserow:80)
elif [[ "$network" -eq 1 ]]; then
  runtime_args+=(--network bridge)
else
  runtime_args+=(--network none)
fi
if [[ -n "$baserow_database" ]]; then
  runtime_args+=(-e "BASEROW_DATABASE_NAME=$baserow_database")
fi
if [[ -f "$secrets_file" ]]; then
  chmod go-rwx "$secrets_file" 2>/dev/null || true
  runtime_args+=(--env-file "$secrets_file")
fi
# Use a tiny public shell image by default. The command may invoke mounted scripts or installed tools in custom images in future.
image="docker.io/library/alpine:3.20"

set +e
"$runtime" "${runtime_args[@]}" "$image" /bin/sh -lc "$cmd"
exit_code=$?
set -e
end_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
python3 - "$metadata_tmp" <<PY
import json, sys
path=sys.argv[1]
data={
  "run_name": "$run",
  "task_path": "$abs_task",
  "model": "$model",
  "reasoning": "$reasoning",
  "harness_version": "$harness_version",
  "start_time_utc": "$start_time",
  "end_time_utc": "$end_time",
  "exit_code": $exit_code,
  "container_runtime": "$runtime",
  "git_commit_before": "$git_commit_before"
}
open(path,'w',encoding='utf-8').write(json.dumps(data, indent=2, sort_keys=True)+"\n")
PY
mv "$metadata_tmp" "$abs_output/metadata.json"
exit "$exit_code"
