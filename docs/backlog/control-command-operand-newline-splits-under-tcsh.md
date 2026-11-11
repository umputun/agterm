---
worth: later
where: agtermCore/Sources/agtermCore/RemoteSession.swift:controlCommand
added: 2026-11-11
---
# remote control command splits a newline operand into commands under tcsh

`controlCommand` quotes its outer layer with `accountShellQuoted` for any login shell, but tcsh refuses a
newline inside single quotes: each line becomes its own command. With the remote login shell set to tcsh,
an argument or operand carrying `first\necho INJECTED\nlast` reports `Unmatched '''` for the outer lines and
runs `echo INJECTED`; sh, zsh and fish keep the whole argument intact. The Re-run restore path is not
exposed, since `CommandRestore.shouldRestore` refuses control characters before quoting.

Surfaced by the dependency screen while reviewing PR #967. Two fixes, which is the open call: refuse control
characters in `controlCommand`'s arguments and operands, or escape a newline as backslash-newline inside the
quotes for tcsh. Not traced: which callers (`RemoteCatalogActions`, `ControlServer+RemoteCompanions`) can
pass a newline from text the local user did not type.
