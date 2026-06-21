# Langfuse archive future download plan

## Daily cadence

- The Hermes daily archive job is documented in `docs/langfuse-daily-export-job.md`.
- Export only complete days during routine backfill/maintenance. The installed daily job chooses yesterday's date using `Europe/Berlin` local time and runs at 04:30 Europe/Berlin.
- Keep current-day exports out of the normal complete-day archive flow unless a future exporter mode clearly labels them as partial/current-day exports.

## Local archive path

Archive files stay outside this repository under:

```text
/home/hermes/archives/langfuse/raw/YYYY/MM/DD/
```

Expected files for a successful day are `manifest.json` plus gzip JSONL files for traces, observations, scores, and sessions.

## Validation checks

For each exported day:

- `manifest.json` has schema version 1 and `completed_successfully: true`.
- Each object status is `success` or an explicitly supported `skipped` status.
- Each `.jsonl.gz` file is gzip-readable.
- JSONL line counts match the manifest `record_count` values.
- SHA-256 hashes of gzip files match manifest hashes.
- Output path is under `/home/hermes/archives/langfuse/raw`, not inside the git repository.

## Failed or incomplete days

- Do not overwrite a successful v1 manifest.
- Inspect incomplete days without printing raw records or raw JSON payloads.
- Record only file names, sizes, manifest metadata, statuses, counts, and hash presence/results.
- If the day is clearly failed/incomplete and all affected files belong to that date partition, move those files to a quarantine directory outside the repository, for example:

```text
/home/hermes/archives/langfuse/quarantine/YYYY-MM-DD-incomplete-<UTC timestamp>/
```

- Re-export the date with the reliable exporter and a conservative `--page-size`.
- If ownership/safety is unclear, do not retry automatically; report the reason and leave files untouched.

## Automation timing

Add cron, systemd timers, or other automation only after several manual daily exports have succeeded and validation is repeatable. Automation should export yesterday's complete UTC day, validate immediately, and fail closed without deleting successful archives.

## Hetzner Object Storage sync

Add Hetzner Object Storage only after local daily export and validation are stable. Sync should run after local validation succeeds, preserve the `YYYY/MM/DD` partition layout, and avoid uploading partial or failed days.

## Postgres loading

Add Postgres loading only after local archive retention and object storage sync are reliable. Loading should read validated archive files, be idempotent by day/object, and never be the source of truth for raw archives.

## Git safety

Never commit exported archive data, quarantined archive files, credentials, environment files, raw Langfuse records, prompts, completions, tool payloads, observation bodies, or generated data dumps. Only exporter code, documentation, validation scripts, and non-sensitive metadata belong in git.
