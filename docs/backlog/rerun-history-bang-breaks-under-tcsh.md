---
worth: maybe
where: agterm/Ghostty/LaunchSeed.swift:restoreInitialInput
added: 2026-11-11
---
# Re-run restore of a command containing ! fails under a tcsh login shell

Re-run types the captured argv into an interactive login shell, and interactive tcsh performs history
substitution even inside single quotes (tcsh(1), "History substitution"). `shouldRestore` accepts `!`, so a
captured `grep '!needle' log` comes back as `'grep' '!needle' 'log'`, and tcsh answers `needle: Event not
found.` and runs nothing; a `!` followed by a matching history word is substituted instead. Reproduced with
`printf "%s\n" "/usr/bin/printf '%s\\n' 'fix!x'" | /bin/tcsh -f -i` printing `x: Event not found.`.
sh, bash, zsh and fish keep the argument intact.

Both `shellQuotedLine` and `accountShellQuoted` leave `!` inside the quotes, so PR #967's switch of this
call site neither caused nor changed it; its round-trip tests run under `-c`, where history is off.
Surfaced reviewing PR #967. Open call: escape `!` outside the quotes as `\!` in `accountShellQuoted`, which
needs a five-shell interactive round trip to prove fish and zsh read it alike, or refuse `!` for a tcsh
login shell in `shouldRestore`.
