# Current OpenCode Model Routing Policy

This is the current working model-routing policy for Hermes delegating coding work to OpenCode in this project.

It is not a benchmark conclusion. It should be updated after enough real OpenCodeBench traces have been collected.

Hermes main-brain/orchestrator model selection is intentionally not covered here. The user chooses the Hermes model manually. This file only covers which worker model Hermes should ask OpenCode to use.

## Default Worker

- `opencode/deepseek-v4-flash-free`
- Use for:
  - routine implementation
  - bug fixes
  - wrapper changes
  - shell/script work
  - validation fixes
  - small refactors

## First Escalation

- `openai/gpt-5.5`
- Use when:
  - DeepSeek fails or confidence is low
  - requirements are ambiguous
  - code quality is questionable
  - implementation spans multiple files
  - higher confidence is desired

## Second Escalation

- `minimax-coding-plan/MiniMax-M3`
- Use when:
  - GPT-5.5 did not resolve the issue
  - an independent reasoning engine is valuable
  - architecture or debugging benefits from a second opinion
  - recovering interrupted or partially completed work
  - comparing alternative implementation approaches

## Final Escalation

- `openai/gpt-5.5`
- Use with a higher reasoning setting if supported by the current OpenCode/OpenAI integration.
- Use when:
  - architecture decisions are involved
  - debugging is difficult or prolonged
  - security/privacy-sensitive code is affected
  - tracking infrastructure is being modified
  - failure would be expensive

## Supporting Models

- `opencode/mimo-v2.5-free`
  - diagnostics
  - summaries
  - validation-output condensation
  - docs cleanup

- `opencode/nemotron-3-ultra-free`
  - privacy review
  - metadata review
  - schema review
  - pre-commit review

- `opencode/north-mini-code-free`
  - small isolated tasks
  - secondary implementation attempts
  - quick code checks

- `opencode/big-pickle`
  - experimental fallback
  - low-risk investigations

## Operating Rules

- For coding tasks in this repo, Hermes should normally delegate implementation through `opencodebench-opencode`.
- Use `--dir <target-repo>` for tracked OpenCode work.
- Follow this routing policy unless there is a clear reason to deviate.
- If another model or reasoning configuration appears better suited for a task, suggest it first and ask for user approval before deviating.
- Record the actual worker model used in task reports until OpenCodeBench captures the model automatically in metadata.
