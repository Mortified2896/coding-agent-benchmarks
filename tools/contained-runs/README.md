# Contained comparison runs

This harness runs benchmark tasks with a narrow filesystem view so model and workflow comparisons are less dependent on prompt-only discipline.

## What it does

`run-contained-task.sh` starts a minimal container with:
- task input mounted read-only at `/benchmark/input`
- only one run output mounted writable at `/benchmark/output`
- no repo-root mount
- no `~/.hermes`, `~/.ssh`, GitHub config, sibling run outputs, or unrelated workspace directories mounted

It records non-secret run metadata in the run output.

## What is isolated

Isolated in v1:
- filesystem visibility is limited to the task input and the selected run output
- sibling outputs are not mounted
- network is disabled by default
- Linux capabilities are dropped and no-new-privileges is requested

Not fully isolated in v1:
- the container runtime itself is trusted
- `--network` allows outbound network access when the task needs APIs
- env-file secrets, if enabled, are visible to the process inside the container
- Baserow v1 uses one persistent local service with separate production and benchmark databases/workspaces

## Secrets

Secrets are read from `/home/hermes/.config/contained-runs/secrets.env` when present. The harness never writes secret values to metadata. `check-secrets.sh` prints only set/missing.

Create the file safely on the VM, not in this repo:

```bash
mkdir -p /home/hermes/.config/contained-runs
chmod 700 /home/hermes/.config/contained-runs
$EDITOR /home/hermes/.config/contained-runs/secrets.env
chmod 600 /home/hermes/.config/contained-runs/secrets.env
```

Example variable names only; do not paste real values into repo docs or prompts:

```bash
OPENAI_API_KEY=...
LANGFUSE_PUBLIC_KEY=...
LANGFUSE_SECRET_KEY=...
LANGFUSE_BASE_URL=...
BASEROW_BASE_URL=...
BASEROW_ADMIN_EMAIL=...
BASEROW_ADMIN_PASSWORD=...
```

## Create the HSK 1 task

```bash
tools/contained-runs/create-task.sh --task tasks/baserow-hsk1-design
```

## Baserow admin/API setup

Set up or verify the local Baserow admin account and benchmark targets:

```bash
tools/contained-runs/baserow-test-stack/setup-baserow-admin.sh
```

The script writes required Baserow connection variables to `/home/hermes/.config/contained-runs/secrets.env`, creates the admin only when needed, verifies API login without printing tokens, and creates/verifies the benchmark workspaces plus database applications:

- `hsk1_design_gpt55_low`
- `hsk1_design_gpt55_medium`

It does not create or modify `Learn Chinese Like A Baby`.

## OpenCode worker smoke test

This verifies that the contained worker can install/run the OpenCode CLI in a Node container and write only to `/benchmark/output`. It does not call a model and does not create the real Baserow schema:

```bash
tools/contained-runs/run-opencode-smoke.sh
```

## Run low vs medium comparison

Network is disabled unless `--network` or `--baserow-network` is passed. Use network access only when the command must call OpenAI, Baserow, or Langfuse.

Small/Low example:

```bash
tools/contained-runs/run-contained-task.sh \
  --task tasks/baserow-hsk1-design \
  --run gpt55-small \
  --model gpt-5.5 \
  --reasoning low \
  --baserow-network \
  --baserow-database hsk1_design_gpt55_low \
  --command 'printf "%s\n" "Read /benchmark/input/task.md and write required outputs to /benchmark/output" > implementation_notes.md'
```

Medium example:

```bash
tools/contained-runs/run-contained-task.sh \
  --task tasks/baserow-hsk1-design \
  --run gpt55-medium \
  --model gpt-5.5 \
  --reasoning medium \
  --baserow-network \
  --baserow-database hsk1_design_gpt55_medium \
  --command 'printf "%s\n" "Read /benchmark/input/task.md and write required outputs to /benchmark/output" > implementation_notes.md'
```

The Worker containers should use `BASEROW_BASE_URL=http://baserow:80` when started with `--baserow-network`; do not use 127.0.0.1 inside workers. The harness also sets `BASEROW_HOST_HEADER=127.0.0.1:18080` for Baserow API calls because the persistent local Baserow service is configured with the host public URL. The `--command` is intentionally explicit so future comparisons can swap model CLIs, prompts, or agent workflows without changing the containment layer.

## Compare outputs

Review:
- `tasks/baserow-hsk1-design/runs/gpt55-small/metadata.json`
- `tasks/baserow-hsk1-design/runs/gpt55-small/schema_spec.md`
- `tasks/baserow-hsk1-design/runs/gpt55-small/implementation_notes.md`
- `tasks/baserow-hsk1-design/runs/gpt55-small/baserow_result.md`
- matching files under `gpt55-medium`

Use `tasks/baserow-hsk1-design/input/rubric.md` as the scoring guide and place evaluator notes under `tasks/baserow-hsk1-design/evaluation/`.

## Known limitations

- v1 uses an Alpine shell image for generic commands. Model-specific CLI images or wrappers can be added later.
- Env-file secrets are process environment variables inside the run container; use Podman secrets later if a run needs stronger secret handling.
- The persistent Baserow stack depends on Podman and keeps local state in the `contained_runs_baserow_data` volume.
- The harness records the requested model/reasoning, not proof that a provider actually used that model. The command should write its own provider evidence without secrets.

## Baserow database names

Use these names for this benchmark family:
- Production: `Learn Chinese Like A Baby`
- Low reasoning benchmark: `hsk1_design_gpt55_low`
- Medium reasoning benchmark: `hsk1_design_gpt55_medium`

The harness refuses `--baserow-database "Learn Chinese Like A Baby"` unless `--allow-production-baserow` is passed. Do not pass that flag for benchmark runs.
