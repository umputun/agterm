---
worth: maybe
where: agterm/Ghostty/ForegroundProcess.swift:22
added: 2026-08-28
---
# what a wrapper pane actually captures on restore is unverified

Reading `command(for:)`, a pane whose shell was replaced by a terminal wrapper (`kiro-cli-term`, `qterm`,
`figterm`) should capture the wrapper itself. `tcgetpgrp` returns the wrapper's group, `procArgs` succeeds
because the wrapper runs as the user, and `isIdleShell` does not match — `basename("zsh (kiro-cli-term)")`
is the whole string, not `zsh`. So the capture is non-nil, which sets `hadForeground` and drops a
`--command` session's `initialCommand`, and `shouldRestore` passes the argv, so restore would type
`'zsh (kiro-cli-term)'` into the pane.

The reporter of discussion #497 observed the opposite: a session running `sleep 600` came back as a plain
shell with `foregroundCommand: null`. `WindowLibrary.stripCaptures` nils that field in the window file on
every launch restore, so a null read after relaunching proves nothing either way — but "came back as a
bare shell" is not what typing a bad command produces.

Two possibilities and they want different fixes: if the capture is non-nil, a `--command` session under a
wrapper silently loses its exec path and every pane gets a `command not found` on launch; if it is nil, the
pane just loses its program, which is what the docs now say. Settling it needs a wrapper installed, so the
cheapest route is to ask on #497 rather than to install one.
