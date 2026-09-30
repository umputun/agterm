# HTML overlay bridge: agterm commands from file pages

## Overview
- A file page shown with `session overlay open --html` can run any agterm command, read the tree,
  switch sessions, and return a chosen value to a script waiting on `--block`, the way `pick` does.
- Two surfaces:
  - `data-agterm` tag attributes, handled by an agterm-injected script, work with page JavaScript off.
  - `agterm.request(cmd, {target, args})` is available on `--js` pages and returns the reply.
- One new socket command, `session.overlay.submit`, turns a page into a selector.
- No permission tiers: pages are self-authored and trusted like a program overlay, which already gets
  `AGTERM_SOCKET`. `--url` pages get nothing.
- Out of scope: `data-agterm-trigger`, `data-agterm-confirm`, templates, `agterm:` links, a URL scheme
  handler, and pushing tree changes into a page. Live lists use `--js`.

## Context (from discovery)
- Web view: `agterm/Views/HtmlOverlayRegistry.swift` (583 lines).
  - `install()` (:19) owns the single `HtmlOverlayReleases.shared.onRelease` callback and is called from
    `AppDelegate.swift:83`.
  - `installTheme` (~193) calls `removeAllUserScripts()` and adds only the theme user script, in
    `themeWorld`.
  - `close()` (~252) clears delegates.
- Page model and release seam: `agtermCore/Sources/agtermCore/HtmlOverlay.swift`.
  - `HtmlNavigationPolicy` (~206).
  - `HtmlOverlayReleases.release()` (~235) fires once per page from every path that empties a slot.
- Slot lookup: `AppStore+HtmlOverlay.swift`.
  - `htmlOverlaySlot(id)` (~106) sees only live sessions, not soft-closed ones.
  - `closeHtmlOverlay` (~118).
  - `htmlOverlayNodes` (~123) carries no page id.
- Socket entry: `agterm/Control/ControlServer.swift`.
  - `dispatch` (~576) is private; its `defer { refreshWindowCache() }` must run for page requests too.
  - The exhaustive `switch request.cmd` follows `dispatch`.
  - `decodeDetail` (:129, used at :439) formats decode errors and is private to the app target.
- Dispatcher: `ControlDispatcher.swift` owns the routing switches and the `ControlActions` protocol
  (`sessionOverlayResult` at :102). `ControlActionsDefaults.swift` holds the defaults. Tests use
  `MockControlActions.swift`.
- Targeting: `agterm/Control/ControlTargetResolver.swift`.
  - `resolveWindowStore` (~55) falls back to the frontmost window.
  - `resolveSessionTarget` (~109) scopes any request carrying `args.window` to that window.
- Session close:
  - Single-target `closeSession` tears the page down at once (`ControlServer+SessionActions.swift:272`,
    `AppStore.swift:521`).
  - Multi-target batches with undo enabled soft-close and keep pages through the grace period.
- Result read: `session.overlay.result` refuses pages (`ControlServer+SessionActions.swift:165`).
- Pick pattern for retained results: `Pick.swift` (`recentResults`, `retainedResults`); exit codes in
  `agtermctlKit/SocketClient.swift` `pickExitCode` (0 submitted, 2 cancelled).
- CLI:
  - `agtermctlKit/SessionCommands.swift` (997 lines) holds overlay-open `validate()`, which rejects
    `--block`/`--wait` with a page.
  - `agtermctlKit/OverlayPageCommands.swift` already holds `Reload` and `Navigate`.
- Hosted tests: `agtermTests/HtmlOverlayRegistryTests.swift` and `agtermTests/ControlServerSessionActionsTests.swift`.
  - `scripts/test-app.sh` forwards no arguments, so scoped runs call `xcodebuild` directly.
- `SkillInstallTests.bundledSkillDescriptionFitsTheSpecLimit` caps the SKILL.md description at 1024
  characters; it is about 1014 now.

## Development Approach
- **testing approach**: TDD - write the failing test first, confirm it fails, then implement
- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - tests are not optional - they are a required part of the checklist
  - write unit tests for new functions/methods
  - write unit tests for modified functions/methods
  - add new test cases for new code paths
  - update existing test cases if behavior changes
  - tests cover both success and error scenarios
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- run tests after each change, scoped per project rules:
  - host-free: `cd agtermCore && swift test --filter <Suite>`
  - hosted: `./scripts/setup.sh && xcodegen generate` once, then
    `xcodebuild test -project agterm.xcodeproj -scheme agtermTests -destination 'platform=macOS'
    -derivedDataPath build/DerivedData -only-testing:agtermTests/<Class>/<test>`
- the full gates (`swift test`, `make test-app`, `make lint`) run once, in Task 8, after the docs
- maintain backward compatibility:
  - program overlays keep their `--block`/`--wait`/`result` contract unchanged
  - `result.id` in the open reply stays the session id
- no production code exists only for tests: test seams are the real injected closures

## Testing Strategy
- **unit tests** (`agtermCore`, host-free):
  - protocol round-trip
  - the outcome store and the release seam
  - dispatcher arms
  - request building, page-relative defaults and exclusions
  - CLI parsing, validation, the open/poll runner and exit codes (`agtermctlKitTests`)
- **hosted tests** (`agtermTests`, isolated AppKit):
  - real input delivery with JS off and on, with a JS-off sentinel
  - proof that the form's submission was cancelled
  - form-value conversion in the injected script
  - reply handlers and main-frame refusal
  - own-page commands with a native reply counter
  - interleaving through a continuation barrier
  - Command-W and app-action paths
- no XCUITest additions: the hosted suite reaches the web view directly

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope
- keep plan in sync with actual work done

## Solution Overview
- **Adapter script.** An agterm-owned script in a dedicated content world, injected at document start into
  every file page's main frame. It works with page JS off because user scripts still run there, and the DOM
  is shared across worlds.
  - It listens for `submit` on `form[data-agterm]` and for `click` on `[data-agterm]` elements that are
    outside an annotated form and have `type="button"` (or are not buttons).
  - It calls `preventDefault()` synchronously before any await.
  - It sends `{cmd, target, args}` through a reply handler registered in its own world.
- **Page helper.** On `--js` pages only, a page-world `agterm.request(cmd, {target, args} = {})` wrapper
  over a reply handler registered in the page world. Its Promise always settles: resolved with the result,
  or rejected with the error.
- **One native path.** Both handlers:
  - check `frameInfo.isMainFrame`;
  - admit the request only while the page is live (`htmlOverlaySlot(id)`);
  - build a `ControlRequest` through `HtmlBridge`, filling in page-relative defaults once at admission;
  - run it through a dispatch closure the registry receives from `ControlServer`, which calls `dispatch`
    so the cache refresh runs.
  - The same closure is the test seam: hosted tests inject a recording or barrier-wrapped closure.
- **Replies.** Each admitted request is answered once, even when the command closes or reloads its own
  page. A destroyed document never sees that answer, which is accepted.
- **Script set.** The theme script, the adapter and the page helper are installed together as one set,
  replacing `installTheme`'s theme-only install. Release unregisters the handlers; reload keeps them.
- **Selectors.**
  - Every successful page open, `--html` or `--url`, registers the page as `pending` at model open, not
    when the web view is realized. A failed open registers nothing. Registering URL pages too keeps submit
    uniform and costs nothing: their release records `dismissed` like any other page.
  - `session.overlay.submit {value}` records `submitted` before releasing the page.
  - `HtmlOverlayReleases.release()` in agtermCore records `dismissed` for a page still pending, before it
    calls `onRelease`. The registry keeps sole ownership of `onRelease`.
  - Pending entries are bounded by open and undo-retained pages. Release moves an entry into a bounded
    terminal history, like pick's retained results.
  - `session overlay open --html --block` polls the page-id result: exit 0 with
    `{"pageID","outcome":"submitted","value"}`, exit 2 with `{"pageID","outcome":"dismissed"}`, exit 1 on
    error. `--json` keeps the raw socket reply, per the standing CLI contract.
  - The open reply gains `pageID`, and the tree's `htmlOverlays` nodes gain `id`.

## Technical Details
- **Adapter form values** (all in the injected script):
  - `type="number"` sends `valueAsNumber`. An empty value is omitted; a non-finite value is refused. It is
    never sent as 0 or null.
  - A checkbox sends `checked`, including an explicit false for an unchecked box.
  - The selected radio in a group sends its value as a string.
  - Other successful controls send strings; disabled controls are skipped.
  - A key that would receive more than one serialized value is refused with an error, for example two
    text inputs with the same name or a multi-select. A radio group is one value, not a repeat.
  - File inputs are refused.
  - `data-agterm-args` (JSON object) is the base, and named controls override matching keys.
  - `data-agterm-target` is the envelope target, never an argument.
- **`data-agterm-into`:** writes `result.text` when present, otherwise the JSON of the result, or the
  error string, as `textContent`.
- **Page-relative defaults**, captured once when the request is admitted:
  - Every session-targeted command with no `target`, no `args.targets` and no `args.window` gets the
    page's current session as its target: rename, status, type, flag, the overlay commands, and so on.
    A request that supplies `args.window` gets no page session or pane, and resolves exactly as it would
    over the socket.
  - `args.window` is filled with the page's window only when `target`, `args.targets` and `args.window`
    are all nil. An explicit `target`, `active`, `args.window` or batch keeps the resolver's existing
    behavior, including cross-window lookup by id.
  - The page's pane fills `args.pane` only for its own `session.overlay.close`, `reload`, `navigate` and
    `submit` when target, pane and window were all omitted.
  - `reload` gets `current: true` only when `current` was omitted. An explicit `current: false` is kept.
- **Refused commands** (execution limits, not permissions):
  - `zmx.present` and `session.overlay.job.run`, which take over a stream;
  - `zmx.reset`, which does work after its reply.
- **Decode errors:** move `decodeDetail`'s formatting into agtermCore so the socket and the bridge produce
  the same `invalid request: …` text.
- **Wire:**
  - `session.overlay.submit`: `target`, `args.pane`, `args.value` (string; required, and may be empty).
  - `session.overlay.result`: a new `args.page` field selects the page outcome; without it, the program
    contract is unchanged.

## What Goes Where
- **Implementation Steps** (`[ ]` checkboxes): tasks achievable within this codebase - code changes,
  tests, documentation updates
- **Post-Completion** (no checkboxes): items requiring external action - manual testing, changes in
  consuming projects, deployment configs, third-party verifications

## Implementation Steps

### Task 1: Prove the adapter mechanism and add the dispatch seam

**Files:**
- Create: `agterm/Views/HtmlOverlayBridge.swift`
- Modify: `agterm/Views/HtmlOverlayRegistry.swift`
- Modify: `agterm/Control/ControlServer.swift`
- Modify: `agterm/AppDelegate.swift` (if the closure is wired there alongside `install()`)
- Modify: `agtermTests/HtmlOverlayRegistryTests.swift`

- [x] write failing hosted tests, with JS off, for both a text-loaded page and a `--cwd` folder page:
  - a JS-off sentinel shows page script did not run: an inline `<script>` sets a marker that stays unset;
  - a real mouse down and up through normal AppKit hit-testing on `<button type="button" data-agterm>`
    reaches the injected dispatch closure exactly once;
  - Return in a focused text input submits an annotated form exactly once;
  - the form's `action` is a destination the fixture demonstrably allows: `b.html` for the `--cwd` page,
    and a distinct `about:` URL for the text-loaded page, which has no file grant. An unannotated control
    proves each one navigates, so "no navigation" means the adapter cancelled the submit, not that the
    policy blocked it;
  - a button inside an annotated form sends exactly one request
- [x] add the adapter script, its content world, and a reply handler that forwards to the dispatch
  closure. The registry receives the closure; `ControlServer` supplies the real one, which calls `dispatch`.
- [x] replace `installTheme` with one install of the full script set (theme plus adapter); test that an
  effective theme change keeps the adapter working
- [x] repeat the click and submit tests with JS on, including nested elements inside a button
- [x] run the scoped hosted tests - must pass before Task 2. ⚠️ If JS-off delivery or cancellation fails,
  stop and revise the design before continuing

### Task 2: Add session.overlay.submit and page outcomes in the model

**Files:**
- Create: `agtermCore/Sources/agtermCore/HtmlPageOutcomes.swift`
- Create: `agtermCore/Tests/agtermCoreTests/HtmlPageOutcomesTests.swift`
- Modify: `agtermCore/Sources/agtermCore/HtmlOverlay.swift` (`HtmlOverlayReleases.release`)
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher+Overlay.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlActionsDefaults.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+HtmlOverlay.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlProjection.swift`
- Modify: `agterm/Control/ControlServer.swift` (the command switch)
- Modify: `agterm/Control/ControlServer+SessionActions.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/MockControlActions.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherOverlayTests.swift`
- Modify: `agtermTests/ControlServerSessionActionsTests.swift`

- [x] write failing store tests:
  - a successful open registers `pending`, and a failed open registers nothing;
  - submit records `submitted` with its value before release, including an empty value;
  - release records `dismissed` only while still pending, and each transition happens once;
  - retention evicts old terminal entries but never a pending one;
  - an outcome is still readable after its page and session are gone;
  - a read never consumes an outcome
- [x] write failing close tests (a page closed before its web view exists is the same model release, so the
  store tests cover it; Command-W moves to the Task 6 hosted tests):
  - a single-target session close records `dismissed` at once;
  - a soft-close batch keeps the page pending through the grace period; undo keeps it pending, and
    finalization records `dismissed`;
  - moves and swaps keep the outcome pending
- [x] implement `HtmlPageOutcomes`, shaped like `Pick.swift`. Register at model open, and record dismissal
  inside `HtmlOverlayReleases.release()` before `onRelease` fires.
- [x] add `session.overlay.submit` (protocol case, routing, `ControlActions` method, default, mock,
  dispatcher arm, app action, server switch) and `args.page` on `session.overlay.result`. The
  program-overlay result contract stays unchanged.
- [x] add `pageID` to the open reply and `id` to `htmlOverlays` tree nodes
- [x] write round-trip and nil-omission tests in `ControlProtocolTests`, dispatcher tests, and a hosted
  app-action test in `ControlServerSessionActionsTests`
- [x] run `swift test --filter` for the touched suites and the scoped hosted test - must pass before Task 3

### Task 3: Build requests and page-relative defaults in agtermCore

**Files:**
- Create: `agtermCore/Sources/agtermCore/HtmlBridge.swift`
- Create: `agtermCore/Tests/agtermCoreTests/HtmlBridgeTests.swift`
- Modify: `agterm/Control/ControlServer.swift` (move the `decodeDetail` formatting into agtermCore)

- [x] write failing tests for decoding a page message into `ControlRequest`:
  - dotted command name, `target`, `args` object;
  - an unknown command or a wrong field type produces the same `invalid request: …` text as the socket
- [x] write failing tests for the defaults:
  - an untargeted rename and status from a page in a background window hit the page's own session;
  - explicit `active`, an explicit id in another window, explicit `args.window` and batch `args.targets`
    are kept as given;
  - an explicit `args.window` with no target gets no page session or pane, and resolves that window's
    selected session as the socket would;
  - the window is filled only when target, targets and window are all nil;
  - the pane is filled only for the page's own overlay commands, including `submit`;
  - `reload` gets `current: true` only when omitted
- [x] write failing tests for refusing `zmx.present`, `session.overlay.job.run` and `zmx.reset`
- [x] implement `HtmlBridge`, taking the page's current window, session and pane as input, and move the
  decode-error formatting into agtermCore, used by both the socket and the bridge
- [x] run `swift test --filter HtmlBridgeTests` and the existing socket decode tests - must pass before
  Task 4

### Task 4: Wire the native bridge, page helper and full adapter behavior

**Files:**
- Modify: `agterm/Views/HtmlOverlayBridge.swift`
- Modify: `agterm/Views/HtmlOverlayRegistry.swift`
- Modify: `agtermTests/HtmlOverlayRegistryTests.swift`

- [x] write failing hosted tests for the round trip:
  - a `tree` request returns the tree to a `--js` Promise, and to `data-agterm-into` text with JS off;
  - `session.select` switches the session;
  - a subframe request is refused;
  - a `--url` page has no adapter and no helper;
  - every Promise settles on an error
- [x] write failing hosted tests for form conversion in the injected script:
  - empty and valid number fields;
  - an unchecked checkbox sends false;
  - disabled controls are skipped;
  - `data-agterm-args` is the base and a named control overrides it;
  - a selected radio group sends one value;
  - a repeated serialized value is refused
- [x] implement the reply handlers through one request-handling helper that takes the reply closure as a
  parameter: main-frame check, live-page admission, `HtmlBridge` build, dispatch through the closure, and
  exactly one call to the reply closure
- [x] add the page-world `agterm.request` helper on `--js` pages, and finish the adapter: form rules,
  args merge, `data-agterm-into`
- [x] unregister handlers on page release and keep them on reload; test that a released page sends nothing
  further
- [x] run the scoped hosted tests - must pass before Task 5

### Task 5: CLI for submit, page results and --block selectors

**Files:**
- Modify: `agtermCore/Sources/agtermctlKit/OverlayPageCommands.swift`
- Modify: `agtermCore/Sources/agtermctlKit/SessionCommands.swift` (register `Submit` in `Overlay`, the
  stored `--page` option and request on `Result`, `Open.run` routing to the page poll, and `validate()`)
- Modify: `agtermCore/Sources/agtermctlKit/SocketClient.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/OverlayCommandsTests.swift`

- [x] write failing tests for parsing and validation:
  - `session overlay submit [--value V] [--pane] [--target]` builds the request;
  - `session overlay result --page ID` reads the page outcome;
  - `--block` is accepted with `--html` and still refused with `--url`, and `--wait` stays refused for
    pages
- [x] write failing tests for the page `--block` flow, through an injectable open/poll runner like pick's:
  - the poll uses the `pageID` from the open reply, and still finds it after a new page reopens the same
    slot;
  - an open reply missing `pageID` is an error;
  - empty and multiline submitted values are printed intact;
  - the output is JSON with exit 0 on submitted, 2 on dismissed and 1 on error;
  - `--json` prints the raw socket reply;
  - program `--block` behavior is unchanged
- [x] implement `Submit` and the page poll/exit helpers in `OverlayPageCommands.swift`, and make the
  declaration edits in `SessionCommands.swift` (registration, `--page`, `Open.run` routing, `validate()`).
  ⚠️ If `SessionCommands.swift` would pass 1000 lines, ask Eugene before moving existing code out of it.
- [x] add the page exit-code mapping next to `pickExitCode`
- [x] run `swift test --filter OverlayCommandsTests` - must pass before Task 6

### Task 6: Own-page and interleaving hosted tests

**Files:**
- Modify: `agtermTests/HtmlOverlayRegistryTests.swift`
- Modify: `agterm/Views/HtmlOverlayBridge.swift` (fixes only, if tests expose them)

- [x] write hosted tests for commands that affect their own page. Each counts calls to the actual reply
  completion. The production request-handling helper takes its reply closure as a parameter: the WebKit
  handler passes WebKit's reply handler, and the test passes a counting one. The destroyed page cannot
  observe its own reply, and a count of dispatch returns would not prove the reply went out once:
  - `session.overlay.close` fired from the page itself;
  - `session.overlay.reload` fired from the page itself;
  - a command that reloads its own page during dispatch, as `theme.set` to a different effective color does
    (the test reloads the page inside a wrapped dispatch rather than sending a real `theme.set`);
  - `session.overlay.submit` followed by the release
- [x] write a hosted Command-W test that records `dismissed` through the app-action path
- [x] write a hosted interleaving test:
  - a continuation barrier wraps the real dispatch closure and holds a page request mid-way;
  - the server's session-close action (the one a socket request reaches, called directly) closes the page's
    session, then the barrier releases;
  - the admitted request completes (its command may correctly return a gone-target error);
  - later requests from the released page fail;
  - the cached window list shows the completed changes
- [x] fix anything these expose in the bridge
- [x] run the scoped hosted tests - must pass before Task 7

### Task 7: Documentation and skill
- [x] update `.claude/rules/control-api.md`:
  - add `.overlay.submit` to the public catalog;
  - rewrite the HTML bullet that says `overlay.result` refuses pages;
  - add the bridge contract: surfaces, defaults, exclusions, reply-once, script set, outcomes
  - say that `sidebar` and `sidebar.mode` act on the frontmost window even from a page: they read no window
    argument, so the page's window cannot reach them
- [x] update `site/commands.html`:
  - `session overlay submit`;
  - `result --page`;
  - `open --html --block`;
  - the `pageID` and tree `id` read-back
- [x] update `site/docs.html`: the page bridge guide with the switcher, forms, page controls and selector
  examples
- [x] update `plugins/agterm/skills/agterm/`:
  - a `SKILL.md` section plus a description trigger that keeps the description within 1024 characters;
  - the `reference.md` entries;
  - an `examples.md` switcher and selector
- [x] run `swift test --filter SkillInstallTests`
- [x] update `ARCHITECTURE.md` with the bridge module and outcome ownership, and `site/llms.txt` if its
  capability list names HTML overlays

### Task 8: Verify acceptance criteria
- [x] verify the Overview requirements:
  - tags run commands with JS off;
  - `agterm.request` returns replies on `--js` pages;
  - selectors return values through `--block`;
  - `--url` pages get nothing
- [x] verify the edge cases above are covered by tests (defaults, exclusions, own-page commands, soft
  close, form conversion)
- [x] build: `scripts/build.sh`
- [x] run full host-free suite: `cd agtermCore && swift test`
- [x] run hosted suite: `make test-app`
- [x] run lint: `make lint` (zero findings)

### Task 9: [Final] Close out
- [x] update `README.md` only if its control-API synopsis should mention interactive pages
  (not needed: the synopsis names the control API, and the bridge is documented in the site and skill)
- [x] move this plan to `docs/plans/completed/`

## Post-Completion
*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Manual verification:**
- In an isolated Debug instance (short `/tmp` `AGTERM_STATE_DIR`, `open -n`):
  - a no-JS switcher generated from `tree`;
  - a `--js` live switcher with Refresh;
  - a rename form;
  - a branch selector driven by `--block` from a shell in that instance
- Check that a page in a background window reads its own window's tree and renames its own session.

Smells pre-check: skipped — non-Go project
