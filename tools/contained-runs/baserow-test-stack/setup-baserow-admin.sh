#!/usr/bin/env bash
set -euo pipefail

secrets_file="/home/hermes/.config/contained-runs/secrets.env"
mkdir -p "$(dirname "$secrets_file")"
chmod 700 "$(dirname "$secrets_file")"

python3 - <<'PY'
import json
import os
import secrets
import string
import sys
import urllib.error
import urllib.request
from pathlib import Path

secrets_path = Path('/home/hermes/.config/contained-runs/secrets.env')
host_base = 'http://127.0.0.1:18080'
worker_base = 'http://baserow:80'
admin_email_default = 'contained-runs-admin@localhost.localdomain'
bench_names = ['hsk1_design_gpt55_low', 'hsk1_design_gpt55_medium']
production_name = 'Learn Chinese Like A Baby'


def load_env(path):
    data = {}
    if path.exists():
        for line in path.read_text(encoding='utf-8').splitlines():
            line = line.strip()
            if not line or line.startswith('#') or '=' not in line:
                continue
            k, v = line.split('=', 1)
            data[k] = v
    return data


def save_env(path, data):
    ordered = [
        'OPENAI_API_KEY',
        'LANGFUSE_PUBLIC_KEY',
        'LANGFUSE_SECRET_KEY',
        'LANGFUSE_BASE_URL',
        'BASEROW_BASE_URL',
        'BASEROW_HOST_BASE_URL',
        'BASEROW_ADMIN_EMAIL',
        'BASEROW_ADMIN_PASSWORD',
        'BASEROW_ADMIN_TOKEN',
    ]
    lines = []
    for k in ordered:
        if k in data and data[k] != '':
            lines.append(f'{k}={data[k]}')
    for k in sorted(data):
        if k not in ordered and data[k] != '':
            lines.append(f'{k}={data[k]}')
    tmp = path.with_suffix('.tmp')
    tmp.write_text('\n'.join(lines) + ('\n' if lines else ''), encoding='utf-8')
    os.chmod(tmp, 0o600)
    tmp.replace(path)
    os.chmod(path, 0o600)


def generate_password():
    alphabet = string.ascii_letters + string.digits + '-_=+.,:;@#%'
    return ''.join(secrets.choice(alphabet) for _ in range(40))


def request(method, url, token=None, payload=None):
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = f'JWT {token}'
    body = None if payload is None else json.dumps(payload).encode('utf-8')
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
            return r.status, json.loads(raw.decode('utf-8') or '{}') if raw else {}
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            parsed = json.loads(raw.decode('utf-8') or '{}')
        except Exception:
            parsed = {}
        return e.code, parsed


def get_token(email, pw):
    status, body = request('POST', f'{host_base}/api/user/token-auth/', payload={'email': email, 'password': pw})
    token = body.get('token') or body.get('access')
    if status == 200 and token:
        return token
    return None

env = load_env(secrets_path)
env['BASEROW_BASE_URL'] = worker_base
env['BASEROW_HOST_BASE_URL'] = host_base
if not env.get('BASEROW_ADMIN_EMAIL'):
    env['BASEROW_ADMIN_EMAIL'] = admin_email_default
if not env.get('BASEROW_ADMIN_PASSWORD'):
    env['BASEROW_ADMIN_PASSWORD'] = generate_password()
save_env(secrets_path, env)

email = env['BASEROW_ADMIN_EMAIL']
pw = env['BASEROW_ADMIN_PASSWORD']

token = get_token(email, pw)
created_admin = False
if not token:
    status, body = request('POST', f'{host_base}/api/user/', payload={
        'name': 'Contained Runs Admin',
        'email': email,
        'password': pw,
        'language': 'en',
        'authenticate': True,
    })
    token = body.get('token') or body.get('access')
    created_admin = bool(status in (200, 201) and token)

if not token:
    token = get_token(email, pw)
if not token:
    print('admin_setup: login_failed_or_existing_admin_unknown')
    sys.exit(3)

status, workspaces_body = request('GET', f'{host_base}/api/workspaces/', token=token)
if status != 200:
    print('api_login: failed')
    sys.exit(4)
print('api_login: verified')

workspaces = workspaces_body if isinstance(workspaces_body, list) else workspaces_body.get('results', [])
existing_ws = {w.get('name'): w for w in workspaces if isinstance(w, dict)}
print('production_target: present_untouched' if production_name in existing_ws else 'production_target: absent_untouched')

for name in bench_names:
    ws = existing_ws.get(name)
    if not ws:
        status, ws = request('POST', f'{host_base}/api/workspaces/', token=token, payload={'name': name})
        if status != 200:
            print(f'{name}: workspace_create_failed')
            sys.exit(5)
    ws_id = ws.get('id')
    status, apps_body = request('GET', f'{host_base}/api/applications/workspace/{ws_id}/', token=token)
    if status != 200:
        print(f'{name}: applications_list_failed')
        sys.exit(6)
    apps = apps_body if isinstance(apps_body, list) else apps_body.get('results', [])
    db_exists = any(a.get('name') == name and a.get('type') == 'database' for a in apps if isinstance(a, dict))
    if not db_exists:
        status, _ = request('POST', f'{host_base}/api/applications/workspace/{ws_id}/', token=token, payload={'name': name, 'type': 'database', 'init_with_data': False})
        if status != 200:
            print(f'{name}: database_create_failed')
            sys.exit(7)
    print(f'{name}: ready')

print('admin_setup: created' if created_admin else 'admin_setup: verified')
PY
