# Stage 2.7 Tracking — Hermes Reasoning Level from `state.db`

This document describes the Stage 2.7 tracking layer. Stage 2.7
resolves the `hermes_orchestrator_reasoning_level` field that
Stage 2.6 introduced but could only populate with the literal string
`"unavailable"` on most hosts. Stage 2.7 adds a targeted read of
`state.db.sessions.model_config.reasoning_config.effort` — a single
`json_extract` path against a single TEXT column in one row — and
a precedence chain that falls back through the WebUI session JSON
scalars to `"unavailable"`.

If you have not read the prior stage docs, start there:

- [docs/task-capture-wrapper.md](task-capture-wrapper.md) — Stage 1
  wrapper, command shape, sidecar files.
- [docs/stage-2-tracking.md](stage-2-tracking.md) — Stage 2 worker
  metadata (`model_id`, `task_type`, `duration_seconds`, etc.).
- [docs/stage-25-tracking.md](stage-25-tracking.md) — Stage 2.5 raw
  Hermes context pointers and worker-prompt capture.
- [docs/stage-26-tracking.md](stage-26-tracking.md) — Stage 2.6 safe
  Hermes orchestrator metadata capture (the layer this doc refines).
- [docs/stage-26-card-1-inventory.md](stage-26-card-1-inventory.md) —
  the read-only inventory of allow-listed WebUI session JSON fields.

Stage 2.7 is purely additive. It inherits the Stage 1 wrapper,
command shape, and sidecar layout. It never renames a Stage 1, 2,
2.5, or 2.6 key, never removes a field, and never changes the
meaning of an existing field. The Stage 2.6
`hermes_orchestrator_reasoning_level` field name is kept; its
valid-value set is expanded from `{..., "unavailable"}` to include
the seven new canonical levels. **No new sidecar file is introduced.**

## Design goals

1. Populate `hermes_orchestrator_reasoning_level` with the
   orchestrator's actual reasoning effort level when it can be
   discovered safely, and with the literal string `"unavailable"`
   when it cannot.
2. Read `state.db` through a single targeted `json_extract` path —
   never `SELECT *`, never the `system_prompt` column, never the
   `messages` table.
3. Preserve the Stage 2.6 precedence chain (`context_engine` →
   `compression_anchor_mode`) as a fallback, and the literal
   `"unavailable"` as the final fallback.
4. Provide an explicit env-var override (`OPENCODEBENCH_HERMES_REASONING_LEVEL`)
   and a per-stage opt-out (`OPENCODEBENCH_SKIP_HERMES_REASONING=1`)
   so callers can force a value or skip reasoning-level capture
   entirely.
5. Record the provenance of the reasoning level via a
   `_source` field so that consumers can distinguish env-override,
   `state.db` read, WebUI session JSON read, unavailable, and
   skipped cases.

## What Stage 2.7 adds

1. **Three new top-level `hermes_orchestrator_*` fields in
   `metadata.json`.** All additive. None of the Stage 1/2/2.5/2.6
   fields are renamed, removed, or retyped.
2. **A dual mirror under `opencodebench.orchestrator.*`.** Same
   dual-location convention as `opencodebench.trace.*` in Stage 2.5
   and `opencodebench.orchestrator.*` in Stage 2.6.
3. **A new `OPENCODEBENCH_SKIP_HERMES_REASONING=1` opt-out.** Per-stage
   opt-out that skips the `state.db` read and the WebUI session JSON
   fallback; all three fields stay at their default values.
4. **A new `OPENCODEBENCH_HERMES_REASONING_LEVEL` env-var override.**
   When set to a non-empty value, the wrapper records the override
   value as `hermes_orchestrator_reasoning_level`, records
   `"env_override"` as the source, and still reads the `state.db`
   value into `hermes_orchestrator_reasoning_level_raw` so consumers
   can detect mismatches.

## Why full transcripts remain out of scope

The Stage 2.6 reasoning level was `"unavailable"` on this host
because the only safe sources (`context_engine` and
`compression_anchor_mode`) were both `null`. Stage 2.7 resolves this
by reading a single `json_extract` path from `state.db`. The full
transcript, `messages[*]`, run journal, turn journal, and auth/config
files remain out of scope — see
[Stage 2.6 § Why full transcripts remain out of scope](stage-26-tracking.md#why-full-transcripts-remain-out-of-scope).

## Fields captured

All three fields are top-level keys in `metadata.json` and are
mirrored under `opencodebench.orchestrator.*` per the dual-location
convention.

| Field | Type | Source | Default |
|---|---|---|---|
| `hermes_orchestrator_reasoning_level` | string | See [Precedence chain](#precedence-chain) | `"unavailable"` |
| `hermes_orchestrator_reasoning_level_source` | string | Derived from the source that produced `reasoning_level` | `"unavailable"` |
| `hermes_orchestrator_reasoning_level_raw` | string or null | The raw value from the winning source before normalization; `null` when source is `"unavailable"` or `"skipped"` | `null` |

Notes:

- The field name `hermes_orchestrator_reasoning_level` is retained
  from Stage 2.6 for backward-compatibility. A consumer that already
  reads this field from Stage 2.6 metadata will continue to receive
  the same key; the only change is that the value may now be one of
  the seven canonical levels instead of always `"unavailable"`.
- The `..._source` field is the provenance trail. Consumers should
  filter on it when they need to distinguish "state.db had a value"
  from "we gave up."
- The `..._raw` field preserves the pre-normalization string from the
  winning source. When the source is `"env_override"`, `..._raw`
  contains the actual `state.db` value (if read), so a consumer can
  detect "user claimed high but state.db says low."
- `hermes_orchestrator_reasoning_level` is a string, **not** null.
  The literal string `"unavailable"` is a valid expected outcome and
  is the only correct way to mark "we tried, but the safe source had
  no value."

## Precedence chain

The wrapper tries these sources in strict order. The first match
wins. The wrapper does not fall through to a less-safe source after
a match.

1. **`env_override`** — `OPENCODEBENCH_HERMES_REASONING_LEVEL` is
   set to a non-empty string. The wrapper records the override value
   (after normalization) as `reasoning_level` and records
   `"env_override"` as the source. When the `state.db` read also
   succeeds, the raw `state.db` value is stored in
   `reasoning_level_raw`; otherwise `reasoning_level_raw` is `null`.
2. **`state_db`** — `HERMES_HOME` is set, `$HERMES_HOME/state.db`
   exists and is readable, and the targeted query returns a non-null
   non-empty value. The wrapper records the normalized value as
   `reasoning_level` and `"state_db"` as the source.
3. **`webui_session_json`** — the Stage 2.6 fallback: `HERMES_HOME`
   and `HERMES_WEBUI_STATE_DIR` are set, the session JSON file
   exists, and either `context_engine` or `compression_anchor_mode`
   is a non-empty non-null scalar. The wrapper records the first
   non-empty non-null value (after normalization) as
   `reasoning_level` and `"webui_session_json"` as the source.
4. **`unavailable`** — none of the above produced a value. The
   wrapper records `"unavailable"` as `reasoning_level` and
   `"unavailable"` as the source.
5. **`skipped`** — `OPENCODEBENCH_SKIP_HERMES_REASONING=1` is set.
   All three fields stay at their defaults: `"unavailable"`,
   `"skipped"`, `null`.

## Normalization rules

All raw values are normalized before storage:

1. **Lowercase.**
2. **Replace spaces with underscores.**
3. **Trim leading and trailing whitespace.**

Canonical stored values:

| Raw (from source) | Normalized |
|---|---|
| `"none"` | `"none"` |
| `"Minimal"` | `"minimal"` |
| `"Low"` | `"low"` |
| `"Medium"` | `"medium"` |
| `"High"` | `"high"` |
| `"Extra High"` | `"extra_high"` |
| `"Max"` | `"max"` |
| `"unavailable"` | `"unavailable"` |

No semantic mapping is performed. `"low"` is never mapped to
`"small"`. `"extra_high"` is never collapsed to `"high"`. The
canonical value set is: `none`, `minimal`, `low`, `medium`, `high`,
`extra_high`, `max`, `unavailable`.

## Source enum

The `hermes_orchestrator_reasoning_level_source` field is one of:

| Value | Meaning |
|---|---|
| `"env_override"` | Value came from `OPENCODEBENCH_HERMES_REASONING_LEVEL`. |
| `"state_db"` | Value came from `state.db.sessions.model_config.reasoning_config.effort`. |
| `"webui_session_json"` | Value came from the WebUI session JSON `context_engine` or `compression_anchor_mode` fallback chain. |
| `"unavailable"` | No safe source produced a value. |
| `"skipped"` | `OPENCODEBENCH_SKIP_HERMES_REASONING=1` was set; all three fields stay at defaults. |

When the source is `"skipped"`, all three fields stay at their
default values: `"unavailable"`, `"skipped"`, `null`.

## Where the metadata ends up

Every Stage 2.7 tracked run still creates a new directory at:

```text
.local/coding-agent-task-logs/<year>/<month>/<task_id>/
```

Stage 2.7 does **not** add a new sidecar file to that directory.
The new fields are pure metadata additions:

- **`metadata.json`** — gains the three new top-level
  `hermes_orchestrator_reasoning_level*` fields and the dual mirror
  under `opencodebench.orchestrator.*`.
- **`hermes_trace.json`** (from Stage 2.5) — unchanged.
- **Stage 2.6 `hermes_orchestrator_*` fields** — unchanged; the
  ten Stage 2.6 fields remain as-is.

## How to invoke a tracked Stage 2.7 run

The wrapper is the same as Stage 1/2/2.5/2.6:

```text
./opencodebench-opencode --dir <repo> -m <model> ...opencode args...
```

New Stage 2.7 env vars (all optional):

| Env var | Effect | Default |
|---|---|---|
| `OPENCODEBENCH_HERMES_REASONING_LEVEL=<value>` | Explicit override. When set to a non-empty value, the wrapper records the normalized value as `reasoning_level`, `"env_override"` as the source, and the raw `state.db` value (if read) in `reasoning_level_raw`. Acceptable values: `none`, `minimal`, `low`, `medium`, `high`, `extra_high`, `max`, `unavailable`. | unset (capture falls through the precedence chain) |
| `OPENCODEBENCH_SKIP_HERMES_REASONING=1` | Skip the `state.db` read and the WebUI session JSON fallback. All three fields stay at defaults: `"unavailable"`, `"skipped"`, `null`. | unset (capture is on) |

## Privacy boundary (do-not-cross)

The wrapper's Stage 2.7 code path is allowed to read **only** the
following Hermes surfaces. Anything else is a hard-don't. The list is
normative; a reviewer can reject a Card 3 PR that adds a read not on
this list without updating both this section and the implementation.

| Surface | Read allowed? |
|---|---|
| `HERMES_*` env vars (17 known) | **Allow.** Inherited from the process env. No filesystem access. |
| `state.db.sessions.model_config` JSON column | **Allow narrowly.** Read ONLY via `SELECT json_extract(model_config, '$.reasoning_config.effort') FROM sessions WHERE id=?`. No `SELECT *`. No `system_prompt` column. No `state.db.messages`. No FTS index access. |
| WebUI session JSON `context_engine` | **Allow (existing).** Scalar only. One of the 16 Stage 2.6 allow-listed fields. |
| WebUI session JSON `compression_anchor_mode` | **Allow (existing).** Scalar only. One of the 16 Stage 2.6 allow-listed fields. |
| `messages[*].content` | **NO.** Would leak the full Hermes transcript. Stage 1 / 2.5 privacy boundary. |
| `context_messages[*]` | **NO.** Compressed transcript snapshot. |
| `composer_draft` | **NO.** User's in-progress draft input. |
| `pre_compression_snapshot` | **NO.** Marker that points at the transcript. |
| `tool_calls[*]` | **NO.** Full tool-call history. |
| `compression_anchor_details` | **NO.** Compression engine internals. |
| `compression_anchor_summary` | **NO.** Compression engine summary. |
| `gateway_routing` | **NO.** Gateway-routing object — touches the same surface as the forbidden `routing_policy_followed` label. |
| `gateway_routing_history` | **NO.** Same. |
| `~/.hermes/webui/sessions/_run_journal/...` | **NO.** Run journal — full tool-call history. |
| `~/.hermes/webui/sessions/_turn_journal/...` | **NO.** Turn journal — full transcript. |
| `~/.hermes/.env` | **NO.** Stage 1 / 2.5 privacy boundary. API keys. |
| `~/.hermes/config.yaml` | **NO.** Stage 1 / 2.5 privacy boundary. Provider / model / MCP config. |
| `~/.hermes/auth.json` | **NO.** Stage 1 / 2.5 privacy boundary. Auth tokens. |
| `~/.hermes/SOUL.md`, `MEMORY.md`, `USER.md` | **NO.** Stage 1 / 2.5 privacy boundary. Memory / persona / user profile. |
| `state.db.messages` | **NO.** Full transcript store. |
| Any interpretive label (e.g. `routing_policy_followed`, `delegated_to_opencode`, `user_intervention_needed`, `quality_score`, `success_indicator`) | **NO.** Subjective flag; Stage 3 territory, never in raw data. |

### Implementation contract (for Card 3)

The only acceptable `state.db` read is the targeted projection:

```sql
SELECT json_extract(model_config, '$.reasoning_config.effort')
  FROM sessions WHERE id=?;
```

The wrapper MUST NOT:

- `SELECT *` from any table.
- Select the `system_prompt` column.
- Read from the `messages` table.
- Access the FTS index.
- Read any row by any column other than the session id.

Card 3's grep-audit will verify this constraint.

## Validation matrix (Card 4 fills in actual values)

| Case | Caller | `..._reasoning_level` | `..._source` | `..._raw` |
|---|---|---|---|---|
| 1 | WebUI run, no override | `"<normalized value of MiniMax M3 effort on this host>"` | `"state_db"` | `"<raw value from state.db>"` |
| 2 | WebUI with `OPENCODEBENCH_HERMES_REASONING_LEVEL=extra_high` | `"extra_high"` | `"env_override"` | `"<raw value from state.db>"` |
| 3 | WebUI with `OPENCODEBENCH_HERMES_REASONING_LEVEL=unavailable` | `"unavailable"` | `"env_override"` | `"<raw value from state.db>"` |
| 4 | Plain shell, no `HERMES_*` env | `"unavailable"` | `"unavailable"` | `null` |
| 5 | WebUI with `OPENCODEBENCH_SKIP_HERMES_REASONING=1` | `"unavailable"` | `"skipped"` | `null` |

`hermes_orchestrator_reasoning_level` is a string, **not** null. The
literal string `"unavailable"` is a valid expected outcome and is the
only correct way to mark "we tried, but the safe source had no
value". This is consistent with the Stage 2.5
`hermes_user_prompt_source="unavailable"` convention and the Stage
2.6 `hermes_orchestrator_reasoning_level="unavailable"` convention.

## Worked example (typical WebUI run)

A typical WebUI run with the MiniMax M3 orchestrator on this host,
where `state.db` contains `reasoning_config.effort = "low"`:

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
  "hermes_orchestrator_reasoning_level": "low",
  "hermes_orchestrator_reasoning_level_source": "state_db",
  "hermes_orchestrator_reasoning_level_raw": "low",
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
      "reasoning_level": "low",
      "reasoning_level_source": "state_db",
      "reasoning_level_raw": "low",
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
  "hermes_orchestrator_reasoning_level_source": "unavailable",
  "hermes_orchestrator_reasoning_level_raw": null,
  "hermes_orchestrator_capture_source": "none"
}
```

## What is **not** captured

Stage 2.7 is strict about what it does not read or write. In addition
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
  `quality_score`, `success_indicator`, or any other flag that requires
  the wrapper to *judge* the run are not in the schema. A Stage 3
  analysis tool may compute them on top of the raw data; the raw data
  does not contain them.
- **No reasoning level derived from `gateway_routing`.** The
  `gateway_routing` object is the closest thing to a "reasoning level"
  in the WebUI session JSON on some hosts, but its contents relate to
  model-routing policy — exactly the surface the user instruction
  named as forbidden (and that the Stage 2.5 design correction was
  written to prevent Stage 2.6 from re-introducing). Stage 2.7
  resolves the reasoning-level gap via `state.db` instead.
- **No `state.db` whole-row reads.** The wrapper reads one column from
  one row via a single `json_extract` path. It does not `SELECT *`,
  does not select `system_prompt`, does not select any row by any
  column other than the session id.
- **No new sidecar file.** All Stage 2.7 information lives in
  `metadata.json` (top-level fields and dual mirror under
  `opencodebench.orchestrator.*`). The Stage 2.5 `hermes_trace.json`
  is unchanged.
- **No full Hermes state copy.** The `hermes_trace.json` pointer
  sidecar still points at the WebUI session JSON; the new
  `hermes_orchestrator_*` fields are scalars read from the `state.db`
  and the WebUI session JSON, not a copy of either file.

## Privacy and security

In addition to the "what is not captured" list above:

1. **Path leakage unchanged from Stage 2.6.**
   `hermes_orchestrator_workspace` and
   `hermes_orchestrator_worktree_path` reveal the user's directory
   layout and username. Stage 1/2 already capture `repo_path` and
   `opencode_executable_path`; Stage 2.5 already captures
   `hermes_home` and `hermes_webui_state_dir`. Stage 2.7 does not
   add new path surfaces. Mitigation: this is a local-only capture,
   and the README's "keep them ignored and private" guidance already
   covers the fields.
2. **Session-id leakage unchanged.**
   `hermes_orchestrator_session_id` reveals the live WebUI session
   id. It is the same session id Stage 2.5 already captures as
   `hermes_session_id`. Stage 2.7 does not introduce a new
   capability exposure.
3. **No credential exposure.** None of the new fields contain API
   keys, OAuth tokens, or any other secret. The wrapper reads only
   a single `json_extract` path from the `model_config` TEXT column
   in `state.db`.
4. **Redaction asymmetry inherited.** `HERMES_REDACT_SECRETS=***` is
   exported; the WebUI already redacts secrets in its own outputs.
   The wrapper inherits whatever Hermes redacts and does not attempt
   its own redaction.
5. **`OPENCODEBENCH_HERMES_REASONING_LEVEL` override transparency.**
   The `..._source="env_override"` value makes the override explicit.
   The `..._raw` field still records the actual `state.db` value when
   the override disagrees, so a consumer can detect "user claimed
   high but state.db says low."
6. **`state.db` schema drift.** If a future Hermes release renames the
   `effort` key, the targeted `json_extract` returns NULL and the
   chain falls through to the WebUI scalar chain (or `"unavailable"`).
   No wrapper crash, no data corruption.
7. **`state.db` is opened read-only.** The wrapper's `sqlite3`
   invocation passes no writable flags. The `state.db` file is not
   modified.

## Stage 3 deferred work

Stage 2.7 is the foundation. The following analyses are **deferred**
to a future Stage 3, and only on **explicit user opt-in**. None of
them are implemented in Stage 2.7, and the raw data Stage 2.7
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
- ~~**Reasoning level backfill from `gateway_routing`.~~ Moved to
  Stage 2.7 done state — see `state.db.sessions.model_config.reasoning_config.effort`
  in this doc. The `gateway_routing` surface remains forbidden; the
  reasoning level is now sourced from `state.db` instead.

## Known limitations

1. **The wrapper assumes a single `state.db` location.** The path is
   `$HERMES_HOME/state.db`. If a future Hermes release moves the
   database, the `state.db` read returns NULL and the chain falls
   through to the WebUI scalar chain (or `"unavailable"`).
2. **The wrapper assumes a stable JSON shape inside `model_config`.**
   If Hermes changes the key path from `reasoning_config.effort` to
   something else, the targeted `json_extract` returns NULL and the
   chain falls through. No crash, no corruption — just an
   `"unavailable"` fallback.
3. **The canonical value set is opinionated.** If a future provider
   adds a reasoning level outside `{none, minimal, low, medium, high,
   extra_high, max}`, the normalized value is whatever the
   lowercase-and-underscore rule produces and the consumer will need
   to learn it.
4. **The `OPENCODEBENCH_HERMES_REASONING_LEVEL` env override trusts
   the caller.** A caller who sets `=high` when `state.db` says
   `low` will get `reasoning_level="high"`,
   `reasoning_level_source="env_override"`, and
   `reasoning_level_raw="low"`. The raw field makes the mismatch
   visible but does not prevent it.

## See also

- [docs/task-capture-wrapper.md](task-capture-wrapper.md) — Stage 1
  wrapper docs (the foundation this Stage 2.7 doc layers on).
- [docs/stage-2-tracking.md](stage-2-tracking.md) — Stage 2 worker
  tracking (the layer Stage 2.7 adds to).
- [docs/stage-25-tracking.md](stage-25-tracking.md) — Stage 2.5 raw
  Hermes trace capture (the layer Stage 2.7 sits next to).
- [docs/stage-26-tracking.md](stage-26-tracking.md) — Stage 2.6 safe
  Hermes orchestrator metadata capture (the layer this doc refines).
- [docs/stage-26-card-1-inventory.md](stage-26-card-1-inventory.md) —
  the read-only inventory of allow-listed fields.
- [docs/current-openbench-model-routing.md](current-openbench-model-routing.md) —
  worker selection and provider-failure handling policy.
