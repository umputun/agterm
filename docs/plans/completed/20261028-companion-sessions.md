# Companion Sessions

## Overview
- A companion is a session that belongs to a parent session: a sub-task shell spun off the primary session,
  a session running some related program, or a session that exists only to hold an HTML page next to it.
- Today users approximate this with Duplicate (which copies only the directory) or a separate session
  holding an overlay, and nothing in the sidebar ties the two together.
- Companions render as a third sidebar level under their parent, move and close with it, and carry a
  `parent › child` label wherever a list has no indentation to show the relationship.
- A companion is an ordinary session in every other way: it can run any command, exactly like any session.
  The only special kind is the HTML page companion, which has no shell under it.
- Delivered in stages, each shippable on its own: a Live-mode fix for command sessions, terminal companions,
  page companions, Duplicate as Companion with layout copy and process replay, and remote companions.

## Context (from discovery)
- Model and store: `agtermCore/Sources/agtermCore/Session.swift`, `Workspace.swift`, `AppStore.swift`
  (`moveSession`, `moveSessions`, `closeSession`), `AppStore+Duplicate.swift`, `AppStore+PendingClose.swift`,
  `AppStore+RecentClosed.swift`, `RecentClosed.swift`, `Snapshot.swift`, `AppStore+Snapshot.swift`,
  `AppStore+Persistence.swift`, `AppStore+Restore.swift`, `AppStore+Naming.swift`, `AppStore+Panes.swift`,
  `AppStore+HtmlOverlay.swift`, `SidebarDrop.swift`, `Reorder.swift`, `RestartReplay.swift`, `CommandRestore.swift`,
  `ZmxSupport.swift`, `ZmxReplayScript.swift`, `RemoteSession.swift`, `RemoteTree.swift`.
- Control: `ControlProtocol.swift`, `ControlDispatcher*.swift`, `ControlProjection.swift` (`ControlSessionNode`),
  `ControlModes.swift` (`ControlSessionCreateOptions`), `ControlDispatcherOptions.swift`
  (`ControlSessionOverlayOpenOptions`), `ControlActionsDefaults.swift`, `agterm/Control/ControlServer.swift`
  (`waitsOnNetwork`), `ControlServer+SessionActions.swift`, `+SessionClose.swift`, `+Restart.swift`, `+Zmx.swift`,
  `+RemotePage.swift`, `agtermCore/Sources/agtermctlKit/`.
- Sidebar and lists: `agterm/Views/WorkspaceSidebar*.swift`, `SidebarRowViews.swift`, `SessionSwitcher.swift`,
  `Palette.swift`, `WindowContentView+RecentSessions.swift`, `WindowContentView+Detail.swift`, `DashboardView.swift`,
  `agterm/AppActions+Palette.swift`, `agterm/AppDelegate+DockMenu.swift`, `agterm/agtermApp.swift` (surface
  `onExit` wiring), `agterm/Ghostty/ZmxLaunch.swift`, `LaunchSeed.swift`.
- Facts the design rests on:
  - `Workspace.sessions` is the single owner of session order; the sidebar is an `NSOutlineView` whose
    `isItemExpandable` admits only workspaces today (`WorkspaceSidebar.swift:797`).
  - `syncSelection` expands only the owning workspace; `ownerWorkspaceNode` searches direct children.
  - `softCloseSessions` already groups a batch into one pending undo but records one Recent Closed entry per
    session (`AppStore+PendingClose.swift:176`).
  - GUI close confirmation is optional (`AppActions.confirmCloseSession`); API `session close` is a hard close
    unless `--undoable` with grace undo enabled (`ControlServer+SessionClose.swift`).
  - Remote rows are never persisted (`Session.isPersistable`) and own no local pane identities; closing one
    detaches, the origin daemon keeps running.
  - `session move --window` selects the store to search; it is not a cross-window transfer.
  - The detail deck mounts a terminal for every session (`WindowContentView+Detail.swift`).
  - `ControlServer+Restart.swift` already observes a pane's live foreground argv and process cwd and validates
    them through `RestartReplay.resolve` with the restore denylist.
  - The viewer runs the origin's `agtermctl` over ssh through `RemoteCommandRunner` (`remoteTree`), and only
    `zmx.tree`, `zmx.attach` and `session.restart` are dispatched off the accept thread (`waitsOnNetwork`).
  - `attachRemoteSession` requires the origin session to be zmx-backed with every pane's daemon present
    (`RemoteTreeMerger`), so a just-created origin session is not attachable until its panes realize.
  - `closePrimaryPane` promotes a live split into the primary pane; only the last pane's exit ends a session.
  - `Palette.updateFiltered` ranks an empty sessions query, which sorts A-Z by title.
  - The `session.duplicate` dispatch ignores options and calls the two-argument `duplicateSession`.
  - In Live mode a `--command` session does not close when its command exits: `ZmxSupport.creationArguments`
    renders the command through `ZmxReplayScript.render(commandLine:)`, whose `always` block execs an interactive
    login shell afterwards, and `LaunchSeed` forces `waitAfterCommand: false` for the wrapped disposition, so
    `--wait` has no effect. Outside Live the session closes on exit as `Session.initialCommand` documents.
    Captured-foreground replay returns to the shell deliberately and must keep doing so.
  - Remote overlay presentation ties lifetime to the viewer: `OverlayRunJob` kills a program group on ssh tty
    hangup, `remoteOverlayPresenterLost` ends pages and `endRemotePage` dismisses them.

## Development Approach
- **testing approach**: Regular (code first, then tests in the same task)
- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - tests are not optional - they are a required part of the checklist
  - write unit tests for new functions/methods
  - write unit tests for modified functions/methods
  - add new test cases for new code paths
  - update existing test cases if behavior changes
  - tests cover both success and error scenarios
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- run tests after each change; scope runs to what changed (`swift test --filter`, `-only-testing:` for hosted and UI
  tests), and run each full gate once at the end (`swift test`, `make test-app`, `make lint`)
- maintain backward compatibility: snapshots without the new fields decode unchanged, and the control tree
  keeps `workspace.sessions` flat

## Testing Strategy
- **unit tests**: host-free `agtermCore` tests for the command seed, model invariants, move/close/undo/reopen,
  labels, drop resolution, dispatcher parsing and response shape, replay planning, remote creation with a fake runner
- **hosted tests** (`agtermTests`): sidebar outline shape, row rendering and icons, palette/switcher/Dock labels,
  launch seeds, control server effects
- **UI tests** (`agtermUITests`): one end-to-end flow per stage through `agtermctl` plus the sidebar, added to the
  existing control, sidebar and Live suites

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope
- keep plan in sync with actual work done

## Solution Overview
- Live `--command` sessions (stage 0) close when their command exits and honor `--wait`, as they already do outside
  Live. Only explicit creation commands change; replay of a captured foreground program still returns to the shell.
- `Session` gains an optional parent id. A companion is a full session (own panes, overlay slot, status, flag,
  tint, any command); only tree shape, movement and lifetime change. Code and API say parent/child, UI says Companion.
- Invariants, enforced by the store and never by callers:
  - one level: a companion cannot be a parent; "New Companion" on a companion creates a sibling
  - same workspace as the parent, stored contiguously right after it in `Workspace.sessions`, so sidebar order,
    navigation order and the flat control list agree
  - pinned for life: no detach, no re-parent; drag reorders only among siblings
- Movement: every move entry point (drag, Move to, `session move`, batch move, placement) moves a parent with
  its companions atomically, preserving ids and sibling order. A companion cannot be moved out of its group.
- Lifetime:
  - closing a parent closes its companions, the same way deleting a workspace closes its sessions; the GUI
    confirmation names them, one pending undo restores the group, the API response lists every closed id
  - a parent whose last pane exits on its own while it has companions starts a fresh login shell in that pane's
    last cwd instead of closing (a live split is still promoted first, as today); a parent without companions
    closes on exit as today, so the row never outlives a live shell
  - a terminal companion follows ordinary session semantics for its own exit, persistence and restore
  - Reopen Recent keeps a group record; a companion closed earlier reopens under its parent wherever the parent
    now is, or restores the archived parent group first, and is unavailable when neither exists
- Presentation: the tree sidebar shows the bare name indented under the parent, foldable through the parent's
  disclosure triangle; every list where a companion row is not indented under its parent (⌃P, ⌃Tab, attention
  palette, clock/bell popovers, Dock menu, dashboard tiles, and all three flagged layouts, the flagged tree included
  since it stays workspace -> flagged sessions) shows `parent › child`. The parent's status glyph stays its own; a
  folded parent shows a separate marker for companions needing attention. Flagged views keep exact flagged membership.
  Terminal companions keep the ordinary terminal/split icons.
- Page companions (stage 2) host one HTML page (`list.bullet.rectangle`) with no shell under it; closing the page or the page's
  own `session.overlay.close` ends the row. They are ephemeral across relaunch and refuse hide.
- Duplicate as Companion (stage 3) copies the split layout and starts another copy of each pane's freshly observed
  foreground program in that pane's process cwd, through the restart replay seam and the restore denylist. Plain
  Duplicate keeps its directory-only contract.
- Remote companions (stage 4) are owned by the origin: the viewer asks the origin's agterm over ssh to create the
  companion under its session, waits for it to become attachable, then attaches it. Closing on the viewer detaches
  only. Origin policy (denylist, process reading) is authoritative for replay. Terminal and page companions are both
  supported on remote parents; a remote page stays owned by the origin and survives viewer detach. Until stage 4
  lands, every creation path refuses a remote parent, so no local durable companion can sit under an unsaved remote row.

## Technical Details
- Live command seed (stage 0): a separate `ZmxReplayScript` rendering for explicit creation commands that runs the
  command and exits with its status, with no interactive-shell continuation; zsh and fish both. `ZmxLaunch` uses it
  for `initialCommand`/`splitInitialCommand`; captured-argv replay keeps the shell-return script. The wrapped
  `LaunchSeed` carries the session's `commandWait` (`splitCommandWait` for the split) instead of a fixed `false`.
- `Session.parentID: UUID?` (`public internal(set)`), set only at creation by the store.
- Insertion: every index-based insertion (`addSession(at:)`, `session new --after/--before`, after-current New
  Session placement, plain Duplicate, undo and Reopen Recent of a top-level session) is normalized by the store to
  land outside any group, after a group's last companion; `--after/--before <companion>` without `--parent` lands
  after that companion's group.
- Older running app: `ControlArgs` silently drops unknown keys, so an extra flag on an existing command would be
  executed by an older app as the plain command. Companion creation therefore uses its own wire commands,
  `session.companion.new`, `session.companion.duplicate` and `session.companion.page`, which the CLI forms
  (`session new --parent`, `session duplicate --companion`, `session overlay open --html --companion`) map to. An
  older app fails to decode an unknown command before dispatch, so it mutates nothing; the CLI turns that exact
  decode error into "the running app is too old for companions" and passes every other server error through.
  `result.parent` stays in each reply as the receipt. Remote creation gets the same guarantee on the origin.
- Remote dispatch: `waitsOnNetwork` lists the three companion commands, so they run off the accept thread, local
  ones included; ssh never blocks the accept thread or deadlocks a same-Mac origin. The ordering test waits for the
  creation response and then issues `tree`; a `tree` sent while creation is still pending may see the old state.
  The GUI path calls `AppActions` directly and needs no socket hop.
- Parent shell respawn: only the owner of the pane respawns it (a local session, or the origin for a remote row);
  a viewer never creates a local shell under a remote row. The respawn reuses the pane identity, so in Live mode the
  replacement daemon keeps the same name and the viewer's remote binding stays valid. Like `session restart`, the
  owner confirms a replacement leader whose pid differs from the old one before treating the respawn as done.
  Reconnect alone does not carry the viewer across: it reacts only to ssh status 255, and a clean daemon exit
  reaches `onExitHeld`, which cancels reconnect and leaves the exit prompt. So the owner publishes a respawn
  generation for the pane once the replacement is ready, and any viewer binding to that pane consumes a new
  generation with a bounded attach-only retry, never a creation payload, driven by the generation rather than by
  "host answers". The gate is the origin's generation alone, not whether the viewer shows companions, since a viewer
  may have detached every companion row the origin still owns. The viewer remembers a generation until its held exit
  arrives and the reverse, so either order works. An ordinary clean exit publishes no generation and keeps today's
  behavior. The respawned shell is a plain login shell at the pane's last cwd: the pane's
  creation command, wait flag and pending replay and override are cleared first, so an exited `--command` parent
  never reruns its command. The store bumps an observed host invalidation so the deck remounts the primary host,
  since `surface` and `primarySurfaceHostRevision` are observation-ignored and a nil surface alone remounts nothing.
- `SessionSnapshot.parentID: UUID?` optional, encoded only when set. Restore validates: a parent id naming no
  restored session in the same workspace, or naming a companion, is dropped (agtermCore has no logger and must
  build for the Linux fork), the only case a companion becomes top level (corrupt or hand-edited state).
- `Session.isExpanded` for parents, persisted as `SessionSnapshot.collapsed` written only when true, matching
  `WorkspaceSnapshot.collapsed`.
- Content kind (stage 2): `Session.content: SessionContent` with `.terminal` (default) and `.page(HtmlOverlay
  source)`, fixed at creation; page companions are excluded from snapshots and persistent Recent Closed.
- Label: one store-level formatter, `AppStore.listLabel(for:)`, returning `"\(parent.displayName) › \(child.displayName)"`
  for companions and `displayName` otherwise. `displayName`, rename and control `tree.name` stay bare; nothing stores
  or parses the composed string.
- Control surface (exact names fixed in task 6 against `control-api.md` conventions):
  - `session new --parent <target>` creates a companion (a companion target means its parent) in the parent's
    focused cwd unless `--cwd` is given; combines with the existing `--command`, `--wait` and `--name`
- GUI: the session row menu gets two top-level items next to Duplicate Session, "New Companion" and "Duplicate as
  Companion", each also an action-palette row and a keyless built-in (`new_companion`, `duplicate_companion`) in
  `BuiltinAction.swift`, enabled through `PaletteCommand.isEnabled(in:)`
  - `session duplicate --companion` (stage 3)
  - `session overlay open --html ... --companion` for page companions (stage 2)
  - `session close` on a parent closes the group and returns every closed id
  - read-back: `ControlSessionNode.parent` (id), `collapsed` on parents, `content` kind; `session.created`
    events carry `parent` in both JSON and `EventFormatter.human`
  - `session collapse|expand` for a parent's fold, mirroring `workspace collapse|expand`
- Remote creation (stage 4): the viewer runs the origin's `agtermctl session new --parent <origin-id>` (or
  `duplicate --companion`, or `overlay open --html --companion`) through `RemoteCommandRunner`, reads the created id
  from the JSON response, waits a bounded time for the origin's tree to report it attachable, then attaches it with
  the viewer's remote parent row as parent. The new remote-capable requests join `waitsOnNetwork` so ssh never blocks
  the accept thread or deadlocks a same-Mac origin on its own socket. Create and attach are separate steps: a
  created-but-unattached companion is reported with its id and can be attached later; creation is never retried
  automatically and never falls back to local.

## What Goes Where
- **Implementation Steps** (`[ ]` checkboxes): tasks achievable within this codebase - code changes, tests,
  documentation updates
- **Post-Completion** (no checkboxes): items requiring external action - manual testing, changes in consuming
  projects, deployment configs, third-party verifications

## Implementation Steps

### Stage 0: command sessions in Live mode

### Task 1: Live `--command` sessions close on exit and honor `--wait`

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ZmxReplayScript.swift`, `ZmxSupport.swift`
- Modify: `agterm/Ghostty/ZmxLaunch.swift`, `agterm/Ghostty/LaunchSeed.swift`, `agterm/Control/ControlServer+Restart.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ZmxReplayScriptTests.swift`, `ZmxSupportTests.swift`,
  `agtermTests/LaunchSeedTests.swift`, `agtermTests/ControlServerRestartTests.swift`, `agtermUITests/ZmxLiveUITests.swift`

- [x] add a creation-command rendering (zsh and fish) that runs the command and ends with it, with no login-shell
      continuation, selected by a distinct parameter on `ZmxSupport.attachCommand` that only `ZmxLaunch` passes for
      `initialCommand`/`splitInitialCommand`; captured-argv replay and `session restart --command` keep their
      current scripts
- [x] write a restart test pinning that `session restart --command` still returns to the shell, and a test that a
      held exit of a local wrapped pane (`onExitHeld`) stays inert in the remote-pane handlers
- [x] pass the pane's `commandWait`/`splitCommandWait` through the wrapped `LaunchSeed` so `--wait` holds the final
      output in Live mode as it does outside Live
- [x] write tests for both script renderings (creation ends with the command, replay still returns to the shell)
- [x] write hosted tests for the wrapped seed's wait flag on primary and split
- [x] write a Live UI test: a `--command` session closes when its command exits, and holds with `--wait`
      (written; its run waits for UI-test approval)
- [x] run the new and changed tests - must pass before next task

### Stage 1: terminal companions

### Task 2: Companion model, persistence and group movement

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Session.swift`, `Workspace.swift`, `AppStore.swift`,
  `AppStore+Duplicate.swift`, `AppStore+NewSessionPlacement.swift`, `Snapshot.swift`, `AppStore+Snapshot.swift`
  (`sessionSnapshot`, `session(from:)`), `AppStore+Persistence.swift`, `AppStore+Restore.swift`, `Reorder.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreTests.swift`, `AppStoreOrganizationTests.swift`,
  `SnapshotRoundTripTests.swift`, `AppStoreRestoreTests.swift`, `ReorderTests.swift`

- [x] add `parentID` and `isExpanded` to `Session` and a store entry point that creates a companion right after
      the parent's last companion, resolving a companion target to its parent; refuse a remote parent until Task 10
- [x] enforce the invariants in the store: one level, same workspace, contiguous group, sibling-only reorder
- [x] route every move entry point (`moveSession`, `moveSessions`, placement, reorder) through group-aware logic:
      a parent carries its companions, a companion is refused outside its sibling range, multi-selection holding a
      parent and its companions is deduplicated
- [x] normalize every index-based insertion so it lands outside any group (see Technical Details: `addSession(at:)`,
      `--after/--before`, after-current placement, plain Duplicate, undo and reopen of a top-level session)
- [x] persist `parentID` and parent `collapsed` as optional snapshot fields; on restore drop invalid links and
      regroup a hand-edited order so each companion sits right after its parent
- [x] write tests for creation, invariants, group moves, refusals and dedup
- [x] write tests for each insertion path landing after a group, and a top-level `reorderSession .down` stepping
      past a whole group
- [x] write tests for snapshot round trip, legacy decode, and restore of invalid links
- [x] run the new and changed test suites with `swift test --filter` - must pass before next task

### Task 3: Group close, parent shell respawn, undo and Reopen Recent

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift`, `AppStore+PendingClose.swift`,
  `AppStore+RecentClosed.swift`, `RecentClosed.swift`, `AppStore+CloseReselection.swift`, `AppStore+Panes.swift`,
  `WindowLibrary+RecentClosed.swift`
- Modify: `agterm/agtermApp.swift` (primary surface `onExit`, `handlePaneExit`, `makeSurface` cwd), `agterm/AppActions.swift`
  (confirmation text), `agterm/Views/WindowContentView.swift` (`primarySurfaceID`), `agterm/Ghostty/LaunchSeed.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStorePendingCloseTests.swift`, `RecentClosedTests.swift`,
  `AppStoreCloseReselectionTests.swift`, `AppStorePaneTests.swift`, `WindowLibraryRecentClosedTests.swift`,
  `agtermTests/LaunchSeedTests.swift`

- [x] closing a parent (hard or soft, single or batch, workspace removal included) closes its companions as one
      group with one pending undo that restores ids, order and parent links; `session.closed` fires once per member
- [x] a parent's last pane exiting naturally while it has companions starts a fresh login shell instead of closing,
      as Technical Details describe: owner-only, pane identity reused, replacement leader confirmed in Live mode,
      launch payload cleared, last cwd seeded, observed host invalidation to remount (the viewer handoff is Task 10;
      remote parents cannot have companions before it); a primary exit with a live split still promotes the split first;
      `handlePaneExit` tells a respawn from a promotion by an explicit store result, not by surface presence; a
      parent without companions closes as today (the replacement-leader confirmation lands with the Task 10
      handoff, its only consumer)
- [x] write hosted tests that the respawned shell is visible and takes input, in Live and outside Live, and that a
      parent created with `--command` respawns as a plain shell in the directory it had moved to (store state is
      tested here; the real-shell check needs `session new --parent` and moved to Task 6's e2e tests)
- [x] Recent Closed keeps `kind: session` and gains optional companion snapshots on a parent's record (no new kind,
      so an older build still loads the file); reopening a lone companion attaches it under its live parent,
      restores the archived parent group first when the parent is closed, and is unavailable when neither exists
- [x] name the companions in the GUI close confirmation when it is enabled
- [x] write tests for group close, undo, reselection after group close, per-member `session.closed`, and parent exit:
      primary exit with a live split, split exit, last-pane exit with and without companions
- [x] write tests for Recent Closed group records and the three lone-companion reopen cases
- [x] run the new and changed test suites with `swift test --filter` and `-only-testing:` - must pass before next task

### Task 4: Sidebar third level

**Files:**
- Modify: `agterm/Views/WorkspaceSidebar.swift`, `WorkspaceSidebar+RowRendering.swift`,
  `WorkspaceSidebar+DragDrop.swift`, `WorkspaceSidebar+FlaggedLayout.swift`, `WorkspaceSidebar+ContextMenu.swift`,
  `SidebarRowViews.swift`
- Modify: `agtermCore/Sources/agtermCore/SidebarDrop.swift`, `AppStore+Sidebar.swift`, `AppStore+SidebarSelection.swift`,
  `BuiltinAction.swift`, `PaletteCatalog.swift` (`PaletteCommand.isEnabled(in:)`)
- Modify: `agterm/AppActions+Palette.swift` (dispatch), `agterm/agtermApp+Menus.swift` (Session menu)
- Modify: `.claude/rules/sidebar.md`, `.claude/rules/menu-actions.md`, `.claude/rules/keymap.md` (built-in count),
  `site/docs.html` (built-in list), `plugins/agterm/skills/agterm/reference.md` (built-in list)
- Modify: `agtermCore/Tests/agtermCoreTests/SidebarDropTests.swift`, `BuiltinActionTests.swift`, `PaletteCatalogTests.swift`,
  `agtermCore/Tests/agtermctlKitTests/SocketClientTests.swift` (keymap fixture), `agtermTests/SidebarRowViewsTests.swift`,
  `agtermTests/SidebarRowIndentTests.swift`, `agtermTests/SidebarExpansionMirrorTests.swift`,
  `agtermTests/AppActionsPaletteTests.swift`, `agtermUITests/SidebarUITests.swift`

- [x] build companion nodes under their parent node, make parents expandable, indent companion rows; track parent
      expansion alongside `expandedWorkspaceIDs` and persist only genuine user toggles; `TreeShape` and the
      row-content snapshot include the parent -> companion structure and parent expansion; companion rows keep the
      `session-row` accessibility id with a `companion` accessibility label (the value carries the row name
      UI tests read)
- [x] reveal a selected companion by expanding workspace and parent; folding a parent never changes the active
      session; navigation keeps visiting folded companions (collapse is not a navigation filter)
- [x] drag rules in `SidebarDrop`: siblings reorder within their parent, a parent drag carries its group, any other
      companion drop is refused; the flagged tree stays workspace -> flagged sessions with companion rows unindented
      (a flagged companion of an unflagged parent appears alone, never with its parent pulled in) and applies the
      same drop restriction; the flat/plain flagged layouts keep `moveFlagged` over exact flagged membership
- [x] a folded parent shows a separate attention marker for companions that need it, leaving its own status glyph
      and badge untouched; add accessibility label naming the companions
- [x] "New Companion" as a top-level item in the session row menu, next to Duplicate Session: a fresh login shell
      in the parent's focused cwd (as Duplicate resolves it), placed after the parent's last companion; on a
      companion row it creates a sibling under the same parent; also a Session menu-bar item beside Duplicate
      Session, an action-palette row and a keyless `new_companion` built-in, all enabled through
      `PaletteCommand.isEnabled(in:)`
- [x] write tests for drop resolution cases in `SidebarDropTests`, including a flagged companion whose parent is
      not flagged
- [x] write hosted tests for outline shape, indent, expansion mirror, reveal and the folded marker
- [x] update the built-in count and catalog tests, and the palette dispatch partition test, for `new_companion`
- [x] write a UI test creating a companion, folding the parent and reordering siblings
      (written; its run waits for UI-test approval)
- [x] run the new and changed tests with `-only-testing:` - must pass before next task

### Task 5: `parent › child` labels in flat lists

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore+Naming.swift`, `WindowLibrary+Attention.swift`
- Modify: `agterm/AppActions+Palette.swift`, `agterm/Views/Palette.swift`, `agterm/Views/SessionSwitcher.swift`,
  `agterm/Views/WindowContentView+RecentSessions.swift`, `agterm/AppDelegate+DockMenu.swift`,
  `agterm/Views/DashboardView.swift`, `agterm/Views/WorkspaceSidebar+FlaggedLayout.swift`
- Modify: `.claude/rules/menu-actions.md` (⌃P empty-query order)
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreNameSanitizeTests.swift`, `WindowLibraryAttentionTests.swift`,
  `agtermTests/AppActionsPaletteTests.swift`, `agtermTests/PaletteTests.swift`, `agtermTests/DockMenuTests.swift`,
  `agtermTests/SidebarFlaggedLayoutTests.swift`, `agtermTests/DashboardViewTests.swift`,
  `agtermUITests/SessionSwitcherUITests.swift`, `agtermUITests/RecentSessionsButtonUITests.swift`

- [x] add `AppStore.listLabel(for:)` and use it in ⌃P, ⌃Tab, attention palette, clock and bell popovers, Dock menu,
      dashboard tiles and all three flagged layouts; the ordinary tree sidebar, rename and Copy Name stay bare
- [x] keep ⌃P's empty query grouped: `paletteSessions` emits groups in A-Z parent order with each parent followed
      by its companions, and `Palette.updateFiltered` keeps the supplied order for an empty sessions query only;
      non-empty queries stay fuzzy-ranked; MRU and attention orderings are unchanged
- [x] write tests for the label formatter (top level, companion, parent renamed)
- [x] write hosted tests for palette rows, rendered empty-query order with two identically named parents, Dock
      entries, flagged layout labels and dashboard tiles
- [x] write tests for the label in ⌃Tab, the attention palette and the clock and bell popovers
      (attention palette hosted; popovers in a UI test whose run waits for approval; ⌃Tab has no observable
      seam, since XCUITest releases Control at once, and rests on `listLabel`'s tests)
- [x] run the new and changed tests - must pass before next task

### Task 6: Control API, CLI, skill and docs for terminal companions

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`, `ControlDispatcher.swift`, `ControlModes.swift`
  (`ControlSessionCreateOptions`), `ControlActionsDefaults.swift`, `ControlProjection.swift` (`ControlSessionNode`),
  `ControlEvents.swift`, `AppStore+Events.swift`, `ControlRecent.swift`, `ControlDispatcher+Recent.swift`
- Modify: `agterm/Control/ControlServer.swift` (`makeSessionResponse`), `ControlServer+SessionActions.swift`,
  `ControlServer+SessionClose.swift`, `agterm/AppActions.swift` (parent expansion persist-then-notify),
  `agterm/Views/WorkspaceSidebar.swift` (expansion notification)
- Modify: `agtermCore/Sources/agtermctlKit/` (session subcommands, `SocketClient.formatRecent`)
- Modify: `plugins/agterm/skills/agterm/SKILL.md`, `plugins/agterm/skills/agterm/reference.md`
- Modify: `site/docs.html`, `site/commands.html`, `.claude/rules/sidebar.md`, `.claude/rules/control-api.md` (public catalog)
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherTests.swift`, `ControlProtocolTests.swift`,
  `ControlDispatcherSessionCloseTests.swift`, `ControlEventProtocolTests.swift`, `ControlDispatcherRecentTests.swift`,
  `MockControlActions.swift`, `agtermCore/Tests/agtermctlKitTests/`, `agtermTests/ControlServerSessionActionsTests.swift`,
  `agtermUITests/ControlAPIUITests.swift`

- [x] add the `session.companion.new` wire command behind `session new --parent` (see Technical Details for the
      older-app guarantee), combining with `--command`, `--wait`, `--name`, `--cwd`, `--no-select`; refused
      with `--workspace`, `--workspace-name`, `--create-workspace`, `--after` and `--before`), `session collapse|expand`
      for parents through the same persist-then-notify path as `workspace collapse|expand` (`sidebar expand|collapse`
      keep acting on workspaces only), group semantics for `session close` (`affected` counts every member, every
      closed id in the response), and refusals for illegal companion moves and for a remote parent (until Task 10)
- [x] the CLI turns the older app's unknown-command decode error, and only that error, into "the running app is too
      old for companions"; every reply carries `result.parent`
- [x] write a CLI test against an older-server stub proving the request is refused before any mutation (the stub
      records no executed command) and that genuine server errors pass through unchanged
- [x] add read-back: `parent` and `collapsed` on `ControlSessionNode`, `parent` in `session.created` JSON and
      `EventFormatter.human`; `workspace.sessions` stays flat; `recent list` shows a parent record's companions and
      `recent open` of an unavailable lone companion returns a clear error, with CLI formatting
- [x] wire `agtermctl` subcommands and flags
- [x] update the bundled skill (trigger in `description` plus a section), `site/docs.html`, `site/commands.html` and
      the two rules files; document a command companion as the way to keep a related program next to a session
- [x] write dispatcher, protocol round-trip, nil-omission and CLI tests
- [x] write the e2e test creating, reading back, moving and closing a group through `agtermctl`
      (written; its run waits for UI-test approval)
- [x] ➕ write e2e tests that a respawned parent shell is visible and takes input, in Live and outside Live, and that
      a parent created with `--command` respawns as a plain shell in the directory it had moved to (moved from Task 3)
      (written; its run waits for UI-test approval)
- [x] write an e2e test that ordinary session commands act on a companion as on any session: `session status`,
      `notify`, `type`, `split`, `rename`, `flag`, and `session close` on a companion closes only that companion
      (written; its run waits for UI-test approval)
- [x] run the new and changed tests - must pass before next task

### Stage 2: page companions

### Task 7: Page companion kind

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Session.swift`, `Session+HtmlOverlay.swift`, `Session+OverlayVisibility.swift`,
  `AppStore+Panes.swift`, `AppStore+HtmlOverlay.swift`, `AppStore+OverlayVisibility.swift`, `AppStore+Persistence.swift`,
  `AppStore+RecentClosed.swift`
  `AppStore+Dashboard.swift`, `PaletteCatalog.swift`
- Modify: `agterm/Views/WindowContentView+Detail.swift`, `agterm/Views/TerminalView.swift`, `agterm/agtermApp.swift`,
  `agterm/Views/WorkspaceSidebar.swift`, `agterm/AppActions.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/SessionTests.swift`, `AppStorePaneTests.swift`, `HtmlOverlayTests.swift`,
  `AppStoreOverlayVisibilityTests.swift`, `PersistenceTests.swift`, `AppStore+DashboardTests.swift`,
  `PaletteCatalogTests.swift`, `agtermTests/AppActionsOverlayTests.swift`

- [x] add `SessionContent` (`.terminal`, `.page`) fixed at creation; a page companion spawns no shell, claims no pane
      or daemon identity, and renders its page in place of a terminal in the detail deck
- [x] closing the page or the page's `session.overlay.close` requests removal of the companion before overlay
      teardown; manual close keeps the soft-close grace
- [x] the deck never builds a terminal surface for a page companion (`TerminalView` builds one for any empty slot today)
- [x] refuse hide/toggle for this kind (show is a no-op) and skip it in global hide; at the store/action seam, so
      existing control callers are refused too, refuse every command that would cover or replace the page
      (`session.overlay.open` of a program or another page, `hud.open`, `ask.open`) and every terminal-only command
      (`session.type`, `.text`, `.copy`, `.paste`, `.selectall`, `.search`, `.background`, `.lead`, `.swap`, `.focus`,
      `.resize`, `.split`, `.split.close`, `.scratch`, `.restart`, `.restore`, `surface.zoom`); reflect it in
      `PaletteCommand.isEnabled(in:)` for the menu and palette
- [x] keep page companions out of dashboard membership; `ControlSessionNode.cwd` reports the parent's cwd
- [x] refuse resizing a page companion to a floating size and placing its page in a pane
- [x] exclude page companions from snapshots and persistent Recent Closed
- [x] row icon `list.bullet.rectangle`, filled when flagged in tree mode
- [x] write tests for creation, lifetime paths, refused actions and persistence exclusion
- [x] write hosted tests for deck rendering and the row icon
      (row icon hosted; the deck gate is one `content == .terminal` term in `deckPane` with no hosted seam,
      left to the Task 8 e2e page test, which must assert the main terminal stays unrealized)
- [x] run the new and changed tests - must pass before next task

### Task 8: Control API, CLI, skill and docs for page companions

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher+Overlay.swift`, `ControlDispatcherOptions.swift`
  (`ControlSessionOverlayOpenOptions`), `ControlProjection.swift`, `ControlProtocol.swift`
- Modify: `agterm/Control/ControlServer+SessionActions.swift`, `agtermCore/Sources/agtermctlKit/`
- Modify: `plugins/agterm/skills/agterm/`, `site/docs.html`, `site/commands.html`, `.claude/rules/control-api.md`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherOverlayTests.swift`, `MockControlActions.swift`,
  `agtermUITests/ControlHtmlOverlayUITests.swift`

- [x] the `session.companion.page` wire command behind `session overlay open --html ... --companion` creates a page
      companion under the target's parent group and returns its id with `result.parent`; an older app rejects the
      unknown command before touching the parent's overlay slot; never consumes or replaces the parent's overlay
      slot; refuses a remote parent until Task 11
- [x] reject `--companion` with a program overlay, `--pane`, a floating size or point dimensions, and `--wait`
- [x] read-back of the content kind on `ControlSessionNode`; explicit refusals for hide, floating resize and
      shell-only commands, while close, rename, flag, tint and status keep working on a page companion
- [x] document `app.launched` as the place to recreate page companions after relaunch
- [x] write dispatcher and CLI tests, and an e2e test opening and closing a page companion
      (the e2e test, which asserts the page's `realized` stays false, is written; its run waits for UI-test approval)
- [x] run the new and changed tests - must pass before next task

### Stage 3: Duplicate as Companion

### Task 9: Layout copy and process replay

**Files:**
- Create: `agtermCore/Sources/agtermCore/DuplicateReplay.swift`, `agtermCore/Tests/agtermCoreTests/DuplicateReplayTests.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+Companions.swift`, `RestartReplay.swift`, `ControlProtocol.swift`,
  `ControlDispatcher.swift`, `ControlDispatcher+Companions.swift`, `ControlActionsDefaults.swift`, `BuiltinAction.swift`,
  `PaletteCatalog.swift`
- Modify: `agterm/Ghostty/ForegroundProcess.swift` (shared observation), `agterm/Control/ControlServer+Restart.swift`,
  `agterm/Control/ControlServer+Companions.swift`, `agterm/Control/ControlServer.swift`, `agterm/AppActions.swift`,
  `agterm/AppActions+Companions.swift`, `agterm/AppActions+Palette.swift`, `agterm/agtermApp.swift`,
  `agterm/agtermApp+Menus.swift`, `agterm/Views/WorkspaceSidebar+ContextMenu.swift`
- Modify: `agtermCore/Sources/agtermctlKit/SessionCommands.swift`, `plugins/agterm/skills/agterm/`, `site/docs.html`,
  `site/commands.html`, `.claude/rules/control-api.md`, `sidebar.md`, `menu-actions.md`, `keymap.md`
- Modify: `AppStoreCompanionsTests.swift`, `ZmxReplayScriptTests.swift`, `BuiltinActionTests.swift`, `PaletteCatalogTests.swift`,
  `ControlDispatcherCompanionsTests.swift`, `MockControlActions.swift`, `agtermctlKitTests/SocketClientTests.swift`,
  `SessionCompanionsCommandsTests.swift`, `agtermTests/ControlServerCompanionsTests.swift`,
  `agtermUITests/ControlCompanionsUITests.swift`

- [x] extract the per-pane foreground, process-cwd and executable observation from the restart path into
      `ForegroundProcess.replayObservation`, used by restart and duplicate; `DuplicateReplay` plans a pane from it with
      refusal text that names the pane instead of restart-only advice
- [x] Duplicate as Companion copies split axis and ratio, each pane's cwd, and starts another copy of each pane's
      observed foreground program as that pane's creation command (`initialCommand`/`splitInitialCommand`, the
      `session new --command` semantics Eugene chose): it closes the pane on exit, persists, and runs in every launch
      disposition through the existing creation path, ungated by restore mode. Only a recognized foreground shell
      yields a plain shell; a daemon-leader shell program, an unreadable foreground and a missing cwd are refused.
      A bare argv[0] becomes the process's executable path, since outside Live the command runs on the GUI PATH;
      an argument with a backslash is refused, since libghostty and fish's Live `eval` read it differently.
      A pipeline or shell job is copied as its foreground process only.
- [x] preflight the whole layout before creating anything; a refused pane is reported and nothing is created; no
      overlays, status or flags copied
- [x] "Duplicate as Companion" as a top-level row menu item right after New Companion, a Session menu-bar item, a
      palette row, a keyless `duplicate_companion` built-in action, and `session duplicate --companion` mapped to the
      `session.companion.duplicate` wire command through the protocol, dispatcher and `ControlActions`, with
      `result.parent` in the reply; plain `session.duplicate` is unchanged; refuse a remote source until Task 10
- [x] write tests for the replay plan: idle shell, running program, executable path, daemon-leader shell, backslash,
      denylisted, unreadable, missing cwd; store tests for a split copy
- [x] write zsh and fish round-trip tests for a duplicated program's creation command (apostrophe, spaces, empty
      argument)
- [x] write protocol, dispatcher and CLI tests for `--companion`, and that plain `session duplicate` is unchanged;
      update the built-in count and catalog tests for `duplicate_companion`
- [x] write hosted refusal tests and an e2e test for a split duplicate with replay (the e2e test runs with the UI
      suite in Task 11)
- [x] run the new and changed tests - must pass before next task

### Stage 4: remote companions

### Task 10: Origin-owned remote terminal companions

**Files:**
- Modify: `agtermCore/Sources/agtermCore/RemoteSession.swift`, `RemoteTree.swift`, `ControlDispatcher.swift`,
  `ControlDispatcher+Zmx.swift`, `ControlActionsDefaults.swift` (async creation actions)
- Modify: `agterm/Control/ControlServer.swift` (`waitsOnNetwork`), `agterm/Control/ControlServer+Zmx.swift`,
  `agterm/Control/ControlServer+SessionActions.swift`, `agterm/Control/ControlServer+RemoteReconnect.swift`,
  `agterm/AppActions+RemoteAttach.swift`, `agterm/agtermApp.swift` (`onExitHeld` for remote rows),
  `agterm/agtermApp+RemoteLayout.swift`, `agterm/Views/WorkspaceSidebar+ContextMenu.swift`
- Modify: `agtermCore/Sources/agtermCore/RemoteReconnect.swift`, `AppStore+RemoteLayout.swift`
- Modify: `plugins/agterm/skills/agterm/`, `site/docs.html`, `.claude/rules/control-api.md`
- Modify: `agtermCore/Tests/agtermCoreTests/RemoteSessionTests.swift`, `RemoteTreeTests.swift`,
  `ControlDispatcherZmxTests.swift`, `MockControlActions.swift`, `RemoteReconnectTests.swift`,
  `AppStoreRemoteLayoutTests.swift`, `agtermTests/RemoteAttachTests.swift`, `agtermTests/ControlServerZmxTests.swift`,
  `agtermTests/ControlServerTests.swift`, `agtermTests/ControlServerRemoteReconnectTests.swift`,
  `agtermTests/RemoteLayoutCloseTests.swift`

- [x] make companion creation an async control action and add the three `session.companion.*` commands to
      `waitsOnNetwork` (see Technical Details), so ssh never blocks the accept thread or deadlocks a same-Mac origin
      on its own socket; the GUI path calls `AppActions` directly
- [x] New Companion (with or without a command) and Duplicate as Companion on a remote row run the origin's
      `agtermctl` over ssh with `--no-select` (`RemoteSession.controlCommand`, quoted for any login shell) to create
      the companion under the origin session; an origin that cannot decode the command answers "too old for
      companions". The viewer first checks the origin still offers the session, then polls the origin tree for up to 20 s until it reports the id
      attachable (every pane's daemon present), without re-running creation, then attaches it under the viewer's row
- [x] the attach HUD reports creating on HOST, then attaching, and clears only its own HUD on success, failure or
      cancel; a non-overlay error route when the parent's slot is occupied
- [x] failure handling: created-but-unattached (attach failure or readiness timeout) reports the id and leaves it
      attachable; an origin without the capability creates nothing; no automatic retry of creation, no local fallback
- [x] closing a remote companion on the viewer detaches only; the origin's companion keeps running
- [x] owner-respawn handoff (see Technical Details): the origin publishes a respawn generation, with an origin epoch,
      once a different live leader runs under the daemon name; each LOCAL viewer pane consumes it with a bounded
      attach-only retry (three attaches), matched with its held exit in either order and without expiry, and only
      once the new attachment reports its role; a reconnect snapshot recovers a missed frame; a clean exit with no
      generation keeps today's behavior
- [x] write tests of the respawn join and its wiring: generation before and after the held exit, a missed frame
      recovered by a reconnect snapshot, an origin restart, two local views of one daemon, an attach that ends before
      reporting, the origin publishing only after a different live leader, and a snapshot seed against a frame; the
      two-Mac run (input typed through the viewer row reaching the respawned shell) is under Post-Completion
- [x] lift the Task 2/6/9 remote refusals (the store keeps refusing a LOCAL companion under a remote row)
- [x] write tests with a fake `RemoteCommandRunner` for success, delayed pane realization, origin refusal, older
      origin, attach failure after creation, and timeout
- [x] write a control server test that a companion request runs off the accept thread and that a `tree` issued after
      its response sees the result
- [x] run the new and changed tests - must pass before next task

### Task 11: Origin-owned remote page companions

**Files:**
- Modify: `agtermCore/Sources/agtermCore/RemoteTree.swift`, `RemotePageResources.swift`, `AppStore+RemotePage.swift`,
  `ControlDispatcher+Overlay.swift`
- Modify: `agterm/Control/ControlServer+RemotePage.swift`, `agterm/Control/ControlServer+RemotePresentation.swift`,
  `agterm/AppActions+RemoteAttach.swift`
- Modify: `plugins/agterm/skills/agterm/`, `site/docs.html`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreRemotePageTests.swift`, `RemoteTreeTests.swift`,
  `RemotePageResourcesTests.swift`, `agtermTests/ControlServerRemotePageTests.swift`,
  `agtermTests/ControlServerRemotePresentationTests.swift`

- [x] the origin creates the page companion through `overlay open --html --companion`; the origin's remote tree
      reports page companions, which own no daemon, with no panes and their parent, when the parent is listed
- [x] the page's identity, source, grant and outcome stay owned by the origin; the viewer presents it as a companion
      row of its remote parent by reusing remote page resource serving and bridge dispatch with a fresh serving token
      per attach (`session.companion.page.attach`), never the remote overlay reservation lifecycle; the page's own
      reload and navigation act on the viewer's copy, and the viewer row mirrors no status, notify or context
- [x] viewer close or disconnect releases only that viewer's channel and web view, never `endRemotePage` or a dismiss;
      the page stays available on the origin and can be attached again; closing the page on the origin removes every
      viewer row; a reattach loads a new document, it does not resume the previous viewer's page state
- [x] ordinary remote overlay and page cancellation semantics stay unchanged
- [x] lift the Task 8 remote refusal
- [x] write tests proving the same page stays available on the origin after viewer detach and disconnect, can be
      reattached, and is removed from viewers when closed on the origin
- [x] run the new and changed tests - must pass before next task

### Task 12: Verify acceptance criteria
- [x] verify every Overview and Solution Overview requirement is implemented
- [x] verify edge cases: illegal moves, insertion next to a group, lone companion reopen, parent shell respawn, page
      close, refused replay, replay outside Live, older-app detection, remote attach failure, remote page surviving
      viewer detach, Live `--command` exit and `--wait`
- [x] run full test suite: `cd agtermCore && swift test`
- [x] run hosted tests: `make test-app` (the XCUITest classes written by the tasks run with the user's approval)
- [x] run `make lint` with zero findings

### Task 13: [Final] Update documentation
- [x] update README.md if the synopsis should mention companions, `site/index.html` major features and the
      `site/llms.txt` discovery index
- [x] update CLAUDE.md and `.claude/rules/*.md` for new patterns
- [x] move this plan to `docs/plans/completed/`

## Post-Completion
*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Manual verification**:
- isolated Debug instance in Live mode: a `--command` session closes on exit and holds with `--wait`
- create companions, including one started with a command, fold, drag siblings, close the parent and undo, exit
  the parent shell
- page companions: open, close from the page
- Duplicate as Companion of a split running a program in each pane
- remote companions between two Macs: terminal and page, detach on the viewer, confirm both remain on the origin
- respawn across Macs: exit a Live parent with companions on the origin while a viewer shows it, with the viewer's
  companion rows attached and detached; the viewer row reattaches to the new shell and typed input reaches it

**External system updates**:
- `agterm-linux` fork consumes `agtermCore`; the new `Session` and snapshot fields and control payloads are additive

Smells pre-check: skipped — non-Go project
