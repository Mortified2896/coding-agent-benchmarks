# Langfuse observability on the Hermes Debian VM — status note

**Status as of:** session on `2d7aecb` (post-Debian-port, pre-activation).

**Scope:** the `observability/langfuse` plugin shipped with Hermes
(`/home/hermes/.hermes/hermes-agent/plugins/observability/langfuse/`),
as it stands on the Debian 12 VM that runs the coding-agent-benchmarks
project.

This file is a status note, not a spec. When the plugin is either
activated or disabled on this VM, the file should either be deleted
(activation) or amended to record the decision (disable). It is not
intended to live in the repo long-term as policy.

---

## Current state — enabled, but a runtime no-op

* `plugins.enabled` in `/home/hermes/.hermes/config.yaml` lists
  `observability/langfuse`. `hermes plugins list` shows
  `langfuse · enabled · 1.0.0`.
* Despite that, every hook (`pre_api_request`, `post_api_request`,
  `pre_llm_call`, `post_llm_call`, `pre_tool_call`, `post_tool_call`)
  silently no-ops at runtime. The plugin is designed to fail open.
* Empirical check: a real `hermes chat -q "ping"` round-trip
  (session 20260610_223651_bbdc27, model replied `pong`) produced
  **zero** `langfuse`-related log lines anywhere under
  `/home/hermes/.hermes/logs/`. No trace IDs, no span IDs, no
  OTel exporter messages.

The "looks enabled but isn't working" failure mode is exactly the
one to watch for in `hermes plugins list` output.

## Missing pieces (verified, 2026-06-10)

1. **Langfuse Python SDK is not installed** in the Hermes venv.
   - `find /home/hermes/.hermes/hermes-agent/venv/lib -type d -name 'langfuse*'`
     returns nothing.
   - The plugin's `_get_langfuse()` first checks
     `if Langfuse is None: _LANGFUSE_CLIENT = _INIT_FAILED; return None`,
     so every hook is a no-op until the SDK is installed.

2. **Required env vars are absent from the running service environment.**
   - The service is PID 20105 (`/home/hermes/.hermes/hermes-agent/venv/bin/python3 hermes dashboard ...`),
     user `hermes`. Its `/proc/20105/environ` contains only
     `HOME`, `USER`, `PATH`, `HERMES_HOME` — **no**
     `HERMES_LANGFUSE_PUBLIC_KEY`, `HERMES_LANGFUSE_SECRET_KEY`,
     or `HERMES_LANGFUSE_BASE_URL`.
   - `~/.hermes/.env` (mode 600, user-readable) contains zero
     `HERMES_LANGFUSE_*` / `LANGFUSE_*` lines (name-only grep).
   - The systemd unit `/etc/systemd/system/hermes-agent.service`
     declares `EnvironmentFile=/etc/hermes/hermes.env`. That file
     lives in a `root:root 0750` directory that user `hermes`
     cannot read. Either the file does not contain the Langfuse
     keys, or it does not exist as readable — either way, the
     variables did not reach the running process.

The plugin's own code path is the giveaway: if either the SDK is
missing or any required key is empty, the client init is cached as
`_INIT_FAILED` and every subsequent hook short-circuits to `None`.

## Safe activation plan (do not execute unattended)

If the user later wants real observability on this VM, the minimum
end-to-end sequence is:

1. **Install the SDK into the Hermes venv** (user-`hermes` cannot
   write there, so this needs root or `sudo`):
   ```sh
   sudo -u hermes \
     /home/hermes/.hermes/hermes-agent/venv/bin/pip install langfuse
   ```
   Verify with:
   ```sh
   sudo -u hermes \
     /home/hermes/.hermes/hermes-agent/venv/bin/python -c \
       "import langfuse, sys; print(langfuse.__file__)"
   ```
   No values should be printed or echoed in this verification.

2. **Set the env vars in `/etc/hermes/hermes.env`** (root-only
   directory; the systemd unit already loads it). Use `visudo`-style
   discipline — paste keys with `tee -a` and `chmod 600`, never
   `cat` them in chat, never commit them. The required names are:
   - `HERMES_LANGFUSE_PUBLIC_KEY` (must start with `pk-lf-`)
   - `HERMES_LANGFUSE_SECRET_KEY` (must start with `sk-lf-`)
   - `HERMES_LANGFUSE_BASE_URL` (default: `https://cloud.langfuse.com`)

   Optional but recommended for benchmarking workloads:
   - `HERMES_LANGFUSE_ENV=local`
   - `HERMES_LANGFUSE_RELEASE=v0.16.0` (match the running Hermes version)
   - `HERMES_LANGFUSE_SAMPLE_RATE=1.0`

3. **Restart the service** so the new `EnvironmentFile` is read:
   ```sh
   sudo systemctl restart hermes-agent.service
   systemctl status hermes-agent.service --no-pager
   ```
   Confirm `/proc/<new-main-pid>/environ` now contains
   `HERMES_LANGFUSE_*` (names only, never values).

4. **Run a tiny trace test**:
   ```sh
   hermes chat -q "ping"
   ```
   Then `tail -n 200 /home/hermes/.hermes/logs/agent.log | grep -i langfuse`
   — at minimum, the plugin's placeholder-detection warning
   ("credentials look like placeholders, traces will NOT be emitted")
   should now be **absent** if the keys are real, or **present** if
   a placeholder leaked in. Either is informative; silence after a
   real `chat -q` is a red flag.

5. **Verify in the Langfuse UI** — log in to the project that
   matches the public key, look for a `Hermes turn` trace, confirm
   the metadata includes `task_id`, `repo_path`, and
   `git_head_before` (the latter two so cloud traces can be joined
   back to local benchmark artifacts, per
   `docs/reconstructing-benchmark-cases.md`).

## Safe alternative — disable

If the user decides they do not want Langfuse on this VM, the
cleanest move is to remove it from `plugins.enabled` so `hermes
plugins list` stops advertising it as enabled while it does nothing:

```sh
hermes plugins disable observability/langfuse
hermes plugins list | grep -i langfuse
# (no row, or row shows "not enabled")
```

The plugin stays installed on disk; `enable` is one command away
if the decision reverses. This is the lower-friction choice and
matches the actual runtime behavior.

## What was **not** done in the verification session

To be explicit about blast radius:

* No SDK install was attempted.
* `/etc/hermes/hermes.env` was not read or written.
* No Langfuse keys were generated, printed, pasted, or stored.
* `~/.hermes/.env` was only grepped for variable *names* (the
  file itself was not opened or printed).
* `hermes plugins disable observability/langfuse` was **not**
  run, even though the safe-alternative path is documented here.
  That decision belongs to the user.

## Cross-references

* Plugin source: `~/.hermes/hermes-agent/plugins/observability/langfuse/__init__.py`
* Plugin manifest: `~/.hermes/hermes-agent/plugins/observability/langfuse/plugin.yaml`
* Plugin README: `~/.hermes/hermes-agent/plugins/observability/langfuse/README.md`
* Project context for why local traces are the source of truth and
  Langfuse is the joinable overlay:
  `docs/reconstructing-benchmark-cases.md` (search for "langfuse").
* The fix that unblocked the rest of the Debian-readiness work
  (a separate issue, but adjacent):
  commit `2d7aecb` — bash portability for
  `capture-task-start.sh`.
