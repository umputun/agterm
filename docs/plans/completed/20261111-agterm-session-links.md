# Session links

## Overview
- A ⌘-click on an OSC 8 link to `agterm://session/<uuid>` underlines on hover and does nothing, so an agent cannot
  print "jump to that session" for the user (discussion #958).
- Fix: recognize that one link form in `LinkPolicy`'s terminal routing for pane, split and scratch clicks and carry it
  out in-process. A click raises the destination window, makes it frontmost, selects the row and focuses it, through
  the gated part of `AppActions.selectAttention`, with no confirmation, the same as an http click.
- A pane attached from another Mac resolves that Mac's id to exactly one local row.
- Out of scope, agreed in #958: HUD links, macOS scheme registration, a control command, any confirmation, and any
  change to `LinkPolicy.disposition`, `HudMarkdown.linkTarget` or the system opener.

## Context (from discovery)
- Routing is host-free in `agtermCore/Sources/agtermCore/LinkPolicy.swift`: `disposition(for:)` (also read by
  `HudMarkdown.linkTarget`) and `route(for:mode:origin:)`, which adds the click origin. `ClickOrigin` is
  `.pane(UUID)`, `.remotePane(UUID)`, `.scratch(UUID)`, `.hud`, `.programOverlay`, `.quick`; a split pane reports its
  row's `.pane`/`.remotePane` (`GhosttySurfaceView.linkClickOrigin`) and passes its own identity as `pane`
  (`linkClickPane`; nil for the scratch).
- `agterm/Ghostty/LinkOpener.swift` carries out a `Route`. `follow` goes straight to `carryOut` when
  `LinkPolicy.locations` offers no candidates, which is the case for `agterm://…`, since its first segment holds a colon.
  `carryOut` reveals `route.localFile` on a ⌘⌥ click and otherwise falls through to the route's normal action.
- Exhaustive `switch`es over `LinkPolicy.Route` sit in `LinkOpener.carryOut`, `Route.localFile`,
  `ControlServer+ForwardedClick.swift` `openForwardedRoute` (the app's reverse `link.click` receiver), and
  `AgtermServerKit/ServerStreams.swift` `clickedPage` (the headless server's). Both receivers refuse every non-page
  route with `.notAPage`.
- `AppActions+Focus.swift` `selectAttention(windowID:sessionID:)` runs `canSelectAttention` (`uiActionsEnabled(for:)`:
  no terminal zoom, no open dashboard, no pending modal pick, and the row must exist), raises and fronts a non-active
  window, notes activity, selects, then `revealActiveBlockedPane`. That last step can show or hide the scratch, and in a
  remote window a scratch change is a command to the server. `focusActiveSession()` is the plain focus.
- Attached rows: `Session.remoteHost` and `Session.remotePresentation?.binding` (`RemoteBinding`: `remoteSessionID`,
  `origin?.endpoint`, `catalogOwned`, `remotePane(forLocal:)`, nil for a split running on this Mac).
  `ControlServer.attachedParentRows` matches a row to an origin session by host, `remoteSessionID` and endpoint.
  A remote window's rows (`AppStore+Catalog.swift` `catalogBinding`) reuse the origin id as the row id, have
  `catalogOwned == true`, and their scratch runs on the server. A per-session attached row has a new local id, and its
  scratch is a local shell.
- `catalogBinding` built `origin` from `entry.panes.first` only. The server lists no pane for an ended session but keeps
  its running scratch, so a scratch-only row had `origin == nil`. `updateCatalogSession` returns before rebinding an
  ended row, so a scratch that arrives later needs its own origin refresh there. `PaneLead.launch` also reads
  `binding.origin`, but needs `binding.daemon(forLocalPane:)`, which a scratch daemon is never in.
- `WindowLibrary.swift` is at 992 of the 1000-line lint limit, so the resolver goes in a new extension file.
- `agtermCore` is a library the agterm-linux fork consumes, so the new public `Route` case is a source change for any
  exhaustive switch there, as `.forwardRemote` was.

## Development Approach
- **testing approach**: TDD: failing tests first, confirm they fail, then the change.
- complete each task fully before moving to the next; every task includes its tests.
- run only the touched tests while working (`swift test --filter`, `-only-testing:`); the full gates run once, at the end.

## Testing Strategy
- unit: `LinkPolicyTests` (scheme cases next to the existing ones), new `WindowLibrarySessionLinkTests` (remote-window
  rows come from a real catalog snapshot through `RemoteCatalogMirror`, so `catalogBinding` is under test),
  `RemoteCatalogMirrorTests`, `AgtermServerTests/ServerStreamsTests`.
- hosted: `GhosttySurfaceViewInputTests` (a real OSC 8 ⌘-click through libghostty), `ControlServerForwardedClickTests`,
  `AppActionsFocusTests` (a click raises another window), `ControlServerRemoteCompanionsTests`.
- no test talks to another Mac: attached rows are built with `bindRemote`, remote-window rows from a `CatalogSnapshot`.

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix, blockers with ⚠️ prefix

## Solution Overview

```
libghostty OPEN_URL "agterm://session/<id>"
  -> GhosttySurfaceView.openLink -> LinkOpener.follow(raw, origin, pane, intent)
  -> LinkPolicy.route: origin .pane/.remotePane/.scratch + sessionLink(raw) -> .selectSession(id)
  -> LinkOpener.carryOut: ⌘⌥ (reveal intent) -> nothing; else selectSession(id, origin, pane)
  -> AppActions.followSessionLink(id, from: origin, pane:)
       WindowLibrary.sessionLinkTarget(id, from:, pane:)   // namespace from the clicked pane's binding
       raiseAndSelect(windowID:, sessionID:)                // the gated half of selectAttention
       focusActiveSession()                                 // plain focus, no pane reveal
```

- The clicked pane says which Mac its shell runs on. A pane that runs here prints this Mac's ids, looked up as local row
  ids. A pane that runs on the origin prints that Mac's ids, matched to exactly one local row by host, endpoint and
  origin session id.
- The match is the predicate `attachedParentRows` already used, moved into `agtermCore` so both callers share it.

## Technical Details

**Link grammar** (`LinkPolicy.sessionLink(_:) -> UUID?`): the raw string is exactly `agterm://session/` followed by a
36-character hyphenated UUID, and nothing else. The prefix matches case-insensitively, the id goes through
`UUID(uuidString:)`. The check is on the raw string, not `URLComponents`, because Foundation parses
`agterm://session:/<id>` (an empty port) with `port == nil`. Rejected: a trailing `/`, `?` or `#`, user info, a port,
extra path components, an unhyphenated or braced UUID, and any other host such as `agterm://window/<uuid>`.

**Route**: a new case `selectSession(UUID)`; `localFile` is nil for it. `route(for:)` checks `sessionLink(raw)` first,
before the `.remotePane` forward check. From `.pane`, `.remotePane` or `.scratch` it routes to `.selectSession(id)` in
every `LinkOpenMode`; from `.hud`, `.programOverlay` or `.quick` to `.ignore`.
That is the boundary the overlay link-open setting already draws. The quick terminal is a panel that holds key above
every window, so a selection would change a window hidden behind it. A program overlay belongs to no shell the row's
binding describes, and in a remote window it can run on the server.
`disposition(for:)` is unchanged, so `HudMarkdown.linkTarget` and the system opener see nothing new.

**Shared origin match**: `Session.showsOriginSession(_:host:endpoint:)` in the new `WindowLibrary+SessionLink.swift`,
true when `remoteHost`, `binding.remoteSessionID` and `binding.origin?.endpoint` all match. `attachedParentRows` calls it
in place of its inline comparison and keeps its `parentID == nil` filter.

**Scratch-only catalog rows**: `catalogBinding` takes the origin from `entry.panes.first ?? entry.fields.scratch?.pane`.
A live row is unchanged. An ended row whose scratch still runs now carries the server's endpoint, so a link from its
scratch resolves and a link to it resolves. `daemonsByLocalPane` still lists only `entry.panes`, so no pane reattach
starts from the scratch's origin. An ended row whose scratch arrives later gets the same origin from
`updateCatalogSession` through `RemoteBinding.replacingOrigin`, which keeps the row's pane mappings.
`attachedParentRows` keeps every row it matched before and gains that one row, which does present the origin session.

**Resolver** (`WindowLibrary.sessionLinkTarget(_:from:pane:) -> SessionLinkTarget?`, window and row ids):
1. the clicked row comes from the origin; a missing row, `.hud`, `.programOverlay` or `.quick` gives nil.
2. where the clicked shell runs: here when the row has no `remoteHost`; for `.scratch`, here unless the binding is
   `catalogOwned`; for a pane of a remote row, on the origin when the binding maps `pane`, here when it maps no such pane
   (a local split), and nil when there is no binding or no `pane`.
3. here: the open window holding a live row with that id, else nil. That covers unknown ids, closed windows and
   pending-close rows.
4. on the origin: every live row of every open window that `showsOriginSession` the id for the clicked row's host and
   endpoint. Exactly one match is the result; zero or several give nil. The local namespace is never consulted.

**App side**:
- `LinkOpener` gains a `selectSession(UUID, ClickOrigin, UUID?)` hook, and `carryOut` handles `.selectSession` with
  `guard !click.reveals`, so ⌘⌥ does nothing. ⌘⇧ selects like a plain click, as it already treats `mailto:`.
- both reverse receivers add `.selectSession` to their `.notAPage` refusals.
- `AppActions+Focus.swift`: `raiseAndSelect(windowID:sessionID:focus:)` is `selectAttention`'s gated half;
  `selectAttention` passes `revealActiveBlockedPane`, the new `followSessionLink(_:from:pane:)` passes
  `focusActiveSession()`. `selectSession` is the ordinary path, so `session.selected` hooks, unseen-badge clearing and
  auto-follow grace stand.
- `agtermApp.init` wires `LinkOpener.shared.selectSession` to `followSessionLink`.

**Printing the link**: `printf '\e]8;;agterm://session/%s\e\\%s\e]8;;\e\\\n' "$AGTERM_SESSION_ID" "back to this session"`,
or `[label](agterm://session/<id>)` in Claude Code markdown, which Claude Code emits as OSC 8. In a pane attached from
another Mac, `AGTERM_SESSION_ID` is that Mac's id, which this Mac resolves.

**Control API**: no new command. `session select` plus `window select` already reach the same outcome and read back
through `tree`. The click is a gesture, like the forwarded `link.click`, which `control-api.md` records as having no
control twin.

## Implementation Steps

### Task 1: Recognize, parse and resolve session links, and refuse them in both reverse receivers

**Files:**
- Create: `agtermCore/Sources/agtermCore/WindowLibrary+SessionLink.swift`
- Modify: `agtermCore/Sources/agtermCore/LinkPolicy.swift`, `AppStore+Catalog.swift`, `RemotePresentationState.swift`
- Modify: `agtermCore/Sources/AgtermServerKit/ServerStreams.swift`
- Modify: `agterm/Ghostty/LinkOpener.swift`, `agterm/Control/ControlServer+ForwardedClick.swift`
- Create tests: `agtermCoreTests/WindowLibrarySessionLinkTests.swift`
- Modify tests: `LinkPolicyTests`, `RemoteCatalogMirrorTests`, `AgtermServerTests/ServerStreamsTests`,
  `agtermTests/GhosttySurfaceViewInputTests`, `agtermTests/ControlServerForwardedClickTests`

- [x] failing tests first in `LinkPolicyTests`: every accepted spelling parses, every rejected one returns nil; `route`
      gives `.selectSession` from pane, remote pane and scratch in every mode and `.ignore` from HUD, program overlay and
      quick terminal; `disposition` of a session link stays `.ignore`; `localFile` is nil
- [x] `WindowLibrarySessionLinkTests` on a temporary library with two local windows and a remote window fed a real
      catalog: local ids resolve across windows; unknown, pending-close and HUD/overlay/quick give nil; an attached pane
      resolves an origin id in either case to the one row showing it and never a local id; a local split and a local
      scratch resolve local ids; a catalog scratch resolves origin ids; a scratch-only ended row resolves both ways,
      also when its scratch arrives later; two matches, another host or endpoint, no binding or no origin give nil
- [x] `RemoteCatalogMirrorTests`: an ended row that gains a scratch takes its endpoint and keeps its panes
- [x] both reverse receivers answer a session link with `.notAPage` (`ServerStreamsTests`, `ControlServerForwardedClickTests`)
- [x] hosted `GhosttySurfaceViewInputTests`: an OSC 8 session link ⌘-clicked through libghostty reaches `selectSession`
      with that id and a `.pane` origin; `.browser` and `.normal` select once each; ⌘⌥ and a HUD click select nothing
- [x] `LinkPolicy.sessionLink`, `Route.selectSession` and the `route(for:)` check
- [x] `Session.showsOriginSession`, `SessionLinkTarget`, `WindowLibrary.sessionLinkTarget`
- [x] `catalogBinding` scratch fallback and the ended-row origin refresh through `RemoteBinding.replacingOrigin`
- [x] `.selectSession` in both receivers' refusals; the `LinkOpener` hook and case
- [x] run the touched tests - must pass before task 2

### Task 2: Carry a session link out through the gated raise/select path

**Files:**
- Modify: `agterm/AppActions+Focus.swift`, `agterm/agtermApp.swift`, `agterm/Control/ControlServer+RemoteCompanions.swift`
- Modify tests: `agtermTests/AppActionsFocusTests`

- [x] failing tests first in `AppActionsFocusTests`: a link to a row in the back window makes it frontmost, shows it and
      selects the row; a row blocked on its scratch keeps the scratch hidden and one blocked on a split keeps a shown
      scratch shown, so no attention reveal ran; nothing changes under terminal zoom, an open dashboard, a pending modal pick, a failed raise, an unknown id or
      a ⌘⌥ click
- [x] `raiseAndSelect`, `selectAttention` over it, and `followSessionLink`
- [x] wire `LinkOpener.shared.selectSession` in `agtermApp.swift`
- [x] `attachedParentRows` through `Session.showsOriginSession`
- [x] run the touched tests, `ControlServerRemoteCompanionsTests` included - must pass before task 3

### Task 3: Docs, skill and rules

**Files:**
- Modify: `site/docs.html`, `plugins/agterm/skills/agterm/SKILL.md`, `.claude/rules/control-api.md`

- [x] `site/docs.html` links section: what a ⌘-click does, how to print the link, how an attached session's id
      resolves, and when nothing happens
- [x] `SKILL.md`: a `## Linking to a session` section, a `when_to_use` request and a `session links` trigger in
      `description`, kept within the 1024-character limit `SkillInstallTests` checks
- [x] `control-api.md`: one bullet owning the routing and namespace contract
- [x] full gates once: `make test`, `make test-app`, `make lint`, `scripts/build.sh`
- [x] move this plan to `docs/plans/completed/`

## Post-Completion
- Run the XCUITest scheme once, as `CONTRIBUTING.md` asks for a UI-behaviour change; it is not in CI and needs a machine
  left alone.
- Question for the maintainer: should the quick terminal or a program overlay carry the link? Both stay ignored here, as
  they are for the link-open overlay.
- The agterm-linux fork sees the new public `LinkPolicy.Route.selectSession` case in its exhaustive switches.
