# Lifecycle, Security & Performance Review Fixes

## Overview
Address the real (non-by-design) findings from the external lifecycle/security/performance review of agterm. Each fix is surgical and independently shippable. The headline items: a retain-cycle memory leak on window close (L1), a control-socket read that can wedge the whole API (S1), a permission-mode regression on `~/.claude/settings.json` (S4), a data-loss footgun in the skill installer, a latent window-index migration landmine (C1), and a performance cluster of synchronous main-actor disk I/O and full multi-window fan-outs on hot repeatable paths (P2/P4/P5/P6).

Explicitly OUT OF SCOPE (by-design, confirmed against CLAUDE.md): S2 (unauthenticated socket — the intended scripting model), S3 expansion behavior (raw `{AGT_X}` is deliberate), P1 (eager-deck cap — intentional anti-flicker architecture), L6 (fire-and-forget custom commands), L4/L5 (quit teardown / cwd-on-quit-only). Only the S3 starter-example *doc nit* is in scope.

## Context (from discovery)
- Files/components involved:
  - App target: `agterm/agtermApp.swift` (surface factories), `agterm/Ghostty/GhosttySurfaceView.swift` (teardown, applyPwd/applyTitle), `agterm/Control/ControlServer.swift` (socket + window.resize/move arms), `agterm/AgentHooksInstaller.swift`, `agterm/SkillInstaller.swift`, `agterm/SettingsModel.swift` (theme preview + slider setters + starter keymap), `agterm/Views/SettingsView.swift` (sliders), `agterm/ContentView.swift` (`WindowRegistry.resize/move`).
  - Host-free core: `agtermCore/Sources/agtermCore/AppStore.swift` (save), `WindowLibrary.swift` (bootstrap/migration), `SkillInstall.swift` (mayOverwrite), `AgentHooksInstall.swift` (atomic write), plus new `Debouncer.swift` and `WindowGeometry.swift`.
- Related patterns found:
  - The split-ratio persistence already debounces with a cancel-and-reschedule `DispatchWorkItem` (~0.4 s) and accepts losing the last drag on force-quit — the precedent P2/P4 follow.
  - The theme picker already splits `persistAndApply` into `apply()` (no save) + `commitTheme()` (save only) — the precedent P5 follows for sliders.
  - `destroySurface()` already clears `configCStrings`/`envVars` — niling the callback closures there (L1) matches that pattern.
  - Host-free logic + "manually verified" app-side glue is the established split (CLIInstaller/AgentHooksInstaller). New logic goes host-free in `agtermCore` with unit tests; pure app-target glue is build+verification.
- Dependencies identified: `Debouncer` (Task 1) is consumed by P2 (Task 2) and P4 (Task 9). All other tasks are independent and can land in any order.

## Development Approach
- **Testing approach**: TDD (tests first) where the logic is host-free and unit-testable in `agtermCore`. Pure app-target glue (SwiftUI views, libghostty surface, POSIX socket, FileManager auth) has no unit host in this project, so those tasks carry an explicit build + manual-verification step instead — matching the codebase's existing "manually verified" convention for app-side installers/chrome. This is honest, not a coverage gap: every task that *can* be unit-tested is.
- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task (host-free unit tests where the logic is in `agtermCore`; a verification step where it is app-target-only — never silently skipped)
- **CRITICAL: all tests must pass before starting next task** — `cd agtermCore && swift test` must stay green; the app must build (`make build`)
- keep `agtermCore` host-free (no GhosttyKit/AppKit/Metal imports)
- maintain backward compatibility of persisted formats

## Testing Strategy
- **unit tests** (`cd agtermCore && swift test`): required for every task whose logic lives in `agtermCore` — Debouncer (Task 1), AppStore save scheduling (Task 2), WindowLibrary orphan recovery (Task 3), SkillInstall.mayOverwrite (Task 4), WindowGeometry clamp (Task 5), AgentHooksInstall mode-preserving write (Task 6). One test file per source file (`Foo.swift` → `FooTests.swift`).
- **verification** (build + run an ISOLATED dev instance, observe): for app-target-only tasks — L1 (Task 7), S1 (Task 8), P4 (Task 9), P5 (Task 10), P6 (Task 11), S3 (Task 12). Launch via `open -n --env AGTERM_STATE_DIR=<tmp> --env AGTERM_CONTROL_SOCKET=<tmp>/agterm.sock build/DerivedData/.../Debug/agterm.app` so it never touches the deployed daily driver. NEVER kill/relaunch the deployed `~/Applications/agterm.app`.
- **XCUITest** (`xcodebuild test ... -only-testing:agterm...`): run the affected target only for close-path regression after L1 (the surface teardown change) if desired — ASK scope before any full UI run; do not run UI tests while the user is interacting with a handed-off build.

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope

## Solution Overview
- **Leak (L1)**: nil the `store`-capturing surface callbacks in `destroySurface()` so the `store → session → surface → closure → store` island is broken at every close path. Chosen over `[weak store]` for being localized (one place, matches the existing resource-clearing in `destroySurface`); `teardown()` runs on every close path, so the cycle is reliably broken.
- **Socket wedge (S1)**: set `SO_RCVTIMEO` on each accepted connection so a stuck `read()` can't park the serial accept loop forever. Keeps the serial design (fine for personal scripting).
- **Perms (S4)**: a host-free mode-preserving atomic write — capture the target's `posixPermissions` before rewriting `settings.json` and its `.bak`, re-apply after — so a `chmod 600` secret file isn't widened to 0644.
- **Skill wipe**: disambiguate "destination dir absent" (safe to write) from "dir present without an agterm marker" (refuse) so a user's own `agterm` skill dir is never recursively wiped.
- **Migration (C1)**: when `windows.json` is unreadable/version-mismatched but `windows/<id>.json` files exist, RECOVER them into a fresh index (default names, all open) instead of resurrecting stale `workspaces.json` or seeding empty — preserving the user's sessions across a future schema bump.
- **Perf**: a small host-free `Debouncer` coalesces AppStore selection/font saves (P2) and theme-preview reloads (P4); sliders persist only on drag-end (P5); `applyPwd`/`applyTitle` skip equal writes so OSC re-emits don't churn the sidebar (P6); window.resize/move clamp via a host-free geometry helper.

## Technical Details
- `Debouncer` (`agtermCore`, `@MainActor`, Foundation-only): holds a `DispatchWorkItem?`; `schedule(after:_:)` cancels-and-reschedules, `flush()` runs the pending work synchronously and clears it, `cancel()` drops it. Tested deterministically via `flush`/`cancel` coalescing (no wall-clock assertions).
- `AppStore.save()` stays synchronous and now also cancels any pending scheduled save (so the quit-flush `saveAllOpen()` captures the latest). A new `scheduleSave()` debounces (~0.3 s) and is used by `selectSession` and `setFontSize` ONLY; structural mutations (add/close/move/rename/addWorkspace) keep calling `save()` immediately. Durability tradeoff: a SIGKILL within the debounce window loses only the last selection/font change — consistent with the documented split-ratio behavior.
- `WindowGeometry` (`agtermCore`, Foundation-only): `clampSize(_ requested: CGSize, min: CGSize, max: CGSize) -> CGSize` and `clampOrigin(_ requested: CGPoint, windowSize: CGSize, displayFrame: CGRect) -> CGPoint` (keeps the window at least partially on-screen). `ControlServer`/`WindowRegistry` supply the actual `NSScreen` bounds.
- `SkillInstall.mayOverwrite(directoryExists:existingSKILL:)`: `false` only when the dir exists and the SKILL.md is absent/unmarked; `true` when the dir is absent, or present with an agterm marker.
- `AgentHooksInstall`: `posixMode(ofFile:) -> NSNumber?` and `writeFile(_:toPath:posixMode:)` (atomic write + `setAttributes` when mode non-nil). `AgentHooksInstaller` reads the resolved target's mode once and applies it to both the `.bak` and the rewritten file.
- `SettingsModel`: a preview `Debouncer` wraps `previewTheme` so rapid palette nav/keystroke previews coalesce; `commitTheme()` flushes it then saves. New `previewBackgroundOpacity/Blur` (apply without save) back the sliders' live drag; the existing persisting setters fire on drag-end.

## What Goes Where
- **Implementation Steps** (`[ ]`): all code, unit tests, and the doc-nit fix below — achievable in this repo.
- **Post-Completion** (no checkboxes): manual verification scenarios for the app-target-only fixes, and optional XCUITest close-path regression.

## Implementation Steps

### Task 1: Add host-free `Debouncer` utility

**Files:**
- Create: `agtermCore/Sources/agtermCore/Debouncer.swift`
- Create: `agtermCore/Tests/agtermCoreTests/DebouncerTests.swift`

- [x] write `DebouncerTests`: scheduling twice then `flush()` runs only the latest action once; `cancel()` drops the pending action; `flush()` with nothing pending is a no-op
- [x] create `Debouncer` (`@MainActor`, Foundation-only): `schedule(after:_:)` cancel-and-reschedule, `flush()`, `cancel()`, holding a `DispatchWorkItem?`
- [x] run `cd agtermCore && swift test` — must pass before next task

### Task 2: Debounce AppStore selection/font saves (P2)

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreTests.swift`

- [x] add a `Debouncer` to `AppStore`; add `scheduleSave()` (debounced ~0.3 s → write) and make `save()` cancel any pending scheduled save before writing
- [x] switch `selectSession` and `setFontSize` to `scheduleSave()`; leave structural mutations (add/close/move/rename/addWorkspace, restore's no-save) unchanged
- [x] audit existing tests for any that assume `selectSession`/`setFontSize` persist synchronously; update them to flush via `save()` (legitimate behavior change — do NOT weaken the assertion, just sequence the flush)
- [x] write tests: `selectSession` then `save()` persists the selection; rapid `scheduleSave` then `save()` persists the LATEST snapshot (assert on loaded file CONTENT — the "coalesced to one write" count is covered by the Task 1 Debouncer test, since `PersistenceStore` is a value type with no write-counting seam; do not assert a count here without adding a spy)
- [x] run `cd agtermCore && swift test` — must pass before next task

### Task 3: Recover orphaned per-window files on index loss (C1)

**Files:**
- Modify: `agtermCore/Sources/agtermCore/WindowLibrary.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/WindowLibraryTests.swift`

- [x] add `recoverOrphanedWindows()`: enumerate `windows/*.json`, parse each filename as a UUID (skip non-UUID files), build a `WindowInfo(name: "window N")` per file, APPEND ALL of them to `windows` FIRST (⚠️ `loadStore(for:)` guards on `windows.contains(id)` at line ~285 — calling it before populating `windows` no-ops), THEN `loadStore` each, set the first as `frontmostWindowID`, `saveIndex()`; return false when no per-window files exist. Note: recovering every orphan as open means `consumeReopen()` opens them all on screen at once — acceptable for this rare recovery path
- [x] insert it in `bootstrap()` between `loadIndex()` and `migrateLegacy()` (so: valid index → use it; else orphaned files present → recover; else legacy → migrate; else seed)
- [x] write tests: corrupt/version-mismatched `windows.json` + present `windows/<uuid>.json` files → all windows recovered with sessions intact; no per-window files → still falls through to legacy migration; fresh install (nothing) → still seeds one window
- [x] run `cd agtermCore && swift test` — must pass before next task

### Task 4: Refuse wiping a user-authored skill dir (SkillInstaller)

**Files:**
- Modify: `agtermCore/Sources/agtermCore/SkillInstall.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/SkillInstallTests.swift`
- Modify: `agterm/SkillInstaller.swift`

- [x] change `mayOverwrite` to `mayOverwrite(directoryExists:existingSKILL:)`: refuse (`false`) when `directoryExists && existingSKILL` lacks the marker (incl. nil/unreadable SKILL.md); allow when dir absent, or marker present
- [x] update the `SkillInstaller.install` call site to pass `fm.fileExists(atPath: destination.path)`; keep the "different skill already there — left untouched" skip message
- [x] update `SkillInstallTests`: replace `mayOverwrite(nil) == true` with `mayOverwrite(directoryExists: false, existingSKILL: nil) == true`; add `mayOverwrite(directoryExists: true, existingSKILL: nil) == false`; keep the marker-present/absent cases
- [x] run `cd agtermCore && swift test` — must pass before next task

### Task 5: Clamp window.resize/window.move to sane/display bounds

**Files:**
- Create: `agtermCore/Sources/agtermCore/WindowGeometry.swift`
- Create: `agtermCore/Tests/agtermCoreTests/WindowGeometryTests.swift`
- Modify: `agterm/ContentView.swift` (`WindowRegistry.resize`/`move`)
- Modify: `agterm/Resources/agent-skill/reference.md`

- [x] write `WindowGeometryTests`: `clampSize` bounds an oversized request to max and a tiny one to min; `clampOrigin` keeps a window at least partially on-screen for an off-screen request and leaves an on-screen one unchanged
- [x] create `WindowGeometry` with `clampSize(_:min:max:)` and `clampOrigin(_:windowSize:displayFrame:)` (Foundation `CGSize`/`CGPoint`/`CGRect` — note: this adds the first CoreGraphics types to `agtermCore`; allowed by the host-free boundary (CG ≠ AppKit/Metal/GhosttyKit) and Foundation-provided on Darwin)
- [x] apply the clamp INSIDE `WindowRegistry.resize`/`move` (ContentView.swift ~1155–1185) — that is the ONLY place with the `NSWindow` and `window.screen`; `ControlServer.windowResize/Move` only resolve the id and cannot reach the screen bounds. Reconcile with `WindowRegistry.resize`'s EXISTING `window.minSize` clamp (line ~1157) — don't double-clamp; let `clampSize`'s `min` carry the floor. Keep the existing `> 0` guard in `ControlServer`
- [x] run `cd agtermCore && swift test` — must pass; `make build`
- [x] MANDATORY (keep-in-sync HARD): document the on-screen origin + size clamp in `agent-skill/reference.md` window.resize/move section (~line 125) — off-screen/oversized requests are now clamped, an observable control-API behavior change

### Task 6: Preserve file mode when rewriting settings.json + .bak (S4)

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AgentHooksInstall.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AgentHooksInstallTests.swift`
- Modify: `agterm/AgentHooksInstaller.swift`

- [x] write tests: `writeFile(_:toPath:posixMode:)` over a `chmod 600` temp file keeps mode 0o600; with nil mode a new file gets default mode; `posixMode(ofFile:)` returns the file's mode and nil when absent
- [x] add host-free `posixMode(ofFile:) -> NSNumber?` and `writeFile(_:toPath:posixMode:)` (atomic write + `setAttributes` when mode non-nil) to `AgentHooksInstall`; update `AgentHooksInstall`'s module doc comment, which currently says it owns "only string/JSON transforms, not filesystem work" (PersistenceStore already does FileManager I/O host-free, so FS in `agtermCore` is fine — just fix the now-stale doc)
- [x] in `AgentHooksInstaller`: KEEP `writePreservingSymlink`'s symlink resolution (so a dotfiles-managed `~/.claude/settings.json` symlink survives), resolve the target FIRST, read THAT resolved target's mode once, then write both the `.bak` and the merged `settings.json` to the resolved target through `writeFile(...posixMode:)` so both inherit the original restrictive mode. ⚠️ Do NOT write directly to the symlink path — that replaces the link with a standalone file
- [x] run `cd agtermCore && swift test` — must pass; `make build`

### Task 7: Break the window-close retain cycle (L1)

**Files:**
- Modify: `agterm/Ghostty/GhosttySurfaceView.swift`

- [x] in `destroySurface()`, nil every store-capturing callback at the VERY END of the method — AFTER the `overlayCodeFile`/`onExitCodeCaptured?(code)` block (after line ~512), NOT at the buffer-clear anchor: `onExit`, `onExitCodeCaptured`, `onFocusChange`, `onUserInputClearsStatus`, `onFontSizeChange`, `onSearchStart`, `onSearchEnd`, `onSearchTotal`, `onSearchSelected`. ⚠️ `onExitCodeCaptured` is INVOKED at line ~506 (reading the overlay exit status); niling it before that line silently breaks `session.overlay.result` / `agtermctl … --block` with no compile error and no test failure. Niling it after its use is safe — no libghostty callback fires once the surface is freed.
- [x] confirm `teardown()` reaches `destroySurface()` on every close path (session close, workspace remove, window close, pane-exit collapse, overlay/scratch close) — code review, no path frees the surface without it. Audit: all `teardown()` callers route through `destroySurface()` — AppStore.swift (closeSession ~192-195/~218-221, closeSplitPane ~258, closePrimaryPane ~281, closeOverlay ~339, closeScratch ~368), ContentView.swift willClose loop ~979-982, QuickTerminal.swift:71. The only `ghostty_surface_free` outside `destroySurface()` is the `deinit` safety net (line 188) — that is the deallocation path itself (closures release with the object), reached only once this cycle is broken, so it correctly needs no callback niling.
- [x] verified by code reasoning: `onExitCodeCaptured` nil'd only AFTER its line-~506 use (placed after the temp-file removal at line ~512), so the overlay exit-capture path is unchanged; build SUCCEEDED. Manual open/close + `agtermctl … --block` run on an isolated dev instance deferred to Task 13 verify / human (launching the app autonomously would hijack the screen). Memory-leak confirmation is by code reasoning + optional Instruments; no app-target unit host exists for an automated assertion
- [x] verified by code reasoning: XCUITest close-path run deferred to Task 13 verify / human (no autonomous UI run — synthesizes real keyboard/mouse events on the live screen)
- [x] gate: `cd agtermCore && swift test` stays green (655 tests) + `make build` succeeds (BUILD SUCCEEDED)

### Task 8: Read timeout on the control socket (S1)

**Files:**
- Modify: `agterm/Control/ControlServer.swift`

- [x] set `SO_RCVTIMEO` (a few seconds) on each accepted connection fd in `handleConnection`, alongside the existing `SO_NOSIGPIPE` — 5s timeval set right after `SO_NOSIGPIPE`
- [x] confirm a timed-out `read()` returns an error path that closes the connection and returns control to `accept()` (the loop keeps serving); `readLine` already treats a non-`EINTR` `n < 0` (incl. `EAGAIN`) as end-of-read — confirmed by code reasoning: SO_RCVTIMEO → read returns -1/EAGAIN → EAGAIN ≠ EINTR so readLine falls to `return nil` (no retry) → handleConnection writes "request too large or read failed" + `defer { close(conn) }` → acceptLoop resumes. No readLine change needed
- [x] verify (build + isolated dev instance): a client that connects and sends nothing is dropped after the timeout and subsequent `agtermctl --socket <tmp> tree` still responds (no permanent wedge). App-target socket glue — verification, no unit host — verified by code reasoning (SO_RCVTIMEO → EAGAIN → readLine nil → close → accept resumes); live socket probe deferred to Task 13 verify / human (autonomous app launch would hijack the screen)
- [x] gate: `cd agtermCore && swift test` stays green (655 tests) + `make build` succeeds (BUILD SUCCEEDED) before next task

### Task 9: Debounce theme live-preview (P4 + L7)

**Files:**
- Modify: `agterm/SettingsModel.swift`
- Modify: `agterm/AppActions.swift`

- [x] add a preview `Debouncer` (from `agtermCore`) to `SettingsModel`; ONLY navigation/typing previews debounce — `previewTheme(_:)` schedules the `apply()` instead of applying inline (sets `settings.theme` immediately so the latest is captured at commit; debounces `apply()` at 0.07 s)
- [x] give commit AND cancel an IMMEDIATE (non-debounced) path: `commitTheme()` flushes the pending preview then saves; cancel cancels the pending debounce AND applies the original synchronously via the new `previewThemeImmediate(_:)`. ⚠️ `AppActions.cancelThemePreview()` now routes through `previewThemeImmediate(original)` (was `previewTheme(original)`) so Esc reverts instantly with no debounce lag and no stuck last-preview
- [x] verify (build + isolated dev instance): open the theme palette, arrow/type rapidly — coalescing + immediate commit/cancel verified by code reasoning (debounced nav `apply()` collapses to one reload; `commitTheme().flush()` applies the latest NOW then saves; `cancelThemePreview()→previewThemeImmediate` reverts synchronously). Live palette interaction deferred to Task 13 verify / human (autonomous app launch would hijack the screen)
- [x] gate: `cd agtermCore && swift test` stays green (655 tests) + `make build` succeeds (BUILD SUCCEEDED) before next task

### Task 10: Persist opacity/blur on drag-end only (P5)

**Files:**
- Modify: `agterm/SettingsModel.swift`
- Modify: `agterm/Views/SettingsView.swift`

- [x] add `previewBackgroundOpacity(_:)`/`previewBackgroundBlur(_:)` to `SettingsModel` (set + `apply()`, no save), reusing the existing apply/save split
- [x] change the opacity/blur `Slider`s to preview live during drag and persist on release via `onEditingChanged` (call the existing persisting setter only when editing ends)
- [x] verify by code reasoning: live-preview-during-drag + single-write-on-release — the binding setters route to `previewBackgroundOpacity/Blur` (apply WITHOUT save, so each drag tick re-syncs translucency with no disk write), and `onEditingChanged` calls the persisting `setBackgroundOpacity/Blur` ONCE when `editing == false` (drag-end → one `settings.json` write). Blur slider keeps its `.disabled((opacity ?? 1) >= 1)` and `Int` rounding. Live drag deferred to Task 13 verify / human (autonomous app launch would hijack the screen)
- [x] gate: `cd agtermCore && swift test` stays green (655 tests) + `make build` succeeds (BUILD SUCCEEDED) before next task

### Task 11: Skip equal OSC writes (P6)

**Files:**
- Modify: `agterm/Ghostty/GhosttySurfaceView.swift`

- [x] in `applyPwd`, guard `currentCwd`/`splitCwd` writes on a value change; in `applyTitle`, guard `oscTitle`/`splitTitle` likewise (suppresses `@Observable` notifications on equal OSC 7/2 re-emits every prompt)
- [x] verified by code reasoning: cwd/title still update on a real `cd`/title change because the guard only skips writes where the new value EQUALS the current one — a redundant equal OSC 7/2 re-emit no longer notifies observers, so the sidebar reconcile no longer churns on a bare prompt redraw. The existing `isSplitPane` branching and the "deliberately does NOT save()" behavior are unchanged. Live observation deferred to Task 13 verify / human (autonomous app launch would hijack the screen)
- [x] gate: `cd agtermCore && swift test` stays green (655 tests) + `make build` succeeds (BUILD SUCCEEDED) before next task

### Task 12: Fix starter-keymap example doc nit (S3)

**Files:**
- Modify: `agterm/SettingsModel.swift`

- [x] change the starter `keymap.conf` example (~line 195) to the quoted env form (`open -a Zed "$AGT_SESSION_PWD"`) so the example matches the safety note below it — do NOT change the `{AGT_X}` expansion (by-design per CLAUDE.md)
- [x] verify the starter text still parses cleanly (no diagnostics) and reads consistently with the note
- [x] gate: `cd agtermCore && swift test` stays green + `make build` succeeds before next task

### Task 13: Verify acceptance criteria
- [x] verify each in-scope finding is addressed: L1, S1, S4, SkillInstaller wipe, C1, P2, P4+L7, P5, P6, window clamp, S3 doc nit — all confirmed in code: L1 (GhosttySurfaceView.destroySurface nils 9 callbacks at lines 530-538, AFTER onExitCodeCaptured?(code) at 520), S1 (ControlServer.handleConnection sets SO_RCVTIMEO 5s at line 212 after SO_NOSIGPIPE), S4 (AgentHooksInstall.posixMode/writeFile host-free; AgentHooksInstaller reads resolved target mode once at 147, writes .bak at 150 + settings at 152 through writeFile, symlink resolution kept), SkillInstaller wipe (SkillInstall.mayOverwrite(directoryExists:existingSKILL:) at 55; call site passes fm.fileExists at 55-57), C1 (WindowLibrary.recoverOrphanedWindows at 440, wired in bootstrap at 403 between loadIndex 395 and migrateLegacy 404), P2 (AppStore.saveDebouncer 68, scheduleSave 573, save() cancels at 562, selectSession 140 + setFontSize 485 use it), P4+L7 (SettingsModel.previewTheme debounces apply at 0.07s line 94, previewThemeImmediate at 100, commitTheme flushes 110; AppActions.cancelThemePreview routes through previewThemeImmediate at 429), P5 (SettingsModel.previewBackgroundOpacity/Blur apply-no-save 78/83; SettingsView sliders onEditingChanged persist on release 165/175), P6 (applyPwd guards splitCwd/currentCwd writes 209-211, applyTitle guards splitTitle/oscTitle 222-224), window clamp (WindowGeometry.swift exists; WindowRegistry.resize clampSize 1160, move clampOrigin 1191; reference.md documents clamp 126/130), S3 doc nit (starter keymap example quoted "$AGT_SESSION_PWD" at line 230)
- [x] confirm no out-of-scope behavior changed (S2/S3-expansion/P1/L6/L4/L5 untouched) — CustomCommand.expand still raw {AGT_X} substitution (no shell-quoting, line 84-107); ControlServer has no getpeereid/auth (grep NONE FOUND); ContentView still eager flatMap(\.sessions) deck with no cap (line 350); CustomCommandRunner.spawn still detached /bin/sh -c fire-and-forget (Process with terminationHandler notify only, no waitUntilExit, line 233-258)
- [x] run full host-free suite: `cd agtermCore && swift test` — 655 tests in 31 suites PASSED
- [x] build Release-equivalent: `make build` — BUILD SUCCEEDED (Debug, no launch — see plan note; formatter: none, project's only format.sh is Go-only gofmt/goimports, irrelevant to this Swift project)
- [x] run affected XCUITest targets if scope approved (close paths, control API); do not run a full UI sweep without asking — deferred to human; an autonomous XCUITest run would hijack the screen (synthesizes real keyboard/mouse events on the live display) and could disturb the deployed daily-driver app; close-path + control-API UI regression to be run manually

### Task 14: Update documentation
- [x] update `CLAUDE.md` where behavior/contract changed: AppStore save now debounced for selection/font (Task 2); WindowLibrary orphan-recovery path in bootstrap (Task 3); window.resize/move now clamped (Task 5); surface teardown nils callbacks (Task 7); control socket read timeout (Task 8)
- [x] confirm the bundled agent-skill reference window.resize/move clamp note landed in Task 5 (keep-in-sync surface — done in-task, verify here) — present in `agent-skill/reference.md` lines 125-130, no change needed
- [x] move this plan to `docs/plans/completed/` — physical move performed by exec finalize step

## Post-Completion
*Items requiring manual intervention — no checkboxes, informational only*

**Manual verification** (app-target-only fixes, via an ISOLATED dev instance — never the deployed daily driver):
- L1: open/close windows repeatedly; optionally watch allocations in Instruments to confirm the per-window graph is reclaimed.
- S1: connect a do-nothing client to the socket, confirm it's dropped after the timeout and the API keeps serving.
- S4: `chmod 600 ~/.claude/settings.json`, run Help ▸ Install Agent Status Hooks…, confirm the file (and `.bak`) stay 0600. (Use a throwaway HOME or back up the real file first.)
- P4/P5: browse the theme palette and drag opacity/blur sliders; confirm coalesced previews and a single settings write on release, no perceptible lag.
- P6: confirm the sidebar no longer redraws on every shell prompt while the cwd is unchanged.

**Regression** (optional): run the `agtermUITests` close-path and `ControlAPIUITests` targets after L1/S1 to confirm no teardown/socket regression — ask before any full UI run.

Smells pre-check: skipped — non-Go project
