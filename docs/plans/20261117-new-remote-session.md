# New Remote Session

## Overview
- File ▸ New Remote Session… creates a top-level session on another host and attaches it into the current
  window and workspace of a normal local window, as Attach Remote… does for an existing session.
- Problem: with nothing from that host attached yet, nothing on this Mac starts a session there. Today it takes
  `ssh HOST agtermctl session new …`, then Attach Remote…. Duplicate, split and scratch of an attached row
  already run on the origin since #999. A remote window (#1018) already creates sessions on its origin, so
  this action is for normal windows only.
- Source: discussion https://github.com/umputun/agterm/discussions/1033, agreed shape in the reply
  https://github.com/umputun/agterm/discussions/1033#discussioncomment-19675756.
- It reuses the create-on-origin and attach path that companions and attached-row Duplicate already use, so
  the new code is the destination choice on the host, the local placement, and the GUI and CLI entry points.

## Context (from discovery)
- Create on the origin, then attach here: `ControlServer.createRemoteCompanion`
  (`agterm/Control/ControlServer+RemoteCompanions.swift:67`) and attached Duplicate's `follow(.attachAfter)`
  (`agterm/Control/ControlServer+AttachedForward.swift:261`). Both run the origin's `agtermctl` once through
  `RemoteSession.controlCommand`, then `attachWhenListed` (`ControlServer+RemoteCompanions.swift:379`)
  polls `zmx tree` until the id is attachable and attaches through `attach(_:from:host:placement:)`.
- Host discovery: `ControlServer.remoteOrigin(host:)` (`agterm/Control/ControlServer+RemoteCatalog.swift:111`)
  answers `.mac(windows)`, `.server`, `.unanswered` or `.failed`; `RemoteOriginWindow.choose` and
  `RemoteOriginWindow.offered` pick the origin window; `windowRemoteOpen` shows the `--origin-window` refusals.
- GUI: `AppActions.attachRemote()`, `openRemoteWindow(_:in:)`, `pickRemote`, `pickOriginWindow` and
  `RemoteAttachHud` in `agterm/AppActions+RemoteAttach.swift`; `RemoteAttaching` protocol there.
- Menu enablement: `PaletteCommand` in `agtermCore/Sources/agtermCore/PaletteCatalog.swift` (`attachRemote` with
  `hasRemotes`, and `localOnly` disabling it in remote windows); `BuiltinAction` in `BuiltinAction.swift`.
- Origin side: `session new` already takes `--window`, `--workspace-name`, `--create-workspace`, `--cwd`,
  `--command`, `--no-select` (`agtermCore/Sources/agtermctlKit/SessionCommands.swift:26`); agterm-server resolves
  `--workspace-name` with `--create-workspace` through `ensureWorkspace`
  (`agtermCore/Sources/AgtermServerKit/ServerActions+Sessions.swift:341`).
- CLI: `session new --parent` already maps to its own wire command (`session.companion.new`) in
  `SessionCommands.New.makeRequest`; `--remote` follows the same pattern.
- Tests to follow: `agtermTests/ControlServerRemoteCompanionsTests.swift`, `ControlServerRemoteCatalogTests.swift`,
  `RemoteAttachTests.swift`, `AppActionsCompanionsTests.swift`; agtermCore dispatcher and palette tests;
  `agtermctlKitTests` for the CLI.

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
- run tests after each change, scoped to what changed (`-only-testing:` for hosted tests); the full gates run
  once at the end
- maintain backward compatibility

## Testing Strategy
- **unit tests**: agtermCore dispatcher, argv builder and palette enablement tests (`cd agtermCore && swift test`);
  CLI mapping and validation in `agtermctlKitTests`.
- **hosted tests**: `ControlServer` flow with the fake remote runner the companion and catalog tests already use,
  run per test with `-only-testing:agtermTests/<Class>/<test>`, then `make test-app` once at the end.
- **e2e**: no XCUITest reaches a real ssh host; the end-to-end path is covered by the hosted fake-runner tests,
  and the manual check under Post-Completion.

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope
- keep plan in sync with actual work done

## Decisions carried from the draft

The draft is the proposal in discussion 1033.

| Proposal decision | Status | Reason |
|---|---|---|
| File ▸ New Remote Session…, no default key | kept | |
| `agtermctl session new --remote HOST` | kept | the CLI flag maps to its own wire command, like `--parent` |
| host list from `remotes.conf`, single entry preselected | kept | the Attach Remote picker, which skips the question for one entry |
| destination typed by hand in the dialog | changed | CLI only; the menu uses `remotes.conf`, as Attach Remote does |
| directory and command in the dialog | changed | CLI only (`--cwd`, `--command`); the menu starts a plain shell |
| workspace with the same name as the current one | kept | |
| exactly one window with that name goes without asking, otherwise a dialog of windows and workspaces | dropped | the window is picked first (as Open Remote Window), then the existing create-or-reuse rule applies in it |
| new workspace name field, prefilled | dropped | create-or-reuse makes the missing workspace with the current name |
| CLI refuses a missing or ambiguous match until `--origin-window` / `--create-workspace` settle it | changed | `--origin-window` is required only when the Mac has several windows; the workspace is always create-or-reuse |
| `--workspace-name` names another workspace | kept | |
| row lands in the current local window and workspace | kept | captured before any wait and checked again before insertion |
| row behaves like any attached row | kept | it is created by the same `attach` |
| failure reported as Attach Remote reports one | kept | the `RemoteAttachHud` panel |
| Mac origins only, no server | changed | agterm-server hosts are included (Eugene's decision): no window pick, same workspace rule |

## Solution Overview
- A host-free `RemoteSessionCreate` in agtermCore owns validation and the argv sent to the origin, so the rule
  "window first, then create-or-reuse by name" lives in one tested place.
- `ControlServer.newRemoteSession` runs discovery, origin window choice, the single create, and
  `attachWhenListed` into the captured local workspace. The control command and the GUI both call it; the GUI
  adds the host picker, the origin-window picker and the HUD in front of it.
- Its own wire command, `session.remote.new`, so an app predating it fails to decode the request instead of
  dropping a `remote` field and creating a local session.

## Technical Details
- Wire: `Command.sessionRemoteNew = "session.remote.new"`. Arguments ride existing `ControlArgs` fields:
  `host`, `originWindow`, `workspaceName`, `cwd`, `command`, `window` (local window). Any other placement or
  creation field (`workspace`, `createWorkspace`, `after`, `before`, `parent`, `wait`, `name`, `noSelect`, tint)
  and an operation id (`opID`) are refused by the dispatcher, never dropped.
- Reply: `result.id` is the local row's id; read-back is that row's `remoteHost` and `remoteSessionID` on the
  `tree` node, which `attach` already sets.
- Origin argv (Mac): `session new --window <origin window id> --workspace-name <name> --create-workspace
  --no-select [--cwd DIR] [--command LINE]`. Server: the same without `--window`.
- Workspace name: the captured local workspace's name unless the request names one. First exact match on the
  origin when it has duplicates, which is the existing `workspace(named:)` rule.
- Strict discovery: the host's `version` reply must name what it is. A Mac advertises `macCatalog` (and must be
  Live), agterm-server advertises `headless: true`; any other reply, an older Mac included, is refused before
  anything is created. A host that does not answer fails with nothing created. `remoteOrigin` reads every
  non-Mac reply as a server and opens an unanswered host, which suits a remote window that retries; this
  action does not use that reading, and Open Remote Window keeps it unchanged.
- One discovery call, `ControlServer.remoteSessionOrigin(host:)`, exposed on `RemoteAttaching`, answers a Mac
  with its offered windows, a server, or a refusal. The control action calls it, then chooses the window with
  `RemoteOriginWindow.choose`; the GUI calls it, then shows the window picker. Both hand the resolved origin
  (a Mac window id, or the server) to the shared creator, so nothing probes the host twice.
- A transport failure whose reply is still a full receipt naming an id is reported with that id and the
  `zmx attach` recovery and never resent, as `createRemoteCompanion` does.
- One creation attempt. A reply that cannot be decoded is reported as unknown and never resent. A created id
  that does not attach is reported with `agtermctl zmx attach HOST ID`, the wording attached Duplicate uses.
- Local placement: a captured destination (window id, workspace id, workspace name) is taken once and passed to
  the shared creator. The GUI captures it before `pickRemote`, the control command at action entry. The
  placement closure in `attachWhenListed` re-resolves that same window's store and workspace and fails with the
  recovery text when either is gone, never retargeting another one. The row is appended to the workspace and
  selected, as Attach Remote does, so `--no-select` is refused.
- Remote window as destination: refused before anything is sent. The control command joins
  `ControlServer.localOnlyCommands` and the `placementStore` arm of `routedStore`
  (`agterm/Control/ControlServer+RemoteActions.swift:19`), as `zmx.attach` does; the menu row joins
  `PaletteCommand.localOnly`.

## What Goes Where
- **Implementation Steps** (`[ ]` checkboxes): tasks achievable within this codebase - code changes, tests,
  documentation updates
- **Post-Completion** (no checkboxes): items requiring external action - manual testing against a second Mac and
  an agterm-server host

## Implementation Steps

### Task 1: Wire command, dispatcher, argv builder and CLI

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Create: `agtermCore/Sources/agtermCore/RemoteSessionCreate.swift`
- Modify: the dispatcher file that owns session creation commands, and `ControlActions` (requirement with a
  refusing default for the agterm-linux conformer)
- Modify: `agtermCore/Sources/agtermctlKit/SessionCommands.swift`
- Modify: `agterm/Control/ControlServer.swift` (`waitsOnNetwork`)
- Create/Modify: matching tests in `agtermCore/Tests/agtermCoreTests` and `agtermCore/Tests/agtermctlKitTests`

- [x] add `Command.sessionRemoteNew` and a `ControlActions` requirement whose default refuses by name
- [x] add `RemoteSessionCreate`: destination validation through `RemoteSession`'s host check, the origin argv for a
      Mac (with `--window`) and a server (without), and the refusal texts
- [x] dispatcher arm: validates `host`, refuses the fields listed in Technical Details, passes the rest to the action
- [x] CLI: `session new --remote HOST` with `--origin-window`, `--workspace-name`, `--cwd`, `--command`, `--window`;
      `validate()` refuses `--remote` beside `--parent`, `--workspace`, `--create-workspace`, `--after`, `--before`,
      `--wait`, `--name`, `--no-select`, tint and the operation-id options, and refuses `--origin-window` without
      `--remote`; maps the decode error to `the running app is too old for remote sessions`
- [x] add the command to `waitsOnNetwork`
- [x] tests: argv for Mac and server with and without cwd/command; dispatcher accepts the minimal request and refuses
      each forbidden field and a bad host; the `ControlActions` default refuses; CLI request mapping, each
      validation refusal, and the too-old text
- [x] run the new and touched test suites with `swift test --filter` - must pass before task 2

### Task 2: ControlServer create-and-attach flow

**Files:**
- Create: `agterm/Control/ControlServer+RemoteSessionNew.swift`
- Modify: `agterm/Control/ControlServer+RemoteCompanions.swift` (make `attachWhenListed` reachable from the new file)
- Modify: `agterm/Control/ControlServer+RemoteCatalog.swift` only if discovery needs a no-retry entry point
- Create: `agtermTests/ControlServerRemoteSessionNewTests.swift`

- [ ] `newRemoteSession(_ destination:, origin:, ...)` takes a captured destination (window id, workspace id, name)
      and a resolved origin (Mac window id or server); the control action captures the destination at entry and
      the command joins `localOnlyCommands` and the `placementStore` arm, so a remote window is refused in
      `remoteRoute` before dispatch
- [ ] strict discovery `remoteSessionOrigin(host:)` on `RemoteAttaching`: `version` must carry `macCatalog` (Live)
      or `headless: true`, else refuse before creating; a Mac's windows come back offered; the control action
      chooses with `RemoteOriginWindow.choose` and refuses `originWindow` for a server
- [ ] run the create once, attach with `attachWhenListed` into the captured window's store and workspace, appended
      and selected
- [ ] failure paths: unanswered host, not-Live Mac and unidentified host create nothing; undecodable reply reported
      as unknown; origin refusal passed through; a failed transport with a full receipt, created-but-unattached
      and a closed destination report the id and `zmx attach` recovery, never resent
- [ ] implement the `ControlActions` requirement in the app so `session.remote.new` reaches it
- [ ] tests with the fake runner: Mac with one window, several windows without `originWindow` refused before any
      create, with `originWindow` sends `--window`; server omits `--window` and refuses `originWindow`; a `version`
      reply with app identity but neither `macCatalog` nor `headless` sends zero creates; argv carries the captured
      workspace name, or the requested one; unanswered and not-Live create nothing; unknown reply is not resent;
      non-zero ssh status with an ok receipt reports the id with nothing resent;
      attach failure and a workspace deleted during the wait give the recovery text; a remote window destination is
      refused with nothing sent; success returns the local id, the row's `remoteSessionID` is the origin id, and
      `session.created` and `remote.opened` are emitted
- [ ] run the new test class with `-only-testing:agtermTests/ControlServerRemoteSessionNewTests` - must pass before
      task 3

### Task 3: Menu, palette and keymap action

**Files:**
- Modify: `agtermCore/Sources/agtermCore/BuiltinAction.swift`, `PaletteCatalog.swift`, `Keymap.swift` if the
  built-in list needs it
- Modify: `agterm/AppActions+RemoteAttach.swift` (GUI flow and `RemoteAttaching`)
- Modify: the File menu in `agterm/agtermApp+Menus.swift`
- Modify: matching tests (`agtermCore` palette and keymap tests, `agtermTests/RemoteAttachTests.swift`)

- [ ] `BuiltinAction.newRemoteSession` (`new_remote_session`, keyless, in the keyless list) and a `PaletteCommand`
      row enabled by `hasRemotes && hasCurrentWorkspace`, as Attach Remote is, and in `localOnly`
- [ ] File ▸ New Remote Session… after Attach Remote…, disabled through `PaletteCommand.isEnabled(in:)`
- [ ] `AppActions.newRemoteSession()`: capture the destination (window id, workspace id and name) first, then
      `pickRemote`, `RemoteAttachHud` progress, `remoteSessionOrigin`, origin window picker when the Mac has several
      (`pickOriginWindow`), then the shared creator with that captured destination and resolved origin; failures
      in the HUD
- [ ] tests: update `BuiltinActionTests`' case count and keyless list and the palette partition test; palette
      enablement (no remotes, no current workspace, remote window, normal window), keymap action name, GUI flow
      through a fake `RemoteAttaching` (one host, several hosts, several origin windows, a host answering with no
      identity refused with nothing created, failure shown in the HUD); the selected workspace changes while the
      host and origin-window picks are pending, and both the origin workspace name and the final local placement
      stay the captured ones
- [ ] run the touched agtermCore tests and `-only-testing:` the touched hosted classes - must pass before task 4

### Task 4: Docs, skill, rules and final gates

**Files:**
- Modify: `site/docs.html` (Remote sessions), `site/commands.html`
- Modify: `plugins/agterm/skills/agterm/SKILL.md` and its reference file for remote sessions
- Modify: `.claude/rules/control-api.md` (catalog list and the Remote sessions contract), `.claude/rules/menu-actions.md`
- Move: this plan to `docs/plans/completed/`

- [ ] docs.html: New Remote Session… under Remote sessions, where it lands on the host, CLI form, normal windows only
- [ ] commands.html: `session new --remote` with its flags and read-back
- [ ] skill: section and a `description` trigger for creating a session on another Mac or server, and the action in
      the built-in action list of `plugins/agterm/skills/agterm/reference.md`
- [ ] `site/docs.html`: the action in its built-in action lists, beside `attach_remote`
- [ ] rules: `session.remote.new` in the public catalog and `localOnlyCommands`, its contract in control-api.md, the
      menu item in menu-actions.md, the case count in keymap.md
- [ ] verify every Overview requirement and the Decisions table against the code
- [ ] run gates once: `cd agtermCore && swift test`, `make test-app`, `make lint`
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion
*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Manual verification:**
- an isolated Debug instance against a second Mac in Live sessions mode: one window and several windows, a workspace
  that exists there and one that does not
- the same against an agterm-server host
- the row survives a relaunch and shows Disconnected while the host is unreachable

Smells pre-check: skipped — non-Go project
