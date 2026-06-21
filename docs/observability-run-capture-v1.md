# Observability run capture v1

Date: 2026-06-21

## Purpose

Run capture v1 adds a small metadata-only run spine to the local `observability` warehouse. It links task identity, agent/model metadata, Git before/after state, Langfuse trace/session IDs, Pi analysis IDs, and future GitHub IDs without modifying source systems.

## Schema overview

Migration path:

```text
db/migrations/002_observability_run_capture_v1.sql
```

Tables:

- `observability.runs` — one row per run, keyed by `run_id`, with task, project, agent, worker/model, status, timestamps, result summary, and metadata JSON.
- `observability.run_git_state` — one row per run with branch/commit before and after, dirty booleans, diff stat counts, commit count created, and final clean boolean.
- `observability.run_links` — existing v1 link table extended backward-compatibly with `source_type`, `source_id`, `link_confidence`, `notes`, and `updated_at`.

Indexes cover run lookup by task/project/agent/status/start time, links by source type and ID, and Git commits before/after.

## CLI

Script path:

```text
scripts/capture_run_metadata.py
```

The script reads only:

```text
/etc/hermes/pi_observability_postgres.env
PI_OBSERVABILITY_DATABASE_URL
```

It prints only sanitized database target metadata: database name, host type, user set/missing, and password set/missing.

Examples:

```bash
python3 scripts/capture_run_metadata.py start \
  --run-id test-run-001 \
  --task-id test-task \
  --task-name "Safe test run" \
  --task-type validation \
  --project coding-agent-benchmarks \
  --agent Pi \
  --repo-path /home/hermes/workspace/repos/coding-agent-benchmarks

python3 scripts/capture_run_metadata.py finish \
  --run-id test-run-001 \
  --status success \
  --result-summary "Safe validation completed."

python3 scripts/capture_run_metadata.py link \
  --run-id test-run-001 \
  --source-type langfuse_session \
  --source-id fake-session-id \
  --link-confidence manual

python3 scripts/capture_run_metadata.py show --run-id test-run-001
```

Supported commands: `migrate`, `start`, `finish`, `link`, and `show`.

## Git metadata captured

Git commands are run as `git -C <repo_path> ...`. V1 stores only:

- branch before/after;
- commit SHA before/after;
- dirty boolean before/after;
- file count, insertion count, deletion count from short diff stats;
- number of commits created between before and after;
- final clean/dirty boolean.

It does not store patches, full diffs, file contents, or untracked file contents.

## Privacy boundaries

Run capture v1 does not store raw prompts, completions, transcripts, tool payloads, observation bodies, full diffs, raw Langfuse records, archive data, secrets, tokens, API keys, passwords, or database URLs.

The helper output avoids raw DB rows and raw DB URLs. `show` reports only counts and a small sanitized status/project/agent summary.

## Validation performed

- Applied migration to explicit database target `pi_observability` using an admin role because schema changes required it.
- Verified the three run-capture tables are present.
- Verified eight expected indexes are present.
- Ran a safe test capture with `start`, `finish`, `link`, and `show`.
- Confirmed the test run row, Git state row, and link row existed.
- Confirmed zero forbidden raw-content columns in the run-capture tables for common raw-content names.
- Deleted the safe test run and related rows.
- Confirmed test-created row count returned to zero.

## Known limitations

- V1 is manual/CLI-driven and does not yet auto-wrap benchmark harness execution.
- Link confidence is simple text metadata.
- The `metadata` JSON column is available for safe metadata only; callers must not put raw content in it.
- GitHub enrichment is not implemented.

## Next steps

- Add run envelope propagation in benchmark/Pi execution paths.
- Add automatic Langfuse trace/session link capture when safe IDs are available.
- Add read-only GitHub issue/PR enrichment in a later phase.
- Add reporting views once run links are populated consistently.
