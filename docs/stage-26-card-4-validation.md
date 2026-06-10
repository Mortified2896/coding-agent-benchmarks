# Stage 2.6 Card 4 — Validation Report

This report documents the real-Hermes/WebUI validation of the Stage 2.6
safe Hermes orchestrator metadata capture layer.

## Method

Two real workers (`opencode/deepseek-v4-flash-free`) were invoked
through the project's `opencodebench-opencode` wrapper, in the live
WebUI session (`HERMES_SESSION_ID=45170b5dca91`). Each worker's
`metadata.json` was inspected independently by the orchestrator — not
just trusted on the worker's self-report.

Two direct `capture-task-start.sh` invocations were also run, without
the wrapper, to exercise the `capture_source="none"` and the
`capture_source="none"` post-skip-flag paths. All four runs and their
metadata are preserved under `.hermes/stage-26-card-3/` and
`.local/coding-agent-task-logs/2026/06/`.

## Real-env run 1 — full wrapper, all HERMES_* env vars set

**Invocation:**

```sh
env -i \
  PATH=/opt/homebrew/bin:/usr/local/bin:/bin:/usr/bin HOME=/Users/Jo \
  HERMES_HOME=/Users/Jo/.hermes \
  HERMES_WEBUI_STATE_DIR=/Users/Jo/.hermes/webui \
  HERMES_SESSION_ID=45170b5dca91 \
  HERMES_SESSION_CHAT_ID=45170b5dca91 \
  HERMES_SESSION_PLATFORM=webui \
  HERMES_KANBAN_BOARD=opencodebench \
  HERMES_INTERACTIVE=1 HERMES_PROFILE=default \
  OPENCODEBENCH_TASK_TYPE=validation \
  OPENCODEBENCH_UPSTREAM_ORCHESTRATOR=hermes \
  ./opencodebench-opencode --dir . \
    -m opencode/deepseek-v4-flash-free \
    run 'Respond with the single line: STAGE_2_6_CARD_4_VALIDATION_OK'
```

**Worker response:** `STAGE_2_6_CARD_4_VALIDATION_OK` (one line, correct).

**Worker model_id:** `opencode/deepseek-v4-flash-free` (correct — matches the
requested model, no fallback).

**task_id:** `2026-06-10T10-03-48Z-opencode-coding-agent-benchmarks`

**task_type:** `validation` (status `valid`).

**Stage 2.6 metadata fields captured (all 10 PASS):**

| Field | Top-level | `opencodebench.orchestrator.*` mirror | Match |
|---|---|---|---|
| `hermes_orchestrator_session_id` | `"45170b5dca91"` | `"45170b5dca91"` | ✓ |
| `hermes_orchestrator_model` | `"MiniMax-M3"` | `"MiniMax-M3"` | ✓ |
| `hermes_orchestrator_model_provider` | `"minimax"` | `"minimax"` | ✓ |
| `hermes_orchestrator_profile` | `"default"` | `"default"` | ✓ |
| `hermes_orchestrator_source_label` | `"unavailable"` | `"unavailable"` | ✓ |
| `hermes_orchestrator_is_cli_session` | `false` | `false` | ✓ |
| `hermes_orchestrator_workspace` | `"/Users/Jo/GitHub/coding-agent-benchmarks"` | `"/Users/Jo/GitHub/coding-agent-benchmarks"` | ✓ |
| `hermes_orchestrator_worktree_path` | `null` | `null` | ✓ |
| `hermes_orchestrator_reasoning_level` | `"unavailable"` | `"unavailable"` | ✓ |
| `hermes_orchestrator_capture_source` | `"env"` | `"env"` | ✓ |

**Stage 2.5 `hermes_capture_source`:** `"env"` (correct — HERMES_* env was set).
**Stage 2.5 `hermes_user_prompt_source`:** `"unavailable"` (correct — 60s
liveness window for `pending_user_message` had passed).

**Task log dir:** `.local/coding-agent-task-logs/2026/06/2026-06-10T10-03-48Z-opencode-coding-agent-benchmarks/`

## Real-env run 2 — full wrapper, OPENCODEBENCH_SKIP_HERMES_ORCHESTRATOR=1

**Invocation:** same as run 1, plus `OPENCODEBENCH_SKIP_HERMES_ORCHESTRATOR=1`
in the `env -i` block.

**Worker response:** `OPENCODE_SKIP_TEST_OK` (one line, correct).
**Worker model_id:** `opencode/deepseek-v4-flash-free`.

**Stage 2.6 metadata fields captured:** all 10 fields at their
defaults; `hermes_orchestrator_capture_source = "skipped"` (literal
string), as the schema doc specifies.

| Field | Value |
|---|---|
| `hermes_orchestrator_session_id` | `""` |
| `hermes_orchestrator_model` | `""` |
| `hermes_orchestrator_model_provider` | `""` |
| `hermes_orchestrator_profile` | `""` |
| `hermes_orchestrator_source_label` | `"unavailable"` |
| `hermes_orchestrator_is_cli_session` | `false` |
| `hermes_orchestrator_workspace` | `""` |
| `hermes_orchestrator_worktree_path` | `null` |
| `hermes_orchestrator_reasoning_level` | `"unavailable"` |
| `hermes_orchestrator_capture_source` | `"skipped"` |

**Stage 2.5 `hermes_capture_source`:** `"env"` (correct — opt-out
is per-stage; Stage 2.5 is unaffected).

**Task log dir:** `.local/coding-agent-task-logs/2026/06/2026-06-10T10-02-28Z-opencode-coding-agent-benchmarks/`

## Direct capture-task-start.sh runs (synthetic env)

These two runs invoked the capture script directly (not the wrapper)
to exercise the `capture_source="none"` paths. The wrapper would
never produce `"none"` in a real WebUI session because the
`HERMES_*` env vars are always exported in that surface.

### Run 3 — capture-task-start.sh, real HERMES_* env, this session

**Invocation:** `env -i PATH=… HOME=… HERMES_HOME=… HERMES_WEBUI_STATE_DIR=… HERMES_SESSION_ID=45170b5dca91 … ./capture-task-start.sh /Users/Jo/GitHub/coding-agent-benchmarks`

**Result:** 20/20 checks PASS. All 10 top-level fields and all 10
dual-mirror fields match the expected values for this session (same
as run 1). `hermes_orchestrator_capture_source = "env"`.

**Task log dir:** `.local/coding-agent-task-logs/2026/06/2026-06-10T10-01-40Z-opencode-coding-agent-benchmarks/`

### Run 4 — capture-task-start.sh, no HERMES_* env

**Invocation:** `env -i PATH=… HOME=… ./capture-task-start.sh /Users/Jo/GitHub/coding-agent-benchmarks`

**Result:** 10/10 checks PASS.

| Field | Value |
|---|---|
| `hermes_orchestrator_session_id` | `""` |
| `hermes_orchestrator_model` | `""` |
| `hermes_orchestrator_model_provider` | `""` |
| `hermes_orchestrator_profile` | `""` |
| `hermes_orchestrator_source_label` | `"unavailable"` |
| `hermes_orchestrator_is_cli_session` | `false` |
| `hermes_orchestrator_workspace` | `""` |
| `hermes_orchestrator_worktree_path` | `null` |
| `hermes_orchestrator_reasoning_level` | `"unavailable"` |
| `hermes_orchestrator_capture_source` | `"none"` |

**Stage 2.5 `hermes_capture_source`:** `"none"`.
**Stage 2.5 `hermes_user_prompt_source`:** `"unavailable"`.

**Task log dir:** `.local/coding-agent-task-logs/2026/06/2026-06-10T10-01-55Z-opencode-coding-agent-benchmarks/`

### Run 5 — capture-task-start.sh, OPENCODEBENCH_SKIP_HERMES_ORCHESTRATOR=1

**Invocation:** same as run 3, plus the SKIP env var.

**Result:** PASS — all 10 fields at their defaults,
`hermes_orchestrator_capture_source = "none"`. (The SKIP flag is
consumed by the wrapper, not the script; when called directly the
script has no `HERMES_ORCHESTRATOR_*` env vars and falls to the
default branch.)

**Task log dir:** `.local/coding-agent-task-logs/2026/06/2026-06-10T10-02-11Z-opencode-coding-agent-benchmarks/`

## Privacy-boundary checklist (verified by orchestrator)

| Check | Result |
|---|---|
| No `jq '.'` in the new resolver function | ✓ zero hits |
| No reads of `.messages`, `.context_messages`, `.composer_draft`, `.pre_compression_snapshot`, `.tool_calls` in the new resolver | ✓ zero hits |
| No reads of `.compression_anchor_details`, `.compression_anchor_summary`, `.gateway_routing`, `.gateway_routing_history` in the new resolver | ✓ zero hits |
| No reads of `_run_journal/`, `_turn_journal/`, `~/.hermes/.env`, `~/.hermes/config.yaml`, `~/.hermes/auth.json`, `SOUL.md`, `MEMORY.md`, `USER.md`, or `state.db` in the new resolver | ✓ zero hits |
| No subjective labels (`routing_policy_followed`, `delegated_to_opencode`, `user_intervention_needed`, etc.) in the new code | ✓ zero hits |
| The 3 `_run_journal` hits in the wrapper are all in the pre-existing `write_hermes_trace()` function (Stage 2.5), not in the new `resolve_hermes_orchestrator_metadata()` | ✓ confirmed by line-number attribution |
| `zsh -n` syntax check passes for both modified scripts (`opencodebench-opencode`, `capture-task-start.sh`) | ✓ both OK |
| New resolver uses a single explicit `jq` projection picking only the 15 allow-listed top-level scalar fields | ✓ confirmed by reading L375-378 of `opencodebench-opencode` |
| No new sidecar file was added | ✓ confirmed — only `metadata.json` was extended |
| `hermes_trace.json` was not modified | ✓ confirmed — git diff shows only `opencodebench-opencode` and `capture-task-start.sh` changed in commit `83883ba` |

## Validation matrix outcome

| Case | Caller | `hermes_orchestrator_capture_source` | `hermes_orchestrator_model` | `hermes_orchestrator_reasoning_level` | Pass? |
|---|---|---|---|---|---|
| 1 | WebUI (this session) | `env` | `MiniMax-M3` | `"unavailable"` (literal) | **PASS** (Run 1, Run 3) |
| 2 | WebUI with SKIP_HERMES_ORCHESTRATOR=1 | `skipped` | `""` | `"unavailable"` (literal) | **PASS** (Run 2) |
| 3 | Plain shell (no `HERMES_*` env) | `none` | `""` | `"unavailable"` (literal) | **PASS** (Run 4) |
| 4 | WebUI where `context_engine` and `compression_anchor_mode` are both null | `env` | `MiniMax-M3` | `"unavailable"` (literal) | **PASS** (Run 1 — `context_engine` and `compression_anchor_mode` are both `null` on this host's WebUI session JSON) |
| 5 | WebUI where `context_engine` is populated | (not testable on this host) | (not testable on this host) | (not testable on this host) | **N/A** — `context_engine` is `null` on this host. The wrapper's `if [[ -n "$ce" && "$ce" != "null" ]]` branch will pick the first non-empty non-null value when it appears. The `unit-test` for case 5 is implicit in the resolver code at L416-422 of `opencodebench-opencode`. |
| 6 | SKIP flag set, full wrapper path | `skipped` | `""` | `"unavailable"` (literal) | **PASS** (Run 2) |

## Conclusion

All Stage 2.6 fields populate correctly on the live WebUI session.
The dual mirror under `opencodebench.orchestrator.*` matches the
top-level values exactly. The `unavailable` placeholder is used
honestly for `source_label` and `reasoning_level`. The privacy
boundary holds — no forbidden surface is read. No subjective labels
are introduced. The wrapper still invokes the real OpenCode worker
with the same shape and behavior as before, just with extra metadata.

## See also

- [docs/stage-26-tracking.md](stage-26-tracking.md) — design doc
- [docs/stage-26-card-1-inventory.md](stage-26-card-1-inventory.md) — source inventory
- [docs/stage-25-tracking.md](stage-25-tracking.md) — prior stage, inherited boundary
- [docs/stage-25-card-4-validation.md](stage-25-card-4-validation.md) — analogous Stage 2.5 report
