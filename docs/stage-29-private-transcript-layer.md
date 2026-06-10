# Stage 2.9 — Private Hermes Transcript Layer

This document describes the **private, local-only** transcript
layer that Stage 2.9 introduces. Its purpose is to **import** Hermes
WebUI conversation data and **link** it to the OpenCodeBench task
logs already captured by Stages 1, 2, 2.5, 2.6, and 2.7, without ever
publishing raw transcripts or private data to GitHub.

This document is the only Stage 2.9 artifact that is allowed to be
Git-tracked. The database, the importer, the validation report, and
any backup of the database are all **private / local-only**.

If you have not read the prior stage docs, start there:

- [docs/task-capture-wrapper.md](task-capture-wrapper.md) — Stage 1
  wrapper, command shape, sidecar files.
- [docs/stage-2-tracking.md](stage-2-tracking.md) — Stage 2 worker
  metadata (`model_id`, `task_type`, `duration_seconds`, etc.).
- [docs/stage-25-tracking.md](stage-25-tracking.md) — Stage 2.5 raw
  Hermes context pointers and worker-prompt capture.
- [docs/stage-26-tracking.md](stage-26-tracking.md) — Stage 2.6 safe
  Hermes orchestrator metadata capture.
- [docs/stage-26-card-1-inventory.md](stage-26-card-1-inventory.md) —
  the read-only inventory of allow-listed WebUI session JSON fields.
- [docs/stage-27-tracking.md](stage-27-tracking.md) — Stage 2.7
  reasoning-level capture from `state.db`.
- [docs/stage-27-card-3-validation.md](stage-27-card-3-validation.md) —
  the Stage 2.7 validation report (the field set that Stage 2.9 must
  still find in sampled task logs).
- [docs/current-openbench-model-routing.md](current-openbench-model-routing.md) —
  the worker-routing policy. Stage 2.9 implementation must delegate
  through `opencodebench-opencode` per `AGENTS.md`.

Stage 2.9 is purely additive to the Git-tracked surface. It does
**not** rename a Stage 1 / 2 / 2.5 / 2.6 / 2.7 key, does **not**
remove a field, and does **not** change the meaning of an existing
field. It introduces exactly one new file in the Git-tracked tree:
this design doc. Everything else lives under
`.local/private-analysis/`, which is matched by the existing
`.local/` rule in `.gitignore` (line 7).

## Design goals

1. Make Hermes prompting/response data **available for private local
   analysis**, on the user's machine, on explicit opt-in, without
   exposing it to GitHub.
2. Keep the **public GitHub surface limited to schema and
   documentation**. No raw transcript text, no raw prompts, no raw
   responses, no raw tool outputs, no raw WebUI session JSON, no raw
   `state.db`, and no raw `metadata.json` / `hermes_trace.json` /
   `worker_prompt.md` sidecar contents may ever appear in a
   Git-tracked file.
3. Make the link from a Hermes conversation to an OpenCodeBench task
   log **structural**, not narrative, so that future analysis can
   join on stable keys.
4. Apply a conservative secret-handling rule: scan transcript text
   for obvious secret-like values, **redact them before storing**,
   count the matches, and never print the values themselves.
5. Make backup a **deliberate, user-approved step** that happens
   before any Stage 3 analysis and is not auto-invoked by the
   importer.

## Why this stage exists

Stage 2.5 captures a best-effort `hermes_user_prompt.md` sidecar
that is bounded by a 60-second liveness window. By the time a
wrapper is invoked during assistant streaming, the field is usually
`null` and the orchestrator's prompt is lost for that run. The
Stage 2.6 / 2.7 capture layers keep the privacy boundary strict —
they do **not** read `messages[*]`, the run journal, the turn
journal, or any `state.db.messages` row. The user's MVP assumption
in the Stage 2.9 brief is: *"I know Hermes chats may be tracked
locally for analysis."* That assumption is what unlocks a private
importer that goes past the Stage 2.5 / 2.6 / 2.7 boundary, **on the
local machine only**, and never onto GitHub.

## What Stage 2.9 adds

1. **A new design doc** — this file. The only Git-tracked artifact
   of Stage 2.9.
2. **A new importer script** under `scripts/` (e.g.
   `scripts/import_hermes_transcripts.py` or
   `scripts/import-hermes-transcripts.sh`). Git-tracked, but it
   reads only the documented private inputs and writes only to
   `.local/private-analysis/`.
3. **A new private SQLite database** at
   `.local/private-analysis/hermes_transcripts.sqlite`. Not
   Git-tracked (matched by the existing `.local/` rule in
   `.gitignore`).
4. **A new validation report** at `docs/stage-29-validation.md`.
   Git-tracked; describes counts, schema, links, and a
   secret/redaction summary. Contains no transcript text.

## Allowed local input sources

The importer may read the following paths on the local machine
**only**. It must not read any other path under `~/.hermes/`, and
it must not read any file under `~/.config/`, `~/.ssh/`,
`~/.aws/`, `~/.netrc`, `~/.docker/config.json`, or any shell
history file.

| Path | Why it is safe to read |
|---|---|
| `~/.hermes/webui/sessions/*.json` | The per-session JSON the WebUI writes. Read via a narrow, allow-listed projection, not as a whole. |
| `~/.hermes/state.db` | Read only via a narrow `json_extract` path on the `sessions` row's `model_config` blob, mirroring the Stage 2.7 read shape. The `messages` table is **not** read. |
| `.local/coding-agent-task-logs/YYYY/MM/<task_id>/metadata.json` | Already captured by the OpenCodeBench wrapper. Local-only. |
| `.local/coding-agent-task-logs/YYYY/MM/<task_id>/hermes_trace.json` | Pointer-only sidecar from Stage 2.5. Local-only. |
| `.local/coding-agent-task-logs/YYYY/MM/<task_id>/worker_prompt.md` | Reliable worker prompt sidecar from Stage 2.5. Local-only. |
| `.hermes/stage-*/` evidence directories | Local evidence the user already collects for stage audits. Read-only. |

If the importer ever needs to read a path that is **not** on this
list, it must stop and ask the user before proceeding.

## What is Git-allowed in this design doc and in the validation report

- Schema, table names, column names, types, indexes.
- Counts: sessions scanned, messages imported, task-log links
  resolved, secret-like matches.
- File paths relative to the project root (e.g.
  `docs/stage-29-validation.md`,
  `scripts/import_hermes_transcripts.py`).
- High-level descriptions of the linking strategy.
- The secret-handling rule and the redaction policy.

## What must stay private / local-only

The following must **never** appear in any Git-tracked file, in any
commit message, in any GitHub issue, in any pull request, or in any
public report:

- Raw Hermes transcript text.
- Raw user prompts (the messages the user typed into Hermes).
- Raw Hermes assistant responses.
- Raw worker prompts (`worker_prompt.md` contents).
- Raw tool outputs from Hermes.
- Raw `metadata.json` sidecars.
- Raw `hermes_trace.json` sidecars.
- Raw `state.db` (in any form, full or partial).
- Raw WebUI session JSON (in any form, full or partial).
- `.local/private-analysis/*.sqlite` (the database itself).
- Any backup archive of the database or of the `.local/` task
  logs.
- Any real password, API key, token, SSH key, recovery phrase, or
  auth secret. If one is ever encountered, it must be redacted
  before storage and reported as a category-only count, never with
  the value.

## Local-only output location

The single canonical output of the importer is:

```text
<project_root>/.local/private-analysis/hermes_transcripts.sqlite
```

`<project_root>` is the root of this Git repository. The path is
matched by the existing `.local/` rule in `.gitignore` and is
therefore never tracked by Git. The schema is described in
[SQLite schema](#sqlite-schema) below.

## Linking strategy

The importer links a Hermes WebUI session (or any captured Hermes
conversation) to an OpenCodeBench task log using the following
stable keys, in this precedence order:

1. `hermes_session_id` — the Hermes session id. This is the
   primary join key when present. It is recorded in Stage 2.5
   `hermes_trace.json` and in Stage 2.6 `metadata.json` as
   `hermes_orchestrator_session_id` and as the
   `HERMES_SESSION_ID` env var captured by the wrapper.
2. `hermes_session_chat_id` — the WebUI session's per-chat id,
   when the WebUI session JSON exposes it. Used as a secondary
   join key.
3. `hermes_orchestrator_session_id` — the Stage 2.6 mirror of
   `hermes_session_id` in `metadata.json`. Used when the
   WebUI session JSON does not carry the original session id.
4. Timestamps — when the WebUI session JSON carries a creation
   timestamp and a last-update timestamp, those are used to
   narrow the candidate task log set.
5. Task directory path — the importer walks
   `.local/coding-agent-task-logs/YYYY/MM/<task_id>/` and indexes
   every `metadata.json` it finds, so the join can resolve
   even if a session id is missing.
6. Worker prompt hash / path — the SHA-256 of
   `worker_prompt.md`, recorded at importer time and at task-log
   capture time. Used to detect when a captured session is the
   one that produced a given worker invocation.

A single session may link to many task logs (one session can
trigger many wrapper runs), and a single task log may link to
many sessions (one wrapper run can be re-invoked from different
sessions). The schema is therefore a many-to-many join table,
not a foreign key on either side.

## SQLite schema

The schema is deliberately small and additive. All timestamps
are stored as ISO-8601 strings, not as Unix epoch numbers, so
that local-time introspection is human-readable. The schema
matches the "content fields, not interpretive fields" rule from
the Stage 2.5 design correction: this layer captures **what was
observed**, not **what the observer thinks of it**.

```text
sessions (
  session_id              TEXT PRIMARY KEY,        -- Hermes session id
  chat_id                 TEXT,                    -- WebUI per-chat id
  profile                 TEXT,                    -- Hermes profile
  model                   TEXT,                    -- Hermes model name
  provider                TEXT,                    -- Hermes model provider
  reasoning_level         TEXT,                    -- reasoning effort, when known
  created_at              TEXT,                    -- ISO-8601, when known
  updated_at              TEXT,                    -- ISO-8601, when known
  source_path             TEXT NOT NULL,           -- path to the WebUI session JSON
  imported_at             TEXT NOT NULL,           -- ISO-8601, importer run time
  message_count           INTEGER NOT NULL DEFAULT 0
)

messages (
  session_id              TEXT NOT NULL,           -- FK -> sessions.session_id
  message_seq             INTEGER NOT NULL,        -- 1-based sequence within the session
  role                    TEXT,                    -- user / assistant / tool / system / unknown
  timestamp               TEXT,                    -- ISO-8601, when known
  content_redacted        TEXT,                    -- text after secret redaction
  char_count              INTEGER NOT NULL,        -- length of content_redacted
  secret_like_hits        INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (session_id, message_seq)
)

task_logs (
  task_id                 TEXT PRIMARY KEY,        -- e.g. 'YYYY/MM/<task_id>'
  task_dir                TEXT NOT NULL,           -- absolute path to the task dir
  task_started_at         TEXT,                    -- ISO-8601, from metadata.json
  task_finished_at        TEXT,                    -- ISO-8601, from metadata.json
  worker_model            TEXT,                    -- metadata.model_id
  worker_prompt_sha256    TEXT,                    -- sha256(worker_prompt.md)
  worker_prompt_path      TEXT NOT NULL,           -- absolute path to worker_prompt.md
  hermes_session_id       TEXT,                    -- metadata.hermes_orchestrator_session_id
  imported_at             TEXT NOT NULL
)

session_task_links (
  session_id              TEXT NOT NULL,           -- FK -> sessions.session_id
  task_id                 TEXT NOT NULL,           -- FK -> task_logs.task_id
  link_source             TEXT NOT NULL,           -- session_id / chat_id / orchestrator_session_id / timestamp / path / worker_prompt_hash
  link_confidence         TEXT NOT NULL,           -- exact / strong / weak
  linked_at               TEXT NOT NULL,
  PRIMARY KEY (session_id, task_id, link_source)
)

import_runs (
  run_id                  INTEGER PRIMARY KEY AUTOINCREMENT,
  started_at              TEXT NOT NULL,
  finished_at             TEXT,
  sessions_scanned        INTEGER NOT NULL DEFAULT 0,
  messages_imported       INTEGER NOT NULL DEFAULT 0,
  task_logs_indexed       INTEGER NOT NULL DEFAULT 0,
  task_log_links          INTEGER NOT NULL DEFAULT 0,
  secret_like_matches     INTEGER NOT NULL DEFAULT 0,
  output_db_path          TEXT NOT NULL
)
```

Indexes (for analysis-time joins):

```text
CREATE INDEX idx_messages_session  ON messages(session_id);
CREATE INDEX idx_messages_role     ON messages(role);
CREATE INDEX idx_links_session     ON session_task_links(session_id);
CREATE INDEX idx_links_task        ON session_task_links(task_id);
CREATE INDEX idx_tasklogs_worker   ON task_logs(worker_model);
CREATE INDEX idx_tasklogs_session  ON task_logs(hermes_session_id);
```

## Secret-handling MVP rule

The importer scans message text for obvious secret-like patterns
**before** writing the message to the database. The MVP rule is:

- Patterns flagged (strict pass; never printed, only counted):
  - `sk-[A-Za-z0-9_-]{20,}` — OpenAI-style API key.
  - `AKIA[0-9A-Z]{16}` — AWS access key id.
  - `ghp_[A-Za-z0-9]{20,}` — GitHub personal access token.
  - `xox[abp]-[A-Za-z0-9-]{10,}` — Slack token.
  - `-----BEGIN [A-Z ]*PRIVATE KEY-----` … `-----END …-----` —
    PEM private key block.
  - High-entropy `password=<value>`, `token=<value>`,
    `api_key=<value>`, `secret=<value>` assignments where `<value>`
    is at least 16 characters and is not a placeholder like
    `changeme`, `example`, `<your-key-here>`.
  - `Authorization: Bearer ` followed by 16+ non-whitespace
    characters.
- Default behavior: **redact before storing**. The stored
  `content_redacted` column contains the original text with each
  match replaced by `[REDACTED:<category>]`, where `<category>` is
  one of `openai_key`, `aws_key`, `github_token`, `slack_token`,
  `private_key`, `kv_assignment`, `bearer`. The
  `secret_like_hits` column records the per-message count.
- The importer never prints matched values to stdout, stderr, or
  any log file. It only prints the per-category counts and the
  grand total.
- If unsure whether something is a secret, the importer prefers
  redaction. False positives are acceptable; false negatives are
  not.
- If a real secret is ever observed during development, the
  importer stops, the value is rotated, and the importer is rerun
  against the re-rotated source.

## Backup implications

This stage does not implement backup. The Stage 2.9 brief
explicitly defers backup to a later user-approved card. The
**minimum** backup implication that this design doc records for
later is:

- A backup of `.local/private-analysis/hermes_transcripts.sqlite`
  must happen **before** any Stage 3 analysis, because the
  analysis is read-only and should not depend on the importer
  being re-run.
- The backup itself is private; it must not be committed to
  GitHub, and it must not be uploaded to any cloud destination
  that the user has not explicitly approved.
- The backup format is undecided (raw `.sqlite` file, `.sqlite`
  + `.sqlite-journal`, `sqlite3 .backup`, or a
  `pg_dump`-equivalent). A follow-up card will pick one and
  document it before any backup command is run.

## Open follow-ups (deferred to later cards)

- A separate **export-for-sharing** command that produces a
  redacted, schema-only dump for analysis sharing. Not in scope
  for Stage 2.9.
- A **differential** importer mode that re-scans only sessions
  whose `updated_at` is newer than the last `import_runs.finished_at`.
  Not in scope for Stage 2.9; the MVP importer does a full scan.
- A **Stage 3** analysis layer that joins the private transcript
  DB to the OpenCodeBench task logs. **Explicitly not started
  in Stage 2.9.** Any Stage 3 card is gated on the user
  approving the backup step above.

## What Stage 2.9 does **not** do

- It does **not** read the user's prompt text from the live
  Hermes session during a wrapper invocation. That is the
  Stage 2.5 / 2.6 surface and is unchanged.
- It does **not** read `state.db.messages`. It reads
  `state.db.sessions.model_config.reasoning_config.effort` at
  most, mirroring the Stage 2.7 narrow-read pattern.
- It does **not** introduce any interpretive label
  (`routing_policy_followed`, `delegated_to_opencode`,
  `user_intervention_needed`, etc.). Those are Stage 3
  computations and are explicitly deferred.
- It does **not** push anything. All commits in Stage 2.9 are
  local.
- It does **not** start Stage 3. Stage 3 is gated on a separate
  user-approved plan and on the backup step above.
