-- Observability run capture v1 metadata schema.
-- Metadata-only: no prompts, completions, transcripts, tool payloads, raw records, or full diffs.

CREATE SCHEMA IF NOT EXISTS observability;

CREATE TABLE IF NOT EXISTS observability.runs (
  run_id text PRIMARY KEY,
  task_id text,
  task_name text,
  task_type text,
  project text,
  agent text,
  worker_tool text,
  model text,
  reasoning_level text,
  repo_path text,
  started_at timestamptz,
  ended_at timestamptz,
  status text,
  result_summary text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE IF NOT EXISTS observability.run_git_state (
  run_id text PRIMARY KEY REFERENCES observability.runs(run_id) ON DELETE CASCADE,
  repo_path text,
  branch_before text,
  branch_after text,
  commit_before text,
  commit_after text,
  dirty_before boolean,
  dirty_after boolean,
  files_changed_count integer,
  insertions integer,
  deletions integer,
  commit_count_created integer,
  final_git_status_clean boolean,
  captured_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE observability.run_links
  ADD COLUMN IF NOT EXISTS source_type text,
  ADD COLUMN IF NOT EXISTS source_id text,
  ADD COLUMN IF NOT EXISTS link_confidence text,
  ADD COLUMN IF NOT EXISTS notes text,
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

UPDATE observability.run_links
SET source_type = COALESCE(source_type, NULLIF(external_system, '')),
    source_id = COALESCE(source_id, NULLIF(external_id, '')),
    link_confidence = COALESCE(link_confidence, confidence::text)
WHERE source_type IS NULL OR source_id IS NULL OR link_confidence IS NULL;

ALTER TABLE observability.run_links
  ALTER COLUMN link_type DROP NOT NULL,
  ALTER COLUMN external_system DROP NOT NULL,
  ALTER COLUMN external_id DROP NOT NULL,
  ALTER COLUMN source DROP NOT NULL;

CREATE INDEX IF NOT EXISTS runs_task_id_idx ON observability.runs(task_id);
CREATE INDEX IF NOT EXISTS runs_project_idx ON observability.runs(project);
CREATE INDEX IF NOT EXISTS runs_agent_idx ON observability.runs(agent);
CREATE INDEX IF NOT EXISTS runs_status_idx ON observability.runs(status);
CREATE INDEX IF NOT EXISTS runs_started_at_idx ON observability.runs(started_at);
CREATE INDEX IF NOT EXISTS run_links_source_type_id_idx ON observability.run_links(source_type, source_id);
CREATE INDEX IF NOT EXISTS run_git_state_commit_before_idx ON observability.run_git_state(commit_before);
CREATE INDEX IF NOT EXISTS run_git_state_commit_after_idx ON observability.run_git_state(commit_after);

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pi_observability_app') THEN
    GRANT USAGE ON SCHEMA observability TO pi_observability_app;
    GRANT SELECT, INSERT, UPDATE, DELETE ON observability.runs TO pi_observability_app;
    GRANT SELECT, INSERT, UPDATE, DELETE ON observability.run_git_state TO pi_observability_app;
    GRANT SELECT, INSERT, UPDATE, DELETE ON observability.run_links TO pi_observability_app;
  END IF;
END $$;
