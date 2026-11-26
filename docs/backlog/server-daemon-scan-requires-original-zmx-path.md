---
worth: later
where: agtermCore/Sources/AgtermServerKit/ProcTable.swift:collect
added: 2026-11-26
---
# server daemon scan drops daemons started from another zmx path

`ProcDaemon.collect` keeps a daemon only when its argv[0] matches the configured `--zmx` literally or
through symlinks. An agterm-server restarted with zmx at a different resolved path still adopts the
surviving daemons from the socket listing, but the `/proc` scan then drops them: `tree` answers
without their foreground data, Duplicate as Companion, restart and `zmx.kill` refuse those live panes,
and session close can miss the SIGHUP for a separate foreground group.
#1101 moved these reads from `zmx list` to the scan; v0.44.1 took the leaders from the listing.

Both supported installers (`scripts/install-server.sh`, `agtermctl server install`) replace
`~/.local/lib/agterm-server` in place, so the path never changes on an upgrade. Only a hand-placed
side-by-side install or a changed `--zmx` hits it.

Fix: in `collect` only, accept an argv[0] whose file name matches the configured executable's, for
valid pane or scratch daemon names, keeping the `ZMX_DIR`, terminal-ownership and newest-process
checks. `select` stays strict: it confirms a launch the server just made with the current path.
This covers a move that keeps the file name (`/old/zmx` to `/new/zmx`); a `--zmx` naming another file,
such as `/new/zmx-custom`, still drops the daemons.
Test with two paths sharing the file name: a live pane whose daemon runs from the old one across a
server restart on the new one.
