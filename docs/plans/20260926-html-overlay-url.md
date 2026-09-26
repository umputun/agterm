# HTML overlay URL mode

## Overview
- `agtermctl session overlay open --url URL` shows a web page by URL in the same overlay slots as
  `--html FILE`: session-wide (full or `--size-percent`) or one split pane. The main use is an agent's
  running dev server (`http://localhost:5173`) or a docs page, next to the terminal that drives it.
- It reuses everything `--html` built: slot rules, close/resize/Command-W, reload and navigate twins,
  opt-in `--navigation` toolbar, presenter refusal, the `htmlOverlays` read-back.
- Also fixes two gaps URL mode makes obvious for file pages too: a failed load is invisible (only the
  tree reports it), and a load the policy cancels (a first open or a reload redirected off-origin)
  leaves `loading` forever.

## Context (from discovery)
- Model and policy: `agtermCore/Sources/agtermCore/HtmlOverlay.swift` (`HtmlOverlay.file/grantRoot`,
  `grantError`, `HtmlNavigationPolicy.decide`, `HtmlNavigationAction`). These types exist only on this
  unmerged branch, so their shape is free to change; program-overlay APIs stay compatible.
- Store: `AppStore+HtmlOverlay.swift` (`openHtmlOverlay`, reload, load state, page info, nodes).
- Control: `ControlProtocol.swift` (`ControlArgs.html`, `OverlayHtmlError`), `ControlDispatcher+Overlay.swift`
  (open validation, `grantError` at :113), `ControlProjection.swift` (`ControlHtmlOverlayNode`, `file`
  non-optional today), CLI `agtermctlKit/SessionCommands.swift:550-610` and `OverlayPageCommands.swift`.
- App: `agterm/Views/HtmlOverlayRegistry.swift` (`HtmlOverlayPage` builds `WKWebView` with a default
  `WKWebViewConfiguration`, `loadOriginal` at :193, `apply` gates `--current` on `grantRoot`,
  `decidePolicyFor` at :213, `reportFailure` at :252 ignores cancellation and WebKit 102),
  `agterm/Views/HtmlOverlayView.swift` (no error presentation), `agterm/Control/ControlServer+SessionActions.swift`
  (`openSessionOverlay` branches only on `options.html` at :31, its helper builds `HtmlOverlay(file:)` at :66).
- `agterm/Info.plist` has no `NSAppTransportSecurity` keys.
- Tests: `agtermCore/Tests/agtermCoreTests/{HtmlOverlayTests,ControlDispatcherOverlayTests,
  AppStoreTreeProjectionTests}.swift`, `agtermctlKitTests/OverlayCommandsTests.swift`,
  hosted `agtermTests/HtmlOverlayRegistryTests.swift`, XCUITest `agtermUITests/ControlHtmlOverlayUITests.swift`.

## Development Approach
- **testing approach**: TDD for everything host-free in `agtermCore` (source model, origin rule, policy,
  dispatcher, projection, CLI); the WebKit adapter gets hosted tests against an in-process HTTP listener,
  plus one XCUITest.
- run only the tests a task touches; full gates (`make build`, `swift test`, `make test-app`, `make lint`)
  run once, in the verification task.
- `agtermCore` stays free of WebKit/AppKit.
- **CRITICAL: update this plan file when scope changes during implementation**

## Testing Strategy
- **unit tests**: source parsing and validation, origin equality (scheme/host case, default ports), policy
  rows for URL pages beside the unchanged file-page rows, dispatcher refusals, projection (`file` xor `url`,
  `cwd` only for files), CLI flag conflicts.
- **hosted tests** (`agtermTests`, local `NWListener` in the test process): URL page loads; same-origin
  redirect loads; cross-origin redirect on the first load ends `failed` with an error instead of `loading`;
  connection refused ends `failed`; `localhost`, `127.0.0.1` and `::1` load over plain http; a cookie or
  `localStorage` value survives reload but not close plus a new overlay; the error panel is shown for a
  failed page.
- **UI test**: one `--url` open against a listener started by the test, rendered text visible, ⌘W closes.

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix, blockers with ⚠️ prefix

## Solution Overview
- **Source.** `HtmlOverlay` carries one `source`: `.file(path, grantRoot)` or `.url(URL)`. Reload of the
  original loads the source; `--current` reloads what is shown. The wire populates exactly one of `file`
  and `url`; `cwd` appears only for a file source.
- **Validation.** `--url` is exclusive with COMMAND, `--html`, `--cwd`, `--wait` and `--block`. The
  dispatcher accepts an absolute `http`/`https` URL with a host and refuses anything else by name. The CLI
  passes the string through unnormalized.
- **Origin.** A URL page is pinned to the ORIGINAL URL's origin: lowercase scheme and host, effective port
  (omitted = 80 for http, 443 for https).
- **Navigation policy for a URL page**, in order: new-window targets follow the shipped rule (clicked
  http(s) opens in the browser, else cancel); `about:` loads (blank and srcdoc); `file:` is cancelled;
  main-frame http(s) to the pinned origin loads in place whether or not user-activated (dev-server
  redirects, SPA routing); main-frame http(s) to another origin opens in the browser only when clicked,
  else cancel; subframe http(s) loads so embeds work. This accepts same-origin redirects only: an
  http-to-https upgrade, a canonical-host redirect or an external login flow on the first load is refused
  and reported. File-page policy is unchanged.
- **Blocked load.** Every explicitly started load (open, bare reload, `--current` reload) ends `loaded` or
  `failed`. The page tracks the attempt in flight; when the policy cancels that attempt's main-frame
  navigation, the page goes `failed` with a message naming the blocked destination instead of staying
  `loading`. A clicked link handed to the browser is not an attempt and leaves the loaded page as it is.
- **Visible errors.** A `failed` page, file or URL, shows a small themed error panel in the overlay with
  the error text; reload clears it.
- **Storage.** Every page gets its own `WKWebsiteDataStore.nonPersistent()`, set on the configuration
  before the web view is created and kept with the page through reload, hiding, swaps and soft-close undo.
  Browser storage is in memory and per overlay; server-side effects are the server's.
- **ATS.** Declare `NSAllowsLocalNetworking`: its default differs across the supported macOS range
  (Apple documents version-dependent IP-literal behavior), so one test Mac cannot justify omitting it.
  Hosted probes on `localhost`, `127.0.0.1` and `::1` validate the behavior. The key covers unqualified
  names, `.local` and IP literals, not just loopback, and applies to file pages' network loads too. The docs
  expect https for public hosts and do not promise that the plist blocks every public http load.
- **Remote.** `localhost` means the Mac serving the control socket; the docs say the server must be
  reachable from that Mac. `--url` is refused while a presenter owns the session, like `--html`.

## Technical Details
- `ControlArgs.url: String?`; `OverlayHtmlError` gains `urlAndHtml`/`urlWithCwd` style refusals plus
  `invalidURL` (`url must be an absolute http or https URL`).
- `ControlHtmlOverlayNode`: `file: String?`, new `url: String?`; `page` keeps the current location (a
  path for files, the absolute URL for URL pages).
- `HtmlNavigationPolicy.decide` gains the URL branch; `HtmlNavigationAction` is unchanged.
- The app reports a blocked load through `setHtmlLoadState(.failed, error:)` from `decidePolicyFor` when
  it cancels the main-frame navigation of the load attempt in flight; the attempt ends on `didFinish`,
  a reported failure, or that cancellation.

## What Goes Where
- **Implementation Steps**: code, tests and docs in this repo.
- **Post-Completion**: manual check against a real dev server.

## Implementation Steps

### Task 1: URL source, origin rule, policy and control surface in agtermCore

**Files:**
- Modify: `agtermCore/Sources/agtermCore/HtmlOverlay.swift`, `AppStore+HtmlOverlay.swift`,
  `ControlProtocol.swift`, `ControlDispatcher+Overlay.swift`, `ControlDispatcherOptions.swift`,
  `ControlProjection.swift`, `agtermctlKit/SessionCommands.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/{HtmlOverlayTests,ControlDispatcherOverlayTests,
  AppStoreTreeProjectionTests}.swift`, `agtermctlKitTests/OverlayCommandsTests.swift`,
  `MockControlActions.swift` if the action signature changes

- [x] failing tests first: source/origin equality (case, default ports), URL policy rows (same origin
      activated or not, cross origin clicked vs redirect, subframe http, about:, file: refused, new window),
      file-page rows unchanged
- [x] `HtmlSource` enum on `HtmlOverlay`; `grantError` moves under the file case; origin helper
- [x] URL branch in `HtmlNavigationPolicy.decide`
- [x] failing dispatcher and CLI tests: `--url` exclusivity, invalid schemes/hosts refused, `--url`
      passes through unnormalized, `--url --navigation` is forwarded (both layers accept it with a URL);
      projection `file` xor `url`, `cwd` only for files
- [x] `ControlArgs.url`, dispatcher validation and open path, projection fields, CLI `--url` flag and help
- [x] `swift test --filter` the touched suites pass
- [x] ➕ app call sites moved to the source model so the app builds: `openSessionOverlay` routes
      `options.page`, `loadOriginal` switches on the source (a URL loads with `load(URLRequest)`), and
      `apply` reloads the current page for every source except a text-loaded file

### Task 2: WebKit adapter: URL loading, per-page storage, failure reporting and error panel

**Files:**
- Modify: `agterm/Views/HtmlOverlayRegistry.swift`, `agterm/Views/HtmlOverlayView.swift`,
  `agterm/Control/ControlServer+SessionActions.swift`, `agterm/Info.plist`
- Modify: `agtermTests/HtmlOverlayRegistryTests.swift`, `agtermUITests/ControlHtmlOverlayUITests.swift`

- [x] `openSessionOverlay` routes a URL source through the page path (reservation checks, follow,
      presenter refusal) before any program or remote-job handling (done in Task 1)
- [ ] per-page `WKWebsiteDataStore.nonPersistent()` on the configuration before `WKWebView` is created
- [x] `loadOriginal` loads a URL source with `load(URLRequest)`; `apply` honors `--current` for URL pages
      too, not only file pages with a grant (done in Task 1)
- [ ] track the load attempt in flight; `decidePolicyFor` reports a cancelled main-frame navigation of
      that attempt as `failed` with the blocked destination; a clicked link sent to the browser leaves
      the loaded page alone
- [ ] themed error panel in `HtmlOverlayView` for a `failed` page, cleared by reload
- [ ] declare `NSAllowsLocalNetworking` in `agterm/Info.plist`
- [ ] hosted tests with an in-process listener: load, same-origin redirect, blocked cross-origin
      redirect on open ends failed, a loaded page whose reload is redirected off-origin ends failed,
      connection refused ends failed, `/a` -> `/b` then `--current` stays on `/b` and bare reload returns
      to `/a`, cookie/localStorage survive reload but not a new overlay, error panel shown, plain http
      on `localhost`/`127.0.0.1`/`::1` loads
- [ ] one XCUITest: `--url` to a test listener renders and ⌘W closes
- [ ] run the touched hosted and UI tests

### Task 3: Documentation
- [ ] `plugins/agterm/skills/agterm/`: the description's HTML phrase becomes a compact "preview HTML
      files, URLs or dev servers" trigger, shortening other wording to stay within 1024; `when_to_use`
      adds a dev-server preview phrase; the HTML artifact section and command summary gain `--url` with
      the reachable-from-this-Mac note; `reference.md` entry and read-back fields
- [ ] `site/commands.html`, `site/docs.html`, `site/llms.txt`
- [ ] `.claude/rules/control-api.md`: source model, origin rule, first-load failure, per-page storage, ATS

### Task 4: Verify acceptance criteria
- [ ] every Overview and Solution Overview item implemented
- [ ] full gates once: `make build`, `cd agtermCore && swift test`, `make test-app`, `make lint`
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion
- Manual check against a real dev server (Vite or similar) with hot reload, and a public https docs page.
