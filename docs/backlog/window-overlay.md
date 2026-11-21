---
worth: later
where: agtermCore/Sources/agtermCore/AppStore+HtmlOverlay.swift:htmlOverlaySlot
added: 2026-11-13
---
# window overlay: an HTML page owned by the window, shown with or without a session

Requested in https://github.com/umputun/agterm/discussions/989 (a launcher that lists folders and opens a
session there), but the feature is general: launchers, dashboards, any panel a user builds. Today every
HTML page belongs to a session (overlay slot, pane slot or page row), so nothing can be shown in a window
with no sessions, and a page over a session needs that session first. Postponed for its size, not doubt.

**Decided design**

- Behaves exactly like a session HTML overlay, owned by the window: full terminal area or a sized panel
  (same sizing flags), owns input while shown, sidebar stays usable, stays on top across session switches,
  `hide`/`show`/`toggle` keep its state (the dashboard case), closed by the strip button, Cmd-W or the
  page's `window.close()`.
- Same page powers as a session file page: `data-agterm` tags, `agterm.request` with `--js`, `--cwd` grant,
  `--block` with `session.overlay.submit`-style result through `HtmlPageOutcomes` (already keyed by page id).
- Draws above every session-level layer (program, page, HUD, terminal ask) without closing it; the
  session's own overlay stays underneath untouched.
- Full remote parity: a script inside a remote session (agterm-server or another Mac) opens it over the
  Mac window presenting that session.
- New wire commands (`window.overlay.open|close|hide|show|toggle|resize|reload|navigate|submit`), not a
  flag on `session.overlay.*`: an older app drops an unknown arg and would open on a session instead.
  `submitSessionOverlay` resolves a `Session`, so a window page needs its own submit; the page-id result
  poll (`session.overlay.result --page`) stays shared.
- A command the page leaves untargeted that addresses an existing session acts on the window's selected
  session and is refused when the window has none; creation and placement commands (`session.new`,
  `workspace.new`, already excluded from session defaults in `HtmlBridge`) keep their window defaults.

**Local work**

- Owner contract: `htmlOverlaySlot` (10 callers: registry, `LogFollower`, remote page, replica page,
  visibility) scans session slots only; it must also answer "the window". `HtmlBridgePage.session` is a
  non-optional UUID; `HtmlOverlayView`/`HtmlWebViewHost` take a `Session` (loading text, ask focus
  deferral); `updateHtmlOverlay` and close/reload callbacks resolve through the session lookup.
- Input: a window cover ahead of session focus routing. Keep `Session.coverOverlayVisible` and friends
  session-scoped; add the window cover at the window input boundary (`focusActiveSession`, split focus,
  `GhosttySurfaceView` focus retries, custom and built-in chords, Cmd-W ladder, auto-follow, quick terminal,
  pick/ask/zoom/dashboard precedence). `HtmlOverlayWebView.cancelOperation` absorbs Esc, so Esc does not
  close a page; keep that. `CustomCommandRunner.runNoSurface` runs a chord against the active session when
  a web view holds first responder: gate it while the window overlay is shown.
- Window teardown must settle `--block` as dismissed and release the web view.
- Read-back on the window node / tree top level (open, hidden, size, page id); `tree.changed` on real changes.

**Remote work** (largest part; codex's source map, 2026-11-13)

- Today `openRemotePage` reserves `session.remoteOverlays`, sends `PresentationPage` through the session's
  presenter, and `showReplicaPage` mounts another session slot; file and content pages travel
  `RemotePageChannel` -> page-serve -> `PageServeStream`, public URLs load directly.
- The transport can carry every source. Ownership cannot: removing the routing row stops its client, and
  claims, bridge lookup and command/state/end replies use that session's presenter generation and stream.
  A window-owned page needs an owner-held control connection and origin reservation independent of the
  row, an explicit window placement scope (pane nil already means session-wide) and a negotiated presenter
  capability kind.
- Use the caller's session only to find the presenter and window, then pin the accepted `WindowInfo.ID`
  (origin window and catalog ids are not viewer window ids). Show over the current detail without
  selecting the routing session.
- On window close, dismiss at the origin before releasing transports: a server channel EOF withdraws and
  requeues the page, leaving `--block` pending, while a Mac channel loss ends it.
- Source costs: HTML with grant, image, markdown and static text already have transfer and render
  formats; log/search/wrap callbacks need owner adaptation; loopback URLs stay refused from a Mac origin.
  Non-HTML sources never gain the control bridge.

**Rejected:** an `agtermctl pick --html` modal (a pick-shaped page that only returns a value). It fit the
requester's launcher but named a general overlay after the mechanism it reused and could not drive
agterm itself. Today's workaround for a launcher is a sessionless keymap chord plus `agtermctl pick`
(window-scoped, works with zero sessions) and `session new`.

**Related, separate change:** `workspace new` has no `--after`/`--before` placement (`AppStore.addWorkspace`
appends; `workspace move` steps only up/down/top/bottom), which the launcher case also needs. Small
locally; a remote window forwards `workspace.new` to agterm-server, whose catalog needs the same insert.
