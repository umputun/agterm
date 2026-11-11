---
worth: later
where: agtermCore/Sources/agtermCore/WindowLibrary+SessionLink.swift:sessionLinkTarget
added: 2026-11-11
---
# session link to an ended remote-window row depends on whether the window was reopened

In a remote window, an `agterm://session/<id>` link to an ended catalog row with no scratch selects it only
when the row ended while the window was open. `updateCatalogSession`'s ended branch returns before the
`catalogBinding` rebind, so that row keeps its last pane origin and `showsOriginSession` matches it. After a
remote window reopen or an app relaunch the same row arrives already ended with no panes, `catalogBinding`
gives it a nil origin, and the link does nothing. A reconnect inside an open window keeps the binding.

The user cannot see which case a row is in. The consequence is a no-op on an "Ended on HOST" row, never a
wrong selection. Either uniform rule needs a decision: also match a catalog-owned row with the same host and
`remoteSessionID` when its origin is nil (only in `sessionLinkTarget`, leaving `attachedParentRows` alone,
and flipping the `empty` expectation in `WindowLibrarySessionLinkTests`), or exclude ended rows in both cases.
Surfaced reviewing https://github.com/umputun/agterm/pull/964.
