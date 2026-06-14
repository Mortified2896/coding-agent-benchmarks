#!/usr/bin/env bash
set -euo pipefail
printf 'This removes the persistent local throwaway Baserow container and volume, not production data outside this stack.
' >&2
if command -v podman >/dev/null 2>&1; then
  podman rm -f contained-runs-baserow >/dev/null 2>&1 || true
  podman volume rm contained_runs_baserow_data >/dev/null 2>&1 || true
  printf 'Reset contained-runs Baserow stack
'
else
  printf 'podman: missing
' >&2
  exit 2
fi
