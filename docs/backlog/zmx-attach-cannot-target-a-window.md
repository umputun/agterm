---
worth: later
where: agterm/Control/ControlServer+Zmx.swift:74
added: 2026-09-02
---
# `zmx attach` cannot target a window

`attachRemoteSession` resolves `library.activeStore` and inserts there, so a remote session always lands
in the frontmost window. Every comparable creation command takes `--window`: `session.new` resolves an
explicit target before choosing a workspace, and the control-api rule says placement commands accept one.

A scripted caller that wants a remote session in a background window cannot express it. It has to select
that window first, which moves the user's focus, then attach, then select back — and it races anything
else changing the frontmost window in between.

The recipe is unaffected: a keymap custom command already runs against the key window, which is the one
the picker appeared over. So nothing user-facing is broken today, and this only bites automation driving
several windows.

Adding it is `--window` on the CLI subcommand, `args.window` through the dispatcher, and resolving the
store through `ControlTargetResolver` instead of `activeStore`, plus the read-back test the rules require.
Surfaced in Fable's pre-merge review of the remote-sessions branch.
