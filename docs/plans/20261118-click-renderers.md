# User renderers for ⌘-clicked files

## Overview
- A ⌘-click on a file path opens agterm's built-in page for images, markdown, HTML documents and text. Users
  want their own renderer instead (the request: custom markdown syntax rendered by their own markdown-it plugin).
- A new `open` line in `keymap.conf` maps file selectors to a user command. A ⌘-click on a plain printed path
  whose resolved file matches runs that command with the file's absolute path in `$AGT_PATH`, in place of the
  built-in page. No rule match keeps today's behavior.
- Consent is the explicit rule plus the click. There is no per-click confirmation. The rule runs a local
  command with the clicked file as untrusted input, and the docs say so.
- Remote panes work too: the origin (Mac or agterm-server) sends a one-time snapshot of the clicked file, and
  the viewing Mac runs its own rule on a private copy.
- Prior decisions this narrows, not reverses: #674 declined a general `link.path` hook (OSC 8 targets, any path,
  a cwd variable); #126/#131 keep terminal paths away from LaunchServices. An ask-experts round (codex, Fable)
  found that for a plain-text path the click adds no vector over select+chord except an OSC 8 hidden target,
  which this design excludes by ghostty's own click kind.

## Decisions (Eugene, 2026-11-18, AskUserQuestion)
- Remote support is in scope, by single-file snapshot. Approved limitation: a remote renderer gets no sibling
  files (images a markdown file links to) and a log is a static copy with no live follow; documented.
- OSC 8 exclusion approved: an OSC 8 hyperlink keeps the built-in page even when a rule matches; documented.
- Length-limit splits approved: link click/refusal types and the snapshot payload move from
  `PresentationFrames.swift` to `PresentationLink.swift`; the keymap human formatter moves from
  `SocketClient.swift` to `KeymapFormatter.swift` with its own tests; the server snapshot seam goes in
  `ServerStreams+Snapshot.swift` with its own tests.
- Basename selectors kept beside extension selectors.
- Testing approach: TDD. Work happens in the `click-renderers` worktree.

## Context (from discovery)
- Click entry: `agterm/Ghostty/GhosttyCallbacks.swift:136` (`GHOSTTY_ACTION_OPEN_URL`, drops `open_url.kind`),
  `agterm/Ghostty/GhosttySurfaceView+Input.swift:657` (`openLink`), `agterm/Ghostty/LinkOpener.swift` (`follow`,
  `carryOut`).
- Routing: `agtermCore/Sources/agtermCore/LinkPolicy.swift` (`disposition`, `localPath`, `locations`,
  `trimmedSpellings`, `resolvedRoute`, `route`, `Route.localFile`, `ClickIntent`).
- Kind enum: `GhosttyKit.xcframework/macos-arm64/Headers/ghostty.h:873` (`UNKNOWN`, `TEXT`, `HTML`, `OSC8`).
- Keymap: `agtermCore/Sources/agtermCore/Keymap.swift` (`parseKeymap` verbs `map`, `command`, `global-hotkey`),
  `CustomCommand.swift`, `CommandContext` token table, `ControlKeymap.swift` (`keymap.list` projection),
  `agterm/SettingsModel.swift` (owns the reloaded keymap), `ConfigPaths.swift` (starter keymap),
  `.claude/rules/keymap.md`.
- Runner: `agterm/Commands/CustomCommandRunner.swift` (`spawn`: whole-line `context.expand`, `/bin/sh -c`,
  failure notification, panel with `--error-hud`).
- Remote click: `AppStore+LinkClickRequest.swift`, `agterm/Control/ControlServer+RemoteLinkClick.swift` (viewer),
  `agterm/Control/ControlServer+ForwardedClick.swift` (Mac origin), `AgtermServerKit/ServerStreams.swift:299`
  (agterm-server origin), `PresentationFrames.swift:653` (`PresentationLinkClick`), `PresentationHub.swift`
  (`linkClickKind`), `RemotePresentationClient.swift` (`linkRefused`), `RemoteLinkRefusal.swift`.
- Page claim route to reuse: `session.overlay.page.serve` → `PageServeHost.claimPageStream` /
  `adoptPageServeStream` (`PageServeStream.swift:450`), adopted in `agterm/Control/ControlServer.swift:563` and
  `ServerStreams.swift:268`, launched by `RemoteSession.swift:77`; the page bridge already refuses the command.
- Viewer transfer: `agterm/Control/RemotePageChannel.swift` (`fetch`, `close` fails buffered transfers).
- Reused checks: `BoundedFile` (descriptor check, size caps), `PasteStaging` (0700 folder, retention sweep),
  `PasteBundle.isSafeComponent`.

## Development Approach
- **testing approach**: TDD: each checklist opens with its failing tests, host-free and hosted alike
- complete each task fully before moving to the next; the touched suites pass before the next task starts
- update this plan when scope changes during implementation
- `agtermCore` stays host-free: parsing, matching, gating, frames and snapshot bookkeeping live there; the app
  target only launches processes and moves bytes
- presentation frames are additive and optional so an older origin or viewer keeps decoding; the new
  `opener.run` event kind follows the existing same-build rule for the control socket (`agtermctl` ships in the
  bundle; `.claude/rules/control-api.md`), as the `message` kind did, and is not guarded for a stale CLI
- `agtermCore` public API changes stay source-compatible for the agterm-linux fork: new callbacks beside old
  ones, defaulted init arguments, default implementations for new protocol requirements; new enum cases only
  after checking a fork clone (`fork:true`) for exhaustive switches over that enum
- every timer, window and sweep takes an injected clock (`.claude/rules/tests.md`)

## Testing Strategy
- host-free unit tests in `agtermCore` (`swift test`): parsing, matching, gating, frames, book, staging, the
  server snapshot seam (`AgtermServerTests`)
- hosted AppKit tests (`make test-app`): click provenance through `LinkClickFixture`, runner launch, Mac origin
  and viewer round trip
- no new XCUITest
- gates run once at the end: `swift test`, `make test-app`, `make lint`

## Solution Overview
- **Rule**: `open <selectors> [options] <shell...>`. Selectors are a comma-separated list of `*.ext` (extension,
  case-insensitive) and exact basenames (`Makefile`, `.env`). Options are the `command` line's failure-panel
  options only. Example: `open *.md,*.markdown mdview "$AGT_PATH"`. A basename selector beats an extension
  selector for the same file; a selector repeated on a later line wins, and the earlier line is diagnosed, as
  `map` is last-wins.
- **Which clicks**: only ghostty's `TEXT` kind (plain detected path or plain `file://`, as measured in Task 1).
  `OSC8`, `HTML` and `UNKNOWN` keep the built-in route. Reveal (⌘⌥) and browser (⌘⇧) intents are decided first and
  never run a rule. Rules apply exactly where a click opens a built-in preview today: a pane, a split, a scratch
  (with that surface's context) and a remote pane (through the snapshot). HUD, program-overlay and quick-terminal
  clicks reveal the file today (`LinkPolicy.route`) and keep doing so.
- **Which files**: the route after today's resolution (`resolvedRoute`) must be `.image`, `.markdown`,
  `.document` or `.text`, i.e. a file the built-in preview would open, and pass the regular-file descriptor check.
  A rule for a type agterm would only reveal never fires.
- **Launch**: the opener's shell text runs VERBATIM under `/bin/sh -c`: no `{AGT_X}` token is expanded, because
  `CommandContext.expand` would paste terminal-derived values (`{AGT_SESSION_PWD}`, `{AGT_SESSION_NAME}`) into
  shell source. Context travels only as environment: `$AGT_PATH` plus the `$AGT_*` env of the CLICKED pane
  (`AGT_PANE`, `AGT_PANE_ID`, `AGT_SESSION_PWD`, `AGT_SESSION_HOST` follow the pane, captured before any async
  step, so a click on an unfocused split names that split). cwd is fixed to `$HOME`. `AGT_PATH` is not added to
  the `CommandContext` token table, so `command` lines never see it. Any `{AGT_` token in an `open` line is a
  diagnostic, so nobody writes one expecting expansion.
- **Failures**: no match opens the built-in page. Once a rule is chosen, every failure is the command's own:
  a launch that throws, a missing renderer (exit 127 from `/bin/sh`) or any nonzero exit reports through the
  existing command failure path (a notification, plus a panel with `--error-hud`) and opens nothing.
- **Remote**: the viewer adds a click id and the matching selector list to `link.click` when the origin lists a
  new `link.snapshot` kind. The origin resolves the click as today; when the resolved file matches a selector and
  is eligible, it registers a one-time snapshot offer and answers `link.snapshot {click, token, name, size}` to
  that viewer only, instead of opening a page. No match, or a file over the page cap, opens the built-in remote
  page as today. The viewer accepts a snapshot only for a pending click id of that connection, session and pane,
  picks the rule from the resolved name (the origin's resolution can strip a `:line` suffix or punctuation, so
  a basename rule may win over the extension rule the raw text suggested), claims the offer once, writes a private
  copy, and runs the rule on it. An older origin gets today's frame and opens the built-in page. Once an offer
  has arrived, every failure up to the spawn (a refused claim, a failed or short read, a teardown) is reported on
  the viewer as `snapshotFailed` and ends the click with no re-forward: a re-forward would resolve a relative path
  again against the pane's current cwd and could open a different file.

## Technical Details
- `FileOpener` (agtermCore): `selectors: [OpenerSelector]`, the shell text, failure-panel options, `line: Int`.
  `OpenerSelector` is `.extension(String)` or `.basename(String)`. `Keymap.openers: [FileOpener]`, a defaulted
  init argument; `Keymap.opener(forFile:) -> FileOpener?` matches basename first, then extension.
- Diagnostics: unknown selector form (any other glob), empty selector list, missing shell, an option outside the
  failure-panel set (`--repeat` and a chord included), any `{AGT_` token, and an earlier line whose selector a
  later line claims.
- Openers are read at click time from `SettingsModel.keymap`; the keyboard matcher keeps no second copy.
- `LinkPolicy.ClickSource` (`text`, `osc8`, `html`, `unknown`) mapped from the C enum in the app target.
  `LinkPolicy.openerFile(for route: Route, source: ClickSource, intent: ClickIntent) -> URL?` returns the file
  only for `.text` source, normal intent and the four preview routes. `LinkPolicy.candidateNames(for raw:)`
  returns the basenames of the literal path and of each spelling the `:line` split and `trimmedSpellings` try.
- Event `opener.run`: `ControlEventPayload` gains `path` and `selector`; the event carries those plus session and
  pane, `path` being the file the command received (the staged copy on a remote click) and `host` set for a
  remote click. `EventFormatter.human` prints them.
- `keymap.list` adds `openers: [{selectors, command, line}]` in the `ControlKeymap` projection, omitted when none.
- Frames (in `PresentationLink.swift`, moved out of `PresentationFrames.swift`): `PresentationLinkClick` gains
  optional `click: UUID` and `openers: [String]`; `PresentationLinkRefusal` gains optional `click: UUID`; new
  `PresentationLinkSnapshot {click, token, name, size}`; the frame body gains one case `linkSnapshot`; new kind
  `PresentationHub.linkSnapshotKind`. `RemotePresentationClient` adds `linkSnapshot` and a click-aware refusal
  callback beside the existing `linkRefused`, which keeps its signature.
- Snapshot serving reuses the page claim route. `PageServeHost` gains `offerSnapshot(file:size:) -> token`
  with `claimPageStream` consulting the snapshot book after attachments and before pages, and
  `adoptPageServeStream` adopting a snapshot claim through its own branch; new requirements get default
  implementations in the extension. The stream reuses `PageServeStream`'s resource framing with no reservation,
  reoffer, bridge or log-tail authority: it answers exactly one read of the offered file and refuses any other
  path, a second read and every other request. `PageServeHost.pageClaimUnanswered`, which both socket handlers
  call when a claim succeeded but its reply failed to write, also drops a claimed snapshot, without touching page
  loss or reoffer. The origin never closes it after the last frame, since a queued
  `.end` can be dropped by `shutdown`; the viewer closes the channel after it has drained the read through
  `.end`, because `RemotePageChannel.close` fails every buffered transfer, a finished one included. An unclaimed
  offer expires after `AppStore.pageClaimWindow`; a claimed one is bounded by the viewer's read deadline.
- Pending click book on the viewer (`PendingOpenerClicks`): keyed by click id, scoped to the presentation
  connection, session and clicked pane, holding the candidate names and the rules eligible for them. On
  `link.snapshot` the received name must be one of those candidates and `Keymap.opener(forFile:)` picks the rule.
  The entry stays in the book, marked in flight, through the claim and read until the spawn, so the same teardown
  cancels an in-flight transfer and deletes its copy; the identity is rechecked just before the spawn. Retired
  by the spawn, by a failure, by a refusal carrying its id, by `AppStore.pageClaimWindow` elapsing before an
  offer, or by the connection's teardown. A no-match click needs no answer of its own: the origin opens its page
  and the entry times out.
- Viewer staging: `OpenerStaging` (agtermCore), modeled on `PasteStaging`: `<caches>/agterm/open/<uuid>/<name>`,
  folder 0700, entries older than one hour swept on each receive and at app launch. `name` and `size` are wire
  input: the name must pass `PasteBundle.isSafeComponent` and be one of the pending click's candidate names, the
  size must be within the local cap for its kind, the read enforces that cap as it goes and is bounded in time,
  and the rule launches only on a clean end with exactly `size` bytes. Anything else deletes the copy and reports
  `snapshotFailed`, a viewer-only `RemoteLinkRefusal` case that never travels.

## What Goes Where
- Implementation Steps: code, tests and docs in this repository.
- Post-Completion: manual checks against real remote hosts and the user reply.

## Implementation Steps

### Task 1: pin ghostty's click kind

**Files:**
- Modify: `agterm/Ghostty/GhosttyCallbacks.swift`, `agterm/Ghostty/GhosttySurfaceView+Input.swift`,
  `agterm/Ghostty/LinkOpener.swift`, `agtermCore/Sources/agtermCore/LinkPolicy.swift`
- Modify tests: `agtermTests/GhosttySurfaceViewInputTests.swift`

- [ ] failing hosted tests on `LinkClickFixture`: a printed absolute path, a printed relative path and a printed
      `file://` link reach `openLink` as `TEXT`, an OSC 8 link as `OSC8`; the tests stay in the suite so a
      `GHOSTTY_REV` bump that changes the mapping fails them
- [ ] `LinkPolicy.ClickSource`; carry the kind from the callback through `openLink` and `LinkOpener.follow`
      (a HUD click reaches the same callback through `passiveClick` and carries its real kind); no behavior change
- [ ] record the measured kinds here; if plain paths are not `TEXT`, stop and bring it to Eugene; if only
      `file://` differs, keep it on the built-in route and note it for the docs
- [ ] check an agterm-linux clone (`fork:true`) for exhaustive switches over `RemoteLinkRefusal`, the presentation
      frame body and `ControlEventKind`, and for `RemotePresentationClient`/`PageServeHost` conformers, before any
      later task adds a case or requirement; record what it uses and adjust the additive plan if anything breaks
- [ ] run `GhosttySurfaceViewInputTests` with `-only-testing`

### Task 2: `open` rule in the keymap and its read-back

**Files:**
- Create: `agtermCore/Sources/agtermCore/FileOpener.swift`, `agtermCore/Sources/agtermctlKit/KeymapFormatter.swift`,
  `agtermCore/Tests/agtermctlKitTests/KeymapFormatterTests.swift`
- Modify: `agtermCore/Sources/agtermCore/Keymap.swift`, `ControlKeymap.swift`, `ConfigPaths.swift` (starter
  `open` example), `agtermCore/Sources/agtermctlKit/SocketClient.swift` (formatter moved out),
  `agterm/SettingsModel.swift`, `.claude/rules/keymap.md` (`paths:` adds `FileOpener.swift`)
- Modify tests: `agtermCoreTests/KeymapTests.swift`, `ControlKeymapTests.swift`, `ConfigPathsTests.swift`,
  `agtermctlKitTests/SocketClientTests.swift` (formatter tests move out), the hosted `SettingsModel` reload test

- [ ] failing tests: selector parsing (`*.md`, `Makefile`, `.env`, mixed-case extension), every diagnostic in
      Technical Details, last-wins with the earlier line diagnosed, `opener(forFile:)` basename before extension,
      the starter example applying when uncommented, `openers` in the projection and the human output
- [ ] `FileOpener`, `OpenerSelector`, the `open` verb in `parseKeymap`, `Keymap.openers` as a defaulted init
      argument, reusing the `command` line's option and shell parsing without chord handling
- [ ] move the keymap formatter to `KeymapFormatter.swift` unchanged, then add the `openers:` section
- [ ] `keymap.reload` exposes openers through `SettingsModel.keymap`; hosted reload test
- [ ] run `swift test` for the keymap, control and CLI suites and the hosted reload test

### Task 3: local ⌘-click runs a matching rule

**Files:**
- Modify: `agterm/Ghostty/LinkOpener.swift`, `agtermCore/Sources/agtermCore/LinkPolicy.swift`,
  `agterm/Commands/CustomCommandRunner.swift`, `agtermCore/Sources/agtermCore/ControlEvents.swift`
  (`opener.run`, payload `path`/`selector`), the event formatter
- Modify tests: `agtermCoreTests/LinkPolicyTests.swift`, `agtermCoreTests/ControlEventProtocolTests.swift`,
  `agtermctlKitTests/EventCommandsTests.swift`, `agtermTests/CustomCommandRunnerTests.swift`,
  `agtermTests/GhosttySurfaceViewInputTests.swift`

- [ ] failing host-free tests for `openerFile`: `.text` source with each preview route returns the file; `osc8`,
      `html`, `unknown`, reveal and browser intents, `.reveal` and web routes return nil; event round trip and
      human formatting
- [ ] failing hosted tests: env and cwd the process sees (a script writing them to a temp file), a click on an
      unfocused split names that split's pane values, a scratch click gets the scratch context, a quick-terminal
      click on a matching file reveals it and launches nothing, a `{AGT_SESSION_NAME}` in the shell text stays literal, a missing renderer (exit 127) posts the
      notification and with `--error-hud` the panel and opens nothing, no launch for a directory or FIFO, an
      OSC 8 link to a matching file opens the built-in page
- [ ] `LinkOpener` captures the clicked pane before the async lookup; in `carryOut`, before the preview arms,
      `openerFile` plus a matching rule from `SettingsModel.keymap`, the regular-file check off the main actor,
      then the runner
- [ ] runner entry `runOpener(_:path:pane:)` sharing the process setup, PATH widening and failure reporting with
      `spawn`, running the shell text verbatim with context as environment only, cwd `$HOME`; emit `opener.run`
- [ ] run the touched suites

### Task 4: snapshot wire format, book, staging and server origin (host-free)

**Files:**
- Create: `agtermCore/Sources/agtermCore/PresentationLink.swift`, `PendingOpenerClicks.swift`,
  `OpenerStaging.swift`, `agtermCore/Sources/AgtermServerKit/ServerStreams+Snapshot.swift`,
  `agtermCoreTests/PresentationLinkTests.swift`, `agtermCoreTests/PendingOpenerClicksTests.swift`,
  `agtermCoreTests/OpenerStagingTests.swift`, `AgtermServerTests/ServerStreamsSnapshotTests.swift`
- Modify: `PresentationFrames.swift` (types moved out, one body case), `PresentationFrame+Codable.swift`,
  `PresentationHub.swift`, `RemotePresentationClient.swift`, `RemoteLinkRefusal.swift`, `PageServeStream.swift`,
  `LinkPolicy.swift` (`candidateNames`), `AgtermServerKit/ServerStreams.swift` (forwarded click, adopt branch)
- Modify tests: `PresentationFramesTests.swift`, `PageServeFramesTests.swift`, `LinkPolicyTests.swift`

- [ ] failing tests: frame round trip with and without the new fields and an old frame decoding; kind
      negotiation; `candidateNames` for literal, `:line` and trailing-punctuation spellings; the book (one
      snapshot per click id within its connection, session and pane; `src/Makefile:3` matches a `Makefile` rule;
      `file.swift` beats `*.swift` for `src/file.swift:3`; a name outside the candidates, unknown ids, a second
      token, a late arrival and anything after teardown rejected; expiry on an injected clock); staging (0700,
      unsafe name, over-cap size, one-hour sweep on an injected clock)
- [ ] move the link frame types to `PresentationLink.swift` unchanged, then add the fields, the snapshot payload,
      the body case, the kind and the two client callbacks
- [ ] snapshot seam on `PageServeHost` with default implementations, `pageClaimUnanswered` dropping a claimed
      snapshot; agterm-server's forwarded click offers a
      snapshot on a match within the cap and opens the page otherwise; refusals carry the click id
- [ ] server seam tests in `ServerStreamsSnapshotTests`: one read served, a second read, another path and a bridge
      request refused, unclaimed offer expiry, an over-cap file opening the page, no close after the last frame,
      a claim whose reply failed to write dropped by `pageClaimUnanswered` with no page loss or reoffer
- [ ] run `swift test`

### Task 5: Mac origin and viewer wiring with the remote round trip (hosted)

**Files:**
- Modify: `agterm/Control/ControlServer+RemoteLinkClick.swift`, `ControlServer+RemotePresentation.swift`,
  `ControlServer+ForwardedClick.swift`, `ControlServer+PageServe.swift`, `ControlServer.swift` (adopt branch),
  `agterm/Control/RemotePageChannel.swift`, the app-launch path that sweeps `OpenerStaging`
- Modify tests: hosted forwarded-click and remote presentation tests, page channel tests

- [ ] failing hosted tests: Mac origin match and no-match, an older origin, two outstanding clicks resolved
      independently, a consumer paused after `.end` still launching, a disconnect after a valid offer and before
      the last chunk launching nothing and leaving no copy, a short read and an overlong read reporting
      `snapshotFailed`, the read deadline on an injected clock, `opener.run` carrying the staged path and host,
      a post-spawn failure reporting through the command path
- [ ] viewer: `LinkOpener` decides remote eligibility before building `RemoteLinkClick`, from the click's
      `ClickSource` and `ClickIntent` (never from `LinkOpenMode`, where `.browser` cannot tell the explicit ⌘⇧
      intent from the Browser setting); only a `.text` source with normal intent, an origin listing
      `link.snapshot` and a rule matching a candidate name record a pending click and send click id and
      selectors; everything else sends today's frame
- [ ] hosted tests for that gate against a capable origin: a matching OSC 8 target and an explicit browser-intent
      click send today's frame with no snapshot request; a normal `.text` click with the Browser link mode
      configured still qualifies
- [ ] Mac origin: offer a snapshot on a match within the cap, open the page otherwise, click id on refusals;
      adopt snapshot claims through `ControlServer.swift`'s adopt branch
- [ ] viewer: validate name and size, pick the rule, claim through `session.overlay.page.serve`, read with the cap
      and deadline, drain through `.end`, close, write through `OpenerStaging`, recheck the pending identity,
      launch on the copy; sweep staging at app launch
- [ ] run the touched hosted suites

### Task 6: docs, skill, rules, and final gates

**Files:**
- Modify: `site/docs.html` (#links-files, the keymap section, the event list), `site/commands.html`
  (`keymap.list` openers, `opener.run`), `plugins/agterm/skills/agterm/SKILL.md` and its reference,
  `.claude/rules/keymap.md`, `.claude/rules/control-api.md`

- [ ] user guide: the `open` line, selectors and precedence, what the command receives, that it runs with the
      clicked file as untrusted input, that OSC 8 links keep the built-in page, the remote snapshot and its
      limits (no sibling files, no live log follow), the `opener.run` event, and the raw-HTML / `data-agterm`
      warning for renderers that open `--html`
- [ ] command reference and skill: `keymap.list` `openers`, the `opener.run` event, a trigger in SKILL.md's
      description for "custom renderer for clicked files"
- [ ] rules files: the gating contract and the snapshot handshake, each owned once
- [ ] verify every Overview requirement and Decision is implemented; run `swift test`, `make test-app`,
      `make lint` once
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion
- Manual check with a real remote Mac and an agterm-server Linux host: click a `.md` in each, confirm the
  user's renderer opens on the viewing Mac and that an older origin still opens the built-in page.
- Reply to the requesting user with the `open` line and an example renderer once released.
