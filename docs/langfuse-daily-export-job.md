# Langfuse daily archive export job

This repository provides the wrapper used by the Hermes user-level systemd timer for the daily Langfuse archive export.

## Purpose

The job exports yesterday's complete Langfuse archive partition into the local raw archive. It is an export/archive job only:

- It does not modify Langfuse data.
- It does not configure or sync Hetzner Object Storage.
- It does not load data into Postgres.
- Archive data stays outside git under `/home/hermes/archives/langfuse/raw`.

## Installed user systemd units

The live units are installed outside the repository:

```text
/home/hermes/.config/systemd/user/langfuse-archive-export.service
/home/hermes/.config/systemd/user/langfuse-archive-export.timer
```

The timer runs daily at 04:30 in `Europe/Berlin`.

## Wrapper

```text
scripts/run_daily_langfuse_archive_export.sh
```

Behavior:

1. Computes yesterday's date using `Europe/Berlin`.
2. Refuses to export the current Berlin local day.
3. Uses `scripts/export_langfuse_archive.py --date YYYY-MM-DD --page-size 25`.
4. Does not pass `--force` and does not overwrite successful exports.
5. If a manifest already exists, validates it and exits successfully without rewriting records.
6. Validates new or existing successful archives before returning success.

The wrapper prints only operational metadata and validation status. It must not print secrets, environment values, raw Langfuse records, prompts, completions, tool payloads, or observation bodies.

## Validation checks

The wrapper verifies:

- `manifest.json` exists under `/home/hermes/archives/langfuse/raw`.
- Manifest `schema_version` is `1`.
- Manifest `completed_successfully` is `true`.
- Each object status is `success` or `skipped`.
- Each successful object has a gzip-readable JSONL file under the archive root.
- JSONL line counts match manifest `record_count` values.
- SHA-256 hashes match manifest `sha256` values.

Any validation failure exits non-zero so systemd marks the service failed.

## Operations

Check timer:

```bash
systemctl --user list-timers langfuse-archive-export.timer
```

Run safely by date override:

```bash
LANGFUSE_ARCHIVE_DATE=YYYY-MM-DD scripts/run_daily_langfuse_archive_export.sh
```

Run the service manually:

```bash
systemctl --user start langfuse-archive-export.service
```

Check status/logs without printing raw archive content:

```bash
systemctl --user status langfuse-archive-export.service
journalctl --user -u langfuse-archive-export.service -n 50 --no-pager
```
