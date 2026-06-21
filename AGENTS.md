# Project Agent Instructions

This file is loaded by AI coding assistants (and human contributors) when working in this repository.

## Coding Worker Routing
This repository supports both Pi direct work and OpenCode/OpenCodeBench workflows.
When working in Pi, use Pi directly by default for coding and repository tasks. Do not delegate to OpenCode by default. Before using OpenCode from a Pi workflow, ask the user first and explain why OpenCode would be advantageous over direct Pi work for the specific task.
OpenCode may be advantageous for larger refactors, test-heavy coding loops, explicit OpenCodeBench comparison runs, or cases where the user explicitly requests OpenCode. Even in those cases, Pi should ask first before delegating unless the user has already explicitly requested OpenCode for that task.
When working through Hermes orchestration or when running benchmarked coding tasks, OpenCode remains the preferred implementation worker via `opencodebench-opencode`; follow `docs/current-openbench-model-routing.md`.
