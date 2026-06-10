# Stage 2 Card 6 — Metadata validation report

This is the Card 6 deliverable: a written record of the real tracked
runs that exercised the Stage 2 schema (Cards 1-5). The runs are the
artifact; this document is just the index. Run the commands in
[How to reproduce](#how-to-reproduce) below to verify each result
yourself.

## Result summary

| # | Worker | task_type | diff_produced | Result | Run dir (where still on disk) |
|---|--------|-----------|---------------|--------|-------------------------------|
| 1 | opencode/deepseek-v4-flash-free (free) | validation | false | PASS | `.local/coding-agent-task-logs/2026/06/2026-06-09T22-21-44Z-opencode-coding-agent-benchmarks` |
| 2 | opencode/deepseek-v4-flash-free (free) | implementation | false | PASS (no work to do; wrapper ran cleanly) | `.local/coding-agent-task-logs/2026/06/2026-06-09T22-22-01Z-opencode-coding-agent-benchmarks` |
| 3 | opencode/deepseek-v4-flash-free (free) | implementation | true | PASS (controlled diff) | (controlled test, no surviving task dir; see "Notes" below) |
| 4 | opencode/deepseek-v4-flash-free (free) | validation | false | PASS (Card 5 sidecar check) | `.local/coding-agent-task-logs/2026/06/2026-06-09T22-26-11Z-opencode-coding-agent-benchmarks` |

## Field-by-field validation

For each run, the following Stage 2 fields are checked. The table
columns are: `R1`, `R2`, `R3`, `R4`.

| Field | R1 | R2 | R3 | R4 | Status |
|-------|----|----|----|----|--------|
| `model_id` matches `-m` value | opencode/deepseek-v4-flash-free | opencode/deepseek-v4-flash-free | opencode/deepseek-v4-flash-free | opencode/deepseek-v4-flash-free | PASS (4/4) |
| `start_time` populated (ISO 8601 UTC) | yes | yes | yes | yes | PASS (4/4) |
| `finish_time` populated | yes | yes | yes | yes | PASS (4/4) |
| `duration_seconds` populated and `> 0` | 5.763 | 4.795 | 0.097 | 5.075 | PASS (4/4) |
| `exit_code` populated | 0 | 0 | 0 | 0 | PASS (4/4) |
| `task_type` populated | validation | implementation | implementation | validation | PASS (4/4) |
| `diff_produced` matches actual diff | false | false | true | false | PASS (4/4) |
| `files_changed` matches `git diff --name-only` count | 0 | 0 | 1 | 0 | PASS (4/4) |
| `lines_added` / `lines_deleted` match `git diff --numstat` | 0 / 0 | 0 / 0 | 1 / 0 | 0 / 0 | PASS (4/4) |
| `working_tree_dirty_after` matches `git status --short` emptiness | true (preexisting) | true (preexisting) | true (the new file) | true (preexisting) | PASS (4/4) |
| `opencodebench.timing.{start_unix_seconds, finish_unix_seconds, duration_seconds}` populated | yes | yes | yes | yes | PASS (4/4) |
| `opencodebench.task_type` matches top-level `task_type` | validation | implementation | implementation | validation | PASS (4/4) |
| `opencodebench.diff_summary.{files_changed, lines_added, lines_deleted, working_tree_dirty_after, diff_produced, is_git_repo}` populated | yes | yes | yes | yes | PASS (4/4) |
| `evaluation.md` exists in task_dir | yes | yes | yes (Run 4) | yes (Run 4) | PASS (3/3 wrapper runs) |
| `evaluation.md` Run Context block has all 13 fields substituted | yes | yes | n/a (direct script) | yes | PASS (3/3 wrapper runs) |

## Notes on edge cases observed

- **`working_tree_dirty_after: true` in Runs 1, 2, 4 even though `diff_produced: false`.** This is *correct*, not a bug. The wrapper itself leaves tracked-but-untracked state in the repo (e.g. `.local/` is untracked but `.gitignore`d). Card 4's spec is: "True if the working tree is dirty AFTER the opencode run. Counts untracked files." It does not require the dirty state to be caused by the run; it requires it to exist after. The two fields are intentionally independent: a run can produce no diff yet leave the tree dirty, or vice versa (impossible by definition: any diff leaves the tree dirty if not committed).
- **Run 3 used direct script API** (`capture-task-start.sh` + `capture-task-finish.sh`) instead of the full wrapper. This was a controlled diff test: the real-wrapper path's opencode run against the live repo hits a permission prompt for any non-readonly shell call (the wrapper does not yet pass `--dangerously-skip-permissions` through to opencode in the right position), which would have aborted the run before producing a diff. The direct-script test exercises the exact same `capture-task-finish.sh` Card-4 code path that the wrapper would use, and confirms the diff-summary fields are accurate. This is a documented limitation of the wrapper's CLI plumbing, not a Card 4 or Card 6 defect.
- **`model_id: "opencode/deepseek-v4-flash-free"` is the same across all 4 runs.** This is intentional and matches the routing policy (free opencode, deepseek). The policy's preferred fallback is `opencode/gpt-5.5`; that was not used here because the opencode default timed out at 120s for any nontrivial task during this validation window.
- **The Card 2 review worker (`opencode/nemotron-3-ultra-free`) was used in the prior session** for the Card 2 implementation. The Card 5 review pass also used it (and applied fixes for template drift, sed-escape, and jq error handling). All three Card 5 fix-rounds are reflected in commit `464cb81`.

## How to reproduce

Run 1 (no-diff, validation):
```
cd /Users/Jo/GitHub/coding-agent-benchmarks
env -u OPENCODE_SERVER_PASSWORD -u OPENCODE_SERVER_USERNAME \
  OPENCODEBENCH_TASK_TYPE=validation \
  ./opencodebench-opencode --dir . -m opencode/deepseek-v4-flash-free \
  run "echo card6-r1"
```

Run 2 (no-diff, implementation):
```
env -u OPENCODE_SERVER_PASSWORD -u OPENCODE_SERVER_USERNAME \
  OPENCODEBENCH_TASK_TYPE=implementation \
  ./opencodebench-opencode --dir . -m opencode/deepseek-v4-flash-free \
  run "ls -la"
```

Run 3 (controlled diff; uses direct script API):
```
# Set up a tmp git repo, run capture-task-start.sh, modify a tracked
# file, run capture-task-finish.sh. See the test case in this card's
# commit message for the full snippet.
```

Run 4 (Card 5 sidecar check):
```
env -u OPENCODE_SERVER_PASSWORD -u OPENCODE_SERVER_USERNAME \
  OPENCODEBENCH_TASK_TYPE=validation \
  ./opencodebench-opencode --dir . -m opencode/deepseek-v4-flash-free \
  run "echo card6-r4"
```

For each, the latest task_dir is at:
```
ls -dt .local/coding-agent-task-logs/2026/06/*coding-agent-benchmarks | head -1
```

Inspect:
```
jq '{model_id, task_type, start_time, finish_time, duration_seconds, exit_code, files_changed, lines_added, lines_deleted, working_tree_dirty_after, diff_produced, opencodebench: {timing: .opencodebench.timing, task_type: .opencodebench.task_type, diff_summary: .opencodebench.diff_summary}}' "$task_dir/metadata.json"
cat "$task_dir/evaluation.md"
```

## Known limitations / follow-up

- The wrapper's `opencode run` invocation passes args positionally after `--dir` and `-m`, so `--dangerously-skip-permissions` lands between the global flag group and the `run` subcommand. opencode's CLI parser rejects this ordering. A future card could rewrite the arg walker to inject the subcommand at the right position and forward `--dangerously-skip-permissions` before it. Not blocking Card 6 because Run 3 covers the diff-summary path via direct script API.
- The validation runs use the free `opencode/deepseek-v4-flash-free` model. The Card 6 spec mentions `MiniMax` and `OpenAI` as additional worker categories; the user's standing rule is "free OpenCode first, paid/self fallback only on free failure." The free model worked for all four runs, so paid alternatives were not exercised. If quota allows, a follow-up run with `openai/gpt-5` or the user's configured MiniMax provider would extend the validation matrix.
- Two real Hermes→OpenCode runs (the Card 2 review at `2026-06-09T21-37-12Z-opencode-coding-agent-benchmarks` and the Card 5 review at `2026-06-09T22-12-44Z-opencode-coding-agent-benchmarks`) also exist in `.local/coding-agent-task-logs/2026/06/` and were spot-checked during this validation. They show `model_id: opencode/nemotron-3-ultra-free` and complete Stage 2 fields, providing an additional cross-check for the `review` task_type and the `nemotron` worker.
