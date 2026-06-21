# Langfuse local archive exporter v1

`./scripts/export_langfuse_archive.py` performs a read-only, bounded export from the Langfuse public API to local archive files outside this repository.

## Dry run

```bash
cd /home/hermes/workspace/repos/coding-agent-benchmarks
python3 scripts/export_langfuse_archive.py --date YYYY-MM-DD --dry-run
```

The dry run checks configured credentials and endpoint/pagination shape. It prints only set/missing config status, object statuses, page counts, and record counts. It does not write archive records.

## Export one UTC day

```bash
python3 scripts/export_langfuse_archive.py --date YYYY-MM-DD
```

For a custom bounded window:

```bash
python3 scripts/export_langfuse_archive.py --start 2026-06-19T00:00:00Z --end 2026-06-20T00:00:00Z
```

Use `--force` only when intentionally replacing the expected files for a partition that already has a successful `manifest.json`.

## Archive location

Files are written outside the git repository under:

```text
/home/hermes/archives/langfuse/raw/YYYY/MM/DD/
  traces.jsonl.gz
  observations.jsonl.gz
  scores.jsonl.gz
  sessions.jsonl.gz
  manifest.json
```

`manifest.json` includes the export window, export timestamps, attempted object types, per-object counts, page counts, gzip sizes, SHA-256 hashes, API status summary, and completion status.

## Intentionally not implemented yet

- No cron jobs, systemd units, timers, or other automation.
- No Hetzner Object Storage configuration or remote sync.
- No Langfuse data mutation; only GET requests are used.
- No package installation or SDK dependency.
- No database/Postgres loader.
- No terminal printing of secrets, env values, prompts, completions, tool payloads, observation bodies, or exported records.
