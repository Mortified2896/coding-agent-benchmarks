# Kanban Board Consolidation

This document records the Stage 2 cleanup that merged two per-stage
Kanban boards into one canonical `opencodebench` board, plus the
freezing of the old boards as historical records.

## Before

Two boards existed before this cleanup:

- `opencodebench-stage-1` — 19 done tasks (Stage 1 baseline work)
- `opencodebench-stage-2-tracking` — 7 done tasks (Stage 2 plan)

Both were 100% complete; both were used as a single workstream and
existed only because one board was created per stage at the start of
each stage. The per-stage-board pattern had two costs that prompted
the consolidation:

- `hermes kanban boards switch` is per-shell only, and the
  `--board <slug>` flag is easy to forget on long commands.
- Cross-stage "what did Stage 1 do that Stage 2 depends on" lookups
  require inspecting two boards instead of one with a frozen column.

## After

A single canonical board exists now:

- `opencodebench` — 26 done tasks, the union of Stage 1 and Stage 2.
  Title prefix `[Stage 1]` or `[Stage 2]` makes the original board
  obvious at a glance. The new-board body for each task includes a
  provenance header that records the original board slug, the
  original task id, the original status, the original created and
  completed timestamps, the original workspace, and the original
  assignee. The original body and any original comments follow
  the provenance header verbatim.

The two old boards are NOT deleted. They are left in place as
frozen historical records, with a single frozen-board marker comment
on the first task of each so future readers know where the live work
has moved.

## Migration map — Stage 1 (19 tasks)

| # | Original id | New id | Original title |
|---|------------|--------|----------------|
| 1 | `t_7ec2796a` | `t_e3b4fe30` | Card 12a: Fix --dir repo detection for opencodebench-opencode |
| 2 | `t_f2bcc599` | `t_c4b6aa8d` | Card 1: Finalize additive Stage 1 metadata schema |
| 3 | `t_8ddd52bd` | `t_90f82a67` | Card 2: Confirm explicit wrapper command name: opencodebench-opencode |
| 4 | `t_967fcb9b` | `t_22ab3670` | Card 3: Define cwd/Git-root repo detection |
| 5 | `t_869ab67b` | `t_54580f7d` | Card 4: Define upstream orchestrator env behavior |
| 6 | `t_303c40cf` | `t_74006484` | Card 5: Implement opencodebench-opencode |
| 7 | `t_46c73f00` | `t_fdbf563e` | Card 6: Add real OpenCode binary resolution and recursion prevention |
| 8 | `t_c93e600a` | `t_7e70e770` | Card 7: Add OpenCode argument passthrough |
| 9 | `t_3284053e` | `t_09190fb8` | Card 8: Validate direct tracked OpenCode run |
| 10 | `t_59386b4a` | `t_0a7529a7` | Card 9: Validate simulated Hermes-delegated OpenCode run |
| 11 | `t_f4e13246` | `t_8e825a18` | Card 10: Validate no-Git failure behavior |
| 12 | `t_e0d7d7ff` | `t_2f937eb1` | Card 11: Add privacy and security validation |
| 13 | `t_8d907a06` | `t_e6e01239` | Card 12: Update docs for Stage 1 data-tracking-only workflow |
| 14 | `t_00ad3dd9` | `t_314521fc` | Decision 1: Invalid upstream orchestrator env behavior |
| 15 | `t_acc7cf4a` | `t_93c7b68e` | Decision 2: Real OpenCode binary lookup strategy |
| 16 | `t_a12f0946` | `t_01a1b1c2` | Decision 3: Minimum Stage 1 OpenCode invocation support |
| 17 | `t_c132ac26` | `t_1d045f19` | Card 13: Existing opencode-bench.sh OpenCode capture path |
| 18 | `t_1d7c10d4` | `t_656e5c35` | Card 14: Existing generic harness metadata support |
| 19 | `t_3e4b8240` | `t_e64a60fc` | Card 15: Existing Hermes CLI/TUI harness |

## Migration map — Stage 2 (7 tasks)

| # | Original id | New id | Original title |
|---|------------|--------|----------------|
| 1 | `t_6075942f` | `t_f24ed315` | Card 7: Document Stage 2 tracking workflow |
| 2 | `t_c8edfc44` | `t_25a2ad9e` | Card 6: Validate metadata on real Hermes → OpenCode runs |
| 3 | `t_2ad08408` | `t_367b334f` | Card 5: Add manual human evaluation template |
| 4 | `t_7554ba5e` | `t_a0a2afff` | Card 4: Add diff-size and changed-files summary metadata |
| 5 | `t_68969aad` | `t_b542897f` | Card 3: Add task type metadata |
| 6 | `t_74b1eca6` | `t_b685d35a` | Card 2: Add clean timing metadata |
| 7 | `t_83e31bb6` | `t_6a94b4ae` | Card 1: Capture actual worker model from -m / --model |

## How to verify

```sh
# Confirm the canonical board has 26 done tasks
hermes kanban --board opencodebench list
hermes kanban --board opencodebench stats

# Confirm the old boards are still present but frozen (1 comment each)
hermes kanban --board opencodebench-stage-1 show t_7ec2796a
hermes kanban --board opencodebench-stage-2-tracking show t_83e31bb6

# Spot-check a migrated task's provenance header
hermes kanban --board opencodebench show t_6a94b4ae   # was t_83e31bb6
```

## Date and operator

- Date: 2026-06-10
- Operator: Hermes
- Migration script: 26 `hermes kanban create` calls + 26
  `hermes kanban complete` calls, all via `--board opencodebench`
- 0 errors; 0 retries

## Future stages

For Stage 3 and beyond, the canonical `opencodebench` board is the
only board for this project. New cards are created on it directly.
The old per-stage boards are kept in place for historical reference;
do not add new tasks to them.
