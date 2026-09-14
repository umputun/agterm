# Event hooks: hooks.conf scripts fired on control events

## Overview

Today the only way to react to an agterm event is a running process polling `events.read` over the control
socket. This adds `hooks.conf`, a file beside `keymap.conf`, where each line binds a shell command to an
event kind. agterm runs the command detached when a matching event enters the control event ring, with the
event JSON on stdin and a small fixed `$AGT_*` environment. No process has to stay alive, the file survives
restarts, and reload/edit reuse the keymap UX.

Scope is deliberately small: seven event kinds, no filter grammar, no registration API, no kill timeout.
Two new ring kinds (`pane.split`, `pane.scratch`) and one new status payload field (`previous`) are shared
work that also improves `events.read`.

## Design decisions (fixed, from the design chat)

- **File**: `<config dir>/hooks.conf`, resolved like `keymap.conf`. Verb-first lines: `on <kind> <shell...>`.
  Blank and whole-line `#` lines ignored. The remainder after the kind is handed to `/bin/sh -c` untouched:
  no inline-comment stripping, no quote normalization, no `{AGT_*}` interpolation, no tilde or variable
  expansion at load time. Identity is `kind` + the remainder trimmed of outer whitespace only; the line
  number is display data and never part of identity.
- **Kinds**: `status`, `notify`, `session.created`, `session.closed`, `tree.changed`, `pane.split`,
  `pane.scratch`. Unknown kind, missing kind, or empty command is a `KeymapDiagnostic`-style line
  diagnostic; the line is skipped, later lines still parse. An identical kind+command line is skipped with a
  duplicate diagnostic (first wins), as keymap does for duplicate command names.
- **Fan-out**: several lines per kind are separate hooks with independent queues, children, counters and
  banners. No ordering between them.
- **Delivery**: stdin carries one encoded `ControlEvent` object, newline, EOF, same field schema as
  `events.read` items (key order not promised). Fixed env, every variable explicitly set and empty when
  the event lacks the field: `AGT_EVENT_KIND`, `AGT_EVENT_STATUS`, `AGT_SESSION_ID`, `AGT_WORKSPACE_ID`,
  `AGT_WINDOW_ID`, `AGT_SOCKET`. `PATH` widened as `CustomCommandRunner` does. Cwd is the app's, never a
  session's. No focused-session fallback.
- **Scheduling**: one child per hook at a time; ordered bounded queue of 256 pending events excluding the
  running one; overflow drops the oldest and increments a per-hook `dropped` counter; no retry; no timeout.
  Dispatch happens after the ring append so hooks and `events.read` see the same kind, payload, sequence and
  `tree.changed` coalescing. Only process exit releases a hook's slot.
- **Main-actor contract**: the main actor never waits for hook completion or stdin progress. JSON encoding
  and the pipe write run off the main actor on immutable event/env data, FIFO order preserved. Entry
  matching, queue bookkeeping and the launch call itself stay on the main actor; their cost is unmeasured
  and must not be described as negligible until measured.
- **Launch contract**: `launch` either throws, meaning no child was started and no callback will follow, or
  returns a pid, after which exactly one exit callback follows. Everything that can fail is prepared before
  `Process.run`: the pipe, `F_SETNOSIGPIPE` set and checked on the write end, and the cancellable I/O
  ownership. A delivery failure after a successful launch is reported as a fact on the live run and never
  releases the slot; an exit 0 from that same run does not erase it. Expected I/O cancellation during exit
  cleanup is not a failure. An immediate child exit racing the encoding job must not let that job create a
  writer afterwards.
- **Pipe lifecycle**: parent closes the read end after a successful spawn, both ends on spawn failure;
  partial writes handled; writer closed to deliver EOF; writer cancelled when the tracked child exits so a
  grandchild holding stdin cannot strand it. EPIPE is a silent success for delivery and never a banner; the
  child's exit status is judged separately (a script that closes stdin and exits 1 still failed). Other pipe
  setup/write errors are visible delivery failures.
- **Failures**: non-zero exit, spawn failure, or delivery failure posts a banner through `NotificationManager`
  with a `hook-failure:` identifier namespace (this path posts to `UNUserNotificationCenter` directly and
  records no `notify` ring event, so it cannot feed a hook). Banners come only from the scheduler's failure
  sink; the runner reports facts. One banner per hook until its next success or a reload; the last failure
  is kept and shown in `hooks list`.
- **Reload**: hook identity is kind + command text. Unchanged entries keep running/pending state, drop count
  and failure state, and take the new line number and file order. Reload re-arms the banner regardless of
  queue preservation. Removed or replaced entries accept no new events, drop their pending queue, and stay
  occupied until the running child exits; a re-add before that exit reattaches to the occupied record and
  waits, so the one-child bound survives remove/re-add. An old child's completion never starts an obsolete
  pending command.
- **Same-socket calls**: a hook may call `agtermctl --socket "$AGT_SOCKET"`. The control server handles one
  connection inline and blocks that thread on main-actor dispatch, so a hook's request queues behind the
  request that emitted its event. This is safe only because dispatch never waits on the hook; an integration
  test pins it.
- **Control API**: `hooks.reload` (returns diagnostic count, like `keymap.reload`) and `hooks.list` (path,
  diagnostics, per hook: kind, command, line, running pid, elapsed seconds, pending, dropped, last failure).
  App-global, no `--window`. The two `ControlActions` methods get unsupported defaults in
  `ControlActionsDefaults.swift` so outside conformers keep compiling.
- **UI**: File ▸ Reload Hooks, File ▸ Edit Hooks… (overlay editor, starter file with commented header on
  first use, reload on editor exit), palette entries, Settings buttons beside the keymap ones.
- **Deferred**: registration over the socket, filter grammar, kill timeout, cwd/pane on lifecycle payloads,
  named entries.

## Context (from discovery)

- Keymap parsing: `agtermCore/Sources/agtermCore/Keymap.swift` (`parseKeymap`, `KeymapDiagnostic`,
  duplicate-name skip at the `commandLines` guard). Paths and starter text: `ConfigPaths.swift`
  (`keymapPath`, `starterKeymapConf`). App loading and reload: `agterm/SettingsModel.swift`
  (`reloadKeymap`, `keymapURL`, `.agtermKeymapChanged`).
- Detached launch today: `agterm/Commands/CustomCommandRunner.swift` `spawn` (widened `PATH`, stdio to
  `/dev/null`, termination handler hops to main, `notifyCommandFailure`). Hooks reuse the launch shape, not
  the focus lookup, selection, usage recording, or the `command-failure:` banner namespace.
- Event ring: `agtermCore/Sources/agtermCore/ControlEvents.swift` (`ControlEventKind`, `ControlEventPayload`,
  `ControlEventRing.append` returns the sequenced event). Emission: `AppStore+Events.swift`,
  `AppStore+Status.swift` `setAgentIndicator` (captures `previous` already, emits only on indicator change),
  `WindowLibrary.swift` `controlEventSink` with the 100 ms `tree.changed` debounce.
- Pane state: `AppStore+Panes.swift` (`setSplitVisibility`, `closeSplit`, `closePrimaryPane`,
  `closeSplitPane` which delegates to `closeSplit`, `toggleScratch`, `closeScratch`).
- Control plumbing: `ControlProtocol.swift` (`enum Command`, `ControlResult`), `ControlDispatcher.swift`
  (987 lines; `keymapReload`/`keymapList` cases and the `ControlActions` protocol),
  `ControlActionsDefaults.swift` (unsupported defaults for outside conformers), app effects in
  `agterm/Control/ControlServer+AppCommands.swift`, CLI in `agtermCore/Sources/agtermctlKit/MiscCommands.swift`
  (`Keymap` command), human event text in `EventCommands.swift` `EventFormatter.human`.
- Menus/actions: `agterm/agtermApp+Menus.swift`, `agterm/AppActions.swift` (`reloadKeymap`, `editKeymap`
  marks `keymapEditOverlaySession`), `agterm/AppActions+Palette.swift` (execution switch),
  `agterm/Views/WindowContentView.swift` `handleClosedEditorOverlays` (reload on overlay close),
  `agterm/Views/SettingsView.swift` keymap Reload button, `PaletteCatalog.swift` (`PaletteCommand`).
- Tests: `agtermCore/Tests/agtermCoreTests` (`KeymapTests`, `ControlEventRingTests`,
  `AppStoreEventTests`, `ControlDispatcherTests`, `ControlEventProtocolTests`, `PaletteCatalogTests`),
  `agtermCore/Tests/agtermctlKitTests` (`EventCommandsTests`, `CommandsTests`), hosted `agtermTests`
  via `xcodebuild` (`scripts/test-app.sh` forwards no arguments), `agtermUITests/ControlAPIUITests.swift`
  (`testKeymapReload…` siblings).
- Docs surfaces: `site/docs.html` (`#keymap`, `#events`; canonical user guide), `site/commands.html`
  (canonical command reference), `plugins/agterm/skills/agterm/` (`SKILL.md`, `reference.md`),
  `.claude/rules/control-api.md`, `.claude/rules/keymap.md`, `ARCHITECTURE.md`. No surface states a command
  count.

## Development Approach

- **testing approach**: TDD. Parser, scheduler and protocol shaping are host-free logic in `agtermCore`;
  write the failing test first, then the code.
- complete each task fully before moving to the next; small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task, success and error
  paths, as separate checklist items
- **CRITICAL: the tests a task touches must pass before starting the next task**; the full gates run once,
  in Task 9
- targeted runs: host-free `cd agtermCore && swift test --filter <Class>`; hosted
  `xcodebuild test -project agterm.xcodeproj -scheme agtermTests -destination 'platform=macOS'
  -derivedDataPath build/DerivedData -only-testing:agtermTests/<Class>` (after `scripts/setup.sh` and
  `xcodegen generate` once); UI `-only-testing:agtermUITests/ControlAPIUITests/<method>`
- **CRITICAL: update this plan file when scope changes during implementation**
- `agtermCore` stays free of AppKit/Foundation `Process`; the process runner lives in the app target and
  reaches the scheduler through a protocol defined in `agtermCore`
- `agtermCore` is consumed by the `agterm-linux` fork: new `public` symbols are fine, never narrow existing
  ones, and new `ControlActions` requirements get defaults
- new wire structs and dispatch helpers go in their own files/extensions; do not grow `ControlDispatcher.swift`
  toward the 1000-line limit
- comments: only non-obvious constraints; no narration, nothing temporal

## Testing Strategy

- **unit tests**: `agtermCore` for parser, scheduler, protocol/CLI shaping, event emission, formatter
- **hosted tests** (`agtermTests`): the process runner with a real `/bin/sh` child: large payload with early
  stdin close, EOF delivery, exit 0/1 with EPIPE, spawn failure, delivery error while the child is alive,
  cancellation on exit, immediate-exit race; Edit Hooks starter creation and preservation
- **UI/e2e tests** (`agtermUITests/ControlAPIUITests`): `hooks reload`/`hooks list` round trips against an
  isolated instance, the same-socket integration case, Edit Hooks opening the editor and reloading on exit.
  Run only the new methods via `-only-testing:`.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope

## Solution Overview

Three layers, each owned once:

1. **`agtermCore`**: `Hooks` model and `parseHooksConf`; wire read-back structs in `ControlHooks.swift`;
   `HookScheduler` (queues, identity, reload diff, counters, last failure, banner suppression state)
   driving an injected `HookLauncher` protocol; the two new event kinds, `previous`, and their emission sites.
2. **App target**: `HookProcessRunner` implements `HookLauncher` with `Process` and the stdin pipe;
   `SettingsModel` loads and reloads `hooks.conf`; the ring append feeds the scheduler; the scheduler's
   failure sink posts the banner; menu/palette/settings wiring; `ControlActions` effects.
3. **CLI and docs**: `agtermctl hooks reload|list`, human formatter, docs, skill, rules.

## Technical Details

Config parsing (`agtermCore/Sources/agtermCore/Hooks.swift`):

```swift
public struct HookIdentity: Hashable, Sendable { public let kind: ControlEventKind; public let command: String }
public struct HookEntry: Equatable, Sendable {
    public let identity: HookIdentity
    public let line: Int              // display only, never part of identity
}
public struct Hooks: Equatable, Sendable { public let entries: [HookEntry] }   // file order
public func parseHooksConf(_ text: String) -> (hooks: Hooks, diagnostics: [KeymapDiagnostic])
```

Read-back (`agtermCore/Sources/agtermCore/ControlHooks.swift`, created in Task 3, routed in Task 4):

```swift
public struct ControlHooks: Codable, Sendable, Equatable {
    public let path: String
    public let diagnostics: [ControlKeymapDiagnostic]   // reuse the keymap diagnostic wire shape
    public let hooks: [ControlHookEntry]
}
public struct ControlHookEntry: Codable, Sendable, Equatable {
    public let kind: String; public let command: String; public let line: Int
    public let runningPid: Int32?; public let elapsedSeconds: Double?
    public let pending: Int; public let dropped: UInt64; public let lastFailure: String?
}
```

Scheduler (`agtermCore/Sources/agtermCore/HookScheduler.swift`), `@MainActor`, host-free:

```swift
@MainActor public protocol HookLauncher: AnyObject {
    /// Throws when no child started (no callbacks follow). On return exactly one `onExit` follows, after
    /// input cleanup and any delivery-failure report. Neither callback runs inline from `launch`.
    func launch(entry: HookEntry, event: ControlEvent,
                onDeliveryFailure: @escaping @MainActor @Sendable (String) -> Void,
                onExit: @escaping @MainActor @Sendable (Int32) -> Void) throws -> Int32
}

@MainActor public final class HookScheduler {
    public static let pendingCapacity = 256
    public init(launcher: HookLauncher, now: @escaping () -> Date = Date.init)
    public func apply(_ hooks: Hooks)                 // reload diff: keep, retire, reattach, re-arm banners
    public func dispatch(_ event: ControlEvent)       // fan out to matching entries
    public var status: [ControlHookEntry]             // file order; elapsed from the injected clock
    public var onFailure: ((HookEntry, String) -> Void)?   // sole banner source, suppressed per hook until success/reload
}
```

Per-record state: `entry`, `running: (pid: Int32, startedAt: Date, run: UInt64, deliveryFailed: Bool)?`,
`pending: [ControlEvent]` (FIFO, cap 256), `dropped: UInt64`, `lastFailure: String?`, `bannerShown: Bool`,
`retired: Bool`. `deliveryFailed` is what lets a clean exit clear an older run's `lastFailure` while keeping
this run's. The run token survives retirement and reattachment: on remove K, re-add K, enqueue E, the
original child's exit releases K and starts E. A callback is stale only when its token differs from the
record's current running token, and a stale callback changes nothing.

Runner (`agterm/Commands/HookProcessRunner.swift`, app target): `init(socketProvider:executableURL:)`
(executable defaults to `/bin/sh`, injectable for spawn-failure tests). Before `run()`: create the `Pipe`,
`fcntl(writeFD, F_SETNOSIGPIPE, 1)` checked, create the `DispatchIO` channel owning the write end. Then
`Process("/bin/sh", ["-c", command])`, env = app env overlaid with the six variables (always set), widened
`PATH`, cwd unset (app's), stdout/stderr to `/dev/null`, stdin from the pipe; on `run()` failure close both
ends, release the channel, throw. After a successful `run()`: close the read end in the parent, encode the
event on a utility queue and write through the channel handling partial writes, close for EOF. An encoding or
write error that is neither EPIPE nor cancellation calls `onDeliveryFailure` on main when it occurs, while
the child is alive; it is never held for the termination handler. The termination handler cancels the channel
(cancelling a not-yet-created writer is handled by a per-launch state flag so the encoding job never creates
one afterwards), waits only for that asynchronous cleanup and any in-flight failure report to order before
it, hops to main, and calls `onExit(status)` exactly once. The write descriptor has one cleanup owner: the
`DispatchIO` channel closes it through its cleanup handler, and `Pipe.fileHandleForWriting` never closes it
independently; on spawn failure the read end is closed directly and the channel is closed to release the
write end.

Protocol (`ControlProtocol.swift`): `Command.hooksReload = "hooks.reload"`, `.hooksList = "hooks.list"`;
`ControlResult.hooks: ControlHooks?`. Dispatcher cases live in a new `ControlDispatcher+Hooks.swift`
extension.

Events: `ControlEventKind.paneSplit = "pane.split"`, `.paneScratch = "pane.scratch"`, payload `status`
carries `shown`/`hidden` and `session` the owner. `ControlEventPayload.previous: String?` set only on
`status` events, from the captured indicator's status raw value, emission gate unchanged (shape/pane-only
changes may emit `previous == status`).

Starter file (`ConfigPaths.starterHooksConf`): the commented header from the design (verb, kinds, env,
one-process-per-line note, stdin JSON note) followed by commented example lines. Every line a comment.

## Implementation Steps

### Task 1: New event kinds and `previous` on status

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlEvents.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+Status.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+Panes.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+Events.swift`
- Modify: `agtermCore/Sources/agtermctlKit/EventCommands.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreEventTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlEventProtocolTests.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/EventCommandsTests.swift`

- [x] write failing tests: `status` event carries `previous` equal to the prior status; a shape-only change
      emits `previous == status`; a refused write emits nothing
- [x] write failing tests: `pane.split` emits `shown`/`hidden` from `setSplitVisibility`, `closeSplit`,
      `closePrimaryPane`; `closeSplitPane` emits exactly once; nothing for an axis change while shown, a
      repeated set-to-shown, or teardown/promotion of an already hidden split
- [x] write failing tests: `pane.scratch` emits from `toggleScratch` and `closeScratch`; nothing on
      `closeScratch` with no surface or on a scratch shell exit while already hidden
- [x] write failing tests: `ControlEventKind` round-trips the two new raw values; `events.read --kind`
      validation accepts them; `EventFormatter.human` renders both kinds and `previous`
- [x] add the kinds and `previous`, emit at the state setters (one emission helper per pane kind in
      `AppStore+Events.swift`, gated on the actual transition), extend the formatter
- [x] run the changed test classes only; must pass before task 2

### Task 2: `hooks.conf` model, parser, paths, starter text

**Files:**
- Create: `agtermCore/Sources/agtermCore/Hooks.swift`
- Create: `agtermCore/Tests/agtermCoreTests/HooksTests.swift`
- Modify: `agtermCore/Sources/agtermCore/ConfigPaths.swift`
- Modify: the test file that pins `ConfigPaths.keymapPath`

- [x] write failing parser tests: valid lines for every kind; multiple lines per kind kept in file order;
      blank and whole-line `#` ignored; CRLF; spacing variants between `on` and kind give one identity;
      identity ignores the line number
- [x] write failing parser tests for the shell remainder preserved verbatim: quoted `#`, escaped quotes,
      pipes, redirection, `$(...)`, tilde, `$VAR`; only outer whitespace trimmed
- [x] write failing diagnostic tests: unknown verb, unknown kind, missing kind, empty command, identical
      kind+command duplicate skipped with first kept; later lines still parse; line numbers correct
- [x] write failing tests: `ConfigPaths.hooksPath` is `<config dir>/hooks.conf`; `starterHooksConf` has
      only comment/blank lines and parses to zero entries and zero diagnostics
- [x] implement `HookIdentity`, `HookEntry`, `Hooks`, `parseHooksConf`, `hooksPath`, `starterHooksConf`
- [x] run `HooksTests` and the paths tests; must pass before task 3

### Task 3: Hook scheduler and read-back types (host-free)

**Files:**
- Create: `agtermCore/Sources/agtermCore/ControlHooks.swift`
- Create: `agtermCore/Sources/agtermCore/HookScheduler.swift`
- Create: `agtermCore/Tests/agtermCoreTests/HookSchedulerTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlEventProtocolTests.swift` (wire round-trip of the new structs)

- [x] write failing tests: `ControlHooks`/`ControlHookEntry` encode/decode with nil omission for
      `runningPid`, `elapsedSeconds`, `lastFailure`
- [x] write failing tests with a fake `HookLauncher`: an event fans out to every matching entry; each entry
      has an independent queue and running child; a non-matching kind launches nothing; callbacks are never
      invoked inline from `launch`
- [x] write failing tests: FIFO order across a burst; second event waits for the first child; cap 256
      pending excluding the running one; overflow drops the oldest and increments `dropped`
- [x] write failing tests: `launch` throwing advances the queue, records `lastFailure`, calls `onFailure`;
      a delivery failure on a live run records one failure, calls `onFailure` once, shows in `status` before
      exit and across a reload, leaves the next event pending until `onExit`, and survives that run's exit 0
      without being erased; exit 0 on a later run clears `lastFailure` and re-arms the banner; exit non-zero
      calls `onFailure` once until success or reload
- [x] write failing reload tests: `apply` after inserting comments and reordering definitions keeps the same
      child, pending queue, drop count and failure state while updating line numbers and file order; reload
      re-arms the banner independently of queue preservation
- [x] write failing retire tests: a removed entry drops pending, accepts no events, stays occupied until its
      child exits, and that exit starts nothing; a changed command is a new identity running alongside the
      retired one
- [x] write failing reattach tests: re-add before exit reattaches and waits, and the original child's exit
      then starts exactly the first newly queued event; an injected older run token cannot release the new
      child
- [x] write failing tests: `status` reports pid, elapsed from the injected clock, pending, dropped, last
      failure per entry, in file order
- [x] implement `ControlHooks`, `ControlHookEntry`, `HookScheduler`, `HookLauncher`
- [x] run `HookSchedulerTests` and the protocol tests; must pass before task 4

### Task 4: Control protocol, dispatcher and CLI for `hooks.reload` / `hooks.list`

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift` (`Command` cases, `ControlResult.hooks`)
- Create: `agtermCore/Sources/agtermCore/ControlDispatcher+Hooks.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift` (two protocol requirements with one-line
  godoc each and one routing case; the file is at 987 of the 1000-line limit and protocol requirements cannot
  live in an extension, so the budget is about ten lines. If lint reports the limit, ask before splitting
  the file per CLAUDE.md; do not raise the limit)
- Modify: `agtermCore/Sources/agtermCore/ControlActionsDefaults.swift` (unsupported defaults)
- Modify: `agtermCore/Sources/agtermctlKit/MiscCommands.swift`
- Modify: `agtermCore/Sources/agtermctlKit/Commands.swift` (subcommand registration)
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlEventProtocolTests.swift` (`Command` and `ControlResult` round trips)
- Modify: `agtermCore/Tests/agtermctlKitTests/CommandsTests.swift`

- [x] write failing tests: `Command` round-trips the two raw values; `ControlResult.hooks` encodes with nil
      omission
- [x] write failing dispatcher tests: both commands reach `ControlActions.reloadHooks()` / `listHooks()`,
      reject a target and `--window`, never fall through to the nil switch; a conformer relying on the
      defaults gets the unsupported error
- [x] write failing CLI tests: `agtermctl hooks reload` and `hooks list` build the right requests; `list`
      prints a human table (kind, command, running, pending, dropped, last failure) and `--json` passes the
      result through; error text on a failed response
- [x] implement the `Command` cases, `ControlResult.hooks`, the dispatcher extension, `ControlActions`
      requirements with defaults, CLI subcommands
- [x] run the changed test classes; must pass before task 5

### Task 5: Process runner in the app target

**Files:**
- Create: `agterm/Commands/HookProcessRunner.swift`
- Create: `agtermTests/HookProcessRunnerTests.swift`
- Modify: `agterm/Notifications/NotificationManager.swift` (`notifyHookFailure` with `hook-failure:` ids)

- [x] write failing hosted tests with a real `/bin/sh` child: env has all six variables set, empty ones
      included, and `PATH` widened; cwd is the app's; stdin receives one JSON object plus newline then EOF
      that decodes as the `ControlEvent`; `onExit` fires exactly once and not inline
- [x] write failing hosted tests: a payload larger than pipe capacity with a script that closes stdin
      immediately reports no delivery failure and `onExit(0)`; the same script exiting 1 reports `onExit(1)`;
      an injected nonexistent executable makes `launch` throw with no callbacks
- [x] write failing hosted tests: a deterministic delivery failure while the child is alive (a throwing
      encoder; DispatchIO's own write-error path is not exercised, since the SDK forbids touching a
      descriptor the channel owns) reports `onDeliveryFailure` while the child is still running and before
      `onExit`; the write descriptor is closed before `onExit` on the success path and both ends are closed
      on the spawn-failure path; a child that exits before the encoding job runs completes without
      a writer being created; cancellation on exit is not reported as a failure; a grandchild holding stdin
      does not keep the writer alive past the child's exit
- [x] write failing tests in `HookProcessRunnerTests.swift`: the `hook-failure:<kind>:<command>` identifier
      builder (the `bannersEnabled` guard is not observable without a notification-center seam and is not
      tested)
- [x] implement `HookProcessRunner: HookLauncher` per Technical Details and the banner method
- [x] run `-only-testing:agtermTests/HookProcessRunnerTests` via the direct `xcodebuild` recipe; must pass
      before task 6

### Task 6: Wire loading, reload, dispatch and control effects in the app

**Files:**
- Modify: `agterm/SettingsModel.swift` (`hooks`, `hooksDiagnostics`, `hooksPath`, `reloadHooks`)
- Modify: `agtermCore/Sources/agtermCore/WindowLibrary.swift` (post-append observer closure)
- Modify: `agterm/AppDelegate.swift` or `agterm/agtermApp.swift` (own the scheduler + runner, wire the
  failure sink to `notifyHookFailure`, subscribe)
- Modify: `agterm/Control/ControlServer+AppCommands.swift` (`reloadHooks`, `listHooks`)
- Modify: `agtermCore/Tests/agtermCoreTests/ControlEventRingTests.swift` (or `WindowLibrary` tests)
- Modify: `agtermUITests/ControlAPIUITests.swift`

- [ ] write failing test: `WindowLibrary` invokes an `onControlEvent` observer with the sequenced event
      after each ring append, including debounced `tree.changed`, never during bootstrap
- [ ] write failing UI tests beside `testKeymapReload…`: `hooks reload` returns the diagnostic count for a
      clean and for a broken isolated `hooks.conf`; `hooks list` reports path, diagnostics and entries
- [ ] write failing UI integration test with a finite fixture: a `hooks.conf` line on `status` that exits
      unless the event names session A, then runs `agtermctl notify --socket "$AGT_SOCKET"`; drive
      `session status --target A blocked`; assert the response returns, the notify ring event appears, and
      `hooks list` reaches no running and no pending work within a deadline
- [ ] implement: SettingsModel loads `hooks.conf` on start and `reloadHooks` posts `.agtermHooksChanged`;
      scheduler `apply` on load/reload; observer feeds `dispatch`; control effects mirror the keymap ones
- [ ] run the new UI methods only with `-only-testing:`; must pass before task 7

### Task 7: Menu, palette and Settings actions

**Files:**
- Modify: `agtermCore/Sources/agtermCore/PaletteCatalog.swift` (`reloadHooks`, `editHooks`)
- Modify: `agterm/AppActions.swift` (`reloadHooks`, `editHooks`, `hooksEditOverlaySession`)
- Modify: `agterm/AppActions+Palette.swift` (execution switch cases)
- Modify: `agterm/Views/WindowContentView.swift` (`handleClosedEditorOverlays` reloads hooks on close)
- Modify: `agterm/agtermApp+Menus.swift`
- Modify: `agterm/Views/SettingsView.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/PaletteCatalogTests.swift`
- Create: `agtermTests/HooksEditTests.swift` (starter-file cases; no hosted keymap-edit test file exists)
- Modify: `agtermUITests/ControlAPIUITests.swift`

- [ ] write failing tests: the two palette commands exist with titles, are keyless, and have the same
      enablement as their keymap counterparts
- [ ] write failing hosted tests: `editHooks` writes the starter file when `hooks.conf` is missing and
      preserves an existing file byte for byte
- [ ] write failing UI test: Edit Hooks opens the overlay editor on the file; closing it reloads hooks
      (observed through `hooks list` reflecting an edit made by the test)
- [ ] implement File menu items, palette entries and execution, Settings Reload/Edit buttons beside the
      keymap ones, overlay-close routing
- [ ] run the palette, hosted and UI cases only; must pass before task 8

### Task 8: Documentation and synchronized surfaces

**Files:**
- Modify: `site/docs.html` (new `#hooks` section after `#keymap`, the canonical user contract: file format
  with the design's example lines, kinds, stdin/env contract, queue policy, failures, reload semantics,
  same-socket note with `--socket "$AGT_SOCKET"`, a note that the log example needs its directory created,
  and a self-feeding loop warning: hooks can trigger themselves when their commands emit another event of
  the subscribed kind; the queue bounds concurrency, it does not detect feedback loops)
- Modify: `site/commands.html` (`hooks reload`, `hooks list` with read-back fields; `events read` gains the
  two kinds and `previous`)
- Modify: `plugins/agterm/skills/agterm/SKILL.md`, `reference.md`
- Modify: `site/index.html` (feature mention beside the keymap one) and `site/llms.txt` (discovery index
  entry), both of which already name `keymap.conf`
- Modify: `.claude/rules/control-api.md` (implementation constraints: launch contract, slot release only on
  exit, reload identity, banner source; points at `site/docs.html#hooks` for the user contract)
- Modify: `.claude/rules/keymap.md` (pointer: `hooks.conf` shares paths and diagnostics, not the parser)
- Modify: `ARCHITECTURE.md` (scheduler/runner split and the main-actor contract)

- [ ] write the user-facing contract once in `site/docs.html#hooks`; commands page covers CLI and read-back
- [ ] update the skill reference and commands page; no surface states a command count
- [ ] update the two rules files with implementation constraints only, cross-referencing the docs page
- [ ] update `ARCHITECTURE.md`

### Task 9: Verify acceptance criteria
- [ ] verify every fixed decision above is implemented and none of the deferred items crept in
- [ ] verify the acceptance cases: queue order and drop count, early stdin close above pipe capacity, EOF,
      launch throw advancing the queue, delivery failure on a live run not releasing the slot, duplicate
      lines, reload after reorder/comments, remove/re-add with a live child, stale exit ignored, EPIPE with
      exit 0 and exit 1, immediate-exit race, fan-out independence, pane emission edges, `previous` on status,
      same-socket integration, Edit Hooks starter/preserve/reload; the docs page carries the self-feeding
      loop warning
- [ ] run full gates once: `cd agtermCore && swift test`, `make test-app`, `make lint`

### Task 10: [Final] Update documentation
- [ ] re-read `README.md`; the synopsis mentions hooks only if the control-API demo changes
- [ ] update `CLAUDE.md` working notes if the runner/scheduler split adds a constraint worth keeping
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification**: in an isolated Debug instance with a `hooks.conf` of the four example lines, drive
`session status`, split/scratch toggles and session create/close through `agtermctl --socket`, and confirm
`hooks list` counters, the failure banner once per hook, and that the live terminal stays responsive under a
deliberately hung hook script.

**Release**: `CHANGELOG.md` is release-only; the feature PR touches product, skill and engineering docs.

Smells pre-check: skipped — non-Go project
