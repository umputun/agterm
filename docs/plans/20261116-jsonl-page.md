# JSON Lines page with Expand

## Overview

- A ⌘-click on a `.jsonl` or `.ndjson` file opens it over its session as a text page, the way `.log` and `.json`
  files open today. Today it falls through to "reveal in Finder" (`TextPage.swift` lists neither extension).
- The page shows the file as written: one line per record, highlighted with the JSON grammar.
- A per-page **Expand** toggle lays each record out over indented rows, numbered by file line. It mirrors Wrap:
  a page-bar button, the `e` key, `session overlay expand on|off|toggle`, an `expand` read-back field, and forwarding
  from and to an attached Mac. The choice lasts until the page closes.
- No new link scheme and no handler runs: the page uses the existing inert text-page path (escaped text,
  `default-src 'none'`, no bridge, bounded reads). The `agterm://custom/...` handler idea was declined for safety.

## Context (from discovery)

- Text page model and HTML: `agtermCore/Sources/agtermCore/TextPage.swift` (`languages`, `isEligible`, `html()`,
  `maxBytes` 4 MB, `maxHighlightBytes` 256 KB).
- Formatter from the first iteration, uncommitted in this worktree:
  `agtermCore/Sources/agtermCore/JSONLines.swift` and `agtermCore/Tests/agtermCoreTests/JSONLinesTests.swift`.
  `TextPage.html` and `text.js` also carry first-iteration edits that this plan reshapes (see the table below).
- Renderer: `agterm/Resources/markdown/text.js` (gutter, `rowStart`/`measureRows`, `startWrap`, search, keys).
- Page bridge: `agterm/Views/TextPageBridge.swift` (`documentPending`, `rendererReady`, `pushWrap`, `wrapped`).
- Wrap's full path, which Expand mirrors: `HtmlOverlay.textWrap`, `AppStore+HtmlOverlay.swift` (`setTextWrap`,
  `TextWrapFailure`, read-back at ~438), `ControlProtocol` `.sessionOverlayWrap`, `ControlDispatcher+Overlay`,
  `ControlActions`/`ControlActionsDefaults`, `HtmlBridge` allowed list, `agtermctlKit/Session+OverlayWrap.swift`,
  `agterm/Control/ControlServer+TextPage.swift`, `AgtermServerKit/ServerActions+Overlay.swift`,
  `ServerCommandPolicy.swift`.
- Remote text pages: `AppStore+RemoteTextPage.swift` (`TextPageAction`, `remoteTextAction` capability gate),
  `PresentationFrames.swift` (`PresentationTextState`, `PresentationPageCommand`), `PresentationHub.swift`
  (`pageFilesKind` is the model for a new negotiated kind), `AppStore+ReplicaPage.swift` (`seeded`, `textState`),
  `HtmlOverlay.mirror`.
- Docs: `site/docs.html` (local files table, text pages), `site/commands.html`,
  `plugins/agterm/skills/agterm/SKILL.md` and `reference.md`, `.claude/rules/control-api.md` (~959).

## Development Approach

- **testing approach**: Regular (code first, then tests in the same task)
- complete each task fully before moving to the next
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
- **CRITICAL: all tests must pass before starting next task**
- **CRITICAL: update this plan file when scope changes during implementation**
- while working, run only the tests a change touches (`swift test --filter`, `-only-testing:`); the full gates run
  once in the last task
- maintain backward compatibility with older presenters and origins

## Testing Strategy

- **host-free**: Swift Testing in `agtermCore/Tests` for the formatter, `TextPage.html`, store, dispatcher, CLI,
  remote action, text state and server actions.
- **hosted**: XCTest in `agtermTests` (`TextPageRenderingTests`, `ControlServerTextPageTests`,
  `ControlServerRemotePageTests`) for the renderer and bridge.
- No XCUITest: the page bar and keys are covered by hosted rendering tests, as Wrap is.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix

## Solution Overview

- **Formatting stays in Swift** (`JSONLines.format`), so the highlight limit and output budget have one owner and
  the logic is host-free tested. The renderer only maps file lines to rows.
- **Expand rebuilds the document.** Toggling it rebuilds the page from the bridge's cached raw text through
  `TextPage.html(..., expand:)`, reopening at the file line that was under the bar. No live text push: Wrap changes
  CSS, Expand replaces the whole text, and one document path keeps highlighting, search and gutter consistent.
- **Eligibility is a marker, not the language.** Every static JSON Lines page carries `data-jsonl`, independent of
  the 256 KB highlight limit and of Expand, so the button and key know the page can expand.
- **Log pages stay raw.** A `.jsonl` opened with `--tail`/`--follow-file` is a log page whose follow shift and search
  restore count file lines; `session.overlay.expand` refuses it, and the page shows no Expand button.
- **Remote** gets a new negotiated kind `page.expand`. A presenter that does not list it is never sent the action;
  `PresentationTextState.expand` is `Bool?` so an older peer's frames still decode.

## Technical Details

- `TextPage.languages`: `jsonl`/`ndjson` map to `jsonl` (read-back `language: "jsonl"`).
- `TextPage.html(..., expand: Bool = false)` for a static page (`log == nil`) whose language is `jsonl`:
  - always: `data-jsonl`, and `data-language="json"` when the shown text is within `maxHighlightBytes`;
  - expand off: the raw text;
  - expand on: `JSONLines.format(text, budget: maxBytes)`; the formatted text is measured for highlighting;
    `data-records="0,3,9,...,N"` (each file line's first shown line, then the shown line count) and `data-expand`.
  - a log page stays raw (no marker, no records) and highlights as `json`, see the last bullet.
  - `top`: the file line to reopen under the bar after a rebuild, `data-top="<line>"`, from 0.
- `JSONLines.format` (kept from the first iteration): validates each line with `JSONSerialization`, rejects a
  trailing comma it accepts, reindents from the original tokens (key order, duplicate keys, escapes, number literals
  kept), keeps invalid and empty lines raw as their own numbered slot, treats CR and CRLF as line ends, and checks the
  output against a budget that reserves room for the raw lines still to come while it emits.
- `text.js`:
  - `records` from `data-records`; `slotCount`/`slotStart` serve the gutter and the `:N` band; `rowStart`,
    `measureRows` and `startWrap` stay in shown-line coordinates.
  - with `data-jsonl`: an `Expand: on/off` button styled and placed like Wrap and the `e` key, both posting
    `{ expand }`. The existing `keys` guard (`text.js:1114`) already leaves `e` to the search field.
  - `agtermTextNavigation()` (`text.js:1141`) also returns `line`, the file line under the bar, found from
    `slotStart`.
  - `data-top` scrolls that file line under the bar, applied after the `:N` band's `scrollIntoView`; a page built
    with `data-top` carries no `data-anchor`.
- `HtmlOverlay.textExpand: Bool` (`public internal(set)`), `AppStore.setTextExpand(_ id:, expanded:)` and
  `setTextExpand(_ sessionID:, pane:, mode:) -> Result<Bool, TextExpandFailure>` with `.page`, `.notJSONLines`
  (`no JSON Lines page`), `.log` (`log page: expand works on a static page`), `.remote`. The JSON Lines check
  matches `.replica(path, .text)` as well as `.text(path, _)`, as `textChangesPage` does
  (`AppStore+HtmlOverlay.swift:329-331`), or every expand on a presenter is refused.
- Read-back: `ControlTextOverlayNode.expand: Bool?`, true or nil as `wrap` is.
- `TextPageBridge`: `expand` beside `wrap`. A change from the model or the page rebuilds through the existing
  non-fresh `loadDocument`, which already reads `agtermTextNavigation()`; when expand changed it passes `top` from
  `line` and no pixel `anchor`, since the pixel offset belongs to the other layout. A change that lands while
  `documentPending` is replayed from `rendererReady` against what the loaded document holds. A rebuild keeps the
  search query (existing `SearchState`); matches are recounted on the new text.
- Remote: `TextPageAction.expand(ControlToggleMode)`, `PresentationPageAction.expand` with `answersWithResult` true
  (`PresentationFrames.swift:449`), `PresentationHub.pageExpandKind = "page.expand"` in `supportedKinds`, gated in
  `remoteTextAction` like `.files`. `PresentationTextState.expand: Bool?`, where nil means false in `mirror` and
  `seeded`: an older presenter drops the key and shows the page raw, so the origin must read it back as off.
  Carried through `seeded`, `textState` (which also seeds a page move, `AppStore+PageMove.swift:55`) and both sides
  of `mirror`'s before/after comparison, so a remote toggle still posts `tree.changed`.
- Log pages and diff hunks: one `TextPage` mapping turns `jsonl` into the `json` grammar, used by `html()` for a log
  page, by a diff's `data-files`, and by `LogFollower.push()` (`LogFollower.swift:195`), which looks the language up
  again for every update; otherwise a following `.jsonl` loses its highlighting on the first appended record.
  Read-back still reports `jsonl`.

## Decisions carried from the draft

The first iteration (uncommitted in this worktree) laid every record out by default.

| Decision | Status | Reason |
| --- | --- | --- |
| Formatter in Swift (`JSONLines`), not in `text.js` | kept | one owner for highlight limit and budget; host-free tests |
| Reindent from original tokens; JSONSerialization only validates | kept | keeps key order, duplicates, int64 and number literals |
| Reject a trailing comma JSONSerialization accepts | kept | `[1,]` is not JSON |
| Budget reserves room for the raw lines after | kept | output stays within `maxBytes` |
| Each record tries its own allowance after an earlier one did not fit | kept | still bounded; shows more laid out |
| Records laid out by default | changed | Eugene: show the file as written; layout is the Expand toggle |
| Formatting gated on `data-language` | changed | `data-jsonl` marker, size-independent |
| `data-records` gutter and `:N` band in file lines; wrap anchor in shown lines | kept | codex review |
| Static page only; log pages raw | kept | follow shift and search restore count file lines |
| Log page of a `.jsonl` unhighlighted (unknown `jsonl` grammar) | changed | emitted as `json`, plan review |
| 4 MB whole-file cap, no tail mode | kept | tail would change what `:N` means |
| Live text push on toggle | dropped | rebuild reuses one document path |

## What Goes Where

- **Implementation Steps**: code, tests and docs in this repo.
- **Post-Completion**: manual checks with a real agent transcript and an attached Mac.

## Implementation Steps

### Task 1: Text page HTML for JSON Lines, with and without Expand

**Files:**
- Modify: `agtermCore/Sources/agtermCore/TextPage.swift`
- Modify: `agtermCore/Sources/agtermCore/JSONLines.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/TextPageTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/JSONLinesTests.swift`
- Modify: `agterm/Views/LogFollower.swift`, `agtermTests/TextPageRenderingTests.swift`

- [x] `html()` takes `expand` and `top`; a static `jsonl` page always carries `data-jsonl`, raw text by default,
      formatted text plus `data-records` and `data-expand` when expanded, highlighting measured on the shown text
- [x] one `TextPage` grammar mapping (`jsonl` to `json`) used by `html()` for log pages and diff `data-files`, and
      by `LogFollower.push()` under the existing size limit; a log page stays raw with no `data-jsonl`
- [x] keep `JSONLines` as is; adjust only what the new call shape needs
- [x] tests: default raw page (marker, json language, no records), expanded page (records, expand, escaping),
      expanded page over the highlight limit keeps records and drops the language, raw page over the limit keeps
      the marker, log page raw and `json`, diff `data-files` maps `.jsonl` to `json`, `top` replaces `anchor`
- [x] hosted test in `TextPageRenderingTests` (`LogFollowerTests` has no web view): a following `.jsonl` page appends a record and keeps `json` highlighting,
      with no Expand available
- [x] run `swift test --filter 'JSONLinesTests|TextPageTests'` and the hosted case with
      `-only-testing:` - must pass before next task; then `lsappinfo list | grep -A4 agterm.debug`

### Task 2: Expand through the model and the control path, local and remote

One task because the app adapter routes through `TextPageAction`, whose new case reaches the presentation frames
and every exhaustive switch over them; no half of it builds alone.

**Files:**
- Modify: `agtermCore/Sources/agtermCore/HtmlOverlay.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+HtmlOverlay.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlProjection+Text.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher+Overlay.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlActions.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlActionsDefaults.swift`
- Modify: `agtermCore/Sources/agtermCore/HtmlBridge.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+RemoteTextPage.swift`
- Modify: `agtermCore/Sources/agtermCore/PresentationFrames.swift`
- Modify: `agtermCore/Sources/agtermCore/PresentationHub.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+ReplicaPage.swift`
- Modify: `agtermCore/Sources/AgtermServerKit/ServerActions+Overlay.swift`
- Modify: `agtermCore/Sources/AgtermServerKit/ServerCommandPolicy.swift`
- Create: `agtermCore/Sources/agtermctlKit/Session+OverlayExpand.swift`
- Modify: `agtermCore/Sources/agtermctlKit/SessionCommands.swift` (registration beside `Session+OverlayWrap`, :608)
- Modify: `agterm/Control/ControlServer+TextPage.swift`, `agterm/Control/ControlServer+RemotePage.swift`,
  `agterm/Control/ControlServer.swift`
- Modify tests: `HtmlOverlayTests`, `HtmlBridgeTests`, `ControlDispatcherOverlayTests`, `ControlProtocolTests`,
  `MockControlActions`, `OverlayCommandsTests`, `PresentationFramesTests`, `PresentationHubTests`,
  `AppStoreRemotePageTests`, `AppStoreReplicaPageTests`, `AppStorePageMoveTests`, `ServerActionsOverlayTests`,
  `ServerActionsSessionsTests`, `ServerCommandPolicyTests`, `ServerStreamsTests`,
  `agtermTests/ControlServerTextPageTests`, `agtermTests/ControlServerRemotePageTests`

- [ ] `HtmlOverlay.textExpand`; `AppStore.setTextExpand` (page id form and slot form) with `TextExpandFailure`
      refusing non-text, non-JSON-Lines, log and remote pages; the JSON Lines check matches `.text` and `.replica`
- [ ] read-back `expand` on `ControlTextOverlayNode`
- [ ] `session.overlay.expand` through protocol, dispatcher, actions, defaults, `HtmlBridge` allowed list, the app's
      `setSessionOverlayExpand` via `textPageAction(.expand)`, and
      `agtermctl session overlay expand on|off|toggle [--pane] [--target] [--window]`
- [ ] remote: `TextPageAction.expand`, `PresentationPageAction.expand` answering with a result, the
      `runTextPageAction` and `applyReplicaPageCommand` switches, `pageExpandKind` advertised and gated in
      `remoteTextAction`; `PresentationTextState.expand: Bool?` with nil as false through `seeded`, `textState` and
      `mirror`'s comparison; server actions and command policy as for wrap
- [ ] tests, host-free: store set/toggle and each refusal including a replica page that is accepted; read-back
      true/nil; protocol round-trip; dispatcher mode parsing; `HtmlBridge` own-overlay list; CLI argument mapping;
      `expand` frame action decodes and answers with a result; `supportedKinds` lists `page.expand`; a presenter
      without it is never sent the action; text state with and without the key decodes; a report without the key
      clears the origin's `expand`; a mirrored change reports a change; a page move seeds `expand`; server forwards
      end to end and refuses page rows as for wrap
- [ ] tests, hosted: the app adapter against a real text page; a replica page command applies expand
- [ ] run the touched suites (`swift test --filter`, `-only-testing:`) - must pass before next task
- [ ] after the hosted run, `lsappinfo list | grep -A4 agterm.debug`

### Task 3: Renderer and bridge: Expand button, rebuild and anchor

**Files:**
- Modify: `agterm/Resources/markdown/text.js`
- Modify: `agterm/Views/TextPageBridge.swift`
- Modify tests: `agtermTests/TextPageRenderingTests.swift`, `agtermTests/ControlServerTextPageTests.swift`

- [ ] `text.js`: Expand button beside Wrap and the `e` key on `data-jsonl` pages, posting `{ expand }`;
      `agtermTextNavigation()` returns `line`; `data-top` applied after the `:N` band; the `records` gutter and
      `:N` band mapping from the first iteration
- [ ] bridge: `expand` state; a change rebuilds through the non-fresh `loadDocument`, passing `top` from `line` and
      no `anchor` when expand changed; replay while `documentPending`; search query kept, and the search field's
      focus and selection restored by the shared non-fresh rebuild, so a theme change keeps them too (Eugene's call)
- [ ] stop the first-iteration demo instance (the pid whose environment holds `AGTERM_STATE_DIR=/tmp/agj`, SIGTERM,
      then the `lsappinfo` Dock-tile check) before rebuilding; build the demo with
      `-derivedDataPath build/DemoDerivedData`, never the `build/DerivedData` that `scripts/test-app.sh` rebuilds,
      launch it isolated and show Eugene the page with Expand off and on before writing the hosted tests
- [ ] hosted tests: default page shows raw lines with gutter 1..N; Expand from the page and from control lays
      records out with file-line numbers; the line under the bar stays there across the toggle; a toggle during
      load lands; `:N` band covers the whole record; wrap on an expanded page keeps its anchor; typing into search,
      expanding through control, then typing again continues the query at the same caret; the same after a theme
      change; `e` typed into search lands in the query (regression test for the existing guard)
- [ ] run the touched hosted tests with `-only-testing:` - must pass before next task
- [ ] after the hosted run, `lsappinfo list | grep -A4 agterm.debug`

### Task 4: Docs, skill, and the gates

**Files:**
- Modify: `site/docs.html`, `site/commands.html`
- Modify: `plugins/agterm/skills/agterm/SKILL.md`, `plugins/agterm/skills/agterm/reference.md`
- Modify: `.claude/rules/control-api.md`

- [ ] `site/docs.html`: `.jsonl`, `.ndjson` row in the local files table; the Expand toggle in the text page
      section beside Wrap; the 4 MB limit applies
- [ ] `site/commands.html`: `session overlay expand` entry and the `expand` read-back field
- [ ] skill: the command in SKILL.md beside wrap, reference.md entry
- [ ] `control-api.md`: Expand beside the wrap line, the `page.expand` kind, log pages refused
- [ ] verify every Overview point; run `cd agtermCore && swift test`, `make test-app`, `make lint` once each
- [ ] check `lsappinfo list | grep -A4 agterm.debug` after the hosted run
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification**:
- open a real Claude Code transcript (`~/.claude/projects/.../*.jsonl`) under 4 MB, toggle Expand with search open
- a `.jsonl` in a pane attached from another Mac, toggled from either side
- a `.jsonl` opened with `--follow-file` shows raw and has no Expand button

Smells pre-check: skipped — non-Go project
