# Control-API native picker (`pick`)

## Overview

A native fuzzy picker driven entirely over the control socket. A caller — a keymap custom command, a
shell script, or a coding agent — hands agterm a finished list of items, agterm shows its own fuzzy
palette, and the caller gets the chosen item back.

This answers [discussion #270](https://github.com/umputun/agterm/discussions/270) in a form that clears
the objections raised against the keymap-level `--submenu` shape it originally asked for. Those three
costs — a flag in a keymap format that has none, the palette blocking on a user shell command with no
answer when the host hangs, and remote text spliced into a raw-substituted shell line — are all
properties of *agterm producing the list*. Here the caller produces the finished list before it calls,
so agterm never runs a shell command and never waits on one.

The capability this adds that nothing else covers: `notify` has no return leg. agterm can interrupt a
human one-way (notify, status, badge, blink) and cannot ask him anything. `pick` is the ask.

**Not in scope:** any keymap format change, any GUI opener, badges or status glyphs on items, multi-select,
server-side timeouts.

## Context (from discovery)

- **Serial accept loop.** `agterm/Control/ControlServer.swift:237-250` handles one connection inline on a
  background queue, with deliberate deadlines (`readTimeoutSeconds = 5`, `readDeadlineSeconds = 10`)
  whose comments name the failure being prevented: "a stalled client can't park the serial accept loop
  forever". A request held open while a human reads a list would park the whole control channel,
  including the agent-status hooks that fire on every tool call. **The pick must not hold the connection.**
- **The open→poll idiom already exists**, twice: `session.overlay.open` → `session.overlay.result` with
  `agtermctl … --block` wrapping them (`agtermctlKit/SessionCommands.swift:644-667`), and
  `session.search` polling for the async `SEARCH_TOTAL` callback. `pick` reuses it verbatim.
- **Per-window modal registries are the established pattern**: `TerminalZoomController`/`TerminalZoomRegistry`
  (`agtermCore/TerminalZoom.swift:109-193`), `DashboardControllerRegistry`, `QuickTerminalRegistry`.
  `PaletteController` is the odd one out at app-global; `pick` follows the registry majority.
- **`CommandPalette` is reusable as-is** except for one seam: `agterm/Views/Palette.swift:96-105` derives
  `allItems` by switching on `controller.mode` to call `actions.paletteX()`. It needs to also accept an
  explicit array. Fuzzy ranking (`fuzzyRank`), subtitle rendering, ↑/↓ nav, Esc, and the scrim are all
  reused untouched. `PaletteItem` already carries `id`/`title`/`subtitle`.
- **File-size pressure**: `ControlProtocol.swift` is 806 lines, `ControlDispatcher.swift` is 794, against
  the project's hard 1000-line limit. New pick types and dispatcher arms go into new files, following the
  existing `ControlServer+WorkspaceCommands.swift` split precedent.
- **⌘W cover chain**: `AppActions.closeActiveSession()` (`agterm/AppActions.swift:251-269`) checks in
  order zoom → dashboard → quick → overlay → scratch, returning `true` to signal it handled the keystroke.

## Development Approach

- **testing approach**: Regular (code first, then tests within the same task)
- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - tests are not optional — they are a required part of the checklist
  - write unit tests for new functions/methods
  - write unit tests for modified functions/methods
  - add new test cases for new code paths
  - update existing test cases if behavior changes
  - tests cover both success and error scenarios
- **CRITICAL: all tests must pass before starting next task** — no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- run tests after each change
- maintain backward compatibility

### Project-specific gates (HARD)

Every code-bearing task is gated on ALL of these before its final checkbox is marked. Each task's
checklist spells them out individually — this paragraph and the per-task gates must never disagree,
because an autonomous executor follows whichever it reads last.

1. `cd agtermCore && swift test` green
2. `make lint` clean (`swiftlint lint --strict`, zero findings — warnings are failures)
3. `make build` succeeds

Plus `make test-app` for any task touching the app target (`agterm/`).

**Every intermediate state must compile.** `Command` is switched over EXHAUSTIVELY with no `default:`
arm in two places — `ControlDispatcher.dispatch` (`ControlDispatcher.swift:150`) and the fallthrough
switch in `ControlServer.swift:374`. Adding a `Command` case without touching both breaks compilation
in `agtermCore` AND the app target, which makes that task's own `swift test` gate impossible to run.

**File-size checks.** Any task touching a file within ~200 lines of the hard 1000-line limit carries a
checkbox verifying it is still under. Current sizes for files this plan touches:
`AppStore.swift` **977**, `agterm/Views/WindowContentView.swift` **844**,
`ControlProtocol.swift` **806**, `ControlDispatcher.swift` **794**.

**Dispatcher-first rule** (`.claude/rules/control-api.md`): every host-free part — argument parsing,
validation, error strings, the success-response shape — lives in `ControlDispatcher` in `agtermCore`
with unit tests. Only target resolution and AppKit side effects go app-side behind `ControlActions`.
Do NOT add validation or response-shaping inline in the `ControlServer` switch.

**Module boundary**: `agtermCore` must not import GhosttyKit, AppKit, or Metal, and must stay
CoreGraphics-free (no `CGSize`/`CGPoint`/`CGRect`/`CGFloat` — they compile and pass tests but crash the
release whole-module optimizer).

## Testing Strategy

- **unit tests** (`swift test`, host-free): required for every task — protocol round-trips, the controller
  and registry, every dispatcher validation and rejection path, CLI argument mapping, the stdin sniff, the
  exit-code mapping, and the `controlTree` read-back closure.
- **hosted AppKit tests** (`make test-app`): only if a change needs a live `NSMenu`/AppKit surface.
- **e2e XCUITests** (`agtermUITests/`): a `ControlPickUITests` subclassing `ControlAPITestCase`, driving
  the real socket end to end. Same rigor as unit tests — must pass before the next task.
- **Round-trip discipline**: every new `Codable` field needs both a `…RoundTrips…` and a
  `…OmitsWhenNil` test, per the existing `ControlProtocolTests` convention.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope
- keep plan in sync with actual work done

## Solution Overview

Three new control commands, catalog **68 → 71**:

```
pick.open   → {"id": "<pick-id>"}                       returns immediately
pick.result → {"result": "pending"|"picked"|"custom"|"cancelled", …}
pick.cancel → dismisses a pending pick
```

`pick.open` / `pick.result` deliberately mirrors `session.overlay.open` / `.result` — the closest
existing analogue (ephemeral, produces a result, polled). `cancel` rather than `close` because it
produces an *outcome* the caller reads, not just a teardown.

A pending pick is per-window state in a `PickController`, reached through a `PickRegistry` keyed by
`WindowInfo.ID`, exactly as `TerminalZoomController`/`TerminalZoomRegistry` works. A window holds at most
one pending pick; a second `pick.open` for that window is rejected.

The modal is the existing `CommandPalette` view fed an explicit item array. Nothing new is drawn.

`agtermctl pick` blocks by default, wrapping open → poll → print. This is a deliberate flip from
`overlay open --block` (where blocking is opt-in), because blocking is the entire point of a pick.

### Key design decisions

| Decision | Rationale |
|---|---|
| Open→poll, never hold the connection | The accept loop is serial with 5s/10s deadlines; a held request parks every other `agtermctl` call |
| Per-window registry, not app-global | Matches zoom/dashboard/quick; makes `--window` meaningful; two scripts on two windows never collide |
| Second pick rejected, not queued | No queue state, no silent serialization; the caller sees a real error and decides |
| JSON items on the wire | Extends to more fields later without inventing delimiter rules; agents emit it natively |
| CLI sniffs stdin | Shell callers pipe bare lines directly; CLI-local, adds no second wire format |
| JSON response on stdout | A pick's output is a machine answer; there is no useful human rendering of it |
| Exit codes 0/1/2 | Shell callers guard without parsing; 1 already means failure (`ExitCode.failure`), 2 is unused |
| No timeout at all, anywhere | Not agterm's concern and not the CLI's; a caller wanting a deadline writes `timeout 60 agtermctl pick …` and clears the modal with `pick cancel` |
| Background by default, `--follow` to raise | Same opt-in-to-foreground default as `session.new --no-select` and `overlay open --follow` |

## Technical Details

### Wire types (new file `agtermCore/Sources/agtermCore/ControlPick.swift`)

```swift
public struct ControlPickItem: Codable, Sendable, Equatable {
    public let id: String
    public let label: String
    public let subtitle: String?
}

public enum ControlPickOutcome: String, Codable, Sendable, CaseIterable {
    case pending, picked, custom, cancelled
}

public struct ControlPickResult: Codable, Sendable, Equatable {
    public let result: ControlPickOutcome
    public let id: String?        // picked only
    public let label: String?     // picked only
    public let index: Int?        // picked only
    public let query: String?     // custom only
}
```

`index` is present so a caller that built the list positionally never needs ids at all.

### Protocol additions

- `Command`: `pickOpen = "pick.open"`, `pickResult = "pick.result"`, `pickCancel = "pick.cancel"`
- `ControlArgs`: `items: [ControlPickItem]?`, `prompt: String?`, `allowCustom: Bool?`
  (reuses the existing `window` and `follow` fields — no new fields for those)
- `ControlResult`: `pick: ControlPickResult?` — nested, like `tree` and `keymap`
- `ControlTree`: `pickPending: String?` — top-level, the pending pick's id, omitted when none

`pick.result` and `pick.cancel` address the pick by its id via the existing top-level `target` field.
Exact match only — no prefix sugar; the caller was handed the exact id by `pick.open`.

### Validation (all host-free, in the dispatcher)

| Condition | Error |
|---|---|
| `items` missing or empty on `pick.open` | `pick.open requires at least one item` |
| an item has an empty `label` | `pick item label must not be empty` |
| duplicate item `id`s | `pick item ids must be unique` |
| item count over `ControlPickItem.maxItems` (1000) | `too many items (max 1000)` |
| a label/subtitle containing control characters | `item text must not contain control characters` |
| `target` missing on `pick.result` / `pick.cancel` | `pick.result requires a pick id` |
| unknown pick id | `unknown pick: <id>` |

App-side (needs the registry): a window that already has a pending pick →
`pick already pending`.

The 1000-item cap and the control-character check mirror the existing
`ControlRestoreOverride.maxCommandBytes` and `command must not contain control characters` precedents —
the wire already caps a single request line at 1 MiB, but a bounded, named limit gives a better error
than a truncated read.

### Controller (new file `agtermCore/Sources/agtermCore/Pick.swift`)

Modeled directly on `TerminalZoom.swift`:

```swift
public struct ResolvedPick: Equatable, Sendable {
    public let id: String
    public let result: ControlPickResult
}

@Observable @MainActor
public final class PickController {
    public private(set) var pending: PendingPick?   // id, items, prompt, allowCustom
    public private(set) var lastResult: ResolvedPick?

    public func open(_ pick: PendingPick) -> Bool   // false when one is already pending
    public func resolve(_ outcome: ControlPickResult)
    public func cancel()
    public func result(for id: String) -> ControlPickResult?
}

@MainActor
public final class PickRegistry {
    public static let shared = PickRegistry()
    public func register(_ id: WindowInfo.ID, controller: PickController)
    public func unregister(_ id: WindowInfo.ID)
    public func controller(for id: WindowInfo.ID?) -> PickController?
}
```

`lastResult` retains exactly one resolved pick per window so `pick.result` can be read *after* the modal
closed — a poll that lands a tick late must still get its answer, not `unknown pick`. It is overwritten
by the next `open`, so nothing accumulates. It is a named `Equatable` struct rather than a labeled tuple
so the "replaced by the next open" test can compare it directly.

### Focus invariant (load-bearing)

`AppActions.focusActiveSession` (`agterm/AppActions+Focus.swift:118-135`) bails on five conditions —
`terminalZoomActive`, `dashboardActive`, `renamePending`, `palette?.mode != nil`, and a visible quick
terminal — and `focusSplitPane` (`:186`) repeats the palette term. `.claude/rules/theme-picker.md` calls
this guard load-bearing and names the failure: `WindowContentView`'s close-restore runs a ~12×0.03s
`makeFirstResponder(terminal)` retry loop that out-races a newly-mounted palette's field focus, so the
terminal behind it eats the keystrokes.

A pick-driven palette is mounted from a **separate `PickController`**, so `palette?.mode` stays nil and
**neither guard fires**. This is not theoretical: opening a pick *closes the built-in palette*, which is
exactly the event that starts that retry loop. Both guards must gain a pending-pick term.

### CLI

Three subcommands, one per control command, mirroring `session overlay`
(`SessionCommands.swift:606` — `subcommands: [Open.self, Close.self, Resize.self, Result.self]`, where
every one of the four overlay commands has its own CLI verb including `Result`):

```
agtermctl pick [open] [--prompt TEXT] [--allow-custom] [--follow] [--window W] [--no-block]
agtermctl pick result <pick-id>
agtermctl pick cancel <pick-id>
```

`open` is the default subcommand, so the common case stays `… | agtermctl pick`. The `result` and
`cancel` verbs are **not optional niceties** — point 3 of the four-point audit requires an `agtermctl`
subcommand per control command, and without them `--no-block` prints a pick id that no shell command
could then poll or cancel, making the flag dead on arrival.

`open` reads stdin and sniffs the first non-whitespace byte: `[` parses as a JSON array of items,
anything else is one label per line (`id == label`, blank lines dropped). Both normalize to the same
JSON request.

Blocks by default: open → poll `pick.result` → print the JSON result object on stdout → exit.
`--no-block` prints `{"id": "<pick-id>"}` and returns.

**There is deliberately no `--timeout`.** A caller wanting a deadline already has one — `timeout 60
agtermctl pick …`. The only thing a built-in flag would add is clearing the modal left on screen when
the caller dies, and that is exactly what `pick cancel` is for; the user can also just press Esc. Giving
agterm a timer it does not need would also make "the caller gave up" a fourth outcome the protocol has
to represent, for no gain.

**Poll cadence matters.** The overlay precedent (`SessionCommands.swift:665`) sleeps a flat 0.1s, tuned
for sub-second overlay programs. A pick polls for the entire human-read duration, unbounded, and at
10 req/s against a *serial* accept loop it competes with the agent-status hooks that fire on every agent
tool call — the exact contention the Context section names as the reason this design exists. So: 0.1s
for the first second, then back off to 0.5s.

Exit codes: **0** got an answer (`picked` or `custom`), **1** command failed, **2** human declined
(Esc, scrim, or `pick.cancel`).

### Behavior

- **Opening** closes the built-in palette on the pick's window, but only when that window is frontmost
  (`PaletteController` is app-global). Precedent: entering zoom already closes the palette and an active
  ⌘F search.
- **Focus**: the pick does not raise the app. `--follow` raises and selects the window.
- **Free text** (`--allow-custom`): when the query matches nothing, a synthetic row `Use "<query>"` is
  rendered and selected. Without it, Enter on an empty list is a silent no-op, which reads as a broken
  affordance — `runSelected` guards on `filtered.indices.contains`.
- **⌘W** dismisses a pending pick first, ahead of zoom, and yields `cancelled`. It goes first because a
  pick is an external caller blocked on an answer; ⌘W should answer it (with a decline) before touching
  anything behind it.
- **Lifetime**: window close, app quit, and `pick.cancel` all resolve a pending pick to `cancelled`.

## What Goes Where

- **Implementation Steps** (`[ ]` checkboxes): code, tests, and in-repo documentation
- **Post-Completion** (no checkboxes): manual verification against a live dev instance


## Implementation Steps

### Task 1: Worktree setup

**Files:**
- none (environment only)

- [x] `git fetch origin master` so the worktree forks the CURRENT remote tip, not a stale local ref
- [x] create the worktree via Claude Code's native support ("work in a worktree" / `EnterWorktree`), never a manual `git worktree add` — Codex equivalent used an isolated Git worktree because it has no native `EnterWorktree` action
- [x] symlink `GhosttyKit.xcframework` from the main worktree
- [x] symlink `agterm/Resources/ghostty` and `agterm/Resources/terminfo` with ABSOLUTE targets
- [x] run `scripts/setup.sh` and confirm it prints `GhosttyKit and resources already present` (it must NOT rebuild libghostty)
- [x] `make build` succeeds in the worktree before any code changes

### Task 2: Pick wire types, protocol fields, and switch routing

**Files:**
- Create: `agtermCore/Sources/agtermCore/ControlPick.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift`
- Modify: `agterm/Control/ControlServer.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift`

- [x] create `ControlPick.swift` with `ControlPickItem`, `ControlPickOutcome`, `ControlPickResult`, `ResolvedPick`, and the `maxItems` constant
- [x] add `pickOpen`/`pickResult`/`pickCancel` cases to `Command` in `ControlProtocol.swift`
- [x] add `items`/`prompt`/`allowCustom` to `ControlArgs` (reuse the existing `window` and `follow` fields)
- [x] add `pick: ControlPickResult?` to `ControlResult` and `pickPending: String?` to `ControlTree`
- [x] route the three cases in `ControlDispatcher.dispatch` to `return nil` — the switch at `:150` is EXHAUSTIVE with no `default:`, so omitting this breaks the `agtermCore` build and makes this task's own `swift test` gate unrunnable
- [x] add the three cases to the fallthrough case list in `ControlServer.swift:374` — that switch is exhaustive too, so omitting this breaks the app target
- [x] write round-trip tests for all three commands and every `ControlPickResult` outcome shape
- [x] write `…OmitsWhenNil` tests for `ControlResult.pick`, `ControlTree.pickPending`, and `ControlPickItem.subtitle`
- [x] verify `ControlProtocol.swift` (was 806) and `ControlDispatcher.swift` (was 794) are still under 1000 lines
- [x] gates: `swift test`, `make lint`, `make build` — all must pass before task 3

### Task 3: PickController and PickRegistry

**Files:**
- Create: `agtermCore/Sources/agtermCore/Pick.swift`
- Create: `agtermCore/Tests/agtermCoreTests/PickTests.swift`

- [x] create `Pick.swift` with `PendingPick`, `PickController` (`@Observable @MainActor`), and `PickRegistry` (`@MainActor`, `shared`), modeled on `TerminalZoom.swift:109-193`
- [x] implement `open` returning false when one is already pending, plus `resolve`, `cancel`, and `result(for:)`
- [x] retain exactly one `ResolvedPick` per controller so a late poll still gets its answer, overwritten on the next `open`
- [x] keep the file Foundation + Observation only — no AppKit, GhosttyKit, Metal, or CoreGraphics geometry
- [x] write tests for open/resolve/cancel, the already-pending rejection, and reading a result after resolution
- [x] write tests for `result(for:)` with an unknown id, and for `lastResult` being replaced by the next open
- [x] write registry tests for register/unregister/lookup and lookup with a nil id
- [x] gates: `swift test`, `make lint`, `make build` — all must pass before task 4

### Task 4: Dispatcher arms, ControlActions surface, and mock

**Files:**
- Create: `agtermCore/Sources/agtermCore/ControlDispatcher+Pick.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/MockControlActions.swift`
- Create: `agtermCore/Tests/agtermCoreTests/ControlDispatcherPickTests.swift`

- [x] widen `ControlDispatcher.actions` from `private` to internal (`ControlDispatcher.swift:143`) — `private` is FILE-scoped in Swift, so a `+Pick.swift` extension cannot reach it and the build fails
- [x] add `openPick`, `pickResult`, and `cancelPick` to the `ControlActions` protocol with doc comments naming what the host owns (registry lookup, window resolution, presentation)
- [x] create `ControlDispatcher+Pick.swift` holding `dispatchPickCommand`, owning all item validation, the missing-target checks, error strings, and the response shape
- [x] replace the three `return nil` stubs from task 2 with real routing to the new arm
- [x] add the three methods and their `Call` cases to `MockControlActions` — it is `final class MockControlActions: ControlActions` and will not compile until every requirement is satisfied
- [x] write tests for every validation rejection: empty items, empty label, duplicate ids, over `maxItems`, control characters, missing target on result/cancel
- [x] write tests asserting a rejection mutates nothing (the mock records no host call)
- [x] write tests for routing and for the success response shape of each command
- [x] verify `ControlDispatcher.swift` is still under 1000 lines
- [x] gates: `swift test`, `make lint`, `make build` — all must pass before task 5

⚠️ Adding the three protocol requirements made the existing app-side `ControlServer` conformance fail
before task 5, contradicting the per-task build gate. `ControlDispatcher+Pick.swift` therefore supplies
explicit-failure `no pick surface` defaults for the intermediate state. Task 5 removes those temporary
defaults after adding concrete `ControlServer` witnesses for all three methods; the mock already uses
explicit witnesses. The exhaustive app switch keeps a dedicated picker `preconditionFailure` arm after
removing the commands from its generic dispatcher-failure fallthrough list.

### Task 5: App-side pick host

**Files:**
- Create: `agterm/Control/ControlServer+Pick.swift`
- Modify: `agterm/Control/ControlServer.swift`
- Create: `agtermTests/ControlServerPickTests.swift`

**Note:** nothing registers a `PickController` with `PickRegistry` until task 7, so `pick.open` returns
`no pick surface` for the whole window between this task and that one. That is expected — do not debug it
as a phantom.

- [x] create `ControlServer+Pick.swift` implementing the three `ControlActions` methods
- [x] resolve the target store/window via `resolvePlacementStore(window)` (frontmost default), erroring `no open window` when there is none
- [x] look up the window's `PickController` through `PickRegistry` and return `pick already pending` when `open` refuses
- [x] close the built-in palette when the pick's window is frontmost, and raise + select the window only under `follow`
- [x] remove the three cases from the `ControlServer.swift:374` fallthrough list now that the dispatcher owns them
- [x] write hosted tests (`agtermTests`, the `DockMenuTests` precedent) for the no-window arm, the registry-miss arm, and the already-pending rejection
- [x] gates: `swift test`, `make lint`, `make build`, `make test-app` — all must pass before task 6

### Task 6: CommandPalette accepts explicit items

**Files:**
- Modify: `agterm/Views/Palette.swift`

- [x] change `CommandPalette.allItems` (`Palette.swift:96-105`) so an explicitly-supplied `[PaletteItem]` array takes precedence over the `controller.mode` switch, leaving all five existing modes untouched
- [x] render the synthetic `Use "<query>"` row when `allowCustom` is set and the filtered list is empty, selected so Enter resolves it
- [x] use the supplied `prompt` as the field placeholder, defaulting to `Select…` when absent — do NOT fall through to the `placeholder` switch's `default:` arm (`Palette.swift:134`), which returns the action-palette's `Run an action…` and would be plainly wrong on a pick
- [x] give the pick-driven instance the accessibility identifier `pick-palette` (distinct from the shared `command-palette` at `Palette.swift:182`) and give rows a per-item identifier, so task 11's e2e can address them
- [x] hoist the custom-row decision into a host-free helper in `agtermCore` (given a query and a filtered count, does a custom row exist and what is its label) so it is unit-testable — the SwiftUI view itself is not reachable from `swift test`
- [x] write host-free tests for that helper: empty query, query matching nothing with and without `allowCustom`, query matching something
- [x] verify the five existing palette modes still render and filter unchanged
- [x] gates: `swift test`, `make lint`, `make build`, `make test-app` — all must pass before task 7

### Task 7: Mount the pick palette and guard focus

**Files:**
- Modify: `agterm/Views/WindowContentView.swift`
- Modify: `agterm/AppActions+Focus.swift`
- Modify: `agterm/Views/Palette.swift`
- Create: `agtermTests/PickFocusGuardTests.swift`

- [x] mount a pick-driven `CommandPalette` from `WindowContentView` observing the window's `PickController`
- [x] register and unregister that controller with `PickRegistry` on the window's lifecycle, alongside the existing registry registrations at `WindowContentView.swift:192-196`
- [x] resolve `picked` with id/label/index, `custom` with the query, and Esc or scrim tap with `cancelled`
- [x] extend the `focusActiveSession` guard (`AppActions+Focus.swift:118-135`) to bail while the window has a pending pick — a separate `PickController` does not trip the existing `palette?.mode != nil` term, and opening a pick CLOSES the built-in palette, which is exactly what starts the ~12×0.03s `makeFirstResponder` retry loop that would steal the pick's field focus
- [x] extend the same term in `focusSplitPane` (`AppActions+Focus.swift:186`)
- [x] verify `WindowContentView.swift` (was 844) is still under 1000 lines; split to `WindowContentView+Pick.swift` if not
- [x] gates: `swift test`, `make lint`, `make build`, `make test-app` — all must pass before task 8

### Task 8: Dismissal and lifetime

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Pick.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/PickTests.swift`
- Modify: `agterm/AppActions.swift`
- Modify: `agterm/Control/ControlServer+Pick.swift`
- Modify: `agterm/Views/WindowAccessor.swift`
- Modify: `agterm/Views/WindowContentView.swift`
- Modify: `agtermTests/ControlServerPickTests.swift`

- [x] add the pending-pick check as the FIRST branch of `closeActiveSession()` (`AppActions.swift:251`), ahead of terminal zoom, cancelling the pick and returning `true`
- [x] resolve a pending pick to `cancelled` when its window closes
- [x] resolve every pending pick to `cancelled` on app termination, alongside the existing quit flush
- [x] confirm a pick left pending never blocks quit or the quit-confirmation prompt
- [x] write a hosted test for the ⌘W precedence — a pending pick cancels ahead of an active terminal zoom, and the zoom survives
- [x] write a hosted test for window-close resolving a pending pick to `cancelled`
- [x] verify `WindowContentView.swift` is still under 1000 lines
- [x] gates: `swift test`, `make lint`, `make build`, `make test-app` — all must pass before task 9

### Task 9: Tree read-back

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift`
- Modify: `agterm/Control/ControlServer.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreTests.swift`

- [x] add a `pickPending: () -> String?` closure parameter to `AppStore.controlTree`, defaulting to nil for host-free tests (the `quickVisible`/`zoomedSurface` seam)
- [x] populate it app-side in `buildTree` from the projected window's `PickController` via the registry
- [x] confirm the field is LIVE and `tree`-only — do NOT mirror it onto the cached `window.list` nodes
- [x] write a `controlTreeReportsPickPendingFromClosure` test and one asserting omission when no pick is pending
- [x] verify `AppStore.swift` (was 977, the closest of any touched file to the cap) is still under 1000 lines; split to `AppStore+Pick.swift` if not
- [x] gates: `swift test`, `make lint`, `make build` — all must pass before task 10

### Task 10: agtermctl pick subcommands

**Files:**
- Modify: `agtermCore/Sources/agtermctlKit/MiscCommands.swift`
- Modify: `agtermCore/Sources/agtermctlKit/SocketClient.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/CommandsTests.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/SocketClientTests.swift`

- [x] add a `pick` command group with `Open` (the default), `Result`, and `Cancel` subcommands, mirroring `session overlay`'s `[Open, Close, Resize, Result]` at `SessionCommands.swift:606` — all three control commands need a CLI verb to satisfy point 3 of the four-point audit, and without them `--no-block` is unusable
- [x] give `Open` the `--prompt`, `--allow-custom`, `--follow`, `--window`, `--no-block` options — there is deliberately NO `--timeout`, since a caller wanting a deadline writes `timeout 60 agtermctl pick …` and clears the orphaned modal with `pick cancel`
- [x] read stdin and sniff the first non-whitespace byte: `[` parses as a JSON item array, anything else is one label per line with blank lines dropped
- [x] implement the blocking path — open, poll `pick.result` until it leaves `pending`, print the result JSON on stdout — with `--no-block` printing the pick id instead
- [x] use a backing-off poll (0.1s for the first second, then 0.5s) rather than the overlay's flat 0.1s, which is tuned for sub-second programs and would hammer the serial accept loop across an unbounded human decision
- [x] map outcomes to exit codes 0 (picked/custom), 1 (failure), 2 (cancelled)
- [x] write tests for the stdin sniff across JSON, bare lines, blank lines, empty stdin, and malformed JSON
- [x] write tests for CLI-to-request argument mapping for all three subcommands
- [x] write tests for the exit-code mapping of every outcome, and for the poll backoff schedule
- [x] verify `MiscCommands.swift` (was 402) is still under 1000 lines
- [x] gates: `swift test`, `make lint`, `make build` — all must pass before task 11

### Task 11: End-to-end tests

**Files:**
- Create: `agtermUITests/ControlPickUITests.swift`

- [x] create `ControlPickUITests` as a `ControlAPITestCase` subclass
- [x] test open → the `pick-palette` modal appears with the supplied rows → select → `pick.result` returns `picked` with the right id, label, and index
- [x] test open → `pick.cancel` → `pick.result` returns `cancelled`
- [x] test a second `pick.open` on the same window is rejected with `pick already pending`
- [x] test the `tree` read-back reports `pickPending` while open and omits it after resolution
- [x] test the free-text path: `--allow-custom` with a non-matching query returns `custom` carrying the query
- [x] test the `--window` leg drives a background window, using a MINIMIZED second window so an arm ignoring the selector lands on the wrong store
- [x] run the suite — must pass before task 12

### Task 12: Verify acceptance criteria

- [x] verify all requirements from Overview are implemented
- [x] verify every validation rejection returns its documented error and mutates nothing
- [x] verify the four-point audit for EACH of the three commands: `Command` case + args, dispatcher arm, `agtermctl` subcommand, round-trip + e2e tests
- [x] verify the read-back obligation: `pickPending` shipped in the same change, with round-trip and populate tests
- [x] verify no file the plan touched crossed 1000 lines
- [x] run `cd agtermCore && swift test`
- [x] run `make test-app`
- [x] run the focused `ControlPickUITests` suite — the repository-wide UI suite is explicitly excluded by user instruction
- [x] run `make lint` — must report zero findings under `--strict`
- [x] run `make build`

### Task 13: [Final] Update documentation

**Files:**
- Modify: `agterm/Resources/agent-skill/SKILL.md`
- Modify: `agterm/Resources/agent-skill/reference.md`
- Modify: `agterm/Resources/agent-skill/examples.md`
- Modify: `agtermCore/Tests/agtermCoreTests/SkillInstallTests.swift`
- Modify: `site/commands.html`
- Modify: `site/docs.html`
- Modify: `README.md`
- Modify: `.claude/rules/control-api.md`

- [x] add the three commands to the bundled agent skill: SKILL.md summary, reference.md per-command detail, examples.md recipes
- [x] add three entries to `site/commands.html` in the right family section, each carrying invocation, arguments, and the `tree` read-back field
- [x] add a `pick.open`/`pick.result`/`pick.cancel` bullet to the command CATALOG list in `.claude/rules/control-api.md:287` — separate from the count bump and easy to miss
- [x] add the pick section to `.claude/rules/control-api.md` using semantic line breaks (one sentence per line)
- [x] bump the command count from 68 to 71 EVERYWHERE — grep for the PATTERN, never for the old or new number, since a surface already stale at a third value is invisible to a search for either
- [x] update the known count sites: `README.md:187`, `SKILL.md:145`, `site/docs.html:1124`, `site/commands.html:9,21,33,238`, `.claude/rules/control-api.md:209,287,316,1740`
- [x] update the hardcoded assertion in `SkillInstallTests.swift:17` (`#expect(skill.contains("Command summary (68 commands)"))`) — it is a required EDIT, not merely a detector, and `swift test` ends red without it
- [x] finish with `rg -n '\b[0-9]{2,3}\b' .claude/rules/control-api.md` and read every hit — the phrasings "the public command count stays N" and "`Command` has N cases" do not match a "N commands" grep and have survived a bump before
- [x] update `README.md` and `site/docs.html`
- [x] confirm `CHANGELOG.md` is UNTOUCHED (release-only) and no `cookbook/` recipe was swept (deliberately not a keep-in-sync surface)
- [x] gates: focused `swift test --filter 'SkillInstallTests.bundledSkillDocumentsEventSubscriptionCommand'` substituted for broad `swift test` per user override; `make lint`; `make build`
- [x] move this plan to `docs/plans/completed/`
## Post-Completion

*Items requiring manual intervention — no checkboxes, informational only*

**Manual verification** on an isolated dev instance (`open -n --env AGTERM_STATE_DIR=/tmp/pickdev …`,
never against the deployed daily driver's default socket):

- a pick opened on a background window does not steal focus; `--follow` raises it
- the built-in ⌃⇧P palette closes cleanly when a pick opens over it, and reopens normally after
- the free-text `Use "…"` row reads as an obvious affordance rather than a glitch
- a long list scrolls and fuzzy-filters at the same speed as the session palette
- ⌘W on a pending pick cancels it and leaves the session behind it untouched
- the caller's blocking `agtermctl pick` returns promptly on selection with no perceptible poll lag

**Worktree cleanup after merge:**

- merge and delete the branch FROM THE MAIN CHECKOUT, never from the worktree — `gh pr merge --delete-branch`
  run inside the worktree switches its branch
- a squash merge makes `ExitWorktree`/`git worktree remove` refuse with "N commits will be discarded
  permanently". This is expected, not a failure. Verify the squash landed on `origin/master`
  (`gh pr view <n> --json state,mergeCommit` plus `git fetch origin master`), then re-invoke `ExitWorktree`
  with `discard_changes: true`
- `ExitWorktree` references the ORIGINAL `worktree-<name>` branch, so a renamed local branch survives and
  needs a separate `git branch -D <name>` from the main checkout

**Follow-ups deliberately deferred** (not scope creep — record them, do not build them):

- badge and status-glyph fields on items; `PaletteItem` already renders both, and JSON items are additive
- a cookbook recipe collapsing `workspace-sets` and `project-switcher` from one keybinding per group to a
  single chord over a dynamic list
- one line in the agent-skill docs warning that a pick blocks its caller until a human answers, so an
  unattended machine means an unbounded poll; the remedy is `timeout N agtermctl pick …`, which is the
  caller's business, not agterm's

---

*Smells pre-check: skipped — non-Go project*
