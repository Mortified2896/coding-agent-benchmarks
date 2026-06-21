-- Observability GitHub metadata v1 schema.
-- Metadata-only: no issue/PR bodies, comments, review bodies, diffs, patches, raw API records, prompts, transcripts, or tool payloads.

CREATE SCHEMA IF NOT EXISTS observability;

CREATE TABLE IF NOT EXISTS observability.github_repositories (
  repo_full_name text PRIMARY KEY,
  owner text NOT NULL,
  name text NOT NULL,
  github_id bigint,
  default_branch text,
  visibility text,
  is_private boolean,
  html_url text,
  updated_at timestamptz,
  captured_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS observability.github_commits (
  repo_full_name text NOT NULL REFERENCES observability.github_repositories(repo_full_name) ON DELETE CASCADE,
  commit_sha text NOT NULL,
  short_sha text,
  author_name_hash text,
  author_email_hash text,
  author_date timestamptz,
  committer_date timestamptz,
  message_subject text,
  html_url text,
  captured_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (repo_full_name, commit_sha)
);

CREATE TABLE IF NOT EXISTS observability.github_issues (
  repo_full_name text NOT NULL REFERENCES observability.github_repositories(repo_full_name) ON DELETE CASCADE,
  issue_number integer NOT NULL,
  github_id bigint,
  title text,
  state text,
  labels jsonb NOT NULL DEFAULT '[]'::jsonb,
  created_at timestamptz,
  updated_at timestamptz,
  closed_at timestamptz,
  html_url text,
  captured_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (repo_full_name, issue_number)
);

CREATE TABLE IF NOT EXISTS observability.github_pull_requests (
  repo_full_name text NOT NULL REFERENCES observability.github_repositories(repo_full_name) ON DELETE CASCADE,
  pr_number integer NOT NULL,
  github_id bigint,
  title text,
  state text,
  merged boolean,
  base_branch text,
  head_branch text,
  head_sha text,
  created_at timestamptz,
  updated_at timestamptz,
  closed_at timestamptz,
  merged_at timestamptz,
  html_url text,
  captured_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (repo_full_name, pr_number)
);

CREATE TABLE IF NOT EXISTS observability.github_checks (
  repo_full_name text NOT NULL REFERENCES observability.github_repositories(repo_full_name) ON DELETE CASCADE,
  commit_sha text NOT NULL,
  check_name text NOT NULL,
  check_run_id bigint,
  status text,
  conclusion text,
  started_at timestamptz,
  completed_at timestamptz,
  html_url text,
  captured_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (repo_full_name, commit_sha, check_name)
);

CREATE TABLE IF NOT EXISTS observability.run_github_commit_links (
  run_id text NOT NULL REFERENCES observability.runs(run_id) ON DELETE CASCADE,
  repo_full_name text NOT NULL,
  commit_sha text NOT NULL,
  link_source text NOT NULL,
  link_confidence text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (run_id, repo_full_name, commit_sha, link_source)
);

CREATE INDEX IF NOT EXISTS github_commits_sha_idx ON observability.github_commits(commit_sha);
CREATE INDEX IF NOT EXISTS github_issues_updated_idx ON observability.github_issues(updated_at);
CREATE INDEX IF NOT EXISTS github_prs_head_sha_idx ON observability.github_pull_requests(head_sha);
CREATE INDEX IF NOT EXISTS github_prs_updated_idx ON observability.github_pull_requests(updated_at);
CREATE INDEX IF NOT EXISTS github_checks_commit_idx ON observability.github_checks(commit_sha);
CREATE INDEX IF NOT EXISTS run_github_commit_links_commit_idx ON observability.run_github_commit_links(commit_sha);

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pi_observability_app') THEN
    GRANT USAGE ON SCHEMA observability TO pi_observability_app;
    GRANT SELECT, INSERT, UPDATE, DELETE ON observability.github_repositories TO pi_observability_app;
    GRANT SELECT, INSERT, UPDATE, DELETE ON observability.github_commits TO pi_observability_app;
    GRANT SELECT, INSERT, UPDATE, DELETE ON observability.github_issues TO pi_observability_app;
    GRANT SELECT, INSERT, UPDATE, DELETE ON observability.github_pull_requests TO pi_observability_app;
    GRANT SELECT, INSERT, UPDATE, DELETE ON observability.github_checks TO pi_observability_app;
    GRANT SELECT, INSERT, UPDATE, DELETE ON observability.run_github_commit_links TO pi_observability_app;
  END IF;
END $$;
