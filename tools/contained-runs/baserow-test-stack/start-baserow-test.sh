#!/usr/bin/env bash
set -euo pipefail
runtime=""
if command -v podman >/dev/null 2>&1; then runtime=podman
elif command -v docker >/dev/null 2>&1; then runtime=docker
else
  printf 'No container runtime found. Run tools/contained-runs/check-runtime.sh for setup guidance.
' >&2
  exit 2
fi
if [[ "$runtime" != "podman" ]]; then
  printf 'Docker fallback is available, but this persistent Baserow setup is currently Podman-network oriented. Prefer Podman.
' >&2
  exit 2
fi
$runtime network exists contained-runs-baserow >/dev/null 2>&1 || $runtime network create contained-runs-baserow >/dev/null
if $runtime container exists contained-runs-baserow >/dev/null 2>&1; then
  $runtime start contained-runs-baserow >/dev/null
else
  $runtime run -d \
    --name contained-runs-baserow \
    --network contained-runs-baserow \
    --network-alias baserow \
    -p 127.0.0.1:18080:80 \
    -v contained_runs_baserow_data:/baserow/data:Z \
    -e BASEROW_PUBLIC_URL=http://127.0.0.1:18080 \
    -e BASEROW_EXTRA_ALLOWED_HOSTS=baserow \
    docker.io/baserow/baserow:1.30.1 >/dev/null
fi
printf 'Baserow container: contained-runs-baserow
'
printf 'Host URL: http://127.0.0.1:18080
'
printf 'Worker URL on Podman network contained-runs-baserow: http://baserow:80
'
