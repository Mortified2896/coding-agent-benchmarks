#!/usr/bin/env bash
set -euo pipefail

source_file="/etc/hermes/hermes.env"
secrets_file="/home/hermes/.config/contained-runs/secrets.env"
secrets_dir="$(dirname -- "$secrets_file")"

mkdir -p "$secrets_dir"
chmod 700 "$secrets_dir" 2>/dev/null || true

python3 - <<'PY'
import os
from pathlib import Path

source_path = Path('/etc/hermes/hermes.env')
secrets_path = Path('/home/hermes/.config/contained-runs/secrets.env')

# Only these values may be copied from /etc/hermes/hermes.env into the
# worker env-file. Do not broaden this list without a security review.
DIRECT_ALLOWLIST = [
    'OPENAI_API_KEY',
    'MINIMAX_API_KEY',
    'MINIMAX_BASE_URL',
    'MINIMAX_GROUP_ID',
]
MAPPED_ALLOWLIST = {
    'HERMES_LANGFUSE_PUBLIC_KEY': ['LANGFUSE_PUBLIC_KEY'],
    'HERMES_LANGFUSE_SECRET_KEY': ['LANGFUSE_SECRET_KEY'],
    'HERMES_LANGFUSE_BASE_URL': ['LANGFUSE_BASE_URL', 'LANGFUSE_BASEURL'],
}
PRESERVE_PREFIXES = ('BASEROW_',)
ORDER = [
    'OPENAI_API_KEY',
    'MINIMAX_API_KEY',
    'MINIMAX_BASE_URL',
    'MINIMAX_GROUP_ID',
    'LANGFUSE_PUBLIC_KEY',
    'LANGFUSE_SECRET_KEY',
    'LANGFUSE_BASE_URL',
    'LANGFUSE_BASEURL',
    'BASEROW_BASE_URL',
    'BASEROW_HOST_BASE_URL',
    'BASEROW_ADMIN_EMAIL',
    'BASEROW_ADMIN_PASSWORD',
    'BASEROW_ADMIN_TOKEN',
]
REPORT_NAMES = [
    'OPENAI_API_KEY',
    'MINIMAX_API_KEY',
    'MINIMAX_BASE_URL',
    'MINIMAX_GROUP_ID',
    'LANGFUSE_PUBLIC_KEY',
    'LANGFUSE_SECRET_KEY',
    'LANGFUSE_BASE_URL',
    'LANGFUSE_BASEURL',
    'BASEROW_BASE_URL',
    'BASEROW_HOST_BASE_URL',
    'BASEROW_ADMIN_EMAIL',
    'BASEROW_ADMIN_PASSWORD',
    'BASEROW_ADMIN_TOKEN',
]


def parse_env(path):
    data = {}
    if not path.exists():
        return data
    with path.open('r', encoding='utf-8', errors='replace') as f:
        for raw in f:
            line = raw.rstrip('\n')
            stripped = line.strip()
            if not stripped or stripped.startswith('#') or '=' not in stripped:
                continue
            key, value = stripped.split('=', 1)
            if key and key.replace('_', '').isalnum() and key[0].isalpha():
                data[key] = value
    return data


def status(path):
    if not path.exists():
        return 'missing'
    try:
        with path.open('r', encoding='utf-8', errors='replace'):
            pass
        return 'readable'
    except PermissionError:
        return 'not_readable'
    except OSError:
        return 'not_readable'

existing = parse_env(secrets_path)
source = parse_env(source_path) if status(source_path) == 'readable' else {}

out = {}
# Preserve only Baserow state from the generated worker env file.
for key, value in existing.items():
    if key.startswith(PRESERVE_PREFIXES) and value:
        out[key] = value

# Copy direct provider values from the source of truth only.
for key in DIRECT_ALLOWLIST:
    if source.get(key):
        out[key] = source[key]

# Map Hermes-host Langfuse names to worker/plugin names.
for src, targets in MAPPED_ALLOWLIST.items():
    if source.get(src):
        for target in targets:
            out[target] = source[src]

secrets_path.parent.mkdir(parents=True, exist_ok=True)
tmp = secrets_path.with_suffix('.tmp')
lines = []
for key in ORDER:
    if out.get(key):
        lines.append(f'{key}={out[key]}')
for key in sorted(out):
    if key not in ORDER and out.get(key):
        lines.append(f'{key}={out[key]}')
tmp.write_text('\n'.join(lines) + ('\n' if lines else ''), encoding='utf-8')
os.chmod(tmp, 0o600)
tmp.replace(secrets_path)
os.chmod(secrets_path, 0o600)

print(f'source_file: {status(source_path)}')
print('secrets.env: synced')
for name in REPORT_NAMES:
    print(f'{name}: {"set" if out.get(name) else "missing"}')
PY
