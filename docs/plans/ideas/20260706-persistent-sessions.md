# Persistent Sessions (opt-in built-in multiplexing)

> **STATUS: ON HOLD — do NOT implement.** This plan is design-complete and review-clean but is deliberately
> shelved pending a go/no-go decision. A dialectic analysis (see foot of file) found the feature technically
> sound but economically marginal for a solo-maintained project: it reverses a reasoned #66 "no", and its
> flagship benefits (remote survival, agent-survives-restart) are largely already met by the scriptable
> `--command` pattern and discussion #71's resume script. The near-free first move is to document the
> scriptable pattern instead. Kept accurate and ready in case real demand appears; not scheduled for build.

## Overview

Add **opt-in per-session persistence** to agterm: a session marked persistent runs its shell wrapped in
`zmx attach <name>` instead of a bare login shell, so the shell — with its scrollback and running
process — survives an agterm quit or crash, and (for a remote/ssh session) network drops and even a laptop
reboot, since the daemon lives on the host. (A LOCAL persistent session's daemon is a local process, so it
survives an app quit/crash but NOT a machine reboot — relaunch after a reboot gets a fresh shell.) Relaunch
reattaches the still-running zmx daemon and the session comes back live rather than as a fresh shell.

Persistence is **off by default**; the default "restore structure, fresh shells" behavior is unchanged.
It becomes a deliberate tool (a `--persist` flag, a control command, a menu/sidebar toggle), so agterm's
stated "a tmux-style backend is out of scope" stance holds — this is not a backend, it is an inside-the-PTY
wrapper the user opts into per session.

**Why this approach (vs discussion #66):** #66's tmux `-CC` control mode was declined because it needs a
PTY-less "feed bytes to a childless surface" API — a standing libghostty patch over the pinned
`GHOSTTY_REV`, i.e. a fork of the one subsystem agterm keeps dependency-clean. This design puts the
multiplexer (zmx) *inside* the PTY as the surface's child process. libghostty still owns a real PTY with a
real child (`zmx attach`), the C-callback single-owner/single-free contract is unchanged, the render tick
is unchanged — **no engine patch**. zmx is deliberately complementary (attach/detach + native scrollback,
explicitly no windows/tabs/splits — agterm already owns all of that), and its `minimum_zig_version` is
`0.15.2`, the exact zig `scripts/setup.sh` already installs for the ghostty build, so zmx is **built from
source** with the existing toolchain — no prebuilt binary in the chain.

Key benefits: local reattach after quit/reboot; remote-host survival for `ssh` sessions and agent
workflows; all with zero change to the libghostty bridge.

## Context (from discovery)

Files/components involved:
- **Model / persistence (host-free, `agtermCore`):** `Session.swift`, `Snapshot.swift`, `Workspace.swift`,
  `AppStore.swift` (the `Session`⟷`SessionSnapshot` mapping in `snapshot()`/`restore`), `PersistenceStore.swift`.
- **Control (host-free parse in `agtermCore`, side effect in app target):** `ControlDispatcher.swift`,
  `ControlProtocol.swift`, `ControlResolve.swift`; app-side `agterm/Control/ControlServer.swift`,
  `ControlServer+SessionActions.swift`, `ControlTargetResolver.swift`.
- **CLI (host-free, `agtermctlKit`):** `Commands.swift`, `SessionCommands.swift`.
- **Surface / bridge (app target):** `agterm/agtermApp.swift` (`makeSurface`, ~line 181),
  `agterm/Ghostty/GhosttySurfaceView.swift` (`config.command` build, ~line 629),
  `agterm/Ghostty/ForegroundProcess.swift`, `agterm/AppDelegate.swift` (quit-flush foreground capture,
  ~lines 206/212; launch/restore).
- **UI:** `agterm/Views/WorkspaceSidebar.swift`, `agterm/AppActions.swift`, `agterm/agtermApp+Menus.swift`.
- **Build:** `scripts/setup.sh`, `project.yml`.
- **Keep-in-sync docs:** `README.md`, `site/docs.html`, `site/index.html`, `agterm/Resources/agent-skill/`
  (`SKILL.md`, `reference.md`, `examples.md`, `troubleshooting.md`), `.claude/rules/control-api.md`.

Related patterns found:
- Surface command is set per-surface via `ghostty_surface_config.command` — the clean injection point for
  wrapping; no `command-wrapper` config key is needed.
- `SessionSnapshot` fields are all `Optional` for forward-compat (missing → default), with **no**
  `Snapshot.currentVersion` bump — the pattern the new `persistent` field follows.
- agterm already *fakes* persistence: `ForegroundProcess.command()` captures the pane's foreground argv at
  clean quit and re-runs it on restore (gated by `restoreRunningCommand`). For a persistent session zmx
  brings the real process back, so this path is **superseded** (must be skipped, not doubled).
- The control channel follows the dispatcher-first split: `ControlDispatcher.dispatch(_:)` owns
  parse/validate/response-shape in `agtermCore`; `ControlServer` supplies target resolution + side effects.
- macterm (thdxg/macterm, MIT) is the reference implementation for `ZmxClient`/`ZmxReaper`/`ZmxSocketBudget`/
  `ZmxSessionName`/`ZmxForegroundResolver`; its pure logic is directly adaptable.

Dependencies identified:
- New tool **zmx** (neurosnap/zmx, Zig, `minimum_zig_version = 0.15.2`), built from source and embedded in
  the bundle at `Contents/Resources/zmx/zmx`.

## Development Approach

- **Testing approach:** Regular (code first, then tests) — but tests are a **required deliverable of every
  task**, listed as separate checklist items, and must pass before the next task starts.
- Bottom-up: host-free `agtermCore` pure logic first (unit-tested with `swift test`), then app-target side
  effects, then control API, then build, then keep-in-sync docs.
- Complete each task fully before the next; small focused changes; maintain backward compatibility (an
  existing on-disk snapshot must still decode, and a non-persistent session must behave exactly as today).
- **CRITICAL: every task includes new/updated tests** covering success and error/edge cases.
- **CRITICAL: all tests pass before starting the next task.**
- **CRITICAL: update this plan file when scope changes during implementation.**

## Project Guardrails (HARD — verify against every task before marking complete)

These supplement CLAUDE.md and are the gate for marking any task complete:

- **`agtermCore` stays host-free:** no `import GhosttyKit`/`AppKit`/`Metal`, and **no CoreGraphics
  geometry** (`CGSize`/`CGPoint`/`CGRect`/`CGFloat`). Pure logic (naming, budget, reaper, ls-parser, model,
  dispatcher, CLI parse) lives here; the app target is the thin side-effect adapter.
- **Green tree after every change:** app builds (`make build`), `swift test` passes, `make lint`
  (`swiftlint --strict`, zero findings) passes.
- **File sizes:** source files < 1000 lines, test files < 2000. New zmx logic goes in **new** files rather
  than growing `Session.swift`/`AppStore.swift`; if a touched file approaches the limit, stop and ask
  before splitting (never bump the swiftlint limit).
- **Visibility:** `public` in `agtermCore`/`agtermctlKit` only where the app target or CLI actually calls
  it; otherwise keep it internal.
- **Comments:** lowercase except godoc on exported symbols; document only non-obvious *why*.
- **Keep-in-sync (HARD):** a user action isn't done until it is drivable from the control socket — the
  `session.persist`/`--persist` surface needs the `Command` case + dispatcher arm + `ControlServer` arm +
  `agtermctl` subcommand + round-trip/e2e tests, and the agent skill + README + website updated.
- **`CHANGELOG.md` is release-only — do NOT touch it in this feature work.**

## Testing Strategy

- **Unit tests (required per task):** host-free logic in `agtermCore`/`agtermctlKit` is fully unit-testable
  — `ZmxSessionName` derivation/parse, `ZmxSocketBudget` probe, `ZmxSessionListParser` + `ZmxReaper`,
  snapshot round-trip + forward-compat decode, `AppStore` inheritance/toggle, `ControlDispatcher` parse +
  response shape, `agtermctl` arg parsing. Place tests one-file-per-source-file in
  `agtermCore/Tests/agtermCoreTests/` and `agtermCore/Tests/agtermctlKitTests/`.
- **App-target logic** is kept injectable (a `ZmxClient` struct of closures with a `.noop` for tests, à la
  macterm) so the budget-gate/resolution decisions are unit-testable without spawning subprocesses.
- **XCUITest (`agtermUITests/`):** exercise the control round-trip (`session new --persist`, `session
  persist`, persistence reflected in `tree`/`status`). **Wrapping MUST be bypassed under test** (keyed on
  the isolated `AGTERM_STATE_DIR`) so a test run never orphans a zmx daemon — macterm hit exactly this.
- **e2e reattach** (create persistent session → quit the isolated dev instance → relaunch → assert the
  process/scrollback returned): high value but heavy and stateful; **starts as a documented manual
  verification** (Post-Completion), promoted to automated later if feasible.

## Progress Tracking

- mark completed items `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document blockers with ⚠️ prefix
- keep the plan in sync with actual work

## Solution Overview

A persistent session's surface runs `zmx attach agterm-<hex12>` as its `config.command` (a shell-quoted
string, since `config.command` is a single `String`, not argv); zmx execs the real shell as its child. The
session **name** derives ONLY from the immutable `Session.id` (`agterm-<hex12>`) — deliberately NOT from
the mutable workspace name/slug, so a workspace rename or a `moveSession` to another workspace does not
change the name and never orphans the running daemon. Only the **primary** and **split** panes are wrapped
(a split owns two names: `agterm-<hex12>` and `agterm-<hex12>-split`); scratch/overlay/quick-terminal are
ephemeral and are never wrapped. Lifecycle: **app quit detaches** (daemons live on), **explicit close kills** that session's
daemon, **launch reaps** zero-client `agterm-*` orphans no restored session claims. `ZMX_DIR` is pinned to
a short path **derived from the instance's `AGTERM_STATE_DIR`** (e.g. `/tmp/agterm-zmx-<short-hash>`, NOT a
bare per-uid dir) so each agterm instance has its OWN socket namespace — otherwise a second instance (your
deployed app + an isolated dev instance) whose reap `known`-set is empty of the first instance's sessions
would reap the first instance's detached daemons. The path stays under the `sun_path` 104-byte budget; over
budget → wrapping is bypassed (plain unpersisted shell, never a broken one). For persistent sessions the legacy
capture-and-rerun restore path is skipped (zmx owns the process). The flag is drivable via `session new
--persist`, `session persist <id> --on/--off`, a menu item, and a sidebar context-menu, and is reflected in
`tree`/`status` output.

## Technical Details

- **Name:** `agterm-<hex12>` where `hex12` = first 12 hex of `Session.id` (48 bits — collision-free at any
  realistic session count). **No workspace slug** — the name must be stable across rename/move, so it folds
  in only immutable state. Split pane name = primary name + `-split`. Worst-case ≤ ~25 bytes;
  `ZMX_DIR=/tmp/agterm-zmx-<short-hash-of-AGTERM_STATE_DIR>` keeps `<dir>/<name>` far under 104 AND scopes
  the daemon namespace per instance (see the reap-isolation note in Solution Overview).
- **argv → command:** `config.command` is a single `String` (strdup'd), and libghostty treats a set
  `command` as REPLACING the shell (mutually exclusive with `initial_input`). So the wrapper is fed as a
  shell-quoted string via `CommandRestore.shellQuotedLine([zmxPath, "attach", name])` (host-free, already
  exists) — this correctly quotes a zmx path containing spaces (a user-renamed `.app`).
- **New model fields:** `Session.persistent: Bool` (observed), `SessionSnapshot.persistent: Bool?`
  (Optional, no version bump), `Workspace.persistentDefault: Bool` + `WorkspaceSnapshot.persistentDefault: Bool?`.
- **Control:** `Command.sessionPersist(target, on: Bool)` + a `persist: Bool` option on the existing
  session-new command; response for `tree`/`status` gains a `persistent` field.
- **Build:** `ZMX_REV` pin in `setup.sh`; `zig build` → stage to `agterm/Resources/zmx/zmx` (gitignored);
  `project.yml` post-compile phase embeds it (mirrors the ghostty staging + `embed: false` discipline).

## What Goes Where

- **Implementation Steps** (`[ ]`): all code, tests, in-repo docs, build wiring.
- **Post-Completion** (no checkboxes): manual e2e reattach verification, dev-instance smoke test.

## Implementation Steps

### Task 1: zmx session identity — `ZmxSessionName` + wrapper command (agtermCore)

**Files:**
- Create: `agtermCore/Sources/agtermCore/ZmxSessionName.swift`
- Create: `agtermCore/Tests/agtermCoreTests/ZmxSessionNameTests.swift`

- [ ] add `ZmxSessionName` with `make(sessionID:)` → `agterm-<hex12>` (first 12 hex of the UUID) and
      `splitName(sessionID:)` → `agterm-<hex12>-split`, plus `hex12(_:)`, `maxByteCount`, and `isOwned(_:)`
      (a name matching the `agterm-` construction). **No workspace slug / no `make(workspaceName:...)`** —
      the identity MUST fold in only the immutable `Session.id`, never mutable workspace state
- [ ] add `ZmxAttach.wrapperCommand(executablePath:sessionName:userCommand:)` → the shell-quoted string
      `CommandRestore.shellQuotedLine([path, "attach", name] + userCommandArgv)` (`userCommand` empty for a
      plain shell; folding a `--command` in relies on zmx's `attach <name> [command...]` run-on-create), and
      `nil` when path is nil (unbundled / over budget → caller launches a plain shell)
- [ ] keep everything `public` only where the app target needs it; no AppKit/CoreGraphics imports
- [ ] write tests: name + split-name + hex derivation, `isOwned` (valid + foreign → false), `maxByteCount`,
      `wrapperCommand` nil-path, and a **path-with-spaces** case (quoted correctly so argv doesn't split),
      plus a **stability** test: the name is identical for the same `Session.id` regardless of any workspace
      name (simulating a rename/move)
- [ ] run `swift test` — must pass before next task

### Task 2: socket-path budget — `ZmxSocketBudget` (agtermCore)

**Files:**
- Create: `agtermCore/Sources/agtermCore/ZmxSocketBudget.swift`
- Create: `agtermCore/Tests/agtermCoreTests/ZmxSocketBudgetTests.swift`

- [ ] add the agterm pinned short-dir helper `agtermSocketDir(stateDir:)` → `/tmp/agterm-zmx-<short-hash>`
      where `<short-hash>` is a short stable hash of the instance's `AGTERM_STATE_DIR` (**per-instance**, so
      two coexisting instances never share a daemon namespace and can't cross-reap — see Solution Overview),
      and `socketDir(env:)` returning a user-set `ZMX_DIR` if present else the per-instance pinned dir
      (trailing-slash trim). **Do not** replicate zmx's full `XDG_RUNTIME_DIR`/`TMPDIR` fallback chain —
      agterm pins `ZMX_DIR`, so the probe only needs to validate the pinned dir plus honor a user override;
      state that intent in the doc comment
- [ ] add `probe(env:)` returning a non-nil reason when `<dir>/<worst-case-name>` exceeds `sun_path` (104)
      minus a small safety margin, else nil
- [ ] write tests: per-instance dir derived from `AGTERM_STATE_DIR` (two different state dirs → two different
      socket dirs — the cross-reap isolation invariant), user `ZMX_DIR` override honored, under-budget nil,
      over-budget reason (long override dir), trailing-slash trim
- [ ] run `swift test` — must pass before next task

### Task 3: `zmx ls` parser + orphan selection — `ZmxReaper` (agtermCore)

**Files:**
- Create: `agtermCore/Sources/agtermCore/ZmxReaper.swift`
- Create: `agtermCore/Tests/agtermCoreTests/ZmxReaperTests.swift`

- [ ] add `ZmxSessionListParser.parse(_:)` → `[Entry(name, clients: Int?)]`, keeping only `agterm-` names,
      `clients == nil` for err/status lines (unknown, not zero)
- [ ] add `ZmxReaper.orphans(in:known:)` selecting `agterm-` entries with `clients == 0` not in `known`
      (spare unknown counts, attached sessions, foreign-prefix names, and claimed names)
- [ ] write tests: parse healthy/err/status/foreign lines; orphan selection spares unknown/attached/claimed,
      selects only zero-client unclaimed `agterm-` names; empty listing → no orphans
- [ ] run `swift test` — must pass before next task

### Task 4: model + persistence fields — `Session`/`SessionSnapshot`/`Workspace` (agtermCore)

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Session.swift`
- Modify: `agtermCore/Sources/agtermCore/Workspace.swift`
- Modify: `agtermCore/Sources/agtermCore/Snapshot.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift` (the `snapshot()`/`restore` mapping)
- Modify: `agtermCore/Tests/agtermCoreTests/PersistenceTests.swift` (the existing snapshot round-trip tests)

- [ ] add `Session.persistent: Bool = false` (observed) and `Workspace.persistentDefault: Bool = false`
- [ ] add `SessionSnapshot.persistent: Bool?` and `WorkspaceSnapshot.persistentDefault: Bool?` (Optional,
      **no** `Snapshot.currentVersion` bump), threaded through the memberwise init **and** the custom
      `init(from decoder:)` (`decodeIfPresent`) **and** `CodingKeys` in `Snapshot.swift` — the custom
      decoder is where forward-compat actually lands, not the memberwise init
- [ ] map `persistent`/`persistentDefault` in `snapshot()` (only emit when true, to keep legacy byte-identical
      output for non-persistent trees) and in `restore` (missing → false)
- [ ] write tests: round-trip with persistent set + unset; a legacy snapshot without the field decodes to
      false (forward-compat); non-persistent tree serializes byte-identically to before
- [ ] run `swift test` — must pass before next task

### Task 5: `AppStore` behavior — inheritance + toggle (agtermCore)

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift` (or `AppStore+Panes.swift`)
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreTests.swift`

- [ ] on session creation, seed `session.persistent` from the owning workspace's `persistentDefault` unless
      an explicit value is passed (the `--persist` path overrides)
- [ ] add `setPersistent(_ id: UUID, on: Bool)` on `AppStore` — the single seam the menu/control/CLI drive;
      set the flag and trigger a snapshot save (mid-life toggle = "persist from next spawn")
- [ ] add `setWorkspacePersistentDefault(_ id: UUID, on: Bool)` for the workspace default
- [ ] write tests: new session inherits workspace default; explicit override wins; `setPersistent` flips the
      flag + marks dirty; unknown id is a no-op
- [ ] run `swift test` — must pass before next task

### Task 6: control command — `session.persist` dispatcher + `ControlServer` conformance (agtermCore + app)

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlModes.swift` (`ControlSessionCreateOptions` gains `persist`)
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift` (the `ControlActions` protocol + dispatch)
- Modify: `agterm/Control/ControlServer.swift` and/or `agterm/Control/ControlServer+SessionActions.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherTests.swift`

- [ ] add `Command.sessionPersist(target:on:)` in `ControlProtocol` and a `persist: Bool` option on
      `ControlSessionCreateOptions` in `ControlModes.swift` (Codable round-trip)
- [ ] add the action method to the `ControlActions` protocol and handle parse/validate + response in
      `ControlDispatcher.dispatch(_:)`; add a `persistent` field to the `tree`/`status` response shaping
- [ ] **land the app-side `ControlServer` conformance in THIS task** (resolve target → `AppStore.setPersistent`,
      Task 5) — a protocol requirement without a conformer breaks the app build, so it cannot be deferred, or
      the `make build` gates of Tasks 9–11 become un-passable
- [ ] write tests (agtermCore): command Codable round-trip; dispatch validates target + on/off; new-command
      `persist` option parsed; `tree`/`status` response includes `persistent`
- [ ] run `make build` + `swift test` — must pass before next task

### Task 7: `agtermctl` CLI — `session persist` + `session new --persist` (agtermctlKit)

**Files:**
- Modify: `agtermCore/Sources/agtermctlKit/SessionCommands.swift`
- Modify: `agtermCore/Sources/agtermctlKit/Commands.swift` (registration, if needed)
- Modify: `agtermCore/Tests/agtermctlKitTests/CommandsTests.swift`

- [ ] add `agtermctl session persist <id> --on/--off` (mutually-exclusive flags, default resolution) mapping
      to the `sessionPersist` command
- [ ] add `--persist` to `agtermctl session new`
- [ ] write tests: arg parsing for `persist --on`/`--off`, missing/invalid flag error, `new --persist` sets
      the option
- [ ] run `swift test` — must pass before next task

### Task 8: app-side zmx client — resolution + kill/ls (app target)

**Files:**
- Create: `agterm/Ghostty/ZmxClient.swift`
- *(No app-target `*Tests.swift` — `project.yml` has only the `agterm` app + `agtermUITests` targets; a
  `*Tests.swift` under `agterm/` would compile INTO the app binary, not run as tests. The pure decision
  logic is already unit-tested in `agtermCore` — Tasks 2/3. The live subprocess path is covered by the
  Post-Completion manual e2e.)*

- [ ] add `ZmxClient` as a struct of `@Sendable` closures (macterm shape): `executableURL()` (bundled binary
      via `Bundle.main.url(forResource:"zmx", subdirectory:"zmx")`, gated by `ZmxSocketBudget.probe`),
      `isBundled()`, `killSession(name)`, `listSessionsWithClients()`, plus a `.noop`
- [ ] implement the subprocess runner (bounded timeout, drained pipes) and `.live` with a once-probed
      budget gate; pin `ZMX_DIR` (the per-instance short dir from `agtermSocketDir(stateDir:)`, Task 2) on
      every spawned subprocess so this instance's daemons/reaps never touch another instance's namespace
- [ ] scrub inherited `ZMX_SESSION` at startup so an agterm launched from inside a persistent shell doesn't
      leak its parent's session identity
- [ ] keep `ZmxClient` thin and injectable so the *decision* logic stays in `agtermCore`; parse `ls` output
      via the Task 3 `ZmxSessionListParser`
- [ ] run `make build` + `swift test` — must pass before next task

### Task 9: wrap the surface command for persistent sessions (app target)

**Files:**
- Modify: `agterm/agtermApp.swift` (`makeSurface` at :181 AND `makeSplitSurface` at :306 — the split pane
  is a separate factory and needs the `-split` name)
- Modify: `agterm/Ghostty/GhosttySurfaceView.swift` (command build path, if needed)

- [ ] in `makeSurface`, when `session.persistent` and `ZmxClient.executableURL()` is available, set
      `config.command` to `ZmxAttach.wrapperCommand(...)` (the shell-quoted string, Task 1) for the primary
      name; else unchanged (plain shell)
- [ ] mirror in `makeSplitSurface` using the `-split` name
- [ ] guard the whole wrap behind the budget gate: over budget → plain unpersisted shell (no broken session)
- [ ] **`--command` under persistence — RESOLVED:** zmx's CLI is `attach <name> [command...]` ("Attach to
      session, creating if needed"), so the user command folds directly into the wrapper:
      `config.command = shellQuotedLine([zmx, "attach", name] + userCommandArgv)`. On first create zmx runs
      that command; on reattach the `[command...]` is ignored (the session already exists) — exactly the
      "run once, reattach thereafter" semantic wanted. This sidesteps the `config.command`/`initial_input`
      mutual-exclusion entirely (no `initial_input` needed). Note the semantic in docs (Task 16): under
      persistence the command runs as a child of zmx's shell, so its exit returns to the zmx prompt rather
      than closing the session (unlike a non-persistent `--command`, which exec-replaces the shell and closes
      on exit)
- [ ] add a targeted test where feasible (the wrap decision is the pure `wrapperCommand` from Task 1; assert
      the factory selects the primary vs `-split` name); otherwise document coverage via the Task 16 e2e
- [ ] run `make build` + `swift test` + `make lint` — must pass before next task

### Task 10: lifecycle — detach on quit, kill on close, reap on launch (app target)

**Files:**
- Modify: `agterm/AppDelegate.swift` (launch reap; quit = detach, i.e. do NOT kill persistent daemons)
- Modify: `agterm/Control/ControlServer+SessionActions.swift` and/or the `AppStore` close path (kill on close)

- [ ] on explicit session close / split-pane close, call `ZmxClient.killSession` for that session's name(s)
- [ ] on app quit, DETACH — ensure persistent daemons are left running (no kill sweep for them)
- [ ] ⚠️ **multi-window reap timing:** agterm is multi-window with async claim-queue window restoration, so
      restored persistent sessions are all zero-client at launch and NOT all restored yet. Build the `known`
      set from the **persisted library index across ALL windows** (every window's snapshot), NOT from
      live-restored sessions, and run reap only AFTER that complete set is assembled — otherwise daemons of
      persistent sessions in not-yet-restored windows get killed. Reap kills only zero-client unclaimed
      `agterm-*` (`ZmxReaper.orphans`, Task 3)
- [ ] **cross-instance safety:** because `ZMX_DIR` is per-instance (Task 2/8), the reap enumerates only THIS
      instance's daemons and can never touch another instance's — so a dev instance can't reap the deployed
      app's detached sessions. Verify `listSessionsWithClients` runs against the per-instance `ZMX_DIR`
- [ ] write tests: the all-windows `known`-set construction from a multi-window persisted snapshot (host-free
      helper in agtermCore); reaper wiring uses the already-tested selection
- [ ] run `make build` + `swift test` + `make lint` — must pass before next task

### Task 11: restore interaction — skip capture-and-rerun for persistent sessions (app target)

**Files:**
- Modify: `agterm/AppDelegate.swift` (quit-flush foreground capture, ~lines 206/212)
- Modify: `agterm/agtermApp.swift` (restore re-run gate) and/or `agtermCore/Sources/agtermCore/CommandRestore.swift`

- [ ] skip the `ForegroundProcess.command` capture at quit for persistent sessions (nothing to re-run — zmx
      owns the process)
- [ ] skip the `initialCommand`/`foregroundCommand` re-run on restore for persistent sessions (prevents a
      double-run on reattach)
- [ ] write tests: the gating predicate (host-free, e.g. in `CommandRestore`) — persistent → skip, plain →
      unchanged behavior
- [ ] run `make build` + `swift test` + `make lint` — must pass before next task

### Task 12: control server — `session new --persist` wiring + `tree`/`status` reflection + e2e (app target)

**Files:**
- Modify: `agterm/Control/ControlServer+SessionActions.swift`
- Modify: `agtermUITests/` (control round-trip case)

*(The `session.persist` side-effect conformance already landed in Task 6 to keep the build green — this task
adds only the create-time flag + response reflection + the XCUITest.)*

- [ ] wire the `ControlSessionCreateOptions.persist` flag through session creation so `session new --persist`
      marks the new session persistent
- [ ] populate the `persistent` field in the `tree`/`status` responses from the live session
- [ ] add an `agtermUITests` control round-trip: `session new --persist` then `session persist --off`, assert
      `tree`/`status` reflect it — with wrapping **bypassed** under the isolated `AGTERM_STATE_DIR` (so a
      test run never orphans a zmx daemon)
- [ ] run `make build` + `swift test` + `make lint` — must pass before next task

### Task 13: UI — sidebar indicator + menu + context-menu toggle (app target)

**Files:**
- Modify: `agterm/Views/WorkspaceSidebar+RowRendering.swift` (the pin/anchor indicator on the row)
- Modify: `agterm/Views/WorkspaceSidebar+ContextMenu.swift` (the context-menu toggle item)
- Modify: `agterm/AppActions.swift` (the toggle action calling `AppStore.setPersistent`)
- Modify: `agterm/agtermApp+Menus.swift` (menu item "Keep Session Running")

- [ ] show a small pin/anchor indicator on a persistent session's sidebar row
- [ ] add a sidebar context-menu item and a menu-bar item toggling persistence via the `AppActions`→
      `AppStore.setPersistent` seam (the same seam control/CLI drive — no drift)
- [ ] add/extend an `agtermUITests` case toggling persistence from the menu and asserting the flag via
      `agtermctl`/`tree`
- [ ] run `make build` + `swift test` + `make lint` — must pass before next task

### Task 14: foreground resolver for persistent sessions — `ZmxForegroundResolver` (app target) — REQUIRED for v1

**Files:**
- Create: `agterm/Ghostty/ZmxForegroundResolver.swift`
- Modify: `agterm/Ghostty/ForegroundProcess.swift` (route through the resolver for persistent sessions)
- Create: `agtermCore/Sources/agtermCore/ZmxLeaderParser.swift` + test (the pure `zmx ls`→leader-pid parse)

- [ ] **NOT deferrable** — `ControlServer.buildTree` feeds `ForegroundProcess.command` (the pane's immediate
      child) into the control tree's `foreground` field (`ControlServer.swift:377-384`,
      `ControlProtocol.swift:253-256`). For a persistent session that child is `zmx attach`, so without this
      resolver `agtermctl tree`/`status` misreports the LIVE foreground as the wrapper for exactly the
      long-running/agent sessions this feature targets — violating the "control API is first-class" norm. So
      the resolver ships in v1, not later
- [ ] add the pure `zmx ls`→`name → session-leader pid` parser in `agtermCore` with unit tests
- [ ] in `ForegroundProcess`, when the query targets a persistent session, resolve the real foreground
      process past the `zmx attach` client via the leader pid (agent-status hooks are unaffected — they run
      inside the hosted shell and already report correctly)
- [ ] write tests: leader-pid parse (healthy/err lines); resolver picks leader over client pid
- [ ] run `swift test` + `make build` + `make lint` — must pass before next task

### Task 15: build — compile, embed & **code-sign** zmx from source (build)

**Files:**
- Modify: `scripts/setup.sh` (pin `ZMX_REV`, `zig build` with the keg zig 0.15.2, stage the built binary
  under `agterm/Resources/zmx/zmx`)
- Modify: `project.yml` (`postBuildScripts` phase that stages **and code-signs** the nested binary)
- Modify: `.gitignore` (ignore `agterm/Resources/zmx/`)

- [ ] add an idempotent zmx build step to `setup.sh` (present-check skip like the ghostty step; clone at
      `ZMX_REV`, `zig build`, stage the binary), reusing the already-installed `zig@0.15`
- [ ] gitignore the staged binary (build output, never committed, like `GhosttyKit.xcframework`)
- [ ] ⚠️ **zmx is a nested Mach-O executable, not a resource** — embed it via a `project.yml`
      `postBuildScripts` step patterned on the existing **agtermctl** phase (`project.yml:114-142`): copy
      into `$CODESIGNING_FOLDER_PATH/Contents/Resources/zmx/zmx`, then
      `codesign --force --options runtime --sign - "$dest"` BEFORE Xcode's automatic outer/`--deep` re-sign.
      `ENABLE_HARDENED_RUNTIME: YES` applies to Debug too, and `release.sh` notarizes — an unsigned nested
      binary would break the outer seal / notarization and may fail to launch. Do **not** model this on the
      ghostty resources/xcframework pattern (neither is a signed nested executable). No separate
      `embed-zmx.sh` — fold it inline like agtermctl
- [ ] verify `Bundle.main.url(forResource:"zmx", subdirectory:"zmx")` resolves at runtime and the nested
      binary is signed (`codesign -dv` on the bundled `zmx`)
- [ ] verify `make build` produces a bundle with a signed `Contents/Resources/zmx/zmx` and a persistent
      session actually wraps (manual dev-instance check, isolated `AGTERM_STATE_DIR` + short
      `AGTERM_CONTROL_SOCKET`)
- [ ] run `make build` — must pass before next task *(build wiring; no unit test surface — covered by the
      dev-instance check above and the Post-Completion e2e)*

### Task 16: keep-in-sync docs — README, website, agent skill, rules (docs)

**Files:**
- Modify: `README.md`
- Modify: `site/docs.html`, `site/index.html` (features + `softwareVersion` JSON-LD)
- Modify: `agterm/Resources/agent-skill/SKILL.md`, `reference.md`, `examples.md`, `troubleshooting.md`
- Modify: `.claude/rules/control-api.md`

- [ ] document persistent sessions in `README.md` (what it is, `--persist`, `session persist`, lifecycle,
      the zmx build) and mirror into `site/docs.html`; update `site/index.html` features + `softwareVersion`
- [ ] update the bundled agent skill: the new `session.persist` command + `session new --persist` + `tree`/
      `status` `persistent` field, and bump the command count **50 → 51** (`SKILL.md` "Command summary (50
      commands)"); add an example + troubleshooting notes (persistence-off fallback, socket-budget bypass,
      and the `--persist --command` semantic decided in Task 9)
- [ ] add a `.claude/rules/control-api.md` note for the new command + the zmx wrap boundary
- [ ] no `CHANGELOG.md` edits (release-only)
- [ ] no code change → no new unit tests; verify the documented command count matches the actual dispatch
      catalog (grep the command list)

### Task 17: Verify acceptance criteria

- [ ] verify all Overview requirements: opt-in flag persists; persistent session wraps in zmx; quit→relaunch
      reattaches (process + scrollback); explicit close kills the daemon; crash orphans are reaped; over-budget
      falls back to a plain shell; non-persistent sessions behave exactly as before
- [ ] verify edge cases: split (two names), `--command` session, workspace-default inheritance, legacy
      snapshot decode
- [ ] run full `swift test` (agtermCore + agtermctlKit) — all green
- [ ] run the `agtermUITests` control/persistence cases — green
- [ ] `make build` clean, `make lint` (`--strict`) zero findings

### Task 18: Update documentation and finalize

- [ ] final pass over `README.md`/website for accuracy
- [ ] update `CLAUDE.md` / add a `.claude/rules/*.md` note if a new persistent-session pattern warrants it
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion
*Items requiring manual intervention or external systems — no checkboxes, informational only*

**Manual verification:**
- **e2e reattach (headline):** launch an isolated dev instance
  (`open -n --env AGTERM_STATE_DIR=<tmp> --env AGTERM_CONTROL_SOCKET=/tmp/agterm-ps.sock <Debug>/agterm.app`),
  create a persistent session running a long-lived process (`top`/`tail -f`), quit the instance by PID,
  relaunch, confirm the same process + scrollback returned. Repeat once with a split.
- **remote survival:** a persistent session running `ssh host` where the remote shell runs `zmx attach`;
  drop the connection / sleep the laptop; confirm the remote process survives and reattaches.
- **budget fallback:** force a long `ZMX_DIR` and confirm a persistent session silently falls back to a
  plain shell rather than failing to spawn.
- Do NOT run these against the deployed `~/Applications/agterm.app` (the live daily driver) — isolated dev
  instance only.

---

Smells pre-check: skipped — non-Go project (Swift; no `go.mod`, so the Go signature/smells rule injections do not apply).

Plan-review pass (auto): 2 critical + 4 major + 4 minor findings applied before commit —
(1) reattach identity decoupled from mutable workspace slug → id-only `agterm-<hex12>` (was silent
data-loss on rename/move); (2) `ControlServer` conformance moved into Task 6 so the app build stays green
through Tasks 9–11; (3) nested zmx binary now code-signed via the `agtermctl` `postBuildScripts` pattern
(not the ghostty resources pattern); (4) reap `known`-set built across all windows' persisted snapshots;
(5) argv→`config.command` via `CommandRestore.shellQuotedLine` (path-with-spaces safe); (6) dropped the
misplaced app-target test file (no app unit-test bundle); plus corrected test-file names, added
`ControlModes.swift`/`makeSplitSurface`/`WorkspaceSidebar+*` to the right tasks, trimmed the socket-dir
resolution chain, and flagged the `--persist --command` / `initial_input` mutual-exclusion as a Task 9
decision gate.

Dialectic pass (parallel PRO/CON agents + code verification): the feature is technically sound and the #66
engine-patch blocker is genuinely dead, but the CON case is stronger on economics — it reverses a reasoned
2026-07-02 "no" whose second reason ("a rendering nicety rather than a new capability"; remote survival
"already works today") the zmx mechanism does not change, and the flagship agent case is separately solved
near-free by discussion #71's `claude --resume` script. Verdict: hold; document the scriptable pattern
first. Four corrections were applied to keep the plan accurate regardless:
(1) **Task 9 `--persist --command` RESOLVED** — zmx's `attach <name> [command...]` supports run-on-create,
so the user command folds into the wrapper (no `initial_input` conflict);
(2) **Task 14 foreground resolver de-deferred to REQUIRED** — without it `agtermctl tree`/`status`
misreports the live foreground as `zmx attach` for persistent sessions (verified `ControlServer.swift:377-384`
→ `ControlProtocol.swift:253-256`), violating the first-class-control-API norm;
(3) **per-instance `ZMX_DIR`** (derived from `AGTERM_STATE_DIR`, not per-uid) — closes a cross-instance
data-loss path where an isolated dev instance's reap would kill the deployed app's detached daemons;
(4) **reboot wording corrected** — a LOCAL persistent session survives an app quit/crash but NOT a machine
reboot (only the remote/ssh case survives reboot, and that already works today).
