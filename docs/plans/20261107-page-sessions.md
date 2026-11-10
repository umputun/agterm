# Top-level page sessions

## Overview
- A page session (`Session.content == .page`, an HTML page with no shell under it) can today exist only as a
  companion, created by `AppStore.addPageCompanion` through `session.companion.page`.
- This change lets the control API and CLI create a page session as an ordinary top-level row, lets any page row
  be a companion parent, saves and restores every local page row like a terminal row, and lets another Mac attach
  a page-rooted group.
- What the page itself does with its bridge is out of scope: no new API serves a particular kind of page.
- One rule for users: a local page row is a session. It sits where it was put, groups companions, survives
  relaunch and Recent Closed, and a failed load leaves the row with its error and a reload, never a missing row.

## Context (from discovery)
- Page creation: `agtermCore/Sources/agtermCore/AppStore+Companions.swift` (`addPageCompanion`, `companionSlot`
  with no content check, `convertToCompanion`), `ControlDispatcher+Companions.swift` (refuses image, markdown and
  text sources for a page row at :30), `agterm/Control/ControlServer+Companions.swift` (`pageCompanionRefusal`).
- CLI: `agtermCore/Sources/agtermctlKit/SessionCommands.swift` (`session overlay --html/--url --companion`).
- Bridge: `HtmlBridge.swift` (the `session.` prefix already defaults to the page's own session, :103),
  `agterm/Views/HtmlOverlayRegistry.swift` (`webViewDidClose` sets `closeRequested`, never cleared, and every
  mount re-checks it, :231/:427/:798).
- Close: `AppStore+Panes.swift:462` `closeOverlay` hard-closes a page row (:465); `AppActions.closeSession`
  prompts per setting and is gated by `uiActionsEnabled` (:289-291); control close uses the store path
  (`ControlServer+SessionClose.swift:44`).
- Persistence: `Snapshot.swift` (`SessionSnapshot`), `AppStore+Snapshot.swift` (`sessionSnapshot`,
  `workspaceSnapshot`, `session(from:)`), `Session.swift` (`isPersistable`, `locallyManagedPaneIdentities`),
  `WindowLibrary.swift:938` `persistedClaims` and `ZmxLifecycle.swift:129` `PaneIdentityInventory.upgrade`, both of
  which treat every saved session as owning a daemon.
- Recent Closed: `RecentClosed.swift`, `AppStore+RecentClosed.swift:210` (refuses a nonpersistable root),
  `AppStore+PendingClose.swift:179-190` (companions ride in the parent's entry), `WindowLibrary+RecentClosed.swift`.
- Menus: `PaletteCatalog.swift:179` (`terminalOnly` blocks `.convertCompanion` on a page);
  `WorkspaceSidebar+ContextMenu.swift:115/126` already offers New Companion and Convert on any parentless row.
- Remote: `RemoteTree.swift:117`, `ControlServer+RemoteCompanions.swift` (`attachRemotePageRow`,
  `attachedParentRows` endpoint check at :233), `AppStore+ReplicaPage.swift:46`, `AppActions+RemoteAttach.swift`,
  `ControlServer+RemoteGroup.swift:11` (terminal-only root).
- Contracts: `.claude/rules/control-api.md`, `sidebar.md`, `windows.md`.

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
- run only the tests a task touches (`swift test --filter`, `-only-testing:`); full gates run once in Task 7
- maintain backward compatibility: a snapshot without a page descriptor restores as a terminal

## Testing Strategy
- **unit tests**: host-free `agtermCore` tests for store, snapshot, Recent Closed, dispatcher, bridge, CLI and
  remote tree; hosted `agtermTests` for ControlServer, overlay registry, sidebar, actions and remote attach.
- **e2e tests**: one targeted `agtermUITests/ControlAPIUITests` case for `session overlay --page` plus a
  companion under it, run with `-only-testing:`; never the whole suite.

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope
- keep plan in sync with actual work done

## Solution Overview
- **Creation**: `session overlay --html F | --url U --page`, exclusive with `--companion`, sends a new
  `session.page` wire command. It reuses the page source flags and validation; like a page companion it takes
  only file and URL sources. The page lands in the target's workspace right after the target's whole group;
  `session move` places it anywhere else, including an empty workspace. `--follow` selects the new row. A
  remote target is only a local placement anchor; creation is never forwarded. Its own wire command, so an older
  app answers "unknown command" instead of opening a terminal overlay.
- **Page parents**: `companionSlot` already accepts a page root; New Companion, `session new --parent`, and
  `session.companion.new` from a page's bridge create companions under it. Convert to Companion becomes
  available for a top-level page in the Session menu, palette and keymap, matching the sidebar.
- **Persistence**: every local page row, top-level or companion, is saved with a page descriptor and restored in
  every restart mode. Restart modes keep governing terminal companions only. A failed load keeps the row, its
  identity and its companions in the ordinary failed-page state with reload. Remote replica rows stay unsaved.
- **Close safety**: a page's `window.close()` on a page row goes through the app's session close, honoring the
  close-confirmation setting and the grace-period undo, since the row can own terminal companions. Control
  `session.overlay.close`/`submit` keep their non-prompting store path.
- **Remote**: the origin lists local page roots and their companions; the viewer attaches a page root as a
  top-level replica row, its companions under it, through the existing page-serve channel.

**Security**
- Untrusted input: the page source path or URL from a CLI or bridge request, validated by the existing page
  source rules; saved descriptors are read back from the app's own state file.
- New capability: a saved `--js` file page reloads at every launch, in every restart mode and on a Recent
  Closed reopen, and runs its scripts with the existing full control bridge without a user action. That is
  broader than a restored `--command`, which reruns only in Re-run commands mode. It is bounded by the file
  the user named with `--js` and whatever that file loads; URL pages still get no bridge. The docs state this.
- `window.close()` from any page with JavaScript, URL pages included, can no longer close terminals without the
  close-confirmation setting and undo.

## Technical Details
- `SessionSnapshot.page: PageSnapshot?` (nil = terminal) with `source` (file path plus optional grant root, or
  URL), `javascript`, `navigation`, `chromeless`, `persistent`, `browse`, `backgroundColor`. Existing id,
  parentID, order, cwd, name, context, tint, flag and fold fields are kept as they are for terminals.
- `Session.isPersistable` admits a local page row; `locallyManagedPaneIdentities`, `persistedClaims` and
  `PaneIdentityInventory.upgrade` skip page descriptors, since a page owns no daemon.
- `session(from:)` builds `Session(content: .page)` directly; the overlay opens after the group is in place,
  through `openHtmlOverlay`. A failed load leaves the row in `HtmlLoadState.failed`; the creation-time
  file-existence refusal never discards a saved row.
- `session.page` result: `id`; read back through `tree` (`content: "page"`, `parent` absent) and
  `htmlOverlays`.
- A page row's `initialCwd` is the anchor's local focused cwd, separate from `--cwd`, which stays the file read
  grant.
- Cmd-clicked markdown and text files keep opening overlays on the clicked terminal session; they are not page
  rows and are not saved.

## What Goes Where
- **Implementation Steps** (`[ ]` checkboxes): code, tests, docs, the review and the local demo.
- **Post-Completion** (no checkboxes): the second-Mac check.

## Implementation Steps

### Task 1: Page rows as companion parents
**Files:**
- Modify: `agtermCore/Sources/agtermCore/PaletteCatalog.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreCompanionsTests.swift`, `agtermCore/Tests/agtermCoreTests/PaletteCatalogTests.swift`
- Modify: `agtermTests/WorkspaceSidebarCompanionsTests.swift`, `agtermTests/AppActionsCompanionsTests.swift`

- [x] remove `.convertCompanion` from `PaletteCatalog.terminalOnly` so Convert matches the sidebar on a
      top-level page; Duplicate as Companion stays terminal-only
- [x] pin with tests: a companion under a page root, New Companion on a page companion lands under its root,
      Convert on a top-level page, group close and undo of a page-rooted group
- [x] write tests for refusals and availability: remote page row as parent, palette availability per row kind
- [x] run touched tests - must pass before task 2

### Task 2: Save and restore every local page row
**Files:**
- Modify: `agtermCore/Sources/agtermCore/Snapshot.swift`, `AppStore+Snapshot.swift`, `Session.swift`
- Modify: `agtermCore/Sources/agtermCore/WindowLibrary.swift`, `ZmxLifecycle.swift`
- Modify: `agtermCore/Sources/agtermCore/RecentClosed.swift`, `AppStore+RecentClosed.swift`, `AppStore+PendingClose.swift`, `WindowLibrary+RecentClosed.swift`
- Modify: `SnapshotRoundTripTests.swift`, `RecentClosedTests.swift`, `WindowLibraryRecentClosedTests.swift`, `AppStoreCompanionsTests.swift`, the zmx claim and identity inventory tests

- [x] `PageSnapshot` descriptor on `SessionSnapshot` for file and URL pages, written for every local page row and
      never for a replica; older snapshots without it restore as terminals
- [x] `isPersistable` admits local page rows; `locallyManagedPaneIdentities`, `persistedClaims` and
      `PaneIdentityInventory.upgrade` skip page descriptors
- [x] restore rebuilds the page row directly in every restart mode, after its group is placed; a missing file,
      refused grant or failed URL leaves a failed page row with its companions and reload
- [x] Recent Closed records a page group together, keeps parentID on a separately closed companion so the
      parent-first reopen recovers the page, and carries the descriptor in session, workspace and window entries
- [x] update the control-api.md bullet saying a page row is excluded from the first save
- [x] write tests: file and URL round trip with options, a page parent with terminal and page companions,
      restore per restart mode, failed load row, Recent Closed group and single-companion reopen, replica rows
      absent from the snapshot, zmx claim walk and identity inventory skipping pages in open and closed windows
- [x] run touched tests - must pass before task 3
- ➕ `LaunchSpawnPlan` skips a restored page row, whose pane key no surface would ever claim; `addPageCompanion`
      saves after its page is placed; a hard group close snapshots companions before closing them
      (`AppStore.swift`), since closing a page companion drops its page. `RecentClosed.swift` and
      `WindowLibrary+RecentClosed.swift` needed no change

### Task 3: session.page command and the --page CLI flag
**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`, `ControlDispatcher+Companions.swift`, `ControlActions.swift`, `ControlActionsDefaults.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+Companions.swift` (top-level page creation beside `addPageCompanion`)
- Modify: `agterm/Control/ControlServer+Companions.swift`
- Modify: `agtermCore/Sources/agtermctlKit/SessionCommands.swift`
- Modify: `ControlDispatcherCompanionsTests.swift`, `HtmlBridgeTests.swift`, `AppStoreCompanionsTests.swift`, `agtermctlKitTests/OverlayCommandsTests.swift` (or the existing overlay CLI test file), `agtermTests/ControlServerCompanionPageTests.swift`, `agtermUITests/ControlAPIUITests.swift`

- [x] store API creates a top-level page after the anchor's whole group, sharing the overlay-open and
      refusal path with `addPageCompanion`; a refused page removes the row again
- [x] `session.page` wire command, dispatcher, ControlServer handler, `--follow` selects the new row, a remote
      anchor creates a local page
- [x] `pageCompanionRefusal`'s error names a page session, not a page companion; update its tests
- [x] CLI `session overlay --html|--url --page`, exclusive with `--companion`, same source and size/pane refusals
      as `--companion`, too-old-app message, help text for `--follow`
- [x] write tests: dispatcher success and refusals, placement after a group, bridge default target (test only,
      no bridge code change), CLI request shape and flag conflicts, ControlServer handler
- [x] write the targeted UI test: `session overlay --page` then `session new --parent <page>`, read back in
      `tree`
- [x] run touched tests - must pass before task 4 (host-free and hosted pass; the UI test passed in Task 7)
- ⚠️ the UI test lives in `agtermUITests/ControlCompanionsUITests.swift`, since `ControlAPIUITests.swift` sits at
      its 2000-line lint budget; its run was stopped at setUp ("Failed to activate application", state Running
      Background) while another `com.umputun.agterm.debug` instance from another worktree was running, so it
      still needs one run with no other Debug instance open

### Task 4: Page window.close goes through the app session close
**Files:**
- Modify: `agterm/Views/HtmlOverlayRegistry.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+Panes.swift` (`closeOverlay` page branch) if the routing needs it
- Modify: `agtermTests/HtmlOverlayRegistryTests.swift`

- [x] `webViewDidClose` on a page row calls the app session close (honoring the confirmation setting, grace-period
      undo, group close); an overlay covering a terminal keeps closing only the overlay
- [x] clear `closeRequested` once the close is handed off, and on a confirmation cancel, so an Undo remount or a
      later mount does not close or prompt again
- [x] control `session.overlay.close`/`submit` keep their non-prompting store path
- [x] ➕ the failed-page view offers Reload through the existing registry reload path whether or not the page has
      `--navigation` or is chromeless, so a restored page whose file or server comes back can be retried; hosted
      test: a restored page with a missing file renders the failure, the file appears, Reload loads it
- [x] ➕ Task 2 comment cleanup: drop the PageGroup MARK in `RecentClosedTests.swift` and the `addPageRow` docstring
      in `AppStoreTestFixtures.swift`; state the save-after-open constraint once and condense `isPersistable`'s doc
- [x] write tests: `window.close()` on a page row with companions goes through the session close; undo after it
      does not re-close; cancel does not re-prompt; a terminal overlay closes only the overlay; control close
      stays non-prompting
- [x] run touched tests - must pass before task 5
- ➕ the hook is `HtmlOverlayRegistry.closePageSession`, wired by `ControlServer` beside `dispatch` to
      `AppActions.closeSession`; `AppStore+Panes.swift` needed no change. The failure view's Reload lives in
      `HtmlOverlayView.swift`, tested in the new `agtermTests/HtmlOverlayViewTests.swift`; the wired close and the
      non-prompting control close are tested in `ControlServerCompanionPageTests.swift`

### Task 5: Attach a page-rooted group from another Mac
**Files:**
- Modify: `agtermCore/Sources/agtermCore/RemoteTree.swift`, `AppStore+ReplicaPage.swift`
- Modify: `agterm/Control/ControlServer+RemoteCompanions.swift`, `ControlServer+RemoteGroup.swift`
- Modify: `agterm/AppActions+RemoteAttach.swift`
- Modify: `RemoteTreeTests.swift`, `AppStoreReplicaPageTests.swift`, `agtermTests/ControlServerRemotePageTests.swift`, `agtermTests/ControlServerRemoteGroupTests.swift`, `agtermTests/RemoteAttachTests.swift`

- [x] origin tree lists local page roots without a daemon requirement, excludes replica rows, admits page
      companions under a page root, and reports the root's full companion membership
- [x] viewer creates a page root as a top-level replica row, rechecking its window and workspace after the async
      handoff; page bindings record the origin host, endpoint and name with an empty daemon map
- [x] `attach.group` accepts a page root and attaches it through the page path before its members; the picker
      offers page roots and still hides page companions
- [x] existing refusals stay: markdown, text, document pages and loopback URLs are not shown remotely
- [x] write tests: tree listing including an empty daemon inventory, a replica root never re-exported, root
      replica placement, destination window or workspace closed during the handoff leaves no row, companion
      auto-attach under a replica page root, group attach with a page root and partial results, picker filtering,
      page-channel EOF while the root and its companions are parked for undo finalizes the group
- [x] run touched tests - must pass before task 6
- ➕ the store side is `AppStore.addReplicaPageRoot` beside `addReplicaPageCompanion`; `attachRemotePage` takes a
      `RemotePageSpot` (`.companion(of:)` or `.root(store:workspace:)`) and a `RemoteBinding.Origin`. The single
      `zmx attach` root and companion auto-attach tests live in `ControlServerRemoteCompanionsTests.swift`, beside its
      page-attach fixtures, and the origin-side top-level page hand-out in `ControlServerCompanionPageTests.swift`;
      `ControlServerRemotePageTests.swift` (the presenter path) needed no change

### Task 6: Product docs, command reference and agent skill
**Files:**
- Modify: `site/docs.html`, `site/commands.html`
- Modify: `plugins/agterm/skills/agterm/SKILL.md`, `plugins/agterm/skills/agterm/reference.md`
- Modify: `.claude/rules/control-api.md`, `.claude/rules/sidebar.md`, `.claude/rules/windows.md` as the contracts change

- [x] document `--page`, page parents, restore behavior including the launch-time `--js` execution, failed rows,
      and remote attach of page groups
- [x] `site/commands.html` mirrors `session.page`, its arguments and read-back
- [x] control-api.md: `session.page` in the public catalog and its contract; contract notes updated once,
      cross-referenced, no repeated facts
- [x] SKILL.md trigger and section for top-level page sessions; reference.md entry
- ➕ refusal strings now name a page session: `not a page session`, `a markdown, text or document page cannot be shown
      on another Mac`, `a page session has no terminal to duplicate`; `site/llms.txt` names page sessions, `site/index.html`'s
      card does not

### Task 7: Verify acceptance criteria and gates
- [x] verify every Overview and Solution Overview point is implemented
- [x] verify edge cases: page parent closed with undo, failed restore row, replica not saved, older snapshot
- [x] `scripts/build.sh` Release build succeeds
- [x] run `cd agtermCore && swift test`
- [ ] run `make test-app`
  ⚠️ unresolved. Full runs on the final tree: run 1 passed (1897 tests, before the round 1 fixes), run 2 failed
  `ControlServerZmxTests.testRealClientPaneChangesFromSupervisorToOrphanedWhileBarePaneReadsApp`, run 3 failed
  `SessionHostClientTests.testClientQueuedBehindStalledPeersStillJoinsTheHost` (1905 tests, 1 failure each).
  Both are one mechanism: the session host's own `zmx attach` prints `session ... created`, fails to connect with
  `FileNotFound`, exits 1, and the client's bare-attach fallback roots the pane at the app. The first test failed
  0 of 20 times alone and 2 of 20 times beside concurrent core SessionHost tests. Evidence is in
  `/tmp/agterm-session-host-evidence/*/host.log` and `zmx-logs`. Who unlinks the new socket name is unknown. It
  is the backlog item `session-host-sometimes-creates-an-app-rooted-daemon`, re-filed on master in e72082a1 with
  these sightings; this branch changes no session host or zmx code.
- [x] run `make lint`
- [x] run the targeted UI test once with `-only-testing:`
  passed (8.4 s) once no other `com.umputun.agterm.debug` instance was running

### Task 8: revmux review until clean
- [x] run revmux on the branch; fix every gating finding and re-run until a round reports none
  round 1 (comprehensive): 1 major, 1 minor, fixed in 63b75b37; round 2 (final): nothing actionable
- [x] ➕ live check in an isolated instance: a page row's `window.close()` waits while a picker is pending in its
  window and closes once `pick cancel` ends it, with no remount or session switch

### Task 9: Local demo
- [x] build Debug and launch an isolated instance (short `/tmp` state dir, `windows` marker, clean environment)
- [x] stage a top-level page session with `--js`, a terminal companion and a page companion under it
- [x] leave it running and describe how to reach it

### Task 10: [Final] Update documentation
- [x] update README.md if the synopsis should mention page sessions
- [x] update CLAUDE.md if new patterns were discovered
- [ ] move this plan to `docs/plans/completed/`
  ⚠️ implementation complete; only the hosted gate above is unresolved, tracked by its backlog item

## Post-Completion
*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Manual verification**
- quit and relaunch the demo instance in each restart mode, confirm the group returns; delete the page file and
  relaunch to see the failed row and reload
- second Mac: attach the page-rooted group, confirm the page renders and its bridge acts on the origin

Smells pre-check: skipped — non-Go project
