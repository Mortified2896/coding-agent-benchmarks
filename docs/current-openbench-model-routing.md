# Current OpenCodeBench Model Routing

This is the current temporary model-routing policy for OpenCodeBench implementation work.

It is based on the currently visible free/OpenCode-accessible models available through the local OpenCode installation. It should be updated after we collect real traces from actual OpenCodeBench runs.

This document is not claiming these models are objectively best. Treat this as a working routing policy, not a benchmark conclusion.

## Current free/OpenCode-accessible models

- `opencode/big-pickle`
- `opencode/deepseek-v4-flash-free`
- `opencode/mimo-v2.5-free`
- `opencode/nemotron-3-ultra-free`

## Temporary routing policy

### Default implementation model

- `opencode/deepseek-v4-flash-free`

Use for shell/script implementation, wrapper code, debugging, validation fixes, argument passthrough, and exit-code handling.

### Planning/review/security/privacy/schema model

- `opencode/nemotron-3-ultra-free`

Use for metadata schema decisions, privacy/logging review, repo-wide design checks, and final review before commit.

### Docs/cleanup/simple-task model

- `opencode/mimo-v2.5-free`

Use for README/docs cleanup, small refactors, simple test scaffolding, and summarizing validation output.

### Experimental/fallback model

- `opencode/big-pickle`

Use only for low-risk sanity checks or fallback until real traces are available.

## Rules

- Do not switch models mid-task unless there is a clear reason.
- Use DeepSeek for the main implementation patch.
- Use Nemotron for review before committing privacy/logging/metadata changes.
- Use MiMo only for low-risk docs/cleanup.
- Record which model was used in the implementation summary if practical.
- Treat this as a routing policy, not a benchmark conclusion.
