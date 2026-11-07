# Convert to Companion

## Overview
- A session the user started as an ordinary top-level session often turns out to belong under another
  task. "Convert to Companion" turns a running top-level session S into a companion without touching its
  running program: a fresh session N takes S's slot in the sidebar, and S nests under N.
- S keeps its identity (id, name, flag, tint, status, context, surfaces, pane identities, zmx daemons,
  mailboxes), so `AGTERM_SESSION_ID`, agent hooks and chat mailboxes keep working.
- S may already have companions. They stay with S: all of them, S first, become companions of N.
- S ends selected so the user sees the conversion took effect; N is never selected.
- The design was agreed with codex in the brainstorm; Eugene chose the label and the CLI spelling.

## Context (from discovery)
- Companion store logic: `agtermCore/Sources/agtermCore/AppStore+Companions.swift` (`addCompanion`,
  `companionSlot`, `groupEnd`, `regroupedCompanions`, `respawnsOnLastPaneExit`).
- `Session.parentID` (`agtermCore/Sources/agtermCore/Session.swift:84`) is documented "set once at
  creation, never changed" (#840); this plan changes that contract.
- Reopen paths that resolve a recorded parent: `restoreRecentClosed`
  (`agtermCore/Sources/agtermCore/AppStore+RecentClosed.swift`), `restorePendingSession`
  (`agtermCore/Sources/agtermCore/AppStore+PendingClose.swift`), and `holdsTopLevelSession` /
  `recentClosedItemLacksParent` / `reopenRecentClosedOutcome`
  (`agtermCore/Sources/agtermCore/WindowLibrary+RecentClosed.swift`).
- Control: `ControlProtocol.swift` (`session.companion.*` cases), `ControlDispatcher+Companions.swift`,
  `ControlActions.swift` / `ControlActionsDefaults.swift`, app side `agterm/Control/ControlServer+Companions.swift`.
- CLI: `agtermCore/Sources/agtermctlKit/SessionCommands.swift` (companion forms are flags on existing
  subcommands: `session new --parent`, `session duplicate --companion`).
- GUI: `agtermCore/Sources/agtermCore/BuiltinAction.swift`, `PaletteCatalog.swift`,
  `agterm/AppActions+Companions.swift`, `agterm/agtermApp+Menus.swift`,
  `agterm/Views/WorkspaceSidebar+ContextMenu.swift`.
- Rules to read before each layer: `.claude/rules/control-api.md`, `sidebar.md`, `menu-actions.md`, `keymap.md`.

## Development Approach
- **testing approach**: TDD. Each task writes its failing tests first, runs them to see them fail, then
  implements.
- complete each task fully before moving to the next; small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
- **CRITICAL: all tests must pass before starting next task**
- **CRITICAL: update this plan file when scope changes during implementation**
- scoped test runs while working (`swift test --filter`, `-only-testing:`); the full gates run once in the
  verification task, per this repo's CLAUDE.md

## Testing Strategy
- **unit tests** (host-free, `cd agtermCore && swift test`): store conversion, reopen resolution,
  dispatcher, CLI request shaping, palette/builtin catalogs.
- **hosted tests** (`make test-app`): `AppActions` entry point, `ControlServer` command, sidebar context menu.
- **UI test**: one end-to-end case in `agtermUITests/ControlCompanionsUITests.swift`, run alone with
  `-only-testing:agtermUITests/ControlCompanionsUITests/<test>`; never the whole suite for this change.

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- keep plan in sync with actual work done

## Solution Overview
- One store operation in `agtermCore` does the whole conversion and is the seam every caller shares:
  menu, row context menu, palette, keymap and control.
- The conversion keeps S's `Session` object, so nothing about the running program changes; zmx daemon
  names derive from pane identity, not from the parent.
- N is an ordinary new session created through `addSession`, so it gets the usual shell, cwd handling,
  automatic name and `session.created` event.
- Reopen resolves a recorded parent to its current top-level root at insert time instead of rewriting
  stored Recent Closed or pending-close history, so entries written by any path stay correct.
- No general reparent API (`session move --parent`): nothing here needs batch, cross-workspace or promote
  semantics.

## Technical Details

**Store operation** (`AppStore+Companions.swift`):
- `convertToCompanion(_ id: UUID) -> Result<Session, ConvertRefusal>` returns N.
- Refusals (`ConvertRefusal`, its own enum: `CompanionRefusal.remoteParent` is shared with companion creation,
  so a convert message on it would be wrong there): `noSuchSession`; `alreadyCompanion`; `remoteSession`
  (`remoteHost != nil`, reported as "convert it on the Mac it runs on").
- Steps:
  1. resolve S's workspace and index;
  2. N's cwd is S's `focusedCwd` (S is local, so `localWorkingDirectory` would return it unchanged);
  3. `addSession(toWorkspace:cwd:at: S's index, select: false)`;
  4. set `parentID = N.id` on S and on every companion of S, keeping order N, S, S's old companions;
     capture S's companions before writing S's `parentID`, since `companions(of:)` returns nothing for a
     companion;
  5. select S only when `selectedSessionID != S.id`, since `selectSession` also clears unseen, resets an
     auto-reset indicator and records recency;
  6. `scheduleTreeChanged()` and `save()`.
- N starts expanded (the default) and unflagged; S's flag and its place in `flaggedOrder` stay unchanged.
- Events: `session.created` for N only; `tree.changed` for the regroup; no create or close for S or its
  companions. `session.selected` is emitted only when the selected id actually changes.
- Parent-exit respawn moves to N with no code: `respawnsOnLastPaneExit` asks `companions(of:)`. S's last
  pane exiting now closes S like any companion.

**Reopen fix**:
- One helper resolving a recorded parent id to the session a restored companion must join: the parent
  itself when it is top-level, the parent's own parent when the recorded parent is now a companion (one
  hop, since nesting is one level).
- Applied in `restoreRecentClosed` and `restorePendingSession` before insertion and before
  `emitSessionCreated`, so the restored session's `parentID` and its event name the final parent.
- `holdsTopLevelSession` becomes a lookup for "an entry that restores this session": the entry's root
  snapshot, its `companions` snapshots, or any workspace member regardless of `parentID`. The rename
  follows the behavior.
- Sequences the fix must pass, each starting with "close C under S, convert S":
  1. reopen C with S open: C lands under N;
  2. close S, reopen C: S's entry reopens first, then C lands under N;
  3. close N as a group, reopen C: N's entry (holding S in `companions`) reopens, then C under N;
  4. close the workspace holding N and S, reopen C: the workspace entry reopens, then C under N.
  - The same idea applies to undo of a pending close (soft close then convert then undo).
- Hard close of a group finalizes the parked companions of every group member, not only of the closed
  parent: `closeSession` (`AppStore.swift:595`) passes `[sessionID] + companions.map(\.id)` to
  `finalizeParkedCompanions`. Otherwise "soft-close C under S, convert S, hard-close N" leaves C parked
  with `parentID == S`, and its undo brings C back top-level with both recorded parents gone.

**Refusal text**: owned once in `agtermCore`, as a `message` on `ConvertRefusal` ("already a
companion", "convert it on the Mac it runs on"), used by both `ControlServer` and
`AppActions.convertToCompanion`.

**Remote viewers**: another Mac that attached S keeps the grouping it attached with; viewer grouping is
attach-time local state and nothing pushes a regroup. Accepted: a later attach reads the new group from
`zmx tree`.

**Control** (protocol `session.companion.convert`):
- Target is a session (id/prefix/active) plus `--window`.
- Reply: `result.id` = S, `result.parent` = N, matching the companion receipts.
- Read-back needs nothing new: session nodes already carry `parent`.
- CLI: `agtermctl session convert --companion [--target X] [--window W]`. `--companion` is required, so
  `convert` alone is a validation error naming the flag. `Convert` lives in `Session+Companions.swift`
  (`SessionCommands.swift` only registers it; it is 900 lines against the 1000-line cap). Human output
  prints N's id, the created session. An app predating the command answers through
  `companionSend(..., tooOld: "the running app is too old for convert")`.
- `ControlServer.swift` (976 lines) and `ControlProtocol.swift` (964) are near the cap: their edits stay
  the enum case and list entries.

**GUI**:
- `BuiltinAction.convertCompanion = "convert_companion"`, keyless.
- Enablement lives in `PaletteCommand.isEnabled(in:)`: new `PaletteContext` terms
  `activeSessionIsCompanion` and `activeSessionIsRemote`, populated in `AppActions.paletteContext`, a
  `.convertCompanion` case refusing either, and `.convertCompanion` added to `terminalOnly` like
  `.duplicateCompanion`. The palette row and the Session menu item both read it.
- Session menu item after Duplicate as Companion, calling `convertActiveSessionToCompanion()`, which keeps
  the `uiActionsEnabled` guard like `duplicateActiveSessionAsCompanion()`.
- Row context menu item after Duplicate as Companion, inside the single-selection (`sessionCount == 1`)
  block. It is omitted on companion rows, as Duplicate as Companion is on page rows, and disabled on
  remote rows.
- `AppActions.convertToCompanion(_:in:)` shared by all three; a refusal shows the `ConvertRefusal` message in
  the timed `RemoteAttachHud` over the session, as Duplicate as Companion's refusal does, falling back to
  `notifyCommandFailure`.

## What Goes Where
- **Implementation Steps**: code, tests and docs in this repo.
- **Post-Completion**: the manual look in an isolated Debug instance.

## Implementation Steps

### Task 1: Store conversion in agtermCore

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore+Companions.swift`
- Modify: `agtermCore/Sources/agtermCore/Session.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreCompanionsTests.swift`

- [x] write failing tests: plain conversion (N at S's slot, S under N, N's cwd from S, N not selected,
  S keeps id/name/flag, and the same `Session` object, surfaces and pane identities survive); selection
  with a different session selected beforehand, so S ending selected is proven; S with companions (order
  N, S, old companions, all pointing at N); refusal for a companion target, a remote row, an unknown id;
  events (one `session.created` for N, no create/close for S); respawn duty (N respawns with companions,
  S closes on its exit); persistence round-trip keeps the group; the converted group closed and reopened,
  and soft-closed and undone, restores N, S and the old companions with their parent links
- [x] implement `convertToCompanion` and `ConvertRefusal` with its message per Technical Details
- [x] update the `parentID` doc on `Session` to the new contract (one line)
- [x] run `swift test --filter AppStoreCompanionsTests` - must pass before task 2

### Task 2: Reopen resolves a recorded parent to its current root

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+Companions.swift` (`groupRoot(of:)`)
- Modify: `agtermCore/Sources/agtermCore/AppStore+RecentClosed.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+PendingClose.swift`
- Modify: `agtermCore/Sources/agtermCore/WindowLibrary+RecentClosed.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreCompanionsTests.swift` (the pending-close cases sit beside
  the existing parked-companion tests there, not in `AppStorePendingCloseTests`)
- Modify: `agtermCore/Tests/agtermCoreTests/WindowLibraryRecentClosedTests.swift`

- [x] write failing tests for the four reopen sequences in Technical Details, the pending-close undo case,
  and "soft-close C, convert S, hard-close N: C's pending close is final"; confirm each fails on the
  current code (C lands at a second level, comes back top-level, or the reopen is refused)
- [x] add the parent-resolution helper and apply it in both restore paths before insertion and the event
- [x] finalize parked companions over the whole closing group in `closeSession`
- [x] widen `holdsTopLevelSession` to companion snapshots and every workspace member, renamed
  `restoresSession`
- [x] confirm `recentClosedItemLacksParent` follows the widened lookup (the `recent.open` error text stays)
- [x] run the affected test classes - must pass before task 3

### Task 3: Control command and CLI

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlActions.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlActionsDefaults.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher+Companions.swift`
- Modify: `agtermCore/Sources/agtermctlKit/Session+Companions.swift`
- Modify: `agtermCore/Sources/agtermctlKit/SessionCommands.swift`
- Modify: `agterm/Control/ControlServer.swift`
- Modify: `agterm/Control/ControlServer+Companions.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherCompanionsTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/MockControlActions.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/SessionCompanionsCommandsTests.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/SocketClientTests.swift`
- Modify: `agtermTests/ControlServerCompanionsTests.swift`
- Modify: `agtermUITests/ControlCompanionsUITests.swift`

- [x] write failing tests: dispatcher routing; CLI `session convert --companion` request shape, the
  missing-flag validation error and the human output naming N (`SessionCompanionsCommandsTests`); the
  "too old for convert" mapping (`SocketClientTests`); hosted `ControlServer` conversion (reply ids, tree
  read-back `parent`, selection, and the real companion and remote refusal texts)
- [x] write the UI test: start a persistent program in S that holds private state, convert over the
  socket, read the tree back, and confirm the same program answers with that state afterwards
- [x] add `session.companion.convert`, route it in `ControlDispatcher.swift`'s switch into
  `dispatchCompanionCommand` and in `ControlServer.swift`'s dispatcher-owned list (not `waitsOnNetwork`:
  the convert is local only), add the `ControlActions` method and its default, the `ControlServer`
  implementation over `convertToCompanion`, and the `Convert` CLI subcommand
- [x] run the dispatcher, CLI and hosted tests; run the single UI test only after asking Eugene
  (ui-tests.md); then `lsappinfo list | grep -A4 agterm.debug` - must pass before task 4
- ⚠️ the tests were written first but not run red before the implementation; they referenced symbols that
  did not exist yet, which is not an observed failing run
- ⚠️ the UI test's first run died at runner init ("Timed out while enabling automation mode", no test case
  started); the retry passed and `lsappinfo` showed no leftover Debug app

### Task 4: Menu, row context menu, palette and keymap

**Files:**
- Modify: `agtermCore/Sources/agtermCore/BuiltinAction.swift`
- Modify: `agtermCore/Sources/agtermCore/PaletteCatalog.swift`
- Modify: `agterm/AppActions+Companions.swift`
- Modify: `agterm/AppActions+Palette.swift`
- Modify: `agterm/agtermApp+Menus.swift`
- Modify: `agterm/Views/WorkspaceSidebar+ContextMenu.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/BuiltinActionTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/PaletteCatalogTests.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/SocketClientTests.swift`
- Modify: `agtermTests/AppActionsCompanionsTests.swift`
- Modify: `agtermTests/WorkspaceSidebarCompanionsTests.swift`

- [x] write failing tests: `convert_companion` parses and is keyless (`BuiltinActionTests` `allCases`
  count 54 to 55, plus the two tables that pin every action); the palette row exists (`PaletteCatalogTests` count 61 to 62 and its title list) and
  `isEnabled(in:)` refuses a companion, a remote and a page session; the `keymap list` expected output in
  `SocketClientTests` gains `convert_companion`; `AppActions.convertToCompanion` converts and selects, and
  a refusal notifies with the store's message; the context menu shows the item on a single top-level row,
  omits it on a companion row, and disables it on a remote row
- [x] add the builtin action, the `PaletteContext` terms and `isEnabled(in:)` case, the `terminalOnly`
  entry, the palette row, `AppActions` entries, the Session menu item and the row context menu item
- [x] run the affected core and hosted tests, then `lsappinfo list | grep -A4 agterm.debug` - must pass
  before task 5
- ⚠️ as in Task 3, the tests were written first but failed only at compile time against the missing symbols

### Task 5: Docs, skill and rules

**Files:**
- Modify: `README.md` (its Companion line said "pinned for life")
- Modify: `site/docs.html`
- Modify: `site/commands.html`
- Modify: `plugins/agterm/skills/agterm/SKILL.md`
- Modify: `agtermCore/Tests/agtermCoreTests/SkillInstallTests.swift` (run only; edit only if a pinned
  string changes)
- Modify: `plugins/agterm/skills/agterm/reference.md`
- Modify: `.claude/rules/control-api.md`
- Modify: `.claude/rules/sidebar.md`
- Modify: `.claude/rules/menu-actions.md`

- [x] `site/docs.html`: one sentence in the Companions section, and `convert_companion` in the keymap
  action list
- [x] `site/commands.html`: `session convert --companion`, its arguments and reply; correct "pinned for
  life to the parent" (around line 1164)
- [x] skill: a `reference.md` entry, `convert_companion` in its built-in action list (around line 2046),
  "pinned for life" corrected in `reference.md` (around 511) and `SKILL.md` (around 371), and the trigger
  ("make this session a companion") in `when_to_use`, since `description` is at its 1024-unit limit
- [x] rules: the store seam and the reopen root resolution in `sidebar.md`, plus the new item in its
  single-target list (line 94); in `control-api.md` the Public catalog entry `.companion.convert` and the
  `waitsOnNetwork` sentence, which must exclude the local-only convert; the menu and context-menu placement
  in `menu-actions.md`
- [x] run `swift test --filter SkillInstallTests`

### Task 6: Verify acceptance criteria
- [x] verify every Overview requirement, including selection and existing companions
- [x] `cd agtermCore && swift test`
- [x] `make test-app`
- [x] `make lint` with zero findings
- [x] `lsappinfo list | grep -A4 agterm.debug` after the hosted and UI runs
- ➕ `make test-app` failed on `AppDelegateCaptureTests/testExitCaptureReadsALiveListingSlowerThanAHundredMilliseconds`
  (from master, unrelated) in two of four full runs. Its fake zmx (`/bin/sh` plus `/bin/sleep`) finished as late as
  287 ms against the 300 ms budget under the suite's load; lowering the sleep to 0.12 s did not hold. It is now one
  `zsh -f` process waiting 120 ms with the `zselect` builtin, which still fails 3 of 3 against the old 100 ms
  budget; the final gate passed. The cause, a slow child or a late termination callback, was not observed at a
  failure, and the production budget is unchanged. 2 skips are by design (fish login shell, below-macOS-27 gate)

### Task 7: [Final] Update documentation
- [x] update README.md if needed (its Companion line was corrected in Task 5)
- [x] update CLAUDE.md if new patterns discovered (none: the rule files carry the new contracts)
- [x] move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification**:
- In an isolated Debug instance, convert a session running a program, with and without companions, and
  look at the sidebar: N in the old slot, S nested and selected, the program still running in S.
- Convert, close and reopen a companion from before the conversion, then relaunch the instance and check
  the group survived.

Smells pre-check: skipped - non-Go project
