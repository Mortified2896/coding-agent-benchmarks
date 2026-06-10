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

## Provider availability and token-limit handling

This section governs how Hermes responds when an OpenCode worker call
to an OpenAI, MiniMax, or other paid/provider model fails. It applies
when the failure is an authentication, quota, rate-limit, billing, or
"model unavailable" style error, not a content/code error from the
model itself.

- **Do not loop-retry a paid/provider model** that has just failed
  with an auth, quota, rate-limit, billing, or unavailability error.
  Repeated retries will not change the outcome and may compound the
  cost or rate-limit window.
- **First classify the failure** as best as possible. The categories:
  - **temporary provider/API failure** — transient network or upstream
    issue; one or two retries with backoff is reasonable, then fall back.
  - **plan / token / quota exhausted** — the account is out of
    capacity for the billing cycle; further calls on this provider
    will fail until the user tops up or the cycle resets.
  - **wrong / missing API key** — credentials are not configured
    correctly for this provider in OpenCode's environment.
  - **OpenCode provider configuration bug** — the failure is in
    OpenCode's plumbing, not the provider; retrying will not help.
  - **unknown** — the error message is ambiguous; do not guess, ask
    the user.
- **Suspicious same-provider failure.** If the current Hermes
  orchestrator is itself running on the same provider family that
  failed inside OpenCode, treat the OpenCode failure as suspicious
  rather than expected. Assume the provider is probably available
  (because Hermes is using it) and surface the failure to the user
  before silently switching models.
  - Example: Hermes is running on MiniMax M3, but OpenCode cannot
    reach a MiniMax model. Ask the user before falling back.
  - Example: Hermes is running on an OpenAI model, but OpenCode
    cannot reach an OpenAI model. Ask the user before falling back.
- **Token/quota exhaustion handling.** If the likely cause is
  plan/token/quota exhaustion:
  - finish the current safe fallback path if one is in progress
    (do not abandon a half-done run mid-edit);
  - then ask the user before trying that provider again;
  - then prefer waiting (a few hours is usually enough) or waiting
    for explicit user confirmation that the plan/tokens are
    available again, before the next attempt.
- **Always log provider failures** in the task report. The minimum
  fields are:
  - requested model (e.g. `openai/gpt-5.5`)
  - command used (the actual `opencodebench-opencode …` invocation,
    redacted of any secrets)
  - error category (one of the five above)
  - whether fallback was used, and to which model
  - whether the resulting run is benchmark-valid for the intended
    model (it is **not** benchmark-valid if the requested model did
    not actually answer; the trace represents the fallback model, not
    the requested one)
- **Free OpenCode first.** Free OpenCode models remain the default
  first attempt unless the task explicitly requires a paid/provider
  model or the user has approved escalation. A provider failure on a
  free OpenCode model is itself useful information: log it, but a
  one-retry-then-fallback to another free OpenCode model is fine
  without asking the user, because no paid capacity was consumed.

## Operating Rules

- For coding tasks in this repo, Hermes should normally delegate implementation through `opencodebench-opencode`.
- Use `--dir <target-repo>` for tracked OpenCode work.
- Follow this routing policy unless there is a clear reason to deviate.
- If another model or reasoning configuration appears better suited for a task, suggest it first and ask for user approval before deviating.
- The actual worker model used is captured automatically in `metadata.json` as `model_id` and `opencodebench.timing.*` (Stage 2 Card 1). No manual recording needed.
- Treat the worker's report as the source of truth for what model actually answered. A "successful" run on a different model than `-m` requested is a fallback event, not a clean run.
