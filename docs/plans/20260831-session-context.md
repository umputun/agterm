# Session context in the title bar

## Overview

A per-session free-text string set only from outside, over the control API/CLI, and shown in the title
bar. It answers "what is this session about" — a PR number, an issue, a task — where the sidebar row has
no room for it and the OSC title cannot serve: the OSC title is owned by whatever runs in the pane, a TUI
overwrites it, an outside process cannot inject it into a pane already running one, and it feeds
`Session.displayName` so setting it would rewrite the sidebar identity too.

The contract is durable session purpose, held until an explicit clear. Not a claim about current activity:
no TTL, no timestamps, no auto-clear on command exit.

## Context (from discovery)

- Title bar line 1 is `titleText` (session name, plus `— window` for a custom window name), line 2 is
  `windowSubtitle` = `Session.subtitleDetail`, rendered only in `.normal` toolbar mode —
  `agterm/Views/WindowContentView+Titlebar.swift`.
- `ControlSessionNode` lives in `agtermCore/Sources/agtermCore/ControlProjection.swift:80` (it moved out of
  `ControlProtocol.swift` in #521).
- `session.flag` is the shape to mirror: enum case in `ControlProtocol.swift:26`, validation in
  `ControlDispatcher.swift:331`, effect through a `ControlActions` method, app side in
  `agterm/Control/ControlServer+SessionActions.swift`, CLI in `agtermctlKit/SessionCommands.swift:490`.
- `SessionSnapshot` is `agtermCore/Sources/agtermCore/Snapshot.swift:138`, written in
  `AppStore+Snapshot.swift:30` and read back at `:77`.
- `AppStore+Duplicate.swift:8` documents that a duplicated session carries only the directory, so it does
  not inherit context for free — no work needed.

## Development Approach

- Regular: code first, then tests, in the same task.
- Every task ends with tests written and passing before the next starts.
- Gates run ONCE at the end (`swift test`, `make test-app`, `make lint`); per-task runs are scoped with
  `-only-testing:` to what changed.

## Solution Overview

`Session.context: String?`, persisted, mutated only over the control channel, projected on
`ControlSessionNode`, rendered by the title bar under a new Interface toggle.

Validation lives in `agtermCore` so the app target stays an adapter. A set trims outer whitespace and is
rejected when the result is empty, over 256 UTF-8 bytes, or contains a newline or control character. A
rejected set leaves the previous value untouched. `--clear` is the ONLY clearing form — a blank set must
not become a second, undocumented clear path.

## Technical Details

Validator, static on `Session` (called from the dispatcher, not from a `Session` method, so static is
right — mirrors `WatermarkConfig.isValidColorHex`):

```swift
public enum SessionContextValidation: Sendable, Equatable {
    case valid(String)
    case invalid(String)  // message for the ControlResponse error
}

public static func validateContext(_ raw: String) -> SessionContextValidation
```

Composition matrix, pinned as test cases:

| toolbar mode | context | toggle | line 1 | line 2 |
|---|---|---|---|---|
| normal | none | — | identity | cwd/OSC subtitle (unchanged) |
| normal | set | on | identity | context (replaces the subtitle) |
| normal | set | off | identity | cwd/OSC subtitle (unchanged) |
| compact | set | on | `identity · context` | — |
| compact | set, identity hidden | on | context alone | — |
| hidden | set | on | no row | no row |

`windowTitle` (the OS window title, Mission Control and the Window menu) never changes in any row.
`Session.subtitleDetail` itself is never touched, so the cwd still shows in Recent Sessions, Ctrl-Tab and
the palette.

Compact puts the context AFTER the identity so `lineLimit(1)` tail truncation eats the context, not the
session name — `ToolbarMode` is independent of `sidebarVisible`, so compact with the sidebar hidden leaves
the title bar as the only place the session name appears.

## Out of scope

No hover/tooltip reveal of a truncated context. The sidebar got one in #520, but `titleLabel` sets
`.allowsHitTesting(false)` so drag and double-click-zoom pass through to `WindowControlArea`; a tooltip
needs hit testing and would cost those gestures.

## Implementation Steps

### Task 1: Session.context and its validator

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Session.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/SessionTests.swift`

- [ ] add `public var context: String?` to `Session` with a short godoc naming the durable-purpose contract
- [ ] add `SessionContextValidation` and `Session.validateContext(_:)` per Technical Details
- [ ] write tests: trims outer whitespace; rejects empty-after-trim, >256 UTF-8 bytes, newline, control chars
- [ ] write tests: rejects U+2028 LINE SEPARATOR and U+2029 PARAGRAPH SEPARATOR (a `\n`-only check misses both)
- [ ] write tests: a multi-byte value near the boundary is measured in BYTES, not characters
- [ ] run `swift test --filter SessionTests` — must pass before task 2

### Task 2: Persist context across restart and restore

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Snapshot.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+Snapshot.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/SnapshotRoundTripTests.swift`

- [ ] add optional `context` to `SessionSnapshot`, written in `sessionSnapshot` and read back alongside `flagged`
- [ ] drop an invalid context on decode (run it through `validateContext`) rather than failing the restore,
      matching the existing optional-field policy for a hand-edited snapshot
- [ ] write tests: round-trip; a snapshot with no `context` key decodes to nil; an invalid stored value drops
- [ ] write test: a duplicated session has no context (pins `AppStore+Duplicate` behavior)
- [ ] run `swift test --filter SnapshotRoundTripTests` — must pass before task 3

### Task 3: session.context protocol, dispatcher and read-back

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlActionsDefaults.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlProjection.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlProtocolCompatibility.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreTests.swift`

- [ ] add `case sessionContext = "session.context"` and its `text`/`clear` args
- [ ] dispatch it: `--clear` sets nil; otherwise run `validateContext` and return `ok: false` with the
      message on failure, leaving the previous value untouched
- [ ] reject BOTH `text` and `clear` together, and NEITHER, in the dispatcher — a raw socket client never
      goes through the CLI, so parse-time exclusivity in task 7 is not enough on its own
- [ ] add `setSessionContext` to `ControlActions` with the default returning the unimplemented response
- [ ] add optional `context` to `ControlSessionNode`, a default in the compatibility initializer
      (agtermCore is a `.library` consumed by the agterm-linux fork), and populate it at `AppStore.swift:283`
      — `ControlProjection` owns only the DTO
- [ ] write dispatcher tests in `ControlDispatcherTests` against `MockControlActions`: set, clear, and every
      rejection path calling NO action at all
- [ ] write tests: the encoded protocol shape, and the node projection through `AppStoreTests`
- [ ] run `swift test --filter "ControlProtocolTests|ControlDispatcherTests|AppStoreTests"` — must pass
      before task 4

### Task 4: App-side effect, event and save

**Files:**
- Modify: `agterm/Control/ControlServer+SessionActions.swift`
- Modify: `agterm/Control/ControlServer.swift`
- Modify: `agtermTests/ControlServerSessionActionsTests.swift`

- [ ] implement `setSessionContext` against the resolved target session
- [ ] emit `tree.changed` and save immediately on a successful mutation
- [ ] skip both when the value is unchanged, matching `setFlag`'s `session.flagged != on` guard
- [ ] register the command in the `ControlServer` command list alongside `.sessionFlag`
- [ ] write tests: mutation reaches the store, event fires, setting the SAME value again fires no event
- [ ] write test: the saved snapshot on disk holds the new context after a mutation
- [ ] rejection is asserted in task 3, not here — an invalid value never reaches this layer
- [ ] run the scoped hosted test — must pass before task 5

### Task 5: Host-free title composition

`titleText` and `windowSubtitle` are private computed properties on a SwiftUI view extension with NO test
coverage today, so the matrix cannot be pinned where they sit. Hoist the composition into `agtermCore`
first, following `InterfaceElement.titlebarGroupDividers` ("Host-free so it is unit-testable").

**Files:**
- Create: `agtermCore/Sources/agtermCore/TitlebarComposition.swift`
- Create: `agtermCore/Tests/agtermCoreTests/TitlebarCompositionTests.swift`

**Design Contract:**

Type:
- `TitlebarComposition` (public — the app target calls it across the module boundary)

Shape (one pure function, an option struct because the input exceeds three values):

```swift
public struct TitlebarComposition: Sendable, Equatable {
    public let title: String     // line 1, "" when everything is hidden
    public let subtitle: String  // line 2, "" in compact/hidden mode

    public struct Parts: Sendable, Equatable {
        public var sessionName: String?   // nil when hidden by InterfaceElement
        public var windowName: String?    // nil when auto-named or hidden
        public var context: String?       // nil when unset or hidden
        public var detail: String         // subtitleDetail (cwd/OSC title)
    }

    public static func compose(_ parts: Parts, mode: ToolbarMode) -> TitlebarComposition
}
```

- [ ] add `TitlebarComposition` per the contract, reproducing today's behavior exactly when `context` is nil
- [ ] write tests for every row of the composition matrix
- [ ] run `swift test --filter TitlebarCompositionTests` — must pass before task 6

### Task 6: Title bar rendering and the Interface toggle

**Files:**
- Modify: `agterm/Views/WindowContentView+Titlebar.swift`
- Modify: `agtermCore/Sources/agtermCore/AppSettings.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppSettingsTests.swift`

No Settings UI change: `SettingsView.swift:458` builds the Title Bar section from
`InterfaceElement.allCases.filter { $0.section == .titleBar }`, so the new toggle appears on its own.

- [ ] add `case sessionContext` to `InterfaceElement` (title-bar section) with its display name; it gates
      only itself — `sessionName`/`windowName` keep gating identity alone
- [ ] rewrite `titleText` and `windowSubtitle` to build `Parts` and read `TitlebarComposition.compose`
- [ ] apply `lineLimit(1)` and tail truncation to the title label
- [ ] confirm `windowTitle` (the OS window title) still bypasses the Interface toggles entirely
- [ ] write tests for the new `InterfaceElement` case (section, display name, hidden-set round trip)
- [ ] run `swift test --filter AppSettingsTests` AND a scoped `make test-app` run — the agtermCore filter
      never compiles `WindowContentView`, so it cannot catch a break in the rewiring
- [ ] both must pass before task 7

### Task 7: agtermctl session context

**Files:**
- Modify: `agtermCore/Sources/agtermctlKit/SessionCommands.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/CommandsTests.swift`

- [ ] add `session context [TEXT] [--clear]` mirroring `session flag`, with target/window options
- [ ] reject `TEXT` and `--clear` together, and neither, at parse time with a clean usage error
- [ ] write tests: argument parsing, both rejection cases, request shape sent to the socket
- [ ] ⚠️ `CommandsTests.swift` is at ~1940 lines against the 2000-line test cap. If the new cases cross it,
      STOP and ask the maintainer before splitting the file — do not raise the limit
- [ ] run `swift test --filter CommandsTests` — must pass before task 8

### Task 8: Cross-surface documentation

**Files:**
- Modify: `.claude/rules/control-api.md`
- Modify: `plugins/agterm/skills/agterm/SKILL.md`
- Modify: `plugins/agterm/skills/agterm/reference.md`
- Modify: `site/commands.html`
- Modify: `site/docs.html`

- [ ] document the command, its arguments and the `context` read-back field in `control-api.md`
- [ ] add it to the bundled skill's `SKILL.md` trigger list AND to `reference.md`, which owns the full
      command and JSON contract (the sole source for the installed Claude/Codex copies)
- [ ] mirror the command, arguments and read-back field in `site/commands.html`
- [ ] describe the feature and the Interface toggle in `site/docs.html`
- [ ] state no command total anywhere (per the `control-api.md` rule)

### Task 9: Verify acceptance criteria

- [ ] every row of the composition matrix behaves as pinned
- [ ] a rejected set leaves the previous context untouched, and `--clear` is the only clearing form
- [ ] context survives quit and relaunch, and a restored session shows it
- [ ] `agtermctl tree` reports the context; a node without one omits the field
- [ ] run `cd agtermCore && swift test`, `make test-app`, `make lint` — all clean

### Task 10: [Final] Wrap up

- [ ] update `ARCHITECTURE.md` if the surface split changed
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification:**
- Launch an isolated Debug instance, set a context from `agtermctl --socket`, and check all three toolbar
  modes plus the Interface toggle by eye.
- Confirm a long context truncates by tail without pushing the trailing button cluster.

Smells pre-check: skipped — non-Go project.
