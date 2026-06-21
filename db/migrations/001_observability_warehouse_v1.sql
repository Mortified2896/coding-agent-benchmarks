-- Observability warehouse v1 metadata schema.
-- Metadata-only: no raw Langfuse input/output payloads or full JSON records.

CREATE SCHEMA IF NOT EXISTS observability;

CREATE TABLE IF NOT EXISTS observability.import_runs (
  id uuid PRIMARY KEY,
  importer_name text NOT NULL,
  importer_version text NOT NULL,
  source_type text NOT NULL,
  archive_root text,
  started_at timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz,
  status text NOT NULL,
  dry_run boolean NOT NULL DEFAULT false,
  force boolean NOT NULL DEFAULT false,
  date_start date,
  date_end date,
  traces_count integer NOT NULL DEFAULT 0,
  observations_count integer NOT NULL DEFAULT 0,
  scores_count integer NOT NULL DEFAULT 0,
  sessions_count integer NOT NULL DEFAULT 0,
  files_count integer NOT NULL DEFAULT 0,
  error_category text,
  message text
);

CREATE TABLE IF NOT EXISTS observability.source_archive_files (
  id uuid PRIMARY KEY,
  archive_date date NOT NULL,
  object_type text NOT NULL,
  source_path text NOT NULL,
  file_name text NOT NULL,
  gzip_size_bytes bigint,
  sha256 text NOT NULL,
  manifest_record_count integer NOT NULL DEFAULT 0,
  manifest_page_count integer,
  manifest_status text NOT NULL,
  exporter_version text,
  export_window_start timestamptz,
  export_window_end timestamptz,
  first_imported_at timestamptz NOT NULL DEFAULT now(),
  last_imported_at timestamptz NOT NULL DEFAULT now(),
  last_import_run_id uuid REFERENCES observability.import_runs(id),
  UNIQUE (archive_date, object_type),
  UNIQUE (source_path)
);

CREATE TABLE IF NOT EXISTS observability.source_file_imports (
  import_run_id uuid NOT NULL REFERENCES observability.import_runs(id) ON DELETE CASCADE,
  source_file_id uuid NOT NULL REFERENCES observability.source_archive_files(id) ON DELETE CASCADE,
  object_type text NOT NULL,
  imported_count integer NOT NULL DEFAULT 0,
  skipped_count integer NOT NULL DEFAULT 0,
  error_count integer NOT NULL DEFAULT 0,
  PRIMARY KEY (import_run_id, source_file_id)
);

CREATE TABLE IF NOT EXISTS observability.langfuse_traces_meta (
  trace_id text PRIMARY KEY,
  archive_date date NOT NULL,
  source_file_id uuid REFERENCES observability.source_archive_files(id),
  import_run_id uuid REFERENCES observability.import_runs(id),
  project_id text,
  environment text,
  timestamp timestamptz,
  created_at timestamptz,
  updated_at timestamptz,
  name text,
  html_path text,
  latency double precision,
  total_cost numeric,
  session_id text,
  metadata_session_id text,
  user_id_hash text,
  external_id_hash text,
  model text,
  provider text,
  git_branch text,
  git_commit text,
  git_remote_host text,
  git_remote_path text,
  repo_identity text,
  repo_owner text,
  repo_name text,
  repo_root_name text,
  turn_count integer,
  tool_call_count integer,
  total_tools integer,
  total_tool_errors integer,
  tool_success_rate double precision,
  session_had_errors boolean,
  completed boolean,
  source_type text,
  metadata_source text,
  tag_count integer,
  score_count integer,
  observation_count integer,
  content_hash text NOT NULL,
  imported_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS observability.langfuse_observations_meta (
  observation_id text PRIMARY KEY,
  trace_id text,
  archive_date date NOT NULL,
  source_file_id uuid REFERENCES observability.source_archive_files(id),
  import_run_id uuid REFERENCES observability.import_runs(id),
  parent_observation_id text,
  project_id text,
  environment text,
  type text,
  name text,
  level text,
  status_message text,
  start_time timestamptz,
  end_time timestamptz,
  completion_start_time timestamptz,
  created_at timestamptz,
  updated_at timestamptz,
  latency double precision,
  time_to_first_token double precision,
  model text,
  model_id text,
  provider text,
  finish_reason text,
  request_id_hash text,
  prompt_tokens integer,
  completion_tokens integer,
  total_tokens integer,
  calculated_input_cost numeric,
  calculated_output_cost numeric,
  calculated_total_cost numeric,
  input_price numeric,
  output_price numeric,
  content_hash text NOT NULL,
  imported_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS observability.langfuse_scores_meta (
  score_id text PRIMARY KEY,
  trace_id text,
  observation_id text,
  archive_date date NOT NULL,
  source_file_id uuid REFERENCES observability.source_archive_files(id),
  import_run_id uuid REFERENCES observability.import_runs(id),
  name text,
  value numeric,
  string_value text,
  data_type text,
  source text,
  timestamp timestamptz,
  created_at timestamptz,
  updated_at timestamptz,
  trace_environment text,
  trace_tag_count integer,
  execution_trace_id text,
  content_hash text NOT NULL,
  imported_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS observability.langfuse_sessions_meta (
  session_id text PRIMARY KEY,
  archive_date date NOT NULL,
  source_file_id uuid REFERENCES observability.source_archive_files(id),
  import_run_id uuid REFERENCES observability.import_runs(id),
  project_id text,
  environment text,
  created_at timestamptz,
  content_hash text NOT NULL,
  imported_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS observability.run_links (
  id uuid PRIMARY KEY,
  run_id text,
  link_type text NOT NULL,
  external_system text NOT NULL,
  external_id text NOT NULL,
  confidence numeric,
  source text NOT NULL,
  source_file_id uuid REFERENCES observability.source_archive_files(id),
  import_run_id uuid REFERENCES observability.import_runs(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS langfuse_traces_meta_session_idx ON observability.langfuse_traces_meta(session_id);
CREATE INDEX IF NOT EXISTS langfuse_traces_meta_timestamp_idx ON observability.langfuse_traces_meta(timestamp);
CREATE INDEX IF NOT EXISTS langfuse_observations_meta_trace_idx ON observability.langfuse_observations_meta(trace_id);
CREATE INDEX IF NOT EXISTS langfuse_scores_meta_trace_idx ON observability.langfuse_scores_meta(trace_id);
CREATE INDEX IF NOT EXISTS source_archive_files_date_type_idx ON observability.source_archive_files(archive_date, object_type);
CREATE UNIQUE INDEX IF NOT EXISTS run_links_unique_idx ON observability.run_links(link_type, external_system, external_id, COALESCE(run_id, ''));
