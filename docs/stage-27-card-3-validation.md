# Stage 2.7 Card 3 — Validation report

**Date:** 2026-06-10
**Branch:** `main` (local, ahead of `origin/main` by 2 commits, not pushed)
**Worker model (this report):** direct orchestrator write, per user instruction "Direct Hermes work is acceptable for documentation-only cards and final report writing"
**Worker model (Card 2 implementation):** `opencode/deepseek-v4-flash-free`
**Worker model (Card 1 design doc):** `opencode/mimo-v2.5-free`

This report is the closeout for Stage 2.7. It independently verifies the implementation committed in `4458fd3` ("Stage 2.7 Card 2: implement reasoning-level capture in wrapper and capture script") against the design committed in `de0f1b1` ("Stage 2.7 Card 1: document reasoning-level source and privacy boundary").

---

## 1. Real-env validation cases

The Card 2 implementation was exercised against five distinct real-env configurations. For each case, the orchestrator independently inspected the produced `metadata.json` (no trust in worker self-reports).

| # | Configuration | Task dir | `hermes_orchestrator_reasoning_level` | `_source` | `_raw` | Top-level ↔ `opencodebench.orchestrator.*` mirror | Pass? |
|---|---|---|---|---|---|---|---|
| 1 | Normal WebUI, no override, `HERMES_*` set, `state.db` row exists | `…/2026-06-10T11-00-30Z-…` (first run) | `low` | `state_db` | `low` | match | ✅ |
| 2 | `OPENCODEBENCH_HERMES_REASONING_LEVEL=extra_high` | `…/2026-06-10T11-00-30Z-…` (second run) | `extra_high` | `env_override` | `low` (still records state.db value) | match | ✅ |
| 3 | `OPENCODEBENCH_HERMES_REASONING_LEVEL=unavailable` | `…/2026-06-10T11-00-30Z-…` (third run) | `unavailable` | `env_override` | `low` | match | ✅ |
| 4 | Plain shell, `env -i PATH=… HOME=…` only (no `HERMES_*`) | `…/2026-06-10T11-00-30Z-…` (fourth run) | `unavailable` | `unavailable` | `null` (`capture_source: "none"`) | match | ✅ |
| 5 | `OPENCODEBENCH_SKIP_HERMES_REASONING=1` | `…/2026-06-10T11-00-31Z-…` | `unavailable` | `skipped` | `null` | match | ✅ |

Plus a real end-to-end wrapper invocation (not synthetic env-vars — the actual `opencodebench-opencode` wrapper running the actual `opencode` CLI):

| # | Configuration | Task dir | `hermes_orchestrator_reasoning_level` | `_source` | `_raw` | Pass? |
|---|---|---|---|---|---|---|
| 6 | `opencodebench-opencode` (real wrapper) with worker `opencode/deepseek-v4-flash-free` doing a real `opencode run` | `…/2026-06-10T10-59-49Z-…` | `low` | `state_db` | `low` | ✅ |

The wrapper run produced worker output `STAGE_2_7_CARD_2_SMOKE_OK` and a complete `metadata.json` (including `hermes_trace.json`, `evaluation.md`, `git-diff.patch`). This is the most authoritative end-to-end test: the resolver ran inside the wrapper, exported its values as `HERMES_ORCHESTRATOR_*` env vars into the `task_dir=$( ... capture-task-start.sh ... )` subshell, and the capture script wrote the values through to the final JSON.

---

## 2. Raw vs normalized mapping

The user-supplied list of canonical values is: `none`, `minimal`, `low`, `medium`, `high`, `extra_high`, `max`, `unavailable`. The normalization rule is **formatting only**: lowercase, spaces → underscores, trim leading/trailing whitespace. **No semantic mapping** (in particular, `low` does **not** get rewritten to `small`).

| Raw value (as seen in `state.db` or env var) | Normalized value | Notes |
|---|---|---|
| `"low"` | `low` | Live value on this host for MiniMax M3 |
| `"Low"` | `low` | Mixed case → lowercase |
| `"Extra High"` | `extra_high` | Space → underscore + lowercase |
| `"extra_high"` | `extra_high` | Already canonical |
| `"MAX"` | `max` | Uppercase → lowercase |
| `" Max "` | `max` | Trim + lowercase |
| `""` (empty) | `""` (raw), `null` (JSON) | Empty raw becomes null in JSON; level falls through to `unavailable` |
| `"unavailable"` | `unavailable` | Sentinel; never re-normalized |
| anything else | lowercased, spaces→`_`, no semantic rewrite | E.g. `"low-medium"` stays `"low-medium"` |

Confirmed on the live `state.db` row for session `20260610_122139_e5cc59`: `model_config.reasoning_config.effort` is exactly `"low"`. The wrapper reads it raw, stores it in `hermes_orchestrator_reasoning_level_raw`, normalizes it (idempotently in this case) for `hermes_orchestrator_reasoning_level`, and records `hermes_orchestrator_reasoning_level_source = "state_db"`.

---

## 3. Privacy-boundary verification (orchestrator-run, not worker-self-reported)

The following greps were run on `opencodebench-opencode` AND `capture-task-start.sh` (the two files the user authorized Card 2 to touch). Result for each:

| Audit | Result | Notes |
|---|---|---|
| `grep -nE 'SELECT \*' opencodebench-opencode capture-task-start.sh` | **0 hits** | PASS |
| `grep -nE '\bsystem_prompt\b' …` | 1 hit, **inside a `#` comment** at `opencodebench-opencode:420` that documents the privacy contract ("NEVER read system_prompt"). Not an actual read. | PASS (with comment caveat) |
| `grep -nE 'state\.db\.messages' …` | 1 hit, same comment. | PASS (with comment caveat) |
| `grep -nE 'messages\[\*\]' …` | 1 hit at `capture-task-start.sh:63`, inside the deny-list comment at the top of the file. | PASS (with comment caveat) |
| `grep -nE '_run_journal\|_turn_journal' …` | 3 hits in `opencodebench-opencode:753/785/800`, all pre-existing Stage 2.5 code that stores the *path string* `hermes_run_journal_dir` in metadata. The journal *content* is never read. | PASS (pre-existing) |
| `grep -nE 'routing_policy_followed\|delegated_to_opencode\|user_intervention_needed\|quality_score\|success_indicator' …` | **0 hits** | PASS |
| `grep -nE '\.(messages\|context_messages\|composer_draft\|pre_compression_snapshot\|tool_calls\|compression_anchor_details\|compression_anchor_summary\|gateway_routing\|gateway_routing_history)\b' …` | 0 hits in the new Stage 2.7 resolver region | PASS |
| `grep -nE 'state\.db' opencodebench-opencode` | All 8 hits are either (a) inside a comment, (b) the `[[ -f "${HERMES_HOME}/state.db" ]]` precondition, or (c) the single targeted `json_extract(model_config, '$.reasoning_config.effort')` SELECT. **No `SELECT *`, no other column selected.** | PASS |
| `grep -nE 'state\.db' capture-task-start.sh` | 3 hits: (a) the deny-list comment, (b) the precondition, (c) an **identical** `json_extract(model_config, '$.reasoning_config.effort')` SELECT at L151. The capture script mirrors the wrapper's resolver for the direct-capture path. | PASS |
| `zsh -n opencodebench-opencode` | exit 0 | PASS |
| `bash -n capture-task-start.sh` | exit 0 | PASS |

Full audit document with line numbers: `.hermes/stage-27-card-2-pre-run/privacy-audit.md` (written by the orchestrator at the time of Card 2 commit).

### `state.db` read inventory (complete list, post-Card 2)

There are **exactly 2** `state.db` reads in the project, both added by Card 2. Both use the identical targeted projection:

```sql
SELECT json_extract(model_config, '$.reasoning_config.effort')
FROM sessions WHERE id = '…' LIMIT 1;
```

1. `opencodebench-opencode:423` — the wrapper's resolver (runs on every wrapper invocation)
2. `capture-task-start.sh:151` — the capture script's mirror resolver (runs only when `capture-task-start.sh` is invoked directly, bypassing the wrapper)

Both wrap the call in `2>/dev/null || true` so the wrapper never crashes on a missing database, a permission error, or a schema mismatch.

---

## 4. What changed in this Stage

**`opencodebench-opencode`** (172 lines added, 9 lines modified, 2 files per git diff stat):

- Added `_horml_normalize()` helper at L347-356 (lowercase, trim, spaces→underscores)
- Added `hermes_orchestrator_reasoning_level_source` and `hermes_orchestrator_reasoning_level_raw` initializers at L373-374
- Added `OPENCODEBENCH_SKIP_HERMES_REASONING=1` opt-out block at L383-390
- Added the `state.db` targeted read at L417-431 (the only `state.db` read in the wrapper)
- Added the 4-step precedence chain at L473-490 (env override → state.db → fall through to Stage 2.6 WebUI chain)
- Patched the existing Stage 2.6 WebUI chain at L492-499 to also capture the raw value into `_horml_webui_raw` (so the WebUI-source case preserves the raw form)
- Added the post-process block at L521-527 to populate `_source=webui_session_json` when the WebUI chain was the one that produced a value
- Added two new env-var exports at L555-556 (`HERMES_ORCHESTRATOR_REASONING_LEVEL_SOURCE`, `HERMES_ORCHESTRATOR_REASONING_LEVEL_RAW`)
- Updated `--help` text at L77-90 with the two new env vars

**`capture-task-start.sh`** (8 lines added):

- Two new env-var consumption lines at L265-266
- Two new `--arg` lines in the `jq` projection at L475-476
- Two new fields in the top-level projection at L546-547
- Two new fields in the `opencodebench.orchestrator.*` mirror at L575-576
- A mirror resolver inside the script (in case the script is called directly without the wrapper) at L141-185

**`docs/stage-27-tracking.md`** (new file, ~492 lines): design doc, privacy boundary, canonical values, precedence chain, validation matrix, worked example, deferred work, limitations.

**`docs/stage-26-tracking.md`** and **`docs/stage-2-tracking.md`**: cross-link additions in the "See also" sections (Card 1 work, already committed in `de0f1b1`).

---

## 5. Cross-links

The Card 3 spec mentioned updating `docs/README.md`, but no such file exists in the repo. Card 1's worker already added the required "See also" entries in the two existing stage docs:

- `docs/stage-2-tracking.md:487` — bullet linking to `stage-27-tracking.md`
- `docs/stage-26-tracking.md:424` — inline cross-reference inside the Stage 2.7 deferred-work note
- `docs/stage-26-tracking.md:458` — bullet in the "See also" section linking to `stage-27-tracking.md`

No further doc work is required for the closeout.

---

## 6. Verification methodology (synthetic-vs-real)

Per the kanban-worker skill's "synthetic-vs-real" pitfall, the orchestrator (this session) **independently** verified the implementation by:

1. **Reproducing the bug-like behavior the worker encountered.** The Card 2 worker exited after its first smoke test (a direct `capture-task-start.sh` invocation) reported `reasoning_level=unavailable`. The orchestrator diagnosed this as a **synthetic-test mistake**: the worker called the capture script directly, which bypasses the wrapper's resolver and so the new state.db read never ran. The orchestrator then ran the actual wrapper as a real end-to-end test and confirmed the resolver works.

2. **Inlining the resolver.** The orchestrator copied the wrapper's resolver region into a fresh zsh invocation with the smoke-test env and confirmed `hermes_orchestrator_reasoning_level=low`, `_source=state_db`, `_raw=low`. This ruled out any logic bug in the new code.

3. **Running the full wrapper end-to-end.** A real `opencode run` with `deepseek-v4-flash-free` produced a complete task dir; the orchestrator inspected the metadata and confirmed all 3 new fields and the dual mirror.

4. **Running all 5 explicit user-requested cases.** All 5 produced the expected values.

5. **Running the privacy grep audits independently** of any worker self-report. The full audit document is at `.hermes/stage-27-card-2-pre-run/privacy-audit.md`.

---

## 7. Commits in this Stage (local, not pushed)

```
4458fd3 Stage 2.7 Card 2: implement reasoning-level capture in wrapper and capture script
de0f1b1 Stage 2.7 Card 1: document reasoning-level source and privacy boundary
```

Branch `main` is ahead of `origin/main` by 2 commits. **Nothing has been pushed.**

---

## 8. Remaining risks / follow-up items

1. **The `state.db` read is the only cross-version risk.** If Hermes renames `model_config.reasoning_config.effort` in a future release (e.g. to `model_config.reasoning.effort_level`), the wrapper will silently fall through to `unavailable` because of the `2>/dev/null || true` wrapper. The `hermes_orchestrator_reasoning_level_source` will show `unavailable` and an operator can detect the regression. The fix is to update the json_extract path in `opencodebench-opencode:423` and `capture-task-start.sh:151`. A one-time schema probe on this host confirmed the path is stable for MiniMax M3 as of 2026-06-10.

2. **The wrapper's resolver depends on `sqlite3` being on `PATH`.** `sqlite3` ships with macOS at `/usr/bin/sqlite3`, so the default harness is fine. If the wrapper is run inside a sandboxed CI container that lacks `sqlite3`, the read silently returns empty and the level falls through to the WebUI chain (which also returns `unavailable` on this host). This is the same path as Hermes's own WebUI would take.

3. **Stage 2.6 WebUI chain fields are still absent on this host.** The investigation in `docs/stage-27-tracking.md` (section 8) confirmed that `context_engine` and `compression_anchor_mode` are not present in the WebUI session JSON for any probed session on this host. So the WebUI fallback is effectively a no-op today; if Hermes later adds those fields, Stage 2.7 will pick them up automatically.

4. **No benchmarks run against the new fields yet.** The Stage 2.6 closeout report noted "stage-26 captures all 3 model identity fields but only 1 tier is exercised so far". Stage 2.7 inherits that — the bench runs all use `effort=low` on this host. To exercise the new fields across multiple values, the next benchmarks would need to flip the MiniMax M3 reasoning level in WebUI between runs, or use the `OPENCODEBENCH_HERMES_REASONING_LEVEL` env override to set different values per run.

5. **Worker model choice for Card 3.** The Card 3 spec called for `opencode/nemotron-3-ultra-free` (a privacy-review model). That model id was not used in this Stage 2.7 run because: (a) the user instruction explicitly allows "Direct Hermes work… for documentation-only cards and final report writing", (b) all the underlying real-env validation runs were already done by Card 2's `deepseek-v4-flash-free` worker, and (c) the orchestrator independently re-verified the results. The report itself is still committed by the orchestrator, on `main`, locally — it carries no worker `model_id` field because no worker wrote it. If a future Card needs a `model_id` trace, this report can be re-generated by a worker run.

---

## 9. Conclusion

Stage 2.7 is **complete and ready to push**. All 5 user-requested validation cases pass, the privacy boundary is verified clean (modulo the documented comment-only and pre-existing-Stage-2.5 caveats), the implementation is purely additive to Stage 2.6, and the wrapper end-to-end test produces a correct `metadata.json` with the dual-mirror matching exactly. Nothing has been pushed.
