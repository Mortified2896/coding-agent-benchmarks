# Stage 2.6 Tracking — Safe Hermes Orchestrator Metadata Capture

This document describes the Stage 2.6 tracking layer. Stage 2.6 captures a
**small, allow-listed subset** of Hermes orchestrator metadata, without
reading the user's full Hermes transcript, tool-call history, reasoning
text, or any auth/config secret files.

If you have not read the prior stage docs, start there:

- [docs/task-capture-wrapper.md](task-capture-wrapper.md) — Stage 1
  wrapper, command shape, sidecar files.
- [docs/stage-2-tracking.md](stage-2-tracking.md) — Stage 2 worker
  metadata (`model_id`, `task_type`, `duration_seconds`, etc.).
- [docs/stage-25-tracking.md](stage-25-tracking.md) — Stage 2.5 raw Hermes
  context pointers and worker-prompt capture.
- [docs/stage-26-card-1-inventory.md](stage-26-card-1-inventory.md) — the
  read-only inventory of allow-listed WebUI session JSON fields that
  motivates this stage.

Stage 2.6 is purely additive. It inherits the Stage 1 wrapper, command
shape, and sidecar layout. It never renames a Stage 1, 2, or 2.5 key,
never removes a field, and never changes the meaning of an existing
field. All Stage 2.6 additions appear as new top-level keys in
`metadata.json` and as a new nested object under
`opencodebench.orchestrator.*`. **No new sidecar file is introduced.**

## Design goals

1. Capture the orchestrator's model name, model provider, Hermes profile,
   session id, source label, CLI-vs-WebUI flag, workspace, and worktree
   path — top-level scalar fields that are safe to read from the WebUI
   session JSON.
2. Record reasoning / intelligence level **honestly** when it can be
   discovered safely, and as the literal string `"unavailable"` when it
   cannot. Never derive it from a surface that would require reading
   transcripts or reasoning text.
3. Do not read `messages[*]`, the run journal, the turn journal,
   `~/.hermes/.env`, `~/.hermes/config.yaml`, `~/.hermes/auth.json`,
   `~/.hermes/SOUL.md`, `~/.hermes/MEMORY.md`, `~/.hermes/USER.md`, or
   `~/.hermes/state.db` message rows. The Stage 1 / 2.5 privacy boundary
   is inherited unchanged.
4. Do not introduce any **interpretive label** such as
   `routing_policy_followed`, `delegated_to_opencode`, or
   `user_intervention_needed`. These remain Stage 3 analytical
   computations, computed on top of the raw data, on explicit user
   demand, with their own privacy opt-in.
5. Defer the **deep transcript importer** to a future stage (Stage 3 or
   later) and require it to be explicit opt-in. This is the only way to
   recover prompts that the Stage 2.5 `pending_user_message` liveness
   window missed.

## What Stage 2.6 adds

1. **Ten new top-level `hermes_orchestrator_*` fields in
   `metadata.json`.** All additive. None of the Stage 1/2/2.5 fields
   are renamed, removed, or retyped.
2. **A dual mirror under `opencodebench.orchestrator.*`.** Same
   dual-location convention as `opencodebench.trace.*` in Stage 2.5.
3. **A new `OPENCODEBENCH_SKIP_HERMES_ORCHESTRATOR=1` opt-out.** Mirrors
   the Stage 2.5 `OPENCODEBENCH_SKIP_HERMES_TRACE` opt-out.
4. **A new resolver function** in the OpenCodeBench wrapper,
   `resolve_hermes_orchestrator_metadata`, that reads only the
   allow-listed top-level scalar fields of the WebUI session JSON.
5. **Privacy boundary table** (below) — explicit allow list and explicit
   deny list, with the deny list tied to the Stage 1/2.5 boundary.

## Why full transcripts remain out of scope

The user instruction for Stage 2.6 explicitly forbids reading full
transcripts, reasoning text, run journals, turn journals, tool-call
histories, auth/config files, and any of `SOUL.md`, `MEMORY.md`, or
`USER.md`. The Stage 2.5 `pending_user_message` capture is best-effort
and bounded by a 60-second liveness window. By the time a wrapper is
invoked during assistant streaming, the field is usually `null` and the
prompt is lost for that run.

The only way to recover those lost prompts is to read
`messages[*].content` from the WebUI session JSON, the SQLite
`~/.hermes/state.db`, the run journal, or the turn journal — exactly
the surfaces the user instruction forbids Stage 2.6 from touching.
Stage 2.6 records `"unavailable"` honestly. A **Stage 3 deep
transcript importer** is the right place for that, **with explicit
opt-in** from the user. This is documented below in
[Stage 3 deferred work](#stage-3-deferred-work).

## Fields captured

All ten fields are top-level keys in `metadata.json` and are mirrored
under `opencodebench.orchestrator.*` per the dual-location convention.

| Field | Type | Source on WebUI session JSON | Precedence | Default |
|---|---|---|---|---|
| `hermes_orchestrator_session_id` | string | `session_id` | n/a | `""` |
| `hermes_orchestrator_model` | string | `model` | n/a | `""` |
| `hermes_orchestrator_model_provider` | string | `model_provider` | n/a | `""` |
| `hermes_orchestrator_profile` | string | `profile` | n/a | `""` |
| `hermes_orchestrator_source_label` | string | `source_label` \\|\\| `session_source` \\|\\| `raw_source` | first non-empty non-null wins | `"unavailable"` |
| `hermes_orchestrator_is_cli_session` | bool | `is_cli_session` | n/a | `false` |
| `hermes_orchestrator_workspace` | string (path) | `workspace` | n/a | `""` |
| `hermes_orchestrator_worktree_path` | string or null | `worktree_path` | n/a | `null` |
| `hermes_orchestrator_reasoning_level` | string | `context_engine` \\|\\| `compression_anchor_mode` | first non-empty non-null wins; else literal `"unavailable"` | `"unavailable"` |
| `hermes_orchestrator_capture_source` | string | derived: `"env"` if HERMES_* env present and we successfully read the session JSON, `"session_json"` if we read the session JSON but no HERMES_* env was set, `"none"` otherwise | n/a | `"none"` |

Notes:

- The `hermes_orchestrator_*` namespace is intentionally distinct from
  the Stage 2.5 `hermes_*` namespace. The Stage 2.5 fields are
  env-derived pointers; the Stage 2.6 fields are scalar values read
  from the WebUI session JSON. They describe **the orchestrator**, not
  the env around the wrapper.
- The Stage 2 `model_id` and `reasoning_level` (top-level) describe
  the **worker** model, not the **orchestrator** model. The new
  `hermes_orchestrator_model` and `hermes_orchestrator_reasoning_level`
  fields are different and complementary.
- `hermes_orchestrator_capture_source` is the orchestrator-side analog
  of the Stage 2.5 `hermes_capture_source` field. They are intentionally
  separate to keep the privacy boundary per-stage.

## Where the metadata ends up

Every Stage 2.6 tracked run still creates a new directory at:

```text
.local/coding-agent-task-logs/<year>/<month>/<task_id>/
```

Stage 2.6 does **not** add a new sidecar file to that directory. The
new fields are pure metadata additions:

- **`metadata.json`** — gains the ten new top-level
  `hermes_orchestrator_*` fields and the `opencodebench.orchestrator.*`
  dual mirror.
- **`hermes_trace.json`** (from Stage 2.5) — unchanged. Its pointer
  semantics still apply, and the new scalar fields do not require
  extending it.

## How to invoke a tracked Stage 2.6 run

The wrapper is the same as Stage 1/2/2.5:

```text
./opencodebench-opencode --dir <repo> -m <model> ...opencode args...
```

New Stage 2.6 env vars (all optional):

| Env var | Effect | Default |
|---|---|---|
| `OPENCODEBENCH_SKIP_HERMES_ORCHESTRATOR=1` | Skip the ten new `hermes_orchestrator_*` fields and the dual mirror. The Stage 2.5 `hermes_*` context fields are still populated. | unset (capture is on) |
| `OPENCODEBENCH_HERMES_ORCHESTRATOR_LIVENESS=off` | Reserved for future use — would let a power user disable any future liveness check on the WebUI session JSON. Unused in Stage 2.6 (no liveness is needed; the WebUI session JSON is read at `capture-task-start.sh` time, not from a pending-state field). | unset (off, because unused) |

The wrapper does not need to read the WebUI session JSON under a
liveness window — the orchestrator's model and profile do not change
mid-run, so the JSON can be read at task-start time and the values
remain valid for the whole run.

## Privacy boundary (do-not-cross)

The wrapper's Stage 2.6 code path is allowed to read **only** the
following Hermes surfaces. Anything else is a hard-don't. The list is
normative; a reviewer can reject a Card 3 PR that adds a read not on
this list without updating both this section and the implementation.

| Surface | Read allowed? | Why |
|---|---|---|
| `HERMES_*` env vars (17 known) | yes | Inherited from the process env. No filesystem access. |
| WebUI session JSON `session_id` | yes | Top-level scalar pointer. |
| WebUI session JSON `model` | yes | Orchestrator model name. Top-level scalar. |
| WebUI session JSON `model_provider` | yes | Orchestrator provider. Top-level scalar. |
| WebUI session JSON `profile` | yes | Orchestrator Hermes profile. Top-level scalar. |
| WebUI session JSON `source_label` | yes | Source tag, nullable. |
| WebUI session JSON `session_source` | yes | Source tag fallback. |
| WebUI session JSON `raw_source` | yes | Source tag fallback of fallback. |
| WebUI session JSON `is_cli_session` | yes | Bool. |
| WebUI session JSON `workspace` | yes | Path string. |
| WebUI session JSON `worktree_path` | yes | Path string, nullable. |
| WebUI session JSON `worktree_repo_root` | yes | Path string, nullable. |
| WebUI session JSON `worktree_branch` | yes | Branch string, nullable. |
| WebUI session JSON `personality` | yes | String, nullable. |
| WebUI session JSON `context_engine` | yes, scalar only | Reasoning / intelligence marker candidate. |
| WebUI session JSON `compression_anchor_mode` | yes, scalar only | Reasoning / intelligence marker candidate fallback. |
| `messages[*].content` | **NO** | Would leak the full Hermes transcript. Stage 1 / 2.5 privacy boundary. |
| `context_messages[*]` | **NO** | Compressed transcript snapshot. |
| `composer_draft` | **NO** | User's in-progress draft input. |
| `pre_compression_snapshot` | **NO** | Marker that points at the transcript. |
| `tool_calls[*]` | **NO** | Full tool-call history. |
| `compression_anchor_details` | **NO** | Compression engine internals. |
| `compression_anchor_summary` | **NO** | Compression engine summary. |
| `gateway_routing` | **NO** | Gateway-routing object — touches the same surface as the forbidden `routing_policy_followed` label. |
| `gateway_routing_history` | **NO** | Same. |
| `~/.hermes/webui/sessions/_run_journal/...` | **NO** | Run journal — full tool-call history. |
| `~/.hermes/webui/sessions/_turn_journal/...` | **NO** | Turn journal — full transcript. |
| `~/.hermes/.env` | **NO** | Stage 1 / 2.5 privacy boundary. API keys. |
| `~/.hermes/config.yaml` | **NO** | Stage 1 / 2.5 privacy boundary. Provider / model / MCP config. |
| `~/.hermes/auth.json` | **NO** | Stage 1 / 2.5 privacy boundary. Auth tokens. |
| `~/.hermes/SOUL.md`, `MEMORY.md`, `USER.md` | **NO** | Stage 1 / 2.5 privacy boundary. Memory / persona / user profile. |
| `~/.hermes/state.db` (messages table) | **NO** | Full transcript store. |
| Any interpretive label (e.g. `routing_policy_followed`, `delegated_to_opencode`, `user_intervention_needed`, `quality_score`) | **NO** | Subjective flag; Stage 3 territory, never in raw data. |

### Implementation contract (for Card 3)

The `resolve_hermes_orchestrator_metadata` function in the wrapper MUST
use a `jq` projection that picks only the named allow-listed fields,
**never `jq '.'`**. Acceptable shapes:

```sh
jq -r '.session_id // ""'               "$session_json"
jq -r '.model // ""'                    "$session_json"
jq -r '.model_provider // ""'           "$session_json"
jq -r '.profile // ""'                  "$session_json"
jq -r '.is_cli_session // false'        "$session_json"
jq -r '.workspace // ""'                "$session_json"
jq -r '.worktree_path // null'          "$session_json"
```

Or a single projection that picks all 16 named fields at once:

```sh
jq '{session_id, model, model_provider, profile, source_label,
     session_source, raw_source, is_cli_session, workspace,
     worktree_path, worktree_repo_root, worktree_branch, personality,
     context_engine, compression_anchor_mode}' "$session_json"
```

The implementation MUST be grep-checked during Card 4 validation to
ensure no field outside this allow list is read.

## Validation matrix (Card 4 fills in actual values)

| Case | Caller | `hermes_capture_source` (Stage 2.5) | `hermes_orchestrator_capture_source` | `hermes_orchestrator_model` | `hermes_orchestrator_reasoning_level` |
|---|---|---|---|---|---|
| 1 | WebUI (this session) | `env` | `env` | `MiniMax-M3` (actual) | `"unavailable"` (actual) |
| 2 | WebUI with no `HERMES_HOME` / `HERMES_WEBUI_STATE_DIR` env | `env` | `none` (cannot dereference session JSON) | `""` | `"unavailable"` |
| 3 | Plain shell (no `HERMES_*` env) | `none` | `none` | `""` | `"unavailable"` |
| 4 | WebUI where `context_engine` and `compression_anchor_mode` are both null | `env` | `env` | actual | `"unavailable"` (literal string) |
| 5 | WebUI where `context_engine = "thinking"` and `compression_anchor_mode = "summary"` | `env` | `env` | actual | `"thinking"` (first non-empty wins) |
| 6 | `OPENCODEBENCH_SKIP_HERMES_ORCHESTRATOR=1` is set | `env` | (skipped, all fields empty) | `""` | `"unavailable"` |

`hermes_orchestrator_reasoning_level` is a string, **not** null. The
literal string `"unavailable"` is a valid expected outcome and is the
only correct way to mark "we tried, but the safe source had no
value". This is consistent with the Stage 2.5
`hermes_user_prompt_source="unavailable"` convention.

## Worked example (typical WebUI run)

The current live WebUI session (this run) has:

- `session_id = "45170b5dca91"`
- `model = "MiniMax-M3"`
- `model_provider = "minimax"`
- `profile = "default"`
- `is_cli_session = false`
- `workspace = "/Users/Jo/GitHub/coding-agent-benchmarks"`
- `source_label = null`, `session_source = null`, `raw_source = null`
- `worktree_path = null`
- `context_engine = null`, `compression_anchor_mode = null`

With `HERMES_HOME` and `HERMES_WEBUI_STATE_DIR` exported by the WebUI
runtime, the wrapper produces these Stage 2.6 entries in
`metadata.json`:

```json
{
  "hermes_orchestrator_session_id": "45170b5dca91",
  "hermes_orchestrator_model": "MiniMax-M3",
  "hermes_orchestrator_model_provider": "minimax",
  "hermes_orchestrator_profile": "default",
  "hermes_orchestrator_source_label": "unavailable",
  "hermes_orchestrator_is_cli_session": false,
  "hermes_orchestrator_workspace": "/Users/Jo/GitHub/coding-agent-benchmarks",
  "hermes_orchestrator_worktree_path": null,
  "hermes_orchestrator_reasoning_level": "unavailable",
  "hermes_orchestrator_capture_source": "env",
  "opencodebench": {
    "orchestrator": {
      "session_id": "45170b5dca91",
      "model": "MiniMax-M3",
      "model_provider": "minimax",
      "profile": "default",
      "source_label": "unavailable",
      "is_cli_session": false,
      "workspace": "/Users/Jo/GitHub/coding-agent-benchmarks",
      "worktree_path": null,
      "reasoning_level": "unavailable",
      "capture_source": "env"
    }
  }
}
```

A direct non-Hermes run (no `HERMES_*` env) produces:

```json
{
  "hermes_orchestrator_session_id": "",
  "hermes_orchestrator_model": "",
  "hermes_orchestrator_model_provider": "",
  "hermes_orchestrator_profile": "",
  "hermes_orchestrator_source_label": "unavailable",
  "hermes_orchestrator_is_cli_session": false,
  "hermes_orchestrator_workspace": "",
  "hermes_orchestrator_worktree_path": null,
  "hermes_orchestrator_reasoning_level": "unavailable",
  "hermes_orchestrator_capture_source": "none"
}
```

## What is **not** captured

Stage 2.6 is strict about what it does not read or write. In addition
to the in-schema forbidden surfaces listed in
[Privacy boundary](#privacy-boundary-do-not-cross), the following are
also out of scope:

- **No full Hermes session transcripts.** The wrapper does not read
  `messages[*]`, the run journal, the turn journal, the agent log, or
  any other source that contains a full conversation.
- **No `messages[*]` scraping.** If a desired field is not on the
  allow list, the wrapper records `"unavailable"` and gives up. It does
  not scan the session JSON `messages` array to find a candidate.
- **No `~/.hermes/.env`, `config.yaml`, `auth.json` reads.** Stage 1 / 2.5
  privacy boundary, inherited.
- **No `SOUL.md`, `MEMORY.md`, `USER.md` reads.** Stage 1 / 2.5
  privacy boundary, inherited.
- **No `state.db.messages` reads.** Stage 1 / 2.5 privacy boundary,
  inherited.
- **No interpretive labels.** `routing_policy_followed`,
  `delegated_to_opencode`, `user_intervention_needed`,
  `quality_score`, or any other flag that requires the wrapper to
  *judge* the run are not in the schema. A Stage 3 analysis tool may
  compute them on top of the raw data; the raw data does not contain
  them.
- **No reasoning level derived from `gateway_routing`.** The
  `gateway_routing` object is the closest thing to a "reasoning level"
  in the WebUI session JSON on some hosts, but its contents relate to
  model-routing policy — exactly the surface the user instruction
  named as forbidden (and that the Stage 2.5 design correction was
  written to prevent Stage 2.6 from re-introducing). If
  `context_engine` and `compression_anchor_mode` are both null, the
  reasoning level is recorded as the literal string `"unavailable"`,
  not derived from `gateway_routing`.
- **No new sidecar file.** All Stage 2.6 information lives in
  `metadata.json` (top-level fields and dual mirror under
  `opencodebench.orchestrator.*`). The Stage 2.5 `hermes_trace.json`
  is unchanged.
- **No full Hermes state copy.** The `hermes_trace.json` pointer
  sidecar still points at the WebUI session JSON; the new
  `hermes_orchestrator_*` fields are scalars read from that JSON, not
  a copy of the file.

## Privacy and security

In addition to the "what is not captured" list above:

1. **Path leakage.** `hermes_orchestrator_workspace` and
   `hermes_orchestrator_worktree_path` reveal the user's directory
   layout and username. Stage 1/2 already capture `repo_path` and
   `opencode_executable_path`; Stage 2.5 already captures
   `hermes_home` and `hermes_webui_state_dir`. Stage 2.6 adds two
   more, both of which the user already has in the WebUI session
   JSON and chose to share by being on this host. Mitigation: this is
   a local-only capture, and the README's "keep them ignored and
   private" guidance already covers the new fields.
2. **Session-id leakage.** `hermes_orchestrator_session_id` reveals
   the live WebUI session id. It is the same session id Stage 2.5
   already captures as `hermes_session_id`. Stage 2.6 does not
   introduce a new capability exposure.
3. **No credential exposure.** None of the new fields contain API
   keys, OAuth tokens, or any other secret. The wrapper reads only
   non-secret top-level scalars on the WebUI session JSON.
4. **Re-daction asymmetry.** `HERMES_REDACT_SECRETS=***` is exported;
   the WebUI already redacts secrets in its own outputs. The wrapper
   inherits whatever Hermes redacts and does not attempt its own
   redaction.
5. **Empty `HERMES_*` vars in non-Hermes invocations.** If a user
   runs `opencodebench-opencode` directly from a plain shell, every
   `hermes_orchestrator_*` field is the empty string / `false` /
   `null` / `"unavailable"`, and `hermes_orchestrator_capture_source`
   is `"none"`. Downstream analysis can
   `WHERE hermes_orchestrator_capture_source != 'none'` to filter
   for tracked-Hermes runs.
6. **Skew between WebUI session JSON and `HERMES_*` env.** If the
   WebUI session JSON is older than the current `HERMES_SESSION_ID`
   (e.g. the user switched sessions), the captured
   `hermes_orchestrator_session_id` and `hermes_session_id` will
   refer to different sessions. This is not new in Stage 2.6 — it
   already happens in Stage 2.5 between `hermes_session_id` and
   `hermes_session_chat_id`. The Stage 2.5
   `hermes_capture_source="env"` field tells the consumer that
   *some* `HERMES_*` env was set; Stage 2.6's
   `hermes_orchestrator_capture_source` is the orchestrator-side
   analog.

## Stage 3 deferred work

Stage 2.6 is the foundation. The following analyses are **deferred**
to a future Stage 3, and only on **explicit user opt-in**. None of
them are implemented in Stage 2.6, and the raw data Stage 2.6
captures does not contain them.

- **Deep transcript importer.** Read `messages[*].content` from the
  WebUI session JSON (or the SQLite `~/.hermes/state.db` messages
  table) to recover prompts the Stage 2.5 `pending_user_message`
  liveness window missed. **Explicit user opt-in required.** This
  is the only way to get a complete prompt record, and it requires
  re-opening the privacy boundary.
- **Routing-policy scoring.** Given `OPENCODEBENCH_UPSTREAM_ORCHESTRATOR`,
  the worker `model_id`, the captured `worker_prompt`, and now the
  captured `hermes_orchestrator_model`, score whether the routing
  policy in
  [docs/current-openbench-model-routing.md](current-openbench-model-routing.md)
  was followed. This is an **interpretive label** and must not be
  added to the raw data; it is computed by Stage 3 only.
- **Intervention counts.** Given `hermes_user_prompt_source`,
  `hermes_user_prompt_chars`, and the wrapper invocation timing, count
  turns that needed user intervention. Interpretive; not in raw data.
- **Cross-run join keys.** Use `hermes_orchestrator_session_id` +
  `worker_prompt_sha256` to group runs by Hermes session, then
  compute per-session aggregate statistics (e.g. success rate per
  session, average `duration_seconds` per session).
- **Reasoning level backfill from `gateway_routing`** — superseded
  by Stage 2.7 (`state.db.sessions.model_config.reasoning_config.effort`).
  See `docs/stage-27-tracking.md`.

## Known limitations

- **Reasoning / intelligence level is `"unavailable"` on most hosts.**
  The only safe sources are `context_engine` and
  `compression_anchor_mode`, both of which are `null` on this host's
  live WebUI session. The `gateway_routing` object is the other
  candidate, but its contents touch the same surface the user
  instruction explicitly forbade as a subjective label. Stage 2.6
  records `"unavailable"` honestly. A future Hermes/WebUI release
  that populates `context_engine` with a string marker will be
  picked up automatically with no wrapper change.
- **The `source_label`, `session_source`, and `raw_source` fields are
  all `null` on this host.** This is consistent across the five
  WebUI sessions probed in Card 1. The wrapper falls through the
  precedence chain (`source_label` → `session_source` → `raw_source`)
  and records `"unavailable"` when all three are null.
- **The session JSON can change between `capture-task-start.sh` and
  `capture-task-finish.sh`.** Stage 2.6 reads the JSON at task-start
  time, like Stage 2.5 does for `pending_user_message`. The
  orchestrator's model and profile are not expected to change
  mid-run, so this is safe in practice.

## See also

- [docs/task-capture-wrapper.md](task-capture-wrapper.md) — Stage 1
  wrapper docs (the foundation this Stage 2.6 doc layers on).
- [docs/stage-2-tracking.md](stage-2-tracking.md) — Stage 2 worker
  tracking (the layer Stage 2.6 adds to).
- [docs/stage-25-tracking.md](stage-25-tracking.md) — Stage 2.5 raw
  Hermes trace capture (the layer Stage 2.6 sits next to).
- [docs/stage-26-card-1-inventory.md](stage-26-card-1-inventory.md) —
  the read-only inventory of allow-listed fields.
- [docs/stage-27-tracking.md](stage-27-tracking.md) — Stage 2.7
  reasoning level from `state.db` (the layer that resolves the
  `hermes_orchestrator_reasoning_level` field).
- [docs/current-openbench-model-routing.md](current-openbench-model-routing.md) —
  worker selection and provider-failure handling policy.
