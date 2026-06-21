# Observability warehouse investigation

Date: 2026-06-21

## Recommendation summary

Build a **local Postgres analysis layer** that leaves the existing systems immutable:

- keep Langfuse JSONL.gz archives as the append-only source of truth;
- keep Pi `/save-analysis` rows in `control_room_pi.pi_conversation_analyses` unchanged;
- keep benchmark task logs and Git sidecars unchanged;
- add a separate warehouse schema later, populated by idempotent import jobs that load only metadata and derived metrics first.

This setup is recommended for future coding-agent analysis. It is the right balance between safety and usefulness: raw prompts, completions, tool payloads, and transcript bodies can stay out of v1 while the warehouse still supports joins across cost, latency, model, task, outcome, repository, and Git state.

## Current data sources

### Langfuse archive

Archive root: `/home/hermes/archives/langfuse/raw`.

Current shape by file name only:

```text
YYYY/MM/DD/manifest.json
YYYY/MM/DD/traces.jsonl.gz
YYYY/MM/DD/observations.jsonl.gz
YYYY/MM/DD/scores.jsonl.gz
YYYY/MM/DD/sessions.jsonl.gz
```

Manifests are available for daily partitions from 2026-05-24 through 2026-06-20. The 2026-06-20 manifest reports successful exports for traces, observations, scores, and sessions, includes source file names, record counts, page counts, gzip byte sizes, SHA-256 hashes, export windows, exporter version, and a safety block indicating that env values, secrets, and record contents were not printed.

Safe schema sampling found these useful fields without printing raw records:

- `traces`: `id`, `timestamp`, `createdAt`, `updatedAt`, `name`, `projectId`, `environment`, `htmlPath`, `latency`, `totalCost`, `sessionId`, `userId`, `externalId`, `tags`, `scores`, `observations`, `metadata`.
- `traces.metadata`: `model`, `provider`, `sessionId`, `git_branch`, `git_commit`, `git_remote_host`, `git_remote_path`, `repo_identity`, `repo_owner`, `repo_name`, `repo_root_name`, `turn_count`, `tool_call_count`, `totalTools`, `total_tool_errors`, `tool_success_rate`, `session_had_errors`, `completed`, `source_type`, `metadata_source`, plus OpenTelemetry-style `resourceAttributes` and `scope` objects.
- `observations`: `id`, `traceId`, `parentObservationId`, `type`, `name`, `startTime`, `endTime`, `completionStartTime`, `latency`, `timeToFirstToken`, `level`, `statusMessage`, `model`, `modelId`, `promptTokens`, `completionTokens`, `totalTokens`, `usage`, `usageDetails`, `costDetails`, `calculatedInputCost`, `calculatedOutputCost`, `calculatedTotalCost`, `inputPrice`, `outputPrice`, `metadata`, `projectId`, `environment`, timestamps.
- `observations.metadata`: `provider`, `requestId`, `finishReason`, `resourceAttributes`, `scope`.
- `scores`: `id`, `traceId`, `observationId`, `name`, `value`, `stringValue`, `dataType`, `source`, `timestamp`, timestamps, `metadata`, `trace.environment`, `trace.tags`, `executionTraceId`.
- `sessions`: `id`, `createdAt`, `projectId`, `environment`.

Fields named `input` and `output` exist on traces and observations. They are useful for selected forensic review, but should not be loaded into v1 warehouse tables.

### Pi `/save-analysis` data

The Pi logging helper is in `/home/hermes/workspace/repos/pi-customizations/scripts/log_pi_conversation_analysis.py`. It inserts into `control_room_pi.pi_conversation_analyses` and is deliberately limited to approved structured fields.

Credential/database checks, reported without values:

- Pi observability env file: available.
- `PI_OBSERVABILITY_DATABASE_URL`: set.
- Postgres connection for the Pi observability database: available.

Current table schema:

| Column | Type | Nullability | Notes |
|---|---|---|---|
| `id` | `uuid` | not null | primary key |
| `created_at` | `timestamp with time zone` | not null | insertion timestamp |
| `summary` | `text` | not null | structured analysis text; do not print in reports |
| `what_went_wrong` | `text` | not null | structured analysis text; do not print in reports |
| `what_went_right` | `text` | not null | structured analysis text; do not print in reports |
| `root_cause` | `text` | not null | structured analysis text; do not print in reports |
| `lesson_for_next_time` | `text` | not null | structured analysis text; do not print in reports |
| `source` | `text` | not null | default source is `pi-save-analysis` |
| `raw_analysis_json` | `jsonb` | not null | approved fields duplicated as JSON |

Indexes:

- `pi_conversation_analyses_pkey`
- `pi_conversation_analyses_created_at_idx`
- `pi_conversation_analyses_source_idx`

Current safe aggregate check: the table exists but has zero rows, so no existing Pi analysis rows currently provide Langfuse trace IDs, session IDs, task IDs, repo paths, commit SHAs, model fields, or joinable timestamps beyond future `created_at` values.

### Benchmark/repo metadata

Benchmark metadata lives in task-log artifacts and is documented in `docs/stage-2-tracking.md`, `docs/opencodebench-task-log-analysis-prep.md`, and related stage docs. Generated logs are local/private and should not be committed.

Useful fields already designed or captured include:

- `task_id` / run directory name.
- `opencodebench.session_id`.
- `opencodebench.project_id`.
- `opencodebench.repo_root`, `repo_path`, `git_root`.
- `opencodebench.git_commit_before`, `git-head-before.txt`, `git-branch-before.txt`.
- `model_id`, `harness`, `harness_mode`, `agent_command_label`.
- `upstream_orchestrator`.
- `task_type`, `task_type_status`, `task_type_raw`.
- `opencodebench.timing.start_unix_seconds`, `finish_unix_seconds`, `duration_seconds`, plus ISO start/finish times.
- `exit_code`, `agent_exit_code`, `opencode_exit_code`.
- `opencodebench.diff_summary.files_changed`, `lines_added`, `lines_deleted`, `working_tree_dirty_after`, `diff_produced`, `is_git_repo`.
- `worker_prompt_sha256` and prompt length/fingerprint fields.
- orchestrator fields when Hermes is upstream: session ID, model, provider, profile, workspace, worktree path, reasoning level, source label, capture source.
- Stage 3 placeholders: `opencode_session_id`, `opencode_session_id_status`, `langfuse_trace_id`, `langfuse_trace_id_status`.

A human `evaluation.md` sidecar can add task outcome, rating, decision, comments, follow-up status, evaluator, and evaluation timestamp. The warehouse should ingest structured evaluation values before free-text comments.

### Git and GitHub state

Local Git state can be captured reliably without network calls:

- repository root, worktree path, branch, detached/head state;
- `HEAD` SHA before and after;
- dirty status before and after;
- diff stat and numstat;
- patch hash and optional file-level changed-path summaries;
- remote host/path normalized into a privacy-preserving repo identity;
- commit author/committer timestamps for local commits when needed;
- parent SHAs and merge-base against a configured base branch.

GitHub can be connected later by adding optional metadata fields rather than calling GitHub during v1 imports:

- `github_owner`, `github_repo` from normalized remote path;
- `github_issue_number` and `github_pr_number` from task metadata, branch names, commit messages, or explicit user-supplied fields;
- commit SHA links when local commits are pushed;
- later read-only GitHub API enrichment for PR state, labels, checks, review status, and issue closure, gated behind a token check and strict no-secret logging.

No GitHub API call is needed for v1.

## Existing join keys

Strong existing keys:

- Langfuse `trace.id` to Langfuse `observations.traceId` and `scores.traceId`.
- Langfuse `sessions.id` to trace/session metadata when populated.
- Langfuse trace metadata `sessionId` and `git_commit` for matching to benchmark/OpenCode sessions and Git state.
- Benchmark `task_id` as the canonical run key.
- Benchmark `opencodebench.session_id` as a run/session key.
- Benchmark `opencode_session_id` when resolved.
- Benchmark `git_commit_before` and local `git-head-before.txt`.
- Benchmark timestamps and Langfuse trace/observation timestamps for bounded time-window checks.
- Model/provider fields from benchmark metadata and Langfuse trace/observation metadata.

Weak or heuristic joins:

- timestamp windows between benchmark start/end and Langfuse trace timestamps;
- repo identity plus git commit plus model/provider;
- trace metadata `git_commit` to benchmark `git_commit_before` when a run starts from clean `HEAD`;
- Langfuse trace metadata `repo_name`/`repo_owner` to benchmark project/repo path;
- Pi analysis `created_at` near a run end time, once rows exist;
- prompt hash, task type, model, and timestamp proximity, without loading prompt text.

## Missing join keys

Missing or not yet consistently populated:

- Pi analysis rows do not yet store `task_id`, `run_id`, `pi_conversation_id`, `langfuse_trace_id`, `langfuse_session_id`, repo path, commit SHA, model/provider, or task outcome fields.
- Benchmark metadata currently has `langfuse_trace_id` placeholders but Langfuse trace resolution is deferred.
- `git_commit_after` is not a single canonical metadata field, although it can be computed/captured from post-run Git state.
- GitHub issue and PR numbers are not first-class fields.
- A stable cross-system `run_id` is not yet enforced at run start across Pi, OpenCode/Hermes, Langfuse, and benchmark capture.
- Reasoning level and OpenCode version can be underpopulated depending on wrapper path.

## Recommended future correlation ID strategy

Introduce a shared run envelope at task start and propagate it everywhere possible:

| Field | Purpose |
|---|---|
| `run_id` | globally unique warehouse run ID; generated once at benchmark start |
| `task_id` | human/task-log identifier; stable run directory key |
| `pi_conversation_id` | Pi conversation/session identifier when the user interaction starts in Pi |
| `pi_analysis_id` | `/save-analysis` row UUID when an analysis is saved |
| `langfuse_trace_id` | resolved trace ID or explicit trace ID if available |
| `langfuse_session_id` | Langfuse session ID or metadata session ID |
| `opencode_session_id` | OpenCode internal session ID |
| `hermes_session_id` | Hermes/Pi session when available |
| `repo_identity` | normalized `host/owner/repo` without credentials |
| `repo_root` | local path, private/local only |
| `git_commit_before` | starting commit |
| `git_commit_after` | ending commit if a commit exists after the run |
| `github_issue_number` | optional issue linkage |
| `github_pr_number` | optional PR linkage |

The key principle: every producer should accept and emit the same `run_id`, while specialized IDs remain nullable foreign keys.

## Recommended local Postgres schema design

Create a new schema later, for example `coding_agent_obs`, and do not alter Langfuse or Pi source schemas.

### Provenance/import tables

- `import_runs`: one row per import execution; columns for importer name/version, source type, started/finished timestamps, status, error category, record counts.
- `source_files`: one row per archive file or local metadata file; source path, partition date, object type, size, SHA-256, manifest timestamp, first/last imported at.
- `source_file_imports`: many-to-many relation from import run to source file with imported/skipped/error counts.

### Langfuse metadata tables

- `langfuse_traces_meta`: trace ID, project/environment, timestamps, latency, total cost, name/type tags, session IDs, user/external IDs if safe, repo/model/provider metadata, turn/tool counts, error counts, source file ID, content hash.
- `langfuse_observations_meta`: observation ID, trace ID, parent observation ID, type/name/level, timestamps, latency/TTFT, model/model ID, provider, finish reason, token counts, safe cost fields, request ID hash if needed, source file ID.
- `langfuse_scores_meta`: score ID, trace ID, observation ID, name, numeric/string score value where safe, data type, source, timestamp, source file ID.
- `langfuse_sessions_meta`: session ID, project/environment, created timestamp, source file ID.

Do not load raw `input`/`output` fields into these tables.

### Benchmark and Git tables

- `benchmark_runs`: `run_id`, `task_id`, project, harness, model/provider, task type, start/end/duration, exit codes, orchestrator, reasoning level, opencode/hermes session IDs, prompt hash/length, local task-log path.
- `benchmark_evaluations`: `task_id`/`run_id`, rating, decision, follow-up flag, evaluated timestamp, evaluator hash/label; defer free-text comments or store redacted summaries only.
- `git_run_state`: `run_id`, repo identity, repo root, branch, commit before, commit after, dirty before/after, files changed, lines added/deleted, diff produced, patch hash.
- `git_changed_files`: `run_id`, path hash or path, additions, deletions, status; choose path hashing if repository paths are sensitive.
- `github_refs`: nullable issue/PR/commit linkage with source and confidence.

### Pi analysis mirror/link tables

- `pi_analysis_meta`: mirror only `id`, `created_at`, `source`, optional field-presence/length metrics, and future explicit correlation fields; avoid copying structured text bodies in v1.
- `run_links`: general bridge table with `run_id`, link type, external system, external ID, confidence, source, created/imported timestamp.

### Recommended views

- `v_run_overview`: one row per run with task, model, outcome, Git diff summary, cost/latency rollups, and best Langfuse trace match.
- `v_model_performance`: grouped success/evaluation/cost/latency by provider/model/reasoning level/task type.
- `v_trace_costs`: trace-level token and cost rollups from observations.
- `v_failure_candidates`: failed runs, errored traces, high-cost traces, high tool-error rates, and low evaluation decisions.
- `v_join_gaps`: runs without trace IDs, Pi analyses without run IDs, traces without benchmark links.

## Duplicate import prevention

Use deterministic natural keys and source provenance:

- unique `(source_file_id, object_type, object_id)` for raw metadata imports;
- unique Langfuse IDs for trace/observation/score/session metadata tables;
- unique benchmark `task_id` and optional `run_id`;
- unique Pi analysis `id` in the mirror;
- compare manifest SHA-256 and gzip size before importing a source file;
- store importer version and JSON schema version;
- make imports upserts that update metadata only when source hash or importer version changes;
- keep rejected rows in an import error table without raw content.

## Recommended v1 implementation scope

V1 should be small and metadata-only:

1. Create the warehouse schema and provenance tables.
2. Import Langfuse manifests and only safe metadata fields from traces, observations, scores, and sessions.
3. Import benchmark `metadata.json` structural fields and evaluation template structured fields when available.
4. Mirror Pi analysis row IDs/timestamps/source only, plus future correlation fields once added; do not copy analysis text bodies.
5. Add `run_links` and initial views for run overview, model performance, trace costs, failures, and join gaps.
6. Provide a dry-run mode that prints counts, field availability, and set/missing checks only.

## What not to load yet

Do not load in v1:

- Langfuse trace or observation `input`/`output`;
- prompts, completions, tool payloads, observation bodies, or raw JSON records;
- full Pi analysis text bodies;
- raw transcripts or private SQLite transcript contents;
- full patch contents;
- GitHub issue/PR bodies or comments;
- secrets, env values, API keys, passwords, tokens, connection strings;
- archive data into the Git repository.

## Risks and privacy notes

- Metadata can still reveal sensitive project activity through repo names, model names, costs, timestamps, branch names, and file paths.
- Use local-only Postgres permissions and avoid world-readable dumps.
- Treat repo root paths as private; prefer normalized repo identities in shared reports.
- Store hashes for prompts, patches, user IDs, request IDs, and optionally file paths.
- Keep raw archives immutable and outside Git.
- Separate source schemas from warehouse schemas so failed imports cannot corrupt Langfuse or Pi data.
- Make every report query content-safe by default.

## Analysis use cases

The warehouse should answer:

- Which models produce better task outcomes by task type and repository?
- Which models cost the most per successful task?
- Which tasks or workflows have the highest latency, token usage, or tool-error rate?
- Which Pi analyses correlate with high-cost, failed, or low-quality traces?
- Which Langfuse traces correspond to which Git commits and benchmark runs?
- Which workflows improve over time after prompt, model, or tool changes?
- Which agent/tool combinations are most reliable?
- Which repositories or task types produce repeated failure modes?
- Which runs changed code but failed evaluation, or succeeded without a diff?
- Which runs lack trace IDs or other correlation keys and need instrumentation fixes?

## Exact next implementation prompt

```text
Work in /home/hermes/workspace/repos/coding-agent-benchmarks.
Implement v1 of the local Postgres observability warehouse described in docs/observability-warehouse-investigation.md.
Do not modify Langfuse data or Pi source tables. Do not print secrets, env values, API keys, passwords, tokens, connection strings, raw Langfuse records, prompts, completions, tool payloads, observation bodies, raw JSON content, or Pi analysis text bodies. Do not configure Hetzner, systemd, cron, or timers.

Create a separate Postgres schema, preferably coding_agent_obs, with provenance tables, Langfuse metadata tables, benchmark run/Git metadata tables, Pi analysis metadata mirror, run_links, and the recommended v1 views. Add idempotent importer code with --dry-run and --limit options. Read Langfuse archive files from /home/hermes/archives/langfuse/raw but load only safe metadata fields; never load trace/observation input or output. Import benchmark metadata from local task-log metadata.json files, excluding prompt/text bodies. Mirror only Pi analysis id/created_at/source and correlation fields if present. Track source files, hashes, import runs, counts, and errors. Add validation commands that report only counts and set/missing availability. Do not run migrations until explicitly approved; first produce SQL files and a dry-run plan.
```

## Investigation validation

- No Langfuse data was modified.
- No Pi data was modified.
- No Postgres tables were created and no migrations were run.
- Hetzner, systemd, cron, and timers were not configured or changed.
- Archive inspection was limited to manifests, file names, and schema keys/types; raw records and content bodies were not printed.
- Credential/database checks reported only available/unavailable or set/missing.
