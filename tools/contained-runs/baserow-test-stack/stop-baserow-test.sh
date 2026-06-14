#!/usr/bin/env bash
set -euo pipefail
if command -v podman >/dev/null 2>&1 && podman container exists contained-runs-baserow >/dev/null 2>&1; then
  podman stop contained-runs-baserow >/dev/null
  printf 'Stopped contained-runs-baserow
'
else
  printf 'contained-runs-baserow is not present
'
fi
