# Stage 2.5 Tracking — Raw Hermes Orchestration Trace

This document describes the Stage 2.5 tracking layer added on top of the
Stage 2 worker-tracking layer. Stage 2.5 captures **raw evidence only**:
no interpretive labels, no routing-policy judgements, no subjective
flags. If a downstream analysis wants to score "did the orchestrator
follow the policy?" it can do that later, on top of the raw data.

If you have not read the Stage 1 or Stage 2 docs, start there:

- [docs/task-capture-wrapper.md](task-capture-wrapper.md) — Stage 1
  wrapper, command shape, sidecar files.
- [docs/stage-2-tracking.md](stage-2-tracking.md) — Stage 2 worker
  metadata (model_id, timing, task_type, diff summary, evaluation.md).

Stage 2.5 is purely additive. It inherits the Stage 1 wrapper, command
shape, and sidecar layout. It never renames a Stage 1 or Stage 2 key,
never removes a field, and never changes the meaning of an existing
field. All Stage 2.5 additions appear as new top-level keys in
`metadata.json`, as a new nested object under `opencodebench.trace.*`,
or as new sidecar files inside `<task_dir>/`.

## Design correction (approved by the user)

The user prompt is **raw benchmark evidence** and should be captured
when safely available. Interpretive labels such as
`routing_policy_followed`, `delegated_to_opencode`, or
`user_intervention_needed` are **not raw evidence** and are **never**
added to the schema.

Two distinct prompts matter:

1. **The Hermes user prompt** — what the human typed into Hermes to
   start a turn. This is the **orchestrator input**.
2. **The OpenCode worker prompt** — what the wrapper passed to
   `opencode run` as the positional prompt argument. This is the
   **worker input** and is the reliable benchmark join key, because
   the wrapper sees it directly on every invocation.

Stage 2.5 captures both, with different reliability expectations:

- The **worker prompt** is captured **reliably** from the wrapper
  invocation. It is a wrapper-level concern and is always available.
- The **Hermes user prompt** is captured **best-effort**. It is only
  available when Hermes exposes it through a safe channel (an
  env-var, or the ephemeral `pending_user_message` field in the WebUI
  session JSON, within a 60-second liveness window). When none of
  those are available, the wrapper records
  `hermes_user_prompt_source="unavailable"` and writes no sidecar.
  This is a **valid expected outcome**, not a defect.

## What Stage 2.5 adds

1. **Hermes context fields** (Card 3): env-derived identifiers
   that tell a downstream reader which Hermes session, interface,
   profile, and Kanban board the worker was invoked from.
2. **`hermes_trace.json` sidecar** (Card 3): a per-task pointer-only
   sidecar that names the on-disk Hermes state the run came from.
   Pointer-only — the wrapper does not read the contents.
3. **Hermes user prompt capture (best-effort)** (Card 3): a
   `hermes_user_prompt_source` field plus a `hermes_user_prompt.md`
   sidecar. Best-effort; "unavailable" is a valid outcome.
4. **OpenCode worker prompt capture (reliable)** (Card 3): a
   `worker_prompt_source` field plus a `worker_prompt.md` sidecar.
   Always written; the wrapper sees the prompt directly.
5. **Privacy boundary** (Card 2 doc, Card 3 code): explicit list of
   what is **not** captured. No full Hermes session transcript, no
   `messages[*]` scraping, no `~/.hermes/.env`, `config.yaml`,
   `auth.json`, `SOUL.md`, `MEMORY.md`, or `USER.md` reads.

## How to invoke a tracked Stage 2.5 run

The wrapper is the same as Stage 1/2:

```text
./opencodebench-opencode --dir <repo> -m <model> ...opencode args...
```

New Stage 2.5 env vars (all optional):

| Env var | Effect | Default |
|---|---|---|
| `OPENCODEBENCH_SKIP_HERMES_TRACE` | Skip the `hermes_trace.json` sidecar and the four `hermes_user_prompt_*` metadata fields. The 8 `hermes_*` context fields are still populated. | unset (capture is on) |
| `OPENCODEBENCH_HERMES_USER_PROMPT_WINDOW_SECONDS` | Override the liveness window for `pending_user_message`. | unset (60s) |
| `OPENCODEBENCH_HERMES_USER_PROMPT_LIVENESS=off` | Disable the liveness check entirely (capture `pending_user_message` regardless of age). Off by default. | unset (liveness on) |
| `OPENCODEBENCH_HERMES_USER_PROMPT_PATH` | Absolute path to a file containing the Hermes user prompt. Used when Hermes exposes the prompt as a file rather than an env var. | unset |
| `OPENCODEBENCH_HERMES_USER_PROMPT` | Direct env-var source for the prompt text. Used when Hermes exposes the prompt as an env var. | unset |

The wrapper tries these sources in this strict precedence order and
records the first that matches:

1. **`"env"`** — `OPENCODEBENCH_HERMES_USER_PROMPT` is set to a
   non-empty string, or `OPENCODEBENCH_HERMES_USER_PROMPT_PATH` points
   to a readable file. The wrapper reads bytes; no normalization.
2. **`"session_json_pending"`** — `HERMES_HOME` and
   `HERMES_WEBUI_STATE_DIR` are set, the session JSON file exists,
   its `pending_user_message` field is a non-empty string, and
   `pending_started_at` is within the liveness window
   (`OPENCODEBENCH_HERMES_USER_PROMPT_WINDOW_SECONDS` or 60s).
3. **`"unavailable"`** — anything else. The wrapper does **not** read
   `messages[*]`, the run journal, the turn journal, or any auth or
   config file to find the prompt. Recorded honestly.

A typical tracked Stage 2.5 run looks like the Stage 2 form, with the
new env vars added only if the caller wants to override defaults:

```sh
env -u OPENCODE_SERVER_PASSWORD -u OPENCODE_SERVER_USERNAME \
  OPENCODEBENCH_TASK_TYPE=implementation \
  ./opencodebench-opencode --dir . -m opencode/deepseek-v4-flash-free \
    run "fix the off-by-one bug in capture-task-finish.sh"
```

## Where the metadata and sidecars end up

Every tracked run creates a new directory at:

```text
.local/coding-agent-task-logs/<year>/<month>/<task_id>/
```

Stage 2.5 adds three new files inside that directory, alongside the
Stage 1/2 files:

- **`hermes_trace.json`** — pointer-only sidecar naming the on-disk
  Hermes state the run came from. Schema is in the "Sidecar formats"
  section below.
- **`hermes_user_prompt.md`** (best-effort, conditional) — verbatim
  prompt text the wrapper extracted from the safe source. Not written
  when the source is `"unavailable"`. Existing? — yes, written.
- **`worker_prompt.md`** — verbatim OpenCode worker prompt (the
  positional argument to `opencode run`). Always written when the
  positional argument is non-empty. The wrapper sees it directly.

The `task.md` file the Stage 1 wrapper already writes is **not**
modified by Stage 2.5. It still reflects whatever OpenCode itself
recorded as the session task log.

## Stage 2.5 metadata fields

All additions are additive. None of the Stage 1 or Stage 2 keys are
renamed, removed, or retyped.

| Field | Type | Source | Default |
|---|---|---|---|
| `hermes_session_id` | string | `HERMES_SESSION_ID` env | `""` |
| `hermes_session_chat_id` | string | `HERMES_SESSION_CHAT_ID` env | `""` |
| `hermes_session_platform` | string | `HERMES_SESSION_PLATFORM` env | `"unknown"` |
| `hermes_home` | string (abs path) | `HERMES_HOME` env | `""` |
| `hermes_webui_state_dir` | string (abs path) | `HERMES_WEBUI_STATE_DIR` env | `""` |
| `hermes_kanban_board` | string | `HERMES_KANBAN_BOARD` env | `""` |
| `hermes_interactive` | bool or null | `HERMES_INTERACTIVE` env (`"1"`/`"0"`) | `null` |
| `hermes_capture_source` | string | derived: `"env"` if any `HERMES_*` present, else `"none"` | `"none"` |
| `hermes_user_prompt_source` | string | derived: `"env"` \| `"session_json_pending"` \| `"unavailable"` | `"unavailable"` |
| `hermes_user_prompt_path` | string or null | relative path to `hermes_user_prompt.md` sidecar if written | `null` |
| `hermes_user_prompt_sha256` | string or null | sha256 of the sidecar bytes | `null` |
| `hermes_user_prompt_chars` | integer ≥ 0 | byte length of the sidecar | `0` |
| `worker_prompt_source` | string | derived: `"argv"` \| `"unavailable"` | `"unavailable"` |
| `worker_prompt_path` | string or null | relative path to `worker_prompt.md` sidecar if written | `null` |
| `worker_prompt_sha256` | string or null | sha256 of the sidecar bytes | `null` |
| `worker_prompt_chars` | integer ≥ 0 | byte length of the sidecar | `0` |
| `opencodebench.trace.hermes_user_prompt` | object \| null | `{source, sha256, chars, sidecar}` mirror | `null` |
| `opencodebench.trace.worker_prompt` | object \| null | `{source, sha256, chars, sidecar}` mirror | `null` |

The Stage 1 fields `hermes_executable_path`, `hermes_version`,
`hermes_profile`, `hermes_memory_mode`, `hermes_memory_enabled`,
`hermes_user_profile_enabled` keep their current env-var sources
unchanged. They are not the focus of Stage 2.5.

## Sidecar formats

### `hermes_trace.json`

Pointer-only. The wrapper does **not** read the contents of the
pointed-to files. The file is written after `metadata.json` is
written.

```json
{
  "schema_version": "stage-2.5/v1",
  "captured_at": "2026-06-10T08:22:00Z",
  "task_id": "2026-06-10T08-21-44Z-opencode-coding-agent-benchmarks",
  "interface": "webui",
  "hermes_home": "/Users/Jo/.hermes",
  "hermes_session_id": "20260610_100758_a45693",
  "hermes_session_json_path": "/Users/Jo/.hermes/webui/sessions/20260610_100758_a45693.json",
  "hermes_run_journal_dir": "/Users/Jo/.hermes/webui/sessions/_run_journal/20260610_100758_a45693",
  "hermes_kanban_board": "opencodebench",
  "intervention_mode": "interactive",
  "user_prompt_sidecar": "hermes_user_prompt.md",
  "user_prompt_status": "captured|unavailable",
  "worker_prompt_sidecar": "worker_prompt.md",
  "worker_prompt_status": "captured|unavailable"
}
```

### `hermes_user_prompt.md`

Verbatim prompt text — exact bytes, no normalization, no wrapping, no
Markdown formatting (the `.md` extension is a hint to humans and IDEs,
not a contract). Not written when the source is `"unavailable"`. When
`HERMES_REDACT_SECRETS=***` is set in the upstream env, the sidecar
contains the redacted form. The wrapper does not attempt its own
redaction.

### `worker_prompt.md`

Verbatim positional argument passed to `opencode run` — exact bytes,
no normalization, no wrapping. Always written when the positional
argument is non-empty and the source is `"argv"`. When the positional
argument is empty (e.g. an `opencode attach` invocation), the source
is `"unavailable"` and the sidecar is not written.

## Hash semantics

Both `hermes_user_prompt_sha256` and `worker_prompt_sha256` are
`sha256` of the **raw bytes** of the respective sidecar file. No
newline normalization, no encoding normalization, no trim. The hash
is the join key for benchmark aggregators; mutating the bytes would
change the hash and break joins. The hash is computed with
`shasum -a 256` on macOS and `sha256sum` on Linux; the script gates
this on `uname -s`.

## Worked example

A WebUI-initiated worker run where the wrapper is invoked inside the
60-second liveness window produces:

**`metadata.json` (Stage 2.5 keys only):**

```json
{
  "hermes_session_id": "20260610_100758_a45693",
  "hermes_session_chat_id": "20260610_100758_a45693",
  "hermes_session_platform": "webui",
  "hermes_home": "/Users/Jo/.hermes",
  "hermes_webui_state_dir": "/Users/Jo/.hermes/webui",
  "hermes_kanban_board": "opencodebench",
  "hermes_interactive": true,
  "hermes_capture_source": "env",
  "hermes_user_prompt_source": "session_json_pending",
  "hermes_user_prompt_path": "hermes_user_prompt.md",
  "hermes_user_prompt_sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
  "hermes_user_prompt_chars": 1261,
  "worker_prompt_source": "argv",
  "worker_prompt_path": "worker_prompt.md",
  "worker_prompt_sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  "worker_prompt_chars": 42,
  "opencodebench": {
    "trace": {
      "hermes_user_prompt": {
        "source": "session_json_pending",
        "sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
        "chars": 1261,
        "sidecar": "hermes_user_prompt.md"
      },
      "worker_prompt": {
        "source": "argv",
        "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "chars": 42,
        "sidecar": "worker_prompt.md"
      }
    }
  }
}
```

A direct non-Hermes run (no `HERMES_*` env) produces:

```json
{
  "hermes_session_id": "",
  "hermes_session_chat_id": "",
  "hermes_session_platform": "unknown",
  "hermes_home": "",
  "hermes_webui_state_dir": "",
  "hermes_kanban_board": "",
  "hermes_interactive": null,
  "hermes_capture_source": "none",
  "hermes_user_prompt_source": "unavailable",
  "hermes_user_prompt_path": null,
  "hermes_user_prompt_sha256": null,
  "hermes_user_prompt_chars": 0,
  "worker_prompt_source": "argv",
  "worker_prompt_path": "worker_prompt.md",
  "worker_prompt_sha256": "<sha256>",
  "worker_prompt_chars": 42
}
```

The `worker_prompt` fields are populated regardless of whether the
caller was Hermes, because the wrapper sees the prompt directly. The
`hermes_*` and `hermes_user_prompt_*` fields are empty / unavailable
when the caller was not Hermes.

## What is **not** captured

Stage 2.5 is strict about what it does not read or write. The
following are explicitly out of scope:

- **No full Hermes session transcripts.** The wrapper does not read
  `messages[*]`, the run journal, the turn journal, the agent log, or
  any other source that contains a full conversation.
- **No `messages[*]` scraping.** If the Hermes user prompt is not
  available through the safe sources, the wrapper records
  `unavailable` and gives up. It does not scan the session JSON
  `messages` array to find a candidate.
- **No `~/.hermes/.env`, `config.yaml`, `auth.json` reads.** These
  are the Stage 1 privacy boundary and Stage 2.5 inherits it.
- **No `SOUL.md`, `MEMORY.md`, `USER.md` reads.** Same boundary.
- **No interpretive labels.** `routing_policy_followed`,
  `delegated_to_opencode`, `user_intervention_needed`, or any other
  flag that requires the wrapper to *judge* the run are not in the
  schema. A Stage 3 analysis tool may compute them on top of the raw
  data, but the raw data does not contain them.
- **No orchestrator model auto-fill.** The orchestrator's model name
  (e.g. `MiniMax-M3`) is not in the `HERMES_*` env on this host. A
  separate Stage 3 tool, run only on explicit user demand, may read
  it from the WebUI session JSON. Stage 2.5 does not.
- **No reasoning-level auto-fill.** Same as orchestrator model.

## Privacy and security

In addition to the "what is not captured" list above:

1. **The session JSON pointer is a soft PII leak.** Even though the
   wrapper does not copy the contents, anyone with read access to the
   task log directory can follow the pointer and read the user's
   full prompt text and tool-call history. The risk is *capability
   exposure*, not data exfiltration. The risk class is the same as
   the existing captured `git-diff.patch` and `task.md`. Documented
   in `README.md` privacy section.
2. **Path leakage.** The captured absolute paths reveal the user's
   directory layout and username. Stage 1/2 already capture
   `repo_path` and `opencode_executable_path`; Stage 2.5 adds two
   more. Mitigation: this is a local-only capture, and the README's
   "keep them ignored and private" guidance already covers the new
   fields.
3. **Pointer staleness.** The `hermes_session_json_path` can become
   stale if the user archives, deletes, or moves the session. The
   `hermes_trace.json` schema has a `captured_at` timestamp; a Stage
   3 consumer can refuse to dereference pointers older than N hours,
   or surface a "stale pointer" warning.
4. **Re-daction asymmetry.** `HERMES_REDACT_SECRETS=***` is exported;
   the WebUI already redacts secrets in its own outputs. The wrapper
   inherits whatever Hermes redacts and does not attempt its own
   redaction.
5. **Replay of `task_id` collisions.** A user who starts a new WebUI
   session after the old one is archived gets a new
   `HERMES_SESSION_ID`. The Stage 2 `task_id` is generated from the
   run timestamp, not from `HERMES_SESSION_ID`, so collisions are not
   a concern. The `hermes_session_id` field is a foreign key, not a
   primary key.
6. **Empty `HERMES_*` vars in non-Hermes invocations.** If a user
   runs `opencodebench-opencode` directly from a plain shell, every
   `hermes_*` field is the empty string and `hermes_capture_source`
   is `"none"`. Downstream analysis can
   `WHERE hermes_capture_source != 'none'` to filter for tracked-
   Hermes runs.
7. **The `hermes_run_journal_dir` pointer is mutable.** The journal
   directory is appended to for the entire session; pointing at it
   doesn't grant write access, but a future Stage 3 deep-fill script
   that reads it might pick up events that happened *after* the
   OpenCode run finished. The `captured_at` timestamp bounds the
   window.

## End-to-end loop

```text
        +-------------------------+
        |  decide task type       |
        |  set                    |
        |  OPENCODEBENCH_TASK_TYPE|
        +-----------+-------------+
                    |
                    v
        +-------------------------+    +--------------------------+
        |  run wrapper with       |    |  opencode runs the work  |
        |  -m <model>             +--->+  in <task_dir>/<repo>    |
        |  --dir <repo>           |    +--------------------------+
        +-----------+-------------+
                    |
                    v
        +-------------------------+    +--------------------------+
        |  wrapper writes         |    |  <task_dir>/metadata.json|
        |  <task_dir>/...         |    |  + summary.md            |
        |  on finish              |    |  + git diff sidecars     |
        +-----------+-------------+    |  + evaluation.md         |
                    |                  |  + hermes_trace.json     |
                    v                  |  + hermes_user_prompt.md |
        +-------------------------+    |     (best-effort)        |
        |  hermes_* context       |    |  + worker_prompt.md      |
        |  fields populate if     |    +--------------------------+
        |  HERMES_* env present   |
        +-----------+-------------+
                    |
                    v
        +-------------------------+
        |  human edits            |
        |  evaluation.md          |
        +-----------+-------------+
                    |
                    v
        +-------------------------+
        |  benchmark row:         |
        |  metadata + evaluation  |
        |  + trace sidecars       |
        +-------------------------+
```

The benchmark row is the unit of analysis. Each row is one run
(identified by `task_id`) plus its human evaluation plus its Stage
2.5 trace sidecars. The aggregator joins on `task_id`.

## Known limitations

- **The `pending_user_message` field is ephemeral.** It is only
  populated in the brief window between "user submitted" and
  "assistant first token." By the time a wrapper is invoked during
  assistant streaming — which is when most OpenCode work happens —
  the field is `null` and the prompt is lost for that run. Stage 2.5
  records `hermes_user_prompt_source="unavailable"` honestly. A
  future Stage 3 tool may read `messages[*].content` on explicit
  user demand to recover the prompt; Stage 2.5 does not.
- **The 60-second liveness window is a hard-coded constant in the
  wrapper, not a user config.** It is overridable via
  `OPENCODEBENCH_HERMES_USER_PROMPT_WINDOW_SECONDS` for power users,
  but the default is intentionally a constant so it cannot be
  widened by accident.
- **The orchestrator model name and reasoning level are not
  captured.** They are not in the `HERMES_*` env. Reading them from
  the WebUI session JSON requires touching a file Stage 1 already
  prohibits reading. A Stage 3 tool may resolve this on explicit
  user demand.
- **The `worker_prompt.md` sidecar writes the positional argument
  verbatim.** If the caller constructs the positional argument from
  templated context (e.g. a Kanban card body), the sidecar contains
  the templated text, not the original card body. This is
  intentional — the wrapper sees only what was actually passed to
  `opencode run`.

## Schema for implementers

This section is the implementation contract for Card 3. It is
intentionally more prescriptive than the design sections above.

### Metadata `jq` arg-passes

The wrapper's `capture-task-start.sh` adds the following 8
top-level `hermes_*` env-derived fields and 6 top-level prompt
fields to the `jq -n` call that builds `metadata.json`. The full
`jq` arg list is:

```sh
--arg hermes_session_id              "$hermes_session_id"
--arg hermes_session_chat_id         "$hermes_session_chat_id"
--arg hermes_session_platform        "$hermes_session_platform"
--arg hermes_home                    "$hermes_home"
--arg hermes_webui_state_dir         "$hermes_webui_state_dir"
--arg hermes_kanban_board            "$hermes_kanban_board"
--argjson hermes_interactive         "$hermes_interactive"
--arg hermes_capture_source          "$hermes_capture_source"
--arg hermes_user_prompt_source      "$hermes_user_prompt_source"
--arg hermes_user_prompt_path        "$hermes_user_prompt_path"
--arg hermes_user_prompt_sha256      "$hermes_user_prompt_sha256"
--argjson hermes_user_prompt_chars   "$hermes_user_prompt_chars"
--arg worker_prompt_source           "$worker_prompt_source"
--arg worker_prompt_path             "$worker_prompt_path"
--arg worker_prompt_sha256           "$worker_prompt_sha256"
--argjson worker_prompt_chars        "$worker_prompt_chars"
```

The corresponding `jq` output additions are mirrored at the top
level and grouped under `opencodebench.trace.*` per the Stage 1/2
dual-location convention.

### Env-var precedence

The wrapper tries the configured sources in this strict order. The
first non-empty match wins; the wrapper does **not** fall through
to a less-safe source.

1. `OPENCODEBENCH_HERMES_USER_PROMPT` (env, direct text) or
   `OPENCODEBENCH_HERMES_USER_PROMPT_PATH` (env, path to a file).
2. WebUI session JSON `pending_user_message`, with a 60-second
   liveness check on `pending_started_at`.
3. `unavailable` (recorded honestly; no fallback read).

The worker prompt is read from the wrapper's own positional
`"$@"` argument list. The wrapper records the first non-flag
positional argument after the `run` subcommand as the worker
prompt. If no positional argument is present (e.g. an
`opencode attach` call), the source is `unavailable` and the
sidecar is not written.

### Sidecar file paths

All sidecars are written **relative to `<task_dir>/`**:

| Sidecar | Absolute path | Conditional? |
|---|---|---|
| `hermes_trace.json` | `<task_dir>/hermes_trace.json` | Skipped if `OPENCODEBENCH_SKIP_HERMES_TRACE=1` |
| `hermes_user_prompt.md` | `<task_dir>/hermes_user_prompt.md` | Skipped when `hermes_user_prompt_source="unavailable"` |
| `worker_prompt.md` | `<task_dir>/worker_prompt.md` | Skipped when `worker_prompt_source="unavailable"` |

The `*_path` fields in `metadata.json` are **relative** to
`<task_dir>/` (e.g. `hermes_user_prompt.md`), matching the Stage 1
convention of `git_diff_patch_path` etc. The `hermes_trace.json`
file uses **absolute** paths inside its body, because the
trace-sidecar is itself a pointer to other locations.

### `task.md` stub fix

The Stage 1 wrapper writes a stub `task.md` when no startup prompt
file is passed. On the current OpenCode build, a long positional
prompt is sometimes ignored and `task.md` shows a "No startup
prompt was provided" stub even though opencode did receive and
act on the prompt. Stage 2.5 does not change `task.md`; the
`worker_prompt.md` sidecar is the reliable worker-prompt record.
A future Card may also fix the `task.md` stub by writing
`worker_prompt.md` content to `task.md` when OpenCode fails to
do so; that is out of scope for Stage 2.5.

## Privacy boundary (do-not-cross)

The wrapper's Stage 2.5 code path is allowed to read **only** the
following Hermes surfaces. Anything else is a hard-don't.

| Surface | Read allowed? | Why |
|---|---|---|
| `HERMES_*` env vars (17 known) | yes | Inherited from the process env. No filesystem access. |
| WebUI session JSON `pending_user_message` | yes, with 60s liveness | Ephemeral; cleared at first assistant token. |
| WebUI session JSON `pending_started_at` | yes, paired with the above | Used for the liveness check. |
| `~/.hermes/webui/sessions/<id>.json` | yes, only for the two fields above | Pointer-only access; no other field is read. |
| `messages[*].content` | **NO** | Would leak the full Hermes transcript. Stage 2 privacy boundary. |
| `~/.hermes/webui/sessions/_run_journal/...` | **NO** | Contains the full Hermes tool-call history. |
| `~/.hermes/webui/sessions/_turn_journal/...` | **NO** | Same. |
| `~/.hermes/.env` | **NO** | Stage 1 privacy boundary. Contains API keys. |
| `~/.hermes/config.yaml` | **NO** | Stage 1 privacy boundary. Contains provider config. |
| `~/.hermes/auth.json` | **NO** | Stage 1 privacy boundary. Contains auth tokens. |
| `~/.hermes/SOUL.md`, `MEMORY.md`, `USER.md` | **NO** | Stage 1 privacy boundary. Memory/profile data. |
| `~/.hermes/state.db` (sessions, messages) | **NO** | SQLite store of the full transcript. |
| Orchestrator model name (e.g. `MiniMax-M3`) | **NO** | Not in `HERMES_*` env; would require reading the session JSON. |
| Reasoning / intelligence level | **NO** | Same. |

The list is normative. A reviewer can reject a Card 3 PR that
adds a read not on this list without updating both this section
and the implementation.

## Validation matrix

Card 4 fills in this matrix. The expected outcomes are:

| Case | Caller | Wrapper invocation timing | `hermes_capture_source` | `hermes_user_prompt_source` | `worker_prompt_source` |
|---|---|---|---|---|---|
| 1 | WebUI (this session) | Inside 60s of prompt submit | `env` | `session_json_pending` | `argv` |
| 2 | WebUI (this session) | More than 60s after prompt submit | `env` | `unavailable` | `argv` |
| 3 | Plain shell (no `HERMES_*` env) | n/a | `none` | `unavailable` | `argv` |
| 4 | WebUI with no positional prompt | n/a | `env` | (case 1 or 2) | `unavailable` |

Card 4 writes the actual run log into
`docs/stage-25-card-4-validation.md` and references the task
directories by `task_id`.

## Stage 3 analysis path (deferred)

Stage 2.5 captures raw evidence only. A future Stage 3 could compute
analytical scores on top of the captured data, on explicit user
demand and with a separate privacy opt-in. Possible analyses, all
**deferred**:

- **Orchestrator model backfill.** Read the WebUI session JSON's
  `model` and `model_provider` fields (currently
  `MiniMax-M3` / `minimax` on this host) and add
  `hermes_orchestrator_model` and
  `hermes_orchestrator_provider` metadata. Requires
  relaxing the privacy boundary to read those two fields only.
- **Reasoning / intelligence level backfill.** Read
  `gateway_routing` or a future equivalent. Same opt-in.
- **Routing-policy scoring.** Given
  `OPENCODEBENCH_UPSTREAM_ORCHESTRATOR`, the worker `model_id`,
  and the captured `worker_prompt`, score whether the routing
  policy in
  [docs/current-openbench-model-routing.md](current-openbench-model-routing.md)
  was followed. This is an interpretive label and **must not** be
  added to the raw data; it is computed by Stage 3 only.
- **Intervention counts.** Given
  `hermes_user_prompt_source`, `hermes_user_prompt_chars`, and
  the wrapper invocation timing, count turns that needed
  user intervention. Again, interpretive; not in raw data.
- **Cross-run join keys.** Use `hermes_session_id` +
  `worker_prompt_sha256` to group runs by Hermes session, then
  compute per-session aggregate statistics (e.g. success rate
  per session, average `duration_seconds` per session).

None of these are implemented. Stage 2.5 is the foundation;
Stage 3 is a future stage that reads it.

## See also

- [docs/task-capture-wrapper.md](task-capture-wrapper.md) — Stage 1
  wrapper docs (the foundation this Stage 2.5 doc layers on).
- [docs/stage-2-tracking.md](stage-2-tracking.md) — Stage 2 worker
  tracking (the layer Stage 2.5 adds to).
- [docs/stage-25-card-4-validation.md](stage-25-card-4-validation.md) —
  the four-case validation report for Stage 2.5.
- [docs/current-openbench-model-routing.md](current-openbench-model-routing.md) —
  worker selection and provider-failure handling policy.
- [docs/reconstructing-benchmark-cases.md](reconstructing-benchmark-cases.md) —
  how to reconstruct benchmark cases from the captured metadata.
- [docs/kanban-board-consolidation.md](kanban-board-consolidation.md) —
  the Stage 1 + Stage 2 -> `opencodebench` board migration record.
