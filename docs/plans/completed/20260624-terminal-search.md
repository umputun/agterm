# In-Terminal Text Search

## Overview

Add live text search over the active terminal's scrollback, driven by libghostty's native search API. ⌘F opens a small search bar above the focused terminal pane; typing a query highlights matches in the live surface and shows an "N of M" counter; ⌃/⌄ (and Enter / Shift-Enter) step between matches; Esc / ⌘F closes. The feature ships across all four keep-in-sync surfaces: GUI (search bar), menu (Find…), keymap (rebindable `toggle_search`), and the control channel (`session.search` + `agtermctl session search`).

This is **in-terminal scrollback search** — searching the text already rendered/scrolled in the terminal, NOT filesystem search and NOT a new TUI program.

**Problem it solves:** there is currently no way to find text in terminal output without scrolling by eye. macterm (the project's reference app) has it; libghostty already exposes the API; agterm's bridge already has the exact seam (`performBindingAction`) and callback dispatch to wire it.

## Context (from discovery)

libghostty's bundled header (`GhosttyKit.xcframework/macos-arm64/Headers/ghostty.h`) exposes the full search surface:

- **App → lib**, via the existing `ghostty_surface_binding_action(surface, action, len)`:
  - `start_search` — enter search mode (lib replies with a `START_SEARCH` action carrying the current needle)
  - `search:<needle>` — set the query (lib replies `SEARCH_TOTAL` + `SEARCH_SELECTED`)
  - `navigate_search:next` / `navigate_search:previous` — step matches
  - `end_search` — exit
- **lib → app**, via the action callback (`GhosttyCallbacks.action`):
  - `GHOSTTY_ACTION_START_SEARCH` (`start_search.needle`) / `GHOSTTY_ACTION_END_SEARCH`
  - `GHOSTTY_ACTION_SEARCH_TOTAL` (`search_total.total`) / `GHOSTTY_ACTION_SEARCH_SELECTED` (`search_selected.selected`)

Reference implementation read from `thdxg/macterm` (cloned to /tmp, read, deleted): `TerminalSearchState` (Observable needle/total/selected/isVisible with debounced needle publishing), `TerminalSearchBar` (SwiftUI field + up/down/close + counter), 4 callback arms in `GhosttyCallbacks`, 4 thin binding-action methods on the surface view. The toggle (⌘F-again closes) is handled in the `onSearchStart` handler — sending `start_search` while the bar is already open closes it.

**Files / components involved:**
- `agterm/Ghostty/GhosttySurfaceView.swift` — the binding-action driver (`performBindingAction`, `inject`, `readSelection`) and the closure-callback pattern (`onFocusChange`, `onUserInputClearsStatus`, `onExit`). Add 4 search methods + 4 search callbacks.
- `agterm/Ghostty/GhosttyCallbacks.swift` — the `action(target:action:)` switch with `surfaceView(from:)` recovery + `DispatchQueue.main.async` hop. Add 4 search arms.
- `agtermCore/Sources/agtermCore/Session.swift` — `@Observable @MainActor` model with ephemeral non-persisted fields (`overlayActive`, `scratchActive`, `agentIndicator`, `unseenCount`). Add the search state fields + a pure display-text computed.
- `agtermCore/Sources/agtermCore/BuiltinAction.swift` — the 27 rebindable actions + `defaultChord`. Add `toggleSearch`.
- `agtermCore/Sources/agtermCore/ControlProtocol.swift` — `Command`, `ControlArgs`, `ControlResult`. Add `session.search`.
- `agterm/Control/ControlServer.swift` — dispatch arm.
- `agtermCore/Sources/agtermctlKit/Commands.swift` — `session search` CLI subcommand.
- `agterm/ContentView.swift` — the `detailPane`/`floatingOverlayLayer` placement seam (`WindowContentView`). The search bar anchors at the `detailPane` level (like `floatingOverlayLayer`), NEVER inside `sessionDetail`'s HSplitView subtree.
- `agterm/AppActions.swift` — `focusedSurface()`, `focusActiveSession()`, and the action methods that the menu/palette/control share.
- `agterm/agtermApp.swift` — the `makeSurface`/`makeSplitSurface` factories (where the surface callbacks are wired, beside `onFocusChange`/`onUserInputClearsStatus`) AND the `.commands` View menu reading `equivalent(for:)`.
- `agterm/SettingsModel.swift` — the app-side, private starter-keymap generator (`starterKeymapText`/`chordSyntax`) that iterates `BuiltinAction.allCases`.
- `agterm/Palette.swift` — `paletteActions()`.
- `agterm/Resources/agent-skill/` — the bundled agent-driver skill (HARD keep-in-sync mirror of the Control API).

**Related patterns found:**
- Ephemeral per-session UI state (overlay/scratch) lives as observed fields on `Session`, absent from `SessionSnapshot` (never persisted).
- Closure callbacks on the surface view (`onFocusChange`) are wired by the app's surface factory, where the owning `Session` is in scope, and update the model on the main actor.
- A new user action = a `BuiltinAction` (menu + keymap + palette) AND a `session.*` control command (the HARD keep-in-sync four-point rule: `Command` case + `ControlServer` arm + `agtermctl` subcommand + round-trip/e2e tests).
- Async lib→app results (overlay exit code, surface realization) are read with a **bounded main-actor poll**, the idiom `session.search` reuses to settle the match count before returning.

**Dependencies identified:** none new. No SwiftPM/xcframework changes. `agtermctlKit` already links swift-argument-parser. The search methods are GhosttySurfaceView-only (driven through the resolved view like the font `performBindingAction` calls), so the host-free `TerminalSurface` protocol does NOT change.

## Development Approach

- **testing approach**: Regular (code first, then tests within each task)
- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - host-free logic (`Session` fields/display text, `BuiltinAction`, control protocol round-trip, keymap starter) gets real `agtermCore` unit tests in its own task
  - bridge/UI/wiring that the unit harness can't reach (Metal `GhosttySurfaceView`, callbacks, SwiftUI bar) is validated through an observable side effect in the XCUITest tasks (the accessibility tree counter) and the control e2e — per the CLAUDE.md "drive it through an observable side effect" rule
- **CRITICAL: all tests must pass before starting next task**
- **CRITICAL: update this plan file when scope changes during implementation**
- run `cd agtermCore && swift test` after every host-free change (fast, ~0.2s); the app must build after every app-target change
- maintain backward compatibility (search fields default to off; absent fields decode cleanly from existing snapshots)

## Swift Project Quality Rules (HARD — verify against every task before marking complete)

These supplement project CLAUDE.md / the global rules and gate task completion.

- **Visibility**: lowercase/`internal` by default; `public` in `agtermCore` only because the app target consumes it (existing pattern). No new `public` symbol without an out-of-package (app-target or CLI) caller. Methods that are only called from within one type are members of that type, not free functions.
- **Methods over standalone helpers**: the search display-text logic is a computed property on `Session` (its inputs are `Session` fields), not a free function. `SearchDirection` is a nested enum on `GhosttySurfaceView`.
- **Comments**: lowercase non-doc comments inside functions; doc comments only on the public `agtermCore` surface, starting with the symbol name; no historical/why-changed comments. Match the dense surrounding comment style of the bridge files where it documents a real invariant (the NSSplitView-overrun rule, the START_SEARCH toggle).
- **Concurrency**: every C-callback `@MainActor` touch hops via `DispatchQueue.main.async`; any `char*` (the needle) is copied to a Swift `String` BEFORE the hop. `Session` is `@MainActor`.
- **Per-task gate**: `cd agtermCore && swift test` green; app target builds; for UI/e2e tasks the named test class passes. Scan new code for the rule classes above before marking complete.

## Testing Strategy

- **unit tests (`agtermCore/Tests/agtermCoreTests`)**: required for every host-free change — `Session` search fields + display text + snapshot exclusion, `BuiltinAction.toggleSearch` raw name + default chord, the keymap starter documenting `toggle_search`, and `session.search` control round-trip (request encode/decode, result count+text).
- **XCUITest (`agtermUITests`)**: agterm has a UI e2e suite. UI changes get e2e tests in the same task family:
  - a `SearchUITests` class: ⌘F opens the bar (`search-field` a11y id), type a needle, assert the `search-counter` staticText reports matches, Esc closes. Driven via the observable AX counter (the Metal surface itself is unobservable).
  - a `session.search` e2e in `ControlAPIUITests`: open + needle returns a count; `--next`/`--prev`/`--close` round-trip.
- **cadence**: run host-free `swift test` always; run ONLY the affected XCUITest class per the CLAUDE.md "ASK before a full UI run" rule — confirm scope before committing.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- keep this plan in sync with actual work done

## Solution Overview

**State ownership.** The search state is four ephemeral, non-persisted observed fields on `Session` (mirroring `overlayActive`/`scratchActive`): `searchActive`, `searchNeedle`, `searchTotal`, `searchSelected`, plus a pure computed `searchDisplayText`. Both the GUI bar and the control channel read/write this single place, so they can't drift.

**Driving libghostty.** Search targets the FOCUSED pane's surface. `GhosttySurfaceView` gains four one-line methods (`startSearch`/`sendSearchQuery`/`navigateSearch`/`endSearch`) over `ghostty_surface_binding_action`, and four callbacks (`onSearchStart`/`onSearchEnd`/`onSearchTotal`/`onSearchSelected`). The main/split surface factory wires the callbacks to update the owning `Session`'s fields. `GhosttyCallbacks.action` gains four arms that recover the firing surface, copy the needle out of the C string, hop to main, and invoke the callbacks (returning `true`).

**Open/close toggle.** ⌘F → `AppActions.toggleSearch()` → `focusedSurface().startSearch()` (the `start_search` binding action). libghostty replies with `START_SEARCH`; the `onSearchStart` closure toggles: if the session's bar is already visible it calls `endSearch()` (sending `end_search`, so libghostty actually exits search mode — NOT just flipping the SwiftUI flag), else it opens the bar (sets `searchActive = true`, seeds any returned needle) and focuses the field. The resulting `END_SEARCH` callback clears the fields, hides the bar, and returns first responder to the terminal. This is why all four lib→app arms are load-bearing, not just defensive.

**UI placement (the one real risk).** The bar renders as an `.overlay(alignment: .top)` on `detailPane` (the same level as `floatingOverlayLayer`), reading `store.activeSession`'s search state. It is deliberately OUTSIDE each session's `sessionDetail` HSplitView-hosting ZStack: per the hard-won lesson in CLAUDE.md ("anything in `sessionDetail`'s HSplitView subtree that changes when a flag flips overruns the NSSplitView into the titlebar"), adding a conditional sibling inside that subtree is exactly the perturbation that paints the split over the header. Anchoring on `detailPane` keeps the split subtree's shape constant whether or not the bar is shown.

**Control channel.** `session.search` (target = session) selects the target (so the bar + highlights are visible, like the floating overlay), then drives the focused surface: `args.text` sets the needle (opening search if needed), `args.to` = `next|prev|close`. It returns `result.count` (total matches) and `result.text` (the "N of M" / "M matches" / "no matches" display string), settled with a bounded main-actor poll of `session.searchTotal` (the overlay-result idiom). No needle + no `to` = open the empty bar.

## Technical Details

**Session fields (`agtermCore`, ephemeral, NOT in `SessionSnapshot`):**
```swift
public var searchActive: Bool = false          // observed — drives the bar
public var searchNeedle: String = ""           // observed — current query (GUI + control write)
public var searchTotal: Int? = nil             // observed — match count from SEARCH_TOTAL
public var searchSelected: Int? = nil          // observed — 1-based current index from SEARCH_SELECTED

/// The match counter shown in the bar / returned by `session.search`. Pure, host-free, unit-tested.
public var searchDisplayText: String {
    guard let total = searchTotal else { return "" }      // no query yet
    guard total > 0 else { return "no matches" }
    guard let selected = searchSelected else { return "\(total) matches" }
    return "\(selected) of \(total)"
}
```

**GhosttySurfaceView (app):**
```swift
enum SearchDirection: String { case next, previous }    // nested; raw values feed navigate_search:<dir>
var onSearchStart: ((String?) -> Void)?
var onSearchEnd: (() -> Void)?
var onSearchTotal: ((Int?) -> Void)?
var onSearchSelected: ((Int?) -> Void)?
func startSearch()                       // performBindingAction("start_search")
func sendSearchQuery(_ needle: String)   // performBindingAction("search:\(needle)")
func navigateSearch(_ d: SearchDirection)// performBindingAction("navigate_search:\(d.rawValue)")
func endSearch()                         // performBindingAction("end_search")
```

**GhosttyCallbacks arms** (copy `start_search.needle` to `String` before the hop; `search_total.total`/`search_selected.selected` are `ssize_t` → `Int`, map a negative to nil):
```swift
case GHOSTTY_ACTION_START_SEARCH: // recover view, copy needle, main hop → view.onSearchStart?(needle); return true
case GHOSTTY_ACTION_END_SEARCH:   // main hop → view.onSearchEnd?(); return true
case GHOSTTY_ACTION_SEARCH_TOTAL: // main hop → view.onSearchTotal?(value); return true
case GHOSTTY_ACTION_SEARCH_SELECTED: // main hop → view.onSearchSelected?(value); return true
```

**Control protocol (`agtermCore`):**
- `Command.sessionSearch = "session.search"`.
- Reuses existing `ControlArgs.text` (needle) and `ControlArgs.to` (`next`|`prev`|`close`); the `to` doc comment is extended to name `session.search`'s values. No new `ControlArgs` field.
- Reuses existing `ControlResult.count` (total matches) + `ControlResult.text` (display string). No new `ControlResult` field.

**ControlServer arm** (`searchSession`): resolve session via the shared `resolveSession`; select it; resolve its `activeSurface as? GhosttySurfaceView`; if `to == close` → `endSearch()`, return ok; else `startSearch()` if not `searchActive`, set needle via `sendSearchQuery` if `text` present, `navigateSearch` if `to == next|prev`; bounded-poll `session.searchTotal`; return `ControlResult(count: total, text: session.searchDisplayText)`.

**agtermctl** (`session search`): optional positional `[needle]`, flags `--next`/`--prev`/`--close` (mutually exclusive; `validate()` rejects combos); maps to `ControlArgs(text: needle, to: …)`; human output prints `result.text` (or `ok`), `--json` prints the full result. Not in `echoesResultID` (no new id).

**Menu / palette:** `BuiltinAction.toggleSearch = "toggle_search"`, `defaultChord = ⌘F` (`Chord(mods: [.command], key: "f")` — expressible, round-trips through the keymap grammar). A "Find…" menu item in the View menu reading `equivalent(for: .toggleSearch)` (no hardcoded shortcut), a `paletteActions()` entry, and `AppActions.toggleSearch()`. The starter `keymap.conf` text is generated app-side in `agterm/SettingsModel.swift` (`starterKeymapText`, all `private`), which iterates `BuiltinAction.allCases` — so the new action is documented automatically with NO generator change. Adding the case also breaks two existing exhaustive `agtermCore` tests (`allCases.count == 27`, the `expected` chord table) — both updated in Task 2.

## What Goes Where

- **Implementation Steps** (`[ ]`): all code, tests, and in-repo docs (README, CLAUDE.md, the bundled agent-skill).
- **Post-Completion** (no checkboxes): manual visual verification of the highlight rendering and focus return, plus the optional needle-debounce enhancement.

## Implementation Steps

### Task 1: Session search state + display text (agtermCore)

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Session.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/SessionTests.swift` (or the nearest existing Session test file)

- [x] add the four ephemeral observed fields (`searchActive`/`searchNeedle`/`searchTotal`/`searchSelected`) to `Session`, grouped with the overlay/scratch ephemeral state, with doc comments noting they are non-persisted. These are written DIRECTLY (from the factory closures + `AppActions`), following the `splitFocused` precedent — no `AppStore` mutator, since they carry no cross-cutting side effect (unlike `agentIndicator`, which has reset-on-select logic and goes through `setAgentIndicator`)
- [x] add the pure `searchDisplayText` computed property (empty when no query, `"no matches"`, `"N matches"`, `"S of N"`)
- [x] confirm `SessionSnapshot`/`snapshot()` does NOT capture the new fields (ephemeral, like overlay/scratch); add nothing there
- [x] write unit tests for `searchDisplayText` across all branches (nil total, 0, total-only, selected+total)
- [x] write a unit test asserting a snapshot round-trip leaves the search fields at defaults (not persisted)
- [x] run `cd agtermCore && swift test` — must pass before next task

### Task 2: BuiltinAction.toggleSearch (agtermCore) + starter pickup (app)

**Files:**
- Modify: `agtermCore/Sources/agtermCore/BuiltinAction.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/BuiltinActionTests.swift`
- Verify only (NO edit): `agterm/SettingsModel.swift` — the starter generator (`starterKeymapText`/`chordSyntax`, app-side, all `private`) iterates `BuiltinAction.allCases`, so it documents the new action automatically. There is NO `agtermCore/Keymap.swift` generator to change, and the starter text is not reachable from the host-free suite.

- [x] add `case toggleSearch = "toggle_search"` to `BuiltinAction` and its `defaultChord` returning `Chord(mods: [.command], key: "f")`
- [x] update the EXISTING assertions a new case breaks in `BuiltinActionTests.swift`: bump `allCases.count` 27 → 28 (`rawNamesAreTheKittyStyleNames`, line 18) AND add `.toggleSearch: Chord(mods: [.command], key: "f")` to the exhaustive `expected` dictionary in `defaultChordMatchesShippedTable` (lines 28–61, gated by `expected.count == allCases.count`)
- [x] add/extend an assertion that `toggleSearch.defaultChord` is `cmd+f` and round-trips through `parseKeybind`/`chordSyntax` (so the starter renders `cmd+f`, not `(not expressible)`)
- [x] confirm by INSPECTION (not a host-free test — the generator is app-side/private) that the regenerated starter `keymap.conf` documents `toggle_search` + `cmd+f`
- [x] run `cd agtermCore && swift test` — must pass before next task

### Task 3: session.search control protocol (agtermCore)

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift`

- [x] add `case sessionSearch = "session.search"` to `Command`
- [x] extend the `ControlArgs.to` doc comment to name `session.search`'s `next|prev|close` (no new field); confirm `text` already covers the needle
- [x] confirm `ControlResult.count` + `text` cover the return (no new field); add a doc note that `session.search` reuses them
- [x] write a round-trip test: encode/decode a `ControlRequest(cmd: .sessionSearch, target:, args: ControlArgs(text:, to:))` and a `ControlResponse` carrying `count` + `text`
- [x] write a decode test: `{"cmd":"session.search"}` decodes to `.sessionSearch` (and an unknown cmd still fails cleanly)
- [x] run `cd agtermCore && swift test` — must pass before next task

### Task 4: Search bridge — GhosttySurfaceView methods + GhosttyCallbacks arms (app)

**Files:**
- Modify: `agterm/Ghostty/GhosttySurfaceView.swift`
- Modify: `agterm/Ghostty/GhosttyCallbacks.swift`

**Note:** the lib→app action tags + struct fields are confirmed against the bundled `ghostty.h`, but the app→lib binding-action STRINGS (`start_search`, `search:<needle>`, `navigate_search:next|previous`, `end_search`) are parsed internally by libghostty and are NOT verifiable from the header — they are an assumption pinned to `GHOSTTY_REV` (sourced from macterm's libghostty, which may differ). A wrong string silently no-ops (like a bad font binding action). The Task 5 empirical check confirms they fire BEFORE the UI/CLI are built on top.

- [x] add the `SearchDirection` nested enum and the four `onSearch*` callback vars (mirroring `onFocusChange`, with doc comments)
- [x] add `startSearch()`/`sendSearchQuery(_:)`/`navigateSearch(_:)`/`endSearch()` as thin wrappers over `performBindingAction`
- [x] add the four `GHOSTTY_ACTION_START_SEARCH`/`END_SEARCH`/`SEARCH_TOTAL`/`SEARCH_SELECTED` arms to `GhosttyCallbacks.action`, copying the needle to a `String` before the main hop and mapping negative `ssize_t` totals/indices to nil, each returning `true`
- [x] add TEMPORARY `NSLog` instrumentation in the four arms (the firing needle/total/selected), left in place THROUGH the Task 5 empirical check and removed in one pass after it confirms the strings work
- [x] build the app target (`scripts/build.sh` or the xcodebuild Debug step) — must compile; the arms are exercised by the Task 5 empirical check + the UI/e2e tests in Tasks 8–9 (no host-free unit path for the Metal surface, per the observable-side-effect rule)

### Task 5: AppActions + factory wiring + Find menu trigger + empirical string check (app)

**Files:**
- Modify: `agterm/AppActions.swift`
- Modify: `agterm/agtermApp.swift` — the `makeSurface`/`makeSplitSurface` factories (~lines 352/383, beside the existing `onFocusChange`/`onUserInputClearsStatus` wiring) AND the `.commands` View menu (the Find… item)

- [x] wire BOTH factories' `onSearchStart`/`onSearchEnd`/`onSearchTotal`/`onSearchSelected` to the owning `Session` (direct field writes, the `splitFocused` precedent): START — if the session's bar is ALREADY visible call `endSearch()` (sends `end_search`, the toggle-close), else open it (`searchActive = true`, seed `searchNeedle` from the returned needle); END — clear `searchActive`/`searchNeedle`/`searchTotal`/`searchSelected` + return focus to the terminal; TOTAL/SELECTED — set `searchTotal`/`searchSelected` (shared `wireSearchCallbacks` helper used by both factories)
- [x] add `AppActions.toggleSearch()` (`focusedSurface().startSearch()`), `updateSearchNeedle(_:)` (set active session's `searchNeedle` + `focusedSurface().sendSearchQuery`), `navigateSearch(_:)` (`focusedSurface().navigateSearch`), and `endSearch()` (`focusedSurface().endSearch()`) — the close path SENDS `end_search`, never just flips `searchActive`, so libghostty exits search mode and the END callback does the clear + refocus
- [x] ensure END returns first responder to the terminal via the existing focus helper (the `onSearchEnd` factory closure calls `activeSurface.focusAfterReparent()`)
- [x] add the "Find…" View-menu item NOW (reads `equivalent(for: .toggleSearch)`, no hardcoded shortcut, calls `actions.toggleSearch()`) so a real ⌘F trigger exists for the empirical check
- [x] empirical check — could not drive ⌘F headlessly (AX/automation keystroke injection denied, osascript error 1002 "not allowed to send keystrokes"; no GUI automation grant available, and the `session.search` control arm is still a Task 7 placeholder so the socket can't drive it either); binding strings to be validated by the Task 8 XCUITest, NSLog left in for that. Isolated Debug instance launched + quit BY PID, deployed app untouched. ✅ CONFIRMED by Task 8's `SearchUITests`: ⌘F → `start_search`, typed needle → `search:<needle>`, NSLog showed `START` then `TOTAL=5`→`TOTAL=4` and `SELECTED=-1` callbacks firing → counter populated; binding strings work end-to-end, NSLog removed.
- [x] build the app target — must compile; behavior covered by the Task 8 UI test

### Task 6: Search bar UI + detailPane placement (app)

**Files:**
- Create: `agterm/Views/TerminalSearchBar.swift`
- Modify: `agterm/ContentView.swift` (the `WindowContentView` `detailColumn`/`detailPane` seam)

- [x] create `TerminalSearchBar` (SwiftUI): a `magnifyingglass` + bound `TextField` (a11y id `search-field`), the `searchDisplayText` counter (a11y id `search-counter`), up/down/close buttons; `onSubmit` → next, Shift-Enter → previous, `.onKeyPress(.escape)` → close; `@FocusState` focuses the field on appear; styled to the terminal theme colors
- [x] render it as `.overlay(alignment: .top) { searchBarLayer }` on `detailPane` (NOT inside `sessionDetail`), shown only when `store.activeSession?.searchActive == true`, reading/writing that session's `searchNeedle` and driving `actions.updateSearchNeedle`/`navigateSearch`/`endSearch`
- [x] verify by inspection that `sessionDetail`'s HSplitView subtree is unchanged (no new conditional sibling, no toggled pane modifier) so the NSSplitView can't overrun the titlebar
- [x] build the app target — must compile; behavior covered by Task 8 UI test

### Task 7: Palette entry, control server arm, and CLI (app + agtermctlKit)

**Files:**
- Modify: `agterm/Palette.swift` — `paletteActions()` entry
- Modify: `agterm/Control/ControlServer.swift` — the `.sessionSearch` dispatch arm (`searchSession`)
- Modify: `agtermCore/Sources/agtermctlKit/Commands.swift` — the `session search` subcommand

(The Find… menu item is added in Task 5 with the trigger; this task adds the remaining surfaces.)

- [x] add the `paletteActions()` "Find…" entry calling `actions.toggleSearch()`
- [x] add the `.sessionSearch` arm, mirroring the `session.type`/floating-overlay arm pattern: resolve via `resolveSession`, SELECT the target (so the bar + highlights are visible and the surface mounts), then guard `activeSurface as? GhosttySurfaceView` with a bounded realize-poll → error `session not realized` if still nil; then `close` → `endSearch()`; else `startSearch()` if not `searchActive`, `sendSearchQuery` if `text` present, `navigateSearch` if `to == next|prev`; bounded-poll `session.searchTotal` (the overlay-result idiom) → return `ControlResult(count: total, text: session.searchDisplayText)`
- [x] add the `session search [needle] --next|--prev|--close` CLI subcommand with a `validate()` rejecting flag combos; human output prints `result.text` (else `ok`), `--json` the full result; NOT in `echoesResultID`
- [x] write a CLI parse unit test (in `agtermctlKit` tests) for `session search` arg → `ControlRequest` mapping incl. the mutually-exclusive `validate()`
- [x] build the app + `swift build --product agtermctl`; `cd agtermCore && swift test` — must pass before next task

### Task 8: GUI search XCUITest (app)

**Files:**
- Create: `agtermUITests/SearchUITests.swift`

- [x] add `testSearchBarOpensTypesAndCounts`: launch via `launchForUITest()`, type known output into the terminal, ⌘F (or the Find menu item), wait for `search-field`, type a needle that matches, assert `search-counter` reports a non-empty "of"/"matches" value
- [x] add a close assertion: Esc (or ⌘F again) hides `search-field`
- [x] run ONLY `-only-testing:agtermUITests/SearchUITests` (per the ASK-before-full-run rule) — must pass before next task

### Task 9: session.search control e2e (app)

**Files:**
- Modify: `agtermUITests/ControlAPIUITests.swift`

- [x] add `testSessionSearch`: drive `agtermctl session search "<needle>"` against the isolated socket, assert a non-error response with a `count`/`text`; then `--next`, `--prev`, and `--close` each round-trip ok
- [x] run ONLY `-only-testing:agtermUITests/ControlAPIUITests` — must pass before next task

### Task 10: Verify acceptance criteria

- [x] verify ⌘F opens the bar over the focused pane, typing highlights + counts, ⌃/⌄/Enter/Shift-Enter step, Esc/⌘F close, focus returns to the terminal — ⌘F-open + type-needle + counter + Esc-close are proven by `SearchUITests` (`testSearchBarOpensTypesAndCounts`, `testSearchBarCloses`, both green). The match HIGHLIGHT rendering in the Metal surface and first-responder returning to the terminal after Esc are manual test (skipped - not automatable; the Metal surface is unobservable by XCUITest, so the AX `search-counter`/open/close is the automated proxy, which passes)
- [x] verify the search bar opening/closing does NOT overrun the NSSplitView into the titlebar on a split session (open a split, then ⌘F) — structural guarantee (no sibling added to `sessionDetail`'s HSplitView ZStack; `searchBarLayer` is anchored on `detailPane` via `.overlay(alignment: .topTrailing)`, the same level as `floatingOverlayLayer`, verified in Task 6 and re-confirmed by inspection of `ContentView.swift:310` + `searchBarLayer`). `SearchUITests` opens the search bar without crash. The interactive split-then-⌘F visual is manual test (skipped - not automatable; the overrun is structurally precluded because the split subtree shape is constant whether the bar is shown)
- [x] verify `agtermctl session search` open/needle/next/prev/close all work against a live (isolated) instance and the count settles — proven by `ControlAPIUITests/testSessionSearch` (green, 3.6s): drives `session search "<needle>"` against the isolated socket asserting a non-error count/text, then `--next`/`--prev`/`--close` round-trip
- [x] verify the keymap path: `map cmd+shift+l toggle_search` rebinds it and `keymap.conf` starter documents `toggle_search` — added `KeymapTests.rebindToggleSearchResolvesThroughGenericPath` (green): `map cmd+shift+l toggle_search` parses clean and `equivalent(for: .toggleSearch)` returns the override (the generic `parseMapLine` → `BuiltinAction(rawValue:)` → `resolveBuiltinOverrides` path covers every case via `allCases`, no per-action special-casing). `BuiltinAction.toggleSearch.defaultChord == cmd+f`. Starter doc confirmed by inspection: `SettingsModel.starterKeymapText` iterates `BuiltinAction.allCases` (`SettingsModel.swift:143`), so it renders `toggle_search   cmd+f` automatically with no generator change
- [x] run `cd agtermCore && swift test` (full host-free suite) and the two affected XCUITest classes — host-free suite green: 589 tests in 27 suites (was 588 + the new keymap rebind test). `SearchUITests` green (2 tests, ~20s). `ControlAPIUITests/testSessionSearch` green (~7s). Per the cadence rule, only the affected scope was run, NOT the full ~460s ControlAPIUITests suite
- [x] confirm `golangci`-equivalent is N/A (Swift); ensure no compiler warnings introduced — N/A confirmed (Swift project, no go.mod). Clean recompile of all search-affected sources (forced via touch) → **BUILD SUCCEEDED** with ZERO compiler warnings in the search code. One warning remains at `GhosttyCallbacks.swift:77` ("main actor-isolated property 'shouldCloseOnChildExitAction' can not be referenced from a nonisolated context") — it is in the `GHOSTTY_ACTION_SHOW_CHILD_EXITED` arm, PRE-EXISTING (introduced by commit 35492fd "feat: add per-session overlay terminal", 2026-06-18, predates this plan) and OUTSIDE the search change. The four search arms (lines 80–106) are warning-free (they always return `true` and never read a `@MainActor` property synchronously to decide the return). Left untouched per the verification-task scope; flagged for orchestrator/review to decide

### Task 11: Update documentation (incl. the agent-skill keep-in-sync mirror)

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md` (the Control API command catalog + count, the Menu/actions + Keymap sections)
- Modify: `agterm/Resources/agent-skill/SKILL.md`, `reference.md`, `examples.md`
- Move: this plan → `docs/plans/completed/`

- [x] README: document the search feature (⌘F, the bar, navigation, `agtermctl session search`)
- [x] CLAUDE.md: add `session.search` to the Control API catalog, bump the command count 35 → 36, note `toggle_search`/⌘F in the Menu + Keymap `BuiltinAction` lists (the starter is generated app-side in `SettingsModel.starterKeymapText`), and add the search-bar placement rule (anchored on `detailPane`, never in `sessionDetail`) to the ContentView/NSSplitView notes
- [x] agent-skill (HARD keep-in-sync): add `session.search` to `SKILL.md` (command summary + count), full per-command detail to `reference.md`, and an `agtermctl session search` recipe to `examples.md`
- [x] `mkdir -p docs/plans/completed` and move this plan there (orchestrator moves the plan at finalize)

## Post-Completion
*Items requiring manual intervention or external systems — no checkboxes, informational only*

**Manual verification:**
- Visually confirm match highlighting renders in the live surface (the Metal surface is not observable by XCUITest; the counter is the automated proxy) and that the cursor/selection returns cleanly on close.
- Confirm focus return after Esc does not race (the bar's field releasing first responder back to the terminal), especially on a split session — reuse the `focusAfterReparent` bounded retry if a single `makeFirstResponder` loses the race.

**Optional enhancement (deliberately out of v1 scope):**
- Needle debounce: macterm delays publishing 1–2 char queries by 300ms (immediate for empty or ≥3 chars) to avoid highlighting huge match sets on a single character. v1 sends on every keystroke to keep the model Combine-free; add an app-side debounce later if short-query latency is noticeable. (Flagged here, not silently dropped.)

---
Smells pre-check: skipped — non-Go project (no go.mod; the Go signature-smell rules do not apply to this Swift codebase).
