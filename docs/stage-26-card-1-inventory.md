# Stage 2.6 Card 1 — Inventory of Safe Hermes Orchestrator Metadata Sources

This is a read-only inventory. No production code was changed to produce it.

The goal is to determine which of the orchestrator-metadata fields the user
asked for are available as top-level scalar fields on the WebUI session JSON
(`~/.hermes/webui/sessions/<id>.json`), and whether a reasoning / intelligence
marker can be safely discovered without reading transcript or reasoning text.

## Method

1. Listed top-level keys of five WebUI session JSON files, both live and
   archived, to characterize the schema across session ages.
2. Probed each allow-listed candidate field with a one-shot `jq` read of the
   value (string / bool / null / object / list).
3. Confirmed the **forbidden** surfaces are present in the schema (so we
   know exactly what we are NOT touching), and documented them.

The probes were scalar-only — the script never read `messages[*]`,
`context_messages`, `composer_draft`, `pre_compression_snapshot`, `tool_calls`,
`compression_anchor_details`, `compression_anchor_summary`, `gateway_routing`,
or `gateway_routing_history`. The script used one `jq` per candidate field, or
a small explicit `jq '{field1, field2, ...}'` projection that picks named
keys.

## Probed sessions

| Path | session_id | Notes |
|---|---|---|
| `~/.hermes/webui/sessions/45170b5dca91.json` | `45170b5dca91` | Live, current WebUI session. |
| `~/.hermes/webui/sessions/20260610_105656_30987f.json` | `20260610_105656_30987f` | Earlier same-day WebUI session. |
| `~/.hermes/webui/sessions/218dbb533f37.json` | `218dbb533f37` | Older WebUI session. |
| `~/.hermes/webui/sessions/20260610_001724_d8978f.json` | `20260610_001724_d8978f` | Older WebUI session. |
| `~/.hermes/webui/sessions/9b81ffd337eb.json` | `9b81ffd337eb` | Older WebUI session. |

## Allow-listed candidate fields — observed values

| Field | Type | Live (45170b5dca91) | Older sessions | Verdict |
|---|---|---|---|---|
| `session_id` | string | `45170b5dca91` | populated | **Capture** — top-level string, no transcript risk. |
| `model` | string | `MiniMax-M3` | `MiniMax-M3` (all 5) | **Capture** — this is the orchestrator model name. Stable. |
| `model_provider` | string | `minimax` | `minimax` (all 5) | **Capture** — orchestrator provider. Stable. |
| `profile` | string | `default` | `default` (all 5) | **Capture** — orchestrator Hermes profile. Stable. |
| `is_cli_session` | bool | `false` | `false` (all 5) | **Capture** — distinguishes CLI vs WebUI. Stable. |
| `workspace` | string (path) | `/Users/Jo/GitHub/coding-agent-benchmarks` | identical (all 5) | **Capture** — the active workspace at session start. Stable. |
| `source_label` | string or null | `null` | `null` (all 5) | **Capture (nullable)** — not currently populated on this host, but safe to read. |
| `session_source` | string or null | `null` | `null` (all 5) | **Capture (nullable)** — same. |
| `raw_source` | string or null | `null` | `null` (all 5) | **Capture (nullable)** — same. |
| `source_tag` | string or null | `null` | `null` (all 5) | **Capture (nullable)** — same. |
| `worktree_path` | string (path) or null | `null` | `null` (all 5) | **Capture (nullable)** — populated when the session is on a git worktree. |
| `worktree_repo_root` | string (path) or null | `null` | `null` (all 5) | **Capture (nullable)** — same. |
| `worktree_branch` | string or null | `null` | `null` (all 5) | **Capture (nullable)** — same. |
| `personality` | string or null | `null` | `null` (all 5) | **Capture (nullable)** — Hermes "personality" mode if set. |
| `context_engine` | string or null | `null` | `null` (all 5) | **Reasoning/intelligence marker candidate 1** — null on this host. |
| `compression_anchor_mode` | string or null | `null` | `null` (all 5) | **Reasoning/intelligence marker candidate 2** — null on this host. |
| `gateway_routing` | object or null | `null` (type=null) | `null` (all 5) | **Skip** — not just null; the field's semantic is gateway routing, which is the same conceptual surface the user instruction explicitly forbade as a subjective label (`routing_policy_followed`). Reading the contents would require re-opening the boundary. |
| `gateway_routing_history` | list | length 0 | length 0 (all 5) | **Skip (do not even read)** — explicitly in the user-forbidden list. |

## Reasoning / intelligence level — what to record

The user asked: "Hermes reasoning / intelligence level if safely available".

There is no top-level scalar on this host's WebUI session JSON that records
the orchestrator's reasoning or intelligence level. The closest candidates
are `context_engine` and `compression_anchor_mode`, both of which are `null`
on every session we probed.

`gateway_routing` is the only other candidate, but its contents relate to
gateway / model-routing policy — exactly the surface the user explicitly
forbade as a subjective label. Reading it would also risk re-introducing the
interpretive-label anti-pattern the Stage 2.5 design correction
(`docs/stage-25-tracking.md`) was written to prevent.

**Decision:** record the literal string `"unavailable"` for
`hermes_orchestrator_reasoning_level` when neither `context_engine` nor
`compression_anchor_mode` is a non-empty string. This is a valid expected
outcome, not a defect.

## Forbidden surfaces confirmed present (so we know what we are NOT touching)

| Surface | Type | Why we do not read it |
|---|---|---|
| `messages` | list (length 0 in this session) | Full Hermes session transcript. |
| `context_messages` | list (length 0) | Compressed / cached transcript snapshot. |
| `composer_draft` | object with `text` and `files` | User's in-progress draft input. |
| `pre_compression_snapshot` | bool marker | Triggers the wrapper to re-read the transcript. |
| `tool_calls` | list (length 0) | Full tool-call history. |
| `compression_anchor_details` | object (empty here) | Compression engine internals — touches transcript. |
| `compression_anchor_summary` | null / string | Compression engine summary — touches transcript. |
| `gateway_routing` | object or null | Touches routing policy — forbidden as a subjective label. |
| `gateway_routing_history` | list (length 0) | Same. |
| `~/.hermes/webui/sessions/_run_journal/...` | directory | Run journal — full tool-call history. |
| `~/.hermes/webui/sessions/_turn_journal/...` | directory | Turn journal — full transcript. |
| `~/.hermes/.env` | file | API keys / provider config. |
| `~/.hermes/config.yaml` | file | Provider / model / MCP config. |
| `~/.hermes/auth.json` | file | Auth tokens. |
| `~/.hermes/SOUL.md`, `MEMORY.md`, `USER.md` | file | Persona / memory / user profile. |
| `~/.hermes/state.db` (messages table) | SQLite | Full transcript store. |

## Field name → capture target (recommended)

The captured fields belong in a new `hermes_orchestrator_*` namespace in
`metadata.json` to keep them clearly distinct from:

- the existing `hermes_*` context fields (`hermes_session_id`,
  `hermes_session_chat_id`, …) which carry env-derived pointers; and
- the `model_id` and `reasoning_level` fields at the top level, which
  describe the **worker** model, not the **orchestrator** model.

| New field | Source on the WebUI session JSON | Type | Default |
|---|---|---|---|
| `hermes_orchestrator_session_id` | `session_id` | string | `""` |
| `hermes_orchestrator_model` | `model` | string | `""` |
| `hermes_orchestrator_model_provider` | `model_provider` | string | `""` |
| `hermes_orchestrator_profile` | `profile` | string | `""` |
| `hermes_orchestrator_source_label` | `source_label` \|\| `session_source` \|\| `raw_source` (precedence) | string | `"unavailable"` |
| `hermes_orchestrator_is_cli_session` | `is_cli_session` | bool | `false` |
| `hermes_orchestrator_workspace` | `workspace` | string (path) | `""` |
| `hermes_orchestrator_worktree_path` | `worktree_path` | string or null | `null` |
| `hermes_orchestrator_reasoning_level` | `context_engine` \|\| `compression_anchor_mode` (precedence) | string | `"unavailable"` |
| `hermes_orchestrator_capture_source` | derived (`"env"` if HERMES_* env non-empty and we resolved the session JSON, `"session_json"` if session JSON was read but no HERMES_* env, `"none"` otherwise) | string | `"none"` |

The dual mirror lives under `opencodebench.orchestrator.*` per the
Stage 1/2 dual-location convention. **No new sidecar file** is needed —
everything is metadata.

## Conclusion for Card 2

The orchestrator-metadata fields the user asked for are available, and they
are **safe** to read (top-level scalar fields that do not require touching
transcript, reasoning text, or auth files). Reasoning/intelligence level
cannot be discovered safely on this host — record `"unavailable"` honestly.

The privacy boundary is feasible. Card 2 (schema doc) and Card 3
(implementation) can proceed.
