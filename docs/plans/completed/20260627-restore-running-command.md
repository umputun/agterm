# Restore Running Command on Restart

## Overview

Today agterm restores each session pane's working directory on relaunch, but a pane that was running a program (a gate `ssh`, `tail -f`, `top`) comes back as a plain shell. This feature optionally **re-runs the command each pane had in the foreground** at the last clean quit. Opt-in via a Settings ▸ General toggle, default off.

Approach: **re-run** (capture the foreground argv at quit, re-spawn on launch). NOT the daemon/keep-alive model (Forge/Zmx run a sidecar daemon so PTYs survive — out of scope), and NOT name-only re-run (the one prior-art fork, `ryanbreen/ghostty-with-sessionexplorer`, drops arguments). We capture the **full argv** so `ssh gate -t "ssh server"` re-runs intact.

**Scope honesty (important):** a single `ghostty_surface_foreground_pid` + `KERN_PROCARGS2` capture restores ONE process's argv. That equals the typed command line only for a single-process command. A typed pipeline (`tail -f x | grep y`, multiple processes in the foreground group) or a compound line (`a; b`, several processes over time) will NOT restore faithfully — at best one segment re-runs. The motivating single-process case (gate `ssh`) works; the docs (Task 9) must state this limitation rather than overstate "restores whatever was running."

Key benefit: gate `ssh` sessions reconnect automatically after a restart; any single long-runner (`tail`/`top`/`watch`) comes back. Stateful programs (editors, REPLs) are deliberately skipped (re-running them is lossy/harmful).

## Context (from discovery)

- **Project**: native macOS terminal, Swift 6 + SwiftUI + AppKit on libghostty. Host-free model/persistence/pure logic in the `agtermCore` SwiftPM package (`swift test`); app target owns SwiftUI + the libghostty C boundary + Darwin syscalls.
- **Files involved** (verified against the real code):
  - `agtermCore/Sources/agtermCore/Snapshot.swift` — `SessionSnapshot` (`:59`, `splitCwd` at `:76`), the persisted shape.
  - `agtermCore/Sources/agtermCore/Session.swift` — `Session` fields (`initialCommand` ~`:99`, `scratchCommand`, `splitCwd`/`initialSplitCwd`).
  - `agtermCore/Sources/agtermCore/AppStore.swift` — `snapshot()` (`:639`, captures `splitCwd` at `:644`) and `restore(from:)` (`:661`, seeds `initialSplitCwd` at `:668`).
  - `agtermCore/Sources/agtermCore/AppSettings.swift` — `Bool?` settings + the hand-written public `init` (`:81-103`); `notificationsEnabled` pattern.
  - `agterm/SettingsModel.swift` — the `set…(_:) { settings.x = value; persistAndApply() }` setters (`:77-85`).
  - `agterm/Views/SettingsView.swift` — General-tab `Toggle` + binding via `model.setNotificationsEnabled` (`:99-102`).
  - `agterm/agtermApp.swift` — the surface factories `makeSurface`/`makeSplitSurface`/`makeScratchSurface` (`initialCommand` passed at `:442`; `scratchCommand` read-then-nil run-once clear at `:597-599`) and the quit-flush (`AppDelegate.applicationWillTerminate`, per `.claude/rules/windows.md`).
  - `agterm/Ghostty/GhosttySurfaceView.swift` — `config.command` at `:428` (raw, argv-style exec); `readSelection()`/`inject(text:)` surface-method precedent; add `config.initial_input`.
  - `GhosttyKit.xcframework/.../ghostty.h` — `ghostty_surface_foreground_pid` (`:1117`), `config.working_directory` (`:473`), `config.initial_input` (`:477`).
  - `agtermUITests/MultiWindowUITests.swift` — `relaunch()` + `testReopenAllAfterQuit` (`:217-358`) prove `XCUIApplication.terminate()` fires `applicationWillTerminate` and persists state — the quit→relaunch precedent for the e2e.
- **Patterns**: host-free pure utilities in enum namespaces (`ConfigPaths`, `SettingsCatalog`); settings are `Bool?` with nil = default; one test file per source file; the eager deck spawns every session surface at launch; run-once command fields are read-then-nil'd in the factory.

## Development Approach

- **testing approach**: Regular (code first, then tests in the same task).
- complete each task fully before the next; small, focused changes.
- **CRITICAL: every task with code MUST include new/updated tests** (success + error/edge), as SEPARATE checklist items.
- **CRITICAL: all tests must pass before the next task.** Tasks 5 and 6 (live syscall / `initial_input`) cannot be unit-tested host-free; their decision logic is fully covered host-free in Task 2, and their live behavior is covered by the Task 7 e2e which immediately follows — treat 5+6+7 as one verification unit.
- host-free tests: `cd agtermCore && swift test`; app builds: `make build`; XCUITest: `xcodebuild test … -only-testing:…`.
- backward compatible: a snapshot without the new fields decodes to nil (plain shell); inert when the flag is off.

## Testing Strategy

- **unit tests (host-free, `agtermCore`)** carry the logic: snapshot round-trip + legacy-decode (Task 1); `KERN_PROCARGS2` blob parse incl. exec-path NUL-padding + truncated input (Task 2); argv→shell-quoted-string join; the denylist + known-shell(+`$SHELL`) predicates; `AppSettings` decode/default + init.
- **app-side / XCUITest** (Task 7): the live capture (`sysctl` + a real foreground process) and the quit→relaunch→re-run cycle, driven through a counter file whose growth proves re-run; plus a flag-off case asserting no growth.
- treat the XCUITest with the same rigor as unit tests (must pass before the next task).

## Progress Tracking

- mark completed items `[x]` immediately; add discovered tasks with ➕, blockers with ⚠️; keep the plan in sync with actual work.

## Solution Overview

Three slices: **persist** (host-free snapshot field), **capture** (app-side, at clean quit), **restore** (app-side, on launch, flag-gated). All decision logic (parse argv, known-shell, denylist, shell-quote) lives host-free in a new `CommandRestore` namespace, fully unit-tested; the app target does only the libghostty C-boundary calls and Darwin syscalls, deferring every judgement to `CommandRestore`.

Re-run uses `config.initial_input` (feed the quoted command + newline to the restored login shell), NOT `config.command`: the latter replaces the shell so the session closes on exit (the `--command` behavior at `GhosttySurfaceView.swift:428`); `initial_input` runs the command INSIDE the restored shell, so exit returns to a prompt and the command shows in scrollback — the natural "restore" feel.

## Technical Details

New host-free `enum CommandRestore` (`agtermCore`, static funcs, mirroring `ConfigPaths`):
- `parseProcArgs(_ data: Data) -> [String]?` — parse a `KERN_PROCARGS2` blob (`[argc:Int32][exec_path\0][\0…padding…][argv0\0…argvN\0][env…]`) into `[argv0…argvN]`; skip the exec-path + its NUL padding; nil on truncated/malformed.
- `isKnownShell(_ basename: String, extra: String?) -> Bool` — basename ∈ {`zsh`,`bash`,`sh`,`fish`,`dash`,`ksh`,`tcsh`,`csh`} OR == `extra` (the user's `$SHELL` basename, passed app-side).
- `shouldRestore(argv: [String]) -> Bool` — false when argv empty OR `argv[0]` basename ∈ the denylist {`vim`,`nvim`,`vi`,`view`,`nano`,`emacs`,`emacsclient`,`less`,`more`,`man`,`python`,`python3`,`node`,`irb`,`ipython`,`pry`,`lua`,`ghci`}.
- `shellQuotedLine(_ argv: [String]) -> String` — POSIX single-quote each arg (`'`→`'\''`), space-joined.

`SessionSnapshot` (Snapshot.swift) gains `var foregroundCommand: [String]?` and `var splitForegroundCommand: [String]?` (argv arrays, nil/absent for plain-shell panes). `Session` carries matching `@ObservationIgnored` fields; `AppStore.snapshot()` captures them, `AppStore.restore(from:)` seeds them.

`AppSettings` gains `var restoreRunningCommand: Bool?` (nil = off) + the public-init param. `SettingsModel` gains `setRestoreRunningCommand(_:)`.

App target: `enum ForegroundProcess { static func command(for surface:, shellBasename:) -> [String]? }` — `ghostty_surface_foreground_pid` → `sysctl KERN_PROCARGS2` → `CommandRestore.parseProcArgs`; returns nil when pid == 0 / sysctl fails / `argv[0]` basename is a known shell (`CommandRestore.isKnownShell(_, extra: shellBasename)`). `GhosttySurfaceView` gains an `initialInput: String?` init param → `config.initial_input` (strdup'd, same buffer-lifetime handling as `working_directory`). A surface method (`GhosttySurfaceView.foregroundCommand()`) mirroring `readSelection()` is an acceptable alternative; the `ForegroundProcess` enum is chosen because the view is already ~978 lines.

## What Goes Where

- **Implementation Steps** (`[ ]`): all code, tests, in-repo docs below.
- **Post-Completion** (no checkboxes): manual quit/relaunch with live gate sessions; the `make deploy` + relaunch to exercise it outside tests.

## Implementation Steps

### Task 1: Persist foreground command in the snapshot

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Snapshot.swift`
- Modify: `agtermCore/Sources/agtermCore/Session.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreTests.swift`

- [x] add `var foregroundCommand: [String]?` + `var splitForegroundCommand: [String]?` to `SessionSnapshot` (Codable, default nil), beside `splitCwd`
- [x] add matching `@ObservationIgnored var foregroundCommand: [String]?` / `splitForegroundCommand: [String]?` on `Session`
- [x] capture both in `AppStore.snapshot()` (`:639`); seed both back in `AppStore.restore(from:)` (`:661`)
- [x] write tests in `AppStoreTests.swift`, mirroring `splitCwdRoundTripsThroughSnapshot` (`:540`): both fields round-trip; a snapshot lacking the keys decodes to nil (legacy stays a plain shell)
- [x] run `cd agtermCore && swift test` — must pass before next task

### Task 2: CommandRestore host-free logic (parse / shell / denylist / quote)

**Files:**
- Create: `agtermCore/Sources/agtermCore/CommandRestore.swift`
- Create: `agtermCore/Tests/agtermCoreTests/CommandRestoreTests.swift`

- [x] create `enum CommandRestore` with `parseProcArgs(_:)`, `isKnownShell(_:extra:)`, `shouldRestore(argv:)`, `shellQuotedLine(_:)` (signatures in Technical Details)
- [x] implement `parseProcArgs` against the documented `KERN_PROCARGS2` layout — read `argc`, skip the exec path AND its trailing NUL padding before reading `argc` NUL-separated args; nil on truncated/short input
- [x] implement the predicates + POSIX single-quote join
- [x] write tests for `parseProcArgs`: a synthetic multi-arg blob WITH exec-path NUL padding between exec path and argv0 (the real-world gotcha); a truncated-argc blob; an empty blob → nil
- [x] write tests for `isKnownShell` (zsh/bash → true, ssh/vim → false, `extra` match → true), `shouldRestore` (ssh/top → true, `/usr/bin/vim` → false by basename, empty → false), `shellQuotedLine` (spaces, quotes, `$`, glob chars survive)
- [x] run `cd agtermCore && swift test` — must pass before next task

### Task 3: Add the restoreRunningCommand setting

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppSettings.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/SettingsStoreTests.swift` (the AppSettings/SettingsStore test file)

- [x] add `var restoreRunningCommand: Bool?` to `AppSettings` (nil = off), beside the other `Bool?` toggles
- [x] add the matching parameter to the hand-written public `init` (`:81-103`) so callers/tests can construct it
- [x] confirm `ghosttyConfigLines()` is unaffected (this flag drives app behavior, not ghostty config)
- [x] write tests: decode with the key true/false and absent (nil → off); Equatable round-trip unchanged
- [x] run `cd agtermCore && swift test` — must pass before next task

### Task 4: SettingsModel setter + General toggle

**Files:**
- Modify: `agterm/SettingsModel.swift`
- Modify: `agterm/Views/SettingsView.swift`
- Modify: `agtermUITests/SettingsUITests.swift` (or the existing settings-persistence UI test file)

- [x] add `func setRestoreRunningCommand(_ value: Bool?) { settings.restoreRunningCommand = value; persistAndApply() }` (`persistAndApply` no-ops the surface reload — not a ghostty key)
- [x] add a General-tab `Toggle("Restore running commands on restart", isOn: …)` bound via `model.setRestoreRunningCommand`, mirroring the `notificationsEnabled` binding (`:99-102`), with an `accessibilityIdentifier` `settings-restore-running-command`
- [x] add an honest caption: re-runs each pane's foreground command on relaunch; only single-process commands restore faithfully; stateful programs (editors, REPLs) start fresh and are skipped
- [x] write a UI test asserting the toggle persists into `settings.json` (mirror the existing notification-badge settings test)
- [x] run the focused Settings UI test — must pass before next task

### Task 5: Capture the foreground command at clean quit

**Files:**
- Create: `agterm/Ghostty/ForegroundProcess.swift`
- Modify: `agterm/agtermApp.swift` (the quit-flush in `AppDelegate.applicationWillTerminate`)

- [x] ⚠️ FIRST: empirically confirm what `ghostty_surface_foreground_pid` returns (foreground-group leader vs running leaf vs a backgrounded shell) with a throwaway probe in an isolated dev instance; record the finding — it decides whether `sh -c 'a; b'` captures `sh` or `b`. The Task 7 marker is designed to be robust either way, but capture must guard correctly.
- [x] add `enum ForegroundProcess { static func command(for surface:, shellBasename:) -> [String]? }` — `ghostty_surface_foreground_pid` → guard `pid != 0` → `sysctl KERN_PROCARGS2` (guard failure → nil) → `CommandRestore.parseProcArgs`; return nil when `CommandRestore.isKnownShell(argv[0].basename, extra: shellBasename)`
- [x] in the quit-flush, only when `settings.restoreRunningCommand == true`, walk each session's main + split surface and set `session.foregroundCommand` / `session.splitForegroundCommand` from `ForegroundProcess.command(for:shellBasename:)` (`shellBasename` = `$SHELL` basename), before the final snapshot/save
- [x] write tests: the decision seams are host-free and already covered (Task 2 `parseProcArgs`/`isKnownShell`); the live `sysctl` + at-prompt-captures-nothing path is covered by Task 7 (note this explicitly — no own-task host-free test is possible for the syscall)
- [x] run `make build` + `cd agtermCore && swift test` — must pass before next task

### Task 6: Re-run the command on restore via initial_input

**Files:**
- Modify: `agterm/Ghostty/GhosttySurfaceView.swift` (add `initialInput` init param → `config.initial_input`)
- Modify: `agterm/agtermApp.swift` (the `makeSurface` / `makeSplitSurface` factories)

- [x] add an `initialInput: String?` init param to `GhosttySurfaceView`; when non-nil, set `config.initial_input` (strdup'd, same buffer lifetime as `working_directory`)
- [x] in `makeSurface`/`makeSplitSurface`, when `settings.restoreRunningCommand == true` and the session's `foregroundCommand`/`splitForegroundCommand` passes `CommandRestore.shouldRestore`, pass `initialInput = CommandRestore.shellQuotedLine(argv) + "\n"`; else nil
- [x] CLEAR run-once IN THE FACTORY on the `Session` field (`let cmd = session.foregroundCommand; session.foregroundCommand = nil`), exactly mirroring the `scratchCommand` read-then-nil at `agtermApp.swift:597-599`, so a later in-session structural `save()` cannot re-persist and re-fire it
- [x] confirm the restored command runs INSIDE the login shell (exit returns to prompt), NOT via `config.command`
- [x] write tests: gating logic is host-free + already covered (Task 2 `shouldRestore`/`shellQuotedLine`); the live re-run is covered by Task 7 (note this — no own-task host-free test for `initial_input`)
- [x] run `make build` — must pass before next task

### Task 7: XCUITest — capture → relaunch → re-run cycle

**Files:**
- Create: `agtermUITests/RestoreCommandUITests.swift`

- [x] `testRestoreReRunsForegroundCommand`: seed `restoreRunningCommand=true` in the isolated `AGTERM_STATE_DIR` settings.json; start a session whose foreground is `sh -c 'printf x >> <COUNTER>; read _'` (blocks on the `read` BUILTIN, so the single foreground process IS the re-runnable `sh -c` shell — avoids the `sleep`/leaf-capture trap); confirm `<COUNTER>` has 1 byte; quit (`terminate()`), relaunch (per `MultiWindowUITests.relaunch()` `:217`), assert `<COUNTER>` grows to 2 bytes (proves the command re-ran)
- [x] `testRestoreOffDoesNotReRun`: flag off, same setup, relaunch, assert `<COUNTER>` stays 1 byte
- [x] follow `.claude/rules/ui-tests.md`: `launchForUITest`, isolated state dir, observable side effects; ASK before a full UI run, run only this class. (Drop a `vim` denylist e2e — it is unobservable and fully covered host-free by Task 2's `shouldRestore('/usr/bin/vim') == false`.)
- [x] run `xcodebuild test … -only-testing:agtermUITests/RestoreCommandUITests` — must pass before next task

### Task 8: Verify acceptance criteria

- [x] verify all Overview requirements: opt-in flag (default off), full-argv capture, denylist skip, re-run via `initial_input` returns to a prompt on exit
- [x] verify edge cases: legacy snapshot (no fields) → plain shell; flag off → no capture + no re-run; split pane captured independently; at-prompt/blank panes capture nothing (pid==0 / known-shell → nil)
- [x] run the full host-free suite: `cd agtermCore && swift test`
- [x] run the focused UI class: `xcodebuild test … -only-testing:agtermUITests/RestoreCommandUITests`
- [x] confirm keep-in-sync: no `AppActions`/`AppStore` user action and no `ControlSessionNode`/`tree --json` exposure were introduced, so control-API + agent-skill are correctly untouched (justified in Task 9)

### Task 9: [Final] Update documentation

**Files:**
- Modify: `README.md` (Settings ▸ General list + the persistence/"restore path" note)
- Modify: `.claude/rules/settings.md` (the new flag + capture/restore behavior)
- Move: this plan → `docs/plans/completed/`

- [x] document the toggle in README's Settings section; in the persistence bullet, note command-restore alongside path-restore AND the single-process limitation (pipelines/compound lines do not restore faithfully)
- [x] add the flag + the capture-at-quit / restore-via-`initial_input` behavior to `.claude/rules/settings.md`
- [x] state the keep-in-sync justification explicitly: NOT a control-API change because every `AppSettings` toggle (`notificationsEnabled`/`notificationBadgeEnabled`/`compactToolbar`/`mouseScrollMultiplier`/…) is GUI-only — there is no `settings.*` control surface (only `theme.set`/`config.reload` touch settings), so a one-off command for this single flag would be inconsistent scope creep
- [x] state the agent-skill is unchanged: the new `SessionSnapshot` field is internal (not added to `ControlSessionNode` / `tree --json`, no new command), so the 4th keep-in-sync surface needs no edit
- [x] `mkdir -p docs/plans/completed && git mv` this plan into `docs/plans/completed/`

## Post-Completion

*Items requiring manual intervention or external systems — informational only*

**Manual verification:**
- after `make deploy` + a real relaunch, confirm gate `ssh` sessions reconnect with the flag on; confirm a force-quit still restores sessions + cwd (no command re-run), matching the best-effort capture.
- sanity-check the launch storm: several gate sessions re-running `ssh` at once (key-based auth = fine; password prompts = N at once, expected).
- spot-check a pipeline/compound foreground (`a | b`, `a; b`) to confirm it degrades as documented (one segment, not the full line).

Smells pre-check: skipped — non-Go project
