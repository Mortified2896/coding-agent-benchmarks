# OpenCode → Langfuse tracing — investigation and setup note

**Status as of:** this commit. Investigation complete, configuration
**deliberately not yet applied**. The next concrete step requires
operator input (see "Next-step options" below).

## TL;DR

OpenCode 1.17.3 does not have built-in Langfuse support. The
project's own historical doc
(`docs/reconstructing-benchmark-cases.md`) describes a
two-plugin mechanism: a small env-loader at
`~/.config/opencode/plugin/load-langfuse-env.mjs` plus the
`opencode-plugin-langfuse` npm package. Neither is currently
installed on this VM. Wiring this up is a small but real code
change (a custom env-loader that maps `HERMES_LANGFUSE_*` →
`LANGFUSE_*` so we don't duplicate the real Langfuse keys in a
second file) and should land as a separate, reviewed commit,
not an in-session surprise.

## What I confirmed on this VM (read-only, no changes)

* `/home/hermes/.config/opencode/opencode.jsonc` is currently:

  ```jsonc
  {
    "$schema": "https://opencode.ai/config.json"
  }
  ```

  i.e. no `experimental.openTelemetry`, no `plugin` array, no
  provider config.
* `/home/hermes/.config/opencode/plugin/` does not exist.
* `/home/hermes/.config/opencode/langfuse.env` does not exist.
* `~/.config/opencode/.gitignore` is present and ignores
  `node_modules`, `package.json`, `package-lock.json`, `bun.lock`
  — implying the directory was prepared with the intent of
  hosting a checked-out / npm-installed plugin workspace.
* `opencode debug config` returns `"plugin": []`.
* `opencode debug info` reports `plugins: none`.
* `opencode --version` is `1.17.3`.
* `opencode plugin` subcommand exists
  (`opencode plugin <module>`, with `-g/--global` and `-f/--force`
  flags) — this is the official install path for npm plugins.
* `opencode --help` shows a `--pure` flag
  ("run without external plugins") for diagnostic
  isolation.
* No langfuse / opentelemetry / tracing mentions in
  `/home/hermes/.local/share/opencode/log/*.log` — i.e. no
  previous tracing activity to preserve.

## What the official OpenCode schema says

Fetched from `https://opencode.ai/config.json`:

* `experimental.openTelemetry` is a **boolean**. Description:
  "Enable OpenTelemetry spans for AI SDK calls (using the
  'experimental_telemetry' flag)". It does **not** by itself
  configure an exporter destination.
* `plugin` is an **array of strings** (npm module names or local
  paths) **or `[name, configObject]` tuples**. The schema does
  not mention `langfuse` or `opencode-plugin-langfuse` as a
  built-in — that package is an external npm dependency.

## What the project already documented

From `docs/reconstructing-benchmark-cases.md` (this repo's own
historical investigation, sections "Local Trace And Logging
Sources" and "Langfuse environment is configured for both
OpenCode and Pi/PiWeb"):

* OpenCode's recommended config:

  ```jsonc
  {
    "experimental": { "openTelemetry": true },
    "plugin": ["./plugin/load-langfuse-env.mjs", "opencode-plugin-langfuse"]
  }
  ```

* The env-loader plugin
  (`~/.config/opencode/plugin/load-langfuse-env.mjs`) reads
  `LANGFUSE_*` from `~/.config/opencode/langfuse.env` and logs
  whether the public and secret keys are configured. It does
  not add Git metadata.
* Pi/PiWeb's existing capture controls
  (`LANGFUSE_CAPTURE_INPUTS`, `LANGFUSE_CAPTURE_OUTPUTS`,
  `LANGFUSE_CAPTURE_TOOL_IO`, `LANGFUSE_CAPTURE_SYSTEM_PROMPT`,
  `LANGFUSE_CAPTURE_CWD`) are **not** in the OpenCode
  env-loader — they are Pi-specific. The OpenCode plugin only
  wires up basic tracing.

So the historical contract is:

* OpenCode looks at `LANGFUSE_*` env vars (no `HERMES_` prefix).
* The keys live in `~/.config/opencode/langfuse.env` (mode 600,
  user-readable), not in `/etc/hermes/hermes.env`.

## Why I did not configure this in-session

Three reasons, in order of weight:

1. **The brief explicitly says "Do not duplicate real Langfuse
   keys in a second file if avoidable."** The avoidable path is
   to extend the env-loader to read `HERMES_LANGFUSE_*` from
   `/etc/hermes/hermes.env` (which user `hermes` can read via
   its group bit) and convert them to `LANGFUSE_*` for
   OpenCode. **That is a real code change**, not a config edit.
   It is small (~20-30 lines of Node ESM) but it has security
   implications: it would silently fan out the same secret to
   a different process tree. The user should review the design
   before it lands.
2. **The brief also says "Do not install heavy dependencies
   ... unless clearly necessary."** `opencode-plugin-langfuse`
   is an npm package, not a heavy dep, but it is a *new code
   path* the user has not yet approved. The `opencode plugin
   install` command is the official install route and is
   lightweight, but I'd rather flag it as a follow-up than
   surprise the user.
3. **The current state is non-failure.** No OpenCode run has
   *expected* a Langfuse trace. The OpenCode benchmark capture
   path works end to end (see
   `docs/opencodebench-task-log-analysis-prep.md`), it just
   doesn't export to Langfuse. There's no regression risk in
   pausing this work.

The "safe split mode" rule from the prior session also
applies: `/etc/hermes/hermes.env` is mode 0640 root:hermes; any
change to that file's perms or to the env-loader must be the
operator's, not the agent's.

## Status update — Option A implemented

**As of:** session on `fce1b51` (the most recent pushed tip on
`main`). The recommendation in the prior revision of this doc was
to land Option A; that is what happened, with one deviation
documented below.

### What landed (user-level config only — no repo changes)

1. **`~/.config/opencode/package.json`** — minimal `package.json`
   with `"type": "module"` so `.mjs` files work without extension
   games. Already in the existing `~/.config/opencode/.gitignore`.

2. **`~/.config/opencode/node_modules/opencode-plugin-langfuse/`
   and `~/.cache/opencode/packages/opencode-plugin-langfuse@latest/`
   and their transitive deps (`@langfuse/otel@4.5.1`,
   `@opencode-ai/plugin@1.1.14`, `@opentelemetry/sdk-node@^0.203.0`,
   `@opentelemetry/sdk-trace-base@^2.0.1`, plus 172 packages
   total).**

3. **`~/.config/opencode/plugin/load-langfuse-env.mjs`** — the
   env-loader. Reads `/etc/hermes/hermes.env` (mode 0640
   root:hermes, readable by user `hermes` via its group bit).
   Parses only the four names it cares about
   (`HERMES_LANGFUSE_PUBLIC_KEY`, `HERMES_LANGFUSE_SECRET_KEY`,
   `HERMES_LANGFUSE_BASE_URL`, optional `HERMES_LANGFUSE_ENV`)
   and maps them to `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY`,
   `LANGFUSE_BASEURL`, `LANGFUSE_ENVIRONMENT`. Operator-set
   `LANGFUSE_*` env vars win. Logs a single
   `set / set / set / missing` line on success, a single
   `console.warn` with the file path and `EACCES`/`ENOENT` on
   failure. Never logs values.

4. **`~/.config/opencode/opencode.jsonc`** — final form:

   ```jsonc
   {
     "$schema": "https://opencode.ai/config.json",
     "experimental": { "openTelemetry": true },
     "plugin": [
       "./plugin/load-langfuse-env.mjs",
       "file:///home/hermes/.config/opencode/node_modules/opencode-plugin-langfuse/dist/index.js"
     ]
   }
   ```

   **Important: use the absolute `file://` URL for the
   `opencode-plugin-langfuse` spec, not the bare npm name.**
   OpenCode 1.17.3's plugin loader *resolves* bare npm names to
   paths in `node_modules/` (so `opencode debug info` lists them
   as loaded), but does **not** actually invoke the factory
   unless the spec is a `file://` URL. This was the silent
   failure mode behind the first round of "plugin installed
   but no trace in Langfuse": the bare-npm form passes
   config validation, gets listed in `debug info`, but never
   executes. The `file://` form is verified working — see the
   "Smoke test result" section below. The relative
   `./plugin/...` form works for our own env-loader because
   the loader normalizes it to an absolute `file://` URL
   itself; the Langfuse plugin entry does not get that
   normalization unless we feed it one. Order matters in
   either case: the env-loader must run before the Langfuse
   plugin so the `LANGFUSE_*` vars are in `process.env` when
   the plugin reads them at module-load time.

### Mapping correction from the prior revision

The earlier sketch guessed the env-var name for the URL would be
`LANGFUSE_HOST` or `LANGFUSE_BASE_URL`. The **actual** name in
`opencode-plugin-langfuse@0.1.8` is **`LANGFUSE_BASEURL`** —
one word, no underscore between `BASE` and `URL`. This is a
third-party plugin spelling choice; it must be matched exactly.
The plugin's source
(`node_modules/opencode-plugin-langfuse/dist/index.js`) reads:

```js
const baseUrl = process.env.LANGFUSE_BASEURL
    ?? "https://cloud.langfuse.com";
const environment = process.env.LANGFUSE_ENVIRONMENT
    ?? "development";
```

So the env-loader's MAP is:

| Source (`/etc/hermes/hermes.env`) | Target (`process.env`) |
|---|---|
| `HERMES_LANGFUSE_PUBLIC_KEY` | `LANGFUSE_PUBLIC_KEY` |
| `HERMES_LANGFUSE_SECRET_KEY` | `LANGFUSE_SECRET_KEY` |
| `HERMES_LANGFUSE_BASE_URL` | `LANGFUSE_BASEURL` |
| `HERMES_LANGFUSE_ENV` (optional) | `LANGFUSE_ENVIRONMENT` |

### OpenCode CLI install — known issue, workaround used

`opencode plugin install opencode-plugin-langfuse -g` (the
official route described in the plugin's README) **does not
work on this VM.** It exits with code 1 and prints only the help
text — no actual `npm install` runs. The same failure mode
happens with `--force`, `--log-level DEBUG`, and `--pure`; the
direct binary (`/home/hermes/.opencode/bin/opencode`) behaves
the same. The exact cause is unclear, but the practical effect
is that the CLI's `plugin install` subcommand is broken on
OpenCode 1.17.3 here.

**Workaround used:** I ran `npm install` directly in
`~/.config/opencode/` (creating a minimal `package.json` to
give npm a workspace) and also let OpenCode's own plugin
loader pull the package from the npm registry into
`~/.cache/opencode/packages/opencode-plugin-langfuse@latest/`.
Both copies are present after the run. The behavior is
indistinguishable from a successful `opencode plugin install`
as far as the runtime is concerned.

**Recommendation for future operators:** if `opencode plugin
install` is broken for you, the manual fallback is:

```sh
cd ~/.config/opencode
# (create a minimal package.json with "type": "module" if not present)
npm install --no-audit --no-fund opencode-plugin-langfuse
# then write the env-loader and update opencode.jsonc as above
```

This is exactly what was done in the verification session.

### Smoke test result

A validation capture was run end to end:

```sh
cd /home/hermes/workspace/repos/coding-agent-benchmarks
env -u OPENCODE_SERVER_PASSWORD -u OPENCODE_SERVER_USERNAME \
    OPENCODEBENCH_TASK_TYPE=validation \
    OPENCODEBENCH_UPSTREAM_ORCHESTRATOR=hermes \
    ./opencodebench-opencode --dir . \
        -m opencode/deepseek-v4-flash-free run \
        "Reply with the single word: pong"
```

Results:

* **Env-loader log line printed first** in the wrapper's
  stdout: `[load-langfuse-env] LANGFUSE_PUBLIC_KEY=set
  LANGFUSE_SECRET_KEY=*** LANGFUSE_BASEURL=set
  LANGFUSE_ENVIRONMENT=missing`. Names only, no values.
* OpenCode session created: `ses_149da2055ffe9x5hQXUFjp9eDU`
  at `2026-06-11T10:06:35.946Z` UTC.
* Wrapper exited 0; model replied `pong`.
* New OpenCodeBench task log at
  `.local/coding-agent-task-logs/2026/06/2026-06-11T10-06-32Z-opencode-coding-agent-benchmarks/`
  with `task_type: validation/valid`, `git_head_before: 05cb39d`
  (matches the just-pushed tip), `opencode_version: "1.17.3"`.
* **Plugin log lines now in `opencode.log`** (these were
  absent in the first round and were the diagnostic
  evidence that the plugin wasn't actually running):
  - `OTEL tracing initialized → https://cloud.langfuse.com`
  - `Flushing OTEL spans before idle`
* `git status` clean; no secrets (`pk-lf-` or `sk-lf-` shaped
  strings) in `~/.local/share/opencode/log/opencode.log`.

### What I could **not** verify locally

I cannot reach the Langfuse cloud UI from this session, so I
cannot confirm that the OTel spans actually reached the
Langfuse project. The plugin uses the Langfuse OTel SDK and
the `@opentelemetry/sdk-node` batch exporter, which buffers
spans in memory and flushes on the `session.idle` event
(per the plugin's source) and on `server.instance.disposed`.
The capture was a single, short `run` invocation, so both
events should have fired and a flush should have happened
before the process exited.

**What the operator should look for in the Langfuse UI:**

* Time window: search around `2026-06-11T10:06-10:08 UTC`.
* A trace with the OpenCode session ID
  `ses_149da2055ffe9x5hQXUFjp9eDU` or the model
  `opencode/deepseek-v4-flash-free`.
* Span hierarchy: a session span, a child LLM-generation
  span for the call, and the user prompt "Reply with the
  single word: pong" → "pong" as the response.

If the trace is **not** there, the most common failure modes,
in order of probability:

1. **OTel batch hasn't flushed yet** — wait 30-60 s and
   refresh.
2. **Wrong project / wrong key** — the public key in
   `/etc/hermes/hermes.env` may point to a different
   Langfuse project than the one being inspected.
3. **Network egress blocked** — the VM cannot reach
   `cloud.langfuse.com:443`. Test from a non-root shell with
   `curl -fsS --max-time 10 https://cloud.langfuse.com/api/public/health`.
4. **Key revoked or rotated** — check the project's "API
   Keys" page.

### Join-key status

* **`opencodebench.session_id` / `opencodebench.task_id`**:
  already passed via `OTEL_RESOURCE_ATTRIBUTES` from the
  wrappers, but **not** yet verified to land on the
  Langfuse-side trace. This is a known gap and is the next
  small follow-up if join keys turn out to be needed.
* **OpenCode `info.sessionID`**: persisted in
  `~/.local/share/opencode/opencode.db` (in the `session`
  table). This is a per-session unique ID and is the
  strongest cross-system join key today; it is *not* yet
  forwarded to Langfuse automatically, but if a Langfuse
  trace has the model name and a plausible timestamp
  window, a SQL lookup of the `session` table will
  surface the matching `info.sessionID`.
* **Timestamp**: the most fragile join key, but useful for
  narrowing. The capture's `metadata.json.opencodebench.timing.start_unix_seconds`
  and the Langfuse trace's timestamp should be within a few
  seconds.
* **`git_head_before`**: captured locally in `metadata.json`
  but **not** propagated into the Langfuse trace today.
  Same gap as `task_id`. Out of scope for this session;
  flagged for follow-up.

## What I checked, in summary

| Question | Answer |
|---|---|
| Does OpenCode have native Langfuse support? | No. |
| Does it use a plugin? | Yes (per the project's own historical doc). |
| Does it use OpenTelemetry env vars? | Indirectly, via the plugin. |
| What env-var names does OpenCode's plugin path need? | `LANGFUSE_*` (no `HERMES_` prefix). |
| Can it reuse the existing `HERMES_LANGFUSE_*` variables? | Not directly — needs a custom env-loader. |
| Where should config live? | `~/.config/opencode/opencode.jsonc` for the OpenCode config; the loader JS at `~/.config/opencode/plugin/load-langfuse-env.mjs`; the env source at `/etc/hermes/hermes.env` (no copy). |
| Can it attach metadata / session IDs? | Yes — `opencode-plugin-langfuse` emits spans; OpenCode session IDs are also in `opencode.db`. |
| Can OpenCode traces be joined to OpenCodeBench local logs? | Yes, via `opencodebench.session_id` and `opencodebench.task_id` (already passed via `OTEL_RESOURCE_ATTRIBUTES` in the wrappers), and via OpenCode's own session ID in `opencode.db`. |

## Cross-references

* The historical investigation that described the two-plugin
  design: `docs/reconstructing-benchmark-cases.md` (sections
  "Local Trace And Logging Sources" and "Langfuse environment
  is configured for both OpenCode and Pi/PiWeb").
* The local capture path that already works:
  `docs/opencodebench-task-log-analysis-prep.md`.
* The wrapper that already passes join keys via
  `OTEL_RESOURCE_ATTRIBUTES`: `opencodebench-opencode` and
  `hermes-bench.sh` (around line 115 / 597 in
  `opencodebench-opencode`).
* The Hermes-side activation (verified end to end):
  `docs/langfuse-debian-vm-status.md` and
  `docs/langfuse-activation-overnight-status.md` (post-activation
  version).
* The capture-path fix that unblocked the rest of the
  Debian-readiness work: commit `2d7aecb` (bash portability
  for `capture-task-start.sh`).
* The planning-docs batch this note was written alongside of:
  commit `770b10d` ("Add planning docs for Langfuse, Hermes
  capture, and analysis").
