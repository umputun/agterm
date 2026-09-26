# HTML overlay

## Overview
- `agtermctl session overlay open --html FILE` renders a local HTML/JS file (typically an artifact an AI
  agent just wrote) in a WKWebView inside the existing overlay slots: session-wide (full or
  `--size-percent`) or one split pane (`--pane left|right`).
- It must feel like a regular overlay that renders HTML instead of running a program: same addressing,
  same `overlay.close` / `overlay.resize` / Command-W behavior, a visible close button, and a status
  read-back. A page never exits on its own, so explicit close is the only way out.
- Integrates as a content variant of the overlay slot (program | html), not a third occupant family
  like the HUD, and not a separate `session.web.*` command family.

## Context (from discovery)
- Overlay model: `Session` session-wide fields (`overlayActive`, `overlaySurface`, `overlayCommand`,
  `overlayCwd`, `overlayBackgroundColor`, `overlayWait`, `overlayExitCode`, `overlaySizePercent`,
  `overlaySlotGeneration`, `hudSpec`) and `PaneOverlay` (`command`, `cwd`, `backgroundColor`, `wait`,
  `replica`) in `agtermCore/Sources/agtermCore/Session.swift`.
- Predicates: `overlayActive` (occupied), `hudActive`, `programOverlayActive` (`overlayActive && !hudActive`),
  `fullOverlayActive`. `programOverlayActive` has 19 code reads across 8 files and today conflates three
  contracts: "something covers the session and owns input", "a TerminalSurface is the topmost surface"
  (`topmostSurface`/`focusTarget`, Session.swift:919-935, `paneOverlaySurface` :700), and "a process is
  running" (`ControlServer+SessionActions.swift:120`, `AppStore.swift:320` tree `overlay` field).
- Store ops: `openOverlay` (`AppStore+Panes.swift:352`, evicts a HUD only), `closeOverlay`,
  `closePaneOverlay`, soft-close undo window (`AppStore+PendingClose.swift:83`), remote handoff
  (`AppStore+RemoteOverlay.swift`, `ControlServer+SessionActions.swift:31` `openRemoteOverlay`),
  presenter check `PresentationHub.hasPresenter(session:)`.
- Control: `ControlProtocol.swift` (`session.overlay.*` cases, `ControlArgs`), validation in
  `ControlDispatcher+Overlay.swift`, read-back in `ControlProjection.swift` (`overlay`,
  `overlaySizePercent`, `paneOverlays`), CLI in `agtermctlKit/SessionCommands.swift:550-625`
  (`--wait`, `--block`, `--cwd`, `--size-percent`, `--background-color`, `--pane`, `--follow`).
- App: session-wide panel `overlayPanel` in `agterm/Views/WindowContentView+Detail.swift:290`
  (`OverlayPanelStyle` resolves geometry/chrome), pane covers in `deckPane` (same file, ~:243), zoom
  hosts in `WindowContentView+Zoom.swift`, overlay factory in `agtermApp.swift:~690-760`, Command-W
  ladder in `AppActions.swift:~240`, refocus `onChange(of: session.programOverlayActive)` at
  WindowContentView+Detail.swift:178.
- No WebKit in the app today. Deployment target macOS 14 (`project.yml`), so WKWebView, not the newer
  SwiftUI `WebView`. agterm is not App Sandboxed; no entitlement change is expected.
- Tests: `agtermCore/Tests/agtermCoreTests` (`ControlDispatcherOverlayTests`, `SessionTests`,
  `TerminalZoomTests`, `AppStoreRemoteOverlayTests`, `AppStoreTreeProjectionTests`),
  `agtermCore/Tests/agtermctlKitTests/CommandsTests.swift`, hosted `agtermTests`, XCUITest
  `agtermUITests/ControlOverlaySplitUITests.swift`.

## Development Approach
- **testing approach**: TDD for everything host-free in `agtermCore` (model, predicates, store slot rules,
  dispatcher, projection, CLI, navigation policy): write the failing test, run it, implement. The
  WKWebView adapter in the app target gets hosted/XCUITest coverage after its code.
- complete each task fully before moving to the next; every task ships its own tests.
- run only the tests a task touches (`swift test --filter ...`, `-only-testing:` for app tests); the full
  gates (`swift test`, `make test-app`, `make lint`) run once, in the verification task.
- `agtermCore` stays free of WebKit/AppKit; the web view, its delegate glue and its lifetime registry live
  in the app target as a side-effect adapter.
- `agtermCore` is a library consumed by `agterm-linux`: add public API, do not narrow or rename existing
  public symbols.
- **CRITICAL: update this plan file when scope changes during implementation**

## Testing Strategy
- **unit tests** (`swift test` in `agtermCore`): content variant, predicate split, slot replacement rules,
  reload revision, load state, soft-close lifetime, presenter refusal, dispatcher validation and
  refusals, projection read-back, CLI path normalization and flag conflicts, navigation policy.
- **hosted tests** (`agtermTests`): registry keeps one WKWebView per slot across remounts and releases it
  on close/finalization; delegate maps navigation actions through the core policy.
- **XCUITest** (`ControlOverlaySplitUITests`, targeted `-only-testing:`): open `--html` session-wide and
  `--pane right`, page content visible, Command-W closes, close button closes, `overlay.reload` keeps the
  cover open, `overlay.result` refused.

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- keep plan in sync with actual work done

## Solution Overview
- **Content variant, additive.** The slot's occupant gains an optional `html: HtmlOverlaySpec?`; nil means
  the existing program occupant. `PaneOverlay` keeps its public `command`/`wait`/`init(command:...)` and
  gains `html` with a default, and the session-wide slot gets one stored `htmlOverlay` property, so
  `agterm-linux` keeps compiling and `Session` grows by a single stored line (it is at 975 of 1000). No
  dummy command string is ever read for an HTML occupant: every program path checks `html == nil` first.
- **Slot-state refusals live in agtermCore.** New store methods return failure enums (the
  `PaneOverlayOpenFailure` pattern): open (occupied by program/page, presenter), reload (empty slot,
  program), and the HTML checks for result/copy/text. The app's control server only maps those enums to
  responses, so every refusal is tested host-free.
- **Predicate split.** Keep `programOverlayActive` meaning a terminal program (TerminalSurface, zoom
  target, exit result). Add `htmlOverlayActive` and a cover predicate `coverOverlayActive`
  (`programOverlayActive || htmlOverlayActive`) for "something covers the session and owns input".
  Every one of the 19 reads is classified into one of the two and the pane path gets the same split
  (`paneOverlayIsHtml(pane)`); nothing manufactures a TerminalSurface for WebKit. Consumers of the old
  "some terminal surface is always active" invariant are covered too, not only the predicate reads:
  `TerminalZoomController.resolveTarget` returns nil when no terminal surface is active (today it falls
  back to `.primary`, which under an HTML cover is the hidden pane), and `dropUnrealizedPaneOverlays`
  never treats an HTML slot as unrealized (it has no TerminalSurface even when fully loaded).
- **Read grant.** `--cwd DIR` is the WebKit read grant (`loadFileURL(_:allowingReadAccessTo:)`) and FILE
  must resolve inside it. Omitted `--cwd` grants the file alone. The page's base URL is always the file's
  own URL, never rebased onto `--cwd`. The CLI makes both paths absolute against the caller's cwd and
  standardizes them before sending; symlinks are kept, so `/tmp` and `/private/tmp` do not mix.
- **Slot rules.** `--html` replaces a HUD (like a program does), is refused over a running program or
  another page in the same slot (`overlay already open` / `pane overlay already open`), clears the
  previous process exit code on open, and bumps `overlaySlotGeneration`. A HUD over a page is refused
  `overlay already open`, exactly as a HUD over a running program is, and a mirrored remote HUD aimed at
  that slot is dropped the same way it is today for a program.
- **Commands.** `overlay.open` takes exactly one of COMMAND or `--html`. `--wait`/`--block` refused with
  `--html`; `--background-color` is the backing painted before load; `--size-percent`, `--pane`,
  `--follow` unchanged. `overlay.close`, `overlay.resize` (session-wide only, panes stay full) and the
  Command-W ladder behave as for programs. New `session.overlay.reload [--pane]`, HTML-only, reloads the
  originally opened file (a fresh document: all page and JS state resets, and an in-grant navigation to
  another file is undone). `overlay.result`/`copy`/`text` refuse an HTML cover with named errors, the
  way they refuse a HUD.
- **Teardown funnel.** Four paths empty the session-wide slot without `closeOverlay`, each only calling
  `overlaySurface?.teardown()`: `closeSession` (AppStore.swift:534), `removeWorkspace` (:575),
  `hardFinalizePendingSessions` (AppStore+PendingClose.swift:479) and window close
  (WindowAccessor.swift:179). A page has no surface, so its JS and network would keep running. One
  session-wide teardown method on `Session` (beside `teardownPaneOverlays`) tears down the terminal
  surface and fires an HTML release hook; all four sites call it, and `teardownPaneOverlay` fires the same
  hook for pane pages. The explicit closes fire it too: `closeOverlay` (AppStore+Panes.swift:397) and
  `closePaneOverlay` (:495) tear down directly and are what `overlay.close`, Command-W and the close
  button reach. Each keeps its own exit-code semantics: `closePaneOverlay` still retains the pane's exit
  code and `teardownPaneOverlay` still clears it, so neither is substituted for the other. The app
  registry subscribes to that hook.
- **Lifetime.** Each HTML open gets an `occupantID` that travels inside the slot value, so pane swap
  (`swapPanes`) and right-to-left promotion (`promotePaneOverlay`) move it with the page. The WKWebView
  lives in an app-side registry keyed by that id, so it follows swaps and promotion, survives session
  switches, pane hide/show and SwiftUI remounts, stays alive through the 3 s soft-close undo, and is
  released on close or close finalization. Adapter callbacks (load state, focus, close) address the
  occupant id, and the store resolves it wherever the slot now is, including a soft-closed session that
  `session(withID:)` no longer finds. Nothing persists across relaunch.
- **Focus resolution.** Under an HTML cover `topmostSurface` and `focusTarget` return nil instead of falling
  through to `activeSurface`, which would hand keys to the hidden pane. One app helper resolves the focus
  target as either the registry's web view or the terminal surface, and every site that casts
  `topmostSurface` to `GhosttySurfaceView` uses it: agtermApp.swift:540 (split collapse, session close),
  :605 (search end), WorkspaceSidebar.swift:756 (sidebar click), AskDialogView.swift:534 (ask dismissal),
  WindowContentView+Detail.swift:187/199, AppActions+Focus.swift:194 and `focusSplitPane`. The Command-W
  ladder (AppActions.swift:235/239) already keys on `overlayActive`/`focusedOverlayPane` and stays
  unedited.
- **Focus.** A pane page reports focus like a pane program overlay does (`agtermApp.swift` `onFocusChange`):
  clicking it sets `splitFocused`, so Command-W, search and `focusedOverlayPane` act on the pane the user
  sees. A page opened on an unfocused pane or in a background session does not take keys. The focus
  restore paths (`AppActions+Focus.swift` after a palette, quick terminal or session switch, and
  `focusSplitPane`) gain an HTML branch that resolves the registry's web view instead of casting
  `topmostSurface` to `GhosttySurfaceView`. Input in the page calls `noteUserActivity`, so auto-follow
  cannot switch sessions while the user is working in it.
- **Navigation.** The policy governs frame navigations only; subresource requests (CDN scripts, images)
  never reach it and load normally. Only user-activated main-frame `http`/`https` link clicks open in the
  default browser (and are cancelled in the view). Unsolicited redirects, subframe navigations off the
  grant, new-window requests (`targetFrame == nil`, including `target=_blank`, and `createWebViewWith`
  returning nil) and any other scheme are blocked. File navigations outside
  the grant are cancelled, never handed to the browser. In-page anchors and same-file loads are allowed.
- **Remote.** Renders on the Mac serving the command. `open --html` is refused while a presenter owns the
  session (`PresentationHub.hasPresenter`); an already-open page stays local when a presenter arrives,
  and close/reload keep working. HTML never enters `openRemoteOverlay`'s program-job path.
- **Dismissal.** Command-W, `overlay.close`, and the toolbar's close button. Escape goes to the page. No
  timer: a preview is intentionally persistent.
- **Toolbar.** A thin bar along the panel's top edge: back and forward (disabled with nowhere to go), reload,
  open in browser, the page's `<title>`, and close. The toolbar's reload reloads the CURRENT page, like a
  browser; `overlay.reload` reloads the ORIGINAL file, which is what an agent wants after rewriting its
  artifact. Open in browser hands the current page to the default browser, which also covers what the
  overlay blocks (popups, uploads, JS dialogs, `target=_blank`). Every button except the title has a control
  twin: `session.overlay.reload --current` and `session.overlay.navigate back|forward|browser`, both taking
  `--pane`. The read-back reports the current page, title and `canGoBack`/`canGoForward` beside the original
  file.
- **Out of v1:** JS-to-native bridge / result reporting, stdin input, suspending hidden pages, remote
  forwarding.

## Technical Details
- `agtermCore`:
  - `public struct HtmlOverlaySpec: Equatable, Sendable { file: String; grantRoot: String? }` — absolute,
    standardized paths; `grantRoot == nil` means the file alone. `readAccessPath` returns `grantRoot ?? file`.
  - `public enum HtmlLoadState: String, Codable, Sendable { case loading, loaded, failed }` plus
    `error: String?`, stored per slot and written by the app adapter through a store method.
  - `reloadRevision: Int` per html slot, bumped by `reloadHtmlOverlay`; the adapter re-runs
    `loadFileURL(spec.file, allowingReadAccessTo: spec.readAccessPath)` when it changes, never
    `WKWebView.reload()` (which reloads the current page), and without a view-identity bump.
  - `occupantID: UUID` in `HtmlOverlaySpec`, assigned at open; the registry and every adapter callback
    key on it.
  - `public enum HtmlNavigationDecision { case allow, openExternal, cancel }` and
    `HtmlNavigationPolicy.decide(_ action: HtmlNavigationAction, spec:) -> HtmlNavigationDecision`, where
    `HtmlNavigationAction` carries url, target (main frame | subframe | new window) and user activation
    — pure, host-free, unit tested.
  - Grant containment: `HtmlOverlaySpec.validate() -> String?` returns an error when FILE is not inside
    `grantRoot` (component-wise prefix on standardized paths, so `/a/bc` is not inside `/a/b`).
- Protocol: `ControlArgs.html: String?`; `session.overlay.reload` case; errors
  `OverlayHtmlError.noResult`, `.noRead`, `.notHtml` (reload on a program), `.presenter`,
  `.commandAndHtml`, `.waitWithHtml`, `.fileOutsideGrant`.
- Read-back on `ControlSessionNode`: `htmlOverlays: [ControlHtmlOverlayNode]?` with
  `pane` (nil for session-wide), `file`, `cwd` (the grant), `state`, `error`, and the current `page` and
  `title` the adapter reports; session-wide size stays in
  `overlaySizePercent`. `overlay` (tree) reports any covering overlay, program or HTML; `paneOverlays`
  keeps listing covered panes of either kind. Terminal surface nodes and surface zoom availability stay
  terminal-only; `htmlOverlays` carries the content distinction.
- CLI: `agtermctl session overlay open [COMMAND] [--html FILE] [--cwd DIR] ...`; client-side
  `validate()` enforces exactly one of COMMAND/`--html` and refuses `--wait`/`--block` with `--html`;
  new `agtermctl session overlay reload [--pane left|right]`.
- App target: `HtmlOverlayRegistry` (owns WKWebView per slot, `@MainActor`), `HtmlOverlayView`
  (`NSViewRepresentable` hosting the registry's view, close button in a SwiftUI overlay),
  `HtmlOverlayNavigator` (`WKNavigationDelegate` + `WKUIDelegate`, delegating decisions to
  `HtmlNavigationPolicy`, reporting load state to the store, treating
  `webViewWebContentProcessDidTerminate` as `failed`). The UI delegate denies everything it is asked:
  media capture permission, JS `alert`/`confirm`/`prompt` (no panel, `confirm` answers false), and the
  file-upload panel.
- File placement against the lint limits: new store ops in `AppStore+HtmlOverlay.swift` (AppStore.swift
  is at 988), Session behavior in `Session+HtmlOverlay.swift` (only the stored property goes in the class
  body), the CLI reload subcommand in its own `agtermctlKit` file (SessionCommands.swift is at 971), and
  the new CLI tests in `OverlayCommandsTests.swift` (CommandsTests.swift is at 1996 of 2000). No existing
  file is split.

## What Goes Where
- **Implementation Steps**: code, tests and docs in this repo.
- **Post-Completion**: manual checks in an isolated Debug instance.

## Implementation Steps

### Task 1: HTML overlay model, slot rules, predicate split and navigation policy in agtermCore

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Session.swift`
- Create: `agtermCore/Sources/agtermCore/HtmlOverlay.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+Panes.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+PendingClose.swift`
- Modify: `agtermCore/Sources/agtermCore/TerminalZoom.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+RemoteOverlay.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift` (teardown call sites only)
- Create: `agtermCore/Sources/agtermCore/AppStore+HtmlOverlay.swift`
- Create: `agtermCore/Sources/agtermCore/Session+HtmlOverlay.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/SessionTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/TerminalZoomTests.swift`
- Create: `agtermCore/Tests/agtermCoreTests/HtmlOverlayTests.swift`

- [x] slot rules, test first: HTML open replaces a HUD, is refused over a program or another page
      (session-wide and per pane) and while a presenter owns the session, clears the prior exit code and
      bumps the slot generation; reload bumps only `reloadRevision`; load state round-trips by occupant id,
      including for a soft-closed session; soft-close keeps the HTML slot until finalization; HTML never
      enters the remote program-job handoff
- [x] occupant identity, test first: `swapPanes` with two HTML pages keeps each id with its page; promotion
      moves the right page's id to the left slot; close, reload and load-state writes after either move
      reach the moved slot
- [x] pane retention, test first: `dropUnrealizedPaneOverlays` keeps an HTML slot; hiding and re-showing
      the split keeps the page slot and its id
- [x] `HtmlOverlaySpec` (grant containment, `occupantID`), `HtmlLoadState`, added to `PaneOverlay` and the
      session-wide slot without removing any public member
- [x] refusal enums, test first: open, reload and the result/copy/text HTML checks return typed failures
      from store methods; HUD over a page refused
- [x] teardown funnel, test first: `overlay.close` (session-wide and each pane), session close, workspace
      delete, hard finalization of pending closes and split close each fire the HTML release hook exactly
      once; a program pane closed with `closePaneOverlay` still reports its exit code afterwards
- [x] predicate split, test first: `htmlOverlayActive`, `coverOverlayActive` and pane equivalents; all 19
      `programOverlayActive` reads classified (cover vs terminal-program) and the classification recorded
      in `control-api.md`'s overlay section; focus targets stay terminal-only under HTML while the cover
      predicate is true (`topmostSurface`/`focusTarget` nil under a page); `TerminalZoom` treats an HTML cover as covering but never as a zoom target, and
      bare `resolveTarget` returns nil under a session-wide page and under a page on the focused pane
      (left and right)
- [x] navigation policy, test first: `HtmlNavigationPolicy.decide` table over frame navigations: initial
      file load and same-file anchors (allow), user-activated main-frame http(s) (openExternal),
      non-activated http(s) redirects and script navigation (cancel), `file:` inside the grant main frame
      and subframe (allow), `file:` outside the grant (cancel), new-window targets (cancel), other schemes
      (cancel)
- [x] `swift test --filter` for the touched suites passes

### Task 2: Control surface: protocol, dispatcher, read-back and agtermctl

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher+Overlay.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift` (`ControlActions` overlay methods)
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcherOptions.swift` (`ControlSessionOverlayOpenOptions`)
- Modify: `agtermCore/Sources/agtermCore/ControlActionsDefaults.swift` (default reload returning
  `ControlActionsUnsupported`)
- Create: `agtermCore/Sources/agtermctlKit/OverlayReloadCommand.swift`
- Create: `agtermCore/Tests/agtermctlKitTests/OverlayCommandsTests.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlProjection.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift`
- Modify: `agtermCore/Sources/agtermctlKit/SessionCommands.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherOverlayTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreTreeProjectionTests.swift`

- [x] dispatcher, test first (argument validation only): exactly one of command/html; `--wait` with html
      refused; file outside grant refused; `--pane` + `--size-percent` still refused; reload argument
      shape. Slot-state refusals are Task 1's store tests; the `OverlayHtmlError` messages are the mapping
      of those enums, tested once here
- [x] `ControlSessionOverlayOpenOptions` gains `html` additively; `ControlActions.reloadSessionOverlay` has a
      default in `ControlActionsDefaults.swift`
- [x] read-back, test first: `htmlOverlays` for session-wide and both panes with state and error, and
      `overlay`/`paneOverlays` under an HTML cover
- [x] agtermctl, test first: COMMAND optional only with `--html`; both or neither rejected; `--wait` and
      `--block` rejected with `--html`; relative FILE and `--cwd` resolved against the caller's cwd and
      standardized; `session overlay reload --pane` request shape; `--cwd` help states its HTML meaning
- [x] ➕ `session.overlay.reload --current` and `session.overlay.navigate back|forward|browser` (toolbar twins):
      dispatcher, defaults, CLI (`OverlayPageCommands.swift`) and read-back of page/title/history, tested
- [x] `swift test` for `agtermCoreTests` and `agtermctlKitTests` touched suites passes

### Task 3: WKWebView adapter, deck wiring, focus and Command-W

**Files:**
- Create: `agterm/Views/HtmlOverlayView.swift`
- Create: `agterm/Views/HtmlOverlayRegistry.swift`
- Modify: `agterm/Views/WindowContentView+Detail.swift`
- Modify: `agterm/Views/WindowContentView+Zoom.swift`
- Modify: `agterm/agtermApp.swift`
- Modify: `agterm/AppActions+Focus.swift`
- Modify: `agterm/Views/WorkspaceSidebar.swift`
- Modify: `agterm/Views/AskDialogView.swift`
- Modify: `agterm/Views/WindowAccessor.swift`
- Modify: `agterm/Control/ControlServer+SessionActions.swift`
- Modify: `agterm/Control/ControlServer+SurfaceIO.swift`
- Modify: `project.yml` (link WebKit if not implicit)
- Create: `agtermTests/HtmlOverlayRegistryTests.swift`

- [ ] `HtmlOverlayRegistry`: one WKWebView per `occupantID`, created on first mount, reused across remounts,
      session switches, pane swap/promotion and hide/show, released when the store closes or finalizes the
      slot; `loadFileURL` with `spec.readAccessPath`; reload re-loads `spec.file` on `reloadRevision` change
- [ ] `HtmlOverlayView` + navigator: delegate decisions to `HtmlNavigationPolicy`, open externals via
      `NSWorkspace`, report loading/loaded/failed (including WebContent termination), current page and
      title to the store, paint `--background-color` as backing
- [ ] toolbar: back/forward bound to the web view's history (disabled when unavailable), reload of the
      current page, open in browser, page title, close calling the store close
- [ ] mount it in `overlayPanel` (session-wide, full or floating via `OverlayPanelStyle`) and in `deckPane`
      (pane cover); HTML is never mounted in the zoom hosts
- [ ] focus: a page on the focused pane or session-wide takes first responder on open, one on an unfocused
      pane or in a background session does not; clicking a pane page sets `splitFocused`; focus restore
      after a palette, quick terminal or session switch, `focusSplitPane`, split collapse, search end,
      sidebar click and ask dismissal all go through the one focus-target helper; page input calls `noteUserActivity`; refocus-on-close keys on the cover predicate; Command-W
      ladder closes an HTML cover (session-wide and focused pane)
- [ ] control server maps the Task 1 failure enums to responses and dispatches reload; window close calls the
      teardown funnel; the UI delegate denies media capture, JS dialogs and file upload
- [ ] hosted tests for the registry lifetime (remount reuse, swap and promotion keep the right view, release
      on close and on soft-close finalization), navigator-to-policy mapping, a local subresource inside the
      grant loading, and reload after an in-grant navigation from a.html to b.html returning to a.html;
      run with `-only-testing:agtermTests/HtmlOverlayRegistryTests`
- [ ] XCUITest cases in `ControlOverlaySplitUITests`: session-wide and `--pane right` open, content visible,
      Command-W and close button close, reload keeps the cover, result refused, click the right-pane page
      then Command-W closes the right page, a background open does not steal focus, focus returns to the
      page after the command palette closes; run only those methods

### Task 4: Verify acceptance criteria
- [ ] every Overview/Solution Overview item implemented, including presenter refusal and grant containment
- [ ] edge cases: missing file (failed state with error), file outside grant, reload after the file changed,
      session close with undo then restore
- [ ] full gates once: `make build`, `cd agtermCore && swift test`, `make test-app`, `make lint`

### Task 5: [Final] Update documentation
- [ ] `.claude/rules/control-api.md`: `.overlay.reload` in the public catalog (line ~157), HTML variant,
      predicate classification, teardown funnel, refusals, read-back, remote rule
- [ ] `plugins/agterm/skills/agterm/`: `overlay open --html`, `overlay reload`, read-back fields
- [ ] `site/commands.html` (arguments, read-back) and `site/docs.html` (user guide section); `site/index.html`
      if the feature earns a home-page mention
- [ ] `ARCHITECTURE.md` if the app adapter/registry split needs a line
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion
*Manual verification in an isolated Debug instance (short `/tmp` `AGTERM_STATE_DIR`, never the live socket)*
- an agent-style artifact with CDN scripts renders and runs; links open in the browser only on click
- floating `--size-percent 70`, full, and `--pane right` all look like the program overlay equivalents
- switching sessions and back keeps page state; closing the session and undoing keeps it too
- after close, the registry holds no view for the page and the page's activity has stopped

Smells pre-check: skipped — non-Go project
