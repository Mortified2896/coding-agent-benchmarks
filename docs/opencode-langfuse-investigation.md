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

## Next-step options (operator picks)

### Option A — Single source of truth, custom env-loader (recommended)

Extend the project's documented env-loader
(`~/.config/opencode/plugin/load-langfuse-env.mjs`) so it reads
`HERMES_LANGFUSE_*` from `/etc/hermes/hermes.env` and exports
them as `LANGFUSE_*` to the OpenCode process environment. The
keys stay in one place. The custom env-loader is the only new
code, and it lives at a well-known path. Then update
`opencode.jsonc` to enable `experimental.openTelemetry` and
register the loader.

Approximate shape of the env-loader (sketch only; **not yet
written**):

```js
// ~/.config/opencode/plugin/load-langfuse-env.mjs
//
// Reads HERMES_LANGFUSE_PUBLIC_KEY / _SECRET_KEY / _BASE_URL
// from /etc/hermes/hermes.env and re-exports them as the
// LANGFUSE_* names the opencode-plugin-langfuse expects.
// Does not log values. Does not need write access to the env
// file.
import { readFileSync } from "node:fs";

const SOURCE = "/etc/hermes/hermes.env";
const MAP = {
  HERMES_LANGFUSE_PUBLIC_KEY: "LANGFUSE_PUBLIC_KEY",
  HERMES_LANGFUSE_SECRET_KEY: "LANGFUSE_SECRET_KEY",
  HERMES_LANGFUSE_BASE_URL:   "LANGFUSE_HOST", // or _BASE_URL, plugin-specific
};

try {
  const body = readFileSync(SOURCE, "utf8");
  for (const line of body.split("\n")) {
    const m = line.match(/^([A-Z_][A-Z0-9_]*)=(.*)$/);
    if (!m) continue;
    const [, fromName, value] = m;
    const toName = MAP[fromName];
    if (toName && !(toName in process.env)) {
      process.env[toName] = value.trim();
    }
  }
  const have = (k) => (process.env[k] ? "set" : "missing");
  console.log(
    `[load-langfuse-env] ${have("LANGFUSE_PUBLIC_KEY")} / ` +
    `${have("LANGFUSE_SECRET_KEY")} / ${have("LANGFUSE_HOST")}`,
  );
} catch (e) {
  console.error(`[load-langfuse-env] could not read ${SOURCE}: ${e.message}`);
}
```

`opencode.jsonc` then becomes:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "experimental": { "openTelemetry": true },
  "plugin": ["./plugin/load-langfuse-env.mjs", "opencode-plugin-langfuse"]
}
```

…with `opencode-plugin-langfuse` installed via the official
route: `opencode plugin install opencode-plugin-langfuse -g`.

**Concerns with this option:**

* The exact env-var name the OpenCode plugin expects
  (`LANGFUSE_HOST` vs `LANGFUSE_BASE_URL` vs
  `LANGFUSE_TRACING_ENABLED`) is a property of
  `opencode-plugin-langfuse`, not OpenCode core. I would need
  to read the npm package's README / source after install to
  confirm. There is some risk of the names being different
  from what the doc presumes.
* The env file is 0640 root:hermes; the loader would need
  user `hermes` to be in group `hermes` (it is) and to be
  able to read mode 0640 group-readable files (it can). The
  perms are already correct.

### Option B — Separate `~/.config/opencode/langfuse.env` with the same keys

The historical "do what the doc says" path. Two env files in
sync. Risks drift: if the operator updates one and not the
other, OpenCode will silently use stale or missing keys.
**Not recommended** — the brief explicitly says "Do not
duplicate real Langfuse keys in a second file if avoidable."

### Option C — Defer indefinitely

The current state is non-failure. Hermes → Langfuse works;
OpenCode traces just don't reach Langfuse. If join keys for
later analysis turn out to be unimportant for the current
benchmark questions, this option is fine.

## What I checked, in summary, before stopping

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
