---
worth: maybe
where: scripts/zmx-patches/, agtermCore/Sources/SessionHostRuntime/
added: 2026-11-12
---
# per-daemon disclaim instead of a long-lived session host

A replacement for `agterm-session-host` as the Live responsibility root, weighed during #971 and
deferred. macterm (github.com/macterm/macterm, main 19e5bff) patches its zmx so each daemon re-execs
itself in place with `POSIX_SPAWN_SETEXEC` plus `responsibility_spawnattrs_setdisclaim` before
`forkpty` (`server/src/daemonize.zig:206-280`), making every daemon its own root, and signs zmx with
the app's identifier (macterm PRs #420/#421, issue #419). Panes would go back to plain `zmx attach`, so a
daemon is created by its pane's client in the current build and login session, and no host generation
has to be selected, kept or retired. #574's plan never weighed it.

Gain: removes the one-at-a-time host queue and its 30 s fallback to an app-rooted pane, the `uncertain`
creation state and the `--ends-pane` output loss, and most of `SessionHostRuntime` and the trampoline
once host-rooted daemons are gone. Existing panes would go stale only when zmx itself changes
(6 of 12 releases from 2026-09-20), where today every update changes the helper image.

Adopt only if all three pass on a Developer ID build (an ad-hoc grant is a bare cdhash and proves
nothing across builds):

1. microphone with zmx as root, once with zmx's own identifier and once with the app's: TCC must
   report `AUTHREQ_SUBJECT` `com.umputun.agterm` and add no row, as #574's task 9 did for the host;
2. Local Network from a non-Apple binary in a pane after an app quit and relaunch: no second
   Settings entry. macterm #421 still reports a separate path-keyed record after re-signing;
3. bundle replacement with a byte-identical zmx and with a changed one: in a pane created before the
   replace, `codesign -v <daemon pid>`, a LAN connect and a TCC request.

Costs known before measuring: a seventh zmx patch over code `0001` and `0005` already edit, opt-in
through an agterm-set variable, Darwin-only so agterm-server's Linux zmx is unchanged; a hidden daemon
entry that carries the published socket, command, environment, cwd and size across the re-exec;
`Host.awaitLeader` and `SessionHost.classify` both assume the host is the root, so a daemon root reads
`unknown` today; logout detection needs a per-pane record, since the endpoint key is gone; host-rooted
daemons still need the per-build host classification, `stop` and Reset reason until they end.

It does not address #985: a re-exec with disclaim keeps the daemon in its inherited coalition, so every
daemon still shares the coalition of the agterm that created it.
