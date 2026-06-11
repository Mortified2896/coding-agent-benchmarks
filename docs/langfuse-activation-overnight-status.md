# Langfuse activation — final state (Hermes → Langfuse verified)

**Status as of:** this commit.

**Outcome:** Hermes → Langfuse tracing is working end to end and
the operator has confirmed trace visibility in the Langfuse UI.
This note replaces the earlier "blocked on operator" version and
records the verified configuration for future operators.

## What was done (chronology)

1. **Langfuse Python SDK installed** in the Hermes venv at
   `/home/hermes/.hermes/hermes-agent/venv/`:
   - `langfuse-4.7.1` plus its required OTel stack
     (`opentelemetry-api-1.42.1`,
     `opentelemetry-sdk-1.42.1`,
     `opentelemetry-exporter-otlp-proto-common-1.42.1`,
     `opentelemetry-exporter-otlp-proto-http-1.42.1`,
     `opentelemetry-proto-1.42.1`,
     `opentelemetry-semantic-conventions-0.63b1`,
     `wrapt-1.17.3`, `backoff-2.2.1`).
   - Installed via the in-venv pip:
     `/home/hermes/.hermes/hermes-agent/venv/bin/pip install langfuse`.
   - Verified: `python -c 'import langfuse'` resolves to
     `…/venv/lib/python3.11/site-packages/langfuse/__init__.py`.
   - The system Python and the OpenCode binary are unaffected.

2. **`/etc/hermes/hermes.env` populated by the operator.**
   - File created with `root:hermes` ownership and `0640` perms
     so the service user `hermes` (member of the `hermes` group)
     can read the file via its group bit.
   - Three lines set:
     - `HERMES_LANGFUSE_PUBLIC_KEY` (42 chars, starts `pk-`)
     - `HERMES_LANGFUSE_SECRET_KEY` (42 chars, starts `sk-`)
     - `HERMES_LANGFUSE_BASE_URL` (`https://cloud.langfuse.com`,
       26 chars, scheme `https`, netloc `cloud.langfuse.com`)
   - **No values were ever printed, echoed, or committed.** The
     file is mode `0640 root:hermes` and lives in `/etc/hermes`
     (`root:root 0750`). The current agent session verified only
     *names* and *value-shape* (length and prefix), never values.
   - **No edits from the agent session to this file.** The agent
     does not have write access (user `hermes` is not in group
     `root`).

3. **`hermes-agent.service` restarted by the operator.**
   - New `Main PID` is `22693` (was `20105` before the restart).
   - `ActiveEnterTimestamp` is `~08:11:08 UTC`, ~80s after the
     env file mtime. Clean causal order: env written first,
     then restart, then service picked up the new
     `EnvironmentFile`.
   - **The agent did not run `systemctl restart`.** The agent
     session has `NoNewPrivileges=1` and is not authorized to
     run privileged commands at all.

4. **Hermes → Langfuse trace verified by the operator in the
   Langfuse UI.** The test session
   `20260611_081521_a9fa28` (prompt `Reply with the single word:
   pong`, model reply `pong`, 13s) is the session the operator
   confirmed seeing in the UI.

5. **Plugin left enabled throughout.** `plugins.enabled` in
   `~/.hermes/config.yaml` still contains
   `observability/langfuse`, and `hermes plugins list` still
   shows the row as `enabled · 1.0.0`.

## Local-evidence summary from the agent session

The agent session could not see the Langfuse UI, so the local
evidence is *consistent with* successful init, not a proof of
successful export. Specifically:

| Check | Result | What it means |
|---|---|---|
| Three `HERMES_LANGFUSE_*` names in `/etc/hermes/hermes.env` | present (3/3) | env file is populated |
| Three `HERMES_LANGFUSE_*` names in `/proc/22693/environ` | present (3/3) | service picked up the new `EnvironmentFile` |
| Plugin `langfuse · enabled · 1.0.0` in `hermes plugins list` | yes | plugin is registered and not disabled |
| `Plugin discovery complete: 38 found, 33 enabled` in `agent.log` | yes | plugin load step completed without error |
| `Could not initialize Langfuse client: …` warning in any log | **absent** | the `try/except` around `Langfuse(**kwargs)` did not catch |
| Placeholder-detection warning (`credentials look like placeholders…`) in any log | **absent** | the keys pass the `pk-lf-` / `sk-lf-` prefix check |
| `Invalid HERMES_LANGFUSE_SAMPLE_RATE` warning | **absent** | the optional sample-rate env var is not set (or is valid) |
| `hermes chat -q "Reply with the single word: pong"` | session `20260611_081521_a9fa28`, 13s, model reply `pong` | a real LLM call landed; the `pre_llm_call` / `post_llm_call` hooks were the only way a Langfuse trace could have been emitted for this session |
| OpenCode benchmark capture (`opencodebench-opencode ... run "pong"`) | exit 0, 9.6s, new task log at `.local/coding-agent-task-logs/2026/06/2026-06-11T08-22-42Z-opencode-coding-agent-benchmarks` | the benchmark capture path is unaffected by the Langfuse activation |

The plugin's success path is **silent by design** — `_debug()`
only logs when `HERMES_LANGFUSE_DEBUG=true` is set. So "no log
lines about Langfuse" is *expected* on a successful run, not a
warning sign.

## Safety recap (what was deliberately not done)

* No `sudo` invocation from the agent session.
* No `setpriv`, `sg`, `newgrp`, or any other privilege
  workaround.
* No edit to `/etc/hermes/hermes.env`, the systemd unit, or any
  other root-owned file.
* No `systemctl restart hermes-agent.service` from the agent
  session.
* No `hermes plugins disable` — the Langfuse plugin is still
  enabled.
* No edits to `~/.hermes/config.yaml` or `~/.hermes/.env`.
* No Langfuse key values were ever read, generated, written, or
  echoed. The agent verified only the *names* and the
  *value-shape* (length, prefix, scheme, netloc).
* No provider / model / auth configuration was changed.

## If you want to debug a missing trace in the future

These are the failure modes, in order of probability, for
"Hermes → Langfuse was working yesterday but the trace is not
in the UI today":

1. **Wrong project / wrong key.** Most common. The
   `HERMES_LANGFUSE_PUBLIC_KEY` in `/etc/hermes/hermes.env` may
   point to a different Langfuse project than the one being
   inspected. Cross-check the public-key prefix against the
   project's "API Keys" page.
2. **Network egress blocked.** The VM cannot reach
   `cloud.langfuse.com` on 443. The plugin would silently drop
   traces. A non-root check from a developer shell:
   `curl -fsS --max-time 10 https://cloud.langfuse.com/api/public/health`.
   If that fails, the SDK cannot export.
3. **Key revoked.** A stale `pk-lf-…` / `sk-lf-…` pair causes
   the SDK to silently drop on every export. Check the
   project's API Keys page.
4. **`HERMES_LANGFUSE_SAMPLE_RATE=0`.** Intentional or typo.
   Would have produced a `logger.warning("Invalid
   HERMES_LANGFUSE_SAMPLE_RATE=%r", …)` line — that warning did
   not fire, so this is unlikely.
5. **Silent OTel exporter flush failure.** The OTel SDK uses
   batched background export; on a hard exit traces are
   dropped. Not a config issue — the operational fix is to
   call `langfuse.flush()` before any process exit, or to set
   `OTEL_BSP_SCHEDULE_DELAY` shorter. Out of scope for this
   activation, flagged for follow-up.

For local-only debug, set `HERMES_LANGFUSE_DEBUG=true` in
`/etc/hermes/hermes.env`, restart the service, run a `chat
-q`, and look for `Langfuse tracing: …` lines in
`agent.log`. That requires a service restart (operator step)
and an env-file edit (operator step) and is documented here
for completeness, not executed.

## Cross-references

* Older "what is missing" inventory, useful for understanding
  the original failure mode: `docs/langfuse-debian-vm-status.md`.
* The OpenCode → Langfuse follow-up investigation (the next
  phase of the plan): this is the live work in
  `Phase 2` / `Phase 3` of the current brief, and (if it
  results in changes) a new doc will be added or the analysis
  prep note `docs/opencodebench-task-log-analysis-prep.md`
  will be amended.
* The capture-path fix that unblocked the rest of the
  Debian-readiness work: commit `2d7aecb` (bash portability
  for `capture-task-start.sh`).
* The planning-docs batch this note was written alongside of:
  commit `770b10d` ("Add planning docs for Langfuse, Hermes
  capture, and analysis").
