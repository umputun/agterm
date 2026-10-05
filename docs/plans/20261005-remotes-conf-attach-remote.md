# remotes.conf and a built-in Attach Remote action

## Overview

Attaching a session from another Mac works today only through `agtermctl zmx tree` / `zmx attach`, glued
together by a user-written script bound as a `keymap.conf` custom command with a hard-coded host. This
plan adds a config file naming the remote machines and a built-in action that runs the whole flow
natively: pick a machine, pick one of its sessions, attach it in the window the action started in.

- `remotes.conf` in the config directory lists the machines.
- File ▸ Attach Remote…, the command palette and a `keymap.conf` chord all reach one built-in action.
- `agtermctl zmx remotes` reads the same list, so scripts and agents do not locate or parse the file.

## Context (from discovery)

- Remote attach: `agterm/Control/ControlServer+Zmx.swift` (`remoteTree(host:)`,
  `attachRemoteSession(host:session:window:)`), `agtermCore/Sources/agtermCore/RemoteSession.swift`
  (`isPlain`, argv builders), `agterm/Control/RemoteCommandProcessRunner.swift` (ssh off the main actor, runs
  to its own deadline, no cancellation).
- Config files: `agtermCore/Sources/agtermCore/ConfigPaths.swift` (paths, starters),
  `agtermCore/Sources/agtermCore/Hooks.swift` (parser with line diagnostics), `agterm/SettingsModel.swift`
  (loading, starter writing, diagnostics banner).
- Action seam: `agtermCore/Sources/agtermCore/BuiltinAction.swift`, `PaletteCatalog.swift`
  (`PaletteCommand.isVisible` / `isEnabled`, `PaletteContext`), `agterm/agtermApp+Menus.swift` (File menu),
  `agterm/AppActions.swift` (`editHooks`, `uiActionsEnabled`, `dismissPendingModal`),
  `agterm/AppActions+Palette.swift` (`paletteContext`).
- Picker: `agtermCore/Sources/agtermCore/Pick.swift` (`PickController`, `modalPending`; a result is
  readable through `result(for:)` but nothing can await one), `agterm/Views/WindowContentView.swift`
  (`pickPaletteOverlay`, modal focus lifecycle, `handleClosedEditorOverlays`),
  `agterm/Control/ControlServer+Pick.swift`.
- Control: `ControlProtocol.swift` (`zmx.*` commands), `ControlDispatcher+Zmx.swift`,
  `agtermCore/Sources/agtermctlKit/ZmxCommands.swift`.

## Development Approach

- **testing approach**: regular (code, then tests, inside the same task).
- Work in a worktree forked from fetched `origin/master`.
- Every task ends with its tests written and passing. A new or changed test runs targeted
  (`swift test --filter`, `-only-testing:`); the full gates run once, in the verification task.
- Load `swiftui-expert` for the menu and picker work, `swift-concurrency` for the flow, and
  `swift-testing-expert` for tests.
- Update this file when scope changes during implementation.

## Testing Strategy

- **agtermCore unit tests**: parser, paths, starter, catalog visibility and enablement, dispatcher, picker
  controller.
- **hosted tests (`agtermTests`)**: the native flow against a fake of the remote-call seam defined in
  Task 4, so no test opens a real ssh connection and the `private` `FakeRemoteRunner` in
  `ControlServerZmxTests.swift` stays where it is.
- **UI tests (`agtermUITests`)**: menu item presence and absence only. The flow itself needs a second Mac
  and is covered by hosted tests plus the manual check under Post-Completion.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix

## Solution Overview

Decisions already taken with Eugene; implementation follows them and does not reopen them.

- **File format**: one remote per line, `destination [label...]`. The first token is the single argument
  ssh receives. The trimmed rest of the line is an optional picker label that may contain spaces and
  defaults to the destination. Whole-line `#` comments only.
- **Read on use**: the file is parsed each time it is needed. There is no Reload Remotes item.
- **Always shown**: Attach Remote… is in the menu and reachable by its chord whether or not any remote
  is configured. With no valid entry it reports "No remotes configured" and points at File ▸ Edit
  Remotes…, so there is no cached state about the file and nothing to refresh.
- **Existing `HOST` arguments stay literal**: `zmx tree` and `zmx attach` gain no alias lookup. A label is
  presentation; the destination is identity.
- **Cancellation boundary**: Esc, ⌘W or closing the window abandons the flow up to the moment a session
  is picked. Picking a session commits the attach. `attachRemoteSession` is not modified.
- **No GUI-flow control command**: the flow is `zmx remotes` + `pick` + `zmx attach`, all scriptable, so
  starting the native picker from the socket adds nothing. Record that exemption in `control-api.md`.

## Technical Details

### remotes.conf

```
# one remote per line: destination [label]
studio.local
umputun@192.168.1.33   Mac Studio
mini                   office mini
```

- Destination must pass `RemoteSession.isPlain` and must not start with `-`, the same rule the argv
  builders apply, so an entry the picker offers can never be refused later as an invalid host.
- A `#` after the first column is label text, not a comment.
- Diagnostics carry a line number: invalid destination, duplicate destination (the first one wins).
  Duplicate labels are allowed; the picker shows the destination as the row's subtitle.
- Three outcomes are distinct: file missing (no entries, no diagnostics), file present with entries and
  diagnostics, file present but unreadable (an error).

### Native flow

1. Invocation captures the initiating window id, then reads the file. No valid entry: the panel says
   "No remotes configured" and names File ▸ Edit Remotes…; Esc ends the flow.
2. More than one entry: the native picker asks which machine (label as the row, destination as subtitle).
   One entry skips this step.
3. The chosen destination is captured for the rest of the flow, so an edit to the file cannot redirect it.
4. Listing: await the existing `remoteTree(host:)`. During the wait the flow owns the window's modal slot
   as a loading phase of `PickController`, so `uiActionsEnabled` is false, the action cannot start twice,
   and ⌘W dismisses the flow where it would otherwise close the session underneath. The window shows
   which machine is being listed.
5. The session picker shows one row per attachable session: name, then far-side window/workspace,
   context, cwd and pane programs as the subtitle, the same fields the cookbook recipe shows.
6. Picking a session calls `attachRemoteSession(host:session:window:)` with the captured window id.
7. Before a session is picked, Esc, ⌘W and window close end the flow and release the modal slot. A
   lookup abandoned mid-flight runs to its deadline and its result is dropped; it never opens a picker.
   A failure does not release the slot by itself: it replaces the loading text with a message (step 9).
8. After a session is picked the attach is committed. Its second discovery shows progress that cannot be
   dismissed, and the attach's response, ok or not, clears it.
9. Every message of the flow is shown in its own panel, the one that showed the loading text, and Esc
   closes it: no remotes configured, ssh's error text, "nothing to attach on HOST", an unreadable file, a
   list over the picker's item limit, a refused attach. No macOS notification is used, because those
   are gated by the notifications setting and the action would then fail silently.

The flow lives in `AppActions`, which has no reference to `ControlServer` (the server holds the
actions, not the reverse). A narrow protocol declared beside the flow, with the two calls it needs
(`remoteTree(host:)`, `attachRemoteSession(host:session:window:)`), is what `AppActions` holds. The
protocol is `@MainActor` and class-bound and the property is weak: `ControlServer` already holds the
actions strongly, and `agtermApp.swift`, which owns both, assigns it right after constructing the server.

The panel phase of `PickController` has three states: dismissible loading, non-dismissible loading and a
dismissible message. The controller keeps the model, `AppActions` owns the remote calls and the message
text, `WindowContentView` renders it and owns input focus.

Two kinds of cancellation reach the controller through one `cancel` today and must be told apart:

- user dismissal (`AppActions.dismissPendingModal`, from Esc and ⌘W) leaves a non-dismissible panel in
  place;
- forced teardown (`AppActions.cancelAllPendingModals` at quit, `PickRegistry.unregister` at window close)
  clears every state and resolves any waiter, so a committed attach never blocks quit or window cleanup.
  `attachRemoteSession` then refuses the closed window before touching the model.

Each flow run has an identity the panel keeps through loading, picker and message, invalidated on
dismissal and teardown. A late result from an abandoned run is checked against it, so cancelling run A,
starting run B and then finishing A neither replaces nor clears B's panel.

While any of the three states holds the slot, control commands that need it, pick and GUI ask alike, are
refused with an error naming the panel phase; the existing "pick pending" and "ask pending" wording is
unchanged. The tree's `pickPending` stays empty because no pick exists. That read-back gap is deliberate,
since only a GUI action creates the state and nothing can act on it from the socket, and is recorded in
`control-api.md` beside the pick contract.

`PickController` needs two additions: a loading phase that counts toward `modalPending` and is cancelled
by the existing dismissal paths, and a completion an in-app caller can await in place of polling
`result(for:)`, resumed exactly once, after the result is recorded and the pending pick is cleared. `WindowContentView` owns the picker overlay and its focus lifecycle, so the loading phase
is audited there for focus and teardown, not only in the controller.

### Control

`zmx.remotes` returns the ordered entries (`destination`, `label`) and the parse diagnostics from the
same parser, read from the running app's resolved config directory. No reachability check, no ssh, no
write verbs. `agtermctl zmx remotes` prints one line per entry and supports `--json`.

## What Goes Where

- **Implementation Steps**: code, tests and docs in this repository.
- **Post-Completion**: the two-Mac manual check, which no automated test can perform.

## Implementation Steps

### Task 1: remotes.conf parser, path and starter in agtermCore

**Files:**
- Create: `agtermCore/Sources/agtermCore/Remotes.swift`
- Modify: `agtermCore/Sources/agtermCore/ConfigPaths.swift`
- Create: `agtermCore/Tests/agtermCoreTests/RemotesTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ConfigPathsTests.swift`

- [x] parse `destination [label...]` into ordered entries plus line diagnostics, per Technical Details
- [x] expose `ConfigPaths.remotesPath(configDirectory:)` and a commented starter in which every line is a
  comment
- [x] tests: label default, label with spaces, `#` inside a label, whole-line comments and blank lines,
  invalid and dash-leading destinations, duplicate destination keeps the first, starter parses to nothing
- [x] tests: path resolution under a custom, isolated and default config directory
- [x] targeted `swift test --filter` passes

### Task 2: `zmx remotes` across protocol, dispatcher and CLI

**Files:**
- Create: `agtermCore/Tests/agtermCoreTests/ControlProtocolZmxTests.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`, `ControlPayloads.swift`,
  `ControlDispatcher.swift`, `ControlDispatcher+Zmx.swift`, `ControlActionsDefaults.swift`
- Modify: `agtermCore/Sources/agtermctlKit/ZmxCommands.swift`, `SocketClient.swift` (human formatter)
- Modify: `agterm/Control/ControlServer.swift` (exhaustive fallback switch),
  `agterm/Control/ControlServer+Zmx.swift`, `agterm/SettingsModel.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherZmxTests.swift`,
  `MockControlActions.swift`, `agtermCore/Tests/agtermctlKitTests/ZmxCommandsTests.swift`,
  `agtermTests/ControlServerZmxTests.swift`

- [ ] add the `zmx.remotes` command and its result payload (entries, diagnostics), optional on the wire so
  an older server reads as absent
- [ ] the app adapter reads the file from the resolved config directory through one loader that the
  native flow in Task 4 also uses; an unreadable file is a not-ok response, a missing one is an empty list
- [ ] `agtermctl zmx remotes` with plain and `--json` output
- [ ] tests: request/result round-trip and the absent-field case in `ControlProtocolZmxTests.swift`
  (`ControlProtocolTests.swift` is at its 2000-line limit), dispatcher routing, CLI formatting
- [ ] tests: the command through the dispatcher into the app adapter against a temp config directory:
  missing, populated, with diagnostics, unreadable
- [ ] targeted tests pass

### Task 3: picker loading phase and in-app completion

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Pick.swift`
- Modify: `agterm/Views/WindowContentView.swift`, `agterm/AppActions.swift` (user dismissal against forced
  teardown), `agterm/Control/ControlServer+Pick.swift`, `agterm/Control/ControlServer+Ask.swift` (the
  panel-phase refusal)
- Modify: `agtermCore/Tests/agtermCoreTests/PickTests.swift`, `agtermTests/ControlServerPickTests.swift`,
  `agtermTests/ControlServerAskTests.swift`

- [ ] `PickController` loading phase that counts toward `modalPending` and carries the text shown while
  waiting; a dismissible one is cancelled by Esc, ⌘W and window teardown through the existing dismissal
  paths, a non-dismissible one only by its owner and by window teardown
- [ ] a message state in the same phase, replacing the loading text and dismissed by Esc, ⌘W and teardown
- [ ] user dismissal and forced teardown are separate entry points, per Technical Details
- [ ] the flow identity that makes a late result from an abandoned run a no-op
- [ ] pick and GUI ask opened over any panel state are refused with the panel-phase error; the existing
  pick and ask wording is unchanged and the tree's `pickPending` is unaffected
- [ ] a completion an in-app caller can await for a pick; the socket result path is unchanged
- [ ] `WindowContentView` renders the loading and message states in the picker overlay and keeps the focus lifecycle
  and teardown correct for it
- [ ] tests: loading blocks a second pick or ask and reports the right pending error, each dismissal path
  releases a dismissible phase, Esc and ⌘W leave a non-dismissible one in place while teardown releases it,
  a message replaces loading and releases the slot on dismissal, the awaited completion delivers picked and cancelled, quit and window close clear a non-dismissible
  panel and resolve its waiter, cancel run A then start B then finish A leaves B's panel intact, the
  completion resumes once, socket pick and ask behavior unchanged
- [ ] targeted tests pass

### Task 4: Attach Remote and Edit Remotes: actions and flow

**Files:**
- Modify: `agtermCore/Sources/agtermCore/BuiltinAction.swift`, `PaletteCatalog.swift`
- Create: `agterm/AppActions+RemoteAttach.swift` (the flow, the seam protocol and `editRemotes`;
  `AppActions.swift` is 982 lines against a 1000 limit, so nothing but stored state goes there)
- Modify: `agterm/agtermApp.swift`, `agterm/Control/ControlServer+Zmx.swift` (seam conformance),
  `agterm/agtermApp+Menus.swift`, `agterm/AppActions.swift`, `agterm/AppActions+Palette.swift`,
  `agterm/SettingsModel.swift`, `agterm/Views/WindowContentView.swift` (`handleClosedEditorOverlays`),
  `agterm/Notifications/NotificationManager.swift` (a Remotes diagnostics banner; the Hooks one
  hardcodes its title and a Settings destination that does not apply)
- Modify: `agtermCore/Tests/agtermCoreTests/BuiltinActionTests.swift`, `PaletteCatalogTests.swift`,
  `agtermTests/AppActionsPaletteTests.swift`, `agtermUITests/MenuUITests.swift`
- Create: `agtermTests/RemoteAttachFlowTests.swift`, `agtermTests/RemotesEditTests.swift`

- [ ] `attach_remote` built-in with no default chord; the pinned action count in `BuiltinActionTests`
  moves with it
- [ ] the remote-call seam protocol, its `ControlServer` conformance and its assignment in `agtermApp.swift`
- [ ] `PaletteCommand` cases for Attach Remote and Edit Remotes, always visible, enabled under the usual
  modal and workspace gates
- [ ] File menu: Attach Remote… in the session group, Edit Remotes… beside Edit Hooks…, each with an SF
  Symbol
- [ ] Edit Remotes writes the starter when the file is missing, opens it in the editor overlay like
  `editHooks`, and on close posts a Remotes diagnostics banner that points at `agtermctl zmx remotes`
- [ ] the flow in steps 1 to 9 of Native flow, including the one-entry shortcut and the captured window
  and destination
- [ ] tests: catalog enablement under the modal and workspace gates, keymap parsing of the new name,
  the action dispatched from a chord
- [ ] tests: a missing file, an empty file and a file with only invalid lines each produce the
  "No remotes configured" message, and dismissing it releases the modal slot
- [ ] tests (fake runner): single entry goes straight to listing; several entries ask for the machine;
  the attach receives the initiating window even when another window became frontmost; an edit to the
  file after the machine is chosen does not change the destination
- [ ] tests: dismissal during listing opens no picker when the late result arrives; the action cannot
  re-enter while loading; ⌘W during loading leaves the session open; ssh failure, empty remote list and
  unreadable file each show their message in the panel and release the modal slot on dismissal; progress during the committed attach
  clears on its response
- [ ] tests (Edit Remotes, after `HooksEditTests`): the starter is written when the file is missing, an
  existing file is kept, the overlay session is marked, diagnostics are reported on close
- [ ] UI test: both items are present in the File menu with no remotes file
- [ ] targeted tests pass

### Task 5: Verify acceptance criteria

- [ ] every item in Overview and Solution Overview is implemented as decided
- [ ] Debug build succeeds (`scripts/build.sh` for Release as well)
- [ ] `cd agtermCore && swift test`
- [ ] `make test-app`
- [ ] `make lint` with zero findings
- [ ] `lsappinfo list | grep -A4 agterm.debug` shows no leaked test instance

### Task 6: [Final] Update documentation

- [ ] `site/docs.html`: Remote sessions (the file, the menu item, the cancellation boundary), the
  built-in action list, and the config files section
- [ ] `site/llms.txt` config file list; `ARCHITECTURE.md` parser list
- [ ] `site/commands.html`: `zmx remotes` with its fields
- [ ] `plugins/agterm/skills/agterm/SKILL.md` and `reference.md`: `zmx remotes`, `attach_remote`
- [ ] `.claude/rules/control-api.md` (Remote sessions, the no-GUI-flow-command exemption), `keymap.md`,
  `menu-actions.md`, and the loading-phase read-back note beside the pick contract
- [ ] `site/index.html` and `README.md` only if they list remote attach among features
- [ ] `cookbook/remote-session-picker` is left untouched; no `CHANGELOG.md` entry
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification**, in an isolated Debug instance with its own `remotes.conf` and a second Mac in
Live sessions mode:

- one entry: the action lists that machine's sessions directly and the picked one attaches in the window
  the action started in
- two entries: the machine picker appears first
- Esc while listing: no picker appears afterwards and the session underneath is untouched
- unreachable machine: the panel shows ssh's own error, with agterm's notifications setting off
- empty file: the action reports "No remotes configured"; after adding a line in Edit Remotes it lists
  that machine with no reload step

Smells pre-check: skipped — non-Go project
