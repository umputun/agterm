# Forward ⌘-clicked file paths from an attached pane to the origin Mac

## Overview
- A ⌘-click on a file path in a session attached from another Mac does nothing today: `LinkPolicy.route`
  returns `.ignore` for a bare path in a `.remotePane` origin, because the path names a file on the origin.
- The origin can already show image, markdown, text and HTML pages on the presenting Mac (#793, #891, #917).
  This plan sends the click to the origin over the presentation stream; the origin resolves the path with its
  own pane directory and opens the page exactly as a local click there would, and the page reaches the
  clicker through the existing replica page path. No file crosses to this Mac by any new mechanism.
- It also fixes two `file://` defects in an attached pane: a link with an empty, `localhost` or this-Mac host is
  revealed in Finder from THIS Mac's disk (`LinkPolicyTests.swift:285-296` pins it), and GNU `ls --hyperlink`
  output, which carries the origin's host name, is silently ignored. Every `file://` link from an attached pane
  is forwarded, and the origin's own host rule decides it.
- A click that cannot be carried out shows a short self-hiding HUD over the session saying why, the same panel
  and timing a failed remote attach uses (`RemoteAttachHud.fail`, `AppActions.remoteAttachErrorSeconds`, 5 s),
  so it never looks broken. When that panel would replace another HUD (`openHud` replaces a live one) or could
  not be seen (a zoomed terminal, another cover, a taken slot), the click beeps (`NSSound.beep()`) instead.
  Ignores that are not about a remote file (an unsupported scheme) stay silent, as they are for local panes.
- A forwarded click replaces a hidden clicked page an earlier forwarded click opened, as a local click does.

## Context (from discovery)
- Click entry: `agterm/Ghostty/GhosttySurfaceView+Input.swift:640-656` (`openLink`, `linkClickOrigin`,
  `linkClickCwd`) → `agterm/Ghostty/LinkOpener.swift` (`follow` :36-47, `carryOut` :49) → closures wired in
  `agterm/agtermApp.swift:143-161` to `ControlServer.open{Image,Markdown,Text,Document}Link`.
- Policy: `agtermCore/Sources/agtermCore/LinkPolicy.swift` (`locations` :257, `relativePath` :306,
  `route(for:mode:origin:)` :364, the private origin switch :375-411, `localHostNames` :133).
- Origin page placement: `AppStore.openRemotePage` (`AppStore+RemotePage.swift:54`) returns `.local` unless
  every covered pane follows on the presenter (`Session.followsRemotely`, `ZmxLead.swift:176`); called from
  `ControlServer.openHtmlOverlay` (`ControlServer+SessionActions.swift:99`). `canShowLinkOverlay` (:90) refuses
  on a HUD or on a zoomed terminal in the ORIGIN window, and every `open*Link` helper calls it before and after
  its probe. The image helper rebuilds its options (`ControlServer+ImagePage.swift:42-49`).
  `releaseHiddenClickedPage` skips a page `pageBelongsRemote` hands to the presenter
  (`AppStore+ClickedPage.swift:10-11`).
- Protocol: `PresentationFrame.Body` (`PresentationFrames.swift:480-545`, codec :599/:630), capability kinds in
  `PresentationHub.supportedKinds` (:66), presenter-only inbound branch in `PresentationHub.receive` (:182) →
  `ControlServer.receivePresenterFrame` (`ControlServer+Ask.swift:151`); origin-to-presenter send
  `PresentationHub.sendToPresenter` (:144), presenter generation `presenterGeneration` (:209). A frame that
  fails to decode closes the stream on the origin (`ControlServer+Presentation.swift:47-52`). Viewer side
  `RemotePresentationClient` (`answer` :162, `apply` :209) does not retain the origin's hello kinds; its mode
  reaches the store through `setRemoteMode` (`AppStore+RemotePresentation.swift:175`).
- Pane mapping viewer→origin: `RemoteBinding.remotePane(forLocal:)` (`RemotePresentationState.swift:51`,
  internal). A viewer pane can have no origin counterpart (`AppStore+RemoteLayout.swift:35`).
- Refusal HUD precedent: `RemoteAttachHud.fail` (`agterm/AppActions+RemoteAttach.swift:139-143`) and its
  `CommandFailure.message` cleaning of remote text (:153-156).
- File sizes: `ControlServer+SessionActions.swift` 999 lines, `agtermApp.swift` 987, against a 1000-line
  `file_length` warning.

## Decisions carried from earlier plans

| Source | Decision | Status | Reason |
|---|---|---|---|
| #891 plan Overview (`completed/20261104-remote-content-pages.md:8-10`) | ⌘-click on a path in an attached pane stays ignored | changed | The origin resolves and opens it, so the path is read where it exists |
| #891 plan | Origin's own ⌘-click routes reach a presenter-followed session | kept | Forwarded clicks reuse those routes |
| #891 plan | Content pages need `page.content`; clicked HTML needs `page.document` | kept | Forwarded pages pass the same gates |
| #674 / #131 | agterm hands no terminal-printed path to LaunchServices | kept | Forwarded clicks open read-only pages only; every Finder fallback is suppressed |
| #844 (`LinkPolicyTests.swift:285-296`) | A remote pane reveals a local-host `file://` link in Finder | changed | It revealed this Mac's same-named file; it is forwarded now |
| control-api.md clicked-page bullets | A click replaces a hidden clicked page, except one handed to the presenter | changed for forwarded clicks | Eugene: a forwarded click replaces its own hidden page like a local click |

## Development Approach
- **testing approach**: Regular (code first, then tests, in the same task)
- complete each task fully before moving to the next; every task includes its tests
- all touched tests pass before the next task; gates (`swift test`, `make test-app`, `make lint`) run once at
  the end, targeted runs in between (`-only-testing:` for hosted tests)
- update this plan when scope changes

## Testing Strategy
- **unit tests** (`agtermCore`): policy routes, the shared resolve step, frame codec round-trip, lenient mode
  decode and unknown-kind tolerance, hub routing (presenter-only), client kind retention, the viewer's request
  builder and the origin's target resolution with every refusal reason, hidden-page replacement.
- **hosted tests** (`agtermTests`): origin handling of a forwarded click end to end through
  `receivePresenterFrame` with a fake presenter; viewer forwarding and refusal reporting; a recorder-backed
  `LinkOpener` test.
- No XCUITest: there is no two-Mac UI harness; manual verification is under Post-Completion.

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix, blockers with ⚠️ prefix

## Solution Overview
- **Viewer**: the policy turns a bare, relative or `file://` path clicked in a remote pane into
  `.forwardRemote(raw)`. `LinkOpener.carryOut` sends `.forwardRemote` to a new `forward` closure, or to
  `refuse` when the intent is reveal (⌘⌥). The app reads live AppKit state (HUD, zoom, cover overlay) and the
  client's origin kinds, and passes them to one agtermCore builder that checks presenter mode, the origin's
  `link.click` kind and the pane mapping, and returns either the frame or a refusal reason. The app sends the
  frame or reports the refusal: a self-hiding HUD naming the reason, or a beep when a HUD is already up or
  the panel would be hidden, judged from live state at report time.
- **Origin**: `receivePresenterFrame` takes `link.click` from the current presenter only. An agtermCore resolver
  validates the pane identity and returns that pane's cwd; the shared resolve step (factored out of
  `LinkOpener.follow`) probes the candidates and routes with origin `.pane(session)`. Only page routes (image,
  markdown, text, document) are carried out, through the `open*Link` helpers called in forwarded mode: the zoom
  check is skipped (origin zoom is not what the clicker sees), the HUD check is kept, and `openHtmlOverlay`
  refuses an `openRemotePage` outcome of `.local` instead of opening on the origin. Every other outcome - reveal,
  ignore, a web route, a failed probe, a busy slot, a refused placement - sends one `link.refused` frame back to
  the presenter that sent the click (generation captured at receipt; a refusal for a replaced presenter is
  dropped).
- **Hidden page**: a forwarded click replaces a session-wide remote page that is marked clicked and hidden on the
  presenter, under the existing contract (`ControlServer+ClickedPage.swift:5-7`): a refused click never costs
  the old page. `openRemotePage` in forwarded mode admits that occupant at its slot check, runs every other
  check (placement, capabilities, loopback, frame size), and only then closes the old page through the existing
  remote page close path, immediately before reserving the slot for the new one.
- **Stale clicks**: the presenter generation captured at receipt is rechecked after every await (resolve, probe)
  and immediately before the hidden-page close and the reservation; a click whose presenter changed is dropped
  with nothing opened, closed or sent.
- **Placement**: a forwarded page is session-wide, like a local click. When one pane of a split is led from
  the origin (someone took it back from its cover, or it reconnected without the lead), `openRemotePage`
  returns `.local` and the click is refused (Eugene's choice: one placement rule, no pane-sized variant).
- **Compatibility**: a new capability kind `link.click` covers both frames. An origin without it never receives
  a click (the viewer reports the refusal); a viewer without it never sends one. Unknown kinds are skipped by
  both sides already; the mode travels as a raw string so a new mode value cannot close the stream.
- **Web links** in a remote pane keep their current routes on the viewer.

## Technical Details
- `LinkPolicy.Route` gains one case, `forwardRemote(String, session: UUID)`; `localFile` is nil for it, so
  reveal intent cannot bypass it. `route(for:mode:origin:)`: for `.remotePane`, a bare path, a relative
  spelling, or any `file://` link (any host) yields `.forwardRemote`; the relative shape check is split out of
  `relativePath` (`isRelativeSpelling`) and reused, never joined or stat'ed on the viewer. `route(for:
  LinkLocation, …)` returns `.ignore` for `.remotePane` (no location is offered for one). `locations` keeps
  returning `[]` for a remote pane. `ClickOrigin` and `route`'s signature are unchanged (public, the
  agterm-linux fork uses them); the clicked pane identity travels as a separate argument to `follow`.
- Shared resolve step: `LinkPolicy.resolvedRoute(for:candidates:mode:origin:exists:) -> Route` holds the
  candidate probe and route `LinkOpener.follow` ran inline; `follow` and the origin both call it off the main
  actor, and a link with no candidate routes synchronously as before.
- Frames (`PresentationFrames.swift`): `link.click` body `PresentationLinkClick {raw: String, pane: UUID (origin
  identity), mode: String}`, decoded with `LinkOpenMode(rawValue:) ?? .overlay` so an unknown value never fails;
  `link.refused` body `PresentationLinkRefusal {reason: String}` carrying a `RemoteLinkRefusal` raw value, an
  unknown one read as `notOpened`. Size-capped like other frames.
  `PresentationHub.linkClickKind = "link.click"` joins `supportedKinds`.
- Hub: `.linkClick` joins the presenter-only branch (`PresentationHub.swift:182`).
- Client: `RemotePresentationClient` retains the origin hello's `kinds`, reset on link drop, and exposes
  `originSupports(_:)`; `apply` hands `.linkRefused` to a new `effects.linkRefused` with a default so the fork's
  effect constructors still compile. Presenter state is read from `session.remotePresentation?.mode`.
- Refusal reasons: one agtermCore enum `RemoteLinkRefusal` owns the wording, for example `notPresenter`,
  `originTooOld`, `paneNotAttached`, `revealIntent`, `hidden` (HUD/zoom/cover on this Mac), `notFound`,
  `notAPage` (reveal, ignore or web route on the origin), `notOpened` (any `open*Link` helper `false`: busy slot,
  mixed lead, probe failure). Its `message(host:)` builds the text on the presenting Mac from the raw value and
  the session's own `remoteHost`, so no wording from the other Mac reaches the HUD and no cleaning is needed.
- Viewer builder: `AppStore.linkClickRequest(session:, localPane:, raw:, mode:, originSupportsClick:)
  -> Result<PresentationLinkClick, RemoteLinkRefusal>` (option struct if it grows past four inputs).
- Origin resolver: `AppStore.forwardedClickTarget(session:, pane:) -> (cwd: String?)?` returns nil for a pane
  identity that is neither the session's primary nor split.
- Forwarded mode on the origin: the four `open*Link` helpers and `canShowLinkOverlay` take a `forwarded: Bool`
  argument (default false); `ControlSessionOverlayOpenOptions` gains `forwarded: Bool = false`, carried through
  `with(imagePixels:)` and the image helper's `sized` rebuild; `openHtmlOverlay` returns a refusal for
  `.local` when it is set. `RemoteBinding.remotePane(forLocal:)` becomes public.
- Long files: before Task 3, `openLinkOverlay`, `canShowLinkOverlay` and their link-only helpers move from
  `ControlServer+SessionActions.swift` to a new `ControlServer+LinkOverlay.swift` with no behavior change
  (Eugene approved). The `agtermApp.swift` wiring stays within its limit by calling one `ControlServer`
  method that installs both closures.
- Control API: no new command. A click is a gesture with no meaningful scripted form (a script opens the same
  page with `session overlay open --markdown|--text|--image|--html` on the origin); the result reads back as the
  existing replica page on the viewer's tree node. Recorded as an exemption in `control-api.md`.

## What Goes Where
- Implementation Steps: code, tests and docs in this repo.
- Post-Completion: two-Mac manual check, agterm-linux follow-up.

## Implementation Steps

### Task 1: Policy, shared resolve step and opener on the viewer
**Files:**
- Modify: `agtermCore/Sources/agtermCore/LinkPolicy.swift`
- Modify: `agterm/Ghostty/LinkOpener.swift`
- Modify: `agterm/Ghostty/GhosttySurfaceView+Input.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/LinkPolicyTests.swift`
- Modify: `agtermTests/GhosttySurfaceViewInputTests.swift` (the existing home of the `LinkOpener` click tests,
  which drive `openLink` on a surface; no separate `LinkOpenerTests.swift`)
- Create: `agtermCore/Sources/agtermCore/RemoteLinkRefusal.swift` and `agtermCoreTests/RemoteLinkRefusalTests.swift`

- [x] `RemoteLinkRefusal` with `message(host:)` and a test per reason (the opener's `refuse` closure needs it);
      ➕ it travels by raw value and the presenting Mac builds the text, so no remote wording reaches the HUD;
      ➕ `RemoteLinkClick` (raw, session, local pane, mode) is the value the opener hands on
- [x] `.forwardRemote` route with the remote-pane rules above, `isRelativeSpelling` split out of
      `relativePath`; ➕ the shared step is the synchronous `LinkPolicy.resolvedRoute(for:candidates:…)`, which
      the caller runs off the main actor, so a link with no candidate keeps routing synchronously
- [x] `LinkOpener`: `forward` closure (`RemoteLinkClick` → refusal or nil) and `refuse` closure (session,
      `RemoteLinkRefusal`, default beep); `.forwardRemote` → forward, or refuse with `revealIntent` when revealing;
      `.ignore` stays silent
- [x] surface passes the clicked pane identity (primary or split) into `follow` (`linkClickPane`)
- [x] update remote expectations in `LinkPolicyTests` (:285-296, :381-386, :544-548); add hostless, `localhost`,
      injected this-host and origin-host `file://` cases (all forwarded), a `.bin` case, relative
      `./report.html` and `src/main.py:42` forwarded as typed, `http://localhost:3000` still a web link,
      `route(for: LinkLocation)` from a remote pane is `.ignore`; `resolvedRoute` cases for a local pane
- [x] `GhosttySurfaceViewInputTests`: forward is called once and nothing opens or reveals locally; reveal intent
      and a refused forward refuse once; unsupported scheme is silent; a split pane's click carries the split
      identity, the primary its own
- [x] run the touched tests (66 core, 34 hosted in GhosttySurfaceViewInputTests)

### Task 2: Presentation protocol
**Files:**
- Modify: `agtermCore/Sources/agtermCore/PresentationFrames.swift`
- Modify: `agtermCore/Sources/agtermCore/PresentationHub.swift`
- Modify: `agtermCore/Sources/agtermCore/RemotePresentationClient.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/{PresentationFramesTests,PresentationHubTests,RemotePresentationClientTests}.swift`

- [x] `link.click` / `link.refused` bodies, codec, `kind`, lenient mode, `linkClickKind` in `supportedKinds`;
      ➕ the refusal's reason decodes leniently too, an unknown one as `notOpened`
- [x] hub routes `.linkClick` only from the current presenter
- [x] client retains and resets origin kinds, `originSupports(_:)`, applies `.linkRefused` (defaulted effect)
- [x] ➕ `remotePane(forLocal:)` stays internal: the viewer builder lives in agtermCore (Task 5), so no export
- [x] tests: codec round-trip, an unknown mode decodes to `.overlay`, an unknown reason to `notOpened`, hub drops
      a non-presenter's click, client kinds before hello, after a drop and on a reconnect without the kind,
      `.linkRefused` reaches effects; an older peer skipping the kinds is the existing unknown-kind and
      hello-intersection coverage
- [x] agterm-linux (melonamin/agterm-linux, shallow clone): its Linux port routes clicks through
      `LinkPolicy.disposition`, unchanged, and its frame switches end in `default`; `linkRefused` is defaulted,
      so it needs no change; its copy of the macOS `LinkOpener` predates `.text`/`.document` and gains
      `.forwardRemote` with them on its next upstream merge
- [x] run the touched tests (692 core tests)

### Task 3: Move the link helpers out of the long file
**Files:**
- Modify: `agterm/Control/ControlServer+SessionActions.swift`
- Create: `agterm/Control/ControlServer+LinkOverlay.swift`

- [x] move `openLinkOverlay`, `canShowLinkOverlay` and the helpers only they call, unchanged
- [x] build and run `ControlServerLinkOverlayTests` (25 passed); commit on its own

### Task 4: Origin carries out a forwarded click
**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcherOptions.swift`
- Create: `agtermCore/Sources/agtermCore/AppStore+ForwardedClick.swift` and `agtermCoreTests/AppStoreForwardedClickTests.swift`
- Modify: `agterm/Control/ControlServer+Ask.swift`
- Modify: `agterm/Control/ControlServer+LinkOverlay.swift`, `agterm/Control/ControlServer+SessionActions.swift` (`openHtmlOverlay` only)
- Modify: `agterm/Control/ControlServer+{ImagePage,MarkdownPage,TextPage,DocumentPage}.swift`
- Create: `agterm/Control/ControlServer+ForwardedClick.swift` and `agtermTests/ControlServerForwardedClickTests.swift`

- [x] `forwarded` option carried through `with(imagePixels:)` and the image `sized` rebuild; `openHtmlOverlay`
      refuses `.local` for it; helpers take the click's presenter generation (`forward:`) and
      `canShowLinkOverlay` takes `forwarded` (zoom skipped, HUD kept)
- [x] `forwardedClickPane` in agtermCore (returns the pane's cwd); `openRemotePage` in forwarded mode admits a hidden
      clicked remote occupant at its slot check and closes it through `closeRemoteOverlay` only after every other
      check passed, immediately before the new reservation
- [x] `receivePresenterFrame` handles `.linkClick` (`receiveForwardedClick`): capture the presenter generation,
      target, `resolvedRoute` and the file's existence off the main actor, page routes through the helpers, which
      recheck the generation after their probe; a stale click is dropped silently; every other outcome and every
      helper `false` sends one `link.refused` to the captured generation; nothing reveals or opens a browser here;
      ➕ a relative link no candidate matched refuses `notFound`, not `notAPage`
- [x] core tests: pane primary, split and unknown; a hidden clicked remote page is replaced, a shown one and a
      non-clicked one refuse the slot; a mixed-lead refusal leaves the hidden page in place; a frame-size or
      capability refusal leaves it in place
- [x] hosted tests: each page kind reaches the fake presenter; a relative path and `src/x.py:42` resolve against
      the primary's and the split's own cwd and open at the line; page size follows the sent mode (browser mode
      95%); missing file, unknown pane, `.bin`, web link, busy slot each produce one refusal and no local page;
      mixed lead refused for every page kind, image included; origin zoom does not block; a hidden forwarded
      page is replaced, and kept when the click's file is missing; a presenter change before the probe ends
      opens, closes and sends nothing
- [x] run the touched tests (49 core; 10 ControlServerForwardedClickTests and 25 ControlServerLinkOverlayTests hosted)

### Task 5: Viewer forwarding path
**Files:**
- Modify: `agterm/agtermApp.swift` (one call)
- Modify: `agterm/Control/ControlServer+RemotePresentation.swift` (the `linkRefused` effect)
- Create: `agterm/Control/ControlServer+RemoteLinkClick.swift` and `agtermTests/ControlServerRemoteLinkClickTests.swift`
- Create: `agtermCore/Sources/agtermCore/AppStore+LinkClickRequest.swift` and `agtermCoreTests/AppStoreLinkClickRequestTests.swift`

- [x] `linkClickRequest` in agtermCore: presenter mode, origin kind, pane mapping, the app's hidden flag
- [x] `ControlServer.installRemoteLinkClicks` installs `LinkOpener.forward` and `refuse`; forward reads HUD / zoom /
      cover on this Mac, calls the builder, then `answer(.linkClick)` or returns the refusal
- [x] `refuse` beeps when the session already shows a HUD (local or mirrored), its window has a zoomed terminal,
      or a cover overlay holds the slot; otherwise it opens `HudSpec(message:, hideAfter:
      AppActions.remoteAttachErrorSeconds)` through `openHud` with `RemoteLinkRefusal.message(host:)`, and beeps
      if that open fails; `effects.linkRefused` calls the same `refuse` with live state; ➕ the beep is the status
      sound player's `default` (the system alert), whose alert hosted tests already fake
- [x] core tests: each refusal reason and the success frame with the origin pane identity and mode
- [x] hosted tests: a refusal sends nothing; a `link.refused` frame opens one self-hiding HUD; with an agent HUD
      up the refusal beeps and the original HUD stays unchanged; a zoomed terminal and a busy slot beep
- [x] run the touched tests (3 core; 5 ControlServerRemoteLinkClickTests and 46 ControlServerRemotePresentationTests)

### Task 6: Verify acceptance criteria
- [x] every Overview item holds; each refusal reports exactly once and its HUD clears itself; local panes unchanged
- [x] `cd agtermCore && swift test`, `make test-app` (1872, 0 failures), `make lint`, Release build
- [x] `lsappinfo list | grep -A4 agterm.debug` after the hosted run

### Task 7: [Final] Update documentation
- [x] `site/docs.html`: replace "In a session attached from another Mac, a plain path names a file on that Mac,
      so it is ignored" with the forwarded behavior, the refusal panel, and the ⌘⌥ refusal
- [x] `.claude/rules/control-api.md`: a forwarded-click bullet beside the click paths (kind, presenter-only,
      origin pane identity, forwarded mode, hidden-page replacement, refusal frame and panel, no Finder fallback,
      control API exemption), the `.remotePane` routing sentence, and a lenient-decode line in the stream bullet
- [x] `plugins/agterm/skills/agterm/SKILL.md` (:834, :884 "in a local pane"); `site/commands.html` states neither
      remote-click behavior nor presentation kinds, and README, ARCHITECTURE.md, llms.txt and index.html neither
- [x] move this plan to `docs/plans/completed/`

## Post-Completion
**Manual verification**
- two Macs, both on this build: attach a split session, ⌘-click a `.md`, `.py`, `.png`, `.html` path, a relative
  `src/x.py:42`, an `eza --hyperlink` link and a GNU `ls --hyperlink` link in each pane; the page shows here,
  sized for this Mac
- hide a forwarded page with ⇧⌘J and click another path: the new page replaces it
- ⌘⌥-click and a missing path show the refusal panel, which clears after 5 s; with an agent HUD up a refusal
  beeps and the HUD stays; take one pane's lead back on the origin and confirm a click is refused
- origin on an older build: a click is refused here and nothing opens on either Mac

**External**
- agterm-linux: nothing required (Task 2); its Linux port could adopt forwarding through the same frames later

Smells pre-check: skipped — non-Go project
