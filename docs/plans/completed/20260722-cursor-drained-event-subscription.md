# Cursor-Drained Event Subscription

## Overview

Implement the full v1 event surface accepted in [GitHub Discussion #211](https://github.com/umputun/agterm/discussions/211), using the maintainer-selected design: a bounded in-memory event ring drained by ordinary one-request/one-response control calls. `agtermctl events` presents a continuous human or NDJSON stream by short-polling `events.read`; the app never hands off a file descriptor, keeps no subscriber registry, and preserves the control server's serial read/dispatch/write/close lifecycle and existing deadlines.

The v1 kinds are:

- `status`
- `notify`
- `session.created`
- `session.closed`
- `tree.changed` (per-window structural invalidation, coalesced over 100 ms)

This closes gaps that `tree --json` sampling cannot: short-lived status transitions, auto-reset clears, notification title/body, and balanced session lifetime edges. It also gives clients an explicit cursor and app-run identity so they detect retention loss or an app restart instead of silently skipping events.

Explicitly out of scope:

- persistent streaming connections, an event socket, a subscriber broker, or file-descriptor handoff
- disk persistence or replay across app runs
- long-polling, server-side waits, acknowledgements, delivery guarantees, or backpressure queues per client
- terminal output/scrollback streaming
- outbound user-script hooks; a later hook can consume this ring without changing the event contract
- `--since` by timestamp or unbounded history

## Context (from discovery)

Files/components involved:

- `agtermCore/Sources/agtermCore/ControlProtocol.swift` and `ControlDispatcher.swift` define the shared wire catalog, request arguments, responses, and host action seam.
- `agterm/Control/ControlServer.swift` is deliberately serial and one-shot, with per-read/write and overall deadlines; `events.read` must use this path unchanged.
- `agtermCore/Sources/agtermCore/AppStore*.swift` owns status normalization and every workspace/session entry and exit path, including grace closes, undo, and Open Recent.
- `agtermCore/Sources/agtermCore/WindowLibrary.swift` owns app-run window/store lifecycle and is the natural owner of the app-wide ring.
- `agterm/Notifications/NotificationManager.swift` is the shared delivery chokepoint for OSC and control notifications and retains the title/body long enough to emit them.
- `agtermCore/Sources/agtermctlKit` owns the one-shot socket client and CLI; the existing overlay `--block` loop is the nearest polling precedent.
- README scripting docs and the bundled agent skill currently promise “no event subscription” and must be updated together.

Relevant invariants:

- Status emission belongs after `setAgentIndicator` normalization. Equality compares the normalized `AgentIndicator`, not `statusChangedAt`, so a same-value non-idle reassertion may restamp attention ordering without emitting another event.
- `clearAutoResetIndicator` currently assigns `AgentIndicator()` directly. It must route through the same status mutation/emission helper so a visit-clear produces the closing `idle` edge.
- Soft close emits `session.closed` when the row leaves the visible tree, not when its grace timer later tears down the surface. Undo emits `session.created` when the same object re-enters.
- Initial app restoration establishes state without replaying every restored session as newly created. Closing and reopening a window during the same app run does emit balanced close/create edges.
- The main checkout is clean on `master`; implementation is non-trivial and must happen in an isolated worktree after refreshing `origin/master`.

## Development Approach

- **Testing approach: TDD.** Write the failing tests for each task before production code, then make only that task green.
- Complete each task fully before starting the next; every code task includes success, error, and edge-path tests.
- After each task, run `cd agtermCore && swift test`; app-target tasks also require `make build`; run `make lint` before moving on.
- Keep `agtermCore` host-free and Swift 6 strict-concurrency clean. Event storage and model emission are main-actor isolated; the socket accept loop continues to cross to the main actor exactly once per request.
- Keep source files under 1,000 lines and test files under 2,000. Add focused event files/tests instead of growing `AppStore.swift`, `ControlProtocolTests.swift`, or `ControlDispatcherTests.swift` past their limits.
- Preserve backward compatibility: all new request/result fields are optional, existing command wire forms and response rendering remain unchanged, and unknown event kinds receive a normal control error rather than failing JSON decoding.
- Update this plan when implementation discovers a scope or contract change; mark task checkboxes immediately.

Worktree preparation before Task 1:

1. Fetch `origin master` from the main checkout.
2. Create an isolated worktree from the refreshed remote tip using the project's supported worktree workflow.
3. Symlink `GhosttyKit.xcframework` and the `ghostty`/`terminfo` resources from the main checkout before building; never rebuild or mutate the main checkout's artifacts.

## Testing Strategy

- **Host-free unit tests:** ring ordering/retention, cursor semantics, Codable wire shape, dispatcher validation/routing, AppStore status and lifecycle emission, WindowLibrary open/close balance, CLI parsing/state advancement, NDJSON and human formatting.
- **Socket tests:** prove every poll is a fresh connection and a single response, verify consecutive cursored reads, and verify transport/server errors terminate the CLI rather than spin.
- **XCUITest:** use an isolated app/socket to exercise real control commands and GUI-native edges: status set/clear, auto-reset visit-clear, notify payload, session create/soft-close/undo, and debounced structural changes. Do not touch the deployed daily-driver app.
- **Final gates:** `cd agtermCore && swift test`, `make build`, and `make lint`. Run the focused event XCUITest target in an isolated state directory; do not run unrelated UI suites that synthesize input across the live screen.

Do not weaken or delete a failing test to make a task green.

## Solution Overview

### Ring and cursor semantics

Add a host-free, `@MainActor` `ControlEventRing` owned by `WindowLibrary` for the lifetime of one app process:

- `run` is a UUID generated once when the ring is initialized.
- `seq` is a monotonically increasing `UInt64`, beginning at 1; it is never reused during that run.
- capacity defaults to 4,096 events and is injectable for tests. Appending beyond capacity drops the oldest entries only.
- timestamps are Unix seconds as `Double`, with an injectable clock for deterministic tests.
- reads are non-destructive; independent consumers use their own `(run, after)` cursor.

`events.read` accepts these command-specific fields in `ControlArgs`:

- existing `after: String?`, interpreted here as an unsigned decimal sequence (it remains a session-id anchor for `session.new`/`session.move`)
- new `run: String?`
- new `kinds: [String]?`
- new `limit: Int?` (default 100, valid range 1...1,000)

`run` and `after` are either both omitted or both supplied:

- both omitted: bootstrap/subscription read; return no historical events and anchor at the current tail
- both supplied: return matching retained events strictly after `after`
- run mismatch, cursor older than retained history, or cursor ahead of the current tail: `ok:false` with a stable error string and the current anchor in `result.events`, so a caller can deliberately rebaseline

Filtering never creates a hidden gap. The returned `next` cursor advances across every scanned global event, including non-matching kinds. When `limit` matching events are reached, scanning stops at that event; otherwise `next` advances to the current tail. An empty filtered batch can therefore advance safely without rescanning irrelevant entries.

### Public wire contract

Add `Command.eventsRead = "events.read"`, `ControlEventKind`, `ControlEvent`, `ControlEventPayload`, and `ControlEventBatch`; add `events: ControlEventBatch?` to `ControlResult`.

Successful response:

```json
{
  "ok": true,
  "result": {
    "events": {
      "run": "CBB5E3D0-7A9B-4C96-9EA2-18B14380DDB1",
      "next": 42,
      "items": [
        {
          "seq": 42,
          "ts": 1783969641.38,
          "kind": "status",
          "window": "0F96…",
          "workspace": "D545…",
          "session": "9E55…",
          "payload": {"name": "api-fix", "status": "blocked", "blink": true}
        }
      ]
    }
  }
}
```

Event fields:

- common: `seq`, `ts`, `kind`, and optional `window`, `workspace`, `session`
- `status`: `name`, `status` (`idle|active|completed|blocked`), optional `pane`, `blink`, `color`; the idle closing edge is explicit
- `notify`: `name`, effective `title` (session name fallback already applied), and `body`
- `session.created` / `session.closed`: `name`, with window/workspace/session identity in common fields
- `tree.changed`: empty payload and the affected window id; consumers re-read `tree --window <id>` for detail

Error strings are constants shared by server and CLI tests:

- `events.read requires --run and --after together`
- `invalid event cursor`
- `invalid event run id`
- `invalid event kind: <kind>`
- `event limit must be between 1 and 1000`
- `event run changed`
- `event cursor expired`
- `event cursor is ahead of the current sequence`

### Emission semantics

`WindowLibrary` owns the ring and passes a window-scoped event sink into each `AppStore`. Event helper methods live in a focused `AppStore+Events.swift` extension rather than expanding the near-limit main file.

- **Status:** capture the previous normalized indicator, perform current normalization/mutation, and append only when normalized value changed. Route auto-reset, pane teardown/promotion clears, GUI Clear Status, hooks, and `session.status` through this one helper.
- **Notify:** append only after the notification resolves to an open session/window and passes OSC focus suppression. Emit whether or not banners are enabled, because the unseen badge/event still exists. A failed target/window resolution emits nothing.
- **Session lifecycle:** append at visible-tree membership changes. Ordinary add/duplicate, Open Recent, undo, and runtime window reopen emit `created`; hard/soft session close, workspace removal, open-window deletion, and runtime window close emit `closed`. Grace finalization emits nothing. Batch/workspace paths emit one event per session in stable tree order.
- **Tree invalidation:** schedule one `tree.changed` per affected window after 100 ms for membership, name, and order mutations (window/workspace/session create, close/delete, reopen/undo, rename, move, and reorder). Status, notification, selection, pane visibility, cwd/title, and other non-structural projection changes do not schedule it; their dedicated event or existing polling/read command remains authoritative.

### CLI behavior

Add top-level `agtermctl events` with `--json`, repeatable or comma-separated `--kind`, optional paired `--run`/`--after`, and `--limit`:

- no cursor: make one bootstrap read, then poll from its returned anchor; pre-subscription history is not printed
- cursor supplied: drain retained catch-up first, then continue from returned `next`
- poll every 250 ms only after an empty batch; immediately request the next batch after a non-empty or limit-filled batch
- each poll uses the existing `SocketClient.send`, hence a new connection and one response
- `--json` writes one bare `ControlEvent` JSON object per line and flushes promptly for pipes; human mode prints `HH:mm:ss kind name detail`
- terminate non-zero on transport errors, server errors, run changes, or cursor expiry; never silently rebaseline and never retry forever while the app is absent
- normal SIGINT/SIGTERM process behavior stops the loop; no custom signal subsystem is added

## Progress Tracking

- Mark completed items with `[x]` immediately.
- Add newly discovered tasks with a `+` prefix.
- Mark blockers with `WARNING:` and record the evidence.
- Keep this plan synchronized with any accepted wire-contract change.

## Implementation Steps

### Task 1: Add the bounded event ring and cursor rules with tests first

**Files:**

- Create: `agtermCore/Sources/agtermCore/ControlEvents.swift`
- Create: `agtermCore/Tests/agtermCoreTests/ControlEventRingTests.swift`

- [x] Write failing tests for sequence/timestamp assignment, 4,096-default and injected small-capacity eviction, independent non-destructive reads, and deterministic injected run/clock values.
- [x] Write failing tests for bootstrap-from-tail, exclusive cursors, filtered cursor advancement, limit pagination without loss, empty filtered batches, and stable global ordering.
- [x] Write failing tests for run mismatch, expired/ahead cursors, and exact-boundary retention (`after == oldest - 1` remains valid).
- [x] Implement the typed event model, ring append/read result, capacity enforcement, and stable error constants on the main actor.
- [x] Run `cd agtermCore && swift test`; all tests must pass before Task 2.

### Task 2: Add `events.read` to the one-shot control protocol and dispatcher

**Files:**

- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlModes.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/MockControlActions.swift`
- Create: `agtermCore/Tests/agtermCoreTests/ControlEventProtocolTests.swift`
- Create: `agtermCore/Tests/agtermCoreTests/ControlEventDispatcherTests.swift`

- [x] Write failing Codable tests for every event kind/payload, omitted optional fields, bootstrap batch, populated batch, and error response carrying the current anchor.
- [x] Write failing dispatcher tests for paired cursor validation, decimal/UUID parsing, comma/repeat-normalized kind lists, default/max limit, every invalid-input error, and action routing.
- [x] Add the exhaustive `Command` cases, optional request/result fields, typed read options, `ControlActions` requirement, mock call, and dispatcher arm as one compile-safe change.
- [x] Keep raw unknown kinds decodable as strings until dispatcher validation, producing the pinned control error rather than `invalid request`.
- [x] Run `cd agtermCore && swift test`; all tests must pass before Task 3.

### Task 3: Wire the app-run ring into `WindowLibrary` and the control server

**Files:**

- Modify: `agtermCore/Sources/agtermCore/WindowLibrary.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift`
- Create: `agtermCore/Sources/agtermCore/AppStore+Events.swift`
- Create: `agtermCore/Sources/agtermCore/AppStore+Naming.swift`
- Modify: `agterm/Control/ControlServer.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/WindowLibraryTests.swift`
- Create: `agtermCore/Tests/agtermCoreTests/AppStoreEventTests.swift`

- [x] Write failing tests proving one ring/run is shared by every open window, each store sink stamps the correct window/workspace/session ids, and runtime close/reopen can retain cursor continuity.
- [x] Make `WindowLibrary` own the ring, inject a window-scoped sink into every store creation/load path, and expose only the read/append operations needed by app seams.
- [x] Route `.eventsRead` through `ControlDispatcher` into the same main-actor ring while leaving `handleConnection`, socket deadlines, and fast-path cache behavior unchanged.
- [x] Verify an `events.read` call still performs exactly one request, one response, and close; add no listener queue, subscriber state, or wait in the server.
- [x] Run `cd agtermCore && swift test`, `make build`, and `make lint`; all must pass before Task 4.

### Task 4: Emit normalized status and notification edges

**Files:**

- Modify: `agtermCore/Sources/agtermCore/AppStore+Status.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+Panes.swift`
- Modify: `agterm/Notifications/NotificationManager.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreEventTests.swift`

- [x] Write failing tests for active/blocked/completed/idle payloads, pane normalization, blink/color fields, same-value reassertion suppression despite timestamp restamping, unknown sessions, and auto-reset visit/leave clears.
- [x] Refactor all status clear paths, especially `clearAutoResetIndicator`, through the normalized `setAgentIndicator` emission point without changing current attention/auto-follow behavior.
- [x] Emit notification events from both OSC and `notify` paths after successful target/focus gating, using the effective title and emitting even when banners are disabled.
- [x] Add tests or a pure notification-recording seam for accepted/suppressed/invalid notification paths; ensure no event appears when delivery is rejected before the unseen badge increments.
- [x] Run `cd agtermCore && swift test`, `make build`, and `make lint`; all must pass before Task 5.

### Task 5: Emit balanced session lifecycle and debounced structural invalidations

**Files:**

- Modify: `agtermCore/Sources/agtermCore/AppStore.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+PendingClose.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+RecentClosed.swift`
- Modify: `agtermCore/Sources/agtermCore/WindowLibrary.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+Events.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreEventTests.swift`
- Create: `agtermCore/Tests/agtermCoreTests/WindowEventLifecycleTests.swift`

- [x] Write failing tests for add/duplicate, hard close, soft close at removal time, no duplicate on grace finalization, grouped/workspace close ordering, undo, Open Recent, runtime window close/reopen, and open/closed window deletion.
- [x] Implement exactly one `session.created`/`session.closed` per visible-tree membership edge, preserving session identity on undo and suppressing launch-bootstrap creation noise.
- [x] Write failing debounce tests for create/close, rename, move/reorder, cross-workspace batches, and two independent windows; use an injectable/flushable debounce seam rather than wall-clock sleeps.
- [x] Schedule one `tree.changed` per affected window per 100 ms burst, with no structural event for status-only, notification-only, selection-only, or same-value/no-op mutations.
- [x] Run `cd agtermCore && swift test`, `make build`, and `make lint`; all must pass before Task 6.

### Task 6: Add the continuous `agtermctl events` consumer

**Files:**

- Create: `agtermCore/Sources/agtermctlKit/EventCommands.swift`
- Modify: `agtermCore/Sources/agtermctlKit/Commands.swift`
- Modify: `agtermCore/Sources/agtermctlKit/SocketClient.swift`
- Create: `agtermCore/Tests/agtermctlKitTests/EventCommandsTests.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/SocketClientTests.swift`

- [x] Write failing parser tests for default invocation, JSON mode, repeated/comma-separated kinds, paired run/after, limit bounds, and invalid combinations.
- [x] Extract a testable stream state machine that builds each `events.read` request, consumes batches, advances cursors, and decides whether to poll immediately or sleep; test empty, filtered, paginated, and error transitions.
- [x] Implement the 250 ms loop using a fresh `SocketClient.send` per poll, with immediate follow-up after non-empty batches and non-zero termination on any transport/server/cursor error.
- [x] Write failing then passing formatter tests for every human event kind and stable one-object-per-line NDJSON output; flush each event promptly for `jq --unbuffered`/shell pipelines.
- [x] Run `cd agtermCore && swift test` and `make lint`; all must pass before Task 7.

### Task 7: Verify the real app and GUI-native closing edges

**Files:**

- Create: `agtermUITests/EventSubscriptionUITests.swift`
- Modify only if reusable harness extraction is necessary: `agtermUITests/ControlAPITestCase.swift`

- [x] Write an isolated-socket XCUITest that anchors a cursor, sets and clears status through the control API, and verifies ordered blocked/idle events with no duplicate for a same-value reassertion.
- [x] Verify `completed --auto-reset` followed by a real session visit emits the idle closing edge.
- [x] Verify `notify` preserves effective title/body, plus create → soft-close → undo produces created/closed/created and one coalesced structural invalidation per burst.
- [x] Verify filtered reads advance past nonmatching events and a later unfiltered consumer with its own cursor remains independent.
- [x] Run the focused XCUITest against a separate Debug app with isolated state/socket, then run `make build` and `make lint`; do not touch the deployed app.

### Task 8: Document the event API and remove the old non-goal

**Files:**

- Modify: `README.md`
- Modify: `agterm/Resources/agent-skill/SKILL.md`
- Modify: `agterm/Resources/agent-skill/reference.md`
- Modify: `agterm/Resources/agent-skill/examples.md`
- Modify: `agtermCore/Tests/agtermCoreTests/SkillInstallTests.swift`

- [x] Replace “no event subscription” with the bounded cursor-ring contract while retaining the explicit “no terminal-output streaming” boundary.
- [x] Document event kinds/payloads, subscribe-from-now behavior, resumable run/after cursors, retention/run errors, filtering, limits, 250 ms latency, and process exit behavior.
- [x] Add status-wait, notification relay, and session cleanup examples using `agtermctl events --json`; warn that missed/changed cursors fail loudly and require deliberate rebootstrap.
- [x] Update bundled-skill catalog/reference expectations and command lists so installed docs match the CLI exactly.
- [x] Run `cd agtermCore && swift test`, `make build`, and `make lint`; all must pass before Task 9.

### Task 9: Final acceptance and plan completion

- [x] Confirm all five kinds and every documented payload field match the encoded NDJSON observed in the focused e2e test.
- [x] Confirm the control accept loop and four existing timeout/deadline protections are unchanged and no persistent client state exists server-side.
- [x] Run the full host-free suite: `cd agtermCore && swift test`.
- [x] Run the app build: `make build`.
- [x] Run strict lint: `make lint`.
- [x] Confirm source/test file-size limits and a clean implementation worktree except for intended changes.
- [x] Move this plan to `docs/plans/completed/` only after every acceptance item is green.

## Post-Completion

- Manually run `agtermctl events --json | jq --unbuffered .` against an isolated Debug instance and confirm Ctrl-C exits cleanly and events arrive within the expected 250–350 ms polling/debounce envelope.
- Ask the Stream Deck consumer from Discussion #211/#267 to test cursor resumption, status flashes, notification payloads, and session add/remove with the documented v1 wire shape.
- Treat outbound exec hooks, disk journaling, longer replay, and additional event kinds as separate follow-up proposals backed by concrete consumers.

## Assumptions and Defaults

- Full v1 means exactly the five accepted kinds above; no wildcard/custom kinds.
- Ring capacity is 4,096, batch default is 100, batch maximum is 1,000, CLI poll interval is 250 ms, and `tree.changed` debounce is 100 ms per window.
- `agtermctl events` starts at the current tail unless both `--run` and `--after` are supplied; it never dumps arbitrary pre-start history.
- Cursor/run discontinuity is a hard, visible failure. Automatic rebasing would hide lost transitions and is intentionally forbidden.
- Structural `tree.changed` covers membership/name/order only. Status and notifications have dedicated kinds; other live tree projections remain query-on-demand in v1.
- No GUI control or Settings toggle is added; this is a control-native capability.
