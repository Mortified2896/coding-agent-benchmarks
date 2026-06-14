#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname -- "$0")" && pwd)"
repo_root="$(git -C "$script_dir/../.." rev-parse --show-toplevel)"

"$script_dir/run-contained-task.sh" \
  --task "$repo_root/tasks/baserow-hsk1-design" \
  --run gpt55-small \
  --model gpt-5.5 \
  --reasoning low \
  --image docker.io/library/node:22-alpine \
  --baserow-network \
  --baserow-database hsk1_design_gpt55_low \
  --command 'test "$BASEROW_BASE_URL" = http://baserow:80 && test "$BASEROW_DATABASE_NAME" = hsk1_design_gpt55_low && npm_config_cache=/tmp/npm-cache npx -y opencode-ai@latest --version >/tmp/opencode-version.txt && printf "opencode-worker-smoke-ok\n" > /benchmark/output/opencode_smoke.txt'
