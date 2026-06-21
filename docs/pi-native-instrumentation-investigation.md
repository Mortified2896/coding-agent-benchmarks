# Pi-native instrumentation investigation

Date: 2026-06-21
Run: `pi-native-instrumentation-investigation-20260621-1854`

## Scope and safety boundaries

This was a documentation-first investigation into whether Pi has native mechanisms that can replace or improve the current shell-based `pi-task` / `ptask` run-capture launcher.

No Pi core files, provider configuration, secret/env files, shell configuration, or third-party installs were changed. The investigation avoided printing secrets, env values, DB URLs, raw prompts, completions, transcripts, tool payloads, raw DB rows, archive data, and full diffs.

## Inspected

- CLI surface:
  - `which pi`
  - `pi --help`
  - `pi --version`
  - `pi list`
- Local Pi resource/config locations, by file listing only where sensitive content might exist:
  - `~/.pi`
  - repo-local `.pi` paths
  - `/home/hermes/workspace/repos/pi-customizations`
  - `/home/hermes/workspace/repos/pi-customizations/.pi/prompts/analyze.md`
  - `/home/hermes/workspace/repos/pi-customizations/.pi/prompts/save-analysis.md`
- Local Pi docs bundled with the installed package:
  - `README.md`
  - `docs/extensions.md`
  - `docs/prompt-templates.md`
  - related references surfaced by local search, especially security, packages, sessions, and containerization docs
- Installed Pi packages, via `pi list` and public README/package metadata only:
  - `pi-langfuse`
  - `@ayulab/pi-rewind`
  - `@tintinweb/pi-subagents`
  - `pi-undo-redo`

Local documentation was sufficient; no third-party code was installed.

## Findings

### Native extensions/plugins/hooks exist

Pi has a native TypeScript extension system. Extensions can be loaded from global or project-local locations, explicit CLI flags, settings, or Pi packages.

Relevant supported mechanisms:

- Global extensions: `~/.pi/agent/extensions/*.ts` or `~/.pi/agent/extensions/*/index.ts`
- Project extensions: `.pi/extensions/*.ts` or `.pi/extensions/*/index.ts`, loaded only after project trust
- Explicit extension loading: `pi -e ./extension.ts`
- Extension packages: `pi install <source>` and package manifests
- Extension hot reload via `/reload`
- Custom slash commands via `pi.registerCommand()`
- Custom tools via `pi.registerTool()`
- Prompt/context injection via `before_agent_start`
- Input interception/rewriting via `input`
- Session lifecycle events, including `session_start`, `session_before_switch`, `session_before_fork`, `session_before_compact`, `session_compact`, `session_tree`, and `session_shutdown`
- Agent/turn/message/provider/tool lifecycle events, including `agent_start`, `agent_end`, `turn_start`, `turn_end`, `message_start`, `message_update`, `message_end`, `before_provider_request`, `after_provider_response`, `tool_call`, and `tool_result`
- Persistent extension state via `pi.appendEntry()`

This is strong enough to implement native metadata capture later without modifying Pi core.

### Custom slash commands/prompts exist

Pi supports prompt templates that expand from slash commands. Files in `~/.pi/agent/prompts/*.md`, project `.pi/prompts/*.md`, package prompt directories, settings paths, or `--prompt-template` paths become `/name` commands.

Current custom prompt setup in `/home/hermes/workspace/repos/pi-customizations/.pi/prompts/` fits this model. These prompts can help standardize manual analysis or save-analysis workflows, but prompt templates alone cannot guarantee automatic finish capture because they expand into user-visible instructions rather than running lifecycle callbacks.

### Existing third-party extension

`pi-langfuse` is already installed. Its README describes a Pi extension that creates Langfuse traces per user prompt, groups by Pi session, captures model/tool observations, and exposes privacy controls. This overlaps with LLM/tool observability and Pi/Langfuse session linkage.

It does **not** by itself replace `ptask` because the current requirement is a metadata-only local run envelope with a stable `run_id`, Git before/after state, task status, safe warehouse links, and preservation of raw Pi access. `pi-langfuse` is useful as an integration point to link safe Langfuse session/trace IDs, but it is not the run-capture source of truth.

No installed package was found that directly solves the current `ptask` run-envelope use case.

## Option comparison

| Option | Automatic start capture | Automatic finish capture | `run_id` injection | Pi/Langfuse/session link potential | Privacy risk | Complexity | Raw Pi access |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Current `ptask` / `pi-task` shell launcher | Yes, before Pi starts | Via explicit `finish`; not guaranteed on abnormal exit | Yes, generated prompt file | Manual/safe links now; can improve | Low if metadata-only boundaries hold | Low; already working | Preserved: raw `pi` and `pi-task raw` |
| Prompt template slash command | No durable callback; expands instructions | No durable callback | Possible in text only | Manual only | Low-to-medium; prompt text can leak if mishandled | Low | Preserved |
| Pi native extension | Yes via `session_start`, `input`, or `before_agent_start` | Best available via `agent_end` and `session_shutdown`; abnormal process death still needs fallback | Yes via `before_agent_start` message/system-prompt injection or custom session entry | Strong: extension sees session manager and model/tool events; can coordinate with `pi-langfuse` metadata if exposed safely | Medium-to-high unless carefully metadata-only; extensions run with full user permissions and can see sensitive context | Medium | Preserved if opt-in via global/project extension or explicit `-e`; can disable with `--no-extensions` |
| Pi lifecycle hook only | Yes, if packaged as extension event handlers | Partial: graceful lifecycle events only | Yes | Strong | Medium | Medium | Preserved |
| Control Room/Hermes orchestration later | Yes | Yes, potentially stronger outside Pi process | Yes | Strongest cross-system linking | Depends on design; can enforce metadata-only centrally | High | Preserved if Pi remains unwrapped option |

## Recommendation now

Keep `ptask` / `pi-task` as the default serious-task entrypoint for now. It is already working, creates the run before Pi starts, injects the `run_id` into the initial task context, keeps generated prompt files outside git, centralizes metadata-only warehouse writes, and preserves raw Pi access.

Do **not** immediately replace it with a Pi extension. The native extension path is real and promising, but it requires careful privacy design because extension hooks can observe prompts, context, tool payloads, and provider payloads. A rushed implementation could accidentally capture the raw data this project explicitly avoids storing or printing.

## Fallback path

If native extension development is delayed or proves risky, continue using the shell launcher and improve it incrementally:

1. Keep `ptask` as the stable entrypoint.
2. Add safer explicit link commands for known safe Pi/Langfuse/session IDs.
3. Add optional post-run checks that only record metadata.
4. Leave raw `pi` untouched.

## Pi-native path to build later

Build a small, local, opt-in Pi extension only after the current launcher has several real captured runs and the metadata schema has stabilized.

Exact next implementation recommendation:

1. Prototype a local extension in a non-auto-loaded path and run it only with `pi -e <path>`.
2. Make it metadata-only by construction:
   - generate or accept a `run_id`;
   - call existing repo scripts for `start`, `link`, and `finish` rather than writing database code in the extension;
   - never log or persist event prompt text, message content, tool args/results, provider payloads, transcripts, env values, or DB URLs;
   - inject only a short safe run envelope into context, such as `run_id`, project, task type, and privacy rules;
   - finish on `agent_end` for completed prompts and on `session_shutdown` for graceful exits where possible;
   - keep abnormal-exit recovery in the existing active-state CLI.
3. Expose a custom command such as `/run-capture-status` or `/run-capture-finish`, not a broad data-dumping command.
4. Test in a disposable session with `--no-extensions -e <local-extension>` or equivalent explicit loading.
5. Only after privacy review, consider project-local `.pi/extensions/` or a private package.

## What not to build yet

- Do not modify Pi core.
- Do not modify provider config or secrets/env files.
- Do not install or depend on new third-party packages.
- Do not create a broad transcript/tool-payload exporter.
- Do not make a global auto-loaded extension until the local prototype is privacy-reviewed.
- Do not replace raw `pi` or remove `pi-task raw`.
- Do not rely on prompt templates alone for durable lifecycle capture.

## Verdict

Pi has the native extension, command, prompt-template, and lifecycle mechanisms needed for a cleaner future implementation. The recommended path is to keep the current shell launcher now and later prototype a metadata-only Pi extension as a thin wrapper around existing capture scripts.

Final verdict: **PI NATIVE INSTRUMENTATION PATH DECIDED**
