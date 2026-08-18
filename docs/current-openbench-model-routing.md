# OpenCode Benchmark Routing (Legacy / Explicit Runs Only)

> **Status:** legacy benchmark-specific guidance. This file is **not** the repository's coding implementation policy and must not be used to auto-delegate normal repository work to OpenCode.

## Current rule

- For normal implementation, bug fixes, refactors, tests, documentation, and repository maintenance, the active coding harness should work directly.
- Do **not** delegate to OpenCode or `opencodebench-opencode` by default.
- Use OpenCode/OpenCodeBench only when the user explicitly asks for an OpenCode/OpenCodeBench benchmark, tracked capture, model comparison, replay, or another experiment where OpenCode itself is part of what is being measured.
- Merely working inside this repository does not imply that an OpenCode worker should be used.
- Historical documents that refer to this file as the authoritative worker-routing policy describe the old benchmark workflow and must not be interpreted as current implementation instructions.

## Why this file remains

Older benchmark stages and validation records link to this path. Keeping a short compatibility note avoids breaking those references while preventing the historical Hermes-to-OpenCode workflow from being mistaken for the current development workflow.

The previous model-routing policy is preserved in Git history for reproducibility of historical benchmark work.
