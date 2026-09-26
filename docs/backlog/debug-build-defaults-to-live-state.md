---
worth: maybe
where: agterm/agtermApp.swift:init
added: 2026-09-26
---
# a Debug build launched without AGTERM_STATE_DIR opens the live state

A Debug build without `AGTERM_STATE_DIR` resolves the same state directory as the deployed app, so it loads
the live workspaces, attaches to the live session daemons, and rewrites the live windows files when it
quits. Isolation depends on every launch passing the variable, and a Dock launch never does. On
2026-09-26 a Debug instance started with isolated state was stopped by SIGTERM, its Dock tile lingered, and
a click on the tile 13 seconds later relaunched the bundle onto live state; it rewrote `windows.json` and
the window file on quit 30 seconds later.

A Debug build (`com.umputun.agterm.debug`) could default to its own directory, for example
`agterm-debug`, when the variable is unset. The design call is whether anyone relies on a Debug build
seeing live state; UI tests and manual runs already pass an isolated directory.
