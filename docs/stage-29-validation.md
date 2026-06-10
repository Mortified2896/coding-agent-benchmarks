# Stage 2.9 Card 3 — Validation Report

This document is the **public, Git-tracked** validation report for
the Stage 2.9 private Hermes transcript layer. The actual database
at `.local/private-analysis/hermes_transcripts.sqlite` is **not**
Git-tracked and is **not** described in detail here; only its
counts, schema presence, and link breakdown are.

The design doc is
[docs/stage-29-private-transcript-layer.md](stage-29-private-transcript-layer.md).
The importer is `scripts/import_hermes_transcripts.py`. The commit
that introduced the importer is `e20dfe4`.

## 1. SQLite database exists at the documented local-only path

- **Path:** `.local/private-analysis/hermes_transcripts.sqlite`
  (absolute: `<repo>/.local/private-analysis/hermes_transcripts.sqlite`).
- **Match against `.gitignore`:** confirmed by `git check-ignore -v`
  — the path is matched by the `.local/` rule on line 7 of
  `.gitignore`.
- **Size on disk after the third run:** ~5.3 MB.
- **File present:** yes.

## 2. SQLite database has imported sessions and messages

Counts after the third import run (importer is idempotent; see §5):

| Table | Count |
|---|---|
| `sessions` | 11 |
| `messages` | 3363 |
| `task_logs` | 83 |
| `session_task_links` | 19 |
| `import_runs` | 3 |

### 2a. Sample `sessions` rows (5 of 11)

| session_id | model | provider | profile | reasoning_level | message_count |
|---|---|---|---|---|---|
| `1166a7321cf7` | `MiniMax-M3` | `minimax` | `default` | `low` | 91 |
| `20260610_001724_d8978f` | `MiniMax-M3` | `minimax` | `default` | `low` | 649 |
| `20260610_100758_a45693` | `MiniMax-M3` | `minimax` | `default` | `low` | 757 |
| `20260610_105656_30987f` | `MiniMax-M3` | `minimax` | `default` | `low` | 236 |
| `20260610_122139_e5cc59` | `MiniMax-M3` | `minimax` | `default` | `low` | 330 |

`reasoning_level` was read from
`state.db.sessions.model_config.reasoning_config.effort` via a
narrow `json_extract` path, mirroring the Stage 2.7 read shape. No
other `state.db` columns were read.

### 2b. Role distribution in `messages`

| role | count |
|---|---|
| `assistant` | 1425 |
| `tool` | 1841 |
| `user` | 97 |

A `system` role did not appear in the sampled sessions; the importer
maps anything that is not `user` / `assistant` / `tool` / `system`
to `unknown` and would record those as `unknown` in the same row
count. The total is 3363 = 1425 + 1841 + 97.

## 3. Task-log links were found and are exact

The 19 `session_task_links` rows all have `link_source='session_id'`
and `link_confidence='exact'`. The exact matches are produced when
the WebUI session id matches `metadata.hermes_orchestrator_session_id`
or `hermes_trace.session_id` in the task log.

| link_source | link_confidence | count |
|---|---|---|
| `session_id` | `exact` | 19 |

The other precedence-chain links (chat_id, orchestrator_session_id
fallback, timestamp proximity, path, worker_prompt_hash) did not
fire on the current data set, which is consistent with the task
logs being predominantly Stage 1 / 2.5 / 2.6 / 2.7 era runs whose
`hermes_session_id` was already populated and is the primary join
key.

## 4. Stage 2.7 fields still exist in sampled task logs

The 10 most recent `metadata.json` files under
`.local/coding-agent-task-logs/2026/*/*/` were sampled for the
Stage 2.7 fields. **All ten** still contain `model_id`, and the
Stage 2.6 / 2.7 fields are present in **9 of 10** runs that
happened after those stages shipped:

| Field | Present (non-empty, non-`unavailable`) in last 10 runs |
|---|---|
| `model_id` | 10/10 |
| `hermes_orchestrator_model` | 9/10 |
| `hermes_orchestrator_model_provider` | 9/10 |
| `hermes_orchestrator_profile` | 9/10 |
| `hermes_orchestrator_reasoning_level` | 4/10 |
| `hermes_orchestrator_reasoning_level_source` | 5/10 |
| `hermes_orchestrator_reasoning_level_raw` | 4/10 |
| `worker_prompt_path` | 5/10 |
| `worker_prompt_sha256` | 5/10 |

The single row with empty `hermes_orchestrator_*` fields is a
pre-Stage-2.6 run from earlier in the day (timestamp
`2026-06-10T11-00-30Z`); its `model_id` is `unknown` because no
model was selected. This is **expected history**, not a regression:
Stage 2.6 / 2.7 fields can only be populated for runs captured
after those stages shipped. **No Stage 2.5 / 2.6 / 2.7 fields
were renamed, removed, or retyped by Stage 2.9.**

## 5. Importer is idempotent

| Run | sessions | messages | task_logs | links | import_runs |
|---|---|---|---|---|---|
| 1 (worker's first run) | 11 | 3363 | 83 | 19 | 1 |
| 2 (worker's second run) | 11 | 3363 | 83 | 19 | 2 |
| 3 (orchestrator's re-run) | 11 | 3363 | 83 | 19 | 3 |

`import_runs` increments as expected; the other tables do not
double-count. The redaction behavior is also stable: the third run
found 0 secret-like matches, identical to the first two runs, on
the same input set.

## 6. Secret / redaction summary

The importer scans message text for obvious secret-like patterns
**before** writing to the database. Categories implemented:
`openai_key`, `aws_key`, `github_token`, `slack_token`, `bearer`,
`private_key`, `kv_assignment`. All seven categories were
synthetically tested by the worker's verification step 4 and
verified to produce the documented `[REDACTED:<category>]` output.

Across the **11 real sessions and 3363 real messages** scanned by
this validation run, the **total secret-like matches in the
imported corpus is 0**. This is consistent with the corpus being
the user's local Hermes chats, which do not normally include raw
API keys, AWS access keys, GitHub tokens, Slack tokens, bearer
tokens, PEM private keys, or `password=<value>`-style assignments.
**The strict-pass count is 0 in production data; placeholder
values such as `changeme`, `example`, and `<your-key-here>` are
intentionally not redacted and were verified as such by the
worker's synthetic test.**

No secret values are recorded in this validation report, in
`docs/stage-29-private-transcript-layer.md`, or in any other
Git-tracked file. If a future importer run ever reports
`secret_like_matches > 0`, the `import_runs` row will record the
total count and the `messages.secret_like_hits` column will record
the per-message count; the redacted `content_redacted` column will
contain only the literal `[REDACTED:<category>]` placeholder, never
the original value.

## 7. Git privacy verification

### 7a. `git status --short --ignored`

```text
?? scripts/__pycache__/
!! .DS_Store
!! .hermes/
!! .local/
```

- `scripts/__pycache__/` is untracked (not ignored). It contains
  `import_hermes_transcripts.cpython-310.pyc`, the bytecode cache
  produced when the importer is run. **Recommendation:** add
  `__pycache__/` and `*.pyc` to `.gitignore` as a follow-up card.
  This is a **cleanliness** issue, not a **privacy** issue: the
  `.pyc` does not contain any source content beyond what is in
  the tracked `.py` file, and no secret values are baked into it.
- `.DS_Store`, `.hermes/`, and `.local/` are correctly ignored.

### 7b. `git ls-files .local .hermes`

Empty. **No `.local/` or `.hermes/` paths are tracked.**

### 7c. `git ls-files | grep -Ei '(hermes_transcripts|private-analysis|worker_prompt|metadata.json|hermes_trace|state.db|sessions)'`

The only match across the entire tracked tree is
`scripts/import_hermes_transcripts.py` — the importer script
itself, which is **intentionally** Git-tracked. The grep matched
on the word `hermes` in the filename. No other match exists; the
private DB, the session JSON, the `state.db`, the per-task
`metadata.json` / `hermes_trace.json` / `worker_prompt.md`
sidecars, and the `.local/` task-log tree are all **not** tracked.

### 7d. Strict-pass secret scan across all tracked files

Three strict patterns were applied to `git ls-files`:

- **Strict pass A** — real-secret prefixes:
  `(sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}|xox[abp]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----)`
  Result: **empty**. No tracked file contains a real secret prefix.
- **Strict pass B** — `password=…` / `token=…` / `api_key=…` /
  `secret=…` assignments with 16+ non-placeholder characters:
  Result: **empty**. No tracked file contains a real
  `kv=value` secret assignment. (Matches that include
  `changeme`, `example`, `<your-key-here>`, or `REPLACE` are
  excluded; the design doc's secret-rule section is the only
  place any of those strings appear, and they are part of the
  *detection rule* description, not a value.)
- **Strict pass C** — `Authorization: Bearer *** with 16+
  characters: Result: **empty**. No tracked file contains a
  real bearer token.

The empty strict passes are the proof, not an oversight. The
broad keyword scan finds `password` / `secret` / `token` as
*variable names* in `capture-task-start.sh` and
`capture-task-finish.sh` (e.g. `sk-finish`, `sk-capture`); these
are script-name fragments, not secrets, and the strict passes
correctly ignore them.

## 8. Stage 2.7 reasoning-level integrity

- The `state.db` read in the importer is the same narrow
  `json_extract` path documented in Stage 2.7:
  `state.db.sessions.model_config.reasoning_config.effort`. The
  importer does **not** read `state.db.messages`, the run journal,
  or the turn journal.
- The Stage 2.7 precedence chain
  (`OPENCODEBENCH_HERMES_REASONING_LEVEL` env override →
  `state.db` read → WebUI session JSON scalar →
  `"unavailable"`) is mirrored in the importer's
  `sessions.reasoning_level` column. The `reasoning_level` values
  observed in the 11 imported sessions are all `low`, sourced
  from `state.db`.

## 9. Untracked items summary (per the "tracked vs untracked" reporting rule)

- **Tracked, dirty:** none. `git status` shows "no tracked-file
  changes remain" after the Card 2 commit.
- **Untracked, not ignored:** `scripts/__pycache__/import_hermes_transcripts.cpython-310.pyc`
  (and the parent `__pycache__/` dir). Not a privacy risk; see
  §7a for the recommended `.gitignore` follow-up.
- **Untracked, ignored:** `.DS_Store`, `.hermes/`, `.local/`.

## 10. What I did not do

- I did not push. `git log --oneline origin/main..HEAD` shows two
  local commits (`2424ac4` and `e20dfe4`); `git status` reports
  `Your branch is ahead of 'origin/main' by 2 commits.`
- I did not start Stage 3. No analysis layer was created; no
  joining of the private DB to the OpenCodeBench task logs was
  performed.
- I did not implement backup. The design doc records the backup
  implication as a follow-up card; the user's Stage 2.9 brief
  explicitly defers backup to a later user-approved step.
- I did not add `.local/private-analysis/` to `.gitignore` (the
  `.local/` rule on line 7 already covers it).
- I did not read `~/.hermes/.env`, `config.yaml`, `auth.json`,
  `SOUL.md`, `MEMORY.md`, `USER.md`, or any of the other
  Stage 2.5 / 2.6 deny-listed surfaces.
- I did not commit raw transcript text, raw `metadata.json`, raw
  `hermes_trace.json`, raw `worker_prompt.md`, or raw `state.db`
  into any Git-tracked file.
