# Show image, markdown and text pages on the presenting Mac

## Overview
- An image, markdown or text page opened on a session another Mac presents shows on that Mac, the way an HTML file
  or URL page has since #793. Today all three are refused with `OverlayHtmlError.presenter` ("a viewer presents
  this session: an html overlay would open where nobody sees it"), so an agent on the origin cannot show its
  screenshot to the user, who sits at the presenting Mac (discussion #887).
- Covers `session overlay open --image|--markdown|--text` and the origin's own ⌘-click routes for those files
  in a session the presenter follows. A ⌘-click on a path inside an attached pane stays ignored: that path names
  a file on the other Mac and comes from terminal output (#674).
- The presenting Mac builds the same page locally (`ImagePage`, `MarkdownPage`, `TextPage`) from bytes it fetches
  over the existing page channel, sized for its own screen, themed by its own theme, with no control bridge. Its
  `tree` reports the page as `image`, `markdown` or `text`.
- An older presenter, the agterm-linux fork until it merges this, keeps today's refusal: the new page kinds go
  only to a presenter whose hello lists the new capability.

## Context (from discovery)
- Placement and hand-over on the origin: `agtermCore/Sources/agtermCore/AppStore+RemotePage.swift`
  (`openRemotePage`, `presentationSource` returning nil for `.image/.markdown/.text`, `expireRemotePageClaims`,
  `navigateRemotePage`), `AppStore+HtmlOverlay.swift` (`openHtmlOverlay` refuses via `pageBelongsRemote`).
- Wire types: `PresentationFrames.swift` (`PresentationPageSource` with `.file`/`.url`, synthesized `Codable`; an
  unknown case fails the whole stream with "bad frame" in `RemotePresentationClient.receive`),
  `PresentationHub.swift` (`supportedKinds`, `pageKinds`, `overlayPointsKind` as the precedent for a capability
  that names no frame body; one list serves both hello directions).
- Viewer: `AppStore+ReplicaPage.swift` (`presentReplicaPage`, `replicaSource`), `HtmlSource.replica(path:)` in
  `HtmlOverlay.swift`, `agterm/Control/ControlServer+RemotePage.swift` (`showReplicaPage` starts the channel
  for `.file`), `agterm/Control/RemotePageChannel.swift` (`fetch(path:)` returns MIME plus chunks),
  `agterm/Views/HtmlOverlayRegistry.swift` (`loadOriginal`, `bridged`, `styled`), `HtmlOverlayView.swift`.
- Serving on the origin: `agterm/Control/ControlServer+PageServe.swift` (`PageServeStream.transfer` reads any
  file `RemotePageResources.resolve` admits, raw, with no size cap; `answer` runs bridge requests),
  `agtermCore/Sources/agtermCore/RemotePageResources.swift` (`.file` only).
- Local page builders: `agterm/Control/ControlServer+ImagePage.swift` (origin-side sizing from
  `ImagePage.points`), `agterm/Views/ImageProbe.swift`, `MarkdownProbe.swift`, `TextProbe.swift` (all read through
  `BoundedFile`), `agtermCore/Sources/agtermCore/MarkdownPage.swift` (`imageReferences`, whose `localPath` runs
  a lexical check and then resolves symlinks on the local disk), `TextPage.swift`.
- Tests: `agtermCore/Tests/agtermCoreTests/AppStoreRemotePageTests.swift` (pins the refusal for these kinds),
  `RemotePageResourcesTests.swift`, `agtermTests/ControlServerRemotePresentationTests.swift` (both Mac roles in one
  process, real `agtermctl` helpers), `ControlServerPageServeTests.swift`, `ImageProbeTests`, `MarkdownProbeTests`,
  `TextProbeTests`.
- agterm-linux (`melonamin/agterm-linux`) is a full fork of this repo: its app target switches over
  `PresentationPageSource` (`ControlServer+RemotePage.swift`) and `HtmlSource`. It breaks only when it merges
  upstream, and acts as an older presenter until then.

## Development Approach
- **testing approach**: Regular (code first, then tests in the same task)
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
- run tests after each change, scoped to what changed (`swift test --filter`, `-only-testing:`); the full gates run
  once, in the verification task
- maintain backward compatibility: an older presenter keeps the refusal, and an older origin never sends the new
  kinds

## Testing Strategy
- **unit tests** (`cd agtermCore && swift test`): wire round-trip, capability gating, placement, serving rules,
  lexical picture references, replica mapping, tree projection
- **hosted tests** (`make test-app`, targeted with `-only-testing:agtermTests/<Class>/<test>` while iterating):
  byte-based probes, page serving with caps, and end-to-end hand-over of each page kind in
  `ControlServerRemotePresentationTests`
- no UI test is added: the hand-over has no new chrome, and the hosted end-to-end tests cover both roles

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope
- keep plan in sync with actual work done

## Solution Overview
- **Three typed page kinds on the wire.** `PresentationPageSource` gains `.image(path:width:height:)`,
  `.markdown(path:)` and `.text(path:line:)`. They travel only to a presenter whose hello lists
  `PresentationHub.pageContentKind` (`"page.content"`), a capability that names no frame body, like
  `overlay.points`. One kind covers all three because they ship together; a presenter without it gets today's
  refusal, never a frame it cannot decode.
- **The origin keeps opening, probing and refusing as it does locally.** The control path still probes the file
  synchronously, so a missing, oversized or non-image file is refused before anything is reserved. For an image
  the origin sends the oriented pixel size it probed. It does not send points, which depend on the presenter's
  screen.
- **The origin serves exactly the files a kind may read.** `RemotePageResources.resolve` gains one rule per kind:
  an image or text page reads only its own file; a markdown page reads its own file and pictures inside its
  folder, symlinks resolved on the origin (the second half of `MarkdownPage.localPath`). `transfer` opens content
  files through `BoundedFile` (regular file, not an iCloud placeholder, under the kind's byte cap) before
  streaming, so a viewer never pulls an unbounded file. `answer` refuses every bridge request for a content page.
- **The viewer builds the page from fetched bytes.** `HtmlSource.replica` gains a payload naming what the origin
  page is (`ReplicaContent`: html, image, markdown, text with line). The registry fetches over the page's channel
  and runs the byte-level half of each probe: image signature and pixel limit, UTF-8 and NUL for text, the
  markdown picture budget while embedding. Then it loads the same HTML a local page gets. A content replica is
  never bridged; markdown and text replicas wear the theme, an image replica does not, as locally.
- **Sizing on the viewer.** A session-wide image page with no caller size is sized on the viewer from the pixel
  size in the request, its own window's backing scale and its own detail bounds, the same `ImagePage.points`
  rule the origin uses locally. Any explicit size or pane placement passes through as today.
- **Rejected alternatives.** Serving the image as an ordinary file page (no wire change) gives a screenshot the
  control bridge and a directory grant, reports `file` on the viewer, and sizes for the origin's screen. Reusing
  `HtmlSource.image(path:)` on the viewer with `replicaOf` set, instead of a `.replica` payload, would let any
  local path consumer read the viewer's own file of the same name; `.replica` keeps an origin path from ever
  reaching a local file read.

## Technical Details
- `PresentationPageSource` (public, synthesized `Codable`):
  `case file(path: String, grantRoot: String?)`, `case url(String)`, plus
  `case image(path: String, width: Int, height: Int)` (oriented pixels), `case markdown(path: String)`,
  `case text(path: String, line: Int?)`.
- `AppStore.presentationSource(_:imagePixels:)` maps `.image(path)` only together with its probed size
  (`imagePixels` nil leaves an image unmapped), and `.markdown`/`.text` always. `openRemotePage` takes the size
  through `ControlSessionOverlayOpenOptions` and adds one guard after the page-kind check: a content source needs
  `hub.presenterSupports(pageContentKind)`, else `.unsupported`. The page companion caller
  (`ControlServer+CompanionPage.swift`) passes nil and refuses markdown and text explicitly, so page companions
  of a remote parent keep today's behavior.
- `pageBelongsRemote(_ session: Session, pane:)` stays internal for its two in-module callers
  (`openHtmlOverlay`, `AppStore+ClickedPage`), and a public wrapper
  `AppStore.pageBelongsRemote(_ sessionID: UUID, pane: OverlayPane?)` lets `openImageOverlay` skip origin-side
  sizing for a slot the presenter will hold. Dropping the points inside
  `openRemotePage` instead was rejected: by then a caller's explicit size and the origin's auto-size look the same.
- `HtmlSource.replica(path: String, content: ReplicaContent)` with
  `public enum ReplicaContent: Equatable, Sendable { case html, image(width: Int, height: Int), markdown, text(line: Int?) }`.
  `replicaSource` maps each `PresentationPageSource` case to it; `case .replica:` patterns without bindings
  keep compiling.
- `MarkdownPage.lexicalPath(_:folder:)`: the lexical half of `localPath`, which then calls it. The viewer lists
  references with it against the origin folder, and the origin's resolve applies the symlink-resolved check.
- Viewer probes take bytes: `ImageProbe.probe(data:)` (the existing private probe, given a label in place of a
  path), `TextProbe.check(_ data: Data)`, and `MarkdownProbe`'s embedding driven by a reader closure, so the
  local path reads with `BoundedFile` and the replica path fetches over the channel under the same total byte
  and pixel budget. A fetch over its kind's cap is cancelled on the viewer as soon as the chunks exceed it.
- Claim expiry and the navigate refusals treat every source that uses the channel alike: `.file` and the three
  content kinds. Finder and Browser stay refused for a page shown on the presenting Mac.
- Tree on the viewer: `ControlHtmlOverlayNode` reports `image`, `markdown` or `text` (with `line`) for a
  content replica, beside `replica: true`. The origin's `remoteOverlays` node is unchanged.
- The registry's per-page decisions key on what a page shows, not on its source case: `installScripts` (which
  renderer to add), `textLoaded` (whether a reload rebuilds from text), the transparent-canvas check and
  `styled`/`bridged` each treat a markdown, text or image replica as its local kind. Without this a replica
  markdown or text page gets no renderer and stays blank.

## What Goes Where
- **Implementation Steps** (`[ ]` checkboxes): code, tests and docs in this repo
- **Post-Completion** (no checkboxes): two-Mac manual check, the discussion reply, the fork

## Implementation Steps

### Task 1: Wire format, origin placement and serving rules, with the app target kept building

**Files:**
- Modify: `agtermCore/Sources/agtermCore/PresentationFrames.swift`
- Modify: `agtermCore/Sources/agtermCore/PresentationHub.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+RemotePage.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+HtmlOverlay.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+ReplicaPage.swift`
- Modify: `agtermCore/Sources/agtermCore/HtmlOverlay.swift`
- Modify: `agtermCore/Sources/agtermCore/RemotePageResources.swift`
- Modify: `agtermCore/Sources/agtermCore/MarkdownPage.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlProjection.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcherOptions.swift` (image size on
  `ControlSessionOverlayOpenOptions`)
- Modify: `agtermCore/Sources/agtermCore/AppStore+ClickedPage.swift` (only if the internal caller needs a touch)
- Modify: app-target switches the new cases make non-exhaustive: `agterm/Control/ControlServer+RemotePage.swift`,
  `agterm/Control/ControlServer+RemoteCompanions.swift`, `agterm/Views/HtmlOverlayRegistry.swift`,
  `agterm/Views/HtmlOverlayView.swift`, `agterm/Control/ControlServer+CompanionPage.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreRemotePageTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreReplicaPageTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/HtmlOverlayTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/RemotePageResourcesTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/MarkdownPageTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/PresentationFramesTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreTreeProjectionTests.swift`

- [x] add the three `PresentationPageSource` cases and `PresentationHub.pageContentKind`, listed in
      `supportedKinds`
- [x] map `.image/.markdown/.text` in `presentationSource(_:imagePixels:)`, carry the image size through the open
      options, gate the content kinds on the capability in `openRemotePage`, and treat them like `.file` in claim
      expiry and the navigate refusals
- [x] add the public `pageBelongsRemote(_ sessionID:pane:)` wrapper beside the internal `Session` form
- [x] add `ReplicaContent` to `HtmlSource.replica`, map it in `replicaSource`, and update every `.replica`
      pattern that binds its payload (identity, projection, submit refusal) and every test building
      `.replica(path:)` (`AppStoreReplicaPageTests`, `HtmlOverlayTests`, `AppStoreRemotePageTests`)
- [x] keep the app target compiling: the switches over `PresentationPageSource` and `HtmlSource` handle the new
      cases by refusing them as today (`showReplicaPage` refuses a content page, the companion path refuses
      content kinds); Task 3 replaces the refusal in `showReplicaPage` with the real path
- [x] add the per-kind rules to `RemotePageResources.resolve` and split `MarkdownPage.lexicalPath` out of
      `localPath`
- [x] project content replicas on the viewer's tree as `image`/`markdown`/`text` with `replica: true`
- [x] tests: frame round-trip for each new case; `AppStoreRemotePageTests` flips the pinned refusal to a hand-over
      for each kind when the presenter lists the capability, and keeps the refusal when it does not
- [x] tests: resolve admits an image's or text's own file and refuses a sibling; admits a markdown page's own file
      and a picture in its folder; refuses `..`, an outward symlink and the folder itself; `lexicalPath` cases
- [x] tests: the viewer's reference listing uses `lexicalPath` only, pinned by a fixture where the viewer-side path
      is a symlink pointing outside the folder: the reference is still listed (the origin decides), so the
      filesystem-resolving `localPath` cannot be reused by mistake
- [x] tests: `replicaSource` per case, viewer tree projection, claim expiry of an unclaimed content page
- [x] run the touched suites with `cd agtermCore && swift test --filter` and build the app target - must pass before
      task 2

### Task 2: Origin app side - sizing hand-off, bounded serving and bridge refusal

**Files:**
- Modify: `agterm/Control/ControlServer+ImagePage.swift`
- Modify: `agterm/Control/ControlServer+SessionActions.swift`
- Modify: `agterm/Control/ControlServer+PageServe.swift`
- Modify: `agterm/Views/ImageProbe.swift` (shared reader caps, if the cap constants move)
- Modify: `agtermTests/ControlServerPageServeTests.swift`

- [x] `openImageOverlay`: when `pageBelongsRemote` says the presenter holds the slot, skip origin-side sizing and
      pass the probed oriented pixel size in the open options
- [x] claim-expiry scheduling in `openHtmlOverlay` covers the content kinds
- [x] `PageServeStream.transfer`: open a content page's file through `BoundedFile` with that kind's cap and refuse
      a non-regular, offloaded or oversized file with a failure frame; `.file` pages stream as today. Caps: an image
      page's own file `ImagePage.maxBytes`; a text page's own file `TextPage.maxBytes`; a markdown page's own file
      `MarkdownPage.maxBytes`, and each of its pictures `MarkdownPage.maxImageBytes`
- [x] a markdown page's picture is served only when its bytes carry a picture signature
      (`ImagePage.mimeType(sniffing:)`), checked on the origin before the first chunk; any other sibling, whatever
      its name, is refused, so no non-picture file inside the folder crosses the channel. The extension plays no
      part, matching the local probe
- [x] `PageServeStream.answer`: refuse every bridge request for a content page
- [x] tests: transfer serves an image, a markdown file and its picture, and a text file; refuses an oversized file,
      a FIFO and a file outside the kind's rule; a bridge request on a content page is refused
- [x] tests: for a markdown page, a non-picture sibling is refused (one named `notes.txt` and one named `fake.png`),
      a valid picture with no image suffix is served, and a picture over 4 MiB but under 32 MiB is served
- [x] run the targeted hosted tests (`-only-testing:agtermTests/ControlServerPageServeTests`) - must pass before
      task 3

### Task 3: Viewer app side - fetch, probe, build and size content replicas

**Files:**
- Modify: `agterm/Control/ControlServer+RemotePage.swift`
- Modify: `agterm/Views/HtmlOverlayRegistry.swift`
- Modify: `agterm/Views/HtmlOverlayView.swift`
- Modify: `agterm/Views/ImageProbe.swift`
- Modify: `agterm/Views/MarkdownProbe.swift`
- Modify: `agterm/Views/TextProbe.swift`
- Modify: `agtermTests/ImageProbeTests.swift`, `MarkdownProbeTests.swift`, `TextProbeTests.swift`
- Modify: `agtermTests/HtmlOverlayRegistryTests.swift`
- Modify: `agtermTests/ControlServerRemotePresentationTests.swift`

- [x] `showReplicaPage` starts the page channel for the content kinds as it does for `.file`, replacing Task 1's
      refusal
- [x] byte-level probe entry points (`ImageProbe.probe(data:)`, `TextProbe.check`) and reader-driven markdown
      embedding, with the local paths unchanged in behavior
- [x] `loadOriginal` builds content replicas from channel fetches with the shared `textLoad` counter, cancelling a
      fetch past its kind's cap; `bridged` false for all three, `styled` true for markdown and text only; toolbar
      and strip treat them as remote (no Finder, no Browser)
- [x] `installScripts`, `textLoaded` and the transparent-canvas check recognize content replicas as their local
      kind, so a replica markdown or text page gets its renderer and a reload or theme change rebuilds it
- [x] tests (`HtmlOverlayRegistryTests`): a replica markdown and text page install their renderer, an image replica
      installs none and keeps the unstyled canvas, and reload and a theme change rebuild a replica page from a
      fresh fetch
- [x] size a session-wide image replica with no caller size on the viewer from the request's pixel size, its
      window's backing scale and its detail bounds
- [x] tests: byte probes accept a valid PNG/JPEG and refuse a bad signature and an over-limit pixel header; text
      check refuses invalid UTF-8 and NUL; markdown embedding through a fake reader honors the byte and pixel
      budgets and skips a picture the reader refuses
- [x] tests (`ControlServerRemotePresentationTests`): an image, a markdown page with a picture, and a text page with
      a line are handed to the presenter and render there; the viewer tree reports each kind with `replica: true`;
      an auto-sized image takes the viewer's bounds; a presenter without `page.content` keeps the refusal; a file
      grown past the cap after open fails the page on the viewer; an origin ⌘-click on an image in a followed
      session opens on the presenter
- [x] tests (`ControlServerRemotePresentationTests`): after a markdown page's first render, edit the origin file and
      its picture, then reload original and current on the viewer; assert fresh transfers on the same page channel
      (no second claim of the single-use token) and changed rendered content
- [x] run the targeted hosted tests - must pass before task 4

### Task 4: Agent skill, user docs and engineering rules

**Files:**
- Modify: `plugins/agterm/skills/agterm/SKILL.md`
- Modify: `plugins/agterm/skills/agterm/reference.md`
- Modify: `site/docs.html`
- Modify: `site/commands.html`
- Modify: `.claude/rules/control-api.md`
- Modify: `ARCHITECTURE.md`

- [x] SKILL.md image section: `--image` shows on the Mac presenting an attached session too; the ⌘-click hint
      applies only to a local pane; the `show-image.sh` fallback stays for an older CLI, app or presenter
- [x] `site/docs.html` and `site/commands.html`: the presented-session rule covers image, markdown and text pages,
      with the older-presenter refusal; remove the "never on another Mac" statements
- [x] `control-api.md`: replace the "no remote form" sentences in the image, markdown and text bullets with the
      typed hand-over, the capability kind, the per-kind serving rules and the viewer-side sizing; name
      `pageContentKind` beside `overlay.points`
- [x] `ARCHITECTURE.md`: the remote page section lists the content kinds and where each check runs

### Task 5: Verify acceptance criteria
- [x] verify every Overview item: three kinds via CLI, origin ⌘-click routes, attached-pane ⌘-click still ignored,
      older-presenter refusal, no bridge, viewer-side sizing and tree read-back
- [x] run `cd agtermCore && swift test`
- [x] run `make test-app`
- [x] run `make lint`
- [x] after the hosted run: `lsappinfo list | grep -A4 agterm.debug` and stop any leaked test process

### Task 6: [Final] Update documentation
- [x] update README.md only if its remote-session synopsis names the page kinds that travel (it names none: no change)
- [x] update CLAUDE.md if a new pattern was discovered (none)
- [x] move this plan to `docs/plans/completed/`

## Post-Completion
*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Manual verification:**
- two Macs: attach a session with `zmx attach`, run `overlay open --image`, `--markdown` (with a relative picture)
  and `--text --line` on the origin, and confirm each renders on the presenting Mac at a sensible size; ⌘-click an
  image path in an origin pane the presenter follows
- a presenter on a release without this change keeps the refusal

**External:**
- reply on https://github.com/umputun/agterm/discussions/887 once the change merges
- agterm-linux gains the feature, and the switch updates, when it merges upstream

Smells pre-check: skipped - non-Go project
