# Auto-follow Attention

## Overview

Add a Settings option that, after the user has been idle from input for a chosen timeout, automatically
jumps the window's selected session to the oldest `blocked` session, so the user is pulled to whatever
agent is waiting for input.

- **Problem it solves:** with many agent sessions running, a session that blocks (agent waiting for the
  user) is easy to miss. Today the user must watch the sidebar glyphs and navigate manually.
- **Key behavior:** per-window, user-idle-triggered, blocked-only, FIFO (oldest-blocked-first), window-wide
  (crosses workspaces within the window). Disabled by default.
- **Integration:** a host-free policy layer on the existing per-window `AppStore`, reusing `Debouncer`,
  `attentionSessions`, and `selectSession`. Plus a read-only idle/config exposure on the `tree` and
  `window.list` control responses.

## Context (from discovery)

Files/components involved:
- `agtermCore/Sources/agtermCore/AppStore.swift` — per-window `@Observable @MainActor` store; owns
  `selectSession` (:202), `attentionSessions` (:576, window-wide, non-idle, sorted attentionRank then
  `statusChangedAt` DESC), `setAgentIndicator` (:244), `controlTree` (:126).
- `agtermCore/Sources/agtermCore/AgentStatus.swift` — `enum AgentStatus { idle, active, completed,
  blocked }`; `attentionRank` blocked=0/active=1/completed=2/idle=3.
- `agtermCore/Sources/agtermCore/Session.swift` — `Session.agentIndicator` (:44, ephemeral),
  `statusChangedAt` (:51, `@ObservationIgnored`, stamped on every non-idle set, nil on idle).
- `agtermCore/Sources/agtermCore/Debouncer.swift` — `@MainActor` cancel-and-reschedule timer; reuse.
- `agtermCore/Sources/agtermCore/AppSettings.swift` — all-optional `Codable` settings struct; nested
  `NewSessionDirectory` enum (:14) + field (:122) is the pattern to mirror.
- `agtermCore/Sources/agtermCore/ControlProtocol.swift` — `ControlTree { workspaces }` (:283, single-window
  projection, NO window node), `ControlWindowNode { id,name,open,active }` (:293, the `window.list`
  element), `ControlResult` (:311).
- `agterm/SettingsModel.swift` — app-target model; save-only setters (mirror `setNewSessionDirectory`
  :117); appearance-flag fan-out via `.agtermAppearanceChanged`.
- `agterm/Views/SettingsView.swift` — 5-tab scene (:15); `AgentStatusSettingsView` is the target tab;
  `newSessionDirectory` binding (:177) is the `.off -> nil` idiom to mirror.
- `agterm/Ghostty/GhosttySurfaceView+Input.swift` — keystroke path (~:48 `clearedByKeystroke`) is where the
  activity hook goes.
- `agterm/Control/ControlServer.swift` — `buildTree(in store:)` (:470); the `window.list` dispatch arm.
- `agterm/AppActions.swift` — user-facing session-nav wrappers (`selectNextSession` etc.) + the notification
  `reveal` path; `focusActiveSession` for terminal first-responder.
- `agterm/Notifications/DockBadgeController.swift` — `withObservationTracking` re-arm pattern (:81) to
  mirror for status-change arming.

Related patterns found:
- Ephemeral per-session status; `statusChangedAt` is the age key (every non-idle session has one).
- Demand-driven, no poll timer — react via `withObservationTracking` re-arm, not polling.
- Settings persist to `<stateDir>/settings.json` as minimal JSON (default = absent optional).

Dependencies identified:
- Idle metric (`idleMs`) depends on `AppStore.lastActivityAt` (new, Task 2).
- Settings fan-out (Task 6) pushes timeout + stay-on-active into every open `AppStore`.
- Keystroke hook (Task 5) calls `AppStore.noteUserActivity()` (Task 2).

## Development Approach

- **testing approach:** tests-with-each-task. The bug-prone policy is factored as a pure, host-free
  function and unit-tested under `swift test` with no timers. Write/extend tests in the same task as the
  code they cover.
- complete each task fully before moving to the next; small focused changes.
- **CRITICAL: every task MUST include new/updated tests** for its code changes (success + edge cases),
  listed as separate checklist items.
- **CRITICAL: all tests must pass before starting the next task.**
- after each change: `cd agtermCore && swift test` green, `make lint` (swiftlint `--strict`) clean, and for
  app-target changes the app must build. `agtermCore` stays host-free (no AppKit/GhosttyKit/Metal/CoreGraphics).
- test placement follows the codebase's existing concern-split, not a blanket one-file-per-source rule:
  `AppStore` tests already live across `AppStoreTests` / `AppStoreNavigationTests` / `AppStoreOrganizationTests`
  / `AppStorePaneTests` (+ `AppStoreTestFixtures`). Put the auto-follow tests in `AppStoreTests.swift` or a
  new `AppStoreAutoFollowTests.swift`; single-source files (`AppSettings`, `ControlProtocol`) keep their
  single test file.

## Testing Strategy

- **unit tests (host-free, primary):** the `autoFollowTarget` pure decision function, `noteUserActivity`
  activity stamping + `idleMs` computation (inject `now`), and control round-trip encode/decode for the two
  new fields. These are the gate — CI runs `swift test` only.
- **e2e (XCUITest, optional):** one test that sets a session `blocked` via the control socket, waits past a
  short timeout, and asserts the window's selection moved. CI does NOT run XCUITests, so this is a bonus,
  not the gate. Use an isolated `AGTERM_STATE_DIR`/socket per the ui-tests rule.

## Progress Tracking

- mark completed items `[x]` immediately when done.
- add newly discovered tasks with the ➕ prefix; blockers with ⚠️.
- keep this plan in sync if scope shifts during implementation.

## Solution Overview

A per-window idle policy on `AppStore`:

- `noteUserActivity()` stamps `lastActivityAt` (always, so the idle metric is independent of the feature)
  and, when a timeout is configured, arms a `Debouncer`. Called from the keystroke path and from
  user-initiated selection.
- A status-change observer (`withObservationTracking` re-arm, DockBadge pattern) also arms the debouncer so
  a block that lands while the user is already idle — or an active session finishing — is re-evaluated.
- On fire, `autoFollowFire()` consults a pure `autoFollowTarget(...)` function: suppress if the current
  session is blocked (always) or active (when the opt-in toggle is on); otherwise return the oldest blocked
  session (FIFO by `statusChangedAt` ascending, window-wide) and `selectSession` + focus it.

The advance cycle needs no new state: focusing a blocked session does not clear its glyph (only typing
does), so being parked on a blocked session is itself the suppressor; typing a reply clears it and re-arms
the timer, and the next idle fire picks the next blocked session. The "queue" is derived from
`attentionSessions` each fire, never persisted.

## Technical Details

- **Settings:** `AppSettings.AutoFollowAttention: String, CaseIterable, Sendable { case off, s5, s10, s30,
  s60, m5 }` with `var timeout: TimeInterval?` (off->nil, s5->5, s10->10, s30->30, s60->60, m5->300). New
  optional fields `autoFollowAttention: String?` (nil = off = default) and `autoFollowStayOnActive: Bool?`
  (nil/false = off = default), both added to the memberwise `init`, both stored as raw/tolerant so the
  default stays absent from `settings.json`.
- **AppStore new state:** `autoFollowTimeout: TimeInterval?`, `autoFollowStayOnActive: Bool`,
  `lastActivityAt: Date?`, `autoFollowDebouncer = Debouncer()`.
- **Pure decision (host-free, testable):**
  `autoFollowTarget(current: Session?, blocked: [Session], stayOnActive: Bool) -> UUID?`
  where `blocked` is the window-wide blocked set. Rules:
  - `current?.agentIndicator.status == .blocked` -> `nil`.
  - `stayOnActive && current?.agentIndicator.status == .active` -> `nil`.
  - else -> id of `blocked` min-by `statusChangedAt` (ascending); `nil` if `blocked` empty.
- **Idle metric:** `idleMs(asOf: Date = Date()) -> Int?` on `AppStore` = `lastActivityAt` present ?
  `Int(now.timeIntervalSince(lastActivityAt) * 1000)` clamped >= 0 : `nil`.
- **Control fields:** `idleMs` is a live, continuously-growing delta, so it goes on `ControlTree` ONLY
  (top-level; `tree` is built live on the main actor per window). It must NOT go on `ControlWindowNode`:
  `window.list` is answered from the nonisolated `cachedWindowNodes` fast path (ControlServer.swift:70),
  refreshed only after a dispatched command / frontmost-change (no timer), so an `idleMs` there would be
  frozen between commands — a silently-stale value. `autoFollowMs` (config, rarely changes) goes on BOTH
  `ControlTree` and `ControlWindowNode`; document the `window.list` copy as "as of last refresh". All
  additive optionals -> existing decoders tolerate them. `autoFollowMs` = `autoFollowTimeout` in ms or nil;
  `idleMs` = ms since `lastActivityAt` or nil.

## What Goes Where

- **Implementation Steps** (`[ ]`): all code, tests, and in-repo docs (README, site, agent-skill).
- **Post-Completion** (no checkboxes): manual multi-window/idle acceptance testing, optional XCUITest e2e
  wiring notes.

## Implementation Steps

### Task 1: AppSettings — AutoFollowAttention enum + fields

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppSettings.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppSettingsTests.swift`

- [x] add nested `enum AutoFollowAttention: String, CaseIterable, Sendable { case off, s5, s10, s30, s60, m5 }`
      with `var timeout: TimeInterval?` computed mapping (off->nil, s5->5, s10->10, s30->30, s60->60, m5->300)
- [x] add optional field `autoFollowAttention: String?` and `autoFollowStayOnActive: Bool?` to `AppSettings`
      and to the memberwise `init` (default nil), mirroring the `NewSessionDirectory` pattern
- [x] write tests: `AutoFollowAttention(rawValue:)` tolerant decode of an unknown string falls back to off;
      each case maps to the correct `timeout`; `s5`/`m5` boundaries
- [x] write tests: encoding an `AppSettings` with both fields nil omits them from JSON (default minimal);
      round-trip with each field set decodes back equal
- [x] run `cd agtermCore && swift test` — must pass before Task 2

### Task 2: AppStore — idle controller state, activity stamping, pure target function

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift` (stored `@Observable` state must live in the main
  type body); put the methods in a new `agtermCore/Sources/agtermCore/AppStore+AutoFollow.swift` extension
  (AppStore is ~737 lines vs the 1000 cap; the codebase already uses extension-file splits)
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreTests.swift` OR add `AppStoreAutoFollowTests.swift`
  (follow the existing concern-split, not a one-file rule)

- [x] add stored state on `AppStore`: `autoFollowTimeout: TimeInterval?`, `autoFollowStayOnActive: Bool`
      (default false), `lastActivityAt: Date?`, `let autoFollowDebouncer = Debouncer()` — the debouncer is
      `internal` (NOT `private`) so `@testable` tests can drive its `flush()` seam
- [x] add `noteUserActivity()`: stamp `lastActivityAt = Date()` unconditionally; if `autoFollowTimeout` is
      non-nil, `autoFollowDebouncer.schedule(after: timeout) { [weak self] in self?.autoFollowFire() }`
      (match `scheduleSave`'s `[weak self]`, AppStore.swift:683), else `autoFollowDebouncer.cancel()`
- [x] add pure `autoFollowTarget(current: Session?, blocked: [Session], stayOnActive: Bool) -> UUID?`
      implementing the three suppress/pick rules (blocked-suppress, active-suppress-if-opt-in, else FIFO
      oldest by `statusChangedAt` ascending)
- [x] add `autoFollowFire()` (at least `internal`, so tests can call it directly): compute the window-wide
      blocked set (filter `attentionSessions` to `.blocked`), call `autoFollowTarget`, and if non-nil
      `selectSession(id)` (without noting activity); no reschedule on no-op
- [x] add `idleMs(asOf: Date = Date()) -> Int?` computing ms since `lastActivityAt` (nil when never active,
      clamped >= 0)
- [x] write tests for `autoFollowTarget`: current blocked -> nil; stayOnActive+current active -> nil;
      !stayOnActive+current active -> picks; two blocks at different `statusChangedAt` -> oldest; blocked in
      another workspace -> picked (window-wide); empty blocked -> nil; advance (current cleared to idle ->
      next oldest)
- [x] write tests: `noteUserActivity()` stamps `lastActivityAt`; `idleMs(asOf:)` with injected now returns
      expected ms; nil before any activity
- [x] run `cd agtermCore && swift test` — must pass before Task 3

### Task 3: AppStore — status-change arming + enable/disable lifecycle

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreTests.swift`

- [x] add a `withObservationTracking` re-arm observer (mirror `DockBadgeController.apply`) that arms the
      debouncer on ANY `agentIndicator`/`attentionSessions` change in the window while a timeout is set, and
      re-registers itself on each change; tear it down when disabled
- [x] add `setAutoFollow(timeout:stayOnActive:)` (or two setters) that update the stored state, and on
      disable (`timeout == nil`) cancel the debouncer and stop observing; on enable arm from the current state
- [x] guard against self-trigger: `autoFollowFire()`'s own `selectSession` must not count as activity.
      NOTE the one self-trigger path that DOES exist: `selectSession` clears an `autoReset` `completed` glyph
      on the session it moves AWAY from (`clearAutoResetIndicator(previous)`, AppStore.swift:209), which is
      an `agentIndicator` change the observer sees and re-arms on. This self-corrects and is NOT a loop — the
      next fire's `current` is the just-selected blocked session, so `autoFollowTarget` returns nil (blocked
      suppress) and the no-op guard holds. Verify this terminates rather than assuming "observer arms only on
      status change"
- [x] write tests: enabling arms/observing; disabling cancels; a status change while enabled schedules a
      fire (assert via a seam that does not require real-time sleep — e.g. flush the debouncer or call the
      fire path directly). Keep timing deterministic; no `Task.sleep`-based flakiness
- [x] run `cd agtermCore && swift test` — must pass before Task 4

### Task 4: User-initiated selection counts as activity

**Files:**
- Modify: `agterm/AppActions.swift`
- Modify: `agterm/Views/` sidebar selection handler (the row-click path that calls `selectSession`)
- Modify: relevant app-target test if one exists; otherwise assert the non-note behavior via the Task 2/3
  host-free tests (auto-follow's own select does not stamp `lastActivityAt`)

- [x] call `store.noteUserActivity()` from user-initiated selection entry points (the `AppActions`
      session-nav wrappers and the sidebar row-selection handler) so manual navigation buys the full idle
      grace before any pull-back
- [x] confirm `autoFollowFire()`'s `selectSession` path does NOT call `noteUserActivity()` (keep the note at
      user entry points only, not inside `selectSession`)
- [x] write/extend tests: a simulated user selection stamps `lastActivityAt`; the auto-follow fire path does
      not (already covered by Task 2 — assert explicitly here)
- [x] run tests — must pass before Task 5

### Task 5: App-target wiring — keystroke hook + focus-on-follow bridge

**Files:**
- Modify: `agterm/Ghostty/GhosttySurfaceView.swift` (new callback property + `destroySurface` nil-out)
- Modify: `agterm/Ghostty/GhosttySurfaceView+Input.swift` (fire the callback in `keyDown`)
- Modify: `agterm/agtermApp.swift` (wire the callback at BOTH surface factory sites; observe the focus bridge)

- [x] add `var onUserInput: (() -> Void)?` to `GhosttySurfaceView` (sibling of `onUserInputClearsStatus`,
      :102) and nil it in `destroySurface()` alongside `onUserInputClearsStatus = nil` / `onFocusChange = nil`
      (:774) — REQUIRED to break the `store -> session -> surface -> closure -> store` retain cycle
- [x] wire `onUserInput` at BOTH factory sites in `agtermApp.swift` (:205-212 and :307-313, next to the
      existing `onUserInputClearsStatus`), each capturing `store` + `sessionID` and calling
      `store.noteUserActivity()`. Do NOT reach into `WindowLibrary` from the view (it holds no library ref)
- [x] call `onUserInput?()` on EVERY `keyDown`, UNCONDITIONALLY (right after `guard let surface`), OUTSIDE
      the `if ... clearedByKeystroke { }` branch at :47-50 — otherwise ordinary typing in an idle session
      wouldn't reset the idle timer and the user gets yanked mid-typing
- [x] focus bridge (agtermCore cannot call the app-target `focusActiveSession`): `autoFollowFire()` posts a
      `Notification.Name` (e.g. `.agtermAutoFollowed`) carrying the window id + session id; an app-side
      observer, only when that window is key, calls `focusActiveSession()` (AppActions.swift:600). Selection
      alone does NOT move first responder (eager deck keeps the old surface as responder), so this bridge is
      load-bearing. Non-key windows only change selection; they focus normally on becoming key. Session
      granularity — no split-pane logic
- [x] verify no double-clear regression: a keystroke still clears the focused session's blocked glyph
      (existing `onUserInputClearsStatus`) and now also stamps activity via `onUserInput` (new)
- [x] XCUITest (skipped — optional/non-gating; heavy isolated-instance + socket + timing setup, flaky;
      feature gated by host-free Task 2/3 tests + the app build): set a session `blocked` via control, wait past a
      short timeout, assert the window's selection moved to it (isolated state dir + socket). NOTE: Tasks 4/5
      have NO host-free gating test — the gate is the Task 2/3 host-free assertions plus this optional e2e
  - ➕ Task 7b: added `agtermUITests/AutoFollowUITests.swift` (idle-jump + suppress-when-parked), runs
        locally, reliably green — the earlier optional XCUITest, now implemented at maintainer request. Seeds
        `settings.json` with `autoFollowAttention: s5` and relaunches (new `ControlAPITestCase.relaunch(withSettings:)`
        helper), drives the session set/statuses over the socket (none count as activity), and asserts
        selection via the live `tree` `active` flag.
- [x] build the app (Debug) and run `cd agtermCore && swift test` + `make lint` — must pass before Task 6

### Task 6: Settings model + Agent Status tab UI + fan-out

**Files:**
- Modify: `agterm/SettingsModel.swift`
- Modify: `agterm/Views/SettingsView.swift`
- Modify: app-target settings test if present

- [x] add `SettingsModel.setAutoFollowAttention(_:)` and `setAutoFollowStayOnActive(_:)` — save-only
      (non-ghostty, no surface reload; mirror `setNewSessionDirectory`)
- [x] on change, push the resolved `timeout` + `stayOnActive` into every open window's `AppStore` (reuse the
      appearance-flag fan-out style / `.agtermAppearanceChanged`); ensure a newly created window reads the
      current values at init
- [x] in `AgentStatusSettingsView` add a `Picker` "Auto-follow blocked sessions"
      (Disabled/5s/10s/30s/60s/5m, default Disabled) with a binding mapping `.off -> nil` on set (mirror
      `newSessionDirectory` binding), and a `Toggle` "Don't auto-follow away from a running session"
      (default off)
- [x] write/extend tests for the setters (persist + fan-out effect where the layer is testable); assert the
      `.off -> nil` binding keeps the default absent from JSON
- [x] build the app + `make lint` — must pass before Task 7

### Task 7: Control API — idleMs on tree (live), autoFollowMs on tree + window.list

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift` (fields on `ControlTree` + `ControlWindowNode`)
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift` (`controlTree` :126 populates `idleMs` + `autoFollowMs`)
- Modify: `agtermCore/Sources/agtermCore/WindowLibrary.swift` (`controlWindowNodes()` :162 populates
  `autoFollowMs` per open window — this is the REAL `window.list` build site; `ControlServer.buildWindowList`
  just calls it. NOT `ControlServer.swift`)
- Modify: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/WindowLibraryTests.swift` (extend `controlWindowNodesProjectListMetadata`)

- [x] add `idleMs: Int?` + `autoFollowMs: Int?` to `ControlTree`; add ONLY `autoFollowMs: Int?` to
      `ControlWindowNode` (NOT `idleMs` — see below), threaded through their `init`s as additive optionals so
      existing call sites keep compiling
- [x] populate `ControlTree` (built live on the main actor) from the projected window's `idleMs()` +
      `autoFollowTimeout`; populate `ControlWindowNode.autoFollowMs` in `controlWindowNodes()` by reaching each
      open store via `stores[id]` (already in scope, host-free)
- [x] do NOT put `idleMs` on `window.list`: it is answered from the nonisolated `cachedWindowNodes` fast path
      (ControlServer.swift:70) with no timer refresh, so a live/growing `idleMs` would be frozen and
      misleading. `autoFollowMs` is config that changes rarely, so its mild cache-staleness is acceptable
      (documented as "as of last refresh")
- [x] write round-trip tests: encode/decode `ControlTree` (both fields) and `ControlWindowNode`
      (`autoFollowMs`) with fields set and nil; assert JSON omits them when nil and preserves them when set;
      extend the `WindowLibraryTests` metadata test to assert `autoFollowMs` per open window
- [x] confirm NO new `Command` case, NO CLI mutation of the setting (settings stay GUI-only — documented as
      an explicit keep-in-sync exemption; consistent with `newSessionDirectory` / `attentionButtonEnabled` /
      `confirmCloseSession` etc.); command count unchanged
- [x] run `cd agtermCore && swift test` + `make lint` — must pass before Task 8

### Task 8: Documentation and keep-in-sync surfaces

**Files:**
- Modify: `agterm/Resources/agent-skill/reference.md`
- Modify: `README.md`
- Modify: `site/docs.html`

- [x] agent-skill `reference.md`: document `idleMs`/`autoFollowMs` in the `tree` and `window.list` response
      schemas; verify the command count is unchanged (no new command). Edit ONLY the app-repo bundle, never
      the installed copies
- [x] README.md: add the "Auto-follow blocked sessions" setting (values, per-window, blocked-only, FIFO,
      stay-on-active toggle) and the new read-only idle fields
- [x] site/docs.html: mirror the README additions (hand-authored keep-in-sync)
- [x] do NOT touch `CHANGELOG.md` (release-only)
- [x] run `make lint` — must pass before Task 9

### Task 9: Verify acceptance criteria

- [x] verify all Overview requirements: idle-triggered per-window auto-follow to oldest blocked, blocked-only,
      window-wide, FIFO, stay-on-active opt-in (default off), disabled by default
- [x] verify edge cases: parked-on-blocked suppresses; active suppress only when opted in; advance after
      typing clears; empty blocked no-ops; multi-window independence
- [x] run full suite: `cd agtermCore && swift test`
- [x] `make lint` (swiftlint `--strict`) clean; app builds (Debug)
- [x] optional: run the XCUITest e2e locally if wired in Task 5

### Task 10: Final documentation pass and archive plan

- [x] re-read README / site / agent-skill diffs for accuracy against the shipped behavior
- [x] update CLAUDE.md / `.claude/rules/*.md` only if a new reusable pattern emerged (e.g. the idle-activity
      seam) — otherwise skip
- [x] move this plan to `docs/plans/completed/` (deferred to exec finalization — orchestrator moves it after
      the review phases)

## Post-Completion

*Items requiring manual intervention or external systems — informational only.*

**Manual verification:**
- run an isolated dev instance with several sessions; set some `blocked` via `agtermctl session.status`;
  confirm idle-follow jumps to the oldest blocked, stays put while typing, advances after a reply, and (with
  the toggle on) does not leave an active session.
- multi-window: confirm each window follows its own blocked set independently and a background window has
  already surfaced its blocked session when switched to.
- confirm `agtermctl tree` (and `agtermctl tree --window <id>`) shows `idleMs` growing while idle and
  resetting on a keystroke — `idleMs` is `tree`-only (live). Confirm `autoFollowMs` reflects the setting
  (null when Disabled) on both `tree` and `agtermctl window.list`; note the `window.list` value is "as of
  last refresh" (cache-served fast path), so it may lag a just-changed setting until the next command.

**External system updates:** none — the control setting is GUI-only by design; no consuming project or
deploy config changes.

Smells pre-check: skipped — non-Go project.
