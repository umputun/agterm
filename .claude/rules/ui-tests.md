---
paths:
  - "agtermUITests/**/*.swift"
---

## UI tests

- `agtermUITests/` is an XCUITest target that launches the real app and drives the sidebar (rename,
  close, move, drag, add-session) through the accessibility API — the coverage the host-free `agtermCore`
  unit tests can't provide.
  Run with `xcodebuild test -project agterm.xcodeproj -scheme agterm -destination 'platform=macOS'`.
- Tests pass `AGTERM_STATE_DIR` (a temp dir) via launch environment to isolate persistence;
  the app honors it in `agtermApp.restoredStore()`.
  The native `Open Directory…` panel is system UI, verified manually rather than in XCUITest.
- **Launch the app with `app.launchForUITest()` — never bare `app.launch()`.**
  Apple bug **FB11763863**: on macOS 15+/Xcode 16+ (incl.
  26) a SwiftUI `WindowGroup` app launched by another process (XCUITest,
  launchd) frequently **never auto-presents its window** — dock icon shows,
  no window, the scene's `.task`/`.onAppear` never fire, `NSApp.windows` stays empty,
  so elements exist in the AX tree (`waitForExistence` passes) but are un-hittable and every interaction
  silently no-ops.
  It is OS-version dependent, so the SAME app code "worked before" a macOS upgrade and breaks after.
  The fix lives in `AppDelegate.bringUITestWindowsForward` (UITest path):
  when no real window exists it fires a programmatic **reopen** — `NSWorkspace.shared.open(Bundle.main.bundleURL)`,
  the same event a dock click sends — and SwiftUI then creates the window.
  `XCUIApplication.activate()` / `NSApp.activate()` / `orderFrontRegardless()` / `.defaultLaunchBehavior(.presented)`
  do NOT help (the window is never created, not just un-focused).
  `launchForUITest()` (in `XCUIApplicationSidebarIsolation.swift`) feeds the `AGTERM_UITEST_FORCE_SIDEBAR_VISIBLE`
  sentinel via launch **environment** (NOT `launchArguments` — args trip a related variant),
  launches, and `activate()`s.
  The reopen re-triggers macOS state restoration, so the `Settings` window is marked **non-restorable**
  (`SettingsView`'s `NonRestorableWindow`) or a stale Settings window resurrects and steals key focus.
  To diagnose this class of bug, `NSLog` `NSApp.windows.count` on a timer and read it via `log show --predicate 'eventMessage CONTAINS "…"'`;
  `total=0` for seconds = "never created".
  See [[reference_swiftui-windowgroup-no-window-xcuitest]].
- **Open a Settings tab via the retrying `settingsControl(tab:control:)` helper,
  not a one-shot `app.buttons[tab].click()`.** The reopen can leave a half-open/non-key Settings window
  that silently drops the first tab click; `settingsControl` re-clicks each tick until the expected control
  is hittable, which is what makes the Settings tests non-flaky.
- **Add a UI test when you add UI functionality**
  — don't ship UI behavior with only `agtermCore` model-level unit tests.
  For behavior the accessibility tree can't observe (the Metal `GhosttySurfaceView`,
  transient non-persisted state), drive it through an observable side effect:
  e.g. the split test types `tty > <file>` into the focused pane and compares the written tty to verify
  which shell received the keystrokes and that focus follows.
- **Simulating a macOS light/dark flip: the `debug.appearance` control seam.**
  macOS XCUITest has no API to change the system appearance, so `AppearanceFlipUITests` drives the
  UI-test-only `debug.appearance` command (`light`|`dark`), which sets `NSApp.appearance` AND posts
  `.agtermSystemAppearanceChanged` directly, driving the REAL flip path (scheme sync → debounced
  zoom-preserving reload) end to end.
  Production follows the appearance via an app-level KVO observer on `NSApplication.effectiveAppearance`
  (`SystemAppearanceObserver`); the seam posts the notification itself so the test does not depend on
  whether KVO fires on an explicit `NSApp.appearance` set.
  The arm is refused outside an XCUITest launch and is keep-in-sync EXEMPT (see [[control-api]]).
  Set an explicit STARTING side first so the test is independent of the machine's appearance,
  assert the response's echoed side to prove the flip reached the app,
  and poll the seam's BARE (read) form — it reports the last-applied side — to prove the flip actually
  drove the reload (a suppressed flip leaves it on the old side).
  Gotcha: on the current libghostty pin `update_config` does NOT reset the runtime font zoom,
  so a wrongly-routed zoom-clearing flip only BLIPS the persisted `fontSize` nil for ~0.4 s before the
  surface's CELL_SIZE report re-persists it — assert zoom preservation by SAMPLING the snapshot
  continuously, never by one settled read (it would pass on the broken path).
- **Driving an OSC terminal title in a test (and reading it back).**
  `Session.oscTitle`/`subtitleDetail` are ephemeral (never persisted) and the second line renders as
  a SwiftUI `Text`, so test through observable side effects, not the snapshot.
  Set a title by typing/injecting `printf '\033]2;TITLE\007'; cat` into the session — the trailing `; cat`
  is **LOAD-BEARING**: a one-shot printf sets the title but the local shell returns to its prompt where
  the title is cleared again (the prompt cycle), so it reverts to the cwd basename;
  `cat` holds the foreground so no prompt redraw fires, mirroring why a real `ssh` keeps its title but
  a quick local printf "looks broken" (see [[libghostty]]).
  Type **LITERAL** `\033`/`\007` (Swift `"printf '\\033]2;…\\007'"`) so the SESSION shell's printf expands
  them — do NOT pre-expand to raw ESC/BEL bytes (e.g. a host-side `printf` building the string),
  which injects control bytes the shell's line editor reads as keystrokes and garbles the command (it
  can even fire history/ZLE widgets and run an unrelated history command).
  Read the result through an observable: **line 1** (displayName) via the `session-row` static-text **VALUE**
  (not label — see `SidebarUITests`); **line 2** (`subtitleDetail`) via the `palette-subtitle` AX id
  read as VALUE in the Go-to-Session palette.
  Gotcha: `FileManager.default.homeDirectoryForCurrentUser` resolves DIFFERENTLY in the XCUITest runner
  process vs the app, so assert a cwd second line against a stable marker like `/Users/`,
  NOT the runner's own home.
  (`agtermctl session.type` is the control-channel equivalent of the typed injection;
  `agtermctl tree --json` now carries the raw `title`, which an e2e can poll instead of reading the AX
  tree.
  See `SessionSubtitleUITests` + `ControlAPIUITests.testTreeExposesOscTitle`.)
- **Driving an `NSOutlineView` row drag from XCUITest needs three things,
  ALL load-bearing (see `ReorderUITests.dragRow`).** Getting any one wrong means the drag silently does
  nothing — `validateDrop`/`acceptDrop` never fire and the model never mutates:
  (1) **SELECT the source row first** (`from.click()` + a short run-loop drain) — the outline only begins
  a drag from the *selected* row, so dragging an unselected row (e.g. a middle row that wasn't the last
  one touched) never starts a drag session at all.
  This was the actual cause of a "downward drag doesn't work" red herring — the up-drag happened to drag
  the just-renamed (hence selected) row, the down-drag dragged an unselected one.
  (2) **Drag via `coordinate(withNormalizedOffset:)`, NOT element-to-element** — a row's AX element is
  the recycled `NSTextField` inside the cell, while the drag tracking lives in the outline;
  a coordinate drag targets the outline machinery directly.
  (3) **Use the mouse-native `click(forDuration:thenDragTo:withVelocity:thenHoldForDuration:)`,
  NOT the touch `press(forDuration:thenDragTo:)`** — `pressForDuration:` is the touch-events API and
  delivers an `NSDraggingInfo` only intermittently to AppKit.
  One drag per test launch is the reliable unit — a *second chained* native drag in the same method does
  not reliably re-start a drag session (it ends up testing XCTest's event injector,
  not the drop delegate), so cover a second direction in a separate `func test…` (fresh launch),
  never by chaining.
  To diagnose a non-delivering drag, `NSLog` from `validateDrop`/`acceptDrop` and read it with `log show --last 90s --predicate 'eventMessage CONTAINS "…"'`:
  *zero* events = the drag never started (selection/gesture problem); events present but the wrong `dest`
  = a drop-resolution bug in the delegate.
- **NEVER run XCUITests while the user is interacting with a handed-off dev build — it HIJACKS their
  screen.** XCUITest launches/activates app instances and synthesizes REAL keyboard + mouse events on
  the live screen (`typeText`/`typeKey`/`click` drive the actual cursor and focus),
  so a UI run while the user is trying a build types into their windows and steals focus — it interrupts
  their work, hard.
  When you hand the user a build to try ("try it", a launched demo instance),
  do NOT start any `xcodebuild test` (UI target) until they say they're done.
  Run UI tests BEFORE handing off, or AFTER the user is finished — never concurrently with their hands-on
  testing, and never "in parallel/background" (background only hides the output,
  not the on-screen event synthesis).
  Host-free `swift test` is fine anytime (no screen interaction).
- **Test cadence — ASK before a full UI run; don't default to it.**
  The host-free `cd agtermCore && swift test` is fast (~0.2 s) — always run it.
  The XCUITest suite is SLOW (~75 s for one class, ~460 s for all 77) and re-runs unaffected tests,
  so a full UI run is NOT a default pre-commit gate.
  For an isolated change, run ONLY the affected target/case (`xcodebuild test … -only-testing:agtermUITests/SplitUITests`,
  or a single method like `…/SidebarUITests/testRenameSession`).
  Before committing UI-affecting work, ASK which UI-test scope is wanted and RECOMMEND one:
  focused for self-contained changes; full only for foundational/cross-concern work (app launch,
  signing/bundle, the eager deck, window/scene wiring, shared chrome).
  Don't burn minutes re-running the whole suite when the change is self-contained.
- **A screen-occluding overlay app (HazeOver) makes `app.typeText`/`typeKey` fail with `Failed to synthesize event: Timed out while synthesizing event`**
  — a ~90 s hang that ends the test with NO `XCTAssert` failure (the keyboard event never reaches the
  covered window; the run log shows `Synthesize event` → `Failed: Timed out` ~64 s apart).
  It is ENVIRONMENTAL, not a test-logic or app bug: the SAME test passes in ~13 s once HazeOver is quit.
  Treat a `synthesize event` / `Unable to find hit point` timeout (as opposed to a real assertion failure)
  as an occlusion symptom — quit HazeOver and clear covered/minimized/Spaces windows,
  then re-run before suspecting the test or the fix.
  Distinct from FB11763863 (window never created → AX tree empty); here the window exists but is covered.
- **`XCUIApplication.terminate()` HARD-KILLS — it does NOT fire `applicationWillTerminate`.** A test
  that needs the app's graceful-quit path (anything in `applicationWillTerminate`:
  the restore-running-command capture, a quit-flush write) must quit with **⌘Q** (`app.typeKey("q", modifierFlags: .command)`
  then `app.wait(for: .notRunning, timeout:)`), NOT `terminate()`.
  The quit-confirm modal is auto-skipped under XCUITest (`ContentView.isUITestLaunch` → `.terminateNow`),
  so ⌘Q quits cleanly AND runs `applicationWillTerminate`.
  Verified by instrumenting the top of `applicationWillTerminate` to a `/tmp` file:
  empty under `terminate()`, written under ⌘Q.
  (`MultiWindowUITests` survives `terminate()` only because the open-set is also saved by in-session
  structural saves, NOT because the quit-flush ran.) This is the same write-to-a-temp-FILE diagnostic
  the project uses for launch-time values — `NSLog` doesn't reach the unified log from an `open -n`/XCUITest
  dev build.
- **`ghostty_surface_foreground_pid` returns the actual FOREGROUND process,
  not the session's shell.** Confirmed empirically (`tee <file>` → the captured pid/argv is `tee`,
  not `zsh`).
  The restore-running-command capture skips ONLY an IDLE shell-at-prompt (`CommandRestore.isIdleShell`:
  a known-shell argv0 with no payload argument, only `-flags`).
  A shell RUNNING something IS captured: a `#!/bin/sh` wrapper script (its foreground is `/bin/sh <script>`,
  the real-world `cld` claude-code bug) and a `sh -c '…'` BOTH carry a payload argument and are captured
  — only a bare `-zsh`/`/bin/zsh` prompt is dropped.
  `tee <file>` is still the cleanest e2e marker: it creates its output file on start and blocks reading
  the pty, so it's the live foreground at quit, and re-running it recreates the file (a delete-then-relaunch-then-exists
  cycle is the observable proof).
  `RestoreCommandUITests.testRestoreReRunsShellScriptWrapper` covers the shell-with-payload case via
  `sh -c 'tee …; true'` (a compound list keeps `sh` the foreground) — NOT an executable script file,
  since the runner writes its sandboxed temp dir and the app can't exec a script from there (a plain
  `tee` marker writes there fine, but exec is blocked).

