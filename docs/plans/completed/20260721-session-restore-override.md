# Per-session restore-command override (`session.restore`)

## Overview

The restore-running-command feature re-runs each pane's captured foreground argv **verbatim** on the next
launch. That is correct for idempotent commands (`claude --resume <uuid>` reattaches the same session every
time) and wrong for non-idempotent ones:

- `claude --resume <uuid> --fork-session` mints a **new** claude session on every agterm restart. The session
  the user was actually working in is never resumed, and near-identical transcripts accumulate (discussion
  #264 reports 6 same-titled sessions, 3 created in the same second — the restart moment).
- `claude -r` / bare `claude --resume` capture no session id at all, so restore lands in the interactive
  picker rather than the session that was open.

agterm cannot know which commands are idempotent, but it is the only layer where the user — or tooling
acting for the user — can fix it. Capture and restore both live entirely inside agterm (foreground argv read
at quit via `sysctl`, re-run on next launch through `initial_input`), so no external process can rewrite the
seam.

This adds a **per-session, per-pane restore-command override**: persisted state that wins over the captured
foreground on the next restore. It is write-now, consume-next-launch — setting it never touches the running
session. Ownership flips to whoever sets it: a Claude Code `SessionStart` hook knows the live child uuid and
rewrites the override on every start, so the next restart reattaches instead of forking. Write once and
forget and it stays pinned to a stale uuid — that is the deliberate tradeoff, and it is why this is a
hook-driven override rather than a set-once setting.

Benefits:

- non-idempotent foreground commands restore correctly, driven by whoever knows the right invocation
- a per-session opt-out ("this session restores nothing") that today only exists app-globally
  (`restore.clear`, one-shot) or as a too-broad basename entry in `restore-denylist.conf`
- full read-back on `tree`, so a script can record and restore what it changed

Explicitly **out of scope**:

- Settings-level pattern skip/rewrite rules (idea 2 in the discussion). Rewriting other tools' argv is a
  rules engine agterm should not own, and the skip half already exists as `restore-denylist.conf`.
- Shipping a bundled Claude Code `SessionStart` hook. `AgentHooksInstaller` already merges four Claude Code
  hooks, so adding a fifth is possible — but the correct invocation is user- and workflow-specific (which
  claude flags, which pane, whether to pin at all), and guessing it wrong pins the wrong command on every
  start. The hook ships as a documented `examples.md` recipe the user adapts, not as installed machinery.

## Context (from discovery)

Files/components involved:

- `agtermCore/Sources/agtermCore/CommandRestore.swift` — host-free restore judgement: `restorePlan`,
  `shouldRestore`, `parseDenylist`, `shellQuotedLine`, `parseProcArgs`
- `agtermCore/Sources/agtermCore/Session.swift` — `foregroundCommand` / `splitForegroundCommand` /
  `initialCommand` / `wasRestored`, plus `paneRole(forToken:)` (live-slot pane resolution, the #199 fix)
- `agtermCore/Sources/agtermCore/Snapshot.swift` — `SessionSnapshot` persisted fields + the custom decoder
- `agtermCore/Sources/agtermCore/AppStore.swift` — `restore(from:)`, `session(from:)` /
  `workspace(from:)` (snapshot rebuild), `sessionSnapshot(_:)` (capture), `controlTree` (the tree builder)
- `agtermCore/Sources/agtermCore/WindowLibrary.swift` — `loadStore(for:)` (calls `restore(from:)`),
  `closeWindow` (drops the store), and the three bootstrap load sites
- `agterm/ContentView.swift` — `resolveStore()`, the RUNTIME `loadStore` caller
- `agtermCore/Sources/agtermCore/AppStore+RecentClosed.swift` — Reopen Closed Item; rebuilds sessions from
  snapshots at three call sites
- `agtermCore/Sources/agtermCore/AppStore+PendingClose.swift` — the grace-window undo; reinserts the ORIGINAL
  `Session` object rather than rebuilding
- `agtermCore/Sources/agtermCore/AppStore+Panes.swift` — `closeSplit` (split teardown state clearing),
  `closePrimaryPane` (promotion, which already migrates `splitForegroundCommand` up)
- `agtermCore/Sources/agtermCore/AppStore+Status.swift` — 64-line `AppStore` extension; the precedent for
  giving a small store concern its own file
- `agtermCore/Sources/agtermCore/AppStore+Duplicate.swift` — duplicate builds a fresh `Session` via
  `addSession`, so it copies no per-session command state
- `agtermCore/Sources/agtermCore/ControlProtocol.swift` — `Command` enum, `ControlArgs`, `ControlSessionNode`
- `agtermCore/Sources/agtermCore/ControlModes.swift` — `ControlSessionStatusUpdate` and friends
- `agtermCore/Sources/agtermCore/ControlDispatcher.swift` — `ControlActions` protocol + host-free dispatch
- `agtermCore/Sources/agtermctlKit/SessionCommands.swift` — the `session` CLI subcommand tree
- `agtermCore/Sources/agtermctlKit/MiscCommands.swift` — the existing top-level `Restore` (`restore clear`)
- `agterm/Control/ControlServer+SessionActions.swift` — app-side action arms (**998 lines / 1000 limit**)
- `agterm/Control/ControlServer.swift` — `clearRestoreCommands` (the `restore.clear` arm)
- `agterm/agtermApp.swift` — `makeSurface` / `makeSplitSurface` / `restoreInitialInput`
- `agterm/AppDelegate.swift` — `captureForegroundCommands` at quit
- `agtermUITests/RestoreCommandUITests.swift` — the relaunch e2e harness

Related patterns found:

- **Pane addressing**: `session.status` takes `--pane left|right|scratch` plus `--pane-id`, resolving the
  token through `Session.paneRole(forToken:)` first (live slot, survives split promotion) and falling back to
  the baked `--pane`. Shells already export `AGTERM_PANE` and `AGTERM_PANE_ID`.
- **Run-once consumption**: `foregroundCommand` / `splitForegroundCommand` are read then nil'd by the surface
  factories, which is what stops a re-shown split from re-firing them.
- **Dispatcher-first**: parsing/validation/response shape belong in `ControlDispatcher`; the app target
  supplies only target resolution and side effects via `ControlActions`.
- **Read-back pairing**: every state-mutating command has a matching `ControlSessionNode` field
  (`session.focus`/`splitFocused`, `session.resize`/`splitRatio`, `session.overlay.resize`/`overlaySizePercent`),
  covered by BOTH a protocol round-trip and a `controlTree` populate test.
- **Forward-compat persistence**: every post-v1 `SessionSnapshot` field is optional and decoded with
  `decodeIfPresent` so an older snapshot still loads instead of wiping the tree.

Dependencies identified:

- `ControlArgs` already carries `command`, `mode`, `pane`, `paneID` — **no new wire args needed**. Their doc
  comments enumerate the commands that consume them, so reusing them means updating those comments.
- **Adding a `Command` case breaks two exhaustive switches at once.** Neither `ControlDispatcher.dispatch`
  (`ControlDispatcher.swift:136`) nor `ControlServer`'s dispatcher-fallback switch (`ControlServer.swift:365`)
  has a `default:` — both enumerate every case and end at `.debugAppearance`. Combined with `ControlActions`
  having **no protocol extension defaults** (no `extension ControlActions` exists anywhere), the enum case,
  the protocol requirement, the mock, the dispatcher routing, and the app-side arm must all land in ONE task
  or the tree does not compile. Splitting them across tasks was tried in an earlier draft and does not work.
- `MockControlActions` (test double) must gain any new `ControlActions` method or `swift test` will not build.
- **The CLI session selector is `--target`, not `--session`** (`TargetOptions`, `Commands.swift:68`), and
  there is no shared `--pane` / `--pane-id` option group — `Session.Status` declares its own
  (`SessionCommands.swift:358`), so the new subcommand declares its own too. Extracting a shared group for
  two consumers is not worth it.
- Command count is currently **61**, tracked across five files (see the Documentation task).

Constraints verified against tooling:

- **`make lint --strict` fails at 6+ function parameters.** `.swiftlint.yml` leaves
  `function_parameter_count` at its defaults (warning 5), and `--strict` promotes warnings to errors —
  confirmed by linting a synthetic 6-param function. `CommandRestore.restorePlan` already takes 5, so it must
  move to an options struct (also what the global CLAUDE.md "option structs for 4+ parameters" rule wants).
  This was weighed against folding the override into the existing `hadForeground`/`foregroundInput` pair,
  which also reproduces the precedence table; the struct was chosen so the precedence stays in one host-free
  tested function rather than a boolean computed in untested app-target glue.
- `ControlSessionNode.init` is unaffected: `ignores_default_parameters` is on by default and the new fields
  carry `= nil` defaults.
- **Source files stay under 1000 lines.** Current sizes for files this plan touches:
  `ControlServer+SessionActions.swift` **998** (hence the prep split in Task 1), `AppStore.swift` **955**
  (hence `setRestoreCommand` going in its own extension file), `ControlProtocol.swift` 683,
  `SessionCommands.swift` 653, `ControlDispatcher.swift` 649, `ControlServer.swift` 589, `Session.swift` 400,
  `Snapshot.swift` 189, `ControlModes.swift` 152, `CommandRestore.swift` 128.
- **Test files stay under 2000 lines.** `AppStoreTests.swift` **1875** (tightest in the repo),
  `ControlDispatcherTests.swift` 1653, `ControlAPIUITests.swift` **1548**, `CommandsTests.swift` 1248,
  `ControlProtocolTests.swift` 1277, `AppStorePaneTests.swift` 891, `SessionTests.swift` 455,
  `MockControlActions.swift` 429, `RestoreCommandUITests.swift` 265, `ControlModesTests.swift` 70.

## Development Approach

- **testing approach**: Regular (code first, then tests within the same task)
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
- run tests after each change
- maintain backward compatibility

Project-specific gates (from `CLAUDE.md`), applied before marking **any** task complete:

1. `cd agtermCore && swift test` is green
2. **`make build` succeeds** — required on every task marked *(app target)*, because `swift test` compiles
   only `agtermCore`/`agtermctlKit` and would silently defer an app-target break
3. `make lint` passes (swiftlint `--strict`, zero findings)
4. no source file crosses 1000 lines, no test file crosses 2000
5. `agtermCore` stays host-free — no GhosttyKit, AppKit, Metal, **or CoreGraphics** types

Work happens in an **isolated git worktree** (project rule for non-trivial changes). Before creating it, run
`git fetch origin master` so it forks the current remote tip. A fresh worktree lacks the gitignored build
artifacts, so symlink them before the first build (absolute targets for the two under `agterm/Resources/`):

```
ln -s <main>/GhosttyKit.xcframework GhosttyKit.xcframework
ln -s <main>/agterm/Resources/ghostty  <wt>/agterm/Resources/ghostty
ln -s <main>/agterm/Resources/terminfo <wt>/agterm/Resources/terminfo
```

## Testing Strategy

- **unit tests** (`cd agtermCore && swift test`): required for every task. The bulk of this feature is
  host-free and belongs here — precedence table, dispatcher validation, protocol round-trips, store
  mutations, snapshot round-trips, `controlTree` population.
- **e2e tests** (XCUITest, `agtermUITests/`): agterm has no browser e2e; the equivalent is XCUITest driving
  the real app over the control socket. Required here because the payoff — a command actually re-running
  after a relaunch — is only observable end to end.
  - `RestoreCommandUITests.swift` already has the harness: an isolated `AGTERM_STATE_DIR`, a ⌘Q quit so
    `applicationWillTerminate` fires the capture, and a `tee <marker>` foreground whose recreated marker file
    proves a re-run. The harness deletes the marker before quitting, so a recreated marker means a re-run.
    Reuse it rather than inventing a new mechanism.
  - `ControlAPIUITests.swift` carries the `tree` read-back assertions.
  - treat e2e with the same rigor as unit tests: they must pass before the next task.
- **Stickiness needs two relaunches.** The design's load-bearing property is that the override persists and
  fires again on the *next* restart. Every single-relaunch test passes even against an implementation that
  nils the persisted field on consume — the most likely implementer mistake, since the adjacent capture does
  exactly that. Task 9 therefore includes a two-relaunch e2e, and Task 2 asserts the persisted field
  survives `takePendingRestoreOverride`.

Do **not** weaken, narrow, or delete a failing test to get green (project cardinal rule). A failing test means
the code is wrong until instrumented evidence says otherwise.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope
- keep plan in sync with actual work done

## Solution Overview

A per-pane, persisted, **sticky** override that wins over the captured foreground at restore time.

**Tri-state semantics** on a single `String?` field per pane:

| value | meaning |
|---|---|
| `nil` | no override — today's auto-capture behavior, unchanged |
| `""` | pinned to nothing — plain shell; suppresses both the capture and `initialCommand` |
| `"cmd"` | pinned — run this shell line |

**Precedence at restore** (main pane), gated on the `restoreRunningCommand` setting:

| override | setting | result |
|---|---|---|
| `nil` | either | today's logic, byte-for-byte unchanged |
| `"cmd"` | on | `initialInput = "cmd\n"`; denylist not consulted |
| `"cmd"` | off | plain shell |
| `""` | either | plain shell — capture **and** `initialCommand` suppressed |

Key design decisions and rationale:

- **Its own persisted slot, never the capture's.** If the override shared `foregroundCommand`, the quit-time
  capture of the live `--fork-session` process would clobber it and restore would fork again. The whole
  feature hinges on this.
- **Sticky, not run-once.** The capture is consumed (nil'd) on read; the override persists across restores,
  because a hook rewrites it on every session start. That is what keeps it tracking the live fork child.
- **Fires on app bootstrap only, from a payload snapshotted at bootstrap.** The `restoreRunningCommand`
  capture only ever fires at launch, and the override matches it. The eligible value is copied into a
  transient *pending* slot at bootstrap and consumed from there; the factory never reads the live persisted
  field. That freezes what was eligible when the process started, so nothing a socket client writes later can
  execute during this run. See "Lifecycle interactions" for the three paths this is load-bearing for.
- **Delivered through `initial_input`, not the exec `command` path.** Same channel as the captured foreground
  it replaces: the login shell survives the command's exit (the user lands at a prompt instead of the session
  closing), and the line runs through the login rc so an aliased or shell-function `claude` still resolves.
- **Typed verbatim, never re-quoted** through `shellQuotedLine`. It is a shell line, so `cd x && claude
  --resume y` works as written.
- **Obeys the global setting, bypasses the denylist.** `initialCommand` — the closest sibling, also explicit
  and user-set — is gated by `restoreRunningCommand`, so the toggle stays the single master switch. The
  denylist is a basename heuristic for *blind* capture; an override names its command deliberately, so it
  wins. The bypass is structural: the override never routes through the app-side `restoreInitialInput`
  denylist gate.
- **Consumed once per launch, via a pending payload rather than a "consumed" flag.** Sticky state plus a
  factory that can run more than once per launch is a re-fire hazard. An earlier draft used transient
  `…Consumed` booleans guarding a read of the persisted field; that is not robust, because the guarded read
  is of *mutable live* state. A client that pins between `session.new` and SwiftUI's surface factory run
  would have its command execute immediately on a fresh session (and `--none` could suppress a fresh
  `session.new --command`). Snapshotting the payload at bootstrap removes the whole class.
- **`restore.clear` stays capture-scoped.** It already deliberately leaves `initialCommand` alone; widening
  it past its documented contract would surprise. Stale overrides clear per-session with
  `session restore --clear`.

Fit with the existing system: control-native, no GUI surface. No `AppActions` seam, no menu item, no palette
entry, and no Settings ▸ Interface toggle (there is no toggleable chrome here), so the GUI keep-in-sync rules
do not bind. The control-API keep-in-sync rules bind fully — new `Command` case, dispatcher arm, `agtermctl`
subcommand, round-trip + e2e tests, plus the `tree` read-back that every state-mutating command owes.

## Technical Details

### New persisted state (`agtermCore`)

```swift
// Session.swift — @ObservationIgnored, mirroring foregroundCommand/splitForegroundCommand
// PERSISTED, sticky. nil = auto-capture, "" = pinned to nothing, "cmd" = run it.
public var restoreCommand: String?          // main pane
public var splitRestoreCommand: String?     // split pane

// TRANSIENT, never persisted. Seeded ONLY by an app-bootstrap restore, from the persisted field
// above; consumed (take-and-nil) by the surface factory. A session that was not bootstrap-restored
// — freshly created, reopened from Recent Closed, duplicated, or rebuilt when a closed window was
// reloaded mid-process — starts with both nil, so nothing fires.
public var pendingRestoreCommand: String?
public var pendingSplitRestoreCommand: String?

/// Takes the pane's pending override, clearing it so a second surface for the same pane this launch
/// gets a plain shell. The PERSISTED field is never read here and never written — the override is
/// sticky and must fire again after the next restart. `.scratch` always returns nil.
public func takePendingRestoreOverride(pane: StatusPane) -> String?
```

The pending/persisted split is the whole safety property, so it is worth stating plainly: **the factory
reads only `pending*`; the control command writes only the persisted fields; only bootstrap copies one to
the other.** An implementation that has the factory fall back to the persisted field reintroduces every
hazard below.

```swift
// Snapshot.swift — SessionSnapshot, both optional + decodeIfPresent (forward-compat)
public var restoreCommand: String?
public var splitRestoreCommand: String?
```

### Restore precedence (`CommandRestore`)

`restorePlan` already takes 5 parameters and a 6th would fail `make lint --strict`, so it moves to an options
struct:

```swift
public struct RestoreInputs: Equatable, Sendable {
    public let wasRestored: Bool
    public let restoreEnabled: Bool
    public let hadForeground: Bool
    public let foregroundInput: String?
    public let initialCommand: String?
    public let restoreOverride: String?
}

public static func restorePlan(_ inputs: RestoreInputs) -> RestorePlan

/// The `initial_input` for a pane: a pinned override (empty → nil, a plain shell) when one exists,
/// else the captured foreground input. The override is gated on `restoreEnabled`; the captured input
/// arrives already gated + denylist-filtered from the app side.
public static func restoreInput(restoreEnabled: Bool, restoreOverride: String?,
                                capturedInput: String?) -> String?
```

`restoreInput` semantics:

```
restoreOverride == nil              -> capturedInput          (fall through, unchanged behavior)
restoreOverride != nil, setting off -> nil                    (plain shell)
restoreOverride == ""               -> nil                    (plain shell)
restoreOverride == "cmd"            -> "cmd\n"                (verbatim + newline)
```

`restorePlan` short-circuits when an override is present: `command` is always nil (never the exec path) and
`initialInput` comes from `restoreInput`. With no override it reproduces today's logic exactly.

### Surface factories (app target, `agtermApp.swift`)

- `makeSurface` builds `RestoreInputs` with
  `restoreOverride: session.takePendingRestoreOverride(pane: .left)`.
- `makeSplitSurface` does not use `restorePlan` at all (splits carry no `initialCommand`); it calls
  `CommandRestore.restoreInput(restoreEnabled:restoreOverride:capturedInput:)` directly with
  `session.takePendingRestoreOverride(pane: .right)`.

**Why take-and-nil is required**: `makeSplitSurface` runs again when a split shell exits and the user opens a
fresh split (⌘D). The capture cannot re-fire because it was nil'd on read; a pending payload left in place
would fire a second time mid-session. Taking it makes a fresh manual split a plain shell, matching the
reasoning already documented for hidden-split capture.

### Control surface

```swift
// ControlProtocol.swift
case sessionRestore = "session.restore"

// ControlModes.swift
// `pinNone` rather than `none`: a bare `case none` triggers the compiler's
// "assuming you mean Optional<T>.none" warning wherever the enum appears in an Optional
// context, which the dispatcher's parse step does. Wire tokens stay set|none|clear.
public enum ControlRestoreOverride: Equatable, Sendable {
    case pin(String)   // wire "set"   — pin this shell line
    case pinNone       // wire "none"  — pin to nothing → plain shell
    case unpin         // wire "clear" — back to auto-capture
}

public struct ControlSessionRestoreUpdate: Equatable, Sendable {
    public let pin: ControlRestoreOverride
    public let pane: StatusPane?     // nil → main pane
    public let paneID: String?       // resolved app-side against the LIVE slot
}

// ControlDispatcher.swift — ControlActions
func setSessionRestore(_ target: String?, window: String?,
                       update: ControlSessionRestoreUpdate) -> ControlResponse
```

Wire args reuse `ControlArgs.command` + `mode` (`set` | `none` | `clear`) + `pane` + `paneID`. Dispatcher
rejections (all host-free, all unit-tested):

- unknown `mode` → `invalid restore mode: <x>`
- `mode == "set"` with no `command` → `session.restore set requires a command`
- `command` containing control characters → `command must be a single line` (use `;` / `&&` for more)
- `command` over 1024 **UTF-8 bytes** (`command.utf8.count`, not grapheme count — the cap is a storage
  bound) → `command too long (max 1024 bytes)`
- `pane` not `left` / `right` / `scratch` → the existing `--pane must be left, right, or scratch`

Shell metacharacters are deliberately **not** rejected and the value is never run through
`shellQuotedLine` — verbatim shell syntax is the point (aliases, functions, `&&`, pipelines). The value is
arbitrary shell code that persists in `windows/<id>.json` and is readable via `tree`, so the docs must say
plainly: it may enter shell history, and it must not carry secrets. This adds no privilege boundary — the
socket is owner-only `0600` (`ControlServer.swift:201`) and a same-UID client can already inject arbitrary
keystrokes straight to the child PTY via `session.type` — but it does make a buggy writer's mistake durable
across restarts, which is worth documenting.

App side (`setSessionRestore`) resolves the session through the usual resolver, then the pane:
`paneID` → `session.paneRole(forToken:)` first, falling back to the baked `pane`, as `setSessionStatus` does
— **with one deliberate divergence**. For `session.status` an unresolvable `--pane-id` silently falling back
to `.left` costs a glyph on the wrong row; here it would silently overwrite the *main* pane's persisted
restore command when a hook meant the split. So an unresolvable `--pane-id` supplied **without** an explicit
`--pane` is an error, not a silent fallback. With both given, `--pane` is the intended fallback and is used.

Then:

- pane resolves to `.scratch` → error (`the scratch terminal is never restored`)
- pane resolves to `.right` on a session with no split (`!session.hasSplit`) → error, gated like the focus
  helpers
- otherwise `store.setRestoreCommand(value, pane:forSession:)`, where `value` is `nil` (unpin) / `""`
  (pinNone) / the command
- a `false` from that call → error (`failed to save the restore override, the previous value is still in
  effect`)
- success while `restoreRunningCommand` is **off** returns `ok: true` with a note in `result.text` so a hook
  author can see why nothing will fire

```swift
// AppStore+Restore.swift (new file, following the 64-line AppStore+Status.swift precedent —
// AppStore.swift is at 955/1000 and is already modified by two other tasks)
@discardableResult
public func setRestoreCommand(_ value: String?, pane: StatusPane, forSession id: UUID) -> Bool
```

It persists immediately via `save()`. That matters: the override must survive a SIGKILL, or a hook's write is
lost. It is also the one store write whose failure is REPORTED rather than swallowed: it returns whether the
value reached disk (via the internal `AppStore.saveChecked()`, `save()` with the result kept), rolling the
in-memory field back to the previous value when the write fails. The payload is an arbitrary shell line
re-typed on every launch, so acking a `clear` that never landed would leave the old command running forever,
and without the rollback the unchanged-value guard would swallow the retry as a no-op success.

### Read-back (`tree`)

```swift
// ControlSessionNode — both with `= nil` defaults so the init stays under the lint threshold
public let restoreCommand: String?
public let splitRestoreCommand: String?
```

Populated in the tree builder from the session's persisted fields (**not** the transient consumed flags), so
a read after the override fired still reports what is pinned. Swift's synthesized `encode(to:)` uses
`encodeIfPresent` for optionals, so `nil` omits the key while `""` emits an empty string — the tri-state
survives JSON intact.

### Lifecycle interactions

| event | required handling |
|---|---|
| app bootstrap (`WindowLibrary` reopen / recovery / migration → `restore(from:)`) | the ONLY path that seeds `pending*`, i.e. the only path where an override may fire |
| **closed window reopened mid-process** (`ContentView.resolveStore` → `loadStore` → `restore(from:)`) | must NOT seed — see below |
| Reopen Closed Item (`AppStore+RecentClosed`) | must NOT seed — rebuilds via `session(from:)`, which defaults to no seeding |
| **hidden split at rebuild** (`snapshot.isSplit != true`) | must NOT seed the RIGHT pane, and must DROP the persisted `splitRestoreCommand` — the pane is not rebuilt, so the pin is orphaned; see below |
| `closePrimaryPane` (split promoted to main) | migrate BOTH the persisted and the pending right-pane values into the main slots, then nil the split ones — mirroring the existing `foregroundCommand` migration |
| `closeSplit` (split torn down) | clear `splitRestoreCommand` + `pendingSplitRestoreCommand`, alongside the existing `splitCwd` / `splitRatio` clearing |
| soft close + grace-window undo (`AppStore+PendingClose`) | reinserts the ORIGINAL `Session` object, so an UNCONSUMED pending payload would survive the round trip; all three soft-close entry points (`softCloseSession`, `softCloseSessions`, `softRemoveWorkspace`) clear both pending slots before retaining the objects, so undo can never fire one |
| `session.duplicate` | builds a fresh `Session` via `addSession`, so neither persisted nor pending is copied; no change needed, pin it with a test |
| session moved between workspaces | same `Session` object (`AppStore.swift:442`), so both persisted and pending travel with it; no handling needed |
| scratch / overlay | separate factories that never consult restore state; `.scratch` is rejected at the command layer |
| dashboard / terminal zoom | rehost CACHED surface slots — `TerminalView` returns the cached surface before calling a factory, so no factory re-runs and nothing re-fires |
| `restore.clear` | unchanged — captures only, never overrides |

**Bootstrap is not the same thing as `restore(from:)`.** `WindowLibrary.loadStore(for:)` calls
`store.restore(from: persistence.load())` (`WindowLibrary.swift:350`), and it has a RUNTIME caller:
`closeWindow` drops the store entirely (`stores[id] = nil`, `WindowLibrary.swift:394`), so reopening that
window calls `ContentView.resolveStore()` → `loadStore` (`ContentView.swift:98`) → a full `restore(from:)`
mid-process. Gating on `restore(from:)` alone would therefore arm every sticky override the moment a user
closes and reopens a window, and selecting it would execute them with no app restart. The existing capture
escapes this only by accident (the factories nil it in memory and the close saves the nils); a sticky
override does not.

The flag threads through both layers, defaulting to the safe value:

```swift
func session(from snapshot: SessionSnapshot, launchRestore: Bool = false) -> Session
public func restore(from snapshot: Snapshot, launchRestore: Bool = false)
public func loadStore(for id: UUID, launchRestore: Bool = false) -> AppStore?
```

`launchRestore: true` is passed ONLY from the three `WindowLibrary` bootstrap sites — `reopen`
(`WindowLibrary.swift:540`), its frontmost fallback (`:544`), and orphan recovery (`:569`).
`ContentView.resolveStore()` takes the default. Any caller added later defaults to not firing, which is the
recoverable direction.

**A hidden split seeds nothing AND loses its pin.** `sessionSnapshot` persists only `isSplit`
(`AppStore.swift:917`) and `session(from:)` sets `hasSplit = isSplit`, so a split that was hidden at quit
comes back with no right surface — `makeSplitSurface` never runs at bootstrap. A pending right-pane payload
would then sit unconsumed until the user opens a fresh split with ⌘D, firing a stale command mid-session.
The quit capture already dodges this by refusing to capture hidden splits (`AppDelegate.swift:290`); the
seeding must dodge it the same way. So: seed `pendingSplitRestoreCommand` only when
`snapshot.isSplit == true`, and DROP the persisted `splitRestoreCommand` in the same case
(`AppStore.swift:969`) — the same pane-gone rule `closeSplit` already applies (`AppStore+Panes.swift:64`).

Dropping rather than preserving the pin is a deviation from this plan's first draft, which kept it on the
argument that it would still read back on `tree` and still fire on a later launch where the split is shown.
That reasoning was wrong on both halves. It can never fire on "a later launch where the split is shown":
the session came back with `hasSplit == false` and that split is never rebuilt, so the only way a right pane
exists again is a FRESH ⌘D split — an unrelated shell. Preserving the pin therefore ghost-fires it: pin →
hide split → quit → relaunch (pin preserved, nothing armed) → ⌘D opens a fresh split → quit with it shown →
next launch seeds the preserved pin and types the dead pane's command into the new shell. A preserved pin is
also unclearable, because `session.restore --pane right` is rejected when `!session.hasSplit`
(`ControlServer+SessionActions.swift:445`) — `tree` would report a value no write can remove. Dropping it
restores the invariant that `splitRestoreCommand != nil` implies `hasSplit == true`, which is what keeps
every pinned value clearable. The drop is a property of the REBUILD, not of bootstrap: `session(from:)`
applies it on every path (Reopen Closed Item, a mid-process window reload) so no path can resurrect the
orphan, and the next `save()` writes the drop through to `windows/<id>.json`.

### Processing flow

```
hook (SessionStart, inside the session's shell)
  agtermctl session restore "claude --resume $CLAUDE_SESSION_ID" \
      --target "$AGTERM_SESSION_ID" --pane-id "$AGTERM_PANE_ID"
        -> ControlDispatcher: parse + validate -> ControlSessionRestoreUpdate
        -> ControlServer.setSessionRestore: resolve session + live pane slot
        -> AppStore.setRestoreCommand -> Session.restoreCommand = "claude --resume …" + save()
           (PERSISTED only — pendingRestoreCommand is NOT touched, so nothing fires this run)
        -> windows/<id>.json now carries restoreCommand

quit  -> captureForegroundCommands still writes foregroundCommand (harmless, precedence ignores it)

launch -> WindowLibrary.reopen -> loadStore(launchRestore: true) -> restore(from:launchRestore: true)
       -> session(from:launchRestore: true): pendingRestoreCommand = restoreCommand
          (and pendingSplitRestoreCommand only when snapshot.isSplit; a hidden split ALSO drops its
           persisted splitRestoreCommand — the pane is not rebuilt, so the pin is orphaned)
       -> makeSurface -> takePendingRestoreOverride(.left) -> RestoreInputs -> restorePlan
       -> initial_input "claude --resume …\n" typed into the login shell
       -> restoreCommand STILL SET, so the next launch fires it again
```

## What Goes Where

- **Implementation Steps** (`[ ]` checkboxes): everything achievable in this repo — Swift code, unit tests,
  XCUITests, README/site/agent-skill/rules documentation
- **Post-Completion** (no checkboxes): manual verification against a real Claude Code hook, and the
  discussion-thread reply — external actions

## Implementation Steps

### Task 1: Split `ControlServer+SessionActions.swift` to make room (prep refactor) *(app target)*

The file is at 998 of the 1000-line limit and cannot absorb the new arm. This is a pure code move — no
behavior change, no signature change.

Boundary: extract the **app-global, non-session** arms into a new file, paralleling the existing
`ControlServer+WindowCommands.swift` naming. Moving `controlTree`, the sidebar arms (`setSidebarVisibility`,
`setSidebarViewMode` ×2, `expandSidebar`, `collapseSidebar`, `setSidebar`, `expandWorkspaces`,
`collapseWorkspaces`), keymap/config reload, theme set/list, and the quick-terminal arms (`setQuickTerminal`,
`typeQuick`, `readQuickText`) removes roughly 250 lines, leaving both files with real headroom.

**Files:**
- Create: `agterm/Control/ControlServer+AppCommands.swift`
- Modify: `agterm/Control/ControlServer+SessionActions.swift`

- [x] create `agterm/Control/ControlServer+AppCommands.swift` with an `extension ControlServer` and a file
      header comment describing the split
- [x] move the app-global arms listed above verbatim, preserving their doc comments and any `// MARK:` groups
- [x] verify no private helper is orphaned across the boundary (move helpers used only by moved arms; keep
      shared ones where the majority of callers live)
- [x] confirm both files are comfortably under 1000 lines (`wc -l agterm/Control/*.swift`) — 756 and 256
- [x] run `make build` — a pure move must compile with zero source changes elsewhere
- [x] run `cd agtermCore && swift test` — must stay green (no host-free code moved)
- [x] run `make lint` — must report zero findings
- [x] no new tests: behavior is unchanged and the moved arms keep their existing dispatcher/e2e coverage

### Task 2: Add the per-pane override fields to `Session` and `SessionSnapshot`

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Session.swift`
- Modify: `agtermCore/Sources/agtermCore/Snapshot.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift` (`sessionSnapshot(_:)`, `session(from:)`, `restore(from:)`)
- Modify: `agtermCore/Sources/agtermCore/WindowLibrary.swift` (`loadStore(for:)` + the three bootstrap sites)
- Modify: `agtermCore/Tests/agtermCoreTests/SessionTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/SnapshotRoundTripTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/WindowLibraryTests.swift`

- [x] add `restoreCommand` / `splitRestoreCommand` to `Session` as `@ObservationIgnored public var`, with
      doc comments stating the tri-state (nil = auto-capture, "" = pinned to nothing, "cmd" = run it), that
      they are STICKY unlike the consumed capture, and why they need their own slot (the quit capture would
      otherwise clobber them)
- [x] add the transient `pendingRestoreCommand` / `pendingSplitRestoreCommand`, documented as never
      persisted, seeded only by a bootstrap restore, and the ONLY thing the surface factories read
- [x] add `Session.takePendingRestoreOverride(pane:)` returning the pending value and clearing it;
      `.scratch` returns nil. It must never read or write the persisted field — state that in the doc comment
- [x] add `restoreCommand` / `splitRestoreCommand` to `SessionSnapshot`: stored properties, `init` parameters
      with `= nil` defaults, `CodingKeys` entries, and `decodeIfPresent` lines in the custom decoder
- [x] wire both fields through `AppStore.sessionSnapshot(_:)` (capture) and `AppStore.session(from:)` (restore)
- [x] add `launchRestore: Bool = false` to `AppStore.session(from:)`: seed `pendingRestoreCommand` from the
      snapshot only when `launchRestore`, and seed `pendingSplitRestoreCommand` only when
      `launchRestore && snapshot.isSplit == true` (a hidden split has no right surface at bootstrap, so a
      payload left pending would fire on a later manual ⌘D)
- [x] in the same rebuild, DROP the persisted `splitRestoreCommand` when `snapshot.isSplit != true` — the
      split is not rebuilt, so the pin is orphaned: unclearable (`session.restore --pane right` is rejected
      without a split) and liable to ghost-fire into an unrelated fresh split on a later launch. This is a
      deviation from the original design; see "Deviations from the original design"
- [x] add `launchRestore: Bool = false` to `AppStore.restore(from:)` and to
      `WindowLibrary.loadStore(for:)`, threading it down
- [x] pass `launchRestore: true` from ONLY the three `WindowLibrary` bootstrap sites — `reopen` (:540), its
      frontmost fallback (:544), orphan recovery (:569). Leave `ContentView.resolveStore()` on the default:
      reopening a closed window mid-process must not arm anything
- [x] check `AppStore.swift` (955 before) and `WindowLibrary.swift` (620 before) stay under 1000 lines
- [x] write `SessionTests` for `takePendingRestoreOverride`: returns the pending value once then nil for each
      pane; independent per pane; nil when nothing is pending; `""` is returned (not treated as absent) on
      the first call; `.scratch` always nil
- [x] write the stickiness assertion — after `takePendingRestoreOverride`, `session.restoreCommand` still
      holds its value (this is what catches an implementer mirroring the capture's `= nil`)
- [x] write the isolation assertion — a session with `restoreCommand` set but nothing pending returns nil,
      i.e. the factory path cannot reach live persisted state
- [x] write `SnapshotRoundTripTests` for both fields, including the `""` value and a snapshot JSON *lacking*
      the keys (must decode as nil, not throw — the forward-compat guard)
- [x] write `AppStoreRestoreSeedTests.swift` (new file — `AppStoreTests.swift` is at 1875/2000) covering the
      seeding matrix: bootstrap seeds both panes for a shown split; bootstrap seeds only the main pane for a
      HIDDEN split (`isSplit == false`) and DROPS its persisted `splitRestoreCommand` (asserted on the
      session and on the re-taken snapshot, so the orphan cannot come back); the drop repeats on the
      non-bootstrap rebuild paths; a non-bootstrap `restore(from:)` seeds neither; `session(from:)` defaults
      to seeding neither
- [x] write `WindowLibraryTests` for the runtime-reload gate: bootstrap-load a window with a pinned override,
      `closeWindow` it, `loadStore` it again without `launchRestore`, and assert nothing is pending
- [x] run `cd agtermCore && swift test` - must pass before next task

### Task 3: Add override precedence to `CommandRestore` *(app target)*

**Files:**
- Modify: `agtermCore/Sources/agtermCore/CommandRestore.swift`
- Modify: `agterm/agtermApp.swift` (the existing `restorePlan` call site)
- Modify: `agtermCore/Tests/agtermCoreTests/CommandRestoreTests.swift`

- [x] add the `RestoreInputs` options struct (six `let`s + memberwise `public init`) with a doc comment, and
      change `restorePlan` to take it — required because a sixth parameter fails `make lint --strict`
- [x] add `CommandRestore.restoreInput(restoreEnabled:restoreOverride:capturedInput:)` with a doc comment,
      implementing the four-row table in Technical Details
- [x] rewrite `restorePlan` to short-circuit on a present override (`command` always nil, `initialInput` from
      `restoreInput`) and otherwise reproduce today's logic unchanged
- [x] update the `restorePlan` doc comment: the override wins over both the capture and `initialCommand`, is
      gated on the setting, bypasses the denylist structurally, and is typed verbatim (never `shellQuotedLine`)
- [x] update the call site in `agterm/agtermApp.swift` to the new signature (passing `restoreOverride: nil`
      for now; Task 4 wires the real value) so the app still builds
- [x] write `CommandRestoreTests` for `restoreInput`: nil override falls through to the captured input;
      `"cmd"` + enabled yields `"cmd\n"`; `"cmd"` + disabled yields nil; `""` yields nil regardless
- [x] write `CommandRestoreTests` for `restorePlan` with an override: never takes the exec path; `""`
      suppresses a non-nil `initialCommand`; `""` suppresses a captured `foregroundInput`
- [x] write the regression guard: every pre-existing `restorePlan` case reproduces its old result with
      `restoreOverride: nil` (port the existing assertions to the struct, do not delete them)
- [x] run `cd agtermCore && swift test` + `make build` - must pass before next task

### Task 4: Wire both surface factories to consume the override *(app target)*

**Files:**
- Modify: `agterm/agtermApp.swift`

- [x] in `makeSurface`, build `RestoreInputs` with
      `restoreOverride: session.takePendingRestoreOverride(pane: .left)` and pass it to `restorePlan`
- [x] in `makeSplitSurface`, replace the bare `restoreInitialInput(session.splitForegroundCommand)` with
      `CommandRestore.restoreInput(restoreEnabled:restoreOverride:capturedInput:)`, sourcing the override from
      `session.takePendingRestoreOverride(pane: .right)` and keeping the existing capture consumption
- [x] confirm NEITHER factory reads `session.restoreCommand` / `splitRestoreCommand` directly — pending only
      (grepped: the app target has ZERO references to either persisted field; the only reads anywhere are
      `takePendingRestoreOverride`'s own, and the only writer of `pending*` is `AppStore.session(from:)`)
- [x] update both factories' comments to describe the override precedence and the take-and-nil guard
- [x] run `make build` and smoke-test an isolated dev instance
      (`open -n --env AGTERM_STATE_DIR=/tmp/agterm-restore-dev …`): normal sessions and splits still spawn
      plain shells, splits still restore their captured command
- [x] note: nothing can SET an override until Task 6, so this smoke exercises only the nil path — it is a
      no-regression check, not positive verification of the feature
- [x] no new unit tests here: the decision logic is fully covered in Task 3 and the factories are app-target
      glue with no host-free seam. End-to-end proof lands in Task 9.
- [x] run `cd agtermCore && swift test` + `make lint` - must pass before next task

### Task 5: Add `AppStore.setRestoreCommand` and the pane-lifecycle handling

**Files:**
- Create: `agtermCore/Sources/agtermCore/AppStore+Restore.swift`
- Create: `agtermCore/Tests/agtermCoreTests/AppStoreRestoreTests.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+Panes.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+PendingClose.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStorePaneTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreDuplicateTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/RecentClosedTests.swift`

- [x] create `AppStore+Restore.swift` (following the `AppStore+Status.swift` precedent; `AppStore.swift` is
      at 955 and already modified by Tasks 2 and 7) holding `setRestoreCommand(_:pane:forSession:)`
- [x] give `setRestoreCommand` a doc comment covering the tri-state, the immediate `save()`, why it persists
      eagerly (a hook's write must survive a SIGKILL), and that it deliberately does NOT touch the pending
      slots — a write during this run must not execute during this run
- [x] implement it: write the pane's PERSISTED field and `save()`; no-op and no save when the value is
      unchanged (idempotent, matching `setFlag`); `.scratch` is rejected upstream so it need not be handled
      (kept as an explicit no-op arm anyway — the switch must be exhaustive)
- [x] in `closePrimaryPane`, migrate BOTH values on promotion — persisted `restoreCommand = splitRestoreCommand`
      and pending `pendingRestoreCommand = pendingSplitRestoreCommand`, then nil both split fields —
      alongside the existing `foregroundCommand` migration
- [x] in `closeSplit`, clear `splitRestoreCommand` and `pendingSplitRestoreCommand` next to the existing
      `splitCwd` / `splitRatio` / `initialSplitCwd` clearing (the teardown path `closeSplitPane` routes through)
- [x] in `softCloseSession`, clear both pending slots before the `Session` is retained in the pending-close
      record — the same object comes back on undo, so an unconsumed payload would otherwise survive and fire
      when the restored session's surface is built
- [x] ➕ extend the same clearing to `softCloseSessions` (multi-select, >1 target — it does NOT route through
      `softCloseSession`) and `softRemoveWorkspace`, via a shared `clearPendingRestoreOverrides(of:)` helper
      in `AppStore+Restore.swift`. Both retain the ORIGINAL `Session` objects for undo, so they carry the
      identical hazard the singular path was called out for
- [x] ➕ report the write instead of swallowing it: `setRestoreCommand` returns whether the value reached
      disk, saving through the new internal `AppStore.saveChecked()` (`save()` with the result kept, so the
      two cannot drift) and rolling the in-memory field back to its previous value on failure. A swallowed
      failure would ack a `clear` while the OLD shell line stayed armed on every launch, and without the
      rollback the unchanged-value guard would swallow the retry too
- [x] write `AppStoreRestoreTests` for `setRestoreCommand`: sets per pane independently; `nil` clears; `""`
      is stored as an empty string rather than collapsing to nil; unknown session id is a safe no-op; an
      unchanged value does not re-save; **and it never populates the pending slots**
- [x] ➕ write the failed-write tests: an unwritable persistence directory (the `mutationSurvivesSaveFailure`
      idiom) leaves the previous value in memory for both a `clear` and a replacement, and the same request
      retries and persists once the disk recovers
- [x] write `AppStorePaneTests`: promotion migrates both the persisted and pending split values up and leaves
      the split fields nil; `closeSplit` clears both
- [x] write `AppStoreDuplicateTests`: a duplicate of a session with both overrides set has neither
- [x] write `RecentClosedTests`: a session closed with a pinned override and reopened has nothing pending
      while the persisted field survives
- [x] write the soft-close/undo test: soft-close a session whose pending payload was never consumed, undo
      within the grace window, and assert nothing is pending
- [x] run `cd agtermCore && swift test` - must pass before next task

### Task 6: Add the whole control surface, atomically *(app target)*

This is deliberately ONE task. Splitting it does not compile at any intermediate point: adding
`Command.sessionRestore` breaks the exhaustive switches in `ControlDispatcher.dispatch`
(`ControlDispatcher.swift:136`) and `ControlServer`'s dispatcher-fallback (`ControlServer.swift:365`), and
adding the `ControlActions` requirement breaks `ControlServer`'s conformance (no protocol extension
defaults). Enum case, value types, protocol requirement, mock, dispatcher routing, and app arm land together.

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlModes.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift`
- Modify: `agterm/Control/ControlServer.swift` (the fallback switch's case list)
- Modify: `agterm/Control/ControlServer+SessionActions.swift` (has headroom after Task 1)
- Modify: `agtermCore/Tests/agtermCoreTests/MockControlActions.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherTests.swift`

- [x] add `case sessionRestore = "session.restore"` to the `Command` enum, placed with the other
      session-scoped cases
- [x] add `ControlRestoreOverride` (`pin(String)` / `pinNone` / `unpin`) and `ControlSessionRestoreUpdate`
      (`pin`, `pane`, `paneID`) to `ControlModes.swift` alongside `ControlSessionStatusUpdate`, each with a
      doc comment; note in the enum's comment why `pinNone` is not spelled `none`
- [x] update the doc comments on `ControlArgs.command`, `.mode`, `.pane`, and `.paneID` — each enumerates the
      commands that consume it, and all four are now consumed by `session.restore` too
- [x] add `.sessionRestore` to the `dispatchSessionCommand` routing group and implement the arm: parse `mode`
      into `ControlRestoreOverride`, parse `pane` into `StatusPane`, pass `paneID` through untouched, build
      `ControlSessionRestoreUpdate`, call `actions.setSessionRestore`
- [x] implement the rejections from Technical Details (unknown mode; `set` with no command; control
      characters; over 1024 UTF-8 bytes via `command.utf8.count`; invalid pane), each with its own message
- [x] define the 1024 cap as a named constant with a comment, not a magic number
      (`ControlRestoreOverride.maxCommandBytes`)
- [x] add `.sessionRestore` to `ControlServer`'s dispatcher-fallback case list so that switch stays
      exhaustive (the dispatcher owns the command, so it lands in the "did not handle" group)
- [x] add `setSessionRestore(_:window:update:)` to the `ControlActions` protocol with a doc comment
- [x] add the `setSessionRestore` stub to `MockControlActions` following the file's existing recording style
- [x] implement the app-side arm with a doc comment matching the density of its neighbours
      (`setSessionStatus`, `setSessionFlag`): resolve the session via `resolver.resolveSession`
- [x] resolve the pane: `update.paneID.flatMap { session.paneRole(forToken:) }` first, then `update.pane`,
      defaulting to `.left`
- [x] reject an unresolvable `--pane-id` given WITHOUT an explicit `--pane` — unlike `session.status`, a
      silent `.left` fallback here would overwrite the wrong pane's persisted restore command. An EMPTY
      token counts as ABSENT (an older shell exporting no `AGTERM_PANE_ID`), taking the `--pane`/main path
- [x] reject a `.scratch` pane with a clear error (the scratch terminal is never restored)
- [x] reject `.right` when `!session.hasSplit`, gated like the focus helpers
- [x] map `ControlRestoreOverride` to the stored value (`pin(cmd)` → cmd, `pinNone` → `""`, `unpin` → nil) and
      call `store.setRestoreCommand(_:pane:forSession:)`
- [x] ➕ answer `ok: false` (`failed to save the restore override, the previous value is still in effect`)
      when that call reports the write did not land — an ack the disk never took would tell a hook its
      dangerous command is gone while the old line keeps firing
- [x] return `ok` with the session id, and when `restoreRunningCommand` is off include a note in
      `result.text` explaining the override will not fire until the setting is enabled (on `set`/`none`
      only — an `unpin` restores auto-capture, which the same setting already gates)
- [x] write `ControlProtocolTests` round-trips: the `session.restore` request encodes/decodes with each mode
      and with `command` / `pane` / `paneID` populated
- [x] write `ControlDispatcherTests` happy paths: each of the three modes reaches `setSessionRestore` with the
      expected update, and `pane` / `paneID` / `--window` / target pass through (plus a verbatim-shell-line
      case proving metacharacters are never rewritten)
- [x] write `ControlDispatcherTests` for every rejection, asserting `ok == false` and that the mock action was
      never called
- [x] write a boundary test on the byte cap: exactly 1024 UTF-8 bytes accepted, 1025 rejected, and a
      multi-byte string whose grapheme count is under the cap but whose byte count is over it IS rejected
- [x] do NOT add bare `Equatable`/memberwise-init tests for the two new value types — synthesized
      conformances are not worth pinning, and `ControlSessionStatusUpdate` is covered through the dispatcher
- [x] verify `ControlServer+SessionActions.swift` is still under 1000 lines and
      `ControlDispatcherTests.swift` under 2000 (1653 before) — 808 and 1791
- [x] no host-free unit tests for the app arm itself (app-target side effects); its inputs are covered by the
      dispatcher tests above and its behavior by Task 9's e2e
- [x] run `cd agtermCore && swift test` + `make build` + `make lint` - must pass before next task

### Task 7: Add the `tree` read-back fields

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift` (the `controlTree` builder)
- Modify: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStorePaneTests.swift`

- [x] add `restoreCommand` / `splitRestoreCommand` to `ControlSessionNode` as `public let … = nil`-defaulted
      init parameters, with doc comments naming them the read side of `session.restore`
- [x] populate both in the tree builder from the session's PERSISTED fields — never from the transient
      pending slots, so a read after the override fired still reports what is pinned
- [x] check `AppStore.swift` stays under 1000 lines after this task; if it would cross, stop and ask — 978
- [x] write `ControlProtocolTests` round-trips covering all three states per pane: a pinned command survives,
      `""` survives as an empty string (key present), and nil omits the key entirely
- [x] verify the omit-vs-empty behavior by asserting on the encoded JSON, not just the decoded value — the
      tri-state depends on it
- [x] write the `controlTree` populate test (`AppStorePaneTests`, alongside `controlTreeReportsSplitRatio`
      and friends) — mandated by `.claude/rules/control-api.md` for every read-back field. It must assert the
      value survives a `takePendingRestoreOverride`, which is what catches a builder reading the pending slot
- [x] run `cd agtermCore && swift test` - must pass before next task

### Task 8: Add the `agtermctl session restore` subcommand

**Files:**
- Modify: `agtermCore/Sources/agtermctlKit/SessionCommands.swift`
- Modify: `agtermCore/Sources/agtermctlKit/MiscCommands.swift` (help-text cross-reference only)
- Modify: `agtermCore/Tests/agtermctlKitTests/CommandsTests.swift`

- [x] add a `Restore` subcommand to the `Session` namespace, registered in its `subcommands:` list (it nests
      under `Session`, so it does not collide with the existing top-level `Restore` in `MiscCommands.swift`)
- [x] declare an optional positional `@Argument` for the command line plus `--none` / `--clear` flags, and
      `@OptionGroup` the existing `TargetOptions` (which supplies `--target`) and `ClientOptions`
- [x] declare its OWN `--pane` and `--pane-id` options following `Session.Status`
      (`SessionCommands.swift:358`) — there is no shared pane option group, and extracting one for two
      consumers is not worth it
- [x] implement `validate()`: exactly one of (positional command, `--none`, `--clear`) must be given, and
      reuse `validatePaneArgument(pane)`
- [x] implement `makeRequest()` emitting `.sessionRestore` with `mode` set to `set` / `none` / `clear` and
      `command` populated only for `set`
- [x] write help text stating the override is consumed on the NEXT launch, wins over the captured foreground,
      and is read back on `tree`
- [x] cross-reference the two restore verbs in BOTH help strings — `agtermctl restore clear` is app-global and
      capture-scoped, `agtermctl session restore --clear` is per-session and override-scoped; they are easy to
      confuse
- [x] write `CommandsTests` mapping cases: each of the three forms produces the expected `ControlRequest`;
      `--pane` / `--pane-id` / `--target` / `--window` are carried through
- [x] write `CommandsTests` validation cases: no argument at all, and two forms given together, both error
- [x] run `cd agtermCore && swift test` - must pass before next task

### Task 9: End-to-end tests *(app target)*

**Files:**
- Modify: `agtermUITests/RestoreCommandUITests.swift`
- Modify: `agtermUITests/ControlAPIUITests.swift`

- [x] add an e2e proving a pinned override re-runs ITS command and not the captured one: run a
      `tee <markerA>` foreground, pin an override that writes `<markerB>`, delete BOTH markers, quit,
      relaunch, then assert `<markerB>` exists and `<markerA>` does not (the deletes are what make the
      negative half meaningful — the harness already deletes before `gracefulQuit()`)
- [x] add the **two-relaunch stickiness e2e**: pin once, quit/relaunch (marker appears), delete the marker,
      quit/relaunch again WITHOUT re-pinning, assert the marker reappears. This is the only test that proves
      the override is not consumed off the persisted field.
- [x] add an e2e for `--none`: with a `tee <marker>` foreground captured, pin nothing, delete the marker,
      quit, relaunch, and assert the marker was NOT recreated (the baseline test proves it otherwise would be)
- [x] add an e2e for `--clear`: pin an override, clear it, quit, relaunch, and assert the CAPTURED command
      re-ran (auto-capture restored)
- [x] add an e2e proving the override does not fire with `restoreRunningCommand` off, reusing the existing
      settings-seeding helper (also asserts the response's "setting is off" note)
- [x] add a SPLIT-PANE e2e — the `makeSplitSurface` branch has its own restore logic and bypasses
      `restorePlan` entirely, and no other test reaches it. With a shown split, give the right pane a
      captured command writing one marker and pin a right-pane override writing another; after relaunch only
      the override's marker may appear, and the main pane must be unaffected
- [x] add a HIDDEN-SPLIT e2e (`testRestoreOverrideHiddenSplitDoesNotFireOnFreshSplit`): pin a right-pane
      override, hide the split, quit, relaunch, and assert `tree` reports NO `splitRestoreCommand` — the
      orphaned pin is dropped, not preserved. Then open a fresh split with ⌘D and assert it is a plain shell
      (the stale-fire case the `isSplit` seeding guard exists for). Then quit with that fresh split SHOWN
      and relaunch, asserting the dropped pin neither arms into the new pane nor reappears on `tree` — the
      ghost-fire sequence a preserved pin would have produced
- [x] add a FORCE-QUIT e2e: pin an override, `XCUIApplication.terminate()` (SIGKILL — no
      `applicationWillTerminate`, so no capture and no store flush), relaunch, and assert the override still
      fires. Immediate persistence in `setRestoreCommand` is a stated requirement and a clean quit cannot
      prove it, because the quit-flush would mask a missing `save()`
- [x] add `ControlAPIUITests` read-back assertions: after set / `--none` / `--clear`, `tree` reports the
      command, an empty string, and an omitted field respectively
- [x] add a promotion round-trip: with a split, exit the MAIN pane so the right pane is promoted, then pin
      via the survivor's `$AGTERM_PANE_ID` and assert `tree` reports it on `restoreCommand` (the main field),
      not `splitRestoreCommand` — the live-slot resolution that `--pane-id` exists for
- [x] add `ControlAPIUITests` error assertions: `--pane right` on a session with no split, a `--pane-id`
      resolving to the scratch, and an unresolvable `--pane-id` with no `--pane`
- [x] check `RestoreCommandUITests.swift` (265 before) and `ControlAPIUITests.swift` (**1548** before) stay
      under the 2000-line test budget; if `ControlAPIUITests` would cross, stop and ask — 496 and 1662
- [x] ➕ make the shared `runTeeMarker` helper RETRY its injection (the `typeUntilMarker` idiom): a
      full-class run exposed a dropped-keystroke failure — a slow launch under load leaves the shell not
      yet reading when the single injection fires, so the pane stays at its prompt and nothing is captured
- [x] run the XCUITest suite - must pass before next task (all 14 `RestoreCommandUITests` green as a full
      class, plus the 3 new `ControlAPIUITests` methods)

### Task 10: Verify acceptance criteria

- [x] verify all requirements from Overview are implemented: per-pane override, tri-state, sticky across
      restores, hook-drivable, opt-out, full read-back
- [x] verify the precedence table in Solution Overview matches actual behavior for all four rows
- [x] verify every row of the lifecycle table: bootstrap seeds, a mid-process window reload does NOT, Reopen
      Closed Item does NOT, a hidden split does not seed its right pane and drops its orphaned persisted pin
      on every rebuild path, promotion migrates both values,
      `closeSplit` clears both, soft-close/undo cannot fire, duplicate copies nothing, a second split in one
      launch does not re-fire, `restore.clear` leaves overrides alone, a `""` override suppresses
      `initialCommand`
- [x] grep the tree to confirm the surface factories read ONLY `pending*` and `setRestoreCommand` writes ONLY
      the persisted fields — the invariant the whole safety argument rests on
- [x] verify the control-API four-point audit is complete: `Command` case, dispatcher arm, `agtermctl`
      subcommand, round-trip + e2e tests — plus the `tree` read-back and its `controlTree` populate test
- [x] run the full unit suite: `cd agtermCore && swift test`
- [x] run the e2e suite (XCUITest) and `make build`
- [x] run `make lint` — zero findings, `--strict`
- [x] verify no source file exceeds 1000 lines and no test file exceeds 2000 (`wc -l` across changed files)
- [x] manual acceptance on an isolated dev instance: pin an override, ⌘Q, relaunch, confirm the pinned
      command ran and the captured one did not; then ⌘Q and relaunch again to confirm it fires a second time
      (covered by the task-9 e2e `testRestoreOverrideStaysPinnedAcrossTwoRelaunches` +
      `testRestoreOverrideBeatsCapturedCommand`, both green on the isolated `.debug` instance — the
      automated equivalent of the manual round trip)

### Task 11: [Final] Update documentation

All five keep-in-sync surfaces. **`CHANGELOG.md` is release-only — do not touch it.**

**Files:**
- Modify: `README.md`
- Modify: `site/docs.html`
- Modify: `site/commands.html`
- Modify: `agterm/Resources/agent-skill/SKILL.md`
- Modify: `agterm/Resources/agent-skill/reference.md`
- Modify: `agterm/Resources/agent-skill/examples.md`
- Modify: `agterm/Resources/agent-skill/troubleshooting.md`
- Modify: `.claude/rules/control-api.md`
- Modify: `CLAUDE.md` (only if a new pattern emerged — see the last checkbox)

- [x] update `README.md`: document `session.restore` in the restore-running-command section, covering the
      tri-state, the next-launch timing, and the hook-driven ownership tradeoff
- [x] bump the command count from 61 to 62 in all eight occurrences: `README.md` ×1, `site/docs.html` ×1,
      `site/commands.html` ×4 (meta description, og and twitter tags, page copy),
      `agterm/Resources/agent-skill/SKILL.md` ×1, and `.claude/rules/control-api.md` **×5** (the agent-skill
      description, the catalog heading, the "public command count stays 61" note, the skill-count note, and
      the site-copy note — grep, do not eyeball)
- [x] mirror the README change into `site/docs.html` (hand-authored mirror — both must agree)
- [x] add the `session.restore` entry to `site/commands.html`: invocation, arguments, and the
      `restoreCommand` / `splitRestoreCommand` read-back fields, matching the surrounding entry format
- [x] add the command to `agterm/Resources/agent-skill/reference.md` and the `SKILL.md` command summary
- [x] add an `examples.md` entry showing the payoff — a Claude Code `SessionStart` hook running
      `agtermctl session restore "claude --resume $CLAUDE_SESSION_ID" --target "$AGTERM_SESSION_ID"
      --pane-id "$AGTERM_PANE_ID"` (the selector is `--target`; there is no `--session`) — noting that
      write-once-and-forget pins a stale id, and that only safely-interpolated values (a UUID-shaped session
      id) belong in the command
- [x] document that the pinned value is SHELL CODE: it persists in `windows/<id>.json`, is readable via
      `tree`, may enter shell history when it runs, and must not carry secrets
- [x] add a `troubleshooting.md` entry for "my override didn't fire": the setting is off, the pane resolved to
      the scratch, it already fired this launch, the split was hidden at quit, reopening a closed session or
      reopening a closed window is not a launch restore, and the denylist is deliberately bypassed so it is
      never the cause
- [x] update `.claude/rules/control-api.md`: catalog entry, the four-point keep-in-sync audit, the read-back
      pairing list, and a note that the override bypasses the denylist but obeys the setting (use semantic
      line breaks — one sentence per line, per the project rule)
- [x] update `CLAUDE.md` if a genuinely new pattern emerged — at minimum the Task 1 split changed where
      app-global control arms live, which is worth a line (no change: the file split is a routine size-management
      move already covered by the existing "Manage file sizes" pattern, and neither `CLAUDE.md` nor
      `control-api.md` references where those app-global arms live, so there was no stale reference to fix)
- [x] verify docs match the shipped behavior by re-reading the implementation, not the plan
- [x] move this plan to `docs/plans/completed/` (plan move handled by orchestrator)

## Deviations from the original design

**A hidden split's persisted `splitRestoreCommand` is DROPPED at rebuild, not preserved.** The original
design kept it, on the reasoning that it would still read back on `tree` and still fire on a later launch
where the split is shown. The shipped implementation (`AppStore.session(from:)`, `AppStore.swift:969`)
drops it whenever `snapshot.isSplit != true`, mirroring the pane-gone rule `closeSplit` already applies.

Why the original reasoning was wrong:

- **It could never fire "on a later launch where the split is shown."** A split hidden at quit restores with
  `hasSplit == false` and is never rebuilt, so the only right pane that can exist afterwards is a FRESH ⌘D
  split — a different, unrelated shell.
- **Preserving it ghost-fires into that unrelated pane**: pin → hide split → quit → relaunch (pin preserved,
  nothing armed) → ⌘D opens a fresh split → quit with it shown → next launch seeds the preserved pin and
  types the dead pane's command into the new shell.
- **It would be unclearable.** `session.restore --pane right` is rejected when `!session.hasSplit`
  (`ControlServer+SessionActions.swift:445`), so `tree` would report a pinned value that no write can
  remove. Dropping restores the invariant `splitRestoreCommand != nil` implies `hasSplit == true`, which is
  what keeps every pinned value clearable via `--pane right --clear`.

The deviation was introduced by the review-round fixer commit `3b8ff4c` and confirmed correct by two
independent reviewers. It is pinned by `AppStoreRestoreSeedTests.bootstrapRestoreDropsAHiddenSplitsOverrideEntirely`
and `.rebuildDropsAHiddenSplitsOverrideOnEveryPath` (host-free) and by the e2e
`RestoreCommandUITests.testRestoreOverrideHiddenSplitDoesNotFireOnFreshSplit`, all of which assert
`splitRestoreCommand == nil` rather than the originally planned "still reports the pinned value".

## Post-Completion

*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Manual verification:**

- Drive a full round with a real Claude Code `SessionStart` hook: confirm the override tracks the live fork
  child across several agterm restarts, and that no duplicate claude sessions accumulate — the actual
  complaint in discussion #264.
- Verify a hook writing on every session start does not produce noticeable overhead (one socket round-trip
  per start).
- Confirm behavior with the deployed build after `make deploy`, since the deployed `/usr/local/bin/agtermctl`
  shadows the dev binary and hooks resolve it from PATH.

**External system updates:**

- Reply on discussion #264 once merged, confirming the shape that shipped and the tri-state semantics; the
  reporter offered to test builds.
- The installed agent-skill copies at `~/.claude/skills/agterm/` and `~/.codex/skills/agterm/` are install
  OUTPUTS regenerated by Help ▸ Install Agent Skill — never edit them; the user re-runs the installer to pick
  up the new command.

---

Smells pre-check: skipped — non-Go project
