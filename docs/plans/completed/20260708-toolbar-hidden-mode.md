# Toolbar Hidden Mode (GUI-only)

## Overview

Add a third **Hidden** state to the custom titlebar row, alongside the existing Compact and Tall states. GUI-only — no control-socket command (matching how `compactToolbar` is exposed today).

- **Today**: `WindowContentView.customTitlebar` has two states driven by `AppSettings.compactToolbar: Bool?` — nil/true = **compact** (30px, single line: title + sidebar/split/scratch/quick buttons), false = **tall** (48px, adds the cwd subtitle line).
- **New**: **hidden** = fully borderless. Hide the custom titlebar row AND the three macOS traffic lights (close/minimize/zoom). Keep only an invisible ~6px top drag strip so the window is still movable + double-click-zoomable, with the terminal running full-bleed underneath (top ~6px loses click-through — the accepted cost).
- **Window management in hidden mode**: close/minimize/zoom stay covered by keyboard + menu (`deleteWindow`, `closeSession` fallback to `performClose`, ⌘M, Window ▸ Zoom). The invisible drag strip covers move + double-click-zoom, so a window can never get pinned.
- **Model change**: replace the two-state `compactToolbar: Bool?` with a three-state `ToolbarMode` enum (tall/compact/hidden), keeping `compactToolbar` as a decode shim for backward compatibility.

Benefits: a distraction-free full-bleed terminal for users who want zero chrome.

**Explicitly out of scope**: a control-channel command. `compactToolbar`/tall is GUI-only today (no `agtermctl` surface, keep-in-sync EXEMPT — only `theme.set`/`config.reload` touch settings over the socket); the new mode stays consistent with that. No `Command` case, no `ControlProtocol`/`ControlDispatcher`/`ControlServer` change, no CLI, no agent-skill change. (This is what removes the cross-package build-ordering hazard: no wire-protocol enum case → no exhaustive-switch breakage.)

## Context (from discovery)

Files/components involved (all paths + line numbers verified):
- `agtermCore/Sources/agtermCore/AppSettings.swift` — `compactToolbar: Bool?` at ~104 (decl), ~187 (init param), ~205 (assign). This is the ONLY `agtermCore` file that changes.
- `agterm/Ghostty/GhosttyApp.swift` — the `compactToolbar: Bool = true` mirror (~60) + `setCompactToolbar` (~155); "non-observable chrome mirror" comments citing `compactToolbar` (~64/73/81/86).
- `agterm/SettingsModel.swift` — `applyCompactToolbar()` (~645/647), `setCompactToolbar` (~216), init call (~73).
- `agterm/Views/WindowContentView.swift` — `compactToolbar` @State (~31) + comments (~33/44), `resolvedCompactToolbar()` (~473), `titlebarHeight` (~52), `customTitlebar` (~536), `windowSubtitle`/`titleLabel` (~515/521), `.agtermAppearanceChanged` refresh (~101), `WindowControlArea()` drag background (~582).
- `agterm/Views/WindowAppearance.swift` — `sync(window:background:chrome:)` (~28); already hides `NSTitlebarBackgroundView` (~70).
- `agterm/Views/SettingsView.swift` — `Toggle("Compact toolbar")` (~239) + binding calling `model.setCompactToolbar` (~356).
- `agtermUITests/SettingsUITests.swift` — `testCompactToolbarTogglePersists` (~60-69) clicks `settings-compact-toolbar` and asserts `compactToolbar == false` (must be REPLACED — it drives the removed toggle).
- `.claude/rules/settings.md` — `AppSettings` field list + Appearance → Window section + "like compactToolbar" cross-refs (~80/163/333/334).
- `README.md`, `site/docs.html`, `site/index.html` — user-facing feature docs.

Related patterns:
- `compactToolbar` is the established two-state precedent this extends: a non-observable `GhosttyApp` mirror + `.agtermAppearanceChanged` re-render, plus a default-mapped-to-nil Settings binding to keep `settings.json` minimal. `notificationBadgeEnabled`/`attentionButtonEnabled` follow the same mirror pattern.
- `WindowAppearance.sync` already hides `NSTitlebarBackgroundView` for translucency — hiding the three traffic-light buttons is the same kind of per-sync AppKit tweak.

Dependencies:
- `agtermCore` stays host-free (no GhosttyKit/AppKit/CoreGraphics) — `ToolbarMode` is a plain Foundation enum. Only `AppSettings.swift` changes there.
- Test hosts: `AppSettingsTests` (`agtermCoreTests`, `swift test`) for the model; `SettingsUITests` (`agtermUITests`, XCUITest) for the Picker. App-target rendering has no unit host — verified by `xcodebuild` Debug + `make lint` + manual dev instance.

## Development Approach

- **Testing approach**: Regular (code first, then tests, in the SAME task). The host-free `AppSettings` model is unit-tested via `swift test`. The app-target work (`GhosttyApp`/`SettingsModel`/`WindowContentView`/`WindowAppearance`/`SettingsView`) has NO unit-test host — verified by `xcodebuild` Debug build + `make lint` + the Settings XCUITest + manual verification on an isolated dev instance.
- **Task 2 is atomic within the app target**: removing the `GhosttyApp`/`SettingsModel` `compactToolbar` symbols breaks the `WindowContentView` and `SettingsView` call sites, so the mirror rename, both view edits, the `WindowAppearance` change, and the Settings Picker must all land in one task for `xcodebuild` to build. This coupling is entirely within the app target — there is NO cross-package `swift test`-vs-`xcodebuild` conflict, because nothing in `agtermCore` other than `AppSettings` changes.
- Per-task gate: after every task, `cd agtermCore && swift test` green + `xcodebuild` Debug builds + `make lint` (swiftlint `--strict`) clean — before the next task. Every task leaves the whole tree green.
- Keep this plan file in sync (`[x]` immediately, ➕ new tasks, ⚠️ blockers). Work on a feature branch off `master`.

## Testing Strategy

- **Unit tests** (`swift test`):
  - `AppSettingsTests` (Task 1) — `toolbarMode` round-trip; legacy-decode migration; `effectiveToolbarMode` resolution.
- **UI tests** (XCUITest):
  - `SettingsUITests` (Task 3) — REPLACE `testCompactToolbarTogglePersists`; the new toolbar-mode Picker selects Hidden and persists `toolbarMode`.
- **Manual verification** (isolated dev instance; NEVER the deployed `~/Applications/agterm.app`): hidden mode shows no titlebar and no traffic lights, terminal full-bleed; the top drag strip moves + double-click-zooms; toggling back to compact/tall restores the row + buttons live; fullscreen enter/exit restores the traffic lights.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix

## Solution Overview

- **One enum** `ToolbarMode { tall, compact, hidden }` in `agtermCore`, used by `AppSettings` and the app target only (no wire-protocol use).
- **Migration without data loss**: `AppSettings.toolbarMode: String?` is the live field (stored raw for tolerant forward-compat decode — an unknown value degrades instead of failing the whole `settings.json`); `compactToolbar: Bool?` remains ONLY as a decode shim (synthesized `Codable` keeps working — both optional). `effectiveToolbarMode` resolves `toolbarMode.flatMap(ToolbarMode.init(rawValue:)) ?? (compactToolbar == false ? .tall : .compact)`. Writing a mode nils `compactToolbar`, so the legacy key evaporates on the next save. No custom `init(from:)`, no eager migration pass.
- **App-side rendering**: `GhosttyApp` mirrors a single `toolbarMode`; `WindowContentView` maps it to titlebar height (48/30/0) and, when hidden, collapses the row to the invisible drag strip; `WindowAppearance.sync` hides/shows the three traffic-light buttons.
- **Settings**: the Appearance → Window `Toggle("Compact toolbar")` becomes a Tall/Compact/Hidden `Picker`.

## Technical Details

- `public enum ToolbarMode: String, Codable, Sendable, CaseIterable { case tall, compact, hidden }`.
- `AppSettings`: `public var toolbarMode: String?` (raw storage for tolerant decode, nil = `.compact`); `public var compactToolbar: Bool?` kept as decode shim; `public var effectiveToolbarMode: ToolbarMode { toolbarMode.flatMap(ToolbarMode.init(rawValue:)) ?? (compactToolbar == false ? .tall : .compact) }`.
- `GhosttyApp`: `private(set) var toolbarMode: ToolbarMode = .compact`; `func setToolbarMode(_:)`.
- `SettingsModel`: `applyToolbarMode()` (push `settings.effectiveToolbarMode` into `GhosttyApp`) + `setToolbarMode(_ mode:)` (set `toolbarMode`, nil `compactToolbar`, `persistAndApply()`); replaces `applyCompactToolbar`/`setCompactToolbar`, wired in `init` + `persistAndApply`.
- `WindowContentView.titlebarHeight`: `.tall` → 48, `.compact` → 30, `.hidden` → 0. `customTitlebar` in `.hidden` renders `Color.clear.frame(height: 6).background(WindowControlArea())` and nothing else; the cwd subtitle stays gated to `.tall`. State mirror refreshed on `.agtermAppearanceChanged`.
- `WindowAppearance.sync`: `let hidden = GhosttyApp.shared.toolbarMode == .hidden`; `for b in [.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(b)?.isHidden = hidden }`. Re-applies on the existing key/main/fullscreen + `.agtermAppearanceChanged` drivers.
- `SettingsView`: segmented `Picker` (Tall/Compact/Hidden) bound to `model.settings.effectiveToolbarMode` via `model.setToolbarMode`, mapping `.compact` back to nil; `accessibilityIdentifier` `settings-toolbar-mode`.

## What Goes Where

- **Implementation Steps** (`[ ]` checkboxes): all code, tests, and in-repo docs (`settings.md`, README, site).
- **Post-Completion** (no checkboxes): manual dev-instance acceptance (a user action).

## Implementation Steps

### Task 1: ToolbarMode enum + AppSettings migration (agtermCore, host-free — fully green)

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppSettings.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppSettingsTests.swift`

- [x] add `public enum ToolbarMode: String, Codable, Sendable, CaseIterable { case tall, compact, hidden }`
- [x] add `public var toolbarMode: ToolbarMode?` to `AppSettings` (decl + init param + assignment); keep `compactToolbar: Bool?` as-is (decode shim)
- [x] add computed `public var effectiveToolbarMode: ToolbarMode { toolbarMode ?? (compactToolbar == false ? .tall : .compact) }`
- [x] write tests: `toolbarMode` encode/decode round-trip; omit-when-nil; `toolbarMode` present wins over legacy `compactToolbar`
- [x] write tests: legacy migration — `compactToolbar == false` → `.tall`; `compactToolbar == true`/nil → `.compact`
- [x] gate: `cd agtermCore && swift test` green + `xcodebuild` Debug builds + `make lint` clean

### Task 2: App-target adaptation — mirror, rendering, traffic lights, Settings Picker (atomic within the app target)

One compile-coupled unit: the `GhosttyApp`/`SettingsModel` symbol rename breaks the `WindowContentView`/`SettingsView` call sites, so all app-target edits land together and the target builds green at the end.

**Files:**
- Modify: `agterm/Ghostty/GhosttyApp.swift`
- Modify: `agterm/SettingsModel.swift`
- Modify: `agterm/Views/WindowContentView.swift`
- Modify: `agterm/Views/WindowAppearance.swift`
- Modify: `agterm/Views/SettingsView.swift`

- [x] `GhosttyApp`: replace the `compactToolbar: Bool` mirror + `setCompactToolbar` with `toolbarMode: ToolbarMode = .compact` + `setToolbarMode(_:)`; refresh the stale "like compactToolbar" mirror comments
- [x] `SettingsModel`: replace `applyCompactToolbar`/`setCompactToolbar` with `applyToolbarMode()` (push `settings.effectiveToolbarMode`) + `setToolbarMode(_ mode:)` (set `toolbarMode`, nil `compactToolbar`, `persistAndApply()`); wire `applyToolbarMode` in `init` + `persistAndApply`
- [x] `WindowContentView`: replace the `compactToolbar` @State/`resolvedCompactToolbar()` with a `toolbarMode` mirror refreshed on `.agtermAppearanceChanged`; map `titlebarHeight` 48/30/0; render the invisible drag strip when `.hidden`; keep the cwd subtitle gated to `.tall`; update the stale `compactToolbar` comments
- [x] `WindowAppearance.sync`: hide the three `standardWindowButton` when `toolbarMode == .hidden`, restore `isHidden = false` otherwise
- [x] `SettingsView`: replace the `Toggle("Compact toolbar")` with a segmented `Picker` (Tall/Compact/Hidden) bound to `effectiveToolbarMode` via `model.setToolbarMode`, mapping `.compact` back to nil; set `accessibilityIdentifier` `settings-toolbar-mode`
- [x] gate: `xcodebuild` Debug builds + `make lint` clean + `swift test` still green

### Task 3: Settings UI test — replace the compact-toggle test (app target)

**Files:**
- Modify: `agtermUITests/SettingsUITests.swift`

- [x] REPLACE `testCompactToolbarTogglePersists` (it drives the removed `settings-compact-toolbar` toggle) with `testToolbarModePickerPersists`: open Settings → Appearance, select Hidden on `settings-toolbar-mode`, assert the persisted `toolbarMode == "hidden"` (or the Picker selection)
- [x] gate: `xcodebuild` build + the Settings UI test green

### Task 4: Keep-in-sync docs — settings rule + README + website

No `control-api.md` or agent-skill changes (GUI-only, keep-in-sync EXEMPT like `compactToolbar`).

**Files:**
- Modify: `.claude/rules/settings.md`
- Modify: `README.md`
- Modify: `site/docs.html`
- Modify: `site/index.html`

- [x] `settings.md`: update the `AppSettings` field list (`compactToolbar` → `toolbarMode` + the legacy decode-shim note), the Appearance → Window section (toggle → Tall/Compact/Hidden Picker), and refresh the "like compactToolbar" cross-references (~80/163/333/334) to `toolbarMode`
- [x] `README.md`: document the three toolbar modes (Tall/Compact/Hidden)
- [x] `site/docs.html`: mirror the README change (hand-authored mirror)
- [x] `site/index.html`: reflect the feature in the features copy if warranted (do NOT bump `softwareVersion` — release-only) — judged NOT warranted (features grid is high-level; a minor appearance setting does not merit a card), left unchanged
- [x] confirm `CHANGELOG.md` is NOT touched (release-only)

### Task 5: Verify acceptance + housekeeping

- [x] verify all Overview requirements: three modes; hidden hides row + traffic lights; drag strip moves + double-click-zooms; keyboard/menu window management intact — confirmed in code: `ToolbarMode`/`effectiveToolbarMode`; `titlebarHeight` 48/30/0 + `WindowAppearance.sync` hides the three `standardWindowButton`s in hidden; `customTitlebar` hidden case = `Color.clear.frame(height:6).background(WindowControlArea())`; window management stays on ⌘W/⌘M/menu (button visibility only, functionality untouched)
- [x] verify edge cases: live mode toggling updates chrome without relaunch; fullscreen enter/exit restores traffic lights; legacy `settings.json` with `compactToolbar:false` opens tall — confirmed: `WindowContentView.onReceive(.agtermAppearanceChanged)` re-mirrors `toolbarMode` and `WindowAppearance` re-syncs on the same driver; `WindowAppearance` guards `hideButtons` off in `.fullScreen`; `effectiveToolbarMode` = `toolbarMode ?? (compactToolbar == false ? .tall : .compact)`
- [x] run full host-free suite: `cd agtermCore && swift test`; run `SettingsUITests` — swift test green (1263 tests / 53 suites); `SettingsUITests/testToolbarModePickerPersists` passed
- [x] `make lint` (swiftlint `--strict`) — zero findings; `xcodebuild` Debug build clean — lint clean; `xcodebuild build-for-testing` Debug = TEST BUILD SUCCEEDED
- [x] no new pattern; CLAUDE.md unchanged (reused the existing compactToolbar mirror/appearance pattern); plan move deferred to exec finalize step

## Post-Completion
*Items requiring manual intervention — no checkboxes, informational only*

**Manual verification** (isolated dev instance, never the deployed app):
- `make build`, then `open -n --env AGTERM_STATE_DIR=<tmp> build/DerivedData/Build/Products/Debug/agterm.app` (copy the user's `keymap.conf`/`ghostty.conf`/`restore-denylist.conf` into `<tmp>/config/` first if custom commands are needed).
- Hidden mode: no titlebar row, no traffic lights, terminal full-bleed; the top ~6px drag strip moves the window and double-click zooms; ⌘M minimizes, the Close Window action closes.
- Toggle Hidden ↔ Compact ↔ Tall via Settings and confirm the chrome updates live.
- Quit the dev instance BY PID (`kill <pid>`), never `pkill`; never quit/relaunch the deployed `~/Applications/agterm.app`.

---
Smells pre-check: skipped — non-Go project
