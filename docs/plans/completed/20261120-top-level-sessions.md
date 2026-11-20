# Top-Level Sessions Outside Workspaces

## Overview
- Let a session sit at the top of the sidebar, outside any named workspace, with drag and drop, menus and every
  ordinary session operation working on it.
- Internally every such session belongs to one implicit root container per owner (a Mac window's store, or an
  agterm-server catalog), so every session keeps exactly one owner and the existing ownership, move, undo, snapshot
  and catalog paths stay one shape.
- User-facing name: "Top-Level Sessions". Scripts see the root as a marked node in `tree` and address it as `root`.

## Context (from discovery)
- Model: `agtermCore/Sources/agtermCore/Workspace.swift`, `AppStore.swift` (`workspaces`, `currentWorkspaceID` at
  :334, `canRemoveWorkspace` at :704, `removeWorkspace`, `defaultWorkspaceName`), `AppStore+Focus.swift`,
  `AppStore+FlaggedOrder.swift`, `AppStore+SidebarSelection.swift`, `AppStore+SessionMoves.swift`,
  `AppStore+Snapshot.swift`, `AppStore+RecentClosed.swift`, `AppStore+PendingClose.swift`, `AppStore+Catalog.swift`.
- Persistence: `Snapshot.swift` (`WorkspaceSnapshot`, custom decoder), `WindowLibrary.swift`.
- Control: `ControlProtocol.swift`, `ControlDispatcher.swift`, `ControlActions.swift`, `ControlProjection.swift`
  (`ControlWorkspaceNode`, visibility formula at :705), `ControlResolve.swift` (UUID, prefix or `active`; "root" is
  not hex, so no collision), `agterm/Control/ControlServer+WorkspaceCommands.swift`, `+SessionActions.swift`,
  `+WindowCommands.swift`, `+Zmx.swift`, `+RemoteSessionNew.swift`, `ControlTargetResolver.swift`, `agtermctlKit`.
- Remote: `CatalogFrames.swift` (`CatalogWorkspace`, `workspaceAdded`, hello `protocolVersion`), `CatalogDiff.swift`,
  `CatalogRoot.swift` (`seedWorkspace` guards on an empty `workspaces`), `CatalogProjection.swift`, `RemoteTree.swift`,
  `RemoteOperation+Request.swift`, `RemoteCatalogMirror*.swift`, `RemoteWindowViewState.swift`,
  `AgtermServerKit/AgtermServer.swift` (loads `workspaces.json` only when it exists, then seeds at :86),
  `ServerActions+*.swift`, `agterm/Control/ControlServer+MacCatalog.swift`, `+RemoteActions.swift` (`routedStore`),
  `+AttachedRecent.swift`, `agterm/AppActions+RemoteCatalog.swift`.
- Sidebar: `agterm/Views/WorkspaceSidebar.swift`, `+DragDrop.swift` (session drop refuses a nil item; root slots are
  treated as workspace slots; remote drag allows one session at :52), `+ContextMenu.swift`, `SidebarDrop.swift`.
- Menus and actions: `agterm/agtermApp+Menus.swift`, `AppDelegate+DockMenu.swift`, `AppActions.swift`,
  `AppActions+WorkspaceFocus.swift`, `AppActions+Palette.swift`, `AppActions+RemoteAttach.swift`,
  `PaletteCatalog.swift` (`PaletteContext` enablement, Edit Focused Workspaces), `BuiltinAction.swift`,
  `CustomCommand.swift` (`{AGT_WORKSPACE_NAME}`), `agterm/Views/WindowContentView+Titlebar.swift`.
- Size: `workspaces` has 501 references in 109 files: about 157 lookups that must include root and about 165 index,
  count, first/last or subscript uses that are mostly named-workspace index space.
- Precedent: the flat and plain flagged lists already draw sessions as top-level rows (`listsSessionsFlat`).

## Development Approach
- **testing approach**: TDD. Host-free `agtermCore` tests first for each store, drop, control and catalog rule, then
  the code; hosted/UI tests for what only AppKit shows.
- each task runs only the tests it touches (`swift test --filter`, `-only-testing:`); existing tests that pin a
  contract the task changes are rewritten to the new contract in that task, never deleted.
- full gates once at the end: `cd agtermCore && swift test`, `make test-app`, `make lint`.
- update this plan when scope changes during implementation.

## Testing Strategy
- **unit tests** (`agtermCoreTests`, `AgtermServerTests`, `agtermctlKitTests`): every store, snapshot, drop, control
  and catalog rule below gets a table-driven case, success and refusal.
- **hosted/UI tests**: sidebar rendering and drag of the root block, row menus, File menu item, focus filter with
  root; targeted `-only-testing:` runs only.

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with an "added:" prefix
- document issues and blockers with a "blocked:" prefix

## Solution Overview
- **Model.** The root is a `Workspace` inside the stored `workspaces` array with an `isRoot` marker, kept LAST in the
  array, drawn FIRST in the sidebar. A computed `namedWorkspaces` view serves every named operation. Root last keeps
  every named index unchanged (`workspace.move` indices, saved Recent Closed placement, catalog positions);
  named appends, moves and reopen insert before the root.
- **Call-site audit by meaning.** Session lookup and session mutation include the root. Named-workspace operations
  (numbering, navigation, counts, rename, tint, delete, detach, collapse, workspace targets, workspace drag) exclude it,
  including when they resolve by ID, so a workspace operation can never act on the root.
- **Display order.** Root sessions first, then named workspaces in order. Session navigation, MRU candidates,
  flagged-tree order and mixed-selection moves follow display order, never raw storage order.
- **One root per owner.** The owning Mac store or agterm-server creates it on load when absent, never removes it, and
  persists it even when empty. A remote window's store never mints one: it takes only the origin's marked root from
  the catalog, and an older origin without the marker has no root.
- **Read-back with the root.** Task 1 makes the root visible everywhere it is read (`tree` node, catalog marker and
  mirror adoption, `zmx.tree`, the sidebar block) and lands the root's guards with it. From Task 1 the existing
  UUID-based placement (`session.new`/`session.move` with the root's UUID) works, since the block already renders;
  every named-only workspace command refuses the root's UUID, prefix or `active` from the same checkpoint, on the Mac
  and on remote owners. `workspaces.last` and the keep-one counts read named workspaces at Task 1, so minting the root
  changes neither the creation fallback nor last-workspace deletion until Task 3 changes them on purpose.
- **Sidebar.** An unindented block of root session rows above the first workspace row. The gap above the first
  workspace row is a root drop target whenever the root is in the displayed scope, an empty visible root and an empty
  outline included; while the focus filter hides the root there is no root gap, and Move to still names it. Flagged
  layouts ignore workspace focus; flagged-tree drag follows its existing membership placement rules, and flat/plain
  drag only changes flagged order.
- **Focus.** The root is a focus member like any workspace (its UUID in `focusedWorkspaceIDs`). While the filter is
  on, root sessions show only when the root is a member.

## Technical Details
- **Decisions (Eugene, this session):**
  - deleting the last named workspace is allowed; a window may hold only root sessions or nothing;
  - new sessions go to the active session's container, root included;
  - when exactly one focused container is visible and the selected session is hidden, New Session goes to that
    visible container (fixes the same defect for named workspaces today);
  - a new window follows its source: a root session active in the source puts the new window's first HOME shell at
    root, otherwise Workspace 1 as today; a saved window with zero named workspaces reopens as saved;
  - root sessions hide under the focus filter unless the root is focused; the root is focusable from API, CLI and UI;
  - File menu New Top-Level Session, palette entry, keyless built-in `new_root_session`; no footer button;
  - scripts see the root in `tree`;
  - a root session shows no workspace name anywhere: the titlebar Workspace name element, the Recent Closed
    subtitle and the Attach Remote picker omit the name and its separator; `{AGT_WORKSPACE_NAME}` expands empty;
  - an older viewer of a newer origin sees the root as an unnamed workspace and gets the origin's refusals for
    workspace actions on it; nothing is hidden by protocol version.
- **`currentWorkspaceID` (creation destination)**: fresh workspace, else the sole visible focused container when the
  selected session is hidden, else the selected session's container (root included), else the last named workspace,
  else the root.
- **`active`**: one rule. `active` resolves to `currentWorkspaceID`, root included. Named-only commands refuse a root
  result and never substitute the last named workspace; `workspace.focus` and `workspace.flag` act on the root. The
  GUI matches: with a root session active, Rename/Delete/Collapse Workspace are disabled through the shared
  `PaletteContext` enablement predicate. The root node's `active` field reads true exactly when `active` resolves to it.
- **Workspace navigation**: `workspace.go` and Previous/Next Workspace step named workspaces in `visibleWorkspaces`
  order; the root is not a stop and `workspace.go` stays targetless, so it works from a root session: next lands on the
  first visible named workspace and previous on the last; with no visible named workspace the existing `no other
  workspace to navigate to` error stands.
- **New window source per caller**: File menu and palette take the frontmost window's active session; `window.new`
  takes the frontmost window the same way, so GUI and control agree; the Dock menu has no source and seeds Workspace 1;
  a remote window as the source seeds Workspace 1, since the new window is local.
- **Snapshot**: `WorkspaceSnapshot.root: Bool?`, decoded in the custom decoder, written only for the root, empty root
  included. A legacy file without it decodes unchanged and gains an empty root.
- **Recent Closed / pending close**: a closed root session records its container role, so reopen into another window
  (owner not open) lands in that window's root instead of rebuilding a named workspace shell. Attached rows carry the
  same viewer-side role through `RemoteRecentClosedItem.Placement` and `ControlServer+AttachedRecent`, so an attached
  session closed at root reopens at the destination root, companion-parent routing unchanged; the forwarded undo path
  shares that reattach helper.
- **agterm-server seeding**: a server is fresh when `workspaces.json` does not exist at startup. Load first, mint the
  root when absent, then seed Workspace 1 only on a fresh server. A loaded file holding only the root reseeds nothing.
- **Keep-at-least-one sites** that change to "named workspaces only, zero allowed": `AppStore.canRemoveWorkspace`,
  `AppStore+Catalog.canCloseWorkspace` (remote branch counts named mirrored workspaces),
  `RemoteCatalogMirror+Detach.canTerminateWorkspace` (counts named catalog workspaces), the
  `AppActions+RemoteCatalog` message, the `softRemoveWorkspace` doc in `AppStore+PendingClose`, the
  `ServerActions+Workspaces` refusal, and the `workspace.delete` refusal. Tests pinning the old refusal
  (`ServerActionsWorkspacesTests` at :35, `ControlAPIUITests` at :872) are rewritten to the new contract.
- **Control**:
  - `tree.workspaces[]` includes the root node with `root: true` and an empty name; its `focused` and `active` fields
    are reported like any workspace's, `focused` even when the root is empty. The `ControlWorkspaceNode` visibility
    formula gains the root's case (its sessions are visible under the same tree/filter/flagged terms, with no row).
    Older readers see an ordinary group, which is the accepted trade-off.
  - `--workspace root` is accepted by every command that takes a session destination argument: `session.new`,
    `session.move`, `zmx.attach` and `zmx.attach.group`. Before/after take the anchor's container; up/down/top/bottom
    stay inside the source container.
  - `session.remote.new` keeps taking no workspace argument; it attaches into `currentWorkspaceID`. When that is the
    root and no `--workspace-name` is given, the origin creates in its own root (`--workspace root`, no
    `--create-workspace`); an origin without root support refuses before creating. An explicit `--workspace-name`
    keeps creating or reusing that named workspace on the origin while the row attaches locally into the root. GUI New
    Remote Session follows the same rule.
  - `workspace.focus --target root` (all four modes), `workspace.flag --target root` (all root members, companions
    included); the literal resolves in the chosen window, frontmost by default, through `ControlTargetResolver`.
  - root rejected for rename, tint, delete, move, collapse, expand, detach, reattach and select, including by UUID,
    prefix or `active`. `workspace.filter` stays window-wide and targetless.
  - `ControlServer+RemoteActions.routedStore` resolves `root` before dispatch for every workspace command it routes,
    so a remote window's request reaches the catalog owner instead of acting on the viewer's copy.
- **Remote**: the root marker travels in catalog snapshots and `workspace.added` deltas, is restored in the mirror, and
  appears in `zmx.tree` discovery. A remote window routes root moves and creation to the owner with the owner's root
  container ID (named so to stay apart from the `CatalogRoot` type and `catalogID`). A host without root support
  refuses before mutation, nothing falls back to a named workspace, and New Top-Level Session, the palette row, Move to
  Top-Level Sessions and the focus-editor entry are disabled in a remote window whose owner has no root. Focus and
  filter stay viewer-owned (`RemoteWindowViewState`); bulk flag is origin-owned, so agterm-server gains root flagging
  and no focus state. Remote drag keeps today's one-session limit.
- **Older viewer state**: an older Mac may detach the unnamed root locally and save its ID in
  `RemoteWindowViewState.detachedWorkspaces`. On adopting a marked root, an upgraded viewer prunes that ID from the
  workspace-level detach state and keeps individual session detaches.

## What Goes Where
- **Implementation Steps**: code, tests and docs in this repo.
- **Post-Completion**: manual checks in a Debug instance and agterm-linux follow-up.

## Implementation Steps

### Task 1: Root container: model, persistence, provisioning and read-back

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Workspace.swift`, `AppStore.swift`, `AppStore+Snapshot.swift`, `AppStore+Focus.swift`,
  `AppStore+FlaggedOrder.swift`, `AppStore+SidebarSelection.swift`, `AppStore+SessionMoves.swift`, `AppStore+Recency.swift`,
  `AppStore+CloseReselection.swift`, `AppStore+Catalog.swift` (`prepareCatalogWorkspaces`), `Snapshot.swift`, `WindowLibrary.swift`,
  `ControlProjection.swift`, `CatalogFrames.swift`, `CatalogDiff.swift`, `CatalogProjection.swift`, `CatalogRoot.swift`
  (`seedWorkspace`), `RemoteTree.swift`, `RemoteCatalogMirror*.swift`, `RemoteWindowViewState.swift`,
  `AgtermServerKit/AgtermServer.swift` (seeding order), `AgtermServerKit/ServerCatalog.swift`, `ServerActions+Workspaces.swift`,
  `ServerActions+Flags.swift` (tint), `AppStore+RecentClosed.swift`, `AppStore+PendingClose.swift` (named-count clamps),
  `AppStore+Naming.swift`, `AppStore+Tint.swift`, `RemoteCatalogMirror+Detach.swift`, `agtermctlKit/SocketClient.swift` (`formatTree`),
  `agterm/Control/ControlServer+Tint.swift`, `agterm/AppActions+Palette.swift` (Move Session to, Edit Flagged Sessions rows),
  `agterm/SessionSwitcher.swift`, `agterm/Views/WorkspaceSidebar.swift`, `WorkspaceSidebar+FlaggedLayout.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/WorkspaceTests.swift`, `SnapshotRoundTripTests.swift`, `AppStoreTests.swift`,
  `AppStoreFocusTests.swift`, `ControlDispatcherWorkspaceTests.swift`, `CatalogRootTests.swift`, `CatalogFramesTests.swift`, `CatalogDiffTests.swift`,
  `RemoteCatalogMirrorTests.swift`, `WindowLibraryTests.swift`, `ControlProtocolTests.swift`; `AgtermServerTests/ServerActionsTests.swift`;
  `agtermUITests/ControlSidebarStatusUITests.swift` (targeted rendering case; it has the control-socket harness
  `SidebarUITests` lacks)
- Also modified: `AppStore+Root.swift` (new), `AppStore+Naming.swift` (`listSubtitle`), `PaletteCatalog.swift`,
  `agterm/AppActions.swift`, `agterm/Control/ControlTargetResolver.swift`, `ControlServer+WorkspaceCommands.swift`,
  `ControlServer+Detach.swift`, `agterm/Views/WindowContentView+RecentSessions.swift`, `WorkspaceSidebar+Companions.swift`;
  tests `AppStoreRootTests.swift` (new), `AppStoreCompanionsTests.swift`, `AppStoreNameSanitizeTests.swift`, `RemoteTreeTests.swift`,
  `OriginCatalogTests.swift`, `PaletteCatalogTests.swift`, hosted `WorkspaceSidebarTests.swift` (new),
  `ControlServerWorkspaceCommandsTests.swift`, `WorkspaceFocusActionsTests.swift`, `AppActionsPaletteTests.swift`,
  `SidebarFlaggedLayoutTests.swift`

- [x] audit every `workspaces` reference by meaning before changing code (lookup/mutation includes root, named
  operation excludes it even when it resolves by ID); record the result in this plan as a per-file list naming the
  owning task
  - result (501 sites): 196 lookup and 80 by-ID mutation need no change; 28 named-only, 40 projection, 50 persistence,
    104 remote. Named-only sites by owning task:
    - Task 1: `AppStore.swift` (`selectWorkspace`, `defaultWorkspaceName`, `addWorkspace` inserts before the root,
      `workspace(named:)`, `canRemoveWorkspace`, `removeWorkspace`, `moveWorkspace`, `reorderWorkspace`,
      `setWorkspaceExpanded`, `setWorkspacesExpanded`, the `workspaces.last` fallback), `AppStore+PendingClose`
      (`softRemoveWorkspace` refusal; the rebuilt-shell inserts at :546 and :602 clamp to the named count),
      `AppStore+RecentClosed` (rebuilt shell at :33 and reopened workspace at :72 clamp to the named count),
      `AppStore+Catalog.canCloseWorkspace`, `AppStore+Naming.renameWorkspace`, `AppStore+Tint.setTint(forWorkspace:)`,
      `RemoteCatalogMirror+Detach.canTerminateWorkspace`, `CatalogRoot.seedWorkspace` (fresh-server signal)
    - Task 2: `WorkspaceSidebar+DragDrop` remote `workspaceStep` count and `resolveWorkspace` count
    - Task 1 (moved from Task 3): `AppActions.deleteWorkspace` refuses the root before `closeRemoteWorkspace`'s chooser;
      Delete, Rename and Collapse/Expand Workspace are disabled through `PaletteContext.activeWorkspaceIsRoot`
    - Task 4: the root-role reopen paths in `AppStore+RecentClosed` and `AppStore+PendingClose`
  - projection sites using display order (root first) land in Task 1: `AppStore+Focus` (`visibleWorkspaces`,
    `navigableSessions`), `AppStore+CloseReselection`, `AppStore+FlaggedOrder`, `AppStore.swift` reselection,
    `AppStore+PendingClose` reselection, `persistedSelection` and `RemoteCatalogMirror.selectRow` first-session
    fallbacks; sidebar, palette (`AppActions+Palette` Move Session to and Edit Flagged Sessions rows),
    `SessionSwitcher` and `agtermctlKit/SocketClient.formatTree` (root printed as a top-level block) also in Task 1
  - shared workspace resolvers stay root-inclusive (`ControlTargetResolver`, `ServerActions+Workspaces`,
    `RemoteOperation+Request`); their named callers refuse the root; `ControlServer+Tint`, `ServerActions+Flags` tint
    and `AgtermServerKit/ServerCatalog` (root marker) join Task 1
- [x] tests first: a local store has one root after load and after legacy decode; a remote-window store has none after
  load; root stays last on named append and move; root never removed; `defaultWorkspaceName` counts named only
- [x] tests first: the root is minted by `ensureRoot()` at the ownership boundary (local window load, legacy migration,
  new window, agterm-server start), folding duplicates and keeping it last; a store built directly has none
- [x] tests first: the root is a focus member from Task 1: `workspace.focus` by the root's UUID marks it, the filter hides
  root sessions unless the root is a member, and root-only focus never falls back to every named workspace
- [x] tests first: loading a pre-root per-window snapshot persists the minted root, so a reopen from disk with no
  session or workspace edit returns the same root ID; the one-shot capture strip still runs; the mint is saved only
  when the file decoded or is missing, so an existing undecodable window file survives the load byte for byte
- [x] tests first: `navigateWorkspace` steps named workspaces only, so Next from the last named workspace wraps to the
  first named one and never lands on the root (entry from a current root stays Task 3's)
- [x] tests first: Delete Workspace is disabled through `PaletteContext` when the active container is the root, and
  `AppActions.deleteWorkspace` refuses the root before `closeRemoteWorkspace`'s chooser (keep-one change stays Task 3)
- [x] the focus editor lists the root as "Top-Level Sessions", never a blank entry
- [x] ➕ tests first: page sessions work in the root as in a workspace: `session.page` anchored on a root session places
  the page in the root and saves it there with its page snapshot; `session.move` by the root's UUID carries a page in
  (Mac and agterm-server share `addPageSession`)
- [x] tests first: snapshot round trip with an empty root and with root sessions; legacy file unchanged on decode; root
  written only for the root
- [x] tests first: display order drives `navigableSessions`, MRU candidates, flagged-tree order, mixed-selection moves
  and close reselection
- [x] tests first: agterm-server seeds Workspace 1 only when `workspaces.json` was absent; a restart with only the root
  reseeds nothing
- [x] tests first: `tree` root node (`root: true`, empty name, `focused` and `active` fields, visibility formula); root
  marker in catalog snapshot and `workspace.added` delta; mirror adopts only the origin's marked root and never mints
  one for an older peer; `zmx.tree` discovery; an upgraded viewer prunes a saved root ID from `detachedWorkspaces` and
  keeps session detaches
- [x] tests first: every named-only workspace command (rename, tint, delete, move, collapse, expand, detach, reattach,
  select) refuses the root's UUID, prefix and `active` on the Mac and on agterm-server; `session.new`/`session.move` by
  the root's UUID place a session in the root; the creation fallback and the keep-one rule count named workspaces only
- [x] implement `isRoot`, `namedWorkspaces`, the one-root invariant for stores that own their tree, `WorkspaceSnapshot.root`,
  the root guards and named-only refusals,
  server seeding order, the tree and catalog root, mirror adoption and detach pruning; render the root block above
  workspace rows in the ordinary and flagged tree (flat/plain lists drop the workspace suffix for root sessions), honoring
  the focus filter
- [x] show Eugene the rendered block in a Debug instance (a root session placed by UUID), then a targeted rendering
  UI test
- [x] update existing count, tree, snapshot and catalog tests to the new contract; targeted tests green before Task 2

### Task 2: Sidebar drag, Move to and row menus

**Files:**
- Modify: `agterm/Views/WorkspaceSidebar+DragDrop.swift`, `WorkspaceSidebar+ContextMenu.swift`, `agterm/Views/WindowContentView+Titlebar.swift`,
  `agterm/AppActions+RemoteAttach.swift`, `agtermCore/Sources/agtermCore/SidebarDrop.swift`, `RemoteOperation+Request.swift`,
  `OriginCatalogScope.swift`, `AgtermServerKit/ServerActions+Moves.swift`, `ServerActions+Sessions.swift`, `ServerCommandPolicy.swift`,
  `agterm/Control/ControlServer+MacCatalog.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/SidebarDropTests.swift`, `RemoteOperationRequestTests.swift`, `OriginCatalogScopeTests.swift`;
  `AgtermServerTests/ServerActionsTests.swift`; `agtermUITests/SidebarUITests.swift`, `ReorderUITests.swift`, `FocusWorkspaceUITests.swift`

- [x] tests first (`SidebarDropTests`): gap above the first workspace row resolves to root while the root is in the
  displayed scope, empty root and empty outline included, and does not exist while the filter hides the root; reorder
  within root; drag in and out; a parent moves with its companions; workspace drag index counts named workspaces only,
  with the highlight offset by rendered root rows (root parents counted once); validate and accept agree on the gap at
  the end of the root block
- [x] tests first: remote move to and from root by the owner's root container ID, empty root included, detached
  sessions counted; a host without root support refuses before mutation; no fallback to a named workspace
- [x] session drops accept the root slots; remote windows drag a single session into, out of and within the root
- [x] row menus: Move to lists "Top-Level Sessions" (disabled when a remote owner has no root); root session rows get
  Focus/Unfocus Top-Level Sessions and Add/Remove Top-Level Sessions to Focus; workspace-only items never act on root
- [x] the titlebar Workspace name element and the Attach Remote picker omit the name for a root session
- [x] ➕ from review: a Finder folder dropped on a root session row opens in the root; a viewer drop into an
  all-detached root goes to the owner's root ID; both Move to menus use display order and `Workspace.label`
- [x] targeted UI tests for drag in/out, Move to and focus (in `ReorderUITests`, which has the fixture seeding);
  targeted tests green before Task 3

### Task 3: Creation destination, last-workspace deletion, focus, navigation and new windows

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift` (`currentWorkspaceID`, `canRemoveWorkspace`), `AppStore+Focus.swift`,
  `AppStore+Catalog.swift` (`canCloseWorkspace`), `AppStore+PendingClose.swift` (`softRemoveWorkspace` doc), `RemoteCatalogMirror+Detach.swift`
  (`canTerminateWorkspace`), `RemoteSessionCreate.swift`, `PaletteCatalog.swift` (`PaletteContext` enablement), `WindowLibrary.swift`
  (`newWindow` source), `AgtermServerKit/ServerActions+Workspaces.swift`, `agterm/AppActions.swift`, `agterm/AppActions+WorkspaceFocus.swift`,
  `agterm/AppActions+RemoteCatalog.swift`, `agterm/AppDelegate+DockMenu.swift`, `agterm/Control/ControlServer+WindowCommands.swift`,
  `+RemoteSessionNew.swift`, `+WorkspaceCommands.swift`, `+SessionActions.swift`, `RemoteWindowViewState.swift`, `ControlDispatcher.swift`,
  `ControlResolve.swift`, `AgtermServerKit/ServerActions+Sessions.swift`, `agtermctlKit` (`--workspace root` help for `session new`)
- Modify: `AppStoreCurrentWorkspaceTests.swift`, `AppStoreFocusTests.swift`, `PaletteCatalogTests.swift`, `WindowLibraryTests.swift`,
  `RemoteSessionCreateTests.swift`, `RemoteCatalogMirrorTests.swift`; `AgtermServerTests/ServerActionsWorkspacesTests.swift` (rewrite
  the :35 refusal case); `agtermTests/ControlServerRemoteSessionNewTests.swift`; `agtermUITests/ControlWindowUITests.swift` (one
  targeted `window.new` case), `ControlAPIUITests.swift` (rewrite `testWorkspaceDeleteLastErrors` at :872)

- [x] tests first: destination order (fresh, sole visible focused container with hidden selection, selected session's
  container, last named, root), for root and for an empty named workspace
- [x] tests first: when `currentWorkspaceID` resolves to the root, New Session goes there and named-workspace actions
  report disabled through `PaletteContext` while their store methods refuse the root; the last-named fallback applies
  only with no fresh workspace, no focused-container override and no selected session; with no named workspace, root
- [x] tests first: deleting the last named workspace succeeds locally, in a remote window and on agterm-server
  (`canRemoveWorkspace`, `canCloseWorkspace`, `canTerminateWorkspace`, the server refusal), with the GUI message updated
- [x] tests first: `session.new --workspace root` resolves on the Mac and on agterm-server, so an origin of the same
  revision accepts what the next item sends
- [x] tests first: `session.remote.new` and GUI New Remote Session from a root destination send the origin
  `--workspace root` without `--create-workspace`, an explicit `--workspace-name` keeps today's argv, and the row
  attaches locally into the root; an origin without root support refuses before creating
- [x] tests first: root focus through `commitFocus` restore pruning, empty-set rule and selection outside the set
- [x] tests first: workspace navigation from a root session (next to first visible named, previous to last, root never
  a stop, the existing error with no visible named workspace)
- [x] tests first: new window per caller (File menu/palette and `window.new` follow the frontmost window's active
  session; Dock and a remote source seed Workspace 1); a saved zero-named-workspace window reopens as saved
- [x] ➕ from review: the `root` alias resolves in all three `session.new` paths (Mac receiver, mirrored-window
  request, agterm-server); the shared snapshot helpers in the UI suites skip the root entry
- [x] implement (labels stay in Task 6); targeted tests green before Task 4

### Task 4: Close, undo and Recent Closed with the root

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore+RecentClosed.swift`, `AppStore+PendingClose.swift`, `RecentClosed.swift`
  (`RemoteRecentClosedItem.Placement`), `agterm/Control/ControlServer+AttachedRecent.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/RecentClosedTests.swift`, `WindowLibraryRecentClosedTests.swift`, `AppStorePendingCloseTests.swift`

- [x] tests first: hard and undoable close of root sessions and groups; reopen into the same window's root; reopen into
  another window lands in that window's root; the root is never rebuilt as a named shell; legacy recent entries decode
- [x] tests first: the Recent Closed subtitle omits the workspace name for a root session
- [x] tests first: an attached session closed at root reopens at the destination window's root, companion parent
  preserved; forwarded undo through the shared reattach helper lands the same way
- [x] guard the root at the store boundary for workspace close, detach and reattach; record container role on closed
  root sessions, local and attached, and route the missing-owner fallback to the destination root
- [x] ➕ from review: a reopened attached row attaches straight into its saved workspace or the destination's root, so
  its creation never names another workspace; a root entry in a store without a root restores nothing
- [x] targeted tests green before Task 5

### Task 5: Control API and CLI

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`, `ControlDispatcher.swift`, `ControlActions.swift`, `ControlResolve.swift`,
  `ControlTargetResolver.swift`, `AppStore+SessionMoves.swift`, `agtermctlKit/EventCommands.swift` (`EventFormatter.human`), `agtermctlKit`
  argument parsing and help, `AgtermServerKit/ServerActions+Flags.swift`, `agterm/Control/ControlServer+WorkspaceCommands.swift`,
  `+SessionActions.swift`, `+Zmx.swift`, `+RemoteActions.swift` (`routedStore`)
- Modify: `ControlDispatcherWorkspaceTests.swift`, `ControlDispatcherTests.swift`, `ControlProtocolTests.swift`,
  `agtermctlKitTests/EventCommandsTests.swift`; `AgtermServerTests/ServerActionsTests.swift`; `agtermUITests/ControlAPIUITests.swift`
  (targeted new cases)

- [x] tests first: `session.move` with `--workspace root` and anchors; up/down/top/bottom stay in the source container;
  `zmx.attach` and `zmx.attach.group` accept `--workspace root`
- [x] tests first: `active` resolving to the root: `workspace.focus` and `workspace.flag` act on it, every named-only
  command refuses; `--target root` for focus in all four modes and for flag with companions (agterm-server included);
  every rejected workspace command refuses the `root` literal (UUID, prefix and `active` refusals land in Task 1);
  `workspace.go` works from root
- [x] tests first: `routedStore` resolves `root` to the catalog owner for every routed workspace command, frontmost and
  explicit-window forms; `EventFormatter.human` names the root (dropped: no human event line prints a workspace,
  the JSON keeps the UUID)
- [x] implement dispatch, routing, CLI arguments and help text
- [x] ➕ from review: a remote window refuses the owner's root for rename/delete/move/tint before forwarding;
  `zmx.attach.group` through the root alias is covered with a companion
- [x] one end-to-end control test per new argument; targeted tests green before Task 6

### Task 6: New Top-Level Session, palette, labels and focus editor

**Files:**
- Modify: `agtermCore/Sources/agtermCore/BuiltinAction.swift`, `PaletteCatalog.swift`, `CustomCommand.swift`, `agterm/agtermApp+Menus.swift`,
  `agterm/AppActions.swift`, `agterm/AppActions+Palette.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/BuiltinActionTests.swift`, `PaletteCatalogTests.swift`, `CustomCommandTests.swift`,
  `agtermUITests/SidebarUITests.swift` (File menu item, targeted)

- [x] tests first: `new_root_session` built-in and palette entry resolve, are enabled in a root-only window and disabled
  in a remote window whose owner has no root
- [x] tests first: Focus Workspace label reads "Focus Top-Level Sessions" when the active container is the root, in menu
  and palette
- [x] tests first: Edit Focused Workspaces lists "Top-Level Sessions" with the same membership mark and toggle, present
  when root is empty or filtered out
- [x] tests first: `{AGT_WORKSPACE_NAME}` expands empty for a root session
- [x] implement File ▸ New Top-Level Session next to New Session through the existing GUI creation path with the root
  ID (directory and placement settings, selection, remote dispatch unchanged), the palette entry, the built-in, the
  labels and the focus-editor entry
- [x] ➕ from review: View menu and palette "Add Workspace to Focus" read "Add Top-Level Sessions to Focus" when the
  active container is the root; the File item carries the built-in's key equivalent so a mapped chord fires it; the
  focus editor shows a disabled "Top-Level Sessions" entry for a server window whose owner has no root;
  `PaletteUITests` arrow and ⌃J walks count the rows to New Workspace instead of a fixed step count
- [x] targeted UI test for the File menu item and a mapped chord; targeted tests green before Task 7

### Task 7: Docs, skill and final gates

**Files:**
- Modify: `site/docs.html`, `site/commands.html` (:829 keep-at-least-one), `plugins/agterm/skills/agterm/SKILL.md`,
  `reference.md` (:397 keep-at-least-one), `.claude/rules/sidebar.md`, `.claude/rules/control-api.md`,
  `.claude/rules/menu-actions.md` (:249, :303), `.claude/rules/windows.md` (:41), `.claude/rules/keymap.md` (built-in table),
  `ARCHITECTURE.md` if its model section names workspaces

- [x] docs: top-level sessions, New Top-Level Session, focus with root, `--workspace root` on every destination command,
  `session.remote.new` from a root destination, `tree` root node, last workspace deletable, new-window source rules
- [x] skill: SKILL.md trigger and section for top-level sessions; reference entries for every changed command
- [x] rules: sidebar root block, drop rules, focus membership; control-api root addressing, `active` rule and
  rejections; menu-actions and windows keep-at-least-one and seeding lines; keymap built-in
- [x] verify every decision in Technical Details is implemented
  - ➕ full `swift test` found three tests Task 3 and Task 6 missed: the keep-one test rewritten to the delete-last
    contract, the keymap list fixture gained `new_root_session`, and `canStepWorkspaces` keeps a sole focused workspace
    enterable while it holds a session the selection is not in
- [x] gates once: `cd agtermCore && swift test`, `make test-app`, `make lint`, Release build
  - ➕ the hosted suite found three root leaks the host-free tests could not see: the sidebar's expansion mirror carried the
    root id, Collapse Workspaces kept it open with the root current, and a catalog test read `workspaces.last`
- [x] move this plan to `docs/plans/completed/`

## Post-Completion
*Informational, no checkboxes*

**Manual verification** in an isolated Debug instance:
- drag sessions into, out of and within the root block; delete the last named workspace; New Top-Level Session from
  inside a workspace; focus root only, then New Session; open a new window from a root session.
- attach a remote window from another Mac and from agterm-server; move a session to and from root there; view a newer
  origin from an older agterm build.

**Downstream**: agterm-linux consumes `agtermCore`; `isRoot`, `namedWorkspaces` and the `tree` root node change what its
sidebar snapshot sees.
