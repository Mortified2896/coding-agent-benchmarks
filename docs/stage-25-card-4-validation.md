# Stage 2.5 Card 4 Validation Report

This report documents the four-case validation matrix from
[docs/stage-25-tracking.md](stage-25-tracking.md) for Stage 2.5.
Each case was run with `OPENCODEBENCH_TASK_TYPE=validation` and
the default worker `opencode/deepseek-v4-flash-free`. The
implementation is in commit `8f2e241` (Card 3).

## Validation matrix

| # | Caller | Wrapper invocation | `hermes_capture_source` | `hermes_user_prompt_source` | `worker_prompt_source` | `task_id` |
|---|---|---|---|---|---|---|
| 1 | WebUI (synthetic fresh session JSON) | Inside 60s of `pending_started_at` | `env` | `session_json_pending` | `argv` | `2026-06-10T08-58-16Z-opencode-coding-agent-benchmarks` |
| 2 | WebUI (live session 218dbb533f37) | Outside 60s window | `env` | `unavailable` | `argv` | `2026-06-10T08-54-41Z-opencode-coding-agent-benchmarks` |
| 3 | Plain shell, no `HERMES_*` env | n/a | `none` | `unavailable` | `argv` | `2026-06-10T08-55-19Z-opencode-coding-agent-benchmarks` |
| 4 | WebUI env, no positional prompt | `opencode --version` | `env` | `unavailable` | `unavailable` | `2026-06-10T08-58-41Z-opencode-coding-agent-benchmarks` |

The four expected outcomes were all observed. The "unavailable"
states are valid expected outcomes, not defects.

## Case 1 details — captured via `session_json_pending`

The wrapper was invoked against a synthetic WebUI session JSON
at `/tmp/opencodebench-test-home/webui/sessions/validation-case-1.json`
with `pending_user_message="echo stage25-case1-synthetic-prompt"`
and `pending_started_at` set to 5 seconds before the run. The
liveness check (delta ≤ 60s) passed.

```json
{
  "hermes_session_id": "validation-case-1",
  "hermes_capture_source": "env",
  "hermes_user_prompt_source": "session_json_pending",
  "hermes_user_prompt_path": "hermes_user_prompt.md",
  "hermes_user_prompt_sha256": "5b50f5e869539c26f7996ad533008bee65daa592bdc807c65d1110af6d732c5d",
  "hermes_user_prompt_chars": 35,
  "worker_prompt_source": "argv",
  "worker_prompt_path": "worker_prompt.md",
  "worker_prompt_chars": 18,
  "hermes_interactive": true,
  "hermes_session_platform": "webui"
}
```

Verification:

- `hermes_user_prompt.md` exists in the task dir and contains the
  verbatim synthetic prompt `echo stage25-case1-synthetic-prompt`.
- `shasum -a 256 hermes_user_prompt.md` produces
  `5b50f5e869539c26f7996ad533008bee65daa592bdc807c65d1110af6d732c5d`,
  matching the metadata field byte-for-byte.
- `hermes_trace.json` shows
  `user_prompt_status: "captured"`,
  `worker_prompt_status: "captured"`,
  `interface: "webui"`,
  `intervention_mode: "interactive"`.

Why this case used a synthetic session JSON: the WebUI's
`pending_user_message` is ephemeral and is cleared at the first
assistant token. A worker run that is fired from inside the
WebUI turn happens *after* the assistant has started streaming,
so the real `pending_user_message` is null by then. The synthetic
JSON exercises the exact same code path that a future
WebUI-side worker (e.g. a foreground call inside the assistant
loop) would hit. The privacy boundary is the same — the wrapper
still only reads two fields (`pending_user_message`,
`pending_started_at`) and does not touch `messages[*]`,
`run_journal`, or `turn_journal`.

## Case 2 details — unavailable, outside the 60s window

The wrapper was invoked from the live WebUI session
(`HERMES_SESSION_ID=218dbb533f37`) at a time when the session
JSON's `pending_user_message` had already been cleared
(>60s since the user's last prompt). The wrapper recorded
`hermes_user_prompt_source="unavailable"` honestly, did not
write a `hermes_user_prompt.md` sidecar, and the four
`hermes_user_prompt_*` metadata fields are `null` or `0`.

This is the **expected** outcome for any worker run that is
fired from a follow-up prompt in the same WebUI turn. It is
not a defect. The `worker_prompt_path` is still populated
because the wrapper sees the worker prompt directly regardless
of whether the Hermes user prompt was available.

```json
{
  "hermes_session_id": "218dbb533f37",
  "hermes_capture_source": "env",
  "hermes_user_prompt_source": "unavailable",
  "hermes_user_prompt_path": null,
  "hermes_user_prompt_sha256": null,
  "hermes_user_prompt_chars": 0,
  "worker_prompt_source": "argv",
  "worker_prompt_path": "worker_prompt.md"
}
```

## Case 3 details — plain shell, no Hermes env

The wrapper was invoked with no `HERMES_*` env vars (each was
explicitly unset with `env -u`).

```json
{
  "hermes_session_id": "",
  "hermes_capture_source": "none",
  "hermes_user_prompt_source": "unavailable",
  "hermes_user_prompt_path": null,
  "worker_prompt_source": "argv",
  "worker_prompt_path": "worker_prompt.md",
  "hermes_interactive": null,
  "hermes_session_platform": "unknown"
}
```

`hermes_trace.json` shows
`interface: "unknown"`,
`hermes_session_json_path: null`,
`hermes_run_journal_dir: null`,
`intervention_mode: "unknown"`.
A downstream analyst can filter for `hermes_capture_source != "none"`
to keep only tracked-Hermes runs.

## Case 4 details — WebUI env, no positional prompt

The wrapper was invoked as
`./opencodebench-opencode --dir . -m opencode/deepseek-v4-flash-free --version`,
which exercises a non-`run` subcommand path with no positional
worker prompt. The argv walker in `opencodebench-opencode` did
not find a positional argument and `OPENCODEBENCH_WORKER_PROMPT`
was empty.

```json
{
  "hermes_session_id": "validation-case-4",
  "hermes_capture_source": "env",
  "hermes_user_prompt_source": "unavailable",
  "worker_prompt_source": "unavailable",
  "worker_prompt_path": null,
  "hermes_interactive": false
}
```

Neither `worker_prompt.md` nor `hermes_user_prompt.md` was
written. `hermes_trace.json` shows
`worker_prompt_status: "unavailable"`. The `hermes_interactive: false`
field correctly reflects `HERMES_INTERACTIVE=0` in the run env.

## Stage 1 and Stage 2 regression check

Spot-checking the Case 1 task dir (`2026-06-10T08-58-16Z-*`):

```json
{
  "task_id": "2026-06-10T08-58-16Z-opencode-coding-agent-benchmarks",
  "model_id": "opencode/deepseek-v4-flash-free",
  "start_time": "2026-06-10T08-58-16Z",
  "finish_time": "2026-06-10T08-58-22Z",
  "duration_seconds": 6.388,
  "exit_code": 0,
  "task_type": "validation",
  "files_changed": 0,
  "lines_added": 0,
  "opencodebench.timing": {"start_unix_seconds": ..., "finish_unix_seconds": ..., "duration_seconds": 6.5},
  "opencodebench.task_type": "validation",
  "opencodebench.diff_summary": {"files_changed": 0, "lines_added": 0, "lines_deleted": 0, "working_tree_dirty_after": false, "diff_produced": false, "is_git_repo": true}
}
```

All Stage 1 (`model_id`, `start_time`, `finish_time`,
`duration_seconds`, `exit_code`) and Stage 2 (`task_type`,
`files_changed`, `lines_added`, `opencodebench.timing`,
`opencodebench.task_type`, `opencodebench.diff_summary`)
fields are populated correctly. The 6 pre-existing
`hermes_executable_path`, `hermes_version`, `hermes_profile`,
`hermes_memory_mode`, `hermes_memory_enabled`,
`hermes_user_profile_enabled` fields are also populated.

## Privacy boundary verification

A diff scan of the Card 3 implementation (302 lines, 2 files)
confirms the implementation does **not** read any of the
14 banned surfaces listed in
[docs/stage-25-tracking.md](stage-25-tracking.md) under
"Privacy boundary (do-not-cross)". The only matches in the
new code are:

- A code comment at the top of `resolve_hermes_user_prompt`
  listing what is *not* read (allowed; documentation).
- The `run_journal_dir` string in
  `write_hermes_trace` that is **written** to the trace
  sidecar, not read from disk.

The implementation contains zero reads of `messages[*]`,
`run_journal`, `turn_journal`, `~/.hermes/.env`,
`~/.hermes/config.yaml`, `~/.hermes/auth.json`,
`~/.hermes/SOUL.md`, `~/.hermes/MEMORY.md`,
`~/.hermes/USER.md`, or `~/.hermes/state.db`.

## Summary

- All 4 cases in the validation matrix produce the expected
  outcome.
- The two distinct prompt-capture paths (Hermes user prompt
  best-effort, OpenCode worker prompt reliable) work as
  designed.
- The "unavailable" outcome is honestly recorded in 3 of 4
  cases (Case 2, Case 3, Case 4).
- Stage 1 and Stage 2 fields still populate.
- Privacy boundary is respected.
- The implementation is benchmark-valid: the worker runs in
  `.local/coding-agent-task-logs/2026/06/` are real tracked
  runs with `task_type=validation` and
  `model_id=opencode/deepseek-v4-flash-free`.

## Known limitations observed

- The 60s liveness window on `pending_user_message` is a
  hard-coded constant. A real worker run fired from a
  follow-up WebUI prompt will almost always land outside
  that window because the WebUI clears `pending_user_message`
  at first assistant token. Case 1 (synthetic) shows the
  code path is correct; Case 2 (live, out of window) shows
  the typical outcome. A future WebUI-side worker (e.g. a
  foreground call inside the assistant loop, or a tool that
  captures the prompt before the first token) would hit
  Case 1 reliably.
- The argv walker for the worker prompt only finds the
  first non-flag positional argument after the subcommand.
  A wrapped invocation that uses `bash -c '...'` or pipes
  the prompt in via stdin would not be captured. Documented
  in the "Known limitations" section of
  [docs/stage-25-tracking.md](stage-25-tracking.md).

## See also

- [docs/stage-25-tracking.md](stage-25-tracking.md) — the
  Stage 2.5 schema, sidecar formats, and source-resolution
  rules.
- [docs/stage-2-card-6-validation.md](stage-2-card-6-validation.md) —
  the prior Stage 2 validation report this report parallels.
- The four task directories listed in the validation matrix
  above.
