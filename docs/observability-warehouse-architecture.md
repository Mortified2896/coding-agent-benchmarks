# Observability warehouse architecture

Date: 2026-06-21

## Purpose

The local observability warehouse is a long-term analysis layer for improving coding agents. It connects Langfuse archive metadata, Pi analysis data, benchmark run metadata, and Git/GitHub state without changing the source systems.

The warehouse should answer questions such as:

- which models, prompts, workflows, and harnesses perform best for specific task types;
- which failures correlate with cost, latency, tool use, repository state, or workflow choices;
- whether agent changes improve completion quality over time;
- which runs need human review, replay, follow-up issues, or regression tests.

The goal is not to replace Langfuse, Pi, benchmark logs, or Git. The goal is to create a safe local Postgres metadata layer that makes cross-system joins repeatable and auditable while preserving immutable raw archives as the source of truth.

## Data layers

### 1. Raw immutable archive

The raw archive layer contains source artifacts exactly as produced by existing systems. It should be append-only and should not be mutated by warehouse jobs.

Primary raw sources:

- Langfuse JSONL.gz archive files for traces, observations, scores, and sessions.
- Benchmark task logs and sidecar files.
- Local Git state, including before/after commits, branch state, dirty status, and diffs.

This layer is the forensic source of truth. Warehouse tables may store file paths, hashes, partition dates, safe identifiers, counts, and derived metadata, but raw prompts, completions, tool payloads, observation bodies, and full JSON records should not be loaded into Postgres by default.

### 2. Structured warehouse

The structured warehouse is a local Postgres schema containing metadata tables populated by idempotent loaders. It should store normalized, joinable, privacy-conscious fields such as:

- Langfuse trace, observation, score, and session metadata.
- Benchmark run metadata.
- Git repository and diff metadata.
- Import provenance and source file hashes.
- Cross-system link rows.

The warehouse should be optimized for durable joins and reports, not for replacing raw archives or storing every payload.

### 3. Evaluation layer

The evaluation layer is the structured Pi `/save-analysis` data. Pi analysis rows should capture approved human/agent evaluation fields plus correlation fields that allow each analysis to be joined to a benchmark run, Langfuse trace/session, repository, commit range, and future GitHub issue or PR.

Pi currently lacks enough join keys for reliable warehouse correlation. The first implementation step should patch Pi `/save-analysis` so new rows store correlation fields going forward.

### 4. Connection layer

The connection layer links records across systems. The central table should be `run_links`, backed by shared correlation IDs propagated at run start and saved by each producer where possible.

`run_links` should allow nullable, incremental linkage. A benchmark run may initially have only a `run_id`, `task_id`, repository path, and starting commit. Later imports can attach Langfuse trace IDs, Pi analysis IDs, GitHub PR numbers, and evaluation outcomes without rewriting raw data.

## Data sources

The warehouse should eventually connect these sources:

- Langfuse traces, observations, scores, and sessions from the raw archive export.
- Pi analysis rows produced by `/save-analysis`.
- Benchmark run metadata from task logs and sidecars.
- Local Git state, including repository identity, branch, commit before/after, dirty state, diff stats, and changed paths.
- Future GitHub metadata for issues, pull requests, commits, checks, labels, reviews, and closure state.

GitHub enrichment should be optional and read-only. It should not be required for warehouse v1.

## Correlation ID strategy

Future producers should share a run envelope and propagate stable identifiers. Recommended fields:

| Field | Purpose |
|---|---|
| `run_id` | Global warehouse run identifier generated once per benchmark or agent run. |
| `task_id` | Stable task or benchmark identifier. |
| `pi_conversation_id` | Pi conversation/session identifier. |
| `langfuse_trace_id` | Langfuse trace identifier. |
| `langfuse_session_id` | Langfuse session identifier. |
| `git_commit_before` | Repository commit before the run starts. |
| `git_commit_after` | Repository commit after the run, when applicable. |
| `repo_path` | Local repository path for private/local joins. |
| `github_issue_number` | Optional future issue linkage. |
| `github_pr_number` | Optional future pull request linkage. |

Pi currently does not store enough of these fields in `/save-analysis` rows. That should be fixed before building reports, because reports without durable join keys would depend on weak timestamp and metadata heuristics.

For the current staged path from prompt-driven run capture to future automation, see the [Staged adoption plan](observability-run-capture-v1.md#staged-adoption-plan) in the run capture v1 documentation.

## Proposed implementation phases

### Phase 1: Patch Pi `/save-analysis` correlation fields

Patch `pi-customizations` so `/save-analysis` stores correlation fields going forward. At minimum, new analysis rows should be able to store the recommended IDs above when available. This creates durable links for all future human/agent analysis.

### Phase 2: Warehouse v1 loader

Implement a local warehouse v1 metadata loader for Langfuse archive metadata and benchmark metadata. The loader should:

- read archive manifests and safe metadata fields;
- load only metadata and derived metrics by default;
- record import provenance and source file hashes;
- populate benchmark, Git, Langfuse metadata, and `run_links` tables;
- be idempotent and safe to rerun.

### Phase 3: Views and reports

Add views and reports for model, task, and workflow analysis. Initial reports should focus on joins that are reliable, such as run outcomes by model/provider, cost and latency by task type, tool/error rates, and evaluation outcomes by workflow.

### Phase 4: Optional Hetzner backup sync

After local warehouse behavior is stable, optionally sync encrypted backups or archive copies to Hetzner. This should be a backup layer only, not a prerequisite for local analysis.

### Phase 5: Optional GitHub API enrichment

Add optional read-only GitHub API enrichment for issue, PR, commit, check, label, and review metadata. This should be gated behind explicit configuration and strict no-secret logging.

## What not to do yet

- Do not load all raw prompts or completions into Postgres by default.
- Do not load raw tool payloads, observation bodies, or full Langfuse JSON records into v1 tables.
- Do not mutate raw archives.
- Do not make the warehouse the source of truth.
- Do not depend on heuristic joins before basic correlation IDs exist.
- Do not overbuild dashboards before basic joins work.
- Do not configure Hetzner as part of v1.
- Do not require GitHub API access for v1.

## First implementation task

Patch `pi-customizations` so `/save-analysis` stores correlation fields going forward.

This should happen before warehouse loaders and reports, because it creates the durable join keys needed for future Pi analysis rows to connect to benchmark runs, Langfuse traces/sessions, repository state, and later GitHub issues or pull requests.
