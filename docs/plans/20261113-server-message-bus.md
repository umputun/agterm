# Pane mailbox on agterm-server

## Overview
- `msg send`, `msg read` and `msg ack` are refused on agterm-server (discussion #994): the server's default-deny
  `ServerCommandPolicy` never got them, and the message bus plan (`completed/20261030-message-bus.md`) predates
  agterm-server, so its "remote rows excluded" line is no approved exception.
- Serve the three commands on the server between panes of that same server: main, split and scratch panes of its
  sessions, with the same identity, delivery, lifetime and read-back contract as on the Mac.
- Deliver the `message` event for server mail to an attached Mac, so its hooks and `events.read` subscribers see
  it as they do for a local pane.
- Decisions by Eugene (2026-11-13):
  - a local Mac session and an attached server session messaging each other is a parity gap tracked as not yet:
    refused by name and recorded in `docs/backlog/`;
  - the refusal keeps `reason: "unknown pane"` and adds an optional `detail: "remote session"`;
  - a server scratch's mailbox reads back on the session node (`scratchPaneID`, `scratchPendingMessages`);
  - the `message` event for server mail is built in this branch.
- Add a guard test that classifies every control command for the server, so the next command added to the
  protocol cannot be refused there without a decision.

## Context (from discovery)
- `ControlDispatcher+Messages` owns validation and the `MessageBus.shared` operations; a host only resolves
  addresses (`resolveMessagePane`), lists `--all` panes (`messagePanes`) and reports a queued message
  (`messageQueued`). `ServerActions` already dispatches through `ControlDispatcher` (`ServerActions.swift:38`) and
  inherits the unsupported defaults from `ControlActionsDefaults.swift`.
- `MessageBus` is Foundation-only. Server panes already carry `AGTERM_SESSION_ID`/`AGTERM_PANE_ID`
  (`ServerPanes.swift:66`, `agtermEnvironment`), so the CLI's identity works unchanged.
- The server runs the shared `AppStore` (headless, no control event sink, `AgtermServer.swift:62`). Its panes
  have no surfaces: liveness is `Session.daemonBackedPanes` plus `scratchDaemon`, as `ServerActions+Sessions.swift`
  `daemonPane` resolves it. `AppStore+Messages.swift` `livePanes`/`emitMessageQueued` read realized surfaces only.
- Disposal sites in `AppStore` (split close, primary close/promotion, respawn, restart, session/workspace/window
  leave) already run on the server. Gaps: `markSessionEnded` (`AppStore+Panes.swift:401`) drops daemon
  ownership without disposing mail; `disposeMailboxes(of:)` finds the scratch only through `scratchSurface`.
- Read-back: the tree's `pendingMessages` follows daemon identities for main/split (`AppStore.swift:392`). Every
  `surfaces[]` entry is a `surface.zoom` address (`ControlProjection.swift:4`, `TerminalZoom.swift:57-60,225`),
  and the server's scratch path never sets `scratchActive` (`ServerActions+Scratch.swift`), so a server scratch
  cannot carry its mailbox in `surfaces[]`. The session node already has `scratchBacked` and `scratchCwd`.
- Catalog: main and split `CatalogPane` changes travel as `pane.changed`; the scratch's `CatalogPane` sits inside
  `CatalogSessionFields.scratch`, so its changes travel as `session.changed` (`CatalogDiff.swift:88`).
  `ServerActions` refreshes the catalog hub after every dispatch (`ServerActions.swift:40`). The Mac re-attaches
  only on a daemon or endpoint change (`AppStore+Catalog.swift` `updateCatalogSession`).
- Events: a server-side `notify` reaches an attached Mac as a presentation frame (`AppStore+Events.swift:71`,
  handled at `RemotePresentationClient.swift:247`); an older Mac decodes an unknown frame kind as `.unknown`
  (`PresentationFrames.swift:868`).
- The Mac forwards only `RemoteOperation.structuralCommands` to a server (`RemoteOperation+Request.swift:12`);
  `session text`/`type`/`status` act on the Mac's own surface or store. No route carries `msg.*`.
- `agtermctl` decodes the whole `ControlResponse` before returning (`SocketClient.swift:67`), so a new
  `MessageRejection.Reason` case would make an older CLI lose the whole reply.
- `agtermCore` is consumed by agterm-linux: no new case on public enums such as `MessagePaneError.Kind`.
- `ServerCommandPolicyTests` checks hand-picked commands; `Command` is not `CaseIterable`.

## Development Approach
- **testing approach**: TDD. Each task starts with failing tests against the real `ServerActions`/`AppStore`
  (host-free) or the real `ControlServer` adapter (hosted), run to confirm they fail, then the code.
- complete each task fully before moving to the next; all tests pass before the next task.
- update this plan when scope changes.
- Mac local-pane messaging keeps its behavior; the only Mac change is the named rejection for a remote row.

## Testing Strategy
- **host-free** (`cd agtermCore && swift test --filter <Suite>` while working): `ServerActionsMessagesTests`,
  `AppStoreMessagesTests`, `ControlDispatcherMessagesTests`, `MessageBusTests`, `CatalogFramesTests`,
  `CatalogDiffTests`, `ServerCatalogTests`, `RemoteCatalogMirrorTests`, `PresentationFramesTests`,
  `RemotePresentationClientTests`, `agtermctlKitTests/MessageCommandsTests`, `ServerCommandPolicyTests`.
- **hosted**: `-only-testing:agtermTests/ControlServerMessagesTests` for the Mac adapter's remote-row rejection.
- final gates once: `make build`, `cd agtermCore && swift test`, `make test-app`, `make lint`.

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix

## Solution Overview
- The server becomes a full bus host: `ServerActions` implements the host requirements over the headless store's
  daemon panes, and the policy serves `msg.*`. Delivery stays inside one server process; the Mac's `remoteHost`
  filters stay, since mail queued in the Mac's bus could never reach a server reader.
- Lifetime follows the Mac's contract: dispose by departing identity at each site, keep a promoted survivor's
  mail, never dispose on a viewer's detach or disconnect. Mail stays run-local: a server restart loses it while
  the daemons survive, the same guarantee as an app run on the Mac.
- Read-back: the server tree reports `pendingMessages` for main and split surfaces and the session-level scratch
  fields; the counts ride on `CatalogPane` to an attached Mac, whose tree shows them for the remote row.
- Events: a queued server message is published as a `message` presentation frame to the recipient's session, and
  every Mac with a presentation subscription for that session emits the existing `message` control event for
  the remote row. A detached row has no subscription and a reconnect replays no events, as with `notify`; the
  pending counts remain the read-back. `events.read` on the server
  itself stays refused (undecided in the guard), since serving events there covers every event kind.
- Guard: `Command: CaseIterable`; one test requires exactly one class per case: served, `physicalWindowCommands`,
  or an explicit undecided list that claims neither an exemption nor a commitment; an undecided entry that is
  served or physical fails the test.

## Technical Details
- Live server pane: main `paneIdentity` and split `splitPaneIdentity` when in `daemonBackedPanes`, and
  `scratchDaemon.identity`. A page row and an ended row's main/split have none; an ended row's running scratch
  stays a recipient. Hidden split and hidden scratch stay recipients.
- Roles resolve as on the Mac: `left`/`right`/`scratch` pick the slot's pane now; a pane id must be one of the
  session's live panes; identities are `SESSION:PANE-ID` only. `--all` lists the server's live panes,
  `--workspace` narrows; `--window` takes the catalog id or `active`.
- `MessageRejection.detail: String?`, omitted when nil. A Mac recipient on a remote row: `unknown pane` with
  `detail: "remote session"`, carried from the resolver's message, never by parsing an error string. A remote row
  as `--as` identity: refused with an error naming `remote session`.
- `CatalogPane.pendingMessages: Int?`, omitted at zero, absent on decode from an older peer. The Mac keeps mirrored
  counts on the row's `Session`, so they go with the row on detach or removal.
- Session node: `scratchPaneID: String?`, `scratchPendingMessages: Int?` for every server-owned scratch, on the
  origin and the mirror, independent of a local scratch surface; a local Mac scratch keeps `surfaces[]`.
- `PresentationMessage { pane, from?, messageID }` frame kind `message`, no body.

## What Goes Where
- **Implementation Steps**: code, tests and docs in this repository.
- **Post-Completion**: manual check on a real Linux host.

## Implementation Steps

### Task 1: Serve the mailbox on agterm-server and name the remote refusal on the Mac

**Files:**
- Create: `agtermCore/Sources/AgtermServerKit/ServerActions+Messages.swift`
- Create: `agtermCore/Tests/AgtermServerTests/ServerActionsMessagesTests.swift`
- Modify: `agtermCore/Sources/AgtermServerKit/ServerCommandPolicy.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+Messages.swift`, `MessageBus.swift`,
  `ControlDispatcher+Messages.swift`; `agterm/Control/ControlServer+Messages.swift`;
  `agtermCore/Sources/agtermctlKit/MessageCommands.swift`
- Modify: `AppStoreMessagesTests.swift`, `ControlDispatcherMessagesTests.swift`, `MessageBusTests.swift`,
  `agtermctlKitTests/MessageCommandsTests.swift`, `agtermTests/ControlServerMessagesTests.swift`

- [x] failing server tests: send/read/ack between two panes of one session and across sessions; role and pane-id
      recipients; scratch and hidden split as recipient and identity; a swap keeps mail with the identity;
      `--all` and `--workspace`; unknown pane rejected per recipient; an identity that is not a live pane
      refused on send, read and ack; page row and ended row main pane not addressable while an ended row's
      scratch is
- [x] failing Mac tests: a remote-row recipient rejected as `unknown pane` with `detail: "remote session"` while
      local recipients in the same send are delivered; a response with `detail` decodes into a legacy-shaped
      rejection model; human output prints the detail; a remote row as `--as` refused naming `remote session`;
      `--all` keeps excluding remote rows; `detail` omitted when nil
- [x] serve `.msgSend`, `.msgRead`, `.msgAck`; implement `resolveMessagePane` and `messagePanes` on `ServerActions`
      over the store's recipient lookup made daemon-aware for a headless store
- [x] add `MessageRejection.detail` and the remote-row rejection and identity refusal; CLI prints `detail` when
      present, else `reason`
- [x] run the Task 1 suites and the hosted `ControlServerMessagesTests` - must pass

### Task 2: Lifetime, read-back and the message event

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore+Panes.swift`, `AppStore+Messages.swift`, `AppStore.swift`,
  `ControlProjection.swift`, `CatalogFrames.swift`, `AppStore+Catalog.swift`, `PresentationFrames.swift`,
  `RemotePresentationClient.swift`; `agtermCore/Sources/AgtermServerKit/ServerCatalog.swift`,
  `ServerActions+Messages.swift`
- Modify: `AppStoreMessagesTests.swift`, `CatalogFramesTests.swift`, `CatalogDiffTests.swift`,
  `ServerCatalogTests.swift`, `RemoteCatalogMirrorTests.swift`, `PresentationFramesTests.swift`,
  `RemotePresentationClientTests.swift`, `ServerActionsMessagesTests.swift`

- [x] failing lifetime tests: ended session drops main/split mail and keeps a running scratch's; session and
      workspace deletion drops a daemon scratch's mail; split close and promotion keep the survivor's mail;
      viewer detach keeps all mail
- [x] failing read-back tests: server tree `pendingMessages` on main and split and `scratchPaneID`/
      `scratchPendingMessages` on the session; the count omitted at zero in the tree and the encoded
      `CatalogPane`; an old frame without it decodes; the Mac tree shows a remote row's main, split and scratch
      counts, before and after a local scratch surface is realized, through hide/show, and drops them at zero; a
      count-only `pane.changed` and a scratch-count-only `session.changed` trigger no re-attach and no scratch
      close; scratch replacement clears the old identity's count; an ended row's surviving scratch still updates
- [x] failing event tests: one `message` frame per delivered pane (several panes of one session each get one) with
      pane, from and message id and no body; two subscribers to the recipient session (one presenter, one
      mirror) each emit exactly one event per delivered pane; a subscription to the sender's session alone gets
      none; companion, hidden split and hidden never-materialized scratch recipients emit without a local
      surface; an ended row's scratch emits; a full mailbox emits none; an unknown kind stays ignored; a
      reconnect snapshot emits no message events
- [x] dispose at `markSessionEnded` by departing identity; `disposeMailboxes(of:)` also covers `scratchDaemon`
- [x] session-level scratch fields on origin and mirror; `pendingMessages` on `CatalogPane` from
      `catalogWorkspaces`, mirrored on the row's `Session` and read by `controlTree` for `remoteHost` rows
- [x] `messageQueued` on `ServerActions` calls `presentationHub.publish(.message(...), session:)` per delivered
      pane, never `sendToPresenter`; `message` joins `PresentationHub.supportedKinds`
- [x] `RemotePresentationClient.apply` handles `.message` outside any presenter check, as `.notify`, through a new
      `RemotePresentationEffects` callback with a default for existing callers; the Mac emits the event bound to
      the local row, its window and workspace and the transported pane UUID, without `messageRecipient`/
      `livePanes`, and never republishes it
- [x] run the Task 2 suites - must pass

### Task 3: Classify every command for the server, then docs and gates

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift` (`CaseIterable`)
- Modify: `agtermCore/Tests/AgtermServerTests/ServerCommandPolicyTests.swift`
- Modify: `site/commands.html` (msg section, "On agterm-server" served list, tree fields), `site/docs.html`
  (msg section), `plugins/agterm/skills/agterm/reference.md` (msg, tree fields, agterm-server list),
  `.claude/rules/control-api.md` (message bus, read-back, server policy)
- Create: `docs/backlog/local-to-server-messaging.md`

- [ ] `Command: CaseIterable`; one test requires exactly one class per case: served, `physicalWindowCommands`, or
      the undecided list as test data; an undecided entry that is served or physical fails
- [ ] docs: msg between panes of one agterm-server, mail per server run, the `message` event reaching each Mac
      subscribed to the recipient's session, `events.read` not served on the server, the new tree fields and `detail`, and both unsupported
      directions (a Mac session to a server session: `unknown pane` with `detail: "remote session"`; a server
      pane to a Mac session: `unknown pane`)
- [ ] backlog item: local-to-server messaging (two-way route over ssh, sender identity, replies, mixed recipients,
      `--all` scope) as the open parity gap
- [ ] full gates once: `make build`, `cd agtermCore && swift test`, `make test-app`, `make lint`
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion
**Manual verification**:
- on a Linux host running the built agterm-server, two panes of one session exchange messages with
  `agtermctl msg send/read --wait/ack`; the attached Mac's `tree` shows the pending count and its event hook
  fires for the server mail

Smells pre-check: skipped — non-Go project
