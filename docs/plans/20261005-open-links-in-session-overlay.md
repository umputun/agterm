# Open terminal links in a session overlay

## Overview
- A new setting chooses where a clicked web link from terminal output opens: the browser (default, today's
  behavior) or a full session web overlay with JavaScript, the navigation bar and saved logins.
- Only `http`/`https` links are affected. `mailto`, `ftp` and the Finder reveal of `file://` stay as they are.
- A link in a markdown HUD always opens in the browser, whatever the setting says, and the HUD stays up.
- While a HUD is up on a session, links in that session's panes open in the browser too: a full session
  page would close the HUD for good.
- A page opened this way can leave its first site: main-frame navigation across origins is allowed, and the
  panel header names the site of the document shown.
- Whenever the overlay cannot open or would not be visible, an eligible link is handed to the browser
  instead. Ignored schemes stay ignored.
- Control: `agtermctl browser links [browser|overlay]` sets or reads the setting and `tree` reports it.
  `agtermctl session overlay open --url URL --browse --js --navigation --persistent` opens the page a
  click opens; `--browse` alone only widens navigation.

## Context (from discovery)
- Every clicked link ends in `GhosttySurfaceView.openLink` (`agterm/Ghostty/GhosttySurfaceView+Input.swift:583`),
  queued from `GHOSTTY_ACTION_OPEN_URL` in `agterm/Ghostty/GhosttyCallbacks.swift:129`. The callback carries
  the URL only and runs after the click, so the click's modifiers are not available: no per-click override.
- `LinkPolicy.disposition` (`agtermCore/Sources/agtermCore/LinkPolicy.swift`) returns `.open` for
  `http`, `https`, `mailto`, `ftp`; `.reveal` for local `file://`; `.ignore` otherwise.
- HUD links reach the same `openLink` on the HUD's surface (`agterm/Ghostty/HudLinkClick.swift`, #707).
- Surface ownership, enough to tell where a click came from with no new field: `hudBodyFile` is set on a
  HUD surface; `session` on primary and split panes; a sessionless surface whose `focusSession` owns it as
  its scratch surface is the scratch; other sessionless surfaces with a `focusSession` are program
  overlays; a quick terminal has no owner (`TerminalView.swift:47,61` supplies `focusSession`).
- Zoom: while `terminalZoom.target` is set, `WindowContentView.swift:320` hides the split layer and
  `WindowContentView+Zoom.swift:142` hosts the zoomed terminal surface only. Opening a page does not clear
  zoom (`TerminalZoom.swift:217`), so a page opened from a zoomed window is accepted and invisible.
- Slot: `AppStore.openHtmlOverlay` (`agtermCore/Sources/agtermCore/AppStore+HtmlOverlay.swift:40`) closes a
  HUD, then refuses with `.alreadyOpen` for a program or page, and `.presenter` while a presenter owns the
  session. The host adapter `openHtmlOverlay` in `agterm/Control/ControlServer+SessionActions.swift:70`
  also refuses a remotely reserved slot and a failing saved store, then builds a persistent page eagerly
  so `browser.clear` counts it. It is `private`; the `openSessionOverlay` action is its public entry, and
  `GhosttySurfaceView` holds no reference to the server or to settings.
- `openLink` calls `NSWorkspace` directly, so a test of it today opens the real browser or Finder.
- Navigation: `HtmlNavigationPolicy.decide` (`agtermCore/Sources/agtermCore/HtmlOverlay.swift:238`) keeps a
  URL page's main frame on its original origin; anything else goes to a confirm sheet and the browser.
  New-window requests are confirmed-external; `createWebViewWith` returns nil.
- Header: `HtmlOverlay.identity` (`HtmlOverlay.swift:130`) shows the ORIGINAL origin for a URL page;
  `agterm/Views/HtmlOverlayView.swift:81` draws it. Live page facts arrive through `setHtmlPage`
  (`HtmlPageInfo.page` is the current URL).
- Control bridge: installed for file pages only (`HtmlOverlayRegistry.swift:332`), so a URL page with
  JavaScript cannot reach `agterm.request`. This stays.
- Pattern for an app-global browser command: `browser.clear` in `ControlDispatcher+Browser.swift`,
  `ControlActions.clearBrowser`, `ControlServer+AppCommands.swift:134`, `agtermctlKit/MiscCommands.swift`.
- Pattern for a page flag: `--persistent`, see `docs/plans/completed/20261001-html-overlay-persistent-storage.md`
  (`ControlArgs`, `OverlayHtmlError`, `ControlDispatcher+Overlay.swift:39,131`, `ControlHtmlOverlayNode` in
  `ControlProjection.swift:402`).
- Settings: `agtermCore/Sources/agtermCore/AppSettings.swift`, `agterm/SettingsModel.swift`,
  `agterm/Views/SettingsView.swift`; enum-like settings are stored as raw strings and unknown values
  resolve to the default (`.claude/rules/settings.md`).
- `tree` top level: `ControlTree` in `ControlProjection.swift:562`, filled by `ControlServer.buildTree`
  (`ControlServer.swift:803`) and `AppStore.controlTree` (`AppStore.swift:280`); page nodes come from
  `AppStore.htmlOverlayNodes` (`AppStore+HtmlOverlay.swift:138`).
- `HtmlBridge.windowless` (`HtmlBridge.swift:59`) lists the commands a file page may send with no window.
- `--chromeless` already requires `--html` (`OverlayHtmlError.chromelessRequiresFile`), so a URL browsing
  page can never be chromeless.
- `scripts/test-app.sh` passes no arguments to `xcodebuild`, so it always runs the whole hosted suite.

## Development Approach
- **testing approach**: tests first for everything host-free in `agtermCore` (setting, routing decision,
  navigation policy, identity, protocol, dispatcher, projection, CLI); hosted tests on the in-process
  listener for WebKit navigation and for the click path.
- Complete each task before the next; all tests for a task pass before moving on.
- Every task includes its tests. Update this plan when scope changes.
- Existing pages keep their behavior: without `--browse` nothing about a page changes.

## Testing Strategy
- **core tests** (`cd agtermCore && swift test`): each task below.
- **hosted tests**: navigation across origins on the in-process listener, the header label after a
  navigation, the click path with its fallbacks. During a task run them with a direct `xcodebuild test`
  call carrying `-only-testing:agtermTests/<Class>/<test>` and the options `scripts/test-app.sh` uses.
- **gates**, once at the end: `swift test`, `make test-app`, `make lint`, and the Release build
  `scripts/build.sh`.
- One new XCUITest, for the picker, beside its siblings in `agtermUITests/SettingsUITests.swift`; it carries
  the General tab fit assertion. Run it alone with `-only-testing:`. The click path needs none: hosted
  tests cover it through `openLink`.

## Progress Tracking
- Mark completed items with `[x]` when done.
- Add newly discovered tasks with ➕ prefix, blockers with ⚠️ prefix.

## Solution Overview
- **Setting.** `LinkOpenMode` (`browser`, `overlay`) in `agtermCore`, stored on `AppSettings` as a raw
  string, default `browser`. One persistence path serves the Settings picker and the control command.
- **Routing decision in core.** A host-free function decides, from the link disposition, the setting and
  where the click came from, between `browser`, `overlay(sessionID)`, `reveal` and `ignore`. The click
  origin is one of: pane (session id), scratch (owning session id), HUD, program overlay, quick terminal.
  Only pane and scratch with an `http`/`https` link and mode `overlay` give `overlay`. The origin is
  derived from the surface's existing ownership fields.
- **Open with fallback in the app.** `openLink` asks the routing function. The surface gets an injected
  link opener set where surfaces are built; it reads the live setting and, for `overlay`, runs the
  existing `openSessionOverlay` action for the exact owner session id with a browsing page: JavaScript
  on, navigation bar on, saved store, full size, no session selection. Any refusal (occupied or reserved
  slot, presenter, saved store unavailable, unknown session) opens the link in the browser. A page that
  opened and then failed to load stays up with its existing Open in Browser action; no automatic
  browser launch.
- **HUD up.** A pane or scratch click on a session whose HUD is active opens the browser. The opener checks
  this live, after the route chooses the overlay and beside the zoom check. `AppStore.openHtmlOverlay` closes
  a HUD before taking the slot and reports success, so this is checked before the open, not read from a
  refusal.
- **Zoomed window.** A click in a window whose terminal zoom is active opens the browser: the page would
  be hidden behind the zoomed surface. Zoom is left alone, because clearing it returns to the selected
  session, which may not be the one clicked.
- **System effects are injected.** The opener carries the open and reveal effects, `NSWorkspace` by
  default, so tests assert them without opening anything. `mailto`/`ftp` keep the system scheme handler;
  the HTML `SystemBrowser`, which forces the default web browser, is not reused for them.
- **Browsing page.** `HtmlOverlay.browse` is a per-page flag. With it, `HtmlNavigationPolicy` allows
  main-frame `http`/`https` navigation to any origin, user-activated or not (script, form, redirect).
  File and custom schemes stay denied, new-window requests stay confirmed-external, subframes are
  unchanged. Without it, the origin-pinned policy is untouched.
- **No event, no restore.** The setting is poll-only through `tree`; pages stay ephemeral and only the
  setting persists. Each Mac applies its own setting to its own clicks.
- **Header.** For a browsing page, `identity` is the origin of the document currently shown, taken from
  the reported page URL, falling back to the source origin until the first report. Never the page title.
- **Rejected:** keeping a HUD alive under the page (needs HUD ownership separate from the slot occupant),
  a per-click modifier (the callback has no click state), importing browser logins (not possible),
  popup login support (the web view refuses new windows).

## Technical Details
- `AppSettings.linkOpenMode: String?`, `effectiveLinkOpenMode: LinkOpenMode` (unknown or nil → `.browser`).
- `LinkClickOrigin`: `.pane(UUID)`, `.scratch(UUID)`, `.hud`, `.programOverlay`, `.quick`.
- `LinkRoute`: `.browser(URL)`, `.overlay(URL, session: UUID)`, `.reveal(URL)`, `.ignore`;
  `LinkPolicy.route(for:mode:origin:)` wraps `disposition`.
- `HtmlOverlay.browse: Bool`, default false. Valid only with a URL source: `--browse` without `--url` is
  rejected by the dispatcher; the existing `--chromeless requires --html` rule covers the header.
  `--browse` changes navigation scope only; `--js`, `--navigation`, `--persistent` stay separate flags.
- Protocol: command `browser.links` with optional `mode`; no `mode` reads. Refuses a target or `--window`
  like `browser.clear`, and joins `HtmlBridge.windowless`. The effective mode comes back in `result.text`
  so a plain CLI read prints it. `ControlArgs.browse` for `session.overlay.open`.
- Read-back: `ControlTree.linkOpenMode` (always the effective value), `ControlHtmlOverlayNode.browse`
  (decoded with `decodeIfPresent ... ?? false`).
- Settings UI: a picker "Open links in" with "Browser" and "Session overlay", in the General tab's Mouse
  section, accessibility id `settings-link-open-mode`. The tab has a fixed-size window and a fit assertion
  (`SettingsUITests.swift:85`); if the row does not fit, stop and ask before moving anything.

## What Goes Where
- **Implementation Steps**: code, tests and docs in this repo.
- **Post-Completion**: manual checks in an isolated Debug instance.

## Implementation Steps

### Task 1: Setting and link routing in core

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppSettings.swift`
- Modify: `agtermCore/Sources/agtermCore/LinkPolicy.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/LinkPolicyTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppSettingsTests.swift`

- [ ] write tests for `effectiveLinkOpenMode`: nil, `browser`, `overlay`, unknown value, round trip through encode/decode
- [ ] write tests for `LinkPolicy.route`: every origin × both modes for `https`; `mailto`/`ftp` always browser; `file://` always reveal; ignored schemes stay ignored
- [ ] add `LinkOpenMode`, the stored setting and its effective accessor
- [ ] add `LinkClickOrigin`, `LinkRoute` and `LinkPolicy.route`
- [ ] update the `LinkPolicy` doc comment, which says the app side only calls two `NSWorkspace` methods
- [ ] run `swift test` for these suites - must pass before task 2

### Task 2: Browsing pages: navigation scope and current-origin header

**Files:**
- Modify: `agtermCore/Sources/agtermCore/HtmlOverlay.swift`
- Modify: `agterm/Views/HtmlOverlayRegistry.swift`
- Modify: `agterm/Views/HtmlOverlayView.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/HtmlOverlayTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/DashboardCoverTests.swift`
- Modify: `agtermTests/HtmlOverlayRegistryTests.swift`

- [ ] write policy tests: a browsing page allows cross-origin main-frame `http`/`https` navigation with and without user activation; denies `file`, custom schemes and `about` stays allowed; new-window stays external only when user-activated; a non-browsing page decides exactly as before
- [ ] write identity tests: a browsing page shows the reported page's origin, the source origin before the first report, and never the title; a non-browsing URL page and a file page are unchanged; the dashboard cover (`DashboardCover.swift:17,21`) reads the same identity and follows it
- [ ] add `HtmlOverlay.browse` and the policy branch
- [ ] make `identity` follow the shown document for a browsing page; confirm the view redraws when the page report changes
- [ ] update the doc comments this falsifies: `HtmlOverlay.identity`, `HtmlNavigationPolicy`, and `browserURL` in `HtmlOverlayRegistry.swift:424`
- [ ] write hosted tests on the in-process listener: a redirect to a second origin loads in a browsing page and is blocked in an ordinary one; first committed site → second site → back, with the header label following each; a failed or cancelled cross-origin load leaves the label naming the document still shown
- [ ] run the targeted core and hosted tests - must pass before task 3

### Task 3: Control API and CLI

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher+Browser.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher+Overlay.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcherOptions.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlActionsDefaults.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlProjection.swift`
- Modify: `agtermCore/Sources/agtermCore/HtmlBridge.swift`
- Modify: `agtermCore/Sources/agtermctlKit/MiscCommands.swift`
- Modify: `agtermCore/Sources/agtermctlKit/SessionCommands.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift` (`controlTree`)
- Modify: `agtermCore/Sources/agtermCore/AppStore+HtmlOverlay.swift` (`htmlOverlayNodes`)
- Modify: `agterm/Control/ControlServer.swift` (`buildTree`, and the exhaustive command switch at `:574`)
- Modify: `agterm/Control/ControlServer+AppCommands.swift`
- Modify: `agterm/Control/ControlServer+SessionActions.swift`
- Modify: `agterm/SettingsModel.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/` `ControlDispatcherBrowserTests.swift`, `ControlDispatcherOverlayTests.swift`, `AppStoreTreeProjectionTests.swift`, `HtmlBridgeTests.swift`, `MockControlActions.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/MiscCommandsTests.swift` (`browser links`), `OverlayCommandsTests.swift` (`--browse`)
- Modify: `agtermTests/ControlServerTests.swift`

- [ ] write dispatcher tests for `browser.links`: set each mode, bare read, invalid mode, target and `--window` refused
- [ ] write dispatcher tests for `--browse`: accepted with `--url`; rejected with `--html` and without a page; `--url --browse --chromeless` still fails on the existing chromeless rule
- [ ] write projection tests: `tree.linkOpenMode` reports the effective value including the default; `htmlOverlays[].browse` round-trips and decodes as false when absent
- [ ] write CLI tests for `agtermctl browser links` and `session overlay open --browse`
- [ ] add the protocol command, argument, action, dispatch and CLI; add `browser.links` to `HtmlBridge.windowless` with its test, and to the app's command switch
- [ ] implement the app adapter: read and write the setting through the same `SettingsModel` path the picker uses; pass `browse` into `HtmlOverlay`
- [ ] fill `linkOpenMode` in `buildTree`/`controlTree` and `browse` in `htmlOverlayNodes`
- [ ] write a socket round-trip test: set the mode, read it back from `tree`; open a browsing page and read `browse` from `htmlOverlays`
- [ ] run the targeted tests - must pass before task 4

### Task 4: Click path, fallbacks and the Settings picker

**Files:**
- Modify: `agterm/Ghostty/GhosttySurfaceView+Input.swift`
- Modify: `agterm/Ghostty/GhosttySurfaceView.swift`
- Modify: `agterm/agtermApp.swift` (where session surfaces are built and the opener is set; a quick terminal keeps the default, which opens the browser)
- Modify: `agterm/Control/ControlServer+SessionActions.swift`
- Modify: `agterm/Views/SettingsView.swift`
- Modify: `agtermTests/GhosttySurfaceViewInputTests.swift`, `agtermTests/SettingsModelTests.swift`
- Modify: `agtermUITests/SettingsUITests.swift`

- [ ] derive `LinkClickOrigin` from the surface's ownership fields, HUD first; no new identity field
- [ ] add the injected link opener and set it where session surfaces are built; its open and reveal effects are replaceable on their own, so a test swaps them on a factory-built surface and keeps the factory's overlay wiring
- [ ] route `openLink` through `LinkPolicy.route`; for `.overlay`, run `openSessionOverlay` for the owner session id with a browsing page (JavaScript, navigation bar, saved store, full size), without selecting another session
- [ ] fall back to the browser on every refusal (occupied slot, remotely reserved slot, presenter, saved store unavailable, unknown session) when the owner session's HUD is active, and when the owning window's terminal zoom is active
- [ ] add the "Open links in" picker to the General tab, bound to the same setting
- [ ] write hosted tests on surfaces built by the production factories, split and scratch included: pane link in overlay mode opens a browsing page on that session; scratch link opens on its owning session; HUD link opens the browser and the HUD is still active; quick terminal and program-overlay links open the browser; each refusal opens the browser; a pane click on a session with an active HUD opens the browser and the HUD is still active; a click in a zoomed window opens the browser, creates no page and leaves zoom set; `mailto` and `file://` are unchanged; browser mode never opens a page; a browsing page whose load fails stays up and the open effect is not called
- [ ] write a hosted test that the `SettingsModel` value behind the picker and `browser.links` are one value; add `testLinkOpenModePickerPersists` to `SettingsUITests.swift` with the fit assertion and run it alone
- [ ] run the targeted hosted tests - must pass before task 5

### Task 5: Verify acceptance criteria
- [ ] verify each Overview bullet against the built app's tests
- [ ] run `cd agtermCore && swift test`
- [ ] run `make test-app`
- [ ] run `make lint`
- [ ] run `scripts/build.sh` (Release)
- [ ] run `lsappinfo list | grep -A4 agterm.debug` and clear leaked test processes

### Task 6: [Final] Update documentation
- [ ] `site/docs.html`: the setting, what it covers, the fallbacks, HUD links, that logins are agterm's own
- [ ] `site/commands.html`: `browser links`, `--browse`, `tree.linkOpenMode`, `htmlOverlays[].browse`
- [ ] `plugins/agterm/skills/agterm/SKILL.md` and `reference.md`: the command, the flag, both read-backs
- [ ] `.claude/rules/control-api.md`: `browser.links` in the public catalog and in the bridge sentence beside `browser.clear`; record that the setting has no event and pages no restore
- [ ] `.claude/rules/settings.md`: the setting as a control-backed one, like `flaggedViewLayout`
- [ ] `.claude/rules/libghostty.md`: the link routing seam and the injected opener
- [ ] `ARCHITECTURE.md` if the link routing seam is described there
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification** in an isolated Debug instance (`/tmp` state dir, its own socket):
- click a link in overlay mode, sign in on a site with a redirect login, close, click again: still signed in
- confirm the header shows the login site's origin during the redirect
- click a link while a program overlay is up: the browser opens
- click a HUD link: the browser opens and the HUD stays
- click a pane link while a HUD is up: the browser opens and the HUD stays
- click a link in a zoomed pane: the browser opens and zoom stays
- change the picker in Settings and confirm `agtermctl browser links` reads the new value
