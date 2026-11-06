---
worth: later
where: agtermCore/Sources/agtermCore/ZmxReplayScript.swift:render
added: 2026-10-18
---
# replay wrapper strands a payload suspended with Ctrl-Z

A Live pane created by `session restart --command` or a missing-daemon replay runs
`<shell> -lic '<payload>; <rearm>; exec <shell> -il'`. A `session new --command` pane no longer does: it
ends with its command through `ZmxReplayScript.renderEnding`, and its Ctrl-Z behavior is unmeasured. When the user presses Ctrl-Z in the payload
(nvim, claude, less), the wrapper does not wait for the stopped job: it rearms and execs the final shell
in the same pid. The payload stays stopped as that shell's child, `jobs` in the new prompt shows nothing,
`fg` has nothing to resume, and the program dies on SIGHUP when the pane's shell exits.

Both renderers do it. Under script(1), with empty HOME/ZDOTDIR/XDG dirs, the exact rendered scripts left
the payload in state `T` in 8 of 8 runs: `/bin/zsh` 5.9 with the `{ } always { }` wrapper and fish 4.9.3
with the `builtin eval` wrapper, argv and command-line forms, both `kill -TSTP $$` and a real `^Z` byte.
zsh also leaves its stopped forked `zsh -lic` list copy behind. Surfaced reviewing PR #761.

The fix is a semantics call made once for both shells. Resuming before the exec works in fish
(`while builtin jobs -q; builtin fg; end` after the eval) but turns Ctrl-Z into a no-op for the payload and
prints `Send job 1 ... to foreground` into the pane; no zsh equivalent was tried. Keeping the job
reachable from the final shell is impossible while the wrapper execs over it, since exec discards the job
table, so that route means not exec'ing and changes the pane's process shape. Either fix needs a seam test
that sends SIGTSTP and asserts what the user is left with.
