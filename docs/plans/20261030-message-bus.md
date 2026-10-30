# Message bus between panes

## Overview
- Agents in different panes need to exchange messages without typing into each other's terminal: typing has
  no safe moment to insert, and a stale session id can deliver into the wrong agent's prompt.
- Add an app-run, in-memory mailbox per pane with three control commands: `msg.send`, `msg.read`, `msg.ack`
  (CLI `agtermctl msg send|read|ack`). How agents use it is out of scope; this is the transport.
- Delivery is retained and repeat-readable until acked, while the same program runs in the recipient pane
  in this app run. `msg read --ack` is the opt-in at-most-once mode.
- No UI. Read-back is a pending count on the tree's pane node plus a metadata-only `message` event.

## Context (from discovery)
- `ZmxLeadBook.shared` and `AskRegistry.shared` are the existing app-wide in-memory books in `agtermCore`;
  `AppStore.controlTree` already reads `ZmxLeadBook.shared` per pane, and `ZmxLeadBook.shared.forget(pane:)`
  is called at most pane-removal sites. The bus follows that shape.
- Dispatcher-first commands: `ControlDispatcher+<Area>.swift` in `agtermCore`, app effects through
  `ControlActions`, CLI in `agtermctlKit/<Area>Commands.swift`, registered in `Commands.swift`.
- Pane identity: a pane's `$AGTERM_PANE_ID` is its surface `paneToken`, which tree `paneID` also reports.
  Primary and split slots store it as `paneIdentity`/`splitPaneIdentity`; swap exchanges them between slots
  (`AppStore+Panes.swift:125`). Scratch has no stored identity: `agtermApp.swift` mints one per scratch
  surface and only the surface's `paneToken` carries it.
- Existing hooks do not match the bus lifetime: `paneFinalizer` fires only on hard removal (a soft close
  reaches it after the grace period), and `launchPaneDrop` also fires when a split is merely hidden.
- `ControlServer` runs a command before writing its reply (`ControlServer.swift:525`), so a destructive read
  can lose its batch if the reply fails.
- The accept loop is serial, so no command may block server-side; waiting is CLI-side polling, as
  `session wait` does over `events.read`.
- `Session.paneAddress` falls back to the role for `--pane-id`; the bus must not reuse that permissive
  contract.
- Strict SwiftLint caps are at their limit in files this work would touch: `ControlDispatcher.swift`
  (1000/1000), `WindowLibrary.swift` (999/1000), and the test files `ControlProtocolTests.swift`,
  `CommandsTests.swift`, `ControlAPIUITests.swift` (2000/2000) and `AppStorePaneTests.swift` (1982/2000).
- Rules: `.claude/rules/control-api.md` (catalog, read-back, unknown-argument rule, events),
  `ui-tests.md` for e2e.

## Development Approach
- **testing approach**: TDD - write the failing test for each contract first, then the code
- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - tests are not optional - they are a required part of the checklist
  - tests cover both success and error scenarios
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- no test is added to a file at its length cap; a test for an existing source file goes into that file's
  existing test file when it has room
- run the narrow test target after each change; the full gates (`make build`, `swift test`,
  `make test-app`, `make lint`) run once at the end

## Testing Strategy
- **unit tests** (host-free, `agtermCore`): mailbox model, address parser, store disposal, dispatcher
  validation and response shapes, protocol round trips, CLI parsing and output.
- **hosted tests** (`agtermTests`): the real `ControlServer` adapter for address resolution, broadcast,
  identity agreement, restart and window close/reopen disposal.
- **e2e** (`agtermUITests/ControlMessageUITests.swift`, a new class on `ControlAPITestCase`): two panes
  exchange messages through the real socket and through the bundled `agtermctl`, run with
  `-only-testing:` for that class only.

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- keep the plan in sync with the work actually done

## Solution Overview
- **`MessageBus`** (host-free, `agtermCore`, `@MainActor`, one `shared` instance for the app run like
  `ZmxLeadBook`; model tests create their own instances, integration fixtures dispose only their own pane
  ids): mailboxes keyed by pane token (UUID). It owns limits, FIFO order, batch reads, ack, read-and-ack, pending
  counts and `dispose(pane:)`. It knows nothing about sessions, windows or roles.
- **`MessageAddress`** (host-free value beside it): parses `SESSION:PANE`.
- **Addressing**: `PANE` is a pane token, or `left`/`right`/`scratch` for a recipient only, resolved once
  at send time to that slot's current token. A bare session is an error naming its pane addresses.
  Recipient aliases are deduplicated after resolution.
- **Live pane**: a realized surface with a non-empty `paneToken`. Recipients, identities and `--all` all
  use this one definition; a split hidden since launch has no surface and is not a live pane.
- **Identity** (reader for `read`/`ack`, sender for `send`): always `SESSION:PANE-ID`, never a role,
  because a swap re-points roles. The CLI builds it from `AGTERM_SESSION_ID` + `AGTERM_PANE_ID` or takes
  `--as SESSION:PANE-ID`. The server refuses an identity whose pane id is not a live pane of that session,
  naming both ids. No fallback to the active pane or to a role.
- **Anonymous send**: `send` without an identity is allowed only when both env fields are absent and no
  `--as` is given (a script outside agterm); `from` is then nil and `--all` excludes nobody. An incomplete,
  invalid or stale identity fails and never downgrades to anonymous. `read` and `ack` always require one.
- **Mailbox lifetime**: a mailbox lives while the same program runs in its pane in this app run. It is
  disposed whenever the pane leaves or its program is replaced: session close (hard and soft, companions
  included), workspace delete (hard and soft), split close, scratch close, the departing primary on
  `closePrimaryPane` (the promoted survivor keeps its mail), `respawnPrimaryPane`, `session.restart`, and
  window close or delete. A soft close later undone restores the pane with an empty mailbox. Hiding a
  split is not disposal. Pruning by "is this pane live now" cannot detect close-then-undo, so disposal
  happens at each site.
- **Broadcast**: `--all` = every live pane in every open window, hidden-but-realized panes included, remote
  rows excluded, the sender excluded; `--workspace W` narrows it.
- **Delivery result**: per recipient, accepted or rejected with a reason (full mailbox, unknown pane), so
  one full mailbox does not block the rest.
- **Read-back**: tree surface node `pendingMessages` (omitted at 0), populated in `AppStore.controlTree`
  from `MessageBus.shared`; `message` event after enqueue.

## Technical Details
- Limits (fixed constants): body ≤ 64 KiB UTF-8; per mailbox ≤ 256 messages and ≤ 1 MiB of bodies; read
  batch ≤ 32. A send that would exceed a recipient's limits is rejected for that recipient only.
- Message: `id` (UUID), `from` (`SESSION:PANE-ID` or nil for a sender outside agterm), `to`
  (`SESSION:PANE-ID`), `ts` (epoch seconds, `ControlEvent.ts` clock), `body`.
- `msg.read` returns the oldest unacked messages up to the batch limit plus `remaining` = pending messages
  not in this batch. Re-reading before ack returns the same prefix.
- `msg.read` with `ack: true` selects the batch and removes exactly those messages in one synchronous
  mailbox operation with no suspension between, and answers `acked: [ids]`, present even when empty.
  The CLI fails when `acked` is missing or does not match the returned ids, so an app that ignored the
  field cannot pass as a successful read-and-ack. Documented as at-most-once for the dequeue only.
- `msg.ack` takes message ids for the reader's own mailbox; unknown or already-removed ids are not an error.
  Answers `acked` with the ids actually removed.
- Disposal: one store-level method in a new `AppStore+Messages.swift` disposes the mailboxes of a set of
  pane tokens and is called from every site listed under Mailbox lifetime. Scratch disposal reads the
  token from the scratch surface before teardown. The window-close path routes through a store method
  the library already calls, so `WindowLibrary.swift` (999 lines) gains no lines.
- Event `message`: emitted through the recipient store's `emitControlEvent`, so `window`/`workspace` are
  set; `session` = recipient session, payload `paneID` = recipient pane, plus `from` and `messageID`; no
  body. `EventFormatter.human` prints sender, recipient and id.
- Protocol additions (`ControlArgs`): `recipients: [String]?` (the CLI's `--to`; the existing scalar `to`
  keeps its navigation meaning), `identity: String?`, `ack: Bool?`, `ids: [String]?`; reuse the existing
  `all`, `body` and `workspace`. `ControlResult`: `messageID`, `delivered`, `rejected`, `messages`,
  `remaining`, `acked`.
- CLI:
  - `agtermctl msg send (--to SESSION:PANE ... | --all [--workspace W]) [--as SESSION:PANE-ID]`,
    body from `TEXT` or `--stdin`
  - `agtermctl msg read [--as SESSION:PANE-ID] [--ack] [--wait] [--timeout N] [--json]`
  - `agtermctl msg ack ID... [--as SESSION:PANE-ID]`
  - `--wait` polls `msg.read` client-side until a message is pending or `--timeout`, using a watchdog
    like `SessionWaitWatchdog`.

## What Goes Where
- **Implementation Steps**: code, tests and documentation in this repository.
- **Post-Completion**: manual checks in an isolated Debug instance.

## Implementation Steps

### Task 1: Host-free mailbox model and address parser

**Files:**
- Create: `agtermCore/Sources/agtermCore/MessageBus.swift`
- Create: `agtermCore/Sources/agtermCore/MessageAddress.swift`
- Create: `agtermCore/Tests/agtermCoreTests/MessageBusTests.swift`
- Create: `agtermCore/Tests/agtermCoreTests/MessageAddressTests.swift`

- [x] tests first: FIFO order, batch limit and `remaining`, repeat read returns the same prefix, ack
      removes and is idempotent, read-and-ack removes exactly the batch, per-recipient rejection on count
      and byte limits, body limit, disposal empties one pane's mailbox only, pending count per pane
- [x] parser tests: `SESSION:PANE-ID`, role aliases accepted as recipients and refused as identity, bare
      session, empty parts, malformed ids, mixed-case ids
- [x] `MessageBus` with a `shared` instance, the limit constants, `send` (per-recipient result),
      `read(limit:)`, `readAndAck`, `ack(ids:)`, `pending(for:)`, `dispose(pane:)`
- [x] `MessageAddress`: role aliases for recipients only, identity form requires a pane id
- [x] run `cd agtermCore && swift test --filter 'MessageBusTests|MessageAddressTests'` - must pass before
      task 2

### Task 2: Protocol, dispatcher and events

**Files:**
- Create: `agtermCore/Sources/agtermCore/ControlDispatcher+<Area>.swift` (the chunk moved out unchanged)
- Create: `agtermCore/Sources/agtermCore/ControlDispatcher+Messages.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlEvents.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlProjection.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlActionsDefaults.swift`
- Modify: `agtermCore/Sources/agtermctlKit/EventCommands.swift` (`EventFormatter.human`, its switch is
  exhaustive over `ControlEventKind`)
- Modify: `agtermCore/Tests/agtermCoreTests/MockControlActions.swift`
- Create: `agtermCore/Tests/agtermCoreTests/ControlDispatcherMessagesTests.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/EventCommandsTests.swift`

- [x] first, before any new code: move one self-contained group of `ControlActions` requirements or
      routing out of `ControlDispatcher.swift` into a new `ControlDispatcher+<Area>.swift`, unchanged
      (approved by Eugene); existing tests stay green
- [x] tests first in the new `ControlDispatcherMessagesTests.swift`: request/response round trips for the
      three commands, validation errors (no recipient, recipients with `all`, bare session, role in an
      identity, body over the limit, missing identity for read/ack), per-recipient results, `acked` always
      present, `pendingMessages` omitted at 0, `message` event kind and payload, and a regression that the
      scalar `to` still round-trips for navigation commands
- [x] the human formatter line for `message` in the existing `agtermctlKitTests/EventCommandsTests.swift`
      (293 lines; `EventFormatter` is internal to `agtermctlKit`, which `agtermCoreTests` cannot import)
- [x] add `msg.send`, `msg.read`, `msg.ack` commands, the `ControlArgs`/`ControlResult` fields, and the
      `message` event kind with `from`/`messageID` payload fields, with its `EventFormatter.human` case
- [x] dispatcher validates and shapes responses; `ControlActions` supplies address resolution, the live
      pane set, identity agreement and event emission, with refusing defaults for outside conformers
- [x] `pendingMessages` on the tree surface node
- [x] run the new and touched test suites - must pass before task 3

### Task 3: Store disposal, app-side actions and e2e

**Files:**
- Create: `agtermCore/Sources/agtermCore/AppStore+Messages.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift` (session and workspace close sites, `controlTree`)
- Modify: `agtermCore/Sources/agtermCore/AppStore+PendingClose.swift` (soft close, soft workspace delete)
- Modify: `agtermCore/Sources/agtermCore/AppStore+Panes.swift` (split close, `closePrimaryPane`)
- Modify: `agtermCore/Sources/agtermCore/AppStore+Companions.swift` (`respawnPrimaryPane`)
- Modify: the scratch close path and the store method called on window close or delete
- Create: `agterm/Control/ControlServer+Messages.swift`
- Modify: `agterm/Control/ControlServer+Restart.swift`
- Create: `agtermCore/Tests/agtermCoreTests/AppStoreMessagesTests.swift`
- Create: `agtermTests/ControlServerMessagesTests.swift`
- Create: `agtermUITests/ControlMessageUITests.swift`

- [x] host-free store tests first: disposal on session close (hard and soft), companions closed with their
      parent, workspace delete (hard and soft), split close, scratch close and `respawnPrimaryPane`;
      `closePrimaryPane` disposes only the departing primary identity while the promoted survivor keeps
      its mail; hiding a split keeps the mailbox; mail sent before a soft close is gone after undo with no
      bus operation between (regression); `pendingMessages` in `controlTree`
- [x] hosted `agtermTests` first, against the real adapter rather than `MockControlActions`: broadcast
      across two windows, `--workspace` narrowing, sender exclusion, anonymous broadcast, remote rows
      excluded; recipient aliases resolving to one pane are delivered once; a scratch pane as recipient and
      as identity; a split hidden since launch is not a live pane; identity mismatch refused on send, read
      and ack; stale or incomplete identity never downgrades to anonymous; `session.restart` and window
      close then reopen dispose the mailbox; the `message` event carries `window` and `workspace`
- [x] e2e test first, real socket: pane A sends to pane B, B sees `pendingMessages` in tree, reads, acks,
      count drops; a swap keeps the mailbox with its pane id; `read --ack` then an empty read and a
      cleared pending count
- [x] `AppStore+Messages.swift` disposal method called from every lifetime site; `ControlServer` uses
      `MessageBus.shared` and resolves addresses across all open windows without the frontmost-window
      default; identity agreement enforced server-side for send, read and ack
- [x] emit `message` through the recipient store after enqueue; populate `pendingMessages` in `controlTree`
- [x] run the new store, hosted and e2e tests (`-only-testing:` for the hosted and UI classes) - must pass
      before task 4

### Task 4: CLI

**Files:**
- Create: `agtermCore/Sources/agtermctlKit/MessageCommands.swift`
- Modify: `agtermCore/Sources/agtermctlKit/Commands.swift` (`subcommands:` registration)
- Create: `agtermCore/Tests/agtermctlKitTests/MessageCommandsTests.swift`
- Modify: `agtermUITests/ControlMessageUITests.swift`

- [x] tests first: identity from env pair, `--as` overrides the pair, incomplete pair errors, no pair and
      no `--as` sends anonymously but fails `read`/`ack`, `--ack` fails on missing or mismatched `acked`,
      `--wait` returns on pending and exits 124 on timeout, human and JSON output
- [x] `msg send|read|ack` subcommands with the options in Technical Details
- [x] `--wait` as a client-side poll with a watchdog timeout
- [x] e2e: the bundled `agtermctl msg send` / `msg read` against the running app, with `--as` built from
      the tree's `paneID`, following the `openAskCLI` pattern in `ControlAPITestCase.swift`
- [x] run the CLI test target and the e2e class - must pass before task 5

### Task 5: Documentation and skill
- [ ] `site/commands.html`: the three commands, arguments, read-back fields and the `message` event
- [ ] `site/docs.html`: a short section on the bus, its lifetime and delivery guarantee
- [ ] `plugins/agterm/skills/agterm/SKILL.md` trigger and pointer, `reference.md` entries
- [ ] `.claude/rules/control-api.md`: catalog entry and the bus's implementation constraints (disposal
      sites, identity agreement, no role fallback)

### Task 6: Verify acceptance criteria
- [ ] every Overview requirement implemented; edge cases from Technical Details covered by tests
- [ ] `make build`
- [ ] `cd agtermCore && swift test`
- [ ] `make test-app`
- [ ] `make lint`

### Task 7: [Final] Update documentation
- [ ] update README.md only if the control-API demo should mention the bus
- [ ] update CLAUDE.md if new patterns were discovered
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion
*Manual checks in an isolated Debug instance (`AGTERM_STATE_DIR` under `/tmp`)*
- two agents in a split exchange messages with `msg send` / `msg read --wait` / `msg ack`
- a companion created with leader-h reads its own mailbox, not its parent's

Smells pre-check: skipped — non-Go project
