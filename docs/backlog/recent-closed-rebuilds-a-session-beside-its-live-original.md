---
worth: later
where: agtermCore/Sources/agtermCore/AppStore+RecentClosed.swift:restoreOrSelectExistingRecentSession
added: 2026-09-07
---
# Recent Closed can rebuild a session into one window while its original is pending-close in another

Two live `Session` objects can carry the same UUID in two open windows, which breaks every lookup keyed on
a session id alone. `WindowLibrary.windowID(forSession:)` returns the FIRST window in index order holding
the id, so a caller asking about the copy is answered about the original.

Reproduced with public API and the default 3-second grace, no hand-edited state:

```swift
source.softCloseSession(original.id)            // held pending in A, out of A.workspaces
library.reopenLatestRecentClosed(into: other)   // B rebuilds it from the snapshot
source.undoPendingClose()                       // A's original returns to A's tree
// allOpenSessions() now holds two distinct Session objects under one id;
// store(forSession: copy.id) answers with A.
```

As a user: close a session, reopen it from Recent Closed into a different window inside the grace period,
then undo the close in the original window.

Every guard on that path is scoped to one store. `restoreOrSelectExistingRecentSession` asks
`pendingCloseID(containingSessionID:)` and `session(withID:)`, both `AppStore` methods, and the dedupe sets
in the workspace paths — `Set(workspaces.flatMap(\.sessions).map(\.id))` unioned with
`pendingHeldSessionIDs()` — see only the store doing the restoring. The hazard is already known one level
down: `restoreOrSelectExistingRecentWorkspace` carries a comment naming it exactly — "a session left pending
would be rebuilt from the snapshot beside its live original - two objects under one id" — and guards it
within a store. Nothing extends that check across open stores.

A fix has to make the pending-close and recent-closed checks library-wide rather than store-wide, which
touches both subsystems and their reselection behaviour, so it wants its own branch. Note that the two
windows' snapshots then both persist that id, so the repair has to decide which copy wins rather than only
preventing the second rebuild.

Surfaced by the review of the backlog-sweep branch. That branch fixed its own exposure — the sessionless
chord path now carries the owning store through the walk that matched the surface, and
`CustomCommandRunner.context(for:in:selectionSurface:pane:)` resolves the window with `windowID(for: store)`
rather than by session id — but every other `windowID(forSession:)` / `store(forSession:)` caller still
trusts the id to be unique.
