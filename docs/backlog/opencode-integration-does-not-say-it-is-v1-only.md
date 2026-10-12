---
worth: later
where: agterm/AgentHooksInstaller.swift:opencodeText
added: 2026-09-21
resolved: 2026-10-12
---
# OpenCode integration does not say it is v1-only

The bundled `agterm-status.js` uses OpenCode's v1 plugin API, and OpenCode v2 does not run v1 plugins.
The installer gates only on `~/.config/opencode` existing, so on a v2 machine it reports "OpenCode
lifecycle plugin installed ... Restart OpenCode." and no status ever appears. `docs/troubleshooting.md`
and the bundled skill's `troubleshooting.md` give the same restart advice, which does nothing on v2.

Until v2 support exists (#637), say which OpenCode major the integration serves in the install dialog
text and both troubleshooting pages. When #637 is done the wording changes again, so fold this into that
work if it arrives first.

## Resolved 2026-10-12

`agterm/Resources/agent-status/opencode/agterm-status.js` is now dual-entrypoint: `default.setup(ctx)`
serves OpenCode v2 (verified against 2.0.25) and `default.server()` serves v1 >= 1.18.29, so the
install text no longer needs a major qualifier and the "restart" advice is again sufficient (v2 also
hot-reloads the plugin through its file watcher). Notes for #637's remaining scope:

- The v2 **public event stream never carries `session.status`** — only TUI-internal consumers see it.
  The plugin tracks turns from `session.execution.started`/`step.started` (busy),
  `session.execution.succeeded` (completed), `session.execution.failed` (blocked; `error.type` follows
  the `provider.*` / `context-overflow` catalog), and `session.execution.interrupted` (abort → completed
  `--auto-reset`). Questions are `form.created`/`replied`/`cancelled`; payloads sit under `data`, not
  `properties`.
- v1 compatibility needs no code on the v2 side: a default export carrying both `setup` and `server`
  passes the v2 loader (the loader only validates the default export's `id` + `setup`/`effect`).
- The v1 `ContextOverflowError` ambiguity is absorbed in v2 by debouncing `execution.failed` reports
  (800 ms default, `AGTERM_STATUS_FAILURE_DEBOUNCE_MS` override) and canceling on any further activity
  for the session.
