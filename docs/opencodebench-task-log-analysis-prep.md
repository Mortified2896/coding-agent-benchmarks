# OpenCodeBench task log — analysis preparation note

**Source data:** the single successful run on this VM,
`.local/coding-agent-task-logs/2026/06/2026-06-10T23-01-25Z-opencode-coding-agent-benchmarks/`.
This is a `validation` task against
`opencode/deepseek-v4-flash-free`, exit 0, ~8.7s.

**Scope:** this is one run, not a corpus. The point of this note
is to learn the shape of the artifact and pre-empt the gaps
before we start collecting many runs.

## Files produced

| File | Size | What it is |
|---|---:|---|
| `metadata.json` | ~7 KB | The single source of truth. Two top-level sections: the legacy `task_*` / `hermes_*` / `git_*` / `worker_prompt_*` / `*_exit_code` fields, and the structured `opencodebench.*` namespace (added Stage 2). Mode `600`, the only file with sensitive fields. |
| `summary.md` | ~600 B | Human-readable roll-up. Safe to paste into chats/notes. |
| `task.md` | ~100 B | Original task description. For the no-startup-prompt case (this run) it just says so. |
| `worker_prompt.md` | ~30 B | The actual prompt sent to the worker. Hash also lives in `metadata.json` (`worker_prompt_sha256`). |
| `evaluation.md` | ~870 B | Human evaluation template, checkbox-style. Empty on a fresh run. |
| `hermes_trace.json` | ~550 B | Stage 2.5 pointer-only record to the on-disk Hermes state. `user_prompt_sidecar` is null here because this is an OpenCode run, not a Hermes one; `worker_prompt_sidecar` points at `worker_prompt.md`. |
| `git-head-before.txt` | 41 B | The captured HEAD commit. |
| `git-branch-before.txt` | 5 B | The captured branch. |
| `git-status-before.txt` / `git-status-after.txt` | 25 B each | `git status --short` snapshots. |
| `git-diff-stat-before.txt` / `git-diff-stat.txt` | 96 B each | `git diff --stat` snapshots. |
| `git-diff-numstat-before.txt` / `git-diff-numstat.txt` | 27 B each | `git diff --numstat` (added/deleted per file). |
| `git-diff-before.patch` / `git-diff.patch` | 1.5 KB each | Full `git diff` patch (before and after the run, so the "what did the worker actually change" delta is computable). |

The `*-before.*` files capture pre-run state; the bare files capture post-run state. Comparing them is the most reliable "what did this run actually do" answer.

## Most useful metadata fields for later analysis

**Identity / join keys** (always populated, low cardinality):

- `task_id` (also the directory name) — unique per run.
- `opencodebench.session_id` — equal to `task_id` for current runs but is the explicit join key for analysis.
- `opencodebench.project_id` — `basename(repo_root)`. Groups runs by target repo.
- `opencodebench.repo_root` — absolute path. Local-only, do not treat as a portable ID.
- `opencodebench.git_commit_before` — the SHA the run started from. Lets analysis diff "what changed since commit X" by walking task logs.
- `repo_path`, `git_root` — same as `opencodebench.repo_root` and the toplevel; legacy field.
- `harness`, `harness_mode` — filterable. For this run: `"opencode" / "delegated"`.
- `model_id` — `opencode/deepseek-v4-flash-free` here. Critical for cost / latency slicing.
- `agent_command_label` — free-form, e.g. `opencode-direct`. Defaulted from harness+mode; safe to filter on.
- `upstream_orchestrator` — `none` / `hermes` / `unknown`. Lets analysis distinguish standalone runs from Hermes-orchestrated runs.
- `task_type`, `task_type_status` — taxonomy filter. `validation` / `valid` here. The `_status` is `"valid" | "unknown" | "empty" | "unset"`; treat `unknown` separately from `valid`.
- `task_type_raw` — the verbatim input, even if normalized. Useful when `task_type_status == "unknown"`.

**Outcome / cost**:

- `opencodebench.timing.{start_unix_seconds, finish_unix_seconds, duration_seconds}` — three sub-second fields. Sub-second precision matters for short validation runs.
- `opencodebench.diff_summary.{files_changed, lines_added, lines_deleted, working_tree_dirty_after, diff_produced, is_git_repo}` — the Stage 2 Card 4 numeric summary. **`working_tree_dirty_after` and `diff_produced` are intentionally independent** (see `docs/stage-2-card-6-validation.md` — the wrapper itself can leave the tree dirty via `.local/`, so dirty-after is not proof of a worker change).
- `exit_code` (top-level), `agent_exit_code`, `opencode_exit_code` — `exit_code` is the canonical unified field; the other two are the wrapper's view and the underlying binary's view.
- `git-diff.patch` / `git-diff-stat.txt` — for "did the worker actually do something useful" qualitative review.

**Provenance / privacy**:

- `hermes_*` block — empty for an OpenCode-only run by design. Don't try to populate it from OpenCode runs.
- `worker_prompt_sha256` / `worker_prompt_chars` — privacy-respecting fingerprint of the prompt. Combine with `task_id` and `model_id` and you can group runs by prompt without ever holding the prompt text.
- `opencode_executable_path`, `opencode_version` (see "Missing fields" below), `hermes_version` (when present) — for cross-run reproducibility checks.

**Orchestrator metadata** (Stage 2.6, empty for this run):

- `opencodebench.orchestrator.{session_id, model, model_provider, profile, source_label, is_cli_session, workspace, worktree_path, reasoning_level, reasoning_level_source, capture_source}` — populated only when `upstream_orchestrator == "hermes"`. The fields are explicit-empties, not missing — easy to filter with `select(.opencodebench.orchestrator.source_label != "unavailable")`.

## Missing or underpopulated fields

### New fields added: `opencode_session_id` and `langfuse_trace_id`

Stage 3 tracking adds two new field groups to `metadata.json`,
resolved during finish capture:

| Field | Status for this run | Notes |
|---|---|---|
| `opencode_session_id` | `not_found` (no matching session in time window) or `resolved` (matched) | Resolved from `~/.local/share/opencode/opencode.db` via directory match + time window, preferring root `build` sessions over subagents. Strong join key to OpenCode's internal session DB. |
| `opencode_session_id_status` | `resolved` / `not_found` / `ambiguous` / `error` / `skipped` | Categorical signal for downstream analysis. |
| `opencode_session_id_source` | `sqlite` (current impl) | Where the resolution came from. |
| `opencode_session_id_resolved_at` | ISO-8601 timestamp or `null` | When the DB lookup was performed. |
| `opencode_session_id_candidates` | integer (0 when resolved/not_found) | Candidate count when ambiguous; avoid storing raw candidate rows. |
| `langfuse_trace_id` | `null` | Always `null`; Langfuse join is via `opencodebench.session_id` in OTel resource attributes. |
| `langfuse_trace_id_status` | `skipped` | Resolution deferred by design. |

All fields also appear nested under `opencodebench.*` for
consistent grouping.

Two real gaps for an OpenCode run like this one:

1. **`opencode_version` is `null`.** The field is reserved in the
   schema but no wrapper or capture script populates it
   (`grep -rn 'opencode_version\|OPENCODE_VERSION' capture-task-start.sh
   capture-task-finish.sh opencode-bench.sh hermes-bench.sh
   opencodebench-opencode` returns zero hits). Compare to
   `hermes_version`, which `hermes-bench.sh` sets via
   `"$hermes_bin" --version | head -n 1` and threads into
   `capture-task-start.sh`. The OpenCode wrapper would need a
   parallel `"$opencode_bin" --version` capture (the binary
   exits 0 with a single line, safe to call) and an
   `OPENCODE_VERSION` env-var passthrough. Tiny diff, but it
   changes the wrapper contract — not landing it in this note.

2. **`reasoning_level` (top-level) is `null`.** The
   `REASONING_LEVEL` env var is plumbed through
   `capture-task-start.sh` (line ~223) but no current wrapper
   sets it. For the opencode/deepseek-v4-flash-free model this is
   an accurate "no reasoning" report; for other free models
   (e.g. `gpt-5.5` mentioned in
   `docs/current-openbench-model-routing.md`) it would be a real
   gap. Out of scope here; flagged for the analysis prep.

There is no missing **structural** field — every analysis angle
in the doc `docs/reconstructing-benchmark-cases.md` has a
corresponding key in `metadata.json`. The gaps are
populatability, not design.

## Recommended next minimal analysis step

Do not build a database. Do not write a new schema. The smallest
useful next step is a **shell + jq recipe** that walks
`.local/coding-agent-task-logs/20*/*/*/metadata.json` and
produces a single `runs.csv` (or `runs.jsonl`) for offline
analysis. Concretely:

```sh
cd /home/hermes/workspace/repos/coding-agent-benchmarks
find .local/coding-agent-task-logs -name metadata.json -type f | sort \
  | xargs -I{} sh -c 'jq -c . "{}"' \
  | jq -s 'map({
        task_id,
        timestamp_start,
        duration_seconds: .opencodebench.timing.duration_seconds,
        model_id,
        task_type,
        task_type_status,
        harness,
        harness_mode,
        agent_command_label,
        upstream_orchestrator,
        exit_code,
        files_changed: .opencodebench.diff_summary.files_changed,
        lines_added:    .opencodebench.diff_summary.lines_added,
        lines_deleted:  .opencodebench.diff_summary.lines_deleted,
        dirty_after:    .opencodebench.diff_summary.working_tree_dirty_after,
        diff_produced:  .opencodebench.diff_summary.diff_produced,
        git_commit_before: .opencodebench.git_commit_before,
        worker_prompt_sha256
      })
      | (map(keys) | add | unique) as $cols
      | map(. as $r | $cols | map($r[.] // "")) as $rows
      | $cols, $rows[]
      | @csv' > runs.csv
```

This produces a `runs.csv` with one row per captured run and
columns matching the "most useful" list above. Verified end-to-end
on the two runs already on disk (the failed 22:54 run and the
successful 23:01 run) — the recipe correctly identifies the
failure that `2d7aecb` fixed. It is the minimum surface for any
follow-up analysis (p50/p95 duration by `model_id`, failure rate
by `harness_mode`, distribution of `lines_added` by `task_type`,
etc.) and is fully reversible — no schema, no migration, no new
file in the repo. After the corpus grows past ~20 runs, that
recipe is the right time to graduate to a sqlite3 table (per the
README's runtime-deps hint: `apt install sqlite3`), still
without committing a schema.

## What I am **not** recommending yet

* No new directory or `results/`-style folder in the repo.
* No new JSON schema, no new doc with mandatory fields.
* No `scripts/analyze_*.py` committed to the repo. The
  `scripts/import_hermes_transcripts.py` already exists and is
  the only analysis-flavored script in the project today; not
  modifying it without evidence it needs to change.
* No `git diff` of generated `metadata.json` for analysis — the
  per-task summary already exists in
  `opencodebench.diff_summary.*` and is the canonical answer.

## Cross-references

* Schema definitions and field-by-field rationale:
  `docs/stage-2-tracking.md`, `docs/stage-25-tracking.md`,
  `docs/stage-26-tracking.md`,
  `docs/stage-29-private-transcript-layer.md`.
* Worked validation cases for the diff-summary fields:
  `docs/stage-2-card-6-validation.md` (specifically the
  "`working_tree_dirty_after: true` … is correct, not a bug"
  note).
* Capture script entry points:
  `capture-task-start.sh`, `capture-task-finish.sh`.
* The companion notes from this same session:
  `docs/langfuse-debian-vm-status.md` and
  `docs/hermes-noninteractive-capture-design.md`.
