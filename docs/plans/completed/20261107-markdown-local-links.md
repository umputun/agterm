# Markdown overlay follows local .md links

## Overview
- A rendered markdown overlay today strips every link that is not http(s) or `#fragment`, so a README cannot
  open the docs it links to. This plan makes a click on a relative link to a neighbouring `.md`/`.markdown`
  file render that file in the same overlay, with Back/Forward returning to the previous file at its scroll
  position.
- Works the same in a session attached from another Mac (CLAUDE.md: a remote session is a normal view).
- Back/Forward appear exactly where links work: a cmd-clicked local `.md` opens with navigation like a
  clicked URL; CLI `--markdown` accepts `--navigation`; without it local links stay text. A page whose link
  root is refused (`/` or home) opens without navigation, so its strip has no Back/Forward and read-back
  `navigation` is false.
- Integration: link pages move from `loadHTMLString(baseURL: nil)` to the existing `HtmlPageSchemeHandler`
  (`agterm-page://<page-id>/<path>`), so WebKit owns history and scroll restoration and the existing
  toolbar, `session overlay navigate back|forward`, `canGoBack`/`canGoForward` read-back and reload
  `--current` work unchanged.

## Context (from discovery)
- Renderer: `agterm/Resources/markdown/render.js` (strips local hrefs), `agtermCore/.../MarkdownPage.swift`
  (document builder, `localPath`/`lexicalPath`/`remoteImageReferences`), `agterm/Views/MarkdownProbe.swift`
  (bounded read, picture embedding from the folder of the path it is given).
- Web view: `agterm/Views/HtmlOverlayRegistry.swift` (exactly 1000 lines, the lint limit; `loadOriginal`,
  `textLoaded`, `pageURL` already maps `agterm-page` to a file path at :707, `urlChanged`/`reportPage`,
  `reportFailure` shared by every page kind at :770, scheme handler installed only for `.replica` at :269),
  `agterm/Views/HtmlPageSchemeHandler.swift`, `agterm/Views/HtmlOverlayView.swift` (strip gated on
  `overlay.navigation`), `agterm/Views/TextPageBridge.swift` (precedent for a page source in its own file).
- Policy and model: `agtermCore/.../HtmlOverlay.swift` (`HtmlNavigationPolicy.decide` sees only
  `HtmlOverlay`; `identity` at :302; `grantError`); `HtmlSource`, `ReplicaContent` and
  `PresentationPageSource` are public enums matched by agterm-linux, and an older presenter fails its stream
  on an enum shape it cannot decode (PresentationFrames.swift:269-272), so none gains associated values.
- Remote: `agtermCore/.../PresentationFrames.swift` (`PresentationPage` :300), `AppStore+RemotePage.swift`
  (`openRemotePage`), `AppStore+ReplicaPage.swift` (`replicaSource`, navigation already copied),
  `RemotePageResources.swift` (`content`), `agterm/Control/ControlServer+PageServe.swift` (`claimPageServe`
  keeps only the source).
- Control: `SessionCommands.swift:688-698` and `ControlDispatcher+Overlay.swift` `markdownContent` reject
  `--navigation`; `ControlServer+MarkdownPage.swift` opens clicked markdown without navigation after a
  detached file check; `ControlServer+LinkOverlay.swift:13` opens clicked URLs with `navigation: true`.
- Tests: `agtermCore/Tests/agtermCoreTests/{MarkdownPageTests,HtmlOverlayTests,RemotePageResourcesTests,ControlDispatcherOverlayTests}.swift`
  plus the presentation-frame codec tests; hosted `agtermTests/MarkdownPageRenderingTests.swift` (225 lines,
  home for new hosted tests; `HtmlOverlayRegistryTests.swift` is at 1848 of 2000),
  `ControlServerPageServeTests.swift`; XCUITest `agtermUITests/ControlHtmlOverlayUITests.swift:44`.
- Supersedes `docs/backlog/markdown-overlay-follows-local-md-links.md`.

## Development Approach
- **testing approach**: TDD - each task starts with failing tests, then the code
- complete each task fully before moving to the next
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- run only the touched tests while working: `cd agtermCore && swift test --filter <Suite>`,
  `xcodebuild test -project agterm.xcodeproj -scheme agtermTests -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:agtermTests/<Class>/<test>`,
  and the one XCUITest method by `-only-testing:agtermUITests/ControlHtmlOverlayUITests/<test>`;
  the full gates run once in the acceptance task

## Testing Strategy
- **unit tests** (`agtermCore`, host-free): containment, canonical suffix, grant computation and refusal,
  policy decisions, identity, flag validation, remote resource rules, presentation-frame decoding across
  versions
- **hosted tests** (`agtermTests`, mostly `MarkdownPageRenderingTests`): render.js link filter,
  scheme-served pages, native history and scroll restoration, failed link keeping the page, theme refresh
  and reload, presenter replica navigation
- **e2e**: extend the existing markdown socket test in `ControlHtmlOverlayUITests` with navigation read-back

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- keep plan in sync with actual work done

## Solution Overview
- One path for local and remote: a link page first loads `agterm-page://<page-id>/<canonical path>`, and a
  followed link keeps the URL WebKit resolved, a symlinked document included; the handler's
  source builds `MarkdownPage.html` for the requested path off the main actor (local: `MarkdownProbe`;
  presenter: bytes fetched from the origin plus remote pictures). That source, local and replica, lives in
  its own type and file (Eugene approved moving the registry's existing replica markdown branch there);
  the registry keeps only hook lines.
- The document has a real hierarchical URL, so WebKit resolves relative hrefs itself; render.js only decides
  which hrefs survive.
- The link grant (canonical original path plus canonical root) is computed once at open, off the main actor,
  and travels as an optional field on `HtmlOverlay` and on `PresentationPage`; it is nil when the page has
  no navigation, and a refused root turns navigation off at open.
- Security: untrusted input is the markdown text and its hrefs (e.g. a cloned repo's README). The new
  capability is reading more `.md` files. Bounds:
  - a served document must be a regular file whose canonical path lies strictly inside the grant's root and
    itself ends in `.md`/`.markdown`, so a `guide.md -> .env` alias is refused;
  - one path namespace: the first document loads at its canonical path and the root is canonical, so links from
    `/tmp/docs/a.md` or a symlinked project folder resolve inside the root; the presenter never resolves an
    origin path, it uses the canonical values the origin sends;
  - the check runs in the serving source on whichever Mac reads the file (the origin is the authority for a
    remote page), not only in the navigation policy;
  - the origin decides by what the request names: a path spelled `.md`/`.markdown` whose canonical path is
    also markdown is a document (text); any other spelling is a picture and must pass the signature check,
    the original file included, so `picture.png -> large.md` sends no text and authored image references
    cannot pull up to 256 x 4 MiB of markdown; the presenter also never requests a markdown-spelled
    picture reference;
  - nothing sends loaded content anywhere automatically: markdown pages keep content JavaScript off, no
    bridge (`bridged` false), CSP `default-src 'none'; img-src data:`; authored web links keep the confirmed
    hand-off;
  - `BoundedFile` keeps refusing FIFOs, devices, dataless files and files over 4 MiB.
- Accepted residual: a local writer swapping a symlink between check and open can show another readable
  file to the user.

## Decisions carried from the draft
| Draft decision (backlog item) | Status | Reason |
| --- | --- | --- |
| Click on relative `.md`/`.markdown` renders it; Back returns at scroll position | kept | |
| Needs an explicit CLAUDE.md exception to "not a browser" | changed | Eugene chose to build it; the CLAUDE.md line is reworded to scope it |
| Root frozen at the first document's canonical folder; link resolves against current document; lexical plus symlink checks | kept | plus canonical-suffix check and `/`/home refusal on the canonical root |
| render.js gets the current folder from the app (page loads with `baseURL: nil`) | changed | the scheme URL gives the document a real base; WebKit resolves relative links |
| markdown-it `validateLink` rejects `file:` | dropped | no `file:` URLs are used |
| `other.md#section` keeps its fragment | kept | |
| App-side history of (path, scrollY) in agtermCore | dropped | WebKit's own history through the scheme handler; Task 2 proves scroll restoration before anything depends on it |
| New click drops forward branch; missing target leaves history usable | kept | native behavior; a failed link load keeps the shown page |
| Bare reload = original file; toolbar and `--current` = shown file; theme refresh neither resets nor adds history | kept | |
| `--markdown` rejects `--navigation` | changed | accepts it; links follow only with navigation; clicked markdown opens with it |
| Read-back and `identity` follow the shown file | kept | `page` and `identity` show the committed current file, locally and on a replica; `markdown` keeps the original path |
| Pages on another Mac excluded | changed | remote parity, per Eugene |

## Technical Details
- agtermCore `MarkdownPage`:
  - `linkGrant(for path: String, home: String = NSHomeDirectory()) -> MarkdownLinkGrant?` - canonical
    original path and canonical folder; nil when that folder is `/` or `home` (compared canonically);
  - `linkedDocument(_ requested: String, grant: MarkdownLinkGrant) -> String?` - the normalized request
    when it lies lexically and canonically strictly inside the root and the canonical path ends in a
    markdown extension (`LinkPolicy.markdownExtensions`); the file is read at that path, so a linked
    alias takes its pictures from the folder its links resolve against;
  - `html(markdown:images:style:links: Bool = false)` writes `data-links="local"` when true;
  - `remoteImageReferences` skips markdown-spelled references.
- `MarkdownLinkGrant: Codable, Equatable, Sendable` (agtermCore, public: `PresentationPage` carries it) with
  `path` and `root`. Optional `markdownLinks` field on `HtmlOverlay` (defaulted init parameter) and on
  `PresentationPage`. JSON decoding ignores an unknown key, so an old presenter shows links as text; an old
  origin sends none, which a new presenter reads as nil.
- Open path: the clicked path computes the grant inside its existing detached `MarkdownProbe.checkDetached`
  step; the CLI path computes it beside `markdownFileRefusal` (`ControlServer+MarkdownPage.swift:6`), which
  already opens the file on the calling thread, so the synchronous `ControlActions` seam is unchanged.
  A nil grant with navigation requested opens the page with `navigation: false`.
- `HtmlNavigationPolicy.decide`, `.markdown` and `.replica(_, .markdown)`: with a grant, allow a main-frame
  URL with scheme `agterm-page`, host equal to the page id, a markdown-suffixed path lexically inside
  `grant.root`; everything else as today. No `userActivated` requirement: initial load, reload and
  Back/Forward arrive as non-link navigations, and the page runs no scripts that could start one.
- render.js, when `data-links="local"`: keep an href with no scheme, not starting with `/` or `//`, whose
  path part (before `?`/`#`) ends in `.md`/`.markdown`; all other non-web, non-fragment hrefs are stripped.
- Pictures on a link page come from the folder of the path it is read at: the canonical path for the first
  file (a symlinked README embeds pictures beside its target), the normalized request for a linked one; a
  page without a grant keeps today's behavior. Every request, the first file's included, passes
  `linkedDocument` when it is read, so a file retargeted after the grant is judged again.
- Registry hooks: a page with a grant installs `HtmlPageSchemeHandler` backed by the markdown page source;
  `textLoaded` is false for it; reload `--current` and theme refresh go through `webView.reload()`;
  `identity`/`current.page` update only on commit for these pages (`urlChanged` would otherwise name a
  pending or missing target).
- Failure: only on a link page, a failed provisional load after the first commit keeps the shown document,
  restores `.loaded` with no error and calls `reportPage()` (the 102 branch pattern); a failed initial load
  still fails; every other page kind keeps today's `reportFailure`.
- Origin: `openRemotePage` copies the overlay's grant into `PresentationPage`; `claimPageServe` keeps it with
  the source; `RemotePageResources.content(.markdown)` takes the grant: a markdown-spelled request that
  passes `linkedDocument`, the original included, is read at the path it returns and served as text under
  `MarkdownPage.maxBytes`; every other request is a picture under the signature rule. With a nil grant only
  the original file is served as text, as today.
- Mixed versions: the grant goes only to a presenter listing `PresentationHub.pageLinksKind` (`page.links`).
  Any other presenter is handed `HtmlOverlay.withoutLinks()`, in the request and in the record the claim
  serves from, so it gets the pre-link rules and no Back/Forward: an older presenter fetches the original
  spelling and `.md` picture references, which the grant's rules would refuse or answer with text.
- Presenter: `replicaSource` carries the received grant onto the replica `HtmlOverlay`; the replica identity
  follows `current` like `.replica(_, .html)`.

## What Goes Where
- **Implementation Steps**: code, tests and docs in this repo
- **Post-Completion**: manual check across two Macs

## Implementation Steps

### Task 1: Path rules, grant and link filter

**Files:**
- Modify: `agtermCore/Sources/agtermCore/MarkdownPage.swift`
- Modify: `agterm/Resources/markdown/render.js`
- Modify: `agtermCore/Tests/agtermCoreTests/MarkdownPageTests.swift`
- Modify: `agtermTests/MarkdownPageRenderingTests.swift`

- [x] write failing tests for `linkGrant`: canonical path and folder; nil for `/`, home, and a symlinked
      alias of home; a symlinked first file yields its target's folder
- [x] write failing tests for `linkedDocument`: nested file allowed; `..` escape, absolute outside root,
      root itself, non-markdown canonical suffix, and an in-root `guide.md -> .env` symlink all refused; a
      symlink to an in-root `.md` allowed (a percent-encoded `..` arrives decoded from the URL, so Task 3's
      policy tests cover it)
- [x] write failing tests: `remoteImageReferences` skips markdown-spelled references; `html` without
      `links:` writes no flag
- [x] implement `MarkdownLinkGrant`, `linkGrant`, `linkedDocument`, the `links:` flag and the reference filter
- [x] write failing hosted tests for the render.js filter: relative `.md`, `.markdown`, `x.md#h` kept with
      the flag; `/abs.md`, `//host/x.md`, `x.txt`, `file:`, `javascript:` stripped; nothing local kept
      without the flag
- [x] implement the render.js filter
- [x] run the touched tests - must pass before Task 2

### Task 2: Prove native history and scroll restoration on a scheme-served markdown page

**Files:**
- Modify: `agtermTests/MarkdownPageRenderingTests.swift`

- [x] write a hosted test serving two long documents built by `MarkdownPage.html(... links: true)` (`a.md`
      and `sub/b.md` with a heading) through a test-local `WKURLSchemeHandler`, with production settings:
      content JavaScript off, the CSP, the stylesheet, and render.js as the document-end isolated-world script
- [x] assert: clicking `sub/b.md#heading` lands at b's generated heading; Back restores `a.md` at its prior
      `scrollY`; Forward restores b's position; `webView.reload()` keeps the history list, position and
      scroll; reinstalling the theme script and reloading (the theme-refresh path) keeps the same
- [x] if restoration fails, stop and bring the result to Eugene and codex before Task 3 (fallback is the
      draft's app-side history)
- [x] run the test - must pass before Task 3

### Task 3: Local link pages

**Files:**
- Modify: `agtermCore/Sources/agtermCore/HtmlOverlay.swift`
- Create: `agterm/Views/MarkdownPageSource.swift` (markdown page source, local and replica, with the
  registry's existing replica markdown branch moved in)
- Modify: `agterm/Views/HtmlOverlayRegistry.swift` (hook lines only; stays within 1000 lines)
- Modify: `agterm/Control/ControlServer+MarkdownPage.swift`, `agterm/Control/ControlServer+SessionActions.swift`
  (grant computed off the main actor at open)
- Modify: `agtermCore/Tests/agtermCoreTests/HtmlOverlayTests.swift`, `agtermTests/MarkdownPageRenderingTests.swift`

- [x] write failing policy tests: own-host markdown URL inside the grant allowed; no grant, other host,
      non-markdown path, escaping path (plain and percent-encoded `..`), subframe and new window refused;
      web links unchanged
- [x] write failing tests: `identity` names the committed markdown file; `markdown` read-back keeps the
      original; a refused root opens with `navigation: false`; clicked markdown opens with
      `navigation: true` and a grant (the forwarded click's grant reaches the presenter in Task 4)
- [x] implement the `HtmlOverlay` grant field, policy and `identity` changes, and the clicked-page grant and
      navigation default (so the Debug showing below is reachable by a cmd-click)
- [x] move the replica markdown branch into `MarkdownPageSource` with no behavior change, then add the
      local link-page source and the registry hooks; file reads, embedding and HTML building stay off the
      main actor
- [x] show Eugene the rendered result in a Debug instance (README with links, a click, Back/Forward) before
      writing the hosted tests below
- [x] write hosted tests on production code: a click renders `sub/b.md`, Back/Forward with
      `canGoBack`/`canGoForward` read-back, `page` follows the committed file, scroll restored, bare reload
      returns to the original, reload `--current` and theme refresh keep history, a missing target keeps the
      page with `loadState == .loaded` and no error, a failed initial load fails, a URL page's failed load
      still shows the error panel, a page without a grant keeps links as text, a file opened through `/tmp`
      or a symlinked folder follows its relative links
- [x] convert Task 2's test-local handler into these production-path tests
- [x] run the touched tests - must pass before Task 4

### Task 4: Remote pages follow links too

**Files:**
- Modify: `agtermCore/Sources/agtermCore/PresentationFrames.swift`, `AppStore+RemotePage.swift`,
  `AppStore+ReplicaPage.swift`, `RemotePageResources.swift`, `HtmlOverlay.swift` (replica identity)
- Modify: `agterm/Control/ControlServer+PageServe.swift`, `agterm/Control/ControlServer.swift`,
  `agterm/Views/MarkdownPageSource.swift`
- Create: `agterm/Views/HtmlReplicaLink.swift` (`HtmlReplicaLink` and its bounded read moved out of the
  registry, Eugene approved, so the presenter source reads through the same loop)
- Modify: `agtermCore/Tests/agtermCoreTests/RemotePageResourcesTests.swift`, the presentation-frame codec
  tests, `HtmlOverlayTests.swift`
- Modify: `agtermTests/ControlServerPageServeTests.swift`, `agtermTests/MarkdownPageRenderingTests.swift`,
  `agtermTests/ControlServerForwardedClickTests.swift`

- [x] write failing codec tests: `PresentationPage` round-trips the grant; a frame without it decodes to
      nil; a frame with it decodes under the old shape (unknown key ignored)
- [x] write failing origin tests: a linked in-root `.md` served as text under 4 MiB; escaping path,
      non-markdown canonical suffix, `.md -> .env` alias refused; `picture.png -> large.md` and a
      picture-spelled alias of the original refused as non-pictures with no text sent; a page without a
      grant serves only its original file; the grant is the one frozen at presentation; a forwarded
      markdown click sends `navigation: true` and the grant on its presenter request
- [x] implement the grant on `PresentationPage`, `openRemotePage`, `claimPageServe` and the content rules
- [x] write failing presenter tests mirroring Task 3: replica markdown loads the origin's canonical path
      through the scheme handler; a click follows a link; Back/Forward with `canGoBack`/`canGoForward`
      read-back; `page` and `identity` follow the committed file; a missing target keeps the page; reload
      `--current` and theme refresh keep history; links stay text with a nil grant (navigation off, or the
      origin refused a root that is its own home); no markdown-spelled picture request
- [x] implement `replicaSource` carrying the grant, the replica identity change and the presenter source
- [x] run the touched tests - must pass before Task 5

### Task 5: Control surface: `--navigation` for markdown and clicked pages

**Files:**
- Modify: `agtermCore/Sources/agtermctlKit/SessionCommands.swift` (flag rule and messages at :688-698)
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher+Overlay.swift`, `ControlProtocol.swift`
  (`navigationWithoutPage`, `markdownOptions` texts)
- Modify: `agterm/Control/ControlServer+MarkdownPage.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherOverlayTests.swift` and the CLI parse tests
- Modify: `agtermUITests/ControlHtmlOverlayUITests.swift`

- [x] write failing tests: CLI and dispatcher accept `--markdown --navigation` and still reject the other
      flags; the CLI open computes the grant beside `markdownFileRefusal`; markdown page companions stay
      refused by kind in CLI, dispatcher and remote attachment (no new companion support)
- [x] implement the flag, the CLI grant and the error texts
- [x] extend the markdown socket test with `navigation: true`, a linked file, `overlay navigate back`, and
      read-back of `navigation`, `page` and `canGoBack`
- [x] run the touched unit tests and that one XCUITest method - must pass before Task 6

### Task 6: Verify acceptance criteria
- [x] verify every Overview item, locally and on a replica page
- [x] `make lint`, `cd agtermCore && swift test`, `make test-app` (each once)
- [x] `lsappinfo list | grep -A4 agterm.debug` after the hosted run

### Task 7: [Final] Update documentation
- [x] `site/docs.html` markdown overlay section and `site/commands.html` `--markdown`/`--navigation`
- [x] `plugins/agterm/skills/agterm/` reference for `--markdown --navigation`
- [x] `.claude/rules/control-api.md`: the markdown-page bullet (~line 772, "strips every link but http(s) and
      fragments") and the remote content-page bullet (~line 2054, "a markdown page its own file plus pictures")
- [x] `HtmlPageSchemeHandler` doc comment (:11-12), which names only pages on another Mac
- [x] CLAUDE.md "not a browser" line: scope it to what it declines and keep every shipped exception: a page
      navigating its own files (HTML grant, markdown root) is in scope, `--browse` pages navigate across
      origins, and a hidden clicked page may be replaced by another terminal click
- [x] remove `docs/backlog/markdown-overlay-follows-local-md-links.md`
- [x] move this plan to `docs/plans/completed/`

## Post-Completion
**Manual verification**:
- attach a session from a second Mac, cmd-click a README there, click through, Back/Forward, theme switch

Smells pre-check: skipped — non-Go project
