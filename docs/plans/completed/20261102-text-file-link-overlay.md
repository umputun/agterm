# Show a cmd-clicked text file as a read-only overlay, and reveal any file with ⌘⌥

## Overview
- A ⌘-click on a local source, config, text, log, diff or JSON path, bare or `file://`, opens the file as
  read-only text in an overlay over its session, highlighted when its language is known and styled with the
  terminal theme. Today such a path is revealed in Finder.
- A `path:line[:col]` link, as compilers and test runners print it, opens the file scrolled to that line.
  Today a relative one is ignored and an absolute one asks Finder for a file that does not exist.
- ⌘⌥-click on any local path, every type included, reveals it in Finder, so the reveal stays one chord away
  for files that now preview.
- `agtermctl session overlay open --text FILE [--line N]` opens the same page from the control API, with
  tree read-back.
- The file and the path both come from untrusted terminal output. Nothing in this feature may lead to code
  execution: the page runs no authored code, loads nothing, navigates nowhere, and no path in it opens or
  launches a file. Security is the first acceptance criterion (see Security Contract).
- Deferred: CSV/TSV tables and JSON pretty-print (both shown as raw text), Quick Look.

## Context (from discovery)
- The markdown page (#866, `docs/plans/completed/20261102-markdown-link-overlay.md`) is the model:
  `agtermCore/Sources/agtermCore/MarkdownPage.swift`, `agterm/Views/MarkdownProbe.swift` (`check`, `load`,
  `checkDetached` over `BoundedFile`), `agterm/Views/MarkdownAssets.swift`, `agterm/Resources/markdown/`
  (`render.js`, `page.css`, bundled `highlight-11.11.1.min.js` with 37 languages),
  `agterm/Control/ControlServer+MarkdownPage.swift` (`openMarkdownLink`, `markdownFileRefusal`).
- Page hosting: `agterm/Views/HtmlOverlayRegistry.swift` (`markdownWorld` content world, `installScripts()`,
  styling vs bridge eligibility at ~402-410, text-loaded sources at ~481-486, `loadOriginal` at ~523,
  `allowsContentJavaScript = overlay.javascript` at 267), `HtmlNavigationPolicy.decide` in
  `agtermCore/Sources/agtermCore/HtmlOverlay.swift`.
- Click routing: `LinkPolicy.disposition`/`localPath`/`route` (`agtermCore/Sources/agtermCore/LinkPolicy.swift`),
  `agterm/Ghostty/LinkOpener.swift` (`reveal` is `activateFileViewerSelecting`), wiring in `agterm/agtermApp.swift`.
- Raw link delivery: `GHOSTTY_ACTION_OPEN_URL` in `agterm/Ghostty/GhosttyCallbacks.swift:132-141` copies the
  bytes unchanged and snapshots `releaseWantsBrowser` synchronously; `GhosttySurfaceView+Input.swift`
  (`linkMods` strips Shift for the ⌘⇧ browser click, `mouseDown`/`mouseUp`, `refreshLinkHover`).
- HUD link clicks: `agterm/Ghostty/HudLinkClick.swift:38,71` accept exactly `.command`; `passivePointer` and
  `passiveClick` forward raw modifiers.
- Pane cwd: `GHOSTTY_ACTION_PWD` → `GhosttySurfaceView.applyPwd` → `session.currentCwd` or `splitCwd`.
- Ghostty at pin `683d8db` (`src/config/url.zig`, `src/Surface.zig`):
  - `path_chars` include `:`, so `/x/a.go:42:7` and `./a.go:42:7` arrive with the suffix; a slashless
    `a.go:42:7` is not a link at all (the bare relative branch needs a `dir/` prefix).
  - `resolvePathForOpening` makes a relative path absolute only when that exact path exists, so a relative
    path with a suffix arrives raw; agterm then fails `isBarePath` and `URL(string:)` reads the first
    segment as a scheme, and the click is ignored.
  - Links match only when the mouse mods equal exactly `ctrlOrSuper`.
  - On Darwin `isRectangleSelectState` is `mods.alt`, recomputed from the live mods on every drag
    (`Surface.zig:4698`) and autoscroll tick (`:1221`); prompt click-to-move does not read Alt.
- highlight.js timing in node/V8 on Swift source: 256 KB 76 ms, 1 MB 183 ms, 4.8 MB 775 ms with 12 MB of
  span markup. WebKit insertion is unmeasured.

## Development Approach
- **testing approach**: Regular (code first, then tests in the same task); the two click defects above
  (relative suffix ignored, absolute suffix revealed) get a failing test first
- complete each task fully before moving to the next; every task ends with the app and package building
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
- scoped test runs during tasks; the full gates run once, in the verification task
- maintain backward compatibility

## Testing Strategy
- **package tests**: `cd agtermCore && swift test --filter <Suite>` during tasks.
- **hosted tests**: `xcodegen generate`, then `xcodebuild test -project agterm.xcodeproj -scheme agtermTests
  -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:agtermTests/<Class>`.
  Regenerate before every scoped run, since tasks add app and test files.
- **UI test**: one new method, run with scheme `agterm` and
  `-only-testing:agtermUITests/ControlHtmlOverlayUITests/<method>` after `xcodegen generate`. Approving
  this plan is the go-ahead for that one run.
- After every hosted or UI run: `lsappinfo list | grep -A4 agterm.debug`, stopping leaked test processes
  and reporting anything else.

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope
- keep plan in sync with actual work done

## Security Contract
Each guarantee is pinned by a test in the task that builds it. A change that weakens one is a plan change,
not an implementation detail.
- **No authored markup or script.** The file text reaches the document only as HTML-escaped inert data
  (`MarkdownPage.escaped`), never inside a `<script>` element. The renderer writes plain text with
  `textContent`; highlighted output is highlight.js's own escaped `value`, the only string assigned through
  `innerHTML`. The language name comes from the app's map, never from the file, and is passed as data.
- **Page JavaScript off, renderer isolated.** `allowsContentJavaScript` false; the renderer runs as an
  app-owned user script in its own content world, as the markdown renderer does.
- **Loads nothing.** No base URL and no file grant; CSP `default-src 'none'; style-src 'unsafe-inline'`
  (no `img-src`: a text page has no pictures).
- **Navigates nowhere.** The page has no links: URLs in a log stay text. `HtmlNavigationPolicy` decides a
  text source before its shared new-window and `about` exits: it allows only a main-frame `about:blank`, the
  generated document's own load, and cancels every other action, a new window and any other `about:` URL
  included, so nothing is handed to the browser.
- **No bridge, no browser hand-off.** Styling eligibility only; the control bridge is never installed.
  `navigate browser` is refused, so the file is never handed to Safari as `file://`, where an `.html` or
  `.svg` would render and run. `navigate finder` returns `finderRequiresFile`, as for markdown.
- **No path opens or launches a file.** Every fallback and the ⌘⌥ chord reveal through
  `activateFileViewerSelecting`, which selects and never opens; nothing in this feature calls
  `NSWorkspace.open` on a local path. Highlighting a `.sh` shows its text and runs nothing.
- **Bounded, regular-file reads only.** `BoundedFile` judges the opened descriptor: a non-regular file
  (FIFO, device, socket), an offloaded iCloud placeholder or one over the cap is refused before a byte is
  read; a symlink is measured at its target. Content that is not valid UTF-8 or holds a NUL is refused
  before the click accepts the page, so the click reveals instead. The offloaded-placeholder check
  (`SF_DATALESS` in `BoundedFile.withDescriptor`) is shared code no test can reach, since no local volume
  produces a dataless file; it is named here rather than covered.
- **Filesystem access only after the guards.** Remote-pane, local-host and automount checks run on the final
  absolute path, a relative one joined to the pane cwd included, before any `stat`, read or reveal; the
  suffix and relative-path existence checks run off the main actor after them. The ⌘⌥ reveal comes after
  this guarded classification and candidate resolution, and only skips the image, markdown and text viewer
  choice, so a refused path is neither read nor revealed under either intent.
- **Never remote, never a companion.** `presentationSource` returns nil, so a presented session refuses
  it; a raw `session.companion.page` with `textFile` is refused with `companionNeedsPage`.
- **Explicit paths stay literal.** `--text FILE` is never suffix-parsed or cwd-resolved; the location comes
  only from `--line`.

## Solution Overview
- New `HtmlSource.text(path:line:)`. The app reads the file off the main actor and builds an HTML string
  loaded with no base URL; a bundled `text.js` renders it in the markdown content world with page
  JavaScript off. It reuses the markdown page's theme variables, escaping and load counter.
- Source-preserving rendering: escaped `<pre><code>`, never a synthesized markdown fence (the source can
  contain the fence). `white-space: pre`, no wrapping, so every line has one height: the line-number gutter
  and the target-line band are computed from the line count and line height, with no DOM splitting of
  highlighted spans.
- Eligibility by extension and exact basename (agtermCore `TextPage`); an unlisted extension is revealed as
  today. `.html`, `.htm` and `.svg` stay revealed: showing them as text would be safe, but a page author may
  expect them rendered, and that is a separate decision.
- Line targeting: agtermCore parses `:line[:col]` purely; the app resolves candidates off-main, literal
  first, and routes the existing path with the line. Column is parsed and dropped: the page scrolls to the
  line only.
- Gestures: one click intent (`normal`, `browser`, `reveal`) replaces `releaseWantsBrowser`, normalized on
  the exact chord and never on a drag event.

## Technical Details
- `TextPage` (agtermCore):
  - `maxBytes = 4 << 20`; `maxHighlightBytes = 256 << 10`, set by the Task 2 WebKit measurement; above it
    the page renders plain text.
  - `language(forFile:) -> String?` maps a lowercased extension, then an exact basename, to a bundled
    highlight.js language; nil means plain text. Extensions: swift, go, py, rb, rs, js, mjs, cjs, ts, c, h,
    cc, cpp, cxx, hpp, m, mm, java, kt, kts, cs, php, pl, pm, lua, r, sql, css, scss, less, graphql, sh,
    bash, zsh, json, yaml, yml, toml and ini and cfg and conf (ini), xml, plist, diff, patch, mk (makefile),
    vb. Plain-text extensions: txt, text, log, out, csv, tsv, env, lock. Basenames: Makefile, GNUmakefile
    (makefile); Dockerfile, LICENSE, README, CHANGELOG, Procfile (plain); .bashrc, .zshrc, .profile,
    .bash_profile, .zprofile (bash); .gitconfig, .editorconfig (ini); .gitignore (plain). The exact list is
    pinned by tests.
  - `isEligible(file:)` is `language != nil` or a plain-text extension or a listed basename.
  - `html(text:language:line:style:)` builds the document: text and language escaped as data attributes
    and element text, the CSP above.
  - `validate(_ data: Data) -> String?` returns the UTF-8 string, nil on invalid UTF-8 or a NUL byte.
- `TextProbe` (app): `check(path:)` reads through `BoundedFile` with `TextPage.maxBytes` AND validates
  content, so a binary file fails the click; `load(path:)` returns the validated text; `checkDetached` for
  the click.
- `LinkPolicy`:
  - `LinkDisposition.text(URL, line: Int?)`, `Route.text(TextLink)`, routed with the markdown origin rules
    and sizes.
  - `locations(for:origin:cwd:) -> [LinkLocation]` lists the candidates; the internal `lineSuffix` strips a
    trailing `:digits[:digits]` and drops the column, pure.
  - A relative raw link (`./`, `../`, or `dir/` first segment, no scheme parse) is joined to the click's cwd
    lexically; the cwd is captured on the main actor with the click. A first segment containing `:` is never
    a relative directory, so `http://localhost:3000` keeps its web routing.
  - Candidate order: literal path, then the stripped one; the first that exists wins, checked off-main
    after the automount guard. A literal path containing colons that exists is never stripped. When neither
    exists, the literal link keeps today's disposition: an absolute path is revealed, a relative one ignored.
- Wire: `ControlArgs.textFile: String?`, `ControlArgs.line: Int?` (≥ 1, only with `textFile`); CLI
  `--text FILE`, `--line N` on `session overlay open`, with the `--markdown` exclusions. Read-back
  `ControlHtmlOverlayNode.text: ControlTextOverlayNode?` with `file`, `language` (the mapped language,
  omitted when unmapped; a file over `maxHighlightBytes` still reports it and renders plain, since the
  host-free projection never sees the size) and `line` (requested, not the viewport).
- Click intent: `LinkPolicy.ClickIntent { normal, browser, reveal }` in agtermCore with
  `LinkPolicy.clickIntent(modifiers:mode:origin:mouseCaptured:)`:
  - ⌘⇧ → `browser` (unchanged rules); ⌘⌥ → `reveal`; under mouse capture ⌘⌥⇧ → `reveal` unconditionally,
    and libghostty's own Shift bypass decides whether `OPEN_URL` fires: the app has no shift-capture state
    (`ghostty.h` exposes only `ghostty_surface_mouse_captured`). Shift is kept in captured events so
    libghostty can decide the bypass. Accepted limitation of the reserved chord: when the program captures
    Shift, no link matches and the program receives ⌘⇧ instead of ⌘⌥⇧, since the ALT strip is not undone
    (`mouseModsWithCapture` at `Surface.zig:4395`, the report at `:3955`). Restoring it would need new C API.
  - `LinkPolicy.wantsBrowser` is public and `agtermCore` is consumed by the agterm-linux fork: check the fork
    for callers (`fork:true` code search or a clone) before removing it, and keep it as a wrapper over
    `clickIntent` if one exists.
  - `reveal` applies to local paths only and wins over image, markdown, text and the link-open mode; it
    acts after the guarded classification and candidate resolution, never before them; a web URL follows
    its web policy.
  - `linkMods` clears ALT/ALT_RIGHT (and Shift as today) on the exact chord alone, as the ⌘⇧ strip does:
    the app has no over-link signal (no `GHOSTTY_ACTION_MOUSE_OVER_LINK` handler, and libghostty reports a
    link only once the mods are exactly ⌘). It clears them for hover, the press and an undragged release,
    never on a drag event and never on the release after one; raw keyboard events are unchanged. The
    dragged flag replaces nothing, so `GhosttySurfaceView.swift` (995 lines) gains one stored property:
    the intent lock replaces `releaseWantsBrowser` one for one. `mouseUp` stores the intent in one `OSAllocatedUnfairLock`, snapshotted in
    `GHOSTTY_ACTION_OPEN_URL` as today. A drag never reveals: ghostty's `left_click_dragged` release guard
    already stops the link open.
  - `HudLinkClick` accepts ⌘ and ⌘⌥ (and the capture form) and its passive paths forward the normalized
    mods with the intent, so a ⌘⌥-click on a HUD link reveals instead of falling through to the pane.

## What Goes Where
- **Implementation Steps** (`[ ]` checkboxes): code, tests, docs in this repo.
- **Post-Completion** (no checkboxes): manual look in an isolated Debug instance.

## Implementation Steps

### Task 1: Text page builder and file reader

**Files:**
- Create: `agtermCore/Sources/agtermCore/TextPage.swift`
- Create: `agtermCore/Tests/agtermCoreTests/TextPageTests.swift`
- Create: `agterm/Views/TextProbe.swift`
- Create: `agtermTests/TextProbeTests.swift`

- [x] `TextPage`: limits, `language(forFile:)`, `isEligible(file:)`, `validate`, and the HTML builder with
  the CSP, reusing `MarkdownPage.escaped`
- [x] `TextProbe`: bounded descriptor read plus UTF-8/NUL validation in `check` and `load`, detached check
  for the click
- [x] package tests: escaping (`</pre>`, `</script>`, `<img onerror>`, a quote fused with a combining mark
  stay inert); the CSP string; every mapped extension and basename, case-insensitivity, unlisted
  extensions ineligible, `.html`/`.svg` ineligible; `validate` on invalid UTF-8, a NUL, a BOM, empty input
- [x] hosted tests: a plain file loads; FIFO, directory, oversized and binary files refused by `check`
- [x] run `swift test --filter TextPageTests` and the hosted `TextProbeTests`; leak check - must pass
  before task 2

### Task 2: Text page source and rendering

Adds `HtmlSource.text` with every consumer, so the app builds at the end of the task.

**Files:**
- Modify: `agtermCore/Sources/agtermCore/HtmlOverlay.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift` (`OverlayHtmlError.textInOverlay`)
- Modify: `agtermCore/Sources/agtermCore/ControlProjection.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+HtmlOverlay.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+RemotePage.swift`
- Create: `agterm/Resources/markdown/text.js`, `agterm/Resources/markdown/text.css`
- Modify: `agterm/Views/MarkdownAssets.swift`
- Modify: `agterm/Views/HtmlOverlayRegistry.swift`
- Modify: `agterm/Views/HtmlOverlayView.swift`
- Modify: `agterm/Control/ControlServer+RemoteCompanions.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/HtmlOverlayTests.swift`, `AppStoreTreeProjectionTests.swift`,
  `AppStoreRemotePageTests.swift` (read-back round-trips go here: `ControlProtocolTests.swift` is at its
  2000-line limit)
- Create: `agtermTests/MarkdownPageRenderingTests.swift`, `agtermTests/TextPageRenderingTests.swift`
- Modify: `agtermTests/HtmlOverlayRegistryTests.swift` (1981 lines), `agtermTests/MarkdownAssetsTests.swift`

- [x] split first, approved: the markdown page tests move from `HtmlOverlayRegistryTests` to
  `MarkdownPageRenderingTests` unchanged, and the moved tests pass before any text code lands; text page
  tests go in `TextPageRenderingTests`

- [x] agtermCore: `HtmlSource.text(path:line:)` with an accessor; `identity` names the file; the text arm
  of `HtmlNavigationPolicy.decide` runs before the shared new-window and `about` exits and allows only a
  main-frame `about:blank`; `presentationSource` nil; `ControlTextOverlayNode` read-back
- [x] `MarkdownAssets` also serves the text renderer and stylesheet (highlight.js plus `text.js`, without
  markdown-it); `text.js` renders plain text via `textContent`, highlighted text via highlight.js's
  escaped value under `maxHighlightBytes`, a line-number gutter, and scrolls to and marks the target line
- [x] registry: styling eligibility without the bridge; `installScripts()` adds the text renderer in the
  isolated world; `loadOriginal` reads through `TextProbe` under `textLoad`; reload re-reads; `navigate
  browser` refused with `textInOverlay`, `navigate finder` returns `finderRequiresFile`; view toolbar and
  `sourceText` handled
- [x] package tests: identity; the navigation policy for a text source per scheme, activation and target
  (main-frame `about:blank` allowed; `about:srcdoc`, a subframe `about:blank`, http(s) user-activated, a new
  window and `file:` cancelled); read-back round-trip and nil omission; `presentationSource` nil
- [x] hosted security tests, each with a hostile fixture rendered both plain and highlighted (the
  highlighted path is the only `innerHTML` sink): `<script>`, `onerror`, `<img src>`, `<link>`, `<iframe>`,
  `<meta http-equiv=refresh>`, `<a href>` and `javascript:` text stay text, with no element of those kinds in
  the rendered DOM and their side effect absent; no message handler; page JavaScript off; the installed text
  renderer is in the `agterm-markdown` world; the page loads with no base URL and no file grant; no
  navigation and no browser hand-off occur; `navigate browser` and `navigate finder` refused
- [x] hosted behavior tests: Swift and Go highlight; plain text for an unmapped plain extension and for a
  file over `maxHighlightBytes`; the requested line is scrolled to and marked; a source starting with a
  blank line keeps it in the rendered DOM, so the gutter and target line stay aligned; a theme change and
  reload re-render
- [x] measure WebKit render time for a 1 MB and a 4 MB file in a hosted test run and record the numbers
  here; lower `maxHighlightBytes` if 1 MB highlighted takes over ~300 ms
  - measured, file write plus render to populated DOM: highlighted 1 MB 1.44 s, 512 KB 0.67 s, 256 KB
    0.38 s, 128 KB 0.25 s; plain 4 MB 0.71 s, 1 MB 0.24 s, 256 KB 0.15 s. Highlighting adds about 0.23 s at
    256 KB and 1.2 s at 1 MB, so the cap is 256 KB
- [x] run the changed package suites and the hosted `HtmlOverlayRegistryTests`,
  `MarkdownPageRenderingTests`, `TextPageRenderingTests` and `MarkdownAssetsTests`; leak check - must pass
  before task 3

### Task 3: Control API open path

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher+Overlay.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher+Companions.swift`
- Modify: `agtermCore/Sources/agtermctlKit/SessionCommands.swift`
- Create: `agterm/Control/ControlServer+TextPage.swift`
- Modify: `agterm/Control/ControlServer+SessionActions.swift` (995 lines: one call line, the refusal itself
  in `ControlServer+TextPage.swift`, as `markdownFileRefusal` does)
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherOverlayTests.swift` (request round-trips too),
  `agtermCore/Tests/agtermctlKitTests/OverlayCommandsTests.swift`
- Modify: `agtermTests/ControlServerLinkOverlayTests.swift`
- Modify: `agtermUITests/ControlHtmlOverlayUITests.swift`

- [x] `ControlArgs.textFile` and `line`; dispatcher validation mirroring markdown (absolute path, eligible
  file, one source, `line` only with `textFile` and ≥ 1); companion refusal; `oneSource` names `--text`
- [x] CLI `--text FILE` (resolved to absolute, never suffix-parsed) and `--line N`, with the markdown
  exclusions, help and validation messages; the app checks through `TextProbe.check` before opening, and a
  presented session refuses it
- [x] package tests: request round-trip; refusal table rows (two sources, `--line` without `--text`,
  `--line 0`, ineligible extension, companion, and raw-wire `textFile` with `javascript`, `navigation`,
  `cwd`, `browse`, `persistent`, `chromeless` or `wait`); CLI validation, `--block` included (CLI-only); a
  path containing `:12` stays literal
- [x] hosted tests: missing, non-regular, oversized and binary files refused over the control path, opening
  nothing; a `--text` open on a presented session is refused (pinned host-free in
  `AppStoreRemotePageTests`, where the store's presenter rule lives)
- [x] UI test: `overlay open --text FILE --line N` opens a page and `tree` reports `htmlOverlays[].text`
- [x] run the changed package suites, the hosted test and the one UI method; leak check - must pass before
  task 4

### Task 4: Click routing for text files and line suffixes

**Files:**
- Modify: `agtermCore/Sources/agtermCore/LinkPolicy.swift`
- Modify: `agterm/Ghostty/LinkOpener.swift`
- Modify: `agterm/Ghostty/GhosttySurfaceView+Input.swift` (cwd captured with the click)
- Modify: `agterm/Control/ControlServer+TextPage.swift`
- Modify: `agterm/agtermApp.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/LinkPolicyTests.swift`
- Modify: `agtermTests/GhosttySurfaceViewInputTests.swift`, `agtermTests/ControlServerLinkOverlayTests.swift`

- [x] failing tests first: an absolute `/x/a.go:42:7` routes to text at line 42 (today revealed with
  extension `go:42:7`); a relative `./a.go:42` with a cwd routes to text (today ignored)
- [x] `LinkPolicy`: eligible local paths classify as `.text`, routed with the markdown origin rules and
  sizes; `location(of:)`; relative-with-suffix joined to the captured cwd before any scheme parse; the
  remote-pane, local-host and automount guards run first
- [x] `LinkOpener`: candidate resolution off-main (literal first, then stripped), then the `.text`, image or
  markdown route with the line; a refusal reveals the resolved file; `openTextLink` rechecks HUD, zoom and
  slot after the read
- [x] existing `.txt` fixtures that stand for "a revealed file" (moved there by #866) move to an ineligible
  extension, keeping what each tests
- [x] package tests: every origin and link-open mode for `.text`; suffix forms (`:42`, `:42:7`, `:0`, a
  trailing colon, non-digits); a literal file named `a:42` wins over `a`; neither candidate existing keeps
  today's disposition (absolute revealed, relative ignored); `http://localhost:3000` and `https://host:8443`
  keep web routing; relative without cwd ignored;
  refused inputs make no filesystem call (injected existence closure records none): `/net` and `/Network`
  paths, a remote pane, a non-local `file://` host, `//host/share`, a `../` escape normalized into `/net`, and
  an OSC-7 cwd of `/net/x`, empty, relative or holding a control character
- [x] hosted tests: a pane text path calls the text closure with the routed size and line, a binary file
  reveals; HUD up, zoomed terminal, busy slot refuse; candidate resolution runs off the main actor; a cwd or
  path holding `;`, `$()`, a backtick or a quote is treated as filesystem data and nothing calls the open
  seam
- [x] run `swift test --filter LinkPolicyTests` and the two hosted classes; leak check - must pass before
  task 5

### Task 5: ⌘⌥ reveal chord

**Files:**
- Modify: `agtermCore/Sources/agtermCore/LinkPolicy.swift`
- Modify: `agterm/Ghostty/GhosttySurfaceView+Input.swift`
- Modify: `agterm/Ghostty/GhosttySurfaceView.swift`
- Modify: `agterm/Ghostty/GhosttyCallbacks.swift`
- Modify: `agterm/Ghostty/HudLinkClick.swift`
- Modify: `agterm/Ghostty/LinkOpener.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/LinkPolicyTests.swift`
- Modify: `agtermTests/GhosttySurfaceViewInputTests.swift`

- [x] fork check for public `LinkPolicy.wantsBrowser` callers in agterm-linux; remove it, or keep it as a
  wrapper over `clickIntent` when a caller exists
- [x] `LinkPolicy.ClickIntent` and `clickIntent(...)` added, `wantsBrowser` kept as a wrapper for the
  fork's caller; the release lock holds the intent and `OPEN_URL` snapshots it; `follow` takes the intent, and `reveal` on a local path reveals after the guarded
  classification and candidate resolution, skipping only the viewer choice, a web URL keeping its policy
- [x] `linkMods` normalizes ALT on the exact chord alone for hover, the press and an undragged release,
  never on a drag event or the release after one; `HudLinkClick` accepts the reveal chord and forwards
  normalized mods
- [x] package tests: the intent table over modifiers × modes × origins × capture (⌘, ⌘⇧, ⌘⌥, ⌘⌥⇧, ⌥ alone,
  ⌘⌃); `reveal` beats image, markdown and text in every mode; the refused inputs from Task 4 make no
  filesystem, reveal or open call under `reveal` either
- [x] hosted tests: a ⌘⌥ release on a link reveals a `.go`, a `.png`, a `.md`, a `.command`, an `.app`, an
  `.html` and an `.svg`, recording zero calls to the open seam; a ⌘⌥ drag starting on a link (the press may
  be normalized) and one crossing a link keep ALT in every drag update and the release, still select a
  rectangle and reveal nothing; plain ⌥ events are unchanged; a ⌘⌥ HUD link click reveals and does not
  reach the pane under it; under mouse capture, ⌘⌥⇧ forwards mods with Shift kept and ALT cleared, the
  recorded limitation
- [x] run `swift test --filter LinkPolicyTests` and the hosted input tests; leak check - must pass before
  task 6

### Task 6: Verify acceptance criteria
- [x] verify every Overview point and every Security Contract guarantee has its named test
- [x] verify edge cases: remote pane, HUD, program overlay and quick origins; automount path; symlink to a
  FIFO; a 4 MB file; a literal colon path; `</pre>` in the source
- [x] build: `scripts/build.sh`
- [x] run `cd agtermCore && swift test`
- [x] run `make test-app`, then the leak check
- [x] run `make lint` with zero findings

### Task 7: [Final] Update documentation
- [x] `site/docs.html`: the local-path ⌘-click paragraph covers text files, `path:line`, and ⌘⌥ reveal
- [x] `site/commands.html`: `--text FILE`, `--line N` and the `text` read-back field
- [x] `plugins/agterm/skills/agterm/SKILL.md` and `reference.md`: `--text` with a discovery trigger
- [x] `.claude/rules/control-api.md`: the text page bullet beside the markdown one, its security
  guarantees, the click-intent seam, the link-routing bullet's suffix and cwd rules, and the ⌘⌥ reveal
  chord's recorded exemption from a control twin (a gesture modifier over a click, with `overlay open
  --text` and Finder reveal already reachable)
- [x] move this plan to `docs/plans/completed/`

## Post-Completion
*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Manual verification**:
- in an isolated Debug instance, ⌘-click `go build` and `swift build` error locations (relative and
  absolute), a log, a `.json`, a `Makefile` and a binary file, in a light and a dark theme, at each
  link-open mode; ⌘⌥-click each, and ⌘⌥-drag a rectangle across a link

Smells pre-check: skipped — non-Go project
