# Stage 2 Tracking — Workflow and Schema

This document describes the Stage 2 tracking layer added on top of the
Stage 1 task-capture wrapper. It is the Stage 2 analogue of
[docs/task-capture-wrapper.md](task-capture-wrapper.md). If you have
not read the Stage 1 doc, start there: Stage 2 is purely additive and
inherits Stage 1's wrapper, command shape, and sidecar files.

## What Stage 2 adds

Stage 1 captures the Git before/after state and a baseline metadata
record. Stage 2 layers on top of that to make the metadata more
analysis-friendly and to add a human evaluation sidecar. The five
additions:

1. **Cleaner timing fields** (Card 2): ISO 8601 UTC `start_time` /
   `finish_time`, sub-second `duration_seconds`, unified `exit_code`.
2. **Task type classification** (Card 3): the env var
   `OPENCODEBENCH_TASK_TYPE` records what kind of work the run was.
3. **Diff summary at the metadata top level** (Card 4): `files_changed`,
   `lines_added`, `lines_deleted`, `working_tree_dirty_after`,
   `diff_produced` so a benchmark aggregator can join on these without
   parsing the sidecar `git-diff-numstat.txt`.
4. **Human evaluation sidecar** (Card 5): a pre-filled markdown
   template at `<task_dir>/evaluation.md` for the human to rate the
   run, decide whether to accept it, and record comments.
5. **The routing policy** (separate doc, see below) governs which
   worker model to use and what to do when a worker call fails.

Stage 1 fields are preserved verbatim. Stage 2 never renames a Stage 1
key, never removes a field, and never changes the meaning of an
existing field. All Stage 2 additions appear either as new top-level
keys in `metadata.json` or as a new sub-object under
`opencodebench.*`.

## How to invoke a tracked run

The wrapper is the same as Stage 1:

```text
./opencodebench-opencode --dir <repo> -m <model> ...opencode args...
```

The two Stage 2 additions that show up on the command line are:

- `-m <model>` (or `--model <model>`) — required if you want the run
  to be benchmark-valid for a specific model. Without `-m`, the run
  uses OpenCode's default and the `model_id` field will be whatever
  the default resolves to (or `"unknown"` if OpenCode did not surface
  it). See [docs/current-openbench-model-routing.md](current-openbench-model-routing.md)
  for the worker selection policy.
- `OPENCODEBENCH_TASK_TYPE=<value>` — env var set in the parent
  shell, NOT on the opencode command line. Allowed values are
  `implementation`, `debugging`, `review`, `docs`, `investigation`,
  `refactor`, `validation`, `architecture`. The value is normalized
  to lowercase and trimmed before validation. Unknown values are
  recorded as-is in `task_type_raw` and flagged in `task_type_status`
  as `"unknown"`. Missing or whitespace-only values become
  `task_type="unspecified"` with `task_type_status="unset"` or
  `"empty"`. The wrapper never crashes on a bad value; it warns to
  stderr and continues.

A typical tracked run looks like:

```sh
env -u OPENCODE_SERVER_PASSWORD -u OPENCODE_SERVER_USERNAME \
  OPENCODEBENCH_TASK_TYPE=implementation \
  ./opencodebench-opencode --dir . -m opencode/deepseek-v4-flash-free \
  run "fix the off-by-one bug in capture-task-finish.sh"
```

The `env -u` is needed on this host because the Hermes shell inherits
`OPENCODE_SERVER_PASSWORD` and `OPENCODE_SERVER_USERNAME` from a
running opencode server. The wrapper unsets them automatically for
non-attach invocations, so the explicit `env -u` is belt-and-suspenders
but not strictly required when going through the wrapper.

## Where the metadata ends up

Every tracked run creates a new directory at:

```text
.local/coding-agent-task-logs/<year>/<month>/<task_id>/
```

`task_id` is the ISO 8601 UTC timestamp of the run start, suffixed
with `opencode-<repo-basename>` and a short random tag. Example:

```text
.local/coding-agent-task-logs/2026/06/2026-06-09T22-21-44Z-opencode-coding-agent-benchmarks/
```

Inside that directory:

- `metadata.json` — the full metadata record, both Stage 1 and
  Stage 2 fields. This is the canonical file for analysis.
- `summary.md` — a human-readable one-page summary of the run,
  including Started / Duration / Exit code (Stage 2) plus the
  Stage 1 fields.
- `git-diff-before.patch`, `git-diff-stat-before.txt`,
  `git-diff-numstat-before.txt`, `git-status-before.txt` — the
  pre-run Git state.
- `git-diff.patch`, `git-diff-stat.txt`, `git-diff-numstat.txt`,
  `git-status-after.txt` — the post-run Git state.
- `git-head-before.txt`, `git-branch-before.txt` — the starting
  commit and branch.
- `task.md` — the OpenCode session's own task log (its contents
  depend on the opencode version and prompt; see the "Known
  limitations" section below).
- `evaluation.md` — Stage 2 human evaluation sidecar, written
  automatically after the run finishes unless skipped. See below.

The log root is `.local/coding-agent-task-logs/` in the current
working directory by default, and can be overridden with
`OPENCODEBENCH_LOG_ROOT=<path>`. The wrapper refuses to write
inside an unignored Git repo as a safety guard, so the default is
safe even on a fresh checkout.

## Stage 2 metadata fields

Below are the Stage 2 additions to `metadata.json`. Top-level keys
and nested keys under `opencodebench.*` are both listed; the
nested copies exist for the convenience of downstream tools that
already group by `opencodebench.<subsystem>`. Values are always
identical between the two locations for a given run.

| Field | Type | Source | Notes |
|-------|------|--------|-------|
| `model_id` | string | `-m` / `--model` argv, or `OPENCODE_MODEL`, or `MODEL`, else `"unknown"` | Precedence: argv > `OPENCODE_MODEL` > `MODEL` > `"unknown"`. Card 1. |
| `start_time` | string (ISO 8601 UTC) | `date -u` at capture-task-start | Suffixed with `Z`. Card 2. |
| `finish_time` | string (ISO 8601 UTC) | `date -u` at capture-task-finish | Suffixed with `Z`. Card 2. |
| `duration_seconds` | number (float, ≥ 0) | computed at finish | Clamped to 0 on clock skew. Card 2. |
| `exit_code` | integer or `null` | the agent exit code (0 success, 1+ failure) | `null` if the wrapper did not surface one. Card 2. |
| `task_type` | string | `OPENCODEBENCH_TASK_TYPE` normalized | One of the 8 allowed values, or `"unspecified"`, or the unknown value verbatim. Card 3. |
| `task_type_status` | string | validator output | `"valid"`, `"unset"`, `"empty"`, or `"unknown"`. Card 3. |
| `task_type_raw` | string or `null` | the original env var value | Preserved so downstream can see what the user actually typed. `null` if unset. Card 3. |
| `files_changed` | integer (≥ 0) | `git diff --name-only` count | 0 if not a Git repo. Card 4. |
| `lines_added` | integer (≥ 0) | sum of `git diff --numstat` column 1 | Binary files (`-` in numstat) contribute 0. Card 4. |
| `lines_deleted` | integer (≥ 0) | sum of `git diff --numstat` column 2 | Same. Card 4. |
| `working_tree_dirty_after` | bool or `null` | `git status --short` non-empty | `null` if not a Git repo. Card 4. |
| `diff_produced` | bool | `files_changed > 0` | Always equivalent to `files_changed > 0` for a Git repo. Card 4. |
| `opencodebench.timing.start_unix_seconds` | number (float) | `date +%s.%N` at start | For accurate duration math; private handshake. Card 2. |
| `opencodebench.timing.finish_unix_seconds` | number (float) | `date +%s.%N` at finish | Card 2. |
| `opencodebench.timing.duration_seconds` | number (float) | `finish - start` | Card 2. |
| `opencodebench.task_type` | string | mirrors top-level `task_type` | Card 3. |
| `opencodebench.diff_summary.files_changed` | integer | mirrors top-level | Card 4. |
| `opencodebench.diff_summary.lines_added` | integer | mirrors top-level | Card 4. |
| `opencodebench.diff_summary.lines_deleted` | integer | mirrors top-level | Card 4. |
| `opencodebench.diff_summary.working_tree_dirty_after` | bool or null | mirrors top-level | Card 4. |
| `opencodebench.diff_summary.diff_produced` | bool | mirrors top-level | Card 4. |
| `opencodebench.diff_summary.is_git_repo` | bool | whether the target was a Git repo | Card 4. |

## Filling in `evaluation.md`

After every tracked run, the wrapper writes a pre-filled copy of
`config/evaluation_template.md` to `<task_dir>/evaluation.md` and
prints the path. The template has 14 placeholders (run_id, repository,
model, task_type, start_time, finish_time, duration, exit_code,
files_changed, lines_added, lines_deleted, working_tree_dirty_after,
diff_produced, evaluated_at) which the wrapper sed-replaces from
`metadata.json` using a control-char delimiter and a small escape
helper. You should not have to touch the Run Context block; it is
auto-populated.

What you DO fill in (in vim, neovim, or any text editor):

- **Rating (1-5)**: 1 = unusable, 5 = exemplary. One score per run.
- **Decision**: one of `accepted`, `partially_accepted`, `rejected`,
  `needs_follow_up`. Use `partially_accepted` when the run produced
  some good output but the whole thing is not shippable; use
  `needs_follow_up` when the run is incomplete or requires human
  follow-up before a final decision.
- **Comments**: free text. The template's heuristics suggest noting
  if `diff_produced: false` on an `implementation` or `refactor` run
  (almost certainly a problem), and noting any test gaps.
- **Follow-up Needed**: yes or no. If yes, briefly describe the
  follow-up in Comments.
- **Evaluator**: who filled out the form (your name, handle, or
  email).
- **Evaluated At**: ISO 8601 UTC of the evaluation. The wrapper
  pre-fills this with the run's `finish_time`; replace it with the
  actual time you completed the evaluation.

To skip the sidecar for an automated batch run, set
`OPENCODEBENCH_SKIP_EVALUATION_TEMPLATE=1` in the parent shell.

If you re-run a task in the same task_dir (e.g. a follow-up run that
re-uses the same timestamped directory for any reason), the wrapper
detects the existing `evaluation.md` and appends a `## Re-run note`
section instead of overwriting your prior edits. This is why the
template substitution is one-way sed, not a full rewrite.

## End-to-end loop

The full Stage 2 workflow is:

```text
        +-------------------+
        |  decide task type |
        |  set OPENCODEBENCH|
        |  _TASK_TYPE       |
        +---------+---------+
                  |
                  v
        +-------------------+    +--------------------------+
        |  run wrapper with |    |  opencode runs the work  |
        |  -m <model>       +--->+  in <task_dir>/<repo>    |
        |  --dir <repo>     |    +--------------------------+
        +---------+---------+
                  |
                  v
        +-------------------+    +--------------------------+
        |  wrapper writes   |    |  <task_dir>/metadata.json|
        |  <task_dir>/...   |    |  + summary.md            |
        |  on finish        |    |  + git diff sidecars     |
        +---------+---------+    |  + evaluation.md         |
                  |              +--------------------------+
                  v
        +-------------------+
        |  human edits      |
        |  evaluation.md    |
        |  (rating/decision)|
        +---------+---------+
                  |
                  v
        +-------------------+
        |  benchmark row:   |
        |  metadata +       |
        |  evaluation merged|
        +-------------------+
```

The benchmark row is the unit of analysis. Each row is one run
(identified by `task_id`) plus its human evaluation. The aggregator
that consumes these rows should join on `task_id`.

## Worked example

The Card 6 validation runs are the canonical worked examples. The
full validation matrix is in
[docs/stage-2-card-6-validation.md](stage-2-card-6-validation.md);
here is one of them.

**Command (Run 1, Card 6):**

```sh
env -u OPENCODE_SERVER_PASSWORD -u OPENCODE_SERVER_USERNAME \
  OPENCODEBENCH_TASK_TYPE=validation \
  ./opencodebench-opencode --dir . -m opencode/deepseek-v4-flash-free \
  run "echo card6-r1"
```

**Task log directory produced:**

```text
.local/coding-agent-task-logs/2026/06/2026-06-09T22-21-44Z-opencode-coding-agent-benchmarks/
```

**Stage 2 fields from `metadata.json`:**

```json
{
  "model_id": "opencode/deepseek-v4-flash-free",
  "task_type": "validation",
  "task_type_status": "valid",
  "start_time": "2026-06-09T22-21-44Z",
  "finish_time": "2026-06-09T22-21-49Z",
  "duration_seconds": 5.763,
  "exit_code": 0,
  "files_changed": 0,
  "lines_added": 0,
  "lines_deleted": 0,
  "working_tree_dirty_after": true,
  "diff_produced": false,
  "opencodebench": {
    "timing": {
      "start_unix_seconds": 1781043704.056156,
      "finish_unix_seconds": 1781043709.818814,
      "duration_seconds": 5.763
    },
    "task_type": "validation",
    "diff_summary": {
      "files_changed": 0,
      "lines_added": 0,
      "lines_deleted": 0,
      "working_tree_dirty_after": true,
      "diff_produced": false,
      "is_git_repo": true
    }
  }
}
```

**Excerpt from the auto-generated `evaluation.md` Run Context block:**

```markdown
## Run Context

- **Run ID:** 2026-06-09T22-21-44Z-opencode-coding-agent-benchmarks
- **Repository:** /Users/Jo/GitHub/coding-agent-benchmarks
- **Model:** opencode/deepseek-v4-flash-free
- **Task Type:** validation
- **Start Time:** 2026-06-09T22-21-44Z
- **Finish Time:** 2026-06-09T22-21-49Z
- **Duration:** 5.075
- **Exit Code:** 0
- **Files Changed:** 0
- **Lines Added:** 0
- **Lines Deleted:** 0
- **Working Tree Dirty After:** true
- **Diff Produced:** false
```

After this run, the human would open the file in vim, scroll past
the Run Context block, and fill in:

```markdown
### Rating (1-5)

- [x] 5

### Decision

- [x] accepted

### Comments

Smoke test: wrapper captured metadata correctly, no real work
needed, model answered cleanly. Note working_tree_dirty_after is
true because .local/ exists but is .gitignore'd; this is expected
and not a defect.

### Follow-up Needed

- [x] No

### Evaluator

human

### Evaluated At

2026-06-09T22:30:00Z
```

That filled-in `evaluation.md` plus the `metadata.json` is one
benchmark row. Repeat for every tracked run.

## Worker selection and failure handling

The model-routing policy is a separate document:
[docs/current-openbench-model-routing.md](current-openbench-model-routing.md).
It governs two things:

1. **Which worker to use** for a given task. Free OpenCode models
   (`opencode/deepseek-v4-flash-free` is the current default) are
   the first attempt. Escalation goes through `openai/gpt-5.5` and
   then `minimax-coding-plan/MiniMax-M3` per the policy's escalation
   ladder.
2. **What to do when a worker call fails** with an authentication,
   quota, rate-limit, billing, or "model unavailable" error. The
   policy's `## Provider availability and token-limit handling`
   section is the source of truth. The short version: do not
   loop-retry a paid/provider model on those failure classes,
   classify the failure, ask the user if Hermes is on the same
   provider family that just failed inside OpenCode (because then
   the OpenCode failure is suspicious), and always log the failure
   in the task report with the requested model, command, error
   category, whether fallback was used, and whether the run is
   benchmark-valid for the intended model.

If a run fell back from a paid/provider model to a free OpenCode
model because the paid one failed, the run is benchmark-valid for
the *fallback* model, not the requested one. Record this in the
Comments of `evaluation.md` and consider excluding the row from any
analysis that attributes code work to the requested model.

## Kanban boards and project workflow

This project uses **one canonical Kanban board**:

- `opencodebench` — 26 done tasks as of the Stage 2 cleanup,
  covering all of Stage 1 (19) and Stage 2 (7). Title prefixes
  `[Stage 1]` and `[Stage 2]` make the original stage obvious at a
  glance. The body of each migrated task includes a provenance
  header with the original board slug, the original task id, the
  original status, the original created/completed timestamps, the
  original workspace, and the original assignee. The original
  body and any original comments follow the header verbatim.

For Stage 3 and beyond, new tasks go on `opencodebench` directly.
There is no per-stage board.

The two original per-stage boards (`opencodebench-stage-1` and
`opencodebench-stage-2-tracking`) were hard-deleted on 2026-06-10
via `hermes kanban boards rm <slug> --delete`. The audit trail
for those 26 tasks now lives in this repo: the migration map and
per-task provenance headers in
[docs/kanban-board-consolidation.md](kanban-board-consolidation.md).
New work for OpenCodeBench goes on the `opencodebench` board only.
See the consolidation doc for the explicit list of what is and
isn't preserved after the hard-delete.

### Why one board, not per-stage

Two per-stage boards worked for two stages but the costs were:

- `hermes kanban boards switch` is per-shell only and the
  `--board <slug>` flag is easy to forget on long commands.
- Cross-stage "what did Stage 1 do that Stage 2 depends on"
  lookups require inspecting two boards instead of one.
- The list output of each board was dominated by old done tasks.

A single canonical board with title prefixes for stage makes the
old work visible without forcing a second board switch. The cost is
one shared list, but that list is short (26 tasks) and grows slowly
relative to the cost of switching contexts.

## Known limitations

- **Wrapper `--dangerously-skip-permissions` ordering.** The wrapper
  currently passes user args through to opencode positionally after
  `--dir` and `-m`. opencode's CLI parser expects
  `--dangerously-skip-permissions` to come before the `run`
  subcommand, so the flag is not always in the right position. This
  is a known arg-walker limitation, not a Stage 2 schema defect.
  Card 6's Run 3 used the direct script API to work around it; that
  is documented in the validation report.
- **Card 3 and Card 4 implementations were done by Hermes directly
  rather than delegated through `opencodebench-opencode` to
  `opencode/deepseek-v4-flash-free`.** The schema and tests are
  correct, but those two commits are not benchmark-valid worker
  traces and should be excluded from any Stage 2 analysis that
  attributes code work to a model. Card 5 and Card 6 worker runs
  are benchmark-valid. Comments on Kanban cards `t_68969aad`
  (Card 3) and `t_7554ba5e` (Card 4) document this.
- **Commit category reference for the 8 commits that make up Stage
  2 plus the routing-policy update** (commit hashes in
  `git log --oneline origin/main..HEAD`):
  - **Cards 5 and 6 include benchmark-valid worker/validation
    traces.** `464cb81` (Card 5) has 3 implementation runs and 2
    review runs on disk in `.local/coding-agent-task-logs/2026/06/`;
    `c0cb726` (Card 6) indexes 4 wrapper validation runs that are
    themselves benchmark-valid.
  - **Card 7 and the routing-policy update are direct
    documentation commits, acceptable under the routing policy
    but not worker implementation traces.** `e1808d4`
    (`docs/current-openbench-model-routing.md`) and `802e077`
    (`docs/stage-2-tracking.md`) are doc-only commits by Hermes
    with no worker trace behind them. They are not "benchmark-
    valid" in the sense of carrying a worker model_id.
  - **Cards 1-4 are direct-Hermes code commits, also not
    benchmark-valid.** `03ed180`, `5d81d4d`, `795dbc9`, `f12ba19`.
    Same rationale as the Card 3 / Card 4 bullet above.
- **`task.md` content depends on the opencode build.** The wrapper
  captures whatever the opencode CLI writes there; on the current
  build, a long positional prompt is sometimes ignored and `task.md`
  shows a "No startup prompt was provided" stub even though opencode
  did receive and act on the prompt. Stage 2 does not depend on
  `task.md`; the metadata fields come from the wrapper's own
  capture, not from parsing `task.md`.

## See also

- [docs/task-capture-wrapper.md](task-capture-wrapper.md) — Stage 1
  wrapper docs (the foundation this Stage 2 doc layers on).
- [docs/current-openbench-model-routing.md](current-openbench-model-routing.md) —
  worker selection and provider-failure handling policy.
- [docs/stage-2-card-6-validation.md](stage-2-card-6-validation.md) —
  the Card 6 validation report; the source of the worked example
  above and the per-field PASS/FAIL matrix.
- [docs/reconstructing-benchmark-cases.md](reconstructing-benchmark-cases.md) —
  how to reconstruct benchmark cases from the captured metadata.
- [docs/kanban-board-consolidation.md](kanban-board-consolidation.md) —
  the Stage 1 + Stage 2 → `opencodebench` board migration record,
  with the full task-id mapping table.
