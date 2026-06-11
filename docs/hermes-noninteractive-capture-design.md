# Hermes non-interactive capture — design note

**Status:** design proposal only. No code change is proposed for
landing in this note. See "Open question / next step" at the bottom.

**Why this exists:** the current `hermes-bench.sh` wrapper ends in
`"$hermes_bin"` (line 132), i.e. it runs the `hermes` CLI with no
arguments. On a desktop that launches the TUI. On a headless Debian
VM (this VM, in particular) the TUI cannot attach to a terminal and
the run either hangs or exits with a TTY error, so the wrapper
captures a non-actionable task log. We need a way to drive the same
capture path non-interactively.

The cleanest target is `hermes chat -q "..."`, which is the
existing one-shot query path that the Hermes team already supports
(visible in `hermes chat -h`: `-q QUERY, --query QUERY` and
`-Q, --quiet`).

## What the current `hermes-bench.sh` does (baseline)

The wrapper has three pieces:

1. **Configuration** (lines 7-46): load config file, validate
   `HARNESS=hermes`, `HARNESS_MODE=orchestrating-opencode`,
   `DOWNSTREAM_AGENT=opencode`, and `HERMES_MEMORY_MODE=on`.
2. **Pre-capture** (lines 85-115): call
   `capture-task-start.sh "$repo_root"` with
   `HARNESS=hermes`, `HARNESS_MODE=orchestrating-opencode`,
   `AGENT_COMMAND_LABEL=hermes-orchestrating-opencode`, plus a
   fixed set of `HERMES_*` env vars. The script records
   `harness: "hermes"`, `harness_mode: "orchestrating-opencode"`,
   `agent_command_label: "hermes-orchestrating-opencode"`, and
   sets `OTEL_RESOURCE_ATTRIBUTES` with the same
   `opencodebench.*` keys the OpenCode wrapper uses.
3. **Run** (lines 132-134): `cd "$repo_root" && "$hermes_bin"` —
   i.e. the bare `hermes` command, TUI by default.
4. **Post-capture** (lines 122-130, EXIT trap):
   `capture-task-finish.sh "$task_dir" "$hermes_exit_code" hermes`
   — same as the OpenCode wrapper, except `agent_kind=hermes`.

Because steps 1, 2, and 4 are already env-driven, the
non-interactive change is local to step 3.

## Why TUI mode is awkward on this VM

* The Debian 12 VM is a headless Proxmox guest. There is no
  controlling terminal attached to background service user
  `hermes` in the systemd unit's working directory
  (`WorkingDirectory=/opt/hermes`).
* `hermes` launched with no args in that environment either
  prompts for a TUI attach (no TTY) or exits with a clear error
  after capture-task-start has already recorded the start. The
  captured `metadata.json` is structurally fine but the
  `hermes_exit_code` is uninformative (typically 1 or 130 from
  EOF/EPERM, not a real LLM result).
* Even when it "works" on a developer's local box, the resulting
  capture is hard to compare against a headless OpenCode run
  because TUI runs include user-side typing time, completion
  menus, and the developer's REPL habits. A one-shot `-q` query
  keeps the run reproducible.

## Proposed minimal CLI shape

Add flag parsing to the top of `hermes-bench.sh`, then change
the run block to honor the new flags:

```text
Usage:
  hermes-bench.sh [options]

Options:
  --query, -q "TEXT"    Run a one-shot non-interactive query
                        against `hermes chat -q`. Default: omitted,
                        which preserves the current TUI behavior.
  --model, -m MODEL     Model label recorded in metadata.json
                        (HERMES_MODEL). Has no effect on the actual
                        model — pass `-m` to `hermes chat` if needed.
  --quiet, -Q           Pass -Q to `hermes chat` to suppress the
                        banner/spinner (recommended for benchmarks).
  --tui                 Force the current TUI behavior (default if
                        --query is absent).
  --dir PATH            Override the target repo (default: $PWD or
                        OPENCODEBENCH_REPO). Resolved exactly like
                        the OpenCode wrapper.
  -h, --help            Show this help.
```

The implementation cost is roughly:

* A small `parse_args` block (~30 lines) using only `getopts`-style
  loop or a hand-rolled `while [[ $# -gt 0 ]]; do case ...`
  pattern matching the existing style of
  `opencodebench-opencode`.
* One conditional in the run block: if `hermes_query` is non-empty,
  exec `"$hermes_bin" chat -Q -q "$hermes_query" "${passthrough_args[@]}"`
  else exec `"$hermes_bin"` as today.
* Three new env vars threaded into the
  `capture-task-start.sh` call:
  `HARNESS_MODE=hermes-noninteractive-orchestrating-opencode`
  (or similar — see naming below), `HERMES_QUERY_SHA256=$(printf
  '%s' "$hermes_query" | sha256sum | cut -d' ' -f1)` (so we
  record the query without ever persisting the query text), and
  `HERMES_QUERY_CHARS=${#hermes_query}`.

## Reuse of `capture-task-start.sh` and `capture-task-finish.sh`

* `capture-task-start.sh` is keyed on `HARNESS` / `HARNESS_MODE` /
  `AGENT_COMMAND_LABEL` env vars, plus the full Stage 2.5
  `hermes_*` block. It already supports
  `OPENCODEBENCH_TASK_TYPE=validation|implementation|...` and the
  `hermes_user_prompt_*` fields. No edits required to it for this
  proposal.
* `capture-task-finish.sh` is called with `agent_kind=hermes`
  in the existing wrapper. The non-interactive path keeps that
  argument. No edits required there either.

## Metadata that should identify it as a non-interactive Hermes run

The new path is the existing Hermes path plus a
"non-interactive" tag, not a new harness. Concretely:

* `harness`: `"hermes"` (unchanged).
* `harness_mode`: a new value, e.g.
  `"hermes-noninteractive-orchestrating-opencode"`. This is the
  *only* field that distinguishes a TUI run from a one-shot
  query run in downstream analysis. Anything that slices
  metadata on `harness_mode` (e.g. the Stage 2.5 orchestrator
  metadata) needs to learn the new value, but adding it is a
  one-line edit per consumer.
* `agent_command_label`: `"hermes-noninteractive-orchestrating-opencode"`.
* `hermes_interactive`: `false` (the wrapper can derive this
  from `[[ -z "$hermes_query" ]]`).
* `hermes_user_prompt_source` / `hermes_user_prompt_sha256` /
  `hermes_user_prompt_chars`: the wrapper computes the
  SHA-256 and length locally (it already has the prompt in
  `$hermes_query`) and threads them in as
  `OPENCODEBENCH_HERMES_USER_PROMPT_SHA256` /
  `..._CHARS` env vars. The actual prompt text is **not**
  recorded by the wrapper, matching the existing privacy
  boundary: the local Hermes session DB has the prompt; the
  benchmark artifact has a hash, not the text.
* `opencodebench.session_id` / `task_id`: already encodes
  `harness`, so the new mode is visible in the path.
* `opencodebench.opencodebench_meta.noninteractive`: a small
  boolean under the existing `opencodebench.*` namespace for
  consumers that prefer the boolean form.

The privacy boundary from `docs/stage-29-private-transcript-layer.md`
is preserved: the wrapper does not capture the prompt text, the
session DB pointer (`hermes_trace.json`) is the only place the
prompt is recoverable, and that is already gated by
`OPENCODEBENCH_SKIP_HERMES_ORCHESTRATOR` etc.

## Smoke test

Once implemented, the smallest end-to-end check on this VM:

```sh
cd /home/hermes/workspace/repos/coding-agent-benchmarks
env -u OPENCODE_SERVER_PASSWORD -u OPENCODE_SERVER_USERNAME \
    OPENCODEBENCH_TASK_TYPE=validation \
    OPENCODEBENCH_UPSTREAM_ORCHESTRATOR=hermes \
    ./hermes-bench.sh --query "Reply with the single word: pong" \
                     --model "hermes-default" --quiet
```

Expected behavior:

* `bash -n hermes-bench.sh` clean.
* Exit code is the same as `hermes chat -Q -q "Reply with the
  single word: pong"` (i.e. 0 if the model returns, non-zero
  otherwise).
* A task log directory is created under
  `.local/coding-agent-task-logs/YYYY/MM/<task_id>/` with
  `harness_mode: "hermes-noninteractive-orchestrating-opencode"`,
  `agent_command_label: "hermes-noninteractive-orchestrating-opencode"`,
  `hermes_interactive: false`, populated `timing.*` and
  `diff_summary.*` blocks, and `exit_code` matching the
  captured run.
* A second run with the same query and `--task-type
  implementation` (default) confirms the existing
  `task_type_status: "valid"` path in
  `capture-task-start.sh` (post-`2d7aecb` fix).
* `git status --short` shows nothing new (task log is
  gitignored under `.local/`).

The TUI path must keep working too: an invocation with no
`--query` should behave exactly as it does today. That is the
backward-compatibility guarantee.

## Open question / next step

This is a design note, not a patch. The change is small (~30-40
lines) but it touches a wrapper the user is currently iterating
on, and the value of the diff depends on what the user wants
TUI runs to look like in the benchmark corpus going forward:

* If TUI runs are no longer wanted in the corpus, this becomes
  the default and `--tui` becomes a deliberate opt-in.
* If TUI runs are still wanted (e.g. for "real user sessions"
  vs. "synthetic one-shots"), `--query` is opt-in and the new
  `harness_mode` lets analysis split them.

Recommended next step: review this note alongside the
`docs/langfuse-debian-vm-status.md` from the same session, and
decide whether to:

1. Land the design as-is and implement it as a follow-up
   commit.
2. Adjust the proposed `harness_mode` value (e.g. shorten to
   `"hermes-cli-orchestrating-opencode"` or split it as
   `"orchestrating-opencode-cli"` vs. the existing
   `"orchestrating-opencode"`-tui).
3. Defer until a specific downstream analysis needs the
   distinction.

Until then, the existing `hermes-bench.sh` is unchanged and
every documented TUI run is still the only supported path.
