# Persistent local Baserow service for contained runs

V1 intentionally uses one persistent local Baserow instance on the Hermes VM.
This is a practical compromise: it is weaker isolation than one Baserow instance per run, but much easier to inspect, reuse, and debug.

Target databases/workspaces:
- Production: `Learn Chinese Like A Baby`
- Benchmark A: `hsk1_design_gpt55_low`
- Benchmark B: `hsk1_design_gpt55_medium`

Benchmark runs must never target the production database unless explicitly approved. `run-contained-task.sh --baserow-database "Learn Chinese Like A Baby"` refuses by default.

## Network model

The Baserow container is:
- bound on the VM host at `http://127.0.0.1:18080`
- attached to a dedicated Podman network named `contained-runs-baserow`
- reachable by worker containers on that network at `http://baserow:80`

Do not rely on `127.0.0.1` from inside worker containers. Inside a worker container, localhost is the worker itself, not the Baserow container.

## Start once

```bash
tools/contained-runs/baserow-test-stack/start-baserow-test.sh
```

## Verify worker reachability

```bash
tools/contained-runs/baserow-test-stack/check-baserow-worker-reachability.sh
```

## Stop without deleting data

```bash
tools/contained-runs/baserow-test-stack/stop-baserow-test.sh
```

## Reset throwaway local Baserow state

```bash
tools/contained-runs/baserow-test-stack/reset-baserow-test.sh
```

Reset removes the local container and volume used by this harness. Do not run it if you put anything valuable in this local stack.

## Secrets

Keep credentials outside the repo in `/home/hermes/.config/contained-runs/secrets.env` or Podman secrets. Do not commit admin passwords or API tokens.
