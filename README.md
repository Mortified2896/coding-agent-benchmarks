# Coding Agent Benchmarks

This repository contains lightweight tooling and documentation for turning real
coding-agent work into benchmark evidence and future replayable cases.

Current project focus:

- Capture OpenCode worker runs with Git before/after state when OpenCode is explicitly being benchmarked or tracked.
- Preserve enough metadata to join local task logs, OpenCode session IDs, Hermes
  orchestration context, and Langfuse traces without committing private data.
- Export Langfuse data into a local archive for analysis.
- Keep task inputs, evaluations, and historical design notes organized for later
  benchmark reconstruction.

> **Development workflow:** this repository does not require or prefer OpenCode for normal implementation work. The active coding harness should work directly unless the user explicitly requests an OpenCode/OpenCodeBench benchmark, tracked capture, comparison, or replay.

## Current workflows

### 1. Capture tracked OpenCode work

Use the wrapper only when an OpenCode run is intentionally part of a benchmark or capture and should produce OpenCodeBench task logs:

```sh
/path/to/coding-agent-benchmarks/opencodebench-opencode \
  run --dir /path/to/target-repo \
  'Implement the requested change.'
```

Raw `opencode ...` invocations are untracked. Prefer `--dir` for delegated or
cross-repository benchmark work so the captured Git repository is explicit.
This wrapper is benchmark tooling, not the default implementation path for work
on this repository.

Detailed wrapper behavior, metadata, repo detection, environment caveats, and
captured file formats are documented in
[`docs/task-capture-wrapper.md`](docs/task-capture-wrapper.md). Historical stage
notes are in `docs/stage-*.md`.

### 2. Import local Hermes transcript evidence

`scripts/import_hermes_transcripts.py` imports local Hermes WebUI conversation
data into a private SQLite analysis database. It is intentionally local-only and
must not be committed.

See
[`docs/stage-29-private-transcript-layer.md`](docs/stage-29-private-transcript-layer.md)
and [`docs/stage-29-validation.md`](docs/stage-29-validation.md).

### 3. Export Langfuse archive data

The current Langfuse exporter is:

```text
scripts/export_langfuse_archive.py
```

Read the operating guide before running it:
[`docs/langfuse-local-export-v1.md`](docs/langfuse-local-export-v1.md).

Typical dry run:

```sh
python3 scripts/export_langfuse_archive.py --date YYYY-MM-DD --dry-run
```

Typical bounded export:

```sh
python3 scripts/export_langfuse_archive.py --date YYYY-MM-DD
```

The exporter must not print secrets, prompts, completions, tool payloads,
observation bodies, or raw records.

## Local data and archive locations

Private/generated data is intentionally outside tracked source files.

- OpenCodeBench task logs, when run from this checkout:
  `.local/coding-agent-task-logs/YYYY/MM/<task_id>/`
- Private Hermes transcript analysis DB:
  `.local/private-analysis/hermes_transcripts.sqlite`
- Langfuse raw archive export:
  `/home/hermes/archives/langfuse/raw/YYYY/MM/DD/`

Do **not** commit archive data, task logs, raw transcripts, raw prompts, raw
assistant responses, raw tool outputs, raw Langfuse records, local SQLite
analysis databases, or generated run artifacts. `.local/` and the exporter
virtualenv are gitignored; keep any additional archive paths outside the repo or
explicitly ignored.

## Documentation map

- OpenCode wrapper and task logs:
  [`docs/task-capture-wrapper.md`](docs/task-capture-wrapper.md)
- Langfuse local exporter:
  [`docs/langfuse-local-export-v1.md`](docs/langfuse-local-export-v1.md)
- Langfuse investigations/status:
  [`docs/langfuse-local-export-investigation.md`](docs/langfuse-local-export-investigation.md),
  [`docs/langfuse-debian-vm-status.md`](docs/langfuse-debian-vm-status.md),
  [`docs/langfuse-activation-overnight-status.md`](docs/langfuse-activation-overnight-status.md)
- Benchmark case reconstruction:
  [`docs/reconstructing-benchmark-cases.md`](docs/reconstructing-benchmark-cases.md)
- Hermes non-interactive capture design:
  [`docs/hermes-noninteractive-capture-design.md`](docs/hermes-noninteractive-capture-design.md)
- Stage history and validations: `docs/stage-*.md`
- Legacy OpenCode benchmark-routing compatibility note:
  [`docs/current-openbench-model-routing.md`](docs/current-openbench-model-routing.md)

## Scripts and entry points

- `opencodebench-opencode` — tracked OpenCode wrapper for explicit benchmark/capture runs.
- `capture-task-start.sh`, `capture-task-finish.sh` — task log capture helpers.
- `opencode-bench.sh`, `hermes-bench.sh` — benchmark harness launchers.
- `scripts/export_langfuse_archive.py` — read-only Langfuse archive exporter.
- `scripts/import_hermes_transcripts.py` — local-only Hermes transcript importer.
- `requirements-langfuse-export.txt` — optional exporter environment
  requirements.

## Platform notes

The current CLI workflows are Linux/Debian-oriented and run directly from the
checkout with Bash plus standard tools such as `git`, `jq`, and `sqlite3`.

The macOS app bundle and installer are retained as historical/optional launcher
material, but they are not the current primary workflow. Re-test macOS behavior
before relying on those paths.
