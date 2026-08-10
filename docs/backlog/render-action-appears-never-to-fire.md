---
worth: later
where: agterm/Ghostty/GhosttyCallbacks.swift:51
added: 2026-08-10
---
# GHOSTTY_ACTION_RENDER appears never to fire, so renderNow may be dead code

Instrumenting the `GHOSTTY_ACTION_RENDER` arm and `renderNow` and running a Debug instance through a
full session - launch, a `session type` that echoed output, a `--command` session ticking once a second,
window resizes, sleep and wake - produced **zero** RENDER callbacks and zero `renderNow` calls, while the
panes painted normally throughout. libghostty's renderer appears to drive the `CAMetalLayer` itself in
pinned `4dcb09ada`, with the embedding API's RENDER action unused.

If that holds, `renderNow` is dead in production and the "demand-driven" account in `CLAUDE.md` and
[[libghostty]] - "Wakeup coalesces into one main-queue `ghostty_app_tick`; RENDER calls `renderNow`" -
describes a path that does not run. The cost is to whoever debugs a paint problem next: the documented
mechanism is the first place to look and it is not where the pixels come from. It also means the wakeup
coalescing in `GhosttyCallbacks.wakeup` is doing something narrower than the comment implies.

Not urgent and nothing is visibly broken, which is why this is `later` rather than `yes`. Worth pinning
down before trusting either sentence again: confirm against a second instance and a longer run before
concluding "never", since one instrumented session cannot distinguish never from rarely. If it is
confirmed, the choice is deleting `renderNow` and its arm or documenting them as a path the pinned
build does not exercise - not silently leaving both.

Surfaced while instrumenting the display-sleep surface-creation bug (#416, fixed in #417); the probes
were added for that and this fell out of the same log.
