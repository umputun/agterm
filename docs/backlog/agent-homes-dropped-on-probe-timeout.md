---
worth: later
where: agterm/OpenCodeEnvironmentProbe.swift:run
added: 2026-11-27
---
# CODEX_HOME and COPILOT_HOME are dropped when the OpenCode version probe times out

The install probe captures `CODEX_HOME` and `COPILOT_HOME` from the login shell before it runs
`opencode --version`. When that version command outlives the 3-second timeout, `run` discards both
homes even though the capture line arrived whole, so the hooks go to `~/.codex` and `~/.copilot`
instead of the user's custom roots. A slow or hung `opencode` should not decide where Codex and Copilot
hooks are written.

The current behavior is deliberate and pinned: `testTimeoutAfterCaptureDiscardsCodexHome` and
`site/docs.html` ("a timeout falls back to `~/.codex`"). Fixing it means keeping both homes after a
complete capture, changing that test and the docs line, for both agents together or neither.
Surfaced reviewing PR #1120, which copied the Codex policy to `COPILOT_HOME`.
