# Launch spawn pacing

## Overview

A launch that replays captured commands spawns every pane's program at the same instant. With 83 panes
whose captured commands replay, every `claude`/`codex`/`pi` the user had running boots together; each
Claude Code startup alone forks a full-table `ps aux` plus two targeted `ps`, and N bun runtimes booting
concurrently pin the CPU for seconds. This is not one-time and not live-only: rerun mode replays every
captured command on every launch, and live mode does so on the first launch after a rerun quit and on
every launch after a reboot, because a clean quit captures every pane and the reboot kills every daemon.

The fix paces the spawn, not the replay. Every pane's host view and `Session` wiring stay eager exactly
as today; only the moment `ghostty_surface_new` runs is rate-limited, app-wide, with the on-screen panes
of every window and any pane a user or control command reaches spawning at once. Replay semantics,
capture semantics, `restore.clear`, and the deck's constant shape are unchanged.

## Context (from discovery)

- `agterm/Views/WindowContentView+Detail.swift:29` mounts EVERY session's detail in one `ZStack`; switching
  is a visibility flip, so all panes realize at launch by design. Constant-shape rule at `:41-50`.
- `agterm/Views/TerminalView.swift:46-68`: `makeNSView` calls the factory and `updateNSView` calls
  `createSurface()` synchronously ("a deferred next-tick create races the layout").
- `agterm/Ghostty/GhosttySurfaceView.swift:569`: `createSurface()` is the single choke point behind four
  entry paths (`TerminalView.updateNSView`, `viewDidMoveToWindow` at `:857`, the `setFrameSize` retry via
  `pendingSurfaceCreation` at `:876`, the 1 s retry at `:369`). It already defers itself on a zero size.
  `deinit` is nonisolated and cannot call main-actor methods (`:162-165`).
- `agterm/agtermApp.swift:294` and `:500`: the factories take `session.takePendingForegroundCommand` and
  `takePendingRestoreOverride` at CONSTRUCTION, for `.wrapped` inside `ZmxLaunch.surfaceSeed` and for
  `.ordinary` through `CommandRestore.restorePlan`, and bake the result into immutable `view.command` /
  `view.initialInput`. `RestoredRuntime` (`:230`) already carries the library, resolver and zmx client.
- `agterm/Control/ControlServer.swift:512-526` `clearRestoreCommands`: disarms the PENDING slots because the
  socket binds before later windows' decks mount; a clear in that gap must stop the command from running.
  Pacing widens that gap from milliseconds to seconds.
- `agterm/AppDelegate.swift:368` `captureForegroundCommands(preserveUnconsumedPending:)`: a clean quit keeps
  an UNCONSUMED pending seed; an on-demand `restore.capture` must never persist an armed copy.
- `agterm/Control/ControlServer+Zmx.swift:155` `applyKilledPaneExit` needs the wrapper (`surface as?
  GhosttySurfaceView`, `backedByZmx`, `claimProcessExit()`); `backedByZmx` is set in `init` (`:340`) and
  `claimProcessExit` is a pure latch, so an eager unspawned wrapper satisfies it.
- `agterm/Ghostty/ZmxClient.swift:42` `reap` runs one synchronous `zmx list`, parses it, and returns a
  bare `Bool`, discarding the observed session set.
- `agtermCore/Sources/agtermCore/WindowLibrary.swift:141` `prepareLaunchPaneInventory()` claims/reaps
  before SwiftUI mounts and never reads `session.surface`; pacing cannot change which daemons are claimed.
- A restored HIDDEN split keeps its identity and pin with no right host until shown
  (`.claude/rules/control-api.md`, Restore commands). `session.type` on an unrealized main pane
  bounded-polls 12 x 30 ms; `session.text` never selects or realizes; `session.search` "selects and
  realizes the target".
- `ControlSessionNode.realized` already reports an unspawned main pane as `false`.

Measured on the user's machine (1420 processes): targeted `ps -p` 4.1 ms, `ps -axww` 76 ms, one Claude
Code startup issues 3 `ps` of which one is full-table; 69 sessions, 14 split, 83 panes, 166 zmx processes.

## Development Approach

- **testing approach**: TDD - write the task's tests first against the injected clock and spawn
  recorder, watch them fail, then implement
- complete each task fully before moving to the next; small focused changes
- **CRITICAL: every task includes new/updated tests** as separate checklist items; success and error paths
- **CRITICAL: all tests pass before the next task**: `cd agtermCore && swift test`, `make test-app`, `make lint`
- run each full gate ONCE at the end; scope in-task runs with `--filter` / `-only-testing:`
- **CRITICAL: update this plan when scope changes**
- no user-facing setting: pacing constants are code; a preference needs separate approval
- `agtermCore` is a published library consumed by agterm-linux: no public signature changes there beyond
  the new `SpawnPacer` type; `ControlActions` signatures stay synchronous

## Testing Strategy

- **unit tests**: host-free scheduler model in `agtermCore` (`swift test`); hosted `GhosttySurfaceView`,
  factory, capture and launch behavior in `agtermTests` (`make test-app`), following
  `GhosttySurfaceViewTrackingTests` and `AppDelegateCaptureTests` structure
- **e2e**: no XCUITest additions; `ControlAPIUITests` is not re-run for this change
- one test file per source file; Swift Testing in `agtermCore`, XCTest in `agtermTests`
- every timing assertion uses an injected clock and a spawn recorder; nothing sleeps
- **required regressions** (each lives in the task that makes it pass):
  N replaying panes record N spawns each `interval` apart and go red when the gate is deleted; a late
  wake releases one grant, not several; expedite consumes a token and resets the deadline; repeated
  selection of one pane expedites once; zero-size retry consumes no token; every `createSurface` entry
  path reaches the gate; deinit/cancel leaves no stale callback; rerun unspawned clean quit preserves the
  capture; live unspawned clean quit preserves the capture; `restore.clear` before permit prevents the
  command from running; on-demand `restore.capture` persists no armed copy; `zmx kill` before permit
  performs the model transition and the later grant cannot recreate the daemon; a hidden split does not
  block drain; live survivor unpaced, missing and unknown paced, nil observed set paces all; rerun replay
  paced; `session.text`/`session.copy`/`surface.cursor` do not realize; `session.type` left and right and
  `session.search` do; synchronous mutators follow the expedite contract; dashboard promotion preserves
  rate; claim and reap run before any grant; a plain restored shell, a pin-none pane and a
  denylist-refused capture spawn unpaced; an `err=` list row is paced, not treated as a survivor; a view
  destroyed before its provider resolves deallocates; the `restore.clear` case uses a capture-only session;
  arm emits nothing until a key requests; late-mounting views still spawn `interval` apart from actual
  grants; a live pin-only pane is unpaced and keeps its pin pending
- **owners** (verified in Task 6): Task 1 `SpawnPacerTests` - late wake, expedite resets the deadline, arm emits
  nothing, an expected key that has not requested holds the timer. Task 2 `LaunchSeedTests` - rerun replay
  paced, live survivor unpaced with missing/unknown/nil paced, plain shell/pin-none/denied capture unpaced,
  live pin-only pane unpaced; `AppDelegateCaptureTests` - rerun and live unspawned clean quit keep the
  capture, on-demand capture persists no armed copy; `ControlServerRestoreCaptureTests` - `restore.clear`
  before the permit on a capture-only session; `GhosttySurfaceViewTrackingTests` - a view destroyed before
  resolution deallocates. Task 3 `GhosttySurfaceViewTrackingTests` - every entry path reaches the gate (red
  when the gate is deleted), zero-size retry holds no token, teardown and deinit leave no stale callback.
  Task 4 `GhosttySurfaceViewTrackingTests` - repeated selection expedites once; `ControlServerSessionActionsTests`
  - reads never realize, `session.type` left and right and `session.search` do, mutators expedite;
  `ControlServerZmxTests` - `zmx kill` before the permit; `DashboardViewTests` - promotion keeps the rate.
  Task 5 `SpawnRegistryTests` - N panes `interval` apart after the burst; `LaunchSpawnPlanTests` and
  `SurfaceFactorySeedTests` - a hidden split is never armed; `ZmxClientTests` - an `err=` row is not a
  survivor; `SpawnPacerTests` - a window mounting after the first drained spaces its follower. Claim and
  reap before any grant has no unit test: the sink runs inside `WindowLibrary.init` and arm follows it in
  `agtermApp.init`, verified by reading.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix; blockers with ⚠️ prefix
- keep this plan in sync with actual work

## Solution Overview

"Eager host, paced spawn, late seed." Nothing before `createSurface()` changes: bootstrap, claim, reap,
factory and view mounting run as today, so the launch inventory, `zmx kill`, `session.swap` and split
controls see exactly the objects they see now. Two things move later, both to the instant immediately
before `ghostty_surface_new`:

1. **The permit.** `createSurface()` asks an app-global `SpawnPacer` for a grant after its existing
   app/nonzero-size guards. Denied means the view records itself as awaiting and returns; the pacer later
   grants and the same idempotent `createSurface()` runs against then-current bounds, so the "synchronous
   on purpose" site keeps its guarantee: the deferral is the pacer's, not a next-tick hop racing layout.
   Gating the sink covers all four entry paths and stops a zero-size view from holding a permit into a
   later same-layout burst.
2. **The seed.** The factories no longer take the pending slots at construction. Each view carries a
   `LaunchSeedProvider` closure that consumes `pendingForegroundCommand`, `pendingRestoreOverride` and
   the restore-plan precedence atomically when the permit is granted. Until then the slots stay on the
   `Session`, so a clean quit before the permit preserves them through today's
   `preserveUnconsumedPending`, `restore.clear` disarms them exactly as it does in the pre-mount gap,
   and an on-demand `restore.capture` finds nothing armed on the view. This covers primary and split,
   `.ordinary` and `.wrapped`, captured argv and `initialCommand`; `backedByZmx` is still decided at
   construction because the disposition is.

Pacing is start-rate limiting, not a concurrency cap. `createSurface()` returns when
`ghostty_surface_new` has only begun the child's lifecycle; no callback marks a replayed program's startup
finished (PWD/title/output are optional program behavior, exit is far too late), so an in-flight cap has
no truthful release edge. The pacer is a leaky bucket: at most one paced grant per `interval`, the next
deadline computed from the ACTUAL previous grant on a monotonic clock, never catching up missed ticks
after a main-thread stall. The one bounded exemption is the launch burst: every open window's selected
session's on-screen panes are granted synchronously when each one requests, since the user is looking
at them.

Two promotion verbs, because one cannot serve both callers: `expedite(key)` grants ONE key immediately
and resets the deadline (selection, zoom, control commands that must realize now); `prioritize(keys)`
reorders without releasing (a dashboard opening on many queued members). Once granted a key stays
granted; a second expedite of a granted or already-expedited key is a no-op, so repeated
`deckVisible = true` writes cannot mint tokens.

Scope: every launch that replays is paced, whichever mode replays it. In rerun mode every restored pane
carrying a replay is queued. In live mode a `.wrapped` pane is queued only when its daemon is absent or
unknown; a pane whose daemon the launch reap observed alive attaches immediately, because attaching a
survivor runs no program. The reap's parsed `zmx list` becomes a SCHEDULING HINT carried on an
app-local launch context, never on `GhosttyApp`, whose `restoreLaunchDecision` is immutable process
policy. A list-to-attach race can still miss a daemon that died in between, so nothing about correctness
depends on the hint: a mis-hinted survivor merely spawns unpaced, exactly today's behavior. When the
list fails, every replay-bearing live pane is paced; an unrelated orphan-kill failure does not count as
"list failed".

Expected set: every restored primary pane and every restored SHOWN right pane is expected at arm, in
deterministic model order, because providers do not exist yet. The factory later computes `shouldPace`
without consuming: false calls `discard` for the expected key before any spawn, so a plain shell or a
running-daemon attach spawns synchronously and cannot block drain; true registers the weak view, and
`createSurface()` calls `request` only once the view is sized. Pacing therefore touches only panes that
would start a program.
A hidden restored split has no right host until shown and stays outside the queue with its pending state
intact. Fresh and runtime-created splits, scratch, overlays and the quick terminal are never armed; their
host attachment bypasses the bootstrap queue. The pacer is armed only by a launch restore and becomes
passthrough once its queue drains, so a session created later never waits.

Rejected: delaying the factory (widens the on-disk loss window, breaks `zmx kill` and `--pane right`
before mount); baking the seed at construction and re-arming it at exit (cannot honor `restore.clear`
once `view.command` holds the payload, and excludes rerun's `.ordinary` path); making zmx daemons lazy on
first selection (breaks the instant-flip promise and every control caller); per-window pacing (four
windows releasing one each per tick recreate a smaller synchronized burst); making the survivor decision
a correctness input; an in-flight concurrency cap (no truthful child-ready edge).

## Technical Details

**`SpawnKey`**: the pane identity UUID (`paneIdentity` / `splitPaneIdentity`), stable across the
wrapper's lifetime and already the daemon-name input.

**`SpawnPacer` (agtermCore, host-free, `@MainActor`, injected monotonic clock and timer):**
- `request(_ key: SpawnKey) -> Bool`: true = granted now; false = queued
- `expedite(_ key: SpawnKey)`: grant one queued key immediately, consume the next token, reset the
  deadline; no-op for a granted, unknown or already-expedited key
- `prioritize(_ keys: [SpawnKey])`: move to the front in the given order, release nothing
- `cancel(_ key: SpawnKey)`: drop a queued key (pane removed or view destroyed)
- `discard(_ key: SpawnKey)`: a key realized elsewhere leaves the queue without a grant and without
  releasing catch-up tokens
- `arm(order: [SpawnKey], burst: Set<SpawnKey>)`: records the EXPECTED deterministic model order and
  the burst membership. It emits no grant and starts no timer: at arm time no factory, provider or view
  exists yet, so a grant issued then would be a logical grant with no spawn, and the real
  `ghostty_surface_new` calls of several such keys would later collapse into one SwiftUI pass while every
  pacer timestamp still looked correct
- `request(_ key:)` marks the key READY. A ready burst key is granted synchronously on its request. The
  paced timer grants only a READY key, in expected order; when the next expected key is not yet ready or
  classified it waits rather than granting into an empty registry. The deadline runs from the ACTUAL
  grant. A missing registry entry at grant time is stale-state handling, never the bootstrap path
- `isPassthrough` once every expected key is granted, cancelled or discarded; unarmed or drained means
  `request` returns true synchronously
- `interval` (constant; starting value 120 ms, selected as described under Post-Completion) and the
  grant sink `onGrant: (SpawnKey) -> Void`; pure model, no AppKit

**Grant routing:** the app owns a `SpawnRegistry` mapping `SpawnKey` to a weak `GhosttySurfaceView`;
`onGrant` looks the key up and calls `createSurface()`; a missing or destroyed view is dropped. The view
never holds the pacer strongly. `destroySurface` cancels its key on the main actor; the nonisolated
`deinit` safety net schedules a key-only cancellation without capturing `self`.

**`LaunchSeedProvider`:** a value `{ shouldPace: Bool, resolve: @MainActor () -> LaunchSeed }` where
`LaunchSeed` is `(command: String?, initialInput: String?, waitAfterCommand: Bool)`. `shouldPace` is
decided at construction WITHOUT consuming anything, by peeking the inputs the pane's OWN disposition
will read, since the three dispositions honor different slots:
- `.ordinary` (rerun): a nonempty pending `session.restore` override, else a captured argv that
  `CommandRestore.shouldRestore` accepts, else a restored durable `initialCommand` paces; a pin-none
  override, a denylist-refused capture (which still suppresses `initialCommand`, matching the
  `hadForeground` precedence) or no command spawns a plain shell and does not
- `.wrapped` (live): an eligible captured argv, else a restored durable `initialCommand` paces; the
  pending restore override is IGNORED because `ZmxLaunch.surfaceSeed` never reads it (live pins are
  future-rerun policy, not a live opt-out) and it stays pending; a daemon name in `runningNames` forces
  unpaced because attaching runs no program
- `.fallback` (live requested, unavailable): never paced; the factories pass `restoreOverride: nil`
  (`agtermApp.swift:349`, `:546`), take no pending slot, and the provider resolves WITHOUT consuming,
  so pin and capture stay pending exactly as today
- explicit `none` mode: never paced, but it is the `.ordinary` disposition with
  `restoreEnabled == false`, which takes BOTH pending slots and drops them; the provider keeps that
  consume-and-drop path. Preserving them instead would let an old capture resurrect: exit capture keeps
  unconsumed pending state, so a mode change to rerun before the next clean quit would replay a
  command the user launched under none
`resolve` is the factory's existing `.wrapped` / `.ordinary` / `.fallback` seed computation moved into a
closure, so `surfaceSeed` and `restorePlan` precedence are untouched; only WHEN it runs changes.
`createSurface()` calls it once, immediately before `ghostty_surface_config_new`, caches the result for
the surface's lifetime so a retry after an unrelated failure does not consume a second time, and sets
the closure to nil. Lifetime: the closure captures the session only through the view's existing weak
`session` (never strongly, or `Session -> view -> provider -> Session` cycles when a view is destroyed
before spawning); `destroySurface` also nils it. A view built without a provider (overlay, scratch,
quick, HUD, dashboard host) keeps its constructor values and never queues.

**Preemption sources:** `deckVisible = true` expedites the view's key (not `deckActive`, which is
split-focus-gated and would leave the other half of a shown split queued); zoom host attach expedites; the
dashboard host prioritizes its members; the quick terminal and overlays are unarmed. Control commands
that must realize their pane expedite before their existing bounded poll: `session.type` (left AND right;
right keeps failing fast when there is no shown split), `session.search` open/update/next/prev, and the
synchronous mutators that need a live libghostty surface (`session.paste`, `session.selectall`, and
`font.inc/dec/reset` for the left and right panes: `ControlDispatcher.swift:679-687` routes them to
`actions.font`, which resolves a per-pane surface at `ControlServer+SurfaceIO.swift:32-62` and answers
`session not realized`), so `ControlActions` stays synchronous. Reads keep their contract:
`session.text` and `session.copy` report `session not realized`, `surface.cursor` reports
`surface not realized` (`ControlServer+SurfaceIO.swift:337`), and the overlay reads address their own
overlay surface (`no overlay` / `overlay not realized`), never the base pane; none of them realizes
anything. `session.swap` needs eager wrapper slots, not a spawned surface, and is unchanged.

**Launch context:** `ZmxClient.reap` returns `ReapOutcome { runningNames: Set<String>?, killedAll: Bool }`.
`runningNames` holds only records with `clients != nil`: `ZmxListParser` emits `clients == nil` for an
`err=` row and `ZmxInventory` classifies that `.unreadable`, so a stale or unreadable socket must be
paced like an absent daemon, not attached unpaced as a survivor. It is nil only when `zmx list` failed
or did not parse; an orphan-kill failure with a good list leaves it populated. The existing synchronous
inventory sink captures it into a `LaunchSpawnContext` on `RestoredRuntime`; `agtermApp` arms the pacer
after `WindowLibrary` returns, when model order is available, and hands the context to the factories,
which set `shouldPace` when building each provider.

**Model removal drops (revmux round 01):** the pacer grants only a ready head and never jumps an
expected key, so a pane leaving the visible model before its window mounts would hold the queue forever.
`AppStore` and `WindowLibrary` take a default-nil `launchPaneDrop` closure and call it with the pane
identities on hard and soft session close, hard and soft workspace removal, a shown split hidden or
closed, and a loaded window's close or delete; the app wires it to `SpawnPacer.discard`. A hidden split's
identity rides along and is ignored as a key outside the order; a view torn down later drops again,
harmlessly; undo or re-show returns as a key outside the order and spawns synchronously. Owners:
`AppStoreTests`, `AppStorePendingCloseTests`, `AppStorePaneTests`, `WindowLibraryTests`.

**Read-back:** none new. `realized == false` and `agtermctl tree`'s `(not realized)` already describe a
session whose MAIN pane awaits its permit; both read `session.surface` only, so a queued right pane shows
nothing and an empty tree is no proof the queue drained. The pacer's `onDrain` debug log is the drain
signal. No command sets this state, so the read-back rule for state-setting commands does not apply.

## What Goes Where

- **Implementation Steps**: code, tests, rule and doc updates inside this repo
- **Post-Completion**: interval selection and the manual replaying-launch check on the user's setup

## Implementation Steps

### Task 1: Host-free `SpawnPacer` model

**Files:**
- Create: `agtermCore/Sources/agtermCore/SpawnPacer.swift`
- Create: `agtermCore/Tests/agtermCoreTests/SpawnPacerTests.swift`

- [x] write tests first: arm with no requests emits nothing even after the clock advances; N keys requested
      late, in any order, yield N grants each `interval` apart in expected order, timed from the actual
      grants; a burst key grants synchronously on its request, not on arm; the timer waits when the next
      expected key has not requested yet; a clock that wakes late by 3 intervals releases ONE grant;
      expedite grants one key now, consumes the token and resets the deadline; prioritize reorders and
      releases nothing; discarding an expected key that never requests cannot block drain
- [x] write tests first: double request is idempotent; expedite of a granted, unknown or already-expedited
      key is a no-op; cancel and discard drop without a grant and without catch-up; request after
      passthrough is synchronous; unarmed pacer grants synchronously
- [x] add `SpawnKey`, `SpawnPacer` with `request` (marks ready), `expedite`, `prioritize`, `cancel`,
      `discard`, `arm(order:burst:)` (records expectations only), `isPassthrough`, `interval`, injected
      clock/timer, and `onGrant`
- [x] leaky-bucket deadline computed from the actual previous grant; no catch-up
- [x] run `cd agtermCore && swift test --filter SpawnPacerTests` - must pass before Task 2

### Task 2: Late seed: `LaunchSeedProvider` on the view, consumed at spawn

**Files:**
- Create: `agterm/Ghostty/LaunchSeed.swift` (`LaunchSeed`, `LaunchSeedProvider`, `LaunchSeedPolicy` and the
  classifier live here, not in `GhosttySurfaceView.swift`, which sits at 996 of the 1000-line cap and
  Task 3 must still grow)
- Create: `agtermTests/LaunchSeedTests.swift`
- Modify: `agterm/Ghostty/GhosttySurfaceView.swift`
- Modify: `agterm/agtermApp.swift` (both factories)
- Modify: `agterm/AppDelegate.swift` (`captureForegroundCommands`, if the unconsumed-pending path needs a
  wrapper-aware read)
- Modify: `agtermTests/AppDelegateCaptureTests.swift`
- Modify: `agtermTests/GhosttySurfaceViewTrackingTests.swift` (or the file owning surface lifecycle tests)

- [x] write tests first: a mounted-but-unspawned restored pane leaves `pendingForegroundCommand` and
      `pendingRestoreOverride` on the `Session`; a clean quit at that point persists the same argv for
      rerun AND live; `restore.clear` at that point on a CAPTURE-ONLY session (no `initialCommand`, no
      sticky pin, which the command deliberately leaves alone) makes the later spawn run a plain shell; an
      on-demand `restore.capture` at that point persists nothing for that pane
- [x] write tests first: spawning consumes each slot exactly once; a second `createSurface` after a failed
      first attempt reuses the cached seed; a view without a provider keeps its constructor values; a view
      destroyed before its provider resolves deallocates and leaves the `Session` with no strong path back
      to it; the closure is nil after resolution and after `destroySurface`
- [x] write tests first, per disposition: `.ordinary` is true for a captured argv the denylist accepts,
      a nonempty pending override and a restored durable `initialCommand`, false for pin-none, a
      denylist-refused capture and no command; `.wrapped` is true for an eligible capture and for a
      durable `initialCommand`, false for a pane carrying ONLY a sticky pin (which stays pending), and
      false when its daemon name is running; `.fallback` is false and resolving it leaves pin and capture
      pending; explicit `none` is false and resolving it consumes and drops both slots, spawning a plain
      shell, so a later mode change to rerun replays nothing; computing `shouldPace` consumes no slot
- [x] add `LaunchSeed`, `LaunchSeedProvider { shouldPace, resolve }`, the provider property and its one-shot
      cache to `GhosttySurfaceView`; `createSurface()` resolves it immediately before
      `ghostty_surface_config_new`; the closure captures the session weakly and is nilled after resolution
      and in `destroySurface`
- [x] move each factory's `.wrapped` / `.ordinary` / `.fallback` seed computation into the provider it
      passes to the view; construction no longer calls `takePending*`
- [x] run the touched test classes with `-only-testing:` - must pass before Task 3

### Task 3: Gate `createSurface()` on the pacer with weak grant routing

**Files:**
- Modify: `agterm/Ghostty/GhosttySurfaceView.swift`
- Create: `agterm/Ghostty/SpawnRegistry.swift`
- Create: `agterm/Ghostty/GhosttySurfaceView+FirstResponder.swift` (first-responder overrides moved verbatim to keep the view file under the 1000-line limit)
- Modify: `agterm/agtermApp.swift` (owns the pacer and registry; injects them into every factory)
- Create: `agtermTests/SpawnRegistryTests.swift`
- Modify: `agtermTests/GhosttySurfaceViewTrackingTests.swift`
- Modify: `agtermTests/SurfaceFactorySeedTests.swift`

- [x] write tests first: a denied view creates no surface and creates one on grant against current bounds;
      every entry path reaches the same gate and a denied one creates nothing (`TerminalView.updateNSView`,
      `viewDidMoveToWindow`, the `setFrameSize` retry, the 1 s retry); a zero-size view consumes no token
      until it has a size
- [x] write tests first: destroy before grant cancels and the grant is a no-op; a deallocated view leaves
      no strong reference in the registry and no callback fires; unarmed pacer keeps today's synchronous
      behavior (surface exists on return from `updateNSView`)
- [x] add `spawnKey`, `awaitingSpawnPermit` and the registry hookup to `GhosttySurfaceView`; request the
      permit after the size guard and before the provider resolves the seed, and only when the provider's
      `shouldPace` is true; a `false` provider calls `discard` for its expected key at construction and the
      view spawns synchronously exactly as today
- [x] `SpawnRegistry` with weak views keyed by `SpawnKey`; `onGrant` routes through it
- [x] `destroySurface` cancels on the main actor; `deinit` schedules a key-only cancellation without `self`
- [x] run the touched test classes - must pass before Task 4

### Task 4: Expedite and prioritize from selection, hosts and control

**Files:**
- Modify: `agterm/Ghostty/GhosttySurfaceView.swift` (`deckVisible` didSet)
- Modify: `agterm/Views/DashboardView.swift` (the zoom host already sets `deckVisible`, so it needs no change)
- Create: `agtermTests/DashboardViewTests.swift`
- Modify: `agterm/Control/ControlServer+SurfaceIO.swift` (`injectText` for `session.type`, `searchSession`,
  `pasteSession`, `selectAllSession`, `font`)
- `agterm/Control/ControlServer+Zmx.swift` unchanged: teardown cancels the key, so `applyKilledPaneExit` needs no `discard`
- Modify: the corresponding `agtermTests` files and the dispatcher/protocol tests those commands own

- [x] write tests first: with a paced launch the selected pane of each window is granted synchronously on
      its first request after arm; selecting a queued session grants it before the queue reaches it;
      selecting it twice mints one token
- [x] write tests first: `session.type --select` on a queued pane succeeds within the existing 12 x 30 ms
      poll; `session.type --pane right` on a queued shown split succeeds and on an absent split fails fast
      as today; `session.search` open on a queued pane realizes it; `session.paste`, `session.selectall`
      and `font.inc` on a queued left pane and on a queued shown right pane succeed synchronously
- [x] write tests first: on a queued pane `session.text` and `session.copy` answer `session not realized`
      and `surface.cursor` answers `surface not realized`, all leaving it queued; a dashboard opened on
      queued members promotes them but records spawns still `interval` apart
- [x] write tests first: `zmx kill` on a claimed, mounted, unspawned pane performs the model transition
      (`handlePaneExit`) and the later grant does not recreate the daemon
- [x] keep the expedite set to exactly `session.type`, `session.search`, `session.paste`, `session.selectall`
      and `font.inc/dec/reset`: the last four resolve a surface and answer `session not realized` when it
      has none (`ControlServer+SurfaceIO.swift:32-62`); the scratch pane is runtime-only and never queued
- [x] wire `deckVisible`, zoom host and dashboard host; wire the control expedites before each bounded poll
- [x] run the touched test classes - must pass before Task 5

### Task 5: Arm from the launch inventory with the survivor hint; drain to passthrough

**Files:**
- Modify: `agterm/Ghostty/ZmxClient.swift` (`reap` returns `ReapOutcome`)
- Modify: `agterm/agtermApp.swift` (`LaunchSpawnContext` on `RestoredRuntime`; arm after `WindowLibrary`
  returns; classification in the factories' providers)
- Modify: `agtermTests/ZmxClientTests.swift` (owns `reap`: the `ReapOutcome` `err=` row and kill-result
  cases live here)
- Create: `agtermCore/Sources/agtermCore/LaunchSpawnPlan.swift` (model order and burst)
- Create: `agtermCore/Tests/agtermCoreTests/LaunchSpawnPlanTests.swift`
- Modify: `agtermCore/Sources/agtermCore/SpawnPacer.swift` (`onDrain`)
- Modify: `agtermCore/Tests/agtermCoreTests/SpawnPacerTests.swift` (drain; late second window)
- Modify: `agtermTests/SpawnRegistryTests.swift` (launch pipeline with injected clock)
- Modify: `agtermTests/SurfaceFactorySeedTests.swift` (hidden split; policy carries the reap's names)
- Disposition classification was pinned by `LaunchSeedTests` in Task 2

- [x] write tests first (injected clock, spawn recorder): a launch restore of N replaying sessions records
      N spawns each `interval` apart and goes red when the gate is removed; a session created after drain
      spawns synchronously; a one-session launch spawns synchronously
- [x] write tests first: live survivor (name running) spawns unpaced while missing and unknown names are
      paced; an `err=` list row is paced; a nil running set paces every replay-bearing live pane; an
      orphan-kill failure with a good list does not pace survivors; rerun-mode replay is paced
- [x] write tests first: a plain restored shell, a pin-none pane and a denylist-refused capture are never
      queued and spawn synchronously; a restored durable `initialCommand` is paced
- [x] write tests first: a restored hidden split is not armed and drain completes without it; showing it
      later attaches through the normal unarmed path with its pending state intact; reap and claim run
      before any grant
- [x] `reap` returns `ReapOutcome { runningNames: Set<String>?, killedAll: Bool }` built from records with
      `clients != nil`; the inventory sink stores it on `LaunchSpawnContext`
- [x] arm from the model BEFORE any window mounts, recording expectations only: every open window's
      selected session's on-screen panes as the burst set, then remaining windows, sessions, primaries and
      shown right panes; never expect fresh or runtime splits, scratch, overlays or quick
- [x] write tests first: with arm done and no view mounted, advancing the clock records no spawn; views
      that mount one tick late still record spawns `interval` apart from the first actual grant; a
      multi-window launch whose second window mounts after every ready key of the first has been granted
      (not pacer passthrough, which waits on every expected key) records no simultaneous spawns
- [x] passthrough once every armed key is granted, cancelled or discarded; log the drain duration at debug
- [x] run the touched test classes - must pass before Task 6

### Task 6: Verify acceptance criteria
- [x] verify every required regression in Testing Strategy exists and names the task that owns it
- [x] run full gates once: `cd agtermCore && swift test`, `make test-app`, `make lint`
- [x] confirm `realized` read-back and `agtermctl tree` `(not realized)` describe a queued MAIN pane correctly
      (a queued right pane shows nothing on either)

### Task 7: Update documentation
- [x] `.claude/rules/libghostty.md`: the permit and the late seed inside `createSurface()`, and why the
      deferral does not race layout
- [x] `.claude/rules/settings.md` (owns restore capture and the pending slots): seed consumption at
      spawn time; `restore.clear` and clean-quit preservation now cover the paced window; hard reset
      boundary unchanged
- [x] `.claude/rules/control-api.md`: which commands expedite a queued pane and which reads never do
- [x] `site/docs.html` restore section: one sentence that a launch which replays commands brings panes up
      over several seconds, the visible panes first
- [x] `plugins/agterm/skills/agterm/troubleshooting.md`: `(not realized)` right after a replaying launch
      is pacing, not a fault
- [ ] move this plan to `docs/plans/completed/` (left in place: this run does not move the plan; do it when the PR merges)
- [x] ➕ `plugins/agterm/skills/agterm/reference.md` and `SKILL.md`: their `realized` sentences said `session type`
      answers `session not realized` for an unrealized pane, which the expedite makes untrue for a paced one

## Post-Completion

**Interval selection:** 120 ms ships as the explicit product starting value. It is NOT tuned on the
user's live setup: producing samples at several intervals would mean repeatedly killing his daemons and
agents to force replaying launches, which nothing authorizes, and a natural reboot yields one sample. If
tuning is wanted, do it in an isolated instance (`AGTERM_STATE_DIR`, own socket) seeded with N sessions
carrying a cheap captured command, at 80, 120 and 200 ms, recording peak CPU, time to first prompt in
the selected pane and time to full drain; record the numbers in the commit that changes the constant.

**Manual verification, next NATURAL replaying launch only:** no simultaneous `ps` burst and no CPU pin
(each paced Claude startup still runs its own `ps`), selected panes usable immediately, `agtermctl tree`
`(not realized)` clearing from the queued main panes over the drain, and the `onDrain` debug log line as
the proof the whole queue drained, since the tag never covers a right pane.

**External:** none. Claude Code's own `ps aux` at startup is upstream behavior and out of scope.

Smells pre-check: skipped — non-Go project
