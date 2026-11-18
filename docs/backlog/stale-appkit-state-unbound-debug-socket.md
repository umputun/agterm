---
worth: later
where: CLAUDE.md
added: 2026-11-18
---
# stale AppKit state can keep a Debug instance's control socket unbound

The working-norms note on a Debug instance's control socket says a backgrounded `open -n -g` can leave
the app running with no socket, and gives a relaunch without `-g` as the workaround. Discussion #1037
measured one cause on master 235b5f27: with stale AppKit saved state for the bundle, `open -n -g` and an
exec of the binary showed no window and no socket in every run, and passing
`-ApplePersistenceIgnoreState YES` as a launch argument restored both. Whether the 2026-11-07 incident the
note records had stale state behind it is unknown. Revisit the launch guidance once the #1037 fix is in
and verified (https://github.com/umputun/agterm/discussions/1037).
