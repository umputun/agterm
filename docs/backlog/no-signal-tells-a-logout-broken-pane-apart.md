---
worth: maybe
where: agtermCore/Sources/agtermCore/SessionHost.swift:place
added: 2026-11-26
---
# no signal tells a logout-broken pane apart

In discussion #1116 a Live pane started before a macOS logout survived it and lost the ended login's
services (keychain, codesign identities, sysmond, `launchctl managername`), while it looked normal in the
sidebar. The reporter asked for detection at restore plus a stale mark or a restart action. Auto-restart
was declined (it kills running work, the #971 decision); a mark or launch notice was deferred until a
second confirmed report. His pane's attribution is still unconfirmed.

Why no existing signal works: `liveHostStale` is one Bool for both a build change and a login change, and
panes under an earlier build can keep working; `orphaned` also follows a plain quit for panes attributed to
the app. On macOS 27+ a host bootstrapped as a `gui/<uid>` job (#987) ends with its login, with a spawn
fallback when the bootstrap fails. If the daemon survives its host, `tree` can report `orphaned` with no
stale flag. The old endpoint may remain on disk, but placement has lost the live host that tied the pane to
that key.

Cost of a precise signal: a probe reading another process's audit session id, or a per-pane record of the
login it started under (proposed with the per-daemon disclaim item dropped in 34737b34), which would have to
track the daemon generation since `session restart` keeps the pane id; then a tree read-back, a sidebar or
launch-notice surface that clears itself once the pane is replaced, and remote parity. A login mismatch
shows where a pane came from, not that a service failed in it. Related: `reset-selects-working-panes-on-older-hosts`,
which asks the "host age alone, or with a symptom" question for Reset.
