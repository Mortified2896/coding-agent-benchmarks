# Observability warehouse v1 loader

Date: 2026-06-21

## Scope

The v1 loader imports Langfuse archive **metadata only** from `/home/hermes/archives/langfuse/raw` into a separate local Postgres schema named `observability`.

It does not modify Langfuse, Pi data, archive files, systemd jobs, timers, or Hetzner configuration.

## Privacy boundary

The loader does not store full raw JSON records and intentionally excludes raw content fields such as:

- trace/observation `input` and `output`;
- prompts, completions, messages, request/response bodies;
- tool payloads and observation bodies;
- secrets, tokens, API keys, passwords, or database URLs.

User IDs, external IDs, and request IDs are stored only as SHA-256 hashes when present. Loader output prints counts and set/missing or available/unavailable checks only.

## Schema

Migration path:

```text
db/migrations/001_observability_warehouse_v1.sql
```

Created schema and tables:

- `observability.import_runs` — one row per loader execution.
- `observability.source_archive_files` — source file provenance, partition date, manifest count, SHA-256, and exporter metadata.
- `observability.source_file_imports` — import-run to source-file counts.
- `observability.langfuse_traces_meta` — safe trace metadata.
- `observability.langfuse_observations_meta` — safe observation metadata.
- `observability.langfuse_scores_meta` — safe score metadata.
- `observability.langfuse_sessions_meta` — safe session metadata.
- `observability.run_links` — optional future manual/automatic cross-system joins.

The migration is idempotent where practical via `CREATE SCHEMA/TABLE/INDEX IF NOT EXISTS` and natural-key uniqueness constraints.

## Loader

Script path:

```text
scripts/load_langfuse_archive_to_postgres.py
```

Supported options:

```bash
python3 scripts/load_langfuse_archive_to_postgres.py --date YYYY-MM-DD --dry-run
python3 scripts/load_langfuse_archive_to_postgres.py --date YYYY-MM-DD --migrate
python3 scripts/load_langfuse_archive_to_postgres.py --start-date YYYY-MM-DD --end-date YYYY-MM-DD
python3 scripts/load_langfuse_archive_to_postgres.py --start-date 2026-05-24 --end-date 2026-06-20
```

`--force` is recorded in import provenance but does not rewrite archives. The loader validates each successful manifest entry by SHA-256 and gzip line count before loading rows.

Database URL lookup is intentionally narrow and sanitized. The script checks these environment names, including values loaded from existing local env files when present, but never prints their values:

- `OBSERVABILITY_DATABASE_URL`
- `WAREHOUSE_DATABASE_URL`
- `PI_OBSERVABILITY_DATABASE_URL`
- `DATABASE_URL`

## Validation commands

Dry-run a small partition:

```bash
python3 scripts/load_langfuse_archive_to_postgres.py --date 2026-06-20 --dry-run
```

Apply migration and load a small partition when the intended database URL is set:

```bash
OBSERVABILITY_DATABASE_URL=... python3 scripts/load_langfuse_archive_to_postgres.py --date 2026-06-20 --migrate
```

Re-run the same command and verify counts do not grow unexpectedly:

```bash
OBSERVABILITY_DATABASE_URL=... python3 scripts/load_langfuse_archive_to_postgres.py --date 2026-06-20
```

Load the validated archive range:

```bash
OBSERVABILITY_DATABASE_URL=... python3 scripts/load_langfuse_archive_to_postgres.py --start-date 2026-05-24 --end-date 2026-06-20
```

Safe count verification examples, using the intended database explicitly:

```sql
SELECT count(*) FROM observability.langfuse_traces_meta;
SELECT count(*) FROM observability.langfuse_observations_meta;
SELECT count(*) FROM observability.langfuse_scores_meta;
SELECT count(*) FROM observability.langfuse_sessions_meta;
```

Privacy spot-check example that reports only schema shape, not data contents:

```sql
SELECT table_name, column_name
FROM information_schema.columns
WHERE table_schema = 'observability'
  AND column_name IN ('input', 'output', 'prompt', 'completion', 'messages', 'body', 'payload', 'request', 'response');
```

Expected result: zero rows.

## Known limitations

- V1 loads Langfuse archive metadata only; benchmark, Git, and Pi mirror loaders are deferred.
- Metadata can still be locally sensitive because it includes timestamps, costs, model names, repo identities, and branch names.
- The loader depends on `psql` for database writes; it does not require a Python Postgres driver.
- The script requires a valid, explicitly intended database URL before non-dry-run writes.
