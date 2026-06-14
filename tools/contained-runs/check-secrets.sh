#!/usr/bin/env bash
set -euo pipefail

secrets_file="/home/hermes/.config/contained-runs/secrets.env"
required_provider=(OPENAI_API_KEY)
required_langfuse=(LANGFUSE_PUBLIC_KEY LANGFUSE_SECRET_KEY LANGFUSE_BASE_URL)
baserow_optional=(BASEROW_BASE_URL BASEROW_HOST_BASE_URL BASEROW_ADMIN_EMAIL BASEROW_ADMIN_PASSWORD BASEROW_ADMIN_TOKEN)

if [[ -f "$secrets_file" ]]; then
  printf 'secrets.env: exists\n'
  set -a
  # shellcheck disable=SC1090
  source "$secrets_file"
  set +a
else
  printf 'secrets.env: missing\n'
fi

status=0
check_var() {
  local name="$1" fatal="$2"
  if [[ -n "${!name:-}" ]]; then
    printf '%s: set\n' "$name"
  else
    printf '%s: missing\n' "$name"
    if [[ "$fatal" == "fatal" ]]; then status=1; fi
  fi
}

for v in "${required_provider[@]}"; do check_var "$v" fatal; done
for v in "${required_langfuse[@]}"; do check_var "$v" fatal; done
for v in "${baserow_optional[@]}"; do check_var "$v" nonfatal; done

exit "$status"
