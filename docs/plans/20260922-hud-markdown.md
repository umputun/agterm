# HUD markdown mode and font size

## Overview
- Add an opt-in `--markdown` mode to `session.hud.open` and `session.hud.update`, so a controller agent can
  keep a small status panel over its session instead of printing the summary into its own chat.
- Markdown mode renders standard markdown (CommonMark plus the GFM tables Foundation parses). Valid input
  is the caller's responsibility; the renderer adds no dialect of its own.
- Add `--font-size POINTS` to `hud open` in both modes: the panel's own font size, independent of the
  session's. Named `--font-size` because `--size-percent` already sets the panel's width.
- Without either flag, the HUD behaves exactly as today: 256-character cap, per-line centering, rejected
  newlines, blank-line-as-detail-separator, session font. The plain body file stays byte-identical except
  for one new header field the painter needs to tell the modes apart.
- A HUD stays a glance panel: one per session, replaced by the next HUD, discarded by a program overlay.
  None of those slot rules change.

## Context (from discovery)
- `agtermCore/Sources/agtermCore/Hud.swift`: `HudSpec` (Codable, `decodeIfPresent` for optional fields),
  `HudLayout.box`, `renderedBody`, `bodyLines`, `wrap`, `cellCount`, `textLength`; `maxColumns` 60,
  `horizontalPadding` 2, `verticalPadding` 1, `spinnerWidth` 2.
- `agtermCore/Sources/agtermCore/ControlDispatcher+Hud.swift`: `parseHudSpec` rejects control characters
  (newline included) via the shared `containsControlCharacters`, which pick and ask also use.
- `agterm/Resources/hud/hud.sh`: header `<cols> <rows> <spinner> <pid> <interval> <textcolor> [frame...]`,
  centers each line with `${#line}`, a blank line switches later lines to dim, frames are shifted off after
  six fixed fields; WINCH only drops the cached frame and re-reads the same grid.
- `agterm/Control/ControlServer+Hud.swift`: open/update measure `paneMetrics` from the INCOMING spec before
  `AppStore.updateHud` runs; `writeHudBody` is called from open, update and `overlay.resize`
  (`ControlServer+SessionActions.swift`) only.
- `agterm/Views/WindowContentView+Detail.swift`: a window or divider resize changes the panel frame and
  updates the pane-frame cache, but never rewrites the body, so the header grid goes stale.
- `agterm/agtermApp.swift` overlay factory: creates the HUD surface with `session.fontSize`, under an
  `isHud` predicate; `GhosttySurfaceView` applies `initialFontSize` to `config.font_size`.
- `agterm/Control/ControlServer+RemotePresentation.swift`: rebuilds `HudSpec` field by field for a
  mirrored HUD. `AppStore.swift` builds `ControlHudNode`; CLI, protocol and tree carry separate fields, not
  the whole spec. `PresentationHud` carries the whole `HudSpec`; `maxFrameBytes` 256 KiB.
- Parser probes (Swift scripts in /tmp, 2026-09-22), `AttributedString(markdown:)` with `.full` syntax:
  - blocks through `presentationIntent`: header level, paragraph, nested unordered/ordered lists with item
    ordinals, code block, block quote, thematic break, GFM table with header row and cells.
  - inline through `inlinePresentationIntent`: strong, emphasized, code, strikethrough, `softBreak`,
    `lineBreak`, inline HTML (256), block HTML (512); an image yields its alt text with `imageURL`.
  - `- a\n- b` and `- a\n\n- b` parse identically: tight and loose lists cannot be told apart.
  - `# **x** y` yields a strong run and a plain run under one header identity.
  - entities are decoded, so `&#27;` becomes a raw ESC.
- Tests: `HudTests`, `HudHelperTests` (drives hud.sh), `ControlDispatcherHudTests`, `AppStoreHudTests`,
  `CommandsTests`, `ControlProtocolTests`, `SnapshotRoundTripTests`, `RemotePresentation*Tests`,
  `ControlServerRemotePresentationTests`, `ControlServerSessionActionsTests`.

## Development Approach
- **testing approach**: Regular (code first, then tests in the same task)
- complete each task fully before moving to the next; small, focused changes
- every task includes new or updated tests; each task runs only its own new and changed tests
  (`swift test --filter` for core, `-only-testing:` for hosted); the full gates run once, in Task 11
- plain-mode behavior is pinned by existing tests, which must keep passing unmodified except where the
  header gains its new field
- update this plan when scope changes during implementation

## Testing Strategy
- unit tests in `agtermCore` for the renderer, dispatcher, CLI, protocol, projection and store
- `HudHelperTests` for the painter's literal mode, including mode switches inside one running helper
- hosted tests for the factory font input, measurement, geometry refresh and the remote bridge

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix, blockers with ⚠️ prefix

## Solution Overview
- `HudSpec.markdown: Bool` and `HudSpec.fontSize: Double?` (both decoded with `decodeIfPresent`) carry the
  new options. The protocol, CLI and `tree` get their own fields; the remote bridge copies both.
- Foundation's `AttributedString(markdown:)` with `.full` syntax parses the message. A host-free renderer
  in `agtermCore` walks its runs by block identity and turns them into finished rows: styled with generated
  SGR, wrapped at 60 columns, clipped to the panel's current grid on both axes. The painter prints those
  rows verbatim and never measures or interprets them.
- Markdown semantics are the parser's: a single newline inside a paragraph is a soft break and renders as
  a space; a hard break (two trailing spaces or a backslash) starts a new row; blocks are separated by one
  blank row.
- Every change to the panel's real geometry rewrites the body, so clipping always matches the grid the
  panel paints in. This also fixes plain mode's stale centering after a resize.

## Technical Details

**Block rendering**:
- paragraph: its inline runs, wrapped.
- heading (any level): bold, wrapped like any other row.
- unordered list: `•` marker; ordered list: `<ordinal>.` from the parser's ordinal. Continuation rows hang
  under the item text; each nesting level indents by 2 cells. Lists always render tight (no blank row
  between items), because the parser does not expose tight versus loose.
- code block: its lines verbatim (no inline styling), indented by 2 cells, tabs expanded to 4-column tab
  stops; wrapped like any row.
- block quote: rows prefixed with `│ `.
- thematic break: a row of `─` across the content width.
- table: cells padded to the widest cell in their column and joined with ` │ `; header row bold. A table
  wider than the content width is clipped like any other row. Cells and rows are placed by the parser's
  column and row index; trailing all-empty body rows and an all-empty header are not rendered, because
  the parser emits nothing for them.
- image: its alt text. Raw HTML, inline or block: its source text, literal.
- blocks are separated by one blank row; a nested block inherits its container's indent and prefix.

**Inline rendering**:
- strong → bold, emphasized → italic, strikethrough → strikethrough; inline code and link text render as
  plain text (a link shows its label only).
- each run's style is the UNION of its block style (heading, table header) and its inline styles, so
  `# **x** y` keeps `y` bold.
- `softBreak` → space, `lineBreak` → new row.

**Terminal safety** (not markdown rules; they keep the painter's output inside the panel):
- dispatcher, markdown mode: LF and TAB allowed in the message, every other control character (CR, ESC,
  DEL…) rejected; cap `HudSpec.maxMarkdownLength` = 4096 in `textLength`'s unit; non-empty after trimming
  whitespace and newlines. The shared `containsControlCharacters` stays untouched.
- after break intents are mapped and code-block text is split into lines, any control character left in a
  run's text (decoded from an entity such as `&#27;` or `&#10;`) is replaced with U+FFFD.
- detail: unchanged rules (no control characters, 256 cap), rendered as plain dimmed text below a blank row.

**Rows and styling**:
- The renderer yields rows as runs of `(text, style)`; wrapping works on the visible character stream
  across run boundaries (`pre**fix**suffix` stays one word), then SGR is generated per finished row from
  the resolved styles. Every row is self-contained: it opens the styles it carries and closes each with
  its own reset (22 bold/dim, 23 italic, 29 strikethrough), never SGR 0, so the panel's text color from
  the header survives. Styles reopen at the start of a wrapped row and are closed before a clip marker.
- dim appears only on detail rows and the overflow marker, which carry no bold, so 22 closing both is safe.
- Wrap width is fixed at 60 columns (`HudLayout.maxColumns`), so a resize never changes the logical rows.
- Spinner: the PAINTER still prepends the current animated glyph plus a space to the first row, as today;
  the RENDERER indents every later row by `spinnerWidth`. Rows are clipped to the column budget BEFORE that
  gutter is added (the budget already subtracts `spinnerWidth`), and `blockWidth` counts the gutter once.

**Clipping** (in `renderedBody`, from the current grid):
- content columns = `grid.columns - 2 * horizontalPadding - (spinner ? spinnerWidth : 0)`; a row wider than
  that is cut on visible cells and its last visible cell becomes `…`. Cutting never splits generated SGR.
- content rows = `grid.rows - 2 * verticalPadding`; when rows overflow, the last visible row is replaced
  by a dimmed `… N more`, where N counts every hidden row including the one the marker displaced. The
  marker row itself passes through column clipping.
- a budget of 0 columns or 0 rows paints nothing; 1 row shows only the marker when content overflows.
- `cellCount` stays a scalar count, so double-width glyphs can still overflow a row, as they do today.

**Body file**:
- header gains a seventh fixed field, `blockWidth`: `0` means plain mode (painter behaves exactly as
  today); markdown mode always writes at least 1. Its value is the final painted width of the widest row
  after clipping and marker insertion, spinner gutter included. In literal mode the painter prints each
  row verbatim at one shared left offset `(cols - blockWidth) / 2`, ignores the blank-line dim switch and
  does no per-line centering. Frames now shift off after seven fields. The painter resets the field on
  every tick, so an update can switch modes in a running helper.
- `HudLayout.box` uses the rendered (unclipped) rows for a markdown spec: widest row plus padding, row
  count plus padding; the existing percent clamps apply unchanged.

**Geometry refresh**:
- the view's panel-frame change (window resize, divider drag, first realization after an unmeasured open)
  asks `ControlServer` to rewrite the HUD body from fresh `paneMetrics`, coalesced to one write per
  main-queue turn. Plain mode benefits too: its centering follows the new grid.

**Font size**:
- `HudSpec.fontSize: Double?` is the caller's request; `ControlArgs.fontSize`; `--font-size POINTS` on
  `hud open` only. `hud update` does not take it, as it does not take `--color`, because the surface reads
  both once at creation. Accepted range `HudSpec.fontSizeRange` = 6...72, rejected outside it, with one
  predicate the CLI and the dispatcher share.
- On open, the app resolves the EFFECTIVE creation size (`spec.fontSize ?? session.fontSize ?? base`) into
  a local value and passes it explicitly to measurement. A successful `AppStore.openHud` stores that value as
  `Session.hudFontSize` AFTER `openOverlay` has torn down any HUD it replaces, because that teardown clears
  the field. A refused open leaves no `hudFontSize`; a failed body-file write clears it. Update and
  `overlay.resize` measure from the stored value, so a session zoom after open cannot change what the HUD
  is measured with.
- The overlay factory reads `session.hudFontSize` under its existing `isHud` predicate; program and pane
  overlays keep their current font path. `PaneOverlay` does not change.
- `AppStore.updateHud` holds the live `fontSize` request across an update, as it holds the background.
- `ControlHudNode.fontSize: Double?`: the request, omitted when the panel inherits the session's size.

**API surface**:
- `ControlArgs.markdown: Bool?`; `agtermctl session hud [open] --markdown` and `hud update --markdown`;
  an update without the flag goes back to plain mode (whole-spec replacement, as today).
- `--file PATH` on `hud open` (and the bare form) and `hud update`: `agtermctl` reads the message from the
  file, in either mode, instead of the positional argument; the two are mutually exclusive. One trailing
  newline is dropped, since files end with one and plain mode rejects newlines. The read is CLI-side, like
  `session type --stdin`, so the protocol and dispatcher see an ordinary message and every cap and
  rejection applies unchanged. An unreadable or non-UTF-8 file fails in the CLI before anything is sent.
- `ControlHudNode.markdown: Bool`, decoded as false when absent so older tree payloads still decode.
- Remote bridge: `ControlServer+RemotePresentation.swift` copies `markdown` and `fontSize`. An origin
  reopening with a different font already withdraws and republishes the HUD, so the replica is recreated at
  the new size. An older receiver ignores the unknown keys and shows the source as plain text.

## What Goes Where
- **Implementation Steps**: code, tests and docs in this repo.
- **Post-Completion**: manual Debug-instance check, run only when Eugene authorizes a launch.

## Implementation Steps

### Task 1: Add markdown and fontSize to HudSpec and the read-back

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Hud.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlProjection.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift` (`ControlHudNode` builder)
- Modify: `agtermCore/Tests/agtermCoreTests/HudTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/SnapshotRoundTripTests.swift`

- [x] add `markdown: Bool` and `fontSize: Double?` to `HudSpec` (init defaults, `decodeIfPresent`, coding
  keys) and carry both through `withBackgroundColor` and `withSizePercent`
- [x] add `HudSpec.maxMarkdownLength = 4096`, `HudSpec.fontSizeRange = 6...72` and its shared predicate
- [x] add `markdown` (absent decodes as false) and `fontSize` to `ControlHudNode` and its builder
- [x] write tests: spec decode without the keys, round trip with both set, copy methods keep both
- [x] write tests: read-back for both modes, font present and omitted, an older payload without the keys
- [x] run the new and changed tests

### Task 2: Markdown block renderer

**Files:**
- Create: `agtermCore/Sources/agtermCore/HudMarkdown.swift`
- Create: `agtermCore/Tests/agtermCoreTests/HudMarkdownTests.swift`

- [x] create `HudMarkdown` (internal enum, static functions) that parses with `.full` syntax, groups runs
  by block identity and emits unwrapped logical rows of `(text, style)` runs per the block rendering rules
- [x] resolve each run's style as the union of block and inline styles; map soft break to space and line
  break to a new row; split code blocks into lines and expand their tabs
- [x] replace control characters left in run text with U+FFFD, after the break and code-block mapping
- [x] write tests per block kind: paragraph with soft and hard breaks, headings 1–6 with nested strong,
  unordered and ordered lists (ordinal kept, `10.` width), nesting, `- a\n- b` and `- a\n\n- b` both tight,
  code block with a tab and blank lines, block quote, thematic break, table with a bold header and nested
  strong, image alt text, inline and block HTML literal
- [x] write tests for inline styles and safety: strong, emphasized, strikethrough, code, link label,
  `&#27;` and `&#10;` neutralized while a hard break and code-block newlines survive
- [x] run the new tests

### Task 3: Row wrapping, styling and clipping

**Files:**
- Modify: `agtermCore/Sources/agtermCore/HudMarkdown.swift`
- Modify: `agtermCore/Sources/agtermCore/Hud.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/HudMarkdownTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/HudTests.swift`

- [x] wrap logical rows at `maxColumns` over the visible stream across runs, with hanging indent for list
  items and quote prefixes, and spinner indentation for rows after the first
- [x] generate self-contained SGR per row from resolved styles, reopening after a wrap and closing before
  a clip marker; detail rows 2/22
- [x] clip columns and rows against the grid in `renderedBody` per the clipping rules, then compute
  `blockWidth` (spinner gutter included, at least 1) and write it as the seventh header field (0 for plain)
- [x] make `box(for:)` use the rendered rows for a markdown spec
- [x] write tests: wrap across a style boundary, hanging indent for `•` and `10.`, heading `# **x** y`
  stays bold after the inner span, column and row clipping with markers, omission count, marker column
  clip, grids with 0 and 1 usable rows and columns, spinner on, no SGR split by a cut, text color kept,
  `box` for markdown specs, plain-mode body unchanged apart from the new header field
- [x] run the new and changed tests

### Task 4: Painter literal mode

**Files:**
- Modify: `agterm/Resources/hud/hud.sh`
- Modify: `agtermCore/Tests/agtermCoreTests/HudHelperTests.swift`

- [x] parse the seventh header field, reset every tick; shift seven fields before frames
- [x] in literal mode print each row verbatim at the shared block offset, skip the blank-line dim switch
  and per-line centering; plain mode unchanged
- [x] update the header comment to describe the field
- [x] write tests: literal rows verbatim with leading spaces kept, blank rows kept, spinner frames parsed
  after seven fields, plain output unchanged, malformed field treated as 0, plain → markdown → plain in
  one running helper, a one-row animated markdown HUD, equal-width first and continuation rows with a
  spinner, the one-row overflow marker with a spinner
- [x] run the new and changed tests

### Task 5: Dispatcher validation and protocol argument

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher+Hud.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherHudTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift`

- [x] add `ControlArgs.markdown: Bool?` and `ControlArgs.fontSize: Double?`
- [x] in markdown mode allow LF and TAB in the message only, keep rejecting other control characters,
  apply the 4096 cap; plain mode keeps every current rejection
- [x] validate `fontSize` with the shared predicate on open; reject it on update
- [x] write tests: newline rejected in plain mode (existing test untouched), LF and TAB accepted with
  markdown, CR and ESC rejected, 4096 boundary, detail still capped at 256, whitespace-and-newline-only
  message rejected, font range boundaries, font on update rejected
- [x] write protocol encode/decode tests for both arguments
- [x] run the new and changed tests

### Task 6: CLI flags

**Files:**
- Modify: `agtermCore/Sources/agtermctlKit/SessionCommands.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/CommandsTests.swift`

- [x] add `--markdown` to `hud open` (and the bare `hud` form) and `hud update`, with help naming the
  4096 cap and that a single newline is a soft break
- [x] add `--font-size` to `hud open` only, validated with the shared predicate; help says it is fixed for
  the panel's life
- [x] add `--file PATH` to `hud open` (and the bare form) and `hud update`, mutually exclusive with the
  message argument; read UTF-8, drop one trailing newline
- [x] write tests: flags set the arguments, omitted flags send nil, font range rejection, help text
- [x] write tests for `--file`: content becomes the message, one trailing newline dropped, message and
  `--file` together rejected, neither rejected, missing file and invalid UTF-8 rejected before sending
- [x] run the new and changed tests

### Task 7: HUD font size in the app

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Session.swift` (`hudFontSize`)
- Modify: `agtermCore/Sources/agtermCore/AppStore+Panes.swift` (`openHud` stores it, `updateHud` holds
  the request)
- Modify: `agterm/Control/ControlServer+Hud.swift` (resolve before measuring, `paneMetrics` cell)
- Modify: `agterm/Control/ControlServer+SessionActions.swift` (`overlay.resize` measures the stored size)
- Modify: `agterm/agtermApp.swift` (overlay factory font under `isHud`)
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreHudTests.swift`
- Modify: `agtermTests/ControlServerSessionActionsTests.swift` and a hosted HUD test file

- [ ] resolve the effective creation size into a local before measuring on open; `openHud` stores it after
  the replacing teardown; clear it on close, on a refused open and on a failed body write
- [ ] measure the HUD cell from the stored `hudFontSize` in update and `overlay.resize`
- [ ] create the HUD surface at `hudFontSize` in the overlay factory
- [ ] hold the `fontSize` request across `updateHud`
- [ ] write tests: store keeps the request and effective size across update, a replacing open with a
  different font keeps the NEW request and effective size, a refused open leaves no `hudFontSize`, session
  zoom after open does not change the HUD's measurement
- [ ] write hosted tests: the factory passes the HUD font to the surface; a HUD opened with `--font-size`
  measures its panel from that size
- [ ] run the new and changed tests

### Task 8: Geometry refresh

**Files:**
- Modify: `agterm/Views/WindowContentView+Detail.swift`
- Modify: `agterm/Control/ControlServer+Hud.swift`
- Modify: a hosted HUD test file

- [ ] on a panel-frame change for a live HUD, rewrite its body from fresh `paneMetrics`, coalesced to one
  write per main-queue turn
- [ ] cover the first realization after an unmeasured open
- [ ] write hosted tests: shrinking the pane rewrites the header grid and re-clips a markdown body; a plain
  HUD recenters
- [ ] run the new and changed tests

### Task 9: Remote presentation

**Files:**
- Modify: `agterm/Control/ControlServer+RemotePresentation.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/RemotePresentationStateTests.swift`
- Modify: `agtermTests/ControlServerRemotePresentationTests.swift`

- [ ] copy `markdown` and `fontSize` when rebuilding the mirrored `HudSpec`
- [ ] confirm the receiving side applies no 256 cap to a markdown message
- [ ] write tests: a markdown HUD with a font size round-trips through a presentation frame; a
  4096-character markdown message fits the frame limit
- [ ] write hosted tests: bridged open and update carry both fields; an origin reopen with a different font
  recreates the replica at the new size
- [ ] run the new and changed tests

### Task 10: [Final] Update documentation
- [ ] `plugins/agterm/skills/agterm/` (reference and examples): `--markdown`, `--font-size`, `--file`, the
  cap, soft vs hard breaks, tight lists, a controller status panel example
- [ ] `site/commands.html`: the three flags and the `markdown`/`fontSize` read-back fields; `site/docs.html`:
  HUD section
- [ ] `.claude/rules/control-api.md`: the markdown mode contract (validation, header field, clipping,
  geometry refresh) and the font-size contract

### Task 11: Verify acceptance criteria
- [ ] verify plain HUD output is unchanged apart from the header field
- [ ] verify every block and inline kind in Technical Details renders as specified
- [ ] build the app (`make build`)
- [ ] run `cd agtermCore && swift test`
- [ ] run `make test-app`
- [ ] run `make lint`
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification** (only when Eugene authorizes a launch):
- an isolated Debug instance with a markdown status panel containing headings, nested lists, a numbered
  list, bold and italic, a code block, a table and more rows than fit: truncation markers, a narrow pane,
  a window resize, a spinner, an update switching back to plain, text color with styled spans, and
  `--font-size` both smaller and larger than the session's.

Smells pre-check: skipped — non-Go project
