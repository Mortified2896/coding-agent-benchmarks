# Observability GitHub metadata v1

Date: 2026-06-21

## Scope

Adds metadata-only GitHub capture for the local `observability` Postgres warehouse.

Files:

- `db/migrations/003_observability_github_metadata_v1.sql`
- `scripts/load_github_metadata_to_postgres.py`

## Privacy boundary

The loader stores only GitHub metadata. It does **not** store raw API records, issue/PR bodies, comments, review bodies, diffs, patches, prompts, transcripts, tool payloads, tokens, secrets, database URLs, or archive contents.

Potentially identifying GitHub names/emails/logins are hashed where captured for commits and issue/PR authors.

## Database URL

Non-dry-run database access is intentionally explicit and narrow:

```text
/etc/hermes/pi_observability_postgres.env
PI_OBSERVABILITY_DATABASE_URL
```

The loader reports only whether the database is available; it never prints the URL.

## Loader usage

```bash
python3 scripts/load_github_metadata_to_postgres.py --dry-run
python3 scripts/load_github_metadata_to_postgres.py --repo owner/name --dry-run
python3 scripts/load_github_metadata_to_postgres.py --repo owner/name --since 2026-06-01T00:00:00Z --dry-run
python3 scripts/load_github_metadata_to_postgres.py --repo owner/name --since 2026-06-01T00:00:00Z
# If the app DB role cannot create tables, apply the migration with an admin role explicitly:
sudo -u postgres psql -v ON_ERROR_STOP=1 -X -d pi_observability -f db/migrations/003_observability_github_metadata_v1.sql
```

`gh auth status` is checked without printing token details. GitHub API responses are parsed in memory and not logged.

## Captured tables

- `observability.github_repositories`
- `observability.github_commits`
- `observability.github_issues`
- `observability.github_pull_requests`
- `observability.github_check_runs`
- `observability.run_github_commit_links`

Run-to-commit links are conservative: only existing `observability.run_git_state.commit_before` and `commit_after` values that exactly match loaded commit SHAs are linked.

## Validation

Safe validation commands:

```bash
python3 -m py_compile scripts/load_github_metadata_to_postgres.py
python3 scripts/load_github_metadata_to_postgres.py --repo owner/name --since YYYY-MM-DDTHH:MM:SSZ --dry-run
psql -f db/migrations/003_observability_github_metadata_v1.sql
python3 scripts/load_github_metadata_to_postgres.py --repo owner/name --since YYYY-MM-DDTHH:MM:SSZ
python3 scripts/load_github_metadata_to_postgres.py --repo owner/name --since YYYY-MM-DDTHH:MM:SSZ
```

Privacy schema spot-check:

```sql
SELECT table_name, column_name
FROM information_schema.columns
WHERE table_schema = 'observability'
  AND column_name IN ('body','comments','review_comments','diff','patch','payload','request','response','prompt','completion','transcript');
```

Expected result: zero rows.

## Idempotency

All tables have deterministic primary keys and use `ON CONFLICT` upserts. Re-running the loader refreshes metadata and `captured_at` timestamps without duplicating repositories, commits, issues, pull requests, checks, or run links.

## Known limitations

- v1 captures metadata only and intentionally omits comments, bodies, review text, diffs, and patches.
- Check-runs are sampled for the most recent loaded commits to avoid excessive API calls.
- Issue/PR links are not inferred from text; only exact run commit SHA links are created.

## Next steps

- Add configurable page/commit limits.
- Add explicit issue/PR linking only when safe correlation fields exist.
- Add warehouse views for run-to-commit and PR/check summaries.
