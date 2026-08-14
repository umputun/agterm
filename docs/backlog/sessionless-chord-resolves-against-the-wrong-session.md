---
worth: later
where: agterm/Commands/CustomCommandRunner.swift:252
added: 2026-08-13
---
# a chord fired in a sessionless surface resolves against whichever session is active

`runFromKeybind` keys off the surface that held first responder at key-down, which is what lets a chord
report the pane it was typed in before the focus flag catches up. A sessionless surface has no
`view.session` to key off, so `runFromSessionlessSurface` matches it against `library.activeStore`'s
`activeSession` instead, and `runNoSurface` falls back to the same session when that match fails.

`selectedSessionID` moves ahead of the asynchronous focus handoff. In that interval a chord fired in
session A's scratch or overlay is matched against session B, fails every identity check, and
`runNoSurface` builds the context from B: `$AGT_SESSION_ID`, `$AGT_SESSION_PWD`, `$AGT_PANE` and
`$AGT_SELECTION` all describe a session the user was not looking at. A command that types back through
`session type --pane "$AGT_PANE"` therefore writes into the wrong shell, and one that reads
`$AGT_SESSION_PWD` runs against the wrong directory.

The fix is to resolve the firing surface across every open store rather than against the active session
alone, which is a search `WindowLibrary` does not currently offer for surfaces. Deferred for that reason
rather than difficulty: the window is narrow, nobody has reported it, and widening surface lookup touches
every caller of the active-store idiom.

Predates the overlay work: the same lookup carried the scratch alone before `session.overlay.copy`/`.text`
landed, and an overlay chord already fell through to `runNoSurface` and took B's context. Verified against
`3624dd0`. Surfaced by the review of the #434 branch, which classified it as pre-existing on both sightings.
