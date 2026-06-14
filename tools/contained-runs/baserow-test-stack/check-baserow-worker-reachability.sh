#!/usr/bin/env bash
set -euo pipefail
if ! command -v podman >/dev/null 2>&1; then
  printf 'podman: missing\n' >&2
  exit 2
fi
if ! podman network exists contained-runs-baserow >/dev/null 2>&1; then
  printf 'contained-runs-baserow network: missing\n' >&2
  exit 2
fi
# Baserow can return 404/redirects for unauthenticated paths while still proving
# DNS and TCP reachability. Treat any HTTP response from http://baserow:80 as
# worker-to-Baserow reachability; do not print headers that could contain cookies.
out=$(podman run --rm --network contained-runs-baserow docker.io/library/alpine:3.20 /bin/sh -lc 'wget -S -T 20 -O /dev/null http://baserow:80/ 2>&1 || true')
if printf '%s\n' "$out" | grep -Eq 'HTTP/[0-9.]+ [0-9]{3}'; then
  printf 'worker_to_baserow: reachable\n'
else
  printf 'worker_to_baserow: not reachable\n' >&2
  exit 1
fi
