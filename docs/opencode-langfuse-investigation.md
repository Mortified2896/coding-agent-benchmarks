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

### Verified end-to-end (2026-06-11)

Operator confirmed in the Langfuse UI that the OpenCode →
Langfuse trace for the test capture on 2026-06-11 (`task_id`
`2026-06-11T10-22-43Z-opencode-coding-agent-benchmarks`,
OpenCode session `ses_149cb4f99ffeVObjt8T96bycPB`) is
visible. Environment field reads `opencodebench` (set by
the wrapper per the recipe in the "Langfuse `environment`
tag for OpenCodeBench runs" section below). The full set of
local join keys, OTel resource attributes, and the cross-DB
SQL lookup that ties the Langfuse trace back to the
OpenCodeBench task log is recorded in the
"Local-side join keys (what the operator already has)"
section below.

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
  LANGFUSE_ENVIRONMENT=set` (this last field is `set` for
  captures run after commit `dd0b300` lands; for the
  pre-tag validation runs, it was `missing` and the plugin
  fell back to its `development` default).
* OpenCode session created: `ses_149cb4f99ffeVObjt8T96bycPB`
  at `2026-06-11T10:22:46.886Z` UTC (this is the
  **verified trace**; the operator confirmed its presence
  in the Langfuse UI on 2026-06-11).
* Wrapper exited 0; model replied `pong`.
* New OpenCodeBench task log at
  `.local/coding-agent-task-logs/2026/06/2026-06-11T10-22-43Z-opencode-coding-agent-benchmarks/`
  with `task_type: validation/valid`, `git_head_before: 14bbbf5d`
  (matches the just-pushed tip), `opencode_version: "1.17.3"`.
* **Plugin log lines in `opencode.log`**:
  - `OTEL tracing initialized → https://cloud.langfuse.com`
  - `Flushing OTEL spans before idle`
  (these were absent in the first round; their presence
  here was the diagnostic evidence that the plugin was
  actually running, after the file:// spec fix.)
* `git status` clean; no secrets (`pk-lf-` or `sk-lf-` shaped
  strings) in `~/.local/share/opencode/log/opencode.log`.

### Verified end-to-end (operator)

The OpenCode → Langfuse trace for the smoke test above
(`task_id` `2026-06-11T10-22-43Z-opencode-coding-agent-
benchmarks`, OpenCode session `ses_149cb4f99ffeVObjt8T96bycPB`)
is **visible in the Langfuse UI**, as confirmed by the
operator on 2026-06-11. The trace's `environment` field
reads `opencodebench` (set by the wrapper per the recipe
in the "Langfuse `environment` tag for OpenCodeBench runs"
section below). The five `opencodebench.*` OTel resource
attributes (`session_id`, `project_id`, `repo_root`,
`task_dir`, `git_commit_before`) are attached to every
span and are searchable in the UI.

The "what I could not verify locally" caveat in the
prior revision of this doc is now retired — the operator's
UI verification removed the only remaining unknown. The
local-side data (this task log, the OpenCode session DB
row, the `OTEL_RESOURCE_ATTRIBUTES` set by the wrapper)
is now also documented in the
"Local-side join keys (what the operator already has)"
section below.

### Local-side join keys (what the operator already has)

For the verified trace on 2026-06-11 (`task_id`
`2026-06-11T10-22-43Z-opencode-coding-agent-benchmarks`,
OpenCode session `ses_149cb4f99ffeVObjt8T96bycPB`),
the local data sources carry the following join keys. Every
key listed here is retrievable from the VM with a single
file read or one-line SQL query; no cloud access is required.

| Join key | Where it lives locally | Value for the verified trace | In Langfuse today? |
|---|---|---|---|
| `task_id` (= `opencodebench.session_id`) | `metadata.json.task_id` and the task dir name itself | `2026-06-11T10-22-43Z-opencode-coding-agent-benchmarks` | yes, as OTel resource attribute `opencodebench.session_id` on every span (set by the wrapper's `OTEL_RESOURCE_ATTRIBUTES`) |
| `opencodebench.session_id` | `metadata.json.opencodebench.session_id` (nested) and the flat `metadata.json["opencodebench.session_id"]` | same as `task_id` | yes (see above) |
| OpenCode session ID | `~/.local/share/opencode/opencode.db` `session.id`; also visible in the LLM-stream log line and the OpenCodeBench `summary.md` if added later | `ses_149cb4f99ffeVObjt8T96bycPB` | not currently in the Langfuse trace; **not** added by any env var or OTel attribute we set today |
| Model | `metadata.json.model_id`; also `message.data.model.{providerID, modelID}` in OpenCode DB | `opencode/deepseek-v4-flash-free` (providerID=`opencode`, modelID=`deepseek-v4-flash-free`) | yes, on the LLM span as the OTel model name and the GenAI `gen_ai.response.model` attribute |
| Timestamp (start) | `metadata.json.opencodebench.timing.start_unix_seconds` and the OTel SDK's span start time | `1781173363.625667` (UTC `2026-06-11T10:22:43.625Z`); the trace's first span is at the same time | yes, Langfuse trace timestamp |
| Repo path / cwd | `metadata.json.cwd` and `metadata.json.repo_path` and `metadata.json.git_root` (all equal); also `session.directory` and `message.data.path.{cwd, root}` in OpenCode DB | `/home/hermes/workspace/repos/coding-agent-benchmarks` | partially — appears as the OTel `process.executable_path` / `process.working_directory` resource attribute; not a separate Langfuse field |
| `git_head_before` | `metadata.json.git_head_before` and the nested `metadata.json.opencodebench.git_commit_before`; also `git-head-before.txt` next to `metadata.json` | `14bbbf5dd0943e9a711336d4e69c780e004737e6` | yes, as OTel resource attribute `opencodebench.git_commit_before` |

**In addition, the wrapper sets five `opencodebench.*` OTel
resource attributes on every span of the trace (see the
`opencodebench_otel_attributes` block in `opencodebench-opencode`
around line 612):**

* `opencodebench.session_id` (= task_id)
* `opencodebench.project_id` (e.g. `coding-agent-benchmarks`)
* `opencodebench.repo_root`
* `opencodebench.task_dir` (the absolute path to the task log dir)
* `opencodebench.git_commit_before` (= `git_head_before`)

To see them in the Langfuse UI: open a trace, click on any
span, look in the span's "Attributes" or "Resource" panel —
the `opencodebench.*` keys appear there. The
`task_dir` value is the full absolute path to the local
OpenCodeBench task log, so the local join is one click /
one file-open away.

**Hermes-side join key (operator's own session that
triggered this run):**

* `hermes_session_id`: `20260611_101253_dc430c` (in
  `metadata.json.hermes_session_id` and
  `task_dir/hermes_trace.json.hermes_session_id`). The
  Hermes chat session that initiated this OpenCodeBench
  capture. **Not** currently propagated to the Langfuse
  trace, but discoverable via the Langfuse trace's
  approximate timestamp + a grep of
  `~/.hermes/sessions/` for matching `time_created`.

#### Cross-DB SQL lookup (operator recipe)

If you have a Langfuse trace timestamp (or environment
filter result) and want to find the matching local
OpenCode session + task log:

```sh
# From a Langfuse trace session ID like ses_149cb4f99ffeVObjt8T96bycPB:
sqlite3 ~/.local/share/opencode/opencode.db \
  "SELECT id, time_created, project_id, slug, directory, title
   FROM session
   WHERE id = 'ses_149cb4f99ffeVObjt8T96bycPB';"

# From an OpenCodeBench task_id like
# 2026-06-11T10-22-43Z-opencode-coding-agent-benchmarks:
cd /home/hermes/workspace/repos/coding-agent-benchmarks
ls -d .local/coding-agent-task-logs/2026/06/2026-06-11T10-22-43Z-*
jq '.opencodebench' "$(
  ls -d .local/coding-agent-task-logs/2026/06/2026-06-11T10-22-43Z-* \
    | head -1)/metadata.json"
```

The `sqlite3` CLI is not installed on this VM; the same
query works through Python's stdlib `sqlite3`.

### What is **not** in the Langfuse trace today

* **Langfuse `tags` field** (the multi-value `["a","b"]` UI
  field, distinct from `environment`): not set. The
  Langfuse SDK reads tags from OTel *span attributes* or
  OTel *context propagation*, not from OTel resource
  attributes — so a custom OpenCode plugin calling
  `setPropagatedAttribute({ key: 'tags', value: [...] })`
  is the path forward. Per the operator's 2026-06-11
  instruction, the tags plugin is **deferred** until we
  verify what the Langfuse UI already exposes for the
  existing `opencodebench.*` resource attributes and the
  `environment` field.
* **Langfuse `metadata` field** (the arbitrary key/value
  `metadata` record on a trace): not set explicitly. The
  same caveat as `tags` applies; the SDK reads it from
  span attributes/context only.
* **OpenCode session ID on the trace**: not currently in
  the Langfuse trace. Adding it would mean either
  (a) extending the wrapper to put it in
  `OTEL_RESOURCE_ATTRIBUTES` (works for filter-by-span-
  attribute in the UI), or (b) a custom plugin
  (works for trace-level metadata).

### OpenCode session ID — now resolved in metadata.json

As of the stage 3 tracking update, `capture-task-finish.sh`
resolves the OpenCode session ID from
`~/.local/share/opencode/opencode.db` after each OpenCode run and
records it in `metadata.json` as `opencode_session_id` (top-
level) and `opencodebench.opencode_session_id` (nested
mirror). The join chain is now automatically recorded for
each OpenCode run:

| Field | Source | Status | Join use |
|---|---|---|---|
| `opencode_session_id` | SQLite DB lookup | `resolved`, `not_found`, `ambiguous`, `error` | Strong join key from OpenCodeBench to OpenCode DB (`session.id`) |
| `opencodebench.opencode_session_id` | nested mirror | same | Same value, grouped under `opencodebench.*` |
| `langfuse_trace_id` | deferred | `skipped` | Placeholder; join via `opencodebench.session_id` in OTel resource attributes |

Resolution logic: directory match (`session.directory ==
repo_path`, with realpath normalization) within a time
window of start-30s to finish+30s, preferring root `build`
sessions (`parent_id IS NULL`) over subagent sessions. On
unique match the status is `resolved` and the `ses_*` ID is
stored. Multiple candidates produce `ambiguous` with a candidate count only;
no candidate rows are stored. DB absence or query failure
produces `not_found` or `error` without blocking the run.

This means the cross-DB SQL lookup recipe below can now
grab the OpenCode session ID directly from `metadata.json`
instead of guessing the time window.

### Langfuse `environment` tag for OpenCodeBench runs

OpenCodeBench runs set `LANGFUSE_ENVIRONMENT=opencodebench`
in the OpenCode process env. The plugin reads it and
forwards it to the `LangfuseSpanProcessor` constructor's
`environment` field; the SDK uses it as the Langfuse
trace's `environment` field. Result: in the Langfuse UI,
all OpenCodeBench traces show `Environment: opencodebench`,
which is a one-click filter handle.

This is set by the OpenCodeBench wrapper
(`./opencodebench-opencode`, just after the
`OTEL_RESOURCE_ATTRIBUTES` block), not by the env-loader.
Reason: tagging should be per-run, not global — an
interactive `opencode` session that does not go through
the wrapper should not be labelled `opencodebench`. The
env-var is honoured if already set, so the operator can
override per-run (e.g.
`LANGFUSE_ENVIRONMENT=staging ./opencodebench-opencode ...`).

The literal Langfuse `tags` field (the multi-value UI
field usually called 'tags', distinct from `environment`)
is not yet set. Setting it requires a small custom
OpenCode plugin that calls the Langfuse SDK's
`setPropagatedAttribute({ key: 'tags', value: [...] })`
from an event hook — the SDK does **not** read tags from
OTel resource attributes, only from span attributes or
context propagation. Tracked as a separate follow-up.

### Quick-find recipe (operator)

The Langfuse UI's "what's already there" surface for
OpenCodeBench traces is richer than just the `environment`
field. The full set of built-in filter handles for a
verified trace:

* **Environment column filter** (one-click in the trace
  list): `opencodebench`. All OpenCodeBench traces show
  up; no interactive `opencode` traces are mixed in.
* **Search box**: `environment:opencodebench`. Same
  effect.
* **Search box (by span attribute)**: `opencodebench.
  session_id:2026-06-11T10-22-43Z-opencode-coding-agent-
  benchmarks`. This narrows to a single capture.
* **Search box (by commit)**: `opencodebench.git_commit_
  before:14bbbf5dd0943e9a711336d4e69c780e004737e6`. This
  finds every OpenCodeBench trace for a given repo state.
* **Inside a trace**: click any span, look in the
  "Attributes" or "Resource" panel. The five
  `opencodebench.*` keys (`session_id`, `project_id`,
  `repo_root`, `task_dir`, `git_commit_before`) are
  attached to every span as OTel resource attributes.
  `opencodebench.task_dir` is the full absolute path to
  the local task log, so the local join is one click /
  one file-open away.
* **Timestamp window**: combine any of the above with a
  timestamp filter to narrow to a specific capture.

Recommendation (per the operator's 2026-06-11 instruction):
before writing any more tagging code (a custom OpenCode
plugin calling `setPropagatedAttribute`, etc.), the
operator should **first** walk through the Langfuse UI
using the above filters and confirm whether the existing
`opencodebench.*` span attributes and the `environment`
field give enough filter handles. If they do, no extra
tagging is needed; if they don't, the next step is the
custom plugin (deferred).

## What I checked, in summary

| Question | Answer |
|---|---|
| Does OpenCode have native Langfuse support? | No. |
| Does it use a plugin? | Yes (`opencode-plugin-langfuse` + custom env-loader). |
| Does it use OpenTelemetry env vars? | Indirectly, via the plugin. |
| What env-var names does OpenCode's plugin path need? | `LANGFUSE_*` (no `HERMES_` prefix). |
| Can it reuse the existing `HERMES_LANGFUSE_*` variables? | Yes, via the env-loader. |
| Where should config live? | `~/.config/opencode/opencode.jsonc` for the OpenCode config; the loader JS at `~/.config/opencode/plugin/load-langfuse-env.mjs`; the env source at `/etc/hermes/hermes.env` (no copy). |
| Can it attach metadata / session IDs? | Yes — `opencode-plugin-langfuse` emits spans; OpenCode session IDs are also in `opencode.db`; the wrapper sets five `opencodebench.*` OTel resource attributes per span. |
| Can OpenCode traces be joined to OpenCodeBench local logs? | Yes, verified end-to-end on 2026-06-11. The five `opencodebench.*` OTel resource attributes are searchable in the Langfuse UI; the local task log is one click away via the `opencodebench.task_dir` attribute. |
| End-to-end verified? | **Yes** (operator confirmed Langfuse UI shows the 2026-06-11 test trace; Environment field reads `opencodebench`). |

## Cross-references

* The historical investigation that described the two-plugin
  design: `docs/reconstructing-benchmark-cases.md` (sections
  "Local Trace And Logging Sources" and "Langfuse environment
  is configured for both OpenCode and Pi/PiWeb").
* The local capture path that already works:
  `docs/opencodebench-task-log-analysis-prep.md`.
* The wrapper that passes join keys via
  `OTEL_RESOURCE_ATTRIBUTES`: `opencodebench-opencode` around
  line 612 (the `opencodebench_otel_attributes` block).
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
* The commits that landed Option A and the verified-end-to-end
  result: `14bbbf5` (file:// plugin spec fix), `05cb39d`
  (initial Option A doc), `dd0b300` (environment=
  opencodebench), `81ff0f3` (quick-find recipe), and the
  current doc revision recording the verified state.
