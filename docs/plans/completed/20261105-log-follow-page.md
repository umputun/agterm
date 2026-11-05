# Log follow page

## Overview
- A cmd-clicked `.log` or `.out` file opens the same themed text page as today, in a log mode: it shows only
  the last 5,000 lines (bounded to about 2 MB), and it follows the file as it grows.
- Today a `.log` opens as a static `TextPage`, read whole through `BoundedFile` with a 4 MB cap, so a large log
  is refused and a growing one goes stale. Log mode reads only the file's end, so no log is refused for size.
- A thin bar on the page shows `Follow: on` or `Follow: paused - Resume` and `last N lines`. Scrolling up
  pauses and freezes the view; scrolling back to the bottom or clicking Resume reloads the tail and follows
  again. A missing file (mid-rotation, deleted) shows a waiting state until it reappears.
- Control API: `overlay open --text PATH --tail N --follow-file`, `overlay follow on|off|toggle`, and
  read-back on `htmlOverlays[].text`.

## Context (from discovery)
- `agtermCore/Sources/agtermCore/TextPage.swift`: eligibility, `plainExtensions` (holds `log`, `out`),
  `maxBytes` 4 MB, `maxHighlightBytes` 256 KB, `html(text:language:line:style:)`.
- `agtermCore/Sources/agtermCore/HtmlOverlay.swift`: `HtmlSource.text(path:line:)` (public; the agterm-linux fork
  matches on it, so it stays unchanged); `HtmlOverlay` already carries per-page request flags (`javascript`,
  `persistent`, `browse`, `clicked`) set from `ControlSessionOverlayOpenOptions` (`ControlDispatcherOptions.swift`).
- `agtermCore/Sources/agtermCore/AppStore+HtmlOverlay.swift`: host-free `htmlOverlayNode` builds the read-back from
  the model; `setHtmlLoadState` is the pattern for app-reported page state.
- `agtermCore/Sources/agtermCore/AppStore+RemotePage.swift`: `pageBelongsRemote(_:pane:)` is the placement rule;
  `openRemotePage` returns `.local` when the page does not follow remotely, and `presentationSource` maps text
  to path and line only.
- `agtermCore/Sources/agtermCore/ControlDispatcher+Overlay.swift`: `overlayContent`/`textContent`, `textFile` and
  `line` validation; `agtermCore/Sources/agtermctlKit/SessionCommands.swift` (878 lines) has `overlay open --text`.
- `agterm/Views/HtmlOverlayRegistry.swift` is 990 lines against the 1000-line limit; `HtmlOverlayPage` members
  are private. A page object is created only when `HtmlWebViewHost.makeNSView` asks for it
  (`HtmlOverlayView.swift`), so app-side state cannot exist before a view realizes.
- `textLoad` is the page's one document-build counter (`loadOriginal`'s text arm, `close()`); `applyTheme`
  reloads a styled page through `loadOriginal`, which re-reads from disk.
- `agterm/Resources/markdown/text.js` (34 lines) and `text.css`; `agterm/Control/ControlServer+TextPage.swift`
  (`openTextLink`, `textFileRefusal`); `agtermCore/Sources/agtermCore/LinkPolicy.swift` (`Route.text`).
- Existing `overlay open --follow` means "select the session"; `overlay follow` is a separate command and does
  not collide with it.
- Exhaustive `Command` switch in `agterm/Control/ControlServer.swift`; `HtmlBridge.swift` `ownOverlay` list.

## Development Approach
- **testing approach**: Regular (code first, tests in the same task)
- complete each task fully before moving to the next; small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task, success and error paths
- **CRITICAL: all tests must pass before starting next task**
- **CRITICAL: update this plan file when scope changes during implementation**
- run each gate once at the end; during a task run `swift test --filter` and `-only-testing:` for what changed
- every task leaves the app target compiling: mechanical edits a change forces in the app are listed in that task
- maintain backward compatibility: a page or request without the new fields behaves exactly as today
- if `HtmlOverlayRegistry.swift` would still pass 1000 lines after moving the log logic out, stop and ask
  Eugene before splitting it

## Testing Strategy
- **unit tests** (`cd agtermCore && swift test --filter ...`): tail snapshot, `TextPage` log helpers, the log
  model and store setters, dispatcher validation, protocol round-trip, nil omission and population, CLI parsing.
- **hosted tests** (targeted `-only-testing:agtermTests/<Class>`): `readTail`, the log probe, `LogFollower`
  driven by a synchronous `tick()`, page render and updates, link routing.
- **UI tests** (targeted `-only-testing:agtermUITests/ControlHtmlOverlayUITests/<test>`): open with
  `--tail --follow-file`, append, read back; `overlay follow off` then `on`.

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- keep plan in sync with actual work done

## Solution Overview
- **The request and the follow state live on the `HtmlOverlay` model.** The open carries `TextLog` through
  `ControlSessionOverlayOpenOptions` onto `HtmlOverlay.textLog`, as `javascript` and `persistent` travel today, so
  `HtmlSource.text`, `presentationSource` and the replica path are untouched. Following, displayed lines, clipped,
  waiting and unreadable sit in `HtmlOverlay.logState`, written host-free by store setters, so the CLI can change
  following before any view exists and `tree` reads it from the model.
- **Bounded tail snapshot, re-read by path about once a second while following.** Each tick opens the file by
  path and reads at most `maxTailBytes` from its end. Re-opening by path handles rotation and copytruncate; the
  byte cap means one huge line cannot pull in gigabytes. A tick that finds the same inode, size and mtime does no
  work. `LogFollower` owns the tick, its own generation counter, the cached snapshot and the scroll anchor.
- **Pause lives in the page and in the model.** `text.js` posts `{following}` to one narrow handler, registered
  on log pages only, when the user scrolls away from or back to the bottom; the app writes it to the model. The
  page picks up a model change in `apply(_:)` and calls `agtermTextSetFollowing`. Pausing bumps only the
  follower's generation, never `textLoad`, so a document being built still renders.
- **Updates go in as data** through `agtermTextUpdate` in `text.js`'s content world, written with `textContent`.
- **No totals, no line numbers, no Load earlier**: counting earlier lines needs the whole file.
- **path:line clicks keep the static page.** Only a plain click on `.log`/`.out` opens log mode.
- **Remote stays as today.** A page that `pageBelongsRemote` hands to the presenting Mac never gets log mode:
  a control open is refused, and a click opens the static page there as it does now.

## Technical Details
- `TextPage`: `logExtensions = ["log", "out"]`, `isLog(file:) -> Bool`, `defaultTail = 5_000`,
  `maxTail = 100_000`, `maxTailBytes = 2 << 20`; `html(...)` takes the log options and writes `data-log`,
  `data-following`, `data-clipped` on the holder and omits the gutter in log mode.
- `LogTail` (agtermCore, host-free): `snapshot(_ data: Data, fromFileStart: Bool, maxLines: Int) -> LogTail.Snapshot?`,
  `Snapshot { text: String, lines: Int, clipped: Bool }`. The read starts one byte before the window so a window
  that begins exactly on a line boundary keeps that line. When the read did not start at file start, drop bytes up
  to and including the first LF only when bytes follow it; with no LF, or the only LF as the last byte (one line
  longer than the window), keep that line's suffix after any leading UTF-8 continuation bytes and set `clipped`.
  Drop an incomplete UTF-8 scalar at the end; keep a final line without LF; keep the last `maxLines` lines. Lines
  split on LF; a CR before LF stays in the text (rendered invisibly) and a CRLF file counts the same lines as LF.
  nil for a NUL byte or invalid UTF-8 in what remains.
- `HtmlOverlay.textLog: TextLog?` (`TextLog { tail: Int, follow: Bool }`, the request) and
  `HtmlOverlay.logState: TextLogState?` (`following`, `lines`, `clipped`, `waiting`, `unreadable`).
- `AppStore.setTextLogFollowing(session:pane:mode:) -> Result<Bool, HtmlOverlayCommandFailure>`: refused
  `no log page` for any other occupant; a change schedules `tree.changed`.
  `AppStore.setTextLogState(_ id:, _ state:)` writes only on change and schedules no event, so per-tick reports
  never wake hooks.
- Wire: `ControlArgs.tail: Int?`, `ControlArgs.followFile: Bool?`. Dispatcher: `tail` or `followFile` without
  `textFile` refused in `overlayContent` before any source dispatch, beside the `line` check; with `line`
  refused; `tail` must be `1...TextPage.maxTail`; `followFile` alone means `tail = defaultTail`; `tail` without
  `followFile` is a one-shot tail with follow off.
- `session.overlay.follow on|off|toggle [--pane]` uses `ControlArgs.mode` with `ControlToggleMode.parse`; CLI in
  `agtermctlKit/Session+OverlayFollow.swift`. `HtmlBridge` treats it as an own-overlay command.
- Read-back on `htmlOverlays[].text`: `tail`, `following`, `lines`, `clipped`, `waiting`, `unreadable`, all
  omitted for a non-log text page.
- App: `BoundedFile.readTail(path:maxBytes:) -> Result<TailRead, Failure>` with
  `TailRead { data: Data, fromFileStart: Bool, stamp: FileStamp }` (one open, `fstat` regular-file and offloaded
  checks as today, `pread` from `max(0, size - maxBytes - 1)`).
- `LogFollower` (`agterm/Views/LogFollower.swift`): a main-actor object the page holds as `LogFollower?` behind a
  few hook lines (load, `apply`, `setOnScreen`, theme reload, `close`). It detaches only the file read, like the
  existing `textLoad` arms. It ticks while `following`, `onScreen` and `store?.htmlOverlaySlot(id) != nil`
  (a soft-closed or unmounted page stops), ticks at once on resume or on coming back on screen, and exposes a
  synchronous `tick()` and an injectable interval for tests. A nil snapshot keeps the last view and sets
  `unreadable` (bar note `unreadable data`). A theme reload or remount renders from the cached snapshot and
  anchor, and always receives the cache even when the stamp is unchanged. An explicit `session.overlay.reload`
  (a `reloadRevision` change) reads a fresh bounded snapshot even while following is off, and leaves following
  as it was.
- `text.js` log mode: bar, no gutter, `agtermTextUpdate(text, clipped, waiting, unreadable)` and
  `agtermTextSetFollowing(following)`; posts `{following}` only on a user scroll transition, so a CLI `off`
  at the bottom is not undone by a resize. Bar styles go in `text.css`.

## What Goes Where
- **Implementation Steps**: code, tests and docs in this repo.
- **Post-Completion**: manual checks against real rotating logs.

## Implementation Steps

### Task 1: Host-free tail snapshot and log model

**Files:**
- Create: `agtermCore/Sources/agtermCore/LogTail.swift`, `agtermCore/Tests/agtermCoreTests/LogTailTests.swift`
- Modify: `agtermCore/Sources/agtermCore/TextPage.swift`, `HtmlOverlay.swift`, `ControlDispatcherOptions.swift`,
  `AppStore+HtmlOverlay.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/TextPageTests.swift`, `HtmlOverlayTests.swift`

- [x] add `LogTail.snapshot` and `LogTail.Snapshot` per Technical Details
- [x] add the `TextPage` log constants, `isLog(file:)` and the log options of `html(...)`
- [x] add `TextLog`, `TextLogState`, `HtmlOverlay.textLog`/`logState`, the open option, and the store setters
      ➕ three setters: `setTextLogFollowing(session:pane:mode:)` for the command, `setTextLogFollowing(id:following:)`
      for the page's scroll report (event on change), `setTextLogReport(id:)` for ticks (no event), so a tick can
      never overwrite a following change; `TextLogFollowFailure` is a new type so the fork's switches over
      `HtmlOverlayCommandFailure` keep compiling
- [x] write `LogTailTests` table cases: file start vs mid-file, window starting on a line boundary, partial first
      line, no LF in window, a line longer than the window ending in LF at its last byte, trailing partial UTF-8
      scalar, final line without LF, more than `maxLines`, CRLF line count, empty data, NUL, invalid UTF-8
- [x] extend `TextPageTests` (isLog, html attributes, no gutter in log mode) and `HtmlOverlayTests` (setters:
      refusal for non-log pages, write-on-change, event only on a follow transition)
- [x] run `swift test --filter 'LogTailTests|TextPageTests|HtmlOverlayTests'` - must pass before task 2

### Task 2: Control protocol, dispatcher, CLI and read-back

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`, `ControlDispatcher+Overlay.swift`, `ControlProjection.swift`,
  `AppStore+HtmlOverlay.swift`, `ControlActions*.swift` (new action with an unsupported default), `HtmlBridge.swift`
- Create: `agtermCore/Sources/agtermctlKit/Session+OverlayFollow.swift`
- Modify: `agtermCore/Sources/agtermctlKit/SessionCommands.swift` (`--tail`, `--follow-file`)
- Modify: `agterm/Control/ControlServer.swift` (exhaustive `Command` switch), the overlay open adapter
- Modify: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift`, `ControlDispatcherOverlayTests.swift`,
  the `AppStore` html overlay tree tests; `agtermCore/Tests/agtermctlKitTests/OverlayCommandsTests.swift`

- [x] add `tail` and `followFile`; validate in `overlayContent` and `textContent`; carry `TextLog` to the model
- [x] add `session.overlay.follow` with mode and `--pane`, dispatcher-first, routed to the store setter
- [x] project the log fields in `htmlOverlayNode`, omitted when nil
- [x] CLI `overlay open --tail N --follow-file` and `overlay follow on|off|toggle [--pane]`; help names the
      difference from `--follow`
- [x] write protocol round-trip, nil-omission and population tests; dispatcher success and refusal tests for
      each rule, including `--tail`/`--follow-file` with no `--text` and with `--image`/`--markdown`; CLI parse tests
- [x] run `swift test --filter 'ControlProtocolTests|ControlDispatcherOverlayTests|OverlayCommandsTests|HtmlOverlayTests'`
      - must pass before task 3

### Task 3: Log page in the app: tail read, follower, page bar and scroll pause

**Files:**
- Modify: `agterm/Views/ImageProbe.swift` (`BoundedFile.readTail`), `agterm/Views/TextProbe.swift`
- Create: `agterm/Views/LogFollower.swift`, `agtermTests/LogFollowerTests.swift`
- Modify: `agterm/Views/HtmlOverlayRegistry.swift` (hook lines only), `agterm/Resources/markdown/text.js`,
  `agterm/Resources/markdown/text.css`
- Modify: `agterm/Control/ControlServer+TextPage.swift` (open path)
- Modify: `agtermTests/ImageProbeTests.swift`, `agtermTests/TextProbeTests.swift`, `agtermTests/TextPageRenderingTests.swift`,
  `agtermUITests/ControlHtmlOverlayUITests.swift`

- [x] `BoundedFile.readTail` and a `TextProbe` log check that refuses non-regular, offloaded and binary files and
      never refuses for size
- [x] build the initial log page from a tail snapshot; a missing file at open is refused like today; a control
      open with `--tail` or `--follow-file` is refused with `log page is not shown on another Mac` when
      `store.pageBelongsRemote(id, pane:)` is true
- [x] `LogFollower` per Technical Details: own generation, cache and anchor, tick gates, nil-snapshot state,
      theme reload and remount from the cache, an explicit reload from a fresh read, reports to `setTextLogState`
- [x] `text.js` log mode: bar, `agtermTextUpdate`, `agtermTextSetFollowing`, pin to bottom while following,
      `{following}` on user scroll transitions; the narrow handler for log pages only, writing the model
- [x] write tests: `ImageProbeTests` (`readTail` offset, `fromFileStart`, FIFO, dataless, symlink, stamp);
      `TextProbeTests` (over 4 MB accepted, binary refused); `LogFollowerTests` with `tick()` (append, truncate,
      rename and recreate, missing then reappearing, unreadable append, pause drops a read in flight, follow off
      before the first document still renders, unchanged stamp skips, a soft-closed page stops, close stops);
      `TextPageRenderingTests` (render, update, scroll-up pauses and Resume reloads, CLI off/on updates the bar,
      follow set before realization, theme reload keeps the paused snapshot and anchor, one-shot tail then append
      then explicit reload shows the new text with following still false, handler rejects other
      messages, non-log text page unchanged, presented-session refusal)
- [x] write targeted UI tests: open `--text --tail --follow-file`, append, read back `lines` and `following`;
      `overlay follow off` then `on`
- [x] run the targeted hosted and UI tests - must pass before task 4
      ⚠️ hosted classes pass (LogFollower 11, ControlServerTextPage 5, TextPageRendering 23, ImageProbe 12,
      TextProbe 9); the UI test compiles and runs in Task 5, since XCUITest needs Eugene's go-ahead
      ➕ the presented-session refusal lives in `ControlServer+TextPage.swift` (`textLogRefusal`) and its tests in
      a new `agtermTests/ControlServerTextPageTests.swift`: `ControlServerSessionActionsTests.swift` sits at the
      2000-line test limit

### Task 4: Click routing for .log and .out

**Files:**
- Modify: `agtermCore/Sources/agtermCore/LinkPolicy.swift`, `agterm/Control/ControlServer+TextPage.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/LinkPolicyTests.swift`, `agtermTests/ControlServerLinkOverlayTests.swift`

- [x] a plain click on a `TextPage.isLog` path opens log mode with `defaultTail` and follow on, unless
      `store.pageBelongsRemote(id, pane: nil)`, which keeps today's static page; a `:line` click keeps the static
      page; every other text file is unchanged
- [x] a log larger than `TextPage.maxBytes` opens in log mode instead of being revealed
- [x] write `LinkPolicyTests` cases for `.log`, `.out`, `.log:42`, `.txt`
- [x] write `ControlServerLinkOverlayTests` cases: log click opens log mode, `:line` static, large log opens,
      presented-session click opens the static page
- [x] run targeted tests - must pass before task 5

### Task 5: Verify acceptance criteria
- [x] verify every Overview requirement, including the 2 MB byte cap and the waiting state
- [x] `make build`, `cd agtermCore && swift test`, `make test-app`, `make lint`, each once
      ⚠️ lint first failed on cyclomatic complexity in `Open.validate()` and `overlayContent`; the new checks moved into
      `validateLog()` and `textOnlyRefusal(_:)`; hosted gate 1772 tests, 2 skipped, 0 failures
      ⚠️ the UI test's first run never brought the app to the foreground and hung in teardown; tccd logged
      `IDENTITY_ATTRIBUTION` for a stale `agterm-session-host` (CLAUDE.md's known case); the capped retry passed in 10 s
- [x] `lsappinfo list | grep -A4 agterm.debug` after the hosted and UI runs

### Task 6: [Final] Update documentation
- [x] `site/docs.html` local-path paragraph: log mode, follow, pause, tail limit
- [x] `site/commands.html`: `--tail`, `--follow-file`, `overlay follow`, the new read-back fields
- [x] `plugins/agterm/skills/agterm/` SKILL.md trigger and section pointer, reference.md entry
- [x] `.claude/rules/control-api.md` text page bullet and catalog entry for `session.overlay.follow`
- [x] move this plan to `docs/plans/completed/`

### ➕ Task 7: Search on text and log pages

Added on Eugene's request after the first review round. Decisions he made: the search field lives in the page's
own bar, on its right side; every text page gets the bar (a static page shows search only, a log page the follow
controls on the left and search on the right); a jump to the next or previous match pauses following, while typing
a query does not; the control API gets its own command, separate from `session.search`, which searches a terminal.
Every page control has a key (less-style letters, plus ⌘F); follow stays a page key, not a keymap action, and the
page adds no other chords. An open page already takes keyboard focus when it becomes the active layer.

**Matching and highlight:**
- case-insensitive plain text, found in the code element's whole `textContent`, so a query crossing highlight.js
  spans (`main()` over `<span>main</span>()`) matches; never the gutter, the bar or the field
- matches do not overlap and run left to right; next and previous wrap; no matches shows `0 of 0` and current 0
- every match is counted as an offset in one typed array, so navigation reaches all of them; painting uses the CSS
  Custom Highlight API (`CSS.highlights` with `Range`s mapped from offsets to text nodes), which changes no DOM and
  leaves the highlight.js markup alone; at most 5,000 ranges are painted, a window around the current match that
  moves with it, the current one in a second highlight
- WebKit before macOS 14.2 has no `CSS.highlights`: there the counter and jumps work and nothing is painted

**Keys** (page has focus; letters act only outside the field):
- `/` or ⌘F focuses the field; Enter / Shift-Enter in it and `n` / `N` step next / previous; Escape clears the
  query and leaves the field
- log page only: `F` toggles follow, `G` or End goes to the bottom and follows, `g` or Home goes to the top and pauses
- one rule for ⌘F: what is on top owns it, and the terminal behind a cover never opens or closes its search;
  `AppActions.coverTakesSearch` runs before the close branch, whatever holds first responder: the quick terminal
  holding the keys, or `Session.visibleCover` (any shown page or program overlay over the focused pane, full or
  floating); a text page focuses its field, every other cover does nothing; with no cover, ⌘F is terminal search
  as today (Eugene widened this from text pages to every cover; the floating exemption dated from #113 and kept
  the bar visible without asking which layer owns the keys)

**Follow interaction:**
- a jump (key, button or control) pauses first, posts the pause, then moves through `scrollTo`, which records the
  new position, so the scroll handler sees no user move and cannot resume follow even when the match is at the
  bottom
- typing re-runs the search and never pauses: on a page that is not following the current match becomes the first
  one at or below the view's top and is scrolled to; on a following page it becomes the last match and nothing moves
- the current match is anchored as (line index, occurrence within the line); a log update carries `dropped`, the
  lines evicted from the front since the page's last text, and `replaced` when the file was truncated or rotated;
  the page shifts the anchor by `dropped`, and resets it (as typing would) when the line was evicted, no longer has
  that occurrence, or the file was replaced; `dropped` comes from a new `LogTail.Snapshot.startOffset` (the file
  offset of the first kept byte) compared with the previous one on the same file, counting newlines in the cached
  text, so nothing is read beyond the tail; a new start inside an old line (a clipped first line whose window
  advanced) also sets `cut`, and an anchor on that cut line resets, since its earlier occurrences are gone
- `startOffset` needs the read offset: `BoundedFile.readTail` returns the offset its window starts at,
  `TextProbe.loadLog` passes it to `LogTail.snapshot`, which adds only the bytes it drops at the front; trimming an
  unfinished UTF-8 tail never moves it

**Control API and page plumbing:**
- `session.overlay.search TEXT | --to next|prev | --close [--pane left|right]`: exactly one of the three; refused
  `no text page` for any other occupant, a replica page included, and `remote page` for a text page that belongs
  to a presenter (`pageBelongsRemote`), since presentation state carries no search
- the model holds `HtmlOverlay.textSearch {query, revision, matches, current}`; setting or closing the query bumps
  `revision` and clears the counts; the page reports `{revision, matches, current}` and the host-free setter drops a
  report whose revision is not the model's, so an old report never overwrites a new query
- a query set before the page exists runs when it loads; a rebuild (theme, ready) re-applies query and current
  without scrolling or pausing; `--to` is a one-shot push to the realized page, refused `page not loaded` before it
  exists, so a jump runs exactly once and never replays on a rebuild; the push carries the model's query and
  revision, and a page holding an older revision applies it before it moves
- the page side moves into a shared `TextPageBridge` for every local text page, static or log: the message handler
  (`ready`, scroll, search reports), the pending-document gate and the JS pushes; `LogFollower` keeps the file
  reading and uses the bridge; the registry's log hook lines become bridge hook lines, so its length stays the same
- a replica text page on the viewer gets the field and keys from `text.js`, with nothing reported or read back
- read back `htmlOverlays[].text.search {query, matches, current}`, omitted with no query
- CLI `agtermctl session overlay search TEXT | --next | --prev | --close [--pane]`

**Files:**
- Modify: `agtermCore/Sources/agtermCore/HtmlOverlay.swift`, `AppStore+HtmlOverlay.swift`, `ControlProtocol.swift`,
  `ControlDispatcher+Overlay.swift`, `ControlDispatcher.swift`, `ControlProjection.swift`, `ControlActions*.swift`,
  `LogTail.swift`, `TextPage.swift`
- Create: `agtermCore/Sources/agtermctlKit/Session+OverlaySearch.swift`, `agterm/Views/TextPageBridge.swift`
- Modify: `agterm/Views/LogFollower.swift`, `agterm/Views/TextProbe.swift`, `agterm/Views/ImageProbe.swift`
  (`BoundedFile.readTail` offset), `agterm/Views/HtmlOverlayRegistry.swift` (hook lines only),
  `agterm/Resources/markdown/text.js`, `text.css`, `agterm/AppActions.swift` (⌘F),
  `agterm/Control/ControlServer+TextPage.swift`, `agterm/Control/ControlServer.swift`
- Tests: `LogTailTests`, `TextPageTests`, `HtmlOverlayTests`, `ControlProtocolTests`, `ControlDispatcherOverlayTests`,
  `OverlayCommandsTests`, `TextPageRenderingTests`, `LogFollowerTests`, `ControlServerTextPageTests`, one targeted
  UI test for ⌘F and the page keys

- [x] `LogTail.Snapshot.startOffset`; model, revisioned report setter, protocol, dispatcher refusals, projection, CLI
- [x] `TextPageBridge` for static and log pages; `LogFollower` moved onto it; `dropped` / `replaced` on updates
- [x] `text.js`: bar on every text page, field on the right, whole-text matching, highlight window, counter, wrap
- [x] page keys, jump-pauses-first, typing rules, anchor shift and reset
- [x] ⌘F routing in `toggleSearch` ahead of the terminal-search branch
- [x] host-free tests: validation and refusals (`remote page`, replica, other occupants), stale-revision report
      dropped, read-back and nil omission, `startOffset` across eviction, a clipped first line and a trimmed UTF-8
      tail
- [x] WebKit tests: a cross-token match, overlapping and wrapping, a hostile query staying text, clear leaving the
      highlight.js markup intact, the paint window past 5,000, Next to the last line staying paused after its scroll
      event, typing during a following append keeping focus and follow, an evicting append shifting the anchor,
      repeated lines and several matches on one line, the selected line evicted, a replaced file, a clipped first
      line whose window advanced, a rebuild keeping query and current, `--to` before load refused, a query change
      followed at once by `--to next` stepping through the new query, every page key
- [x] hosted tests for `coverTakesSearch`: floating text, markdown and program covers take ⌘F; no cover, a hidden
      page and a pane page on the other pane do not (a HUD is excluded by `visibleCover` itself)
- [x] UI test: ⌘F over a floating text page focuses the page's field and leaves an open terminal search alone; over
      a pane page on the other pane of a split it opens the focused pane's terminal search
      ⚠️ written; two runs stopped at launch with the app stuck `Running Background` while the screen was locked
      (`IOConsoleLocked` true); both passed after unlock (12.9 s and 8.7 s)
- [x] ➕ look set by Eugene in a Debug instance: the find box matches `TerminalSearchBar` (magnifier, 120pt field, fixed
      76pt counter slot in its wording, chevrons, an X disabled with no query, aligned with the strip's close button),
      and the terminal bar takes the same fixed counter slot and field width; the bar never wraps, and the "last N
      lines" note is gone
- [x] run the targeted tests - must pass before task 8

### ➕ Task 8: Verify and document search
- [x] `make build`, `cd agtermCore && swift test`, `make test-app`, `make lint`, each once
- [x] `site/docs.html`, `site/commands.html`, the skill and `.claude/rules/control-api.md` for page search
- [x] ➕ revmux round 02 over the branch: 4/4 sources, 5 minor findings and none gating; all fixed (typed and control
      query reconciliation, CR line breaks, requested-tail check, refusal wording), so no further round

## Post-Completion
**Manual verification**:
- a log rotated by `newsyslog` (rename and recreate) and one truncated by copytruncate keep following
- a multi-GB log opens at once and the CPU stays idle while paused or unchanged
- scroll up during a fast writer, confirm the view stays still, then Resume

Smells pre-check: skipped — non-Go project
