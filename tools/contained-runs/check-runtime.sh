#!/usr/bin/env bash
set -euo pipefail

mac_install_cmd="ssh -t -J proxmox-home hermes@10.10.10.80 'sudo apt-get update && sudo apt-get install -y podman'"
found=0
preferred=""

if command -v podman >/dev/null 2>&1; then
  found=1
  preferred="podman"
  printf 'podman: available\n'
  podman --version || true
else
  printf 'podman: missing\n'
fi

if command -v docker >/dev/null 2>&1; then
  found=1
  if [[ -z "$preferred" ]]; then preferred="docker"; fi
  printf 'docker: available\n'
  docker --version || true
else
  printf 'docker: missing\n'
fi

if [[ "$found" -eq 0 ]]; then
  printf 'preferred_runtime: missing\n'
  printf 'install_command: %s\n' "$mac_install_cmd"
  exit 2
fi

printf 'preferred_runtime: %s\n' "$preferred"
