---
worth: maybe
where: agtermCore/Sources/agtermCore/RemoteSession.swift:controlCommand
added: 2026-11-11
---
# remote control command splits a newline operand into commands under tcsh

`controlCommand` quotes its outer layer with `accountShellQuoted` for any login shell, but tcsh refuses a
newline inside single quotes: each line becomes its own command. With the remote login shell set to tcsh,
an argument or operand carrying `first\necho INJECTED\nlast` reports `Unmatched '''` for the outer lines and
runs `echo INJECTED`; sh, zsh and fish keep the whole argument intact. The Re-run restore path is not
exposed, since `CommandRestore.shouldRestore` refuses control characters before quoting.

Surfaced by the dependency screen while reviewing PR #967. Neither obvious fix works, because
`controlCommand` cannot know the remote login shell:

- refusing control characters in its arguments and operands also refuses a multiline remote `--command`
  (`RemoteCatalogActions` passes `--command=<text>` for new sessions, companions and the scratch), which
  works today on sh, zsh and fish;
- backslash-newline inside single quotes is a newline only to tcsh; sh, zsh and fish keep the backslash.

A fix needs a shell-neutral transport, such as arguments encoded so no login shell sees a newline and
decoded by `/bin/sh` on the far side. Every caller found passes text the local user typed, so the split
runs that user's own lines on their own host. Not traced: callers passing text from another source.
