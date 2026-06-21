# Langfuse Cloud Local Export Investigation

## Current environment findings

- Candidate Langfuse credential/config locations found on Hermes:
  - `/home/hermes/.pi/pi-langfuse.env`
  - `/home/hermes/.config/contained-runs/secrets.env`
  - `/home/hermes/.config/opencode/plugin/load-langfuse-env.mjs`
- Key presence only, no values inspected or recorded:
  - `/home/hermes/.pi/pi-langfuse.env`: `LANGFUSE_PUBLIC_KEY` set, `LANGFUSE_SECRET_KEY` set, `LANGFUSE_HOST` missing, `LANGFUSE_BASEURL` missing.
  - `/home/hermes/.config/contained-runs/secrets.env`: `LANGFUSE_PUBLIC_KEY` set, `LANGFUSE_SECRET_KEY` set, `LANGFUSE_BASEURL` set, `LANGFUSE_HOST` missing.
  - `/home/hermes/.config/opencode/plugin/load-langfuse-env.mjs`: references `LANGFUSE_HOST`, `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY`, and `LANGFUSE_BASEURL`.
- Installed client availability from the current shell/environment:
  - Python: `requests` usable; `langfuse`, `httpx`, and `aiohttp` not installed.
  - Node: `langfuse`, `langfuse-core`, `langfuse-langchain`, `@langfuse/client`, `@langfuse/tracing`, `node-fetch`, and `axios` not resolvable from this repo context.
- A tiny read-only API availability check was performed with `limit=1`, printing only endpoint status, not response data. The following Langfuse public API endpoints returned HTTP 200: `traces`, `observations`, `scores`, and `sessions`.

## Recommended v1 export scope

Start with append-only/raw daily archives for these objects:

1. `traces` - primary run/request object and top-level metadata.
2. `observations` - spans/generations/events linked to traces; needed for latency, model, token, and cost analysis.
3. `scores` - evaluation feedback and benchmark scoring data.
4. `sessions` - available in this Langfuse instance and useful for grouping benchmark runs or user/workflow sessions.

Usage/cost metrics should initially come from fields on traces/observations if present. Defer dedicated metrics endpoints until the raw object export is reliable, because metrics APIs may aggregate data and may not preserve row-level lineage needed for local analysis.

## Recommended local directory layout

Use a date-partitioned raw archive rooted outside the repo:

```text
/home/hermes/archives/langfuse/
  raw/
    YYYY/
      MM/
        DD/
          traces.jsonl.gz
          observations.jsonl.gz
          scores.jsonl.gz
          sessions.jsonl.gz
          manifest.json
          checkpoints.json
  logs/
    YYYY/
      MM/
        DD/
          export.log
```

Keep raw archives immutable after a successful day is sealed. If a day must be re-exported, write to a temporary run directory first and atomically replace or version the partition, for example `DD.retry-YYYYMMDDTHHMMSSZ/`, then promote deliberately.

## File format recommendation

- Use `JSONL.gz` for each object type.
  - One API object per line.
  - Gzip keeps storage reasonable and is stream-friendly.
  - JSONL is easy to inspect, replay, and load into Postgres later.
- Use `manifest.json` per date partition for provenance, counts, hashes, and safety metadata.
- Use `checkpoints.json` for pagination state and idempotent resume metadata during an in-progress export. Once the manifest is finalized, the checkpoint can remain as audit evidence.

## Proposed script design

Implement a small Python script using only the standard library plus installed `requests`:

1. Load Langfuse credentials from an explicit allowlist of env files or from the current process environment.
2. Never print credential values, host values, auth headers, raw response bodies, prompts, completions, or connection strings.
3. Accept CLI arguments:
   - `--date YYYY-MM-DD` for a UTC day partition.
   - `--objects traces,observations,scores,sessions` with the v1 default set.
   - `--out /home/hermes/archives/langfuse`.
   - `--page-limit` with a conservative default such as 100.
   - `--dry-run` to verify credentials/endpoints without writing records.
   - `--redaction-mode minimal|drop-io|metadata-only`.
4. For each object type, request pages from the Langfuse public API using read-only GET endpoints and a bounded time window for the selected day.
5. Stream results to `*.jsonl.gz.tmp`, then rename to `*.jsonl.gz` only after the object export completes.
6. Compute SHA-256 for each final gzip file.
7. Write `manifest.json.tmp`, then atomically rename to `manifest.json` after all selected objects complete.
8. Exit non-zero on partial failure, leaving temporary files/checkpoints for safe resume.

## Proposed manifest fields

```json
{
  "schema_version": 1,
  "source": "langfuse-cloud",
  "export_started_at": "ISO-8601 UTC",
  "export_finished_at": "ISO-8601 UTC",
  "partition_date_utc": "YYYY-MM-DD",
  "langfuse_base_url_present": true,
  "credential_source": "env-file-name-only-or-process-env",
  "objects": {
    "traces": {
      "endpoint": "/api/public/traces",
      "file": "traces.jsonl.gz",
      "record_count": 0,
      "page_count": 0,
      "first_timestamp": null,
      "last_timestamp": null,
      "sha256": "...",
      "redaction_mode": "drop-io"
    }
  },
  "request": {
    "page_limit": 100,
    "time_window_start": "ISO-8601 UTC",
    "time_window_end": "ISO-8601 UTC"
  },
  "safety": {
    "large_blob_fields_dropped": true,
    "raw_transcripts_dropped": false,
    "secrets_printed": false
  }
}
```

## Pagination and rate-limit considerations

- Use the API's native pagination fields rather than offset guessing. Persist the next cursor/page state after each successful page.
- Keep a conservative page size at first, for example 100 records.
- Respect `429` responses with exponential backoff and `Retry-After` when present.
- Record only whether rate-limit headers were present in logs/manifest, not any sensitive request details.
- Add a maximum page count or maximum records option for initial dry runs and backfills.
- Backfill older days one partition at a time to avoid accidental large exports.

## Idempotency strategy for daily exports

- Partition by UTC day and object type.
- Write into temporary files first; only atomically rename completed files.
- Treat a partition with a complete `manifest.json` and matching file hashes as already exported.
- For reruns, default to skip completed partitions unless `--force` is explicitly passed.
- Preserve object IDs and source timestamps in raw JSONL so later Postgres loads can upsert by Langfuse object ID.
- Use checkpoints only for incomplete partitions; do not append blindly to finalized `*.jsonl.gz` files.

## Avoiding unnecessary huge blobs or transcripts

- Default v1 should preserve enough metadata for analysis but avoid expanding storage unnecessarily.
- Add a `drop-io` redaction mode that removes or nulls likely-heavy prompt/completion/input/output fields while retaining IDs, timestamps, model, usage, cost, status, levels, names, tags, session/user references, parent/trace IDs, and metadata keys where safe.
- Keep a `metadata-only` mode for highly sensitive exports.
- Do not log raw records.
- Consider storing raw full transcripts only for selected benchmark projects or date ranges after explicit approval.

## Future Postgres analysis connection

After raw daily archive export is stable, add a separate loader that reads JSONL.gz and upserts into local Postgres staging tables:

- `langfuse_raw_exports`: manifest-level provenance and file hashes.
- `langfuse_traces_raw`, `langfuse_observations_raw`, `langfuse_scores_raw`, `langfuse_sessions_raw`: JSONB raw/staging tables keyed by source object ID and partition date.
- Derived analysis tables/views for benchmark runs, model usage, latency, token/cost rollups, score distributions, and trace-to-observation hierarchies.

Keep export and database loading separate. The exporter should be safe, read-only, and filesystem-only; the loader can be retried independently.

## Hetzner Object Storage recommendation

Do not add Hetzner Object Storage in v1. First prove local exports, manifests, idempotency, and Postgres loading. Once local archives are stable, add an optional `rclone` or S3-compatible sync step that copies sealed daily partitions to Hetzner Object Storage. That sync should verify checksums, avoid deleting remote data by default, and run after manifest completion only.

## Safety/privacy notes

- No Langfuse data should be modified; use GET/read-only APIs only.
- Do not print secrets, API keys, tokens, env values, auth headers, connection strings, or raw response bodies.
- Do not modify env files, systemd units, cron jobs, Langfuse services, or existing observability integrations.
- Do not perform large exports until the v1 script has explicit limits and dry-run behavior.
- Keep archive permissions restrictive because even redacted metadata can reveal project activity.

## SDK vs Requests Evaluation

### Findings

- Langfuse Python SDK `4.7.1` is already installed in `/home/hermes/.hermes/hermes-agent/venv`. It is not installed in the repo's default Python environment, so using it would require either running the exporter inside that existing venv or making the exporter configurable to use it when available.
- A read-only SDK probe was performed with `limit=1` only. It did not print secrets, host values, response bodies, prompts, completions, inputs, outputs, or record values.
- The SDK exposes read methods for all v1 export objects:
  - `lf.api.trace.list(...)` and `lf.api.trace.get(...)` for traces.
  - `lf.api.observations.get_many(...)` for observations.
  - `lf.api.scores.get_many(...)` and `lf.api.scores.get_by_id(...)` for scores.
  - `lf.api.sessions.list(...)` and `lf.api.sessions.get(...)` for sessions.
- The `limit=1` SDK probe succeeded for traces, observations, scores, and sessions.
- Pagination is supported, but with two styles:
  - Traces, scores, and sessions use page-based metadata: `page`, `limit`, `total_items`, `total_pages`.
  - Observations use cursor-based metadata: `cursor`.
- The SDK models expose archival-relevant fields:
  - Traces: `id`, `timestamp`, `createdAt`, `updatedAt`, `session_id`, `user_id`, `metadata`, `tags`, `latency`, `total_cost`, `observations`, and `scores`, plus `input`/`output` fields that should be redacted or omitted by default.
  - Observations: `id`, `trace_id`, `parent_observation_id`, `start_time`, `end_time`, `created_at`, `updated_at`, `session_id`, `user_id`, `metadata`, `tags`, `usage_details`, `cost_details`, `total_cost`, model fields, latency fields, and `input`/`output` fields that should be redacted or omitted by default.
  - Scores: `id`, `timestamp`, `created_at`, `updated_at`, `trace_id`, `observation_id`, `session_id`, `name`, `value`, `string_value`, `data_type`, `source`, `metadata`, and dataset/config linkage fields.
  - Sessions: `id`, `created_at`, `project_id`, and `environment` in list responses; full session detail is available via `get(session_id)` if needed later.

### Pros and cons

SDK approach:

- Pros:
  - Typed method names and response models make object access clearer than hand-building URLs.
  - Pagination metadata is already parsed into model objects.
  - Less boilerplate for authentication, query parameters, datetime handling, and response parsing.
  - More maintainable for normal Langfuse API evolution because generated SDK methods and models track supported endpoints.
- Cons:
  - The SDK is currently available only in an existing Hermes venv, not the repo/default Python environment.
  - SDK object serialization may include fields such as `input` and `output`; the exporter must still explicitly redact or omit heavy/sensitive fields.
  - Pagination is not fully uniform across resources, so the exporter still needs object-specific pagination logic.
  - If the existing venv changes or is removed, an SDK-only exporter could break unless the dependency is later pinned for this repo.

Raw `requests`/Public API approach:

- Pros:
  - `requests` is available in the default Python environment checked earlier.
  - Minimal dependency coupling and easy to run as a standalone archival script.
  - Exact control over URLs, parameters, response storage, retries, headers, and redaction.
  - Best fallback when the SDK is unavailable.
- Cons:
  - More custom boilerplate and more opportunity to drift from Langfuse's supported client behavior.
  - Must manually maintain endpoint paths, pagination differences, error handling, and response assumptions.
  - Less self-documenting than SDK model/method names.

### Recommendation

Prefer the Langfuse SDK when it is available, with a raw `requests` Public API fallback.

### Rationale

The SDK is simpler and more maintainable for the main exporter because it already exposes all required read endpoints, parses pagination metadata, and exposes the IDs, timestamps, usage/cost fields, tags, and session relationships needed for archival. It is likely less brittle against routine Langfuse API updates than hand-written URL handling. However, because the SDK is not available in the repo's default Python environment and package changes are out of scope for this investigation, the implementation should not be SDK-only. The safest v1 design is an adapter interface: use SDK-backed adapters when `langfuse` imports successfully, otherwise fall back to `requests` adapters using the same redaction, manifest, and JSONL.gz writing logic.

## Open questions

- Which timestamp field should define daily partitions for each object type: creation time, update time, event time, or trace timestamp?
- Does the API expose a dedicated usage/cost endpoint that is useful beyond observation-level usage fields?
- Which fields should be dropped in `drop-io` mode for this specific Langfuse schema after inspecting a deliberately sanitized sample?
- Should benchmark/project filters be applied in v1 to reduce archive size?
- What local Postgres database/schema should own the future analysis tables?
- What retention policy is desired for local raw archives and remote object storage copies?

## Exact next implementation prompt

```text
Work in /home/hermes/workspace/repos/coding-agent-benchmarks.
Implement only a safe v1 Langfuse Cloud local exporter script and docs update. Follow docs/langfuse-local-export-investigation.md.
Requirements: read-only Langfuse API usage; no data mutation; no secrets or env values printed; no service/cron/systemd/env-file changes; no package installs unless explicitly approved. Use Python requests if available. Export only bounded UTC date partitions to /home/hermes/archives/langfuse/raw/YYYY/MM/DD/ as JSONL.gz plus manifest.json and checkpoints.json. Include --dry-run, --date, --objects, --out, --page-limit, --max-pages, --redaction-mode, and --force. Write temp files then atomic rename. Respect 429 Retry-After/backoff. Default redaction mode should avoid storing huge input/output transcript fields while preserving IDs, timestamps, linkage, model, usage/cost, scores, tags, and metadata. Add tests or a dry-run validation command that does not print raw Langfuse content. Do not run a large export; at most run dry-run or max-pages=1 validation.
```

## V1 SDK Exporter Implementation Notes

A v1 SDK-based exporter has been added at `scripts/langfuse_export/export_langfuse_day.py` with dependencies pinned in `requirements-langfuse-export.txt`.

### Setup instructions

Create and use a repo-local virtual environment only:

```bash
cd /home/hermes/workspace/repos/coding-agent-benchmarks
python3 -m venv .venv-langfuse-export
. .venv-langfuse-export/bin/activate
python -m pip install -r requirements-langfuse-export.txt
```

Do not use the Hermes agent venv, system Python packages, or unpinned user-site packages for this exporter.

### Example commands

Dry-run endpoint probe for one UTC day. This does not write archive records and prints only set/missing config status plus counts from the first page:

```bash
. .venv-langfuse-export/bin/activate
python scripts/langfuse_export/export_langfuse_day.py --date YYYY-MM-DD --dry-run
```

Real export for one UTC day:

```bash
. .venv-langfuse-export/bin/activate
python scripts/langfuse_export/export_langfuse_day.py --date YYYY-MM-DD
```

### Archive structure

The exporter writes one partition per UTC day:

```text
/home/hermes/archives/langfuse/raw/YYYY/MM/DD/
  traces.jsonl.gz
  observations.jsonl.gz
  scores.jsonl.gz
  sessions.jsonl.gz
  manifest.json
```

`manifest.json` records exporter version, SDK version, export timestamps, date range, per-object status, counts, page counts, filenames, and SHA-256 hashes.

### Current implementation behavior

- Uses the Langfuse Python SDK only; no raw HTTP requests are used.
- Uses read-only SDK methods:
  - `api.trace.list`
  - `api.observations.get_many`
  - `api.scores.get_many`
  - `api.sessions.list`
- Supports current SDK pagination styles:
  - page-based pagination for traces, scores, and sessions
  - cursor-based pagination for observations
- Streams records directly to gzip JSONL instead of accumulating all records in memory.
- Writes temporary gzip files and atomically renames them after each object completes.
- Prints only configuration set/missing status, SDK version, object counts, and archive status. It does not print secrets, env values, connection strings, or raw Langfuse records.

### Known limitations

- The v1 exporter stores SDK response records as returned by Langfuse, including `input`/`output` fields when the API returns them. Add a redaction mode before exporting broad historical ranges if transcript minimization is required.
- `--dry-run` intentionally probes only the first page for each object; its counts are first-page counts, not full-day totals.
- There is no `--force` guard yet; rerunning a real export for the same day overwrites that partition's files.
- Retry handling is conservative and based on SDK exception class names because the generated SDK abstracts HTTP details.
- The exporter currently loads credentials from the process environment plus the known Hermes Langfuse env files, but reports only set/missing.
