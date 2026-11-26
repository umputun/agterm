---
worth: maybe
where: agterm/Ghostty/LaunchSeed.swift
added: 2026-11-26
---
# support OSC 7577 program resume

OSC 7577 (Program Resume Protocol, rev 0.5, 2026-11-25, https://www.superlogical.com/rex/docs/build/program-resume)
lets a program report its own resume argv and cwd, signed with a per-pty `OSC7577_TOKEN`, so the terminal
can restart it after the pty is lost. The gap it closes for agterm: when the pty is lost (Live daemon gone,
or Re-run after a reboot), agterm can replay a saved foreground command but cannot recover a conversation
id absent from it, and without a capture (unclean exit) it may open a plain shell. Only Re-run mode lets a
SessionStart hook pin a conversation explicitly. A Live daemon that survives keeps the program itself.

Adoption at the time of writing: receivers Rex, codevisor, phux; Pi emits it (unreleased); Claude Code only
through Rex's hook, native emission requested in anthropics/claude-code#112408.

Start when both hold:
- an emitter agterm users actually want resumed ships (native Claude Code or Pi);
- an intake path usable by agterm and the pty owner exists, upstream or via a patch worth carrying.
  libghostty-vt 1.4.0 already has an unknown-sequence callback and an OSC 7501 callback, but the embedded
  surface API agterm uses (`ghostty.h`) exposes neither.

Requirements beyond what agterm has:
- MUST keep argv verbatim and never build shell source from it; Re-run shell-quotes argv into shell input
  and the `session restore` pin is shell source, so neither is a usable sink. Running after shell startup
  and preventing builtin/function shadowing are SHOULDs;
- the pty owner (zmx daemon in Live, the agterm-server host remotely) must accept reports and clears while
  no viewer is attached, the record must survive pty loss, and a surviving daemon must never start a second
  copy; token injection itself rides the environment zmx already passes to the shell;
- one record per pane, cleared on `clear=1`, an owner exit on its own, or a deliberate pane close, and kept
  across terminal shutdown, allowing for the owner exiting just before the pty closes; opt-in trust per
  program; records may hold secrets, so owner-only storage.

Do not make the installed Claude hook set `session restore` instead: the pin persists, wins over capture,
bypasses the denylist, overwrites a deliberate `--none`, and resurrects a conversation the user quit.
