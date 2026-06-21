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

## Staged adoption plan

Run capture should move from prompt-controlled use to automation in stages. The immediate goal is to prove that metadata-only capture is useful on real tasks before investing in launchers or Control Room integration.

### Phase A: Prompt-driven run capture

Future serious task prompts should explicitly instruct Pi to:

- create or accept a stable `run_id`;
- call `scripts/capture_run_metadata.py start` before making changes;
- complete the task and validation;
- call `scripts/capture_run_metadata.py finish` after validation;
- link known Langfuse trace/session IDs, Pi session IDs, or Pi analysis IDs when available;
- include the `run_id` in the final report.

This keeps task boundaries under human/agent control while using the script as the durable metadata capture mechanism.

### Phase B: Reusable instrumented task prompt

Create a reusable prompt snippet for future Pi tasks so run capture instructions are not rewritten each time. The snippet should tell Pi to:

- generate or use a stable `run_id`;
- start run capture before changes;
- finish run capture after validation;
- link known trace, session, and analysis IDs;
- include the `run_id` in the final report.

The snippet can be pasted into serious task prompts until the workflow has enough real examples to justify more automation.

### Phase C: Semi-automated wrapper

Later, add a helper such as `scripts/run_instrumented_task.sh` or a Pi command such as `/instrumented-task`. The wrapper should reduce repeated prompt boilerplate and make it harder to forget start/finish capture, while still preserving human/agent judgment about where a task begins, where validation ends, and which external IDs are safe and relevant to link.

### Phase D: Full automation

Full automation is the long-term endgame, not the immediate next task. Later, Control Room, Hermes, or the Pi launcher can:

- create `run_id` automatically;
- inject `run_id` into prompt/context;
- capture Git before/after state;
- link Langfuse trace/session IDs when known;
- ask `/save-analysis` to store the same `run_id`.

This should wait until several real tasks have been captured and reviewed with the Phase A/B workflow.

### Current recommendation

Use Phase A and Phase B now: prompt-controlled workflow plus script-backed capture. Do not build full automation until a few real tasks have been captured, reviewed, and shown to produce useful warehouse joins.

## Next steps

- Add run envelope propagation in benchmark/Pi execution paths.
- Add automatic Langfuse trace/session link capture when safe IDs are available.
- Add read-only GitHub issue/PR enrichment in a later phase.
- Add reporting views once run links are populated consistently.
