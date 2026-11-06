# Show a cmd-clicked markdown file as a rendered overlay

## Overview
- A ⌘-click on a local `.md` or `.markdown` path, bare or `file://`, opens the file rendered as HTML in an
  overlay over its session, styled with the terminal theme. Today such a path is revealed in Finder.
- It follows the image click (#844): same origin rules, same fallbacks to reveal, same off-main read.
- Local images the document references are embedded; remote images show their alt text. No file grant, no
  network, no control bridge, and the document's own JavaScript stays off.
- `agtermctl session overlay open --markdown FILE` opens the same page from the control API, with tree
  read-back.

## Context (from discovery)
- Click routing: `agtermCore/Sources/agtermCore/LinkPolicy.swift` (`disposition`, `localPath`, `route`),
  `agterm/Ghostty/LinkOpener.swift`, wiring in `agterm/agtermApp.swift`.
- Image page as the model: `agterm/Control/ControlServer+ImagePage.swift`, `agterm/Views/ImageProbe.swift`,
  `agtermCore/Sources/agtermCore/ImagePage.swift`, `HtmlSource.image` in `HtmlOverlay.swift`.
- Page hosting: `agterm/Views/HtmlOverlayRegistry.swift` (`themed(_:linked:)` gates both the theme look and
  the bridge install; `installScripts()` removes and reinstalls every user script as one set, and
  `applyTheme` reloads through it; `textLoaded`; `loadOriginal`; `imageLoad`, bumped by `close()`;
  `browserURL`/`pageURL`; the `navigate` actions), `agterm/Views/HtmlOverlayView.swift` (toolbar switch,
  `sourceText`), and in agtermCore `HtmlOverlay.identity`, `HtmlNavigationPolicy` (allows `about` before
  its source switch) and `presentationSource` (`AppStore+RemotePage.swift`).
- Every switch over `HtmlSource` in the app target: the registry members above, `HtmlOverlayView`,
  `RemoteCompanionRequest.pageArguments` in `ControlServer+RemoteCompanions.swift`. `LinkOpener.follow`
  switches over `Route`. `ControlServer+RemotePage` switches over `PresentationPageSource` and needs no
  markdown case.
- Control surface: `ControlDispatcher+Overlay.swift` (`imageContent`), `ControlDispatcher+Companions.swift`
  (`dispatchCompanionPage` refuses only `.image`), `ControlProtocol.swift` (`ControlArgs.image`;
  `ControlArgs.markdown` is already the HUD's `Bool?`; `OverlayHtmlError.oneSource`),
  `ControlProjection.swift` (`ControlHtmlOverlayNode.image`, manual CodingKeys), `AppStore+HtmlOverlay.swift`
  (projection), `SessionCommands.swift` (`overlay open --image`, its help and validation strings).
- Symlink-resolved containment: `RemotePageResources.resolve` in agtermCore.
- Vendored renderer: `cookbook/annotate-document/assets/markdown-it-14.1.0.min.js` and
  `highlight-11.11.1.min.js` with their LICENSE files; webrev's page CSS is the visual model.
- Foundation's `.full` markdown parser reports `imageURL` for inline and reference-style images (probed).
- `.md` is the existing tests' fixture for "a local file that is revealed" (`LinkPolicyTests`,
  `GhosttySurfaceViewInputTests`).
- `project.yml` adds `agterm/` as a group and excludes each resource folder, which then gets its own
  folder-reference entry. `scripts/test-app.sh` runs `xcodegen generate` but forwards no arguments.

## Development Approach
- **testing approach**: Regular (code first, then tests in the same task)
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

## Solution Overview
- New `HtmlSource.markdown(path:)`. The app reads the file and its local images off the main actor and
  builds an HTML string loaded with no base URL, like the image page, so WebKit gets no file access.
- The renderer (markdown-it with `html: false`, highlight.js) is bundled in the app and installed by
  `installScripts()` with the theme set, as a `WKUserScript` in its own content world, so it works with page
  JavaScript off and survives a theme change. The markdown text and the image map reach it as inert
  escaped data, never interpolated into a script element.
- The page takes the terminal theme through the existing `--agterm-*` variables. Theme styling and bridge
  install are separated in `HtmlOverlayRegistry`, so a markdown page gets the first and never the second;
  `applyTheme` reloads on styling eligibility.
- Images: agtermCore collects image URLs with Foundation's markdown parser and decides containment: the
  markdown file's folder and each candidate resolved with symlinks before the check, canonical paths
  deduplicated. The app reads each resolved file through the shared descriptor read and `ImageProbe`'s
  checks and stops at the total byte and pixel budgets. Both sides key references by the percent-decoded
  string. The renderer emits only app-supplied data URIs, or the escaped alt text for everything else; a
  miss between the two parsers degrades to alt text.
- Overlay only; there is no browser path. `navigate browser` is refused for a markdown page, and
  `navigate finder` returns `finderRequiresFile` as it does for an image page.
- Links in the page: `render.js` keeps `href` only on http(s) links and bare `#fragment` links and strips
  it from every other link, `about:` and relative `.md` included. http(s) goes through the existing
  confirmed browser handoff. Headings get GitHub-compatible slugs, so README tables of contents work.
- Never presented on another Mac (`presentationSource` returns nil) and never a page companion.

## Technical Details
- `LinkPolicy`: `markdownExtensions = ["md", "markdown"]`; `LinkDisposition.markdown(URL)` and
  `Route.markdown(URL, session:, sizePercent:)`, routed with the image origin rules (pane and scratch open
  on their session; remote pane bare path ignored, remote `file://` revealed; HUD, program overlay and quick
  reveal). `route` computes the size: a numbered overlay mode keeps its percent, `overlay` is nil (full
  size), `browser` is 95. A ⌘⇧-click that `wantsBrowser` accepts passes `.browser` as the mode, so it opens
  at 95%; under mouse capture `wantsBrowser` is false and the click keeps the configured mode and size.
- Wire field `ControlArgs.markdownFile: String?`, CLI `--markdown FILE` on `session overlay open`. Rules as
  `--image`: absolute path, extension checked, mutually exclusive with COMMAND/`--html`/`--url`/`--image`,
  and refused with `--companion`, `--block`, `--wait`, `--navigation`, `--js`, `--chromeless`,
  `--persistent`, `--browse`, `--cwd`. A raw `session.companion.page` with `markdownFile` is refused with
  `companionNeedsPage`. `OverlayHtmlError.oneSource`, the CLI abstract, argument help and both validation
  messages name `--markdown`.
- Read-back: `ControlHtmlOverlayNode.markdown: String?` (the path), exactly one source field set, omitted
  when nil.
- Limits (`MarkdownPage` in agtermCore): a markdown byte cap, a total embedded-image byte cap and a total
  pixel cap; per-image checks reuse `ImagePage.maxBytes`, `maxPixels` and `mimeType(sniffing:)`. Exact
  values are set in Task 1 and pinned by tests.
- Page CSP: `default-src 'none'; img-src data:; style-src 'unsafe-inline'`.
- One load counter for both text-built sources (`imageLoad` renamed `textLoad`), bumped by `close()`.
- `reload` (original and `--current`) re-reads and re-renders the file, through `textLoaded`, never
  `webView.reload`.
- The click and the synchronous control open check only the markdown descriptor (regular file, under the
  cap) to choose overlay or refusal; images are read once, by the page load.

## What Goes Where
- **Implementation Steps** (`[ ]` checkboxes): code, tests, docs in this repo.
- **Post-Completion** (no checkboxes): manual look in an isolated Debug instance.

## Implementation Steps

### Task 1: Markdown page builder and file reader

No new enum cases yet, so the app builds unchanged around the new code.

**Files:**
- Create: `agtermCore/Sources/agtermCore/MarkdownPage.swift`
- Create: `agtermCore/Tests/agtermCoreTests/MarkdownPageTests.swift`
- Modify: `agterm/Views/ImageProbe.swift`
- Modify: `agtermTests/ImageProbeTests.swift`
- Create: `agterm/Views/MarkdownProbe.swift`
- Create: `agtermTests/MarkdownProbeTests.swift`

- [x] `MarkdownPage`: limits; image-reference extraction with Foundation's parser, keyed by the
  percent-decoded string; containment of each local candidate against the markdown file's folder with
  symlinks resolved first and canonical paths deduplicated; the HTML document builder that escapes the
  markdown and the image map as inert data and carries the CSP
- [x] `ImageProbe`: the descriptor read (`fstat`, regular file, byte cap, offloaded iCloud refused) moves
  into a shared reader that takes the cap and returns a neutral failure; the image path keeps its
  behavior and messages
- [x] `MarkdownProbe`: reads the markdown through the shared reader off the main actor, then reads each
  contained image through `ImageProbe`'s checks until the total byte or pixel budget is reached; returns
  markdown text plus the reference-to-data-URI map
- [x] package tests: escaping (a literal `</script>` and `<img>` in the source stay inert); extraction
  (inline, reference-style, remote, duplicates, a filename with a space and one with non-ASCII);
  containment (`../` escape, an outward symlink, an inward symlink, canonical dedupe); limits
- [x] hosted tests: `ImageProbeTests` still pass with the shared reader; `MarkdownProbeTests` for a plain
  file, non-regular and oversized files refused, an embedded image, a bad signature not embedded, and the
  byte and pixel budgets stopping further embedding
- [x] run `swift test --filter MarkdownPageTests` and the hosted `ImageProbeTests` and
  `MarkdownProbeTests`; leak check - must pass before task 2

### Task 2: Markdown page source and rendering

Adds `HtmlSource.markdown` together with every consumer, so the app builds at the end of the task.

**Files:**
- Modify: `agtermCore/Sources/agtermCore/HtmlOverlay.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlProjection.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+HtmlOverlay.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+RemotePage.swift`
- Create: `agterm/Resources/markdown/` (`markdown-it-14.1.0.min.js`, `highlight-11.11.1.min.js`, both
  LICENSE files copied from `cookbook/annotate-document/assets/`, `render.js`, `page.css`)
- Modify: `project.yml`
- Modify: `agterm/Views/HtmlOverlayRegistry.swift`
- Modify: `agterm/Views/HtmlOverlayView.swift`
- Modify: `agterm/Control/ControlServer+RemoteCompanions.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/HtmlOverlayTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreTreeProjectionTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreRemotePageTests.swift`
- Modify: `agtermTests/HtmlOverlayRegistryTests.swift`
- ➕ Create: `agterm/Views/MarkdownAssets.swift`, `agtermTests/MarkdownAssetsTests.swift`

- [x] agtermCore: `HtmlSource.markdown(path:)` with a `markdownPath` accessor; `HtmlOverlay.identity`
  names the file; navigation policy (http(s) user-activated opens external, everything else cancelled);
  `presentationSource` returns nil; `ControlHtmlOverlayNode.markdown` with CodingKeys, decoder and
  projection
- [x] `project.yml`: `Resources/markdown` added to the `agterm` excludes and given its own folder-reference
  resource entry, like `Resources/hud`
- [x] registry: split `themed(_:linked:)` into styling and bridge eligibility (markdown gets the look and
  transparent canvas, never the bridge); `applyTheme` reloads on styling eligibility; `installScripts()`
  adds the renderer for a markdown source; `loadOriginal` reads through `MarkdownProbe` detached under the
  shared `textLoad` counter; `textLoaded` includes markdown; `browserURL`/`pageURL` handled; `navigate
  browser` refused and `navigate finder` returns `finderRequiresFile` for markdown
- [x] `render.js`: `html: false`; highlight code blocks; GitHub-compatible heading slugs (lowercase,
  punctuation stripped, spaces to `-`, `-1`/`-2` for duplicates); images swapped for app-supplied data URIs
  or escaped alt text; `href` kept only on http(s) and bare `#fragment` links. `page.css` themes with
  `--agterm-*` variables
- [x] `HtmlOverlayView` toolbar switch and `sourceText` handle markdown;
  `RemoteCompanionRequest.pageArguments` handles the case (companion creation stays refused)
- [x] package tests: `HtmlOverlayTests` for `identity` and the navigation policy per scheme and
  activation; `ControlProtocolTests` for `ControlHtmlOverlayNode.markdown` round-trip and nil omission;
  `AppStoreTreeProjectionTests` for a projection that sets only `markdown`; `AppStoreRemotePageTests` for
  `presentationSource` nil
- [x] hosted tests: renders headings and a highlighted code block; theme variables apply; a theme change
  re-renders the page; no bridge handler; an authored `<script>` shows as escaped text and its side effect
  is absent; authored remote and data-URI images show alt text; an embedded image loads; a punctuated
  heading and a duplicate heading are reachable by their slugs; `about:blank` and relative `.md` links are
  inert; an http(s) link goes to the confirmation handoff; original and `--current` reload re-render after
  an anchor click; `navigate browser` and `navigate finder` refused
- [x] ➕ `MarkdownAssets` reads the bundled renderer and stylesheet once; `OverlayHtmlError.markdownInOverlay`
  is the browser refusal
- [x] run `swift test --filter` for the changed suites and the hosted `HtmlOverlayRegistryTests`; leak
  check - must pass before task 3

### Task 3: Control API open path

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher+Overlay.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher+Companions.swift`
- Modify: `agtermCore/Sources/agtermctlKit/SessionCommands.swift`
- Modify: `agterm/Control/ControlServer+SessionActions.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherOverlayTests.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/OverlayCommandsTests.swift`
- Modify: `agtermTests/ControlServerLinkOverlayTests.swift`
- Modify: `agtermUITests/ControlHtmlOverlayUITests.swift`

- [x] `ControlArgs.markdownFile`; dispatcher validation mirroring `imageContent`; `dispatchCompanionPage`
  refuses markdown with `companionNeedsPage`; `OverlayHtmlError.oneSource` names `--markdown`
- [x] CLI `--markdown FILE` with its exclusions, abstract, argument help and validation messages; the app
  opens it synchronously after the markdown descriptor check only, and a presented session refuses it
- [x] package tests: `markdownFile` request round-trip; markdown rows in the dispatcher refusal table,
  the raw companion request included; CLI validation
- [x] hosted test: a missing, non-regular or oversized markdown file is refused over the control path and
  opens nothing
- [x] UI test: `overlay open --markdown` opens a page and `tree` reports `htmlOverlays[].markdown`
- [x] run the changed package suites, the hosted test and the one UI method; leak check - must pass before
  task 4

### Task 4: Click path

**Files:**
- Modify: `agtermCore/Sources/agtermCore/LinkPolicy.swift`
- Create: `agterm/Control/ControlServer+MarkdownPage.swift`
- Modify: `agterm/Ghostty/LinkOpener.swift`
- Modify: `agterm/agtermApp.swift`
- ➕ Modify: `agterm/Views/MarkdownProbe.swift` (`checkDetached` for the click; the unused `loadDetached` removed)
- Modify: `agtermCore/Tests/agtermCoreTests/LinkPolicyTests.swift`
- Modify: `agtermTests/GhosttySurfaceViewInputTests.swift`
- Modify: `agtermTests/ControlServerLinkOverlayTests.swift`

- [x] `LinkPolicy` classifies `.md`/`.markdown` local paths as `.markdown` and routes them with the image
  origin rules and the mode's size, ⌘⇧ included
- [x] `LinkOpener.markdown(URL, UUID, Int?, completion)` and its `.markdown` route, revealing on refusal;
  wired in `agtermApp`
- [x] `openMarkdownLink`: check `canShowLinkOverlay`, run the markdown descriptor check off-main, recheck
  HUD, zoom and slot after it, open at the routed size
- [x] existing tests whose `.md` fixtures mean "a revealed file" move to `.txt`, keeping what each tests:
  `LinkPolicyTests` `localFileReveals`, `otherBarePathsReveal`, `defaultLocalHostsRevealLocalFiles`,
  `fileLinksRevealAndOtherSchemesStayIgnoredInEveryMode` and the symlink-kept case;
  `GhosttySurfaceViewInputTests.testBrowserModeAHudAndNonWebLinksNeverReachTheOverlay`
- [x] package tests: markdown routing for every origin, both extensions, every link-open mode, and ⌘⇧
  with and without mouse capture
- [x] hosted tests: `recordLinks` gets a markdown recorder; a pane markdown path calls the markdown
  closure with the routed size, and a refusal reveals the file; in `ControlServerLinkOverlayTests`, opens
  over the owning session, and HUD up, zoomed terminal, busy slot and unreadable file refuse
- [x] run `swift test --filter LinkPolicyTests` and the two hosted classes; leak check - must pass before
  task 5

### Task 5: Verify acceptance criteria
- [x] verify every Overview point and the Technical Details rules are implemented
- [x] verify edge cases: remote pane, HUD and quick origins, symlink escape, budgets, `</script>` in source
- [x] build: `scripts/build.sh`
- [x] run `cd agtermCore && swift test`
- [x] run `make test-app`, then the leak check
- [x] run `make lint` with zero findings

### Task 6: [Final] Update documentation
- [x] `site/docs.html`: the local-path ⌘-click paragraph covers markdown files
- [x] `site/commands.html`: `--markdown FILE` and the `markdown` read-back field
- [x] `plugins/agterm/skills/agterm/SKILL.md` and `reference.md`: `--markdown` with a discovery trigger
- [x] `.claude/rules/control-api.md`: the markdown page bullet beside the image page one, and the
  theme/bridge split in the scripts-as-one-set bullet
- [x] `ARCHITECTURE.md` if the theme/bridge split warrants a line (it does not: control-api.md owns the split)
- [x] move this plan to `docs/plans/completed/`

## Post-Completion
*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Manual verification**:
- in an isolated Debug instance, ⌘-click a README with screenshots, a plan with tables and code, and a file
  with a remote image, in a light and a dark theme, at each link-open mode

Smells pre-check: skipped — non-Go project
