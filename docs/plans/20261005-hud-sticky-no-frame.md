# Sticky and frameless HUD

## Overview

- `session hud` gains two options: `--sticky` puts the panel flush against the edge or corner its
  `--position` names, and `--no-frame` drops the border, the rounded corners and the blank row above
  and below the text.
- Together they let a script keep a zero-click caption at the top of a session or pane: full width,
  as tall as its text, with clickable links. This answers
  https://github.com/umputun/agterm/discussions/703.
- The HUD stays what it is: one transient slot per session, last writer wins, closed by
  `overlay open`, gone after a restart, not shown in zoom or dashboard cells.
- No row cap. Height follows the text; the caller keeps its line count right.

## Context (from discovery)

- `agtermCore/Sources/agtermCore/Hud.swift`: `HudSpec`, `HudPosition.edgeMarginPercent` (10),
  `HudLayout` (`clampSizePercent` 10...80, `box`, `panelSize`, `heightPercent`, `textColumns` capped at
  `maxColumns` 60, `panelGrid`, `markdownBody`).
- `agtermCore/Sources/agtermCore/AppStore+Panes.swift`: `openHud`, `updateHud`, `resizeOverlay` clamp
  the width and store `hudHeightPercent`.
- `agterm/Control/ControlServer+Hud.swift`: `openHud`/`updateHud` measure once; `watchHudGeometry`
  rewrites the body on a pane-geometry change but reuses the saved height percent.
- `agterm/Views/WindowContentView+Detail.swift`: `OverlayPanelStyle` (`panelFrame`, `offset` with the
  10% margin, `framed` doubling as the opaque backing), `overlayPanel`.
- `agterm/Ghostty/HudLinkClick.swift`: `panel(in:at:)` excludes sheets and asks, not the search bar.
- `agterm/Views/WindowContentView.swift`: `searchBarLayer`, top-trailing above the deck.
- Control surface: `ControlProtocol.swift` (`ControlArgs`), `ControlDispatcher+Hud.swift`,
  `ControlProjection.swift` (`ControlHudNode`), `agtermctlKit/SessionCommands.swift` (`Hud`),
  `ControlServer+RemotePresentation.swift` (`showRemoteHud` rebuilds `HudSpec` field by field).
- Docs: `plugins/agterm/skills/agterm/{SKILL.md,reference.md}`, `site/commands.html`, `site/docs.html`,
  `.claude/rules/control-api.md`.

Three defects found while designing this, all reachable today and all in the way of a caption:

- A HUD's height is a saved percent of the pane, so enlarging the window enlarges the panel while its
  text stays the same size.
- Markdown wraps at 60 columns even when the caller set a wider `--size-percent`.
- A ⌘-click on the search bar where a HUD lies underneath it goes to the HUD.

## Development Approach

- **testing approach**: tests in the same task as the code. The three defects above are TDD: failing
  test first, confirm it fails, then fix.
- Start Swift work with the `swiftui-expert`, `swift-testing-expert` and `swift-concurrency` skills.
- Complete each task before the next; all touched tests pass before moving on.
- Scope test runs to what changed (`-only-testing:`); run each full gate once, in Task 5.
- A HUD posted without the new flags keeps its anchor, margin and chrome. Three things change for it,
  all intended repairs: it stops growing with the window; its height is its text's height in points,
  no longer rounded up to a whole percent of the pane, so it can be a few points shorter and sit a few
  points off where it did at `center` and `bottom`; and a markdown panel on a narrowed pane rewraps and
  grows a row where it used to clip with `… N more`.
- `agtermCore` is a library the `agterm-linux` fork consumes. Public signatures are extended, never
  narrowed: new parameters take defaults and existing initializers keep compiling.
- Lint file-length limits (1000 source, 2000 tests) are already at the edge in five files this work
  touches: `Session.swift` 995, `SessionCommands.swift` 994, `ControlProtocolTests.swift` 2000,
  `CommandsTests.swift` 1996, `ControlServerSessionActionsTests.swift` 1983. No limit is raised.
  Source: the two computed HUD properties live in a new `Session+Hud.swift` extension, and the `Hud`
  command moves unchanged into `SessionHudCommands.swift`, as `SessionMetadataCommands.swift` already
  does for its group. Tests: new cases go into the smaller HUD test files named per task, never into
  the three full ones, which are only edited in place.
- Update this plan when scope changes.

## Testing Strategy

- **host-free** (`cd agtermCore && swift test`): layout math, spec coding, dispatcher, projection, CLI
  argument and help tests.
- **hosted** (`scripts/test-app.sh`, targeted): `OverlayPanelStyle` frames, geometry remeasure,
  `HudLinkClick` exclusion, remote mirror.
- **UI** (`agtermUITests/ControlHudUITests`, targeted methods only): `tree` read-back of the new
  fields through a real socket.
- Where the panel draws is not asserted by any test (a HUD is a Metal surface with no XCUIElement), so
  Task 5 checks it by eye in an isolated Debug instance.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document blockers with ⚠️ prefix

## Solution Overview

- **Sticky is placement only.** It zeroes the edge margin; at `center` there is no edge, so it does
  nothing there. Height still follows the text.
- **Sticky lifts the width cap to 100** when the anchor is not `center`. The cap on height stays at 80%
  of the pane for every HUD.
- **No-frame is appearance only.** Corner radius and border go to zero and the layout stops adding the
  blank row above and below. The opaque backing stays, so a translucent window does not show terminal
  output through the text. It works with or without sticky.
- **Height is held in points for every HUD**, not only sticky ones: rows times the cell height plus the
  panel's own padding, capped at 80% of the pane when laid out. One path instead of two, and a
  frameless panel that is not sticky gets the same stable height.
- **One capped height everywhere.** The 80% cap is applied in the host-free sizing, and that one value
  drives the frame, the painted grid and `hud.heightPercent`, so tall markdown is never fitted to rows
  the surface does not have.
- **A container-geometry change remeasures** the panel (wrap, rows, height) instead of only rewriting
  the body into a stale grid. The trigger is the session or pane bounds the panel is laid out in, not
  the panel's own size: a fixed-height panel does not change size when only the pane's height does,
  and observing the container keeps the remeasure from being driven by its own output.
- **One remeasure path.** The geometry watcher and `overlay resize` both go through a single
  store-level remeasure that sets width, height and grid together and leaves the auto-hide deadline,
  pane scope, spec and slot identity alone. It is not `hud update`, which would restart the lifetime.
- **A width forced by `overlay resize` holds** until the next `hud open` or `hud update`. The remeasure
  uses it in place of the spec's own width, so a geometry change cannot undo a resize.
- **An explicit width is the wrap width**, whether it came from `--size-percent` or from
  `overlay resize`. The 60-column cap keeps applying to a panel whose width the app measures, so an
  unsized HUD keeps its width. A sticky caption needs `--size-percent 100` to span the pane; sticky
  alone does not widen it.
- **The search bar wins its own region.** `HudLinkClick` skips a point the search bar covers, the same
  way it already skips a terminal ask.

Found while building, all in Task 2:

- **The panel's surface gets its own padding.** It inherited the user's `window-padding-*` while the
  sizing assumed the default, so a custom padding clipped a frameless caption, and already clipped
  today's framed HUD. libghostty will not report the padding (`ghostty_config_get` returns false for
  it), so the HUD surface is given the padding the sizing assumes, with `window-padding-balance`, which
  is what makes libghostty derive padding again after creation. The per-surface overlay now loads after
  the `config-file` includes so one of those cannot outrank it.
- **A live panel is measured with its own cell.** A pane's cell scaled to `--font-size` came out a pixel
  short and cost a frameless panel its last row. The surface reports size pushes and cell-size changes,
  and the remeasure reads the cell libghostty draws.
- **A session-wide panel is measured from the detail area** the deck lays it out in, not from terminal
  views that zoom and the dashboard move to another host.

Rejected: a `--lines` row cap (a clip would hide the links the caption exists for); one bundled
`--style banner` flag (placement and appearance are separate choices); a second, persistent HUD slot.

## Technical Details

- `HudSpec`: `sticky: Bool` (default false), `frame: Bool` (default true). Both decode with
  `decodeIfPresent`, so a mirrored spec from an older peer keeps today's look. Both are replaceable by
  `hud update`, like every field the body header or the view reads live.
- `HudLayout`:
  - `maxWidthPercent(for spec:)`: 100 when `spec.sticky` and `spec.position != .center`, else 80.
    `clampSizePercent(_:for:)` is added beside the existing one-argument form, which keeps its 80.
  - `verticalPadding(for spec:)`: 0 when `!spec.frame`, else 1; used by `box` and `markdownBody`.
  - `textColumns`: the `maxColumns` cap applies only when `spec.sizePercent == nil`.
  - `HudPanelSize` gains `heightPoints: Double?` with a nil default, so existing constructions compile;
    nil means an unmeasured pane. `panelSize` computes it as
    `min(rows * cellHeight + paddingHeight * 2, paneHeight * 0.8)` and derives `heightPercent` from it.
  - `panelGrid`/`paintGrid` take their rows from those capped points.
- `Session.hudHeightPoints: Double?` beside `hudHeightPercent`, cleared with the HUD state.
- The forced width reuses `Session.hudResizedWidthPercent`, which already means "the width an
  `overlay resize` forced, until the next open or update". Today only `publishHudResize` sets it, and
  only for a published panel; `AppStore.resizeOverlay` sets it for every HUD instead, and the store's
  `openHud`/`updateHud` clear it. No second field.
- `AppStore.remeasureHud(_:pane:)`: builds the effective spec (forced width over the spec's own),
  runs `HudLayout.panelSize`, stores the result. `ControlServer` wraps it with the body rewrite and the
  rollback on a failed write; the watcher and `resizeSessionOverlay` both call that wrapper.
- `OverlayPanelStyle`: `heightPoints` (used in `panelFrame`), `edgeMargin` (0 when sticky), chrome
  zeroed when `!frame` with `framed` left true for the backing. `offset` works from the laid-out size,
  since height is no longer a fraction. `overlayPanel` fires `onHudGeometryChange` on the layout
  frame's size.
- `ControlArgs`: `sticky: Bool?`, `frame: Bool?`. CLI: `--sticky`, `--no-frame` on `hud open` and
  `hud update`. `ControlHudNode`: `sticky: Bool`, `frame: Bool`, always present.
- `hud.sh` centers the block in the grid it is given; with zero vertical padding the grid rows equal
  the text rows, so the helper needs no change. Task 1 confirms that with a helper test.
- Rows covered, for the docs: with the session's font and default padding, N lines of text cover N rows
  plus the panel's 12 points of padding, so N+1 free rows are enough. A user padding override or a HUD
  `--font-size` changes that; it is stated as an example.

## What Goes Where

- **Implementation Steps**: code, tests and docs in this repo.
- **Post-Completion**: the reply in the discussion after merge.

## Implementation Steps

### Task 1: Layout model in agtermCore

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Hud.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/HudTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/HudMarkdownTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/HudHelperTests.swift`

- [x] failing test first: a markdown spec with an explicit `sizePercent` wider than 60 columns wraps at
      the panel's width; confirm it fails, then lift the cap for an explicit width only
- [x] `HudSpec` carries `sticky` and `frame` through init, coding, `holdingCreationFields` and
      `withSizePercent`; an absent key decodes to today's behavior
- [x] the width cap is per spec: 100 for a sticky panel off center, 80 otherwise, for a measured width
      and a caller's alike
- [x] a frameless spec measures and paints with no blank row above or below the text, plain and
      markdown
- [x] `HudPanelSize` carries the capped height in points, and the paint grid's rows and the derived
      percent come from it
- [x] existing public signatures keep compiling: every current `HudPanelSize(` and
      `clampSizePercent(` call site in the package and its tests builds unchanged
- [x] tests: cap per anchor and flag, frameless box and body rows, points for one, two and wrapped
      lines, content past 80% of the pane (points, grid rows, clipped body and percent all agree),
      round-trip coding, the helper painting a frameless body at row 1
- [x] `cd agtermCore && swift test --filter Hud` passes

### Task 2: Store, geometry and the panel view

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Session.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+Panes.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+Presentation.swift`
- Create: `agtermCore/Sources/agtermCore/Session+Hud.swift`
- Modify: `agterm/Control/ControlServer+Hud.swift`
- Modify: `agterm/Control/ControlServer+SessionActions.swift`
- Modify: `agterm/Views/WindowContentView+Detail.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreHudTests.swift`
- Modify: `agtermTests/HudDeckGatesTests.swift`
- Modify: `agtermTests/ControlServerSessionActionsTests.swift`
- Modify: `agtermTests/ControlServerHudAutoHideTests.swift`

- [x] failing test first: the same HUD laid out at one width in two pane heights has the same frame
      height in points; confirm it fails against the saved percent, then lay out from points and make
      the container-geometry watcher remeasure
- [x] `testAPaneShrinkReclipsAMarkdownHudOnceForABurst` and
      `testTheHudIsMeasuredWithItsOwnFontThroughOpenZoomUpdateAndResize` in
      `ControlServerSessionActionsTests` state the old saved-percent behavior; rewrite their expected
      values to the new one (rewrap and grow by the known added row, once per burst) rather than
      leaving them to fail at the gate
- [x] one remeasure path serves the watcher and `overlay resize`: width, capped height and grid move
      together, a failed write rolls all three back, and the deadline, pane scope, spec, slot
      generation and surface identity are untouched
- [x] a width forced by `overlay resize` survives a later geometry change and is dropped by the next
      open or update; it is honored up to the live spec's cap and is the wrap width
- [x] `OverlayPanelStyle` lays the panel out from points, holds no margin for a sticky panel, and draws
      no border or rounding for a frameless one while keeping the backing
- [x] tests: panel frames for sticky top, bottom, a corner, a side and center; a default HUD's anchor,
      margin and chrome unchanged; frameless chrome values; a height-only pane change updates
      `hud.heightPercent` and leaves the frame height; a narrowed pane adds the known row with a
      matching body grid; `overlay resize` then a geometry change keeps the resized width; the
      auto-hide deadline survives a remeasure
- [x] targeted `swift test` and `scripts/test-app.sh -only-testing:` runs pass

### Task 3: Control surface

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher+Hud.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlProjection.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift`
- Modify: `agtermCore/Sources/agtermctlKit/SessionCommands.swift`
- Create: `agtermCore/Sources/agtermctlKit/SessionHudCommands.swift` (the `Hud` command, moved)
- Modify: `agterm/Control/ControlServer+RemotePresentation.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherHudTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreHudTests.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/HudCommandHelpTests.swift`
- Modify: `agtermTests/ControlServerRemotePresentationTests.swift`
- Modify: `agtermUITests/ControlHudUITests.swift`

- [x] `session.hud.open` and `.update` accept `sticky` and `frame` and pass them into the spec; an
      update that omits them returns the panel to the defaults, like every other replaced option
- [x] `agtermctl session hud [open|update]` takes `--sticky` and `--no-frame`, with help text in the
      caller's words; the `--size-percent` help on both stops saying "bounded to 10-80" without
      qualification
- [x] `tree` reports `hud.sticky` and `hud.frame`, and `hud.sizePercent` reads back 100 for a sticky
      panel that asked for it
- [x] the remote mirror carries both fields to an attached Mac
- [x] tests: dispatcher accept and default cases; request coding with the keys present and omitted
      when nil; `ControlHudNode` round trip and an older server's node decoding to not sticky, framed;
      `controlTreeReportsHudWithEveryField` covers the two fields; CLI argument and help; mirror
      reconstruction; one UI test reading the new fields back over the socket. The protocol and CLI
      cases go in `ControlDispatcherHudTests`, `AppStoreHudTests` and `HudCommandHelpTests`
- [x] targeted runs pass

### Task 4: Search bar keeps its clicks

**Files:**
- Modify: `agterm/Ghostty/HudLinkClick.swift`
- Modify: `agterm/Views/TerminalSearchBar.swift`
- Modify: `agtermTests/GhosttySurfaceViewTrackingTests.swift`

- [x] failing test first: with the real `TerminalSearchBar` hosted over a HUD panel, a ⌘-click at a
      point the bar covers is not claimed by the panel; confirm it fails, then exclude the bar's own
      bounds through a passive marker view registered weakly, as `askCovers` reads its catchers
- [x] ⌘-hover over that region leaves the cursor to the search bar
- [x] the exclusion covers the bar's bounds only, not its alignment padding, and goes away when the
      bar unmounts
- [x] tests: click and hover inside the bar; a ⌘-click on the same panel outside it is still claimed
      as a press and release pair; removing the bar restores routing at that point
- [x] targeted hosted run passes

### Task 5: Verify acceptance criteria

- [x] run each gate once: `cd agtermCore && swift test`, `make test-app`, `make lint`, Debug build
- [x] launch an isolated Debug instance (short `/tmp` state dir, `windows` marker) and check by eye,
      capturing each: a sticky frameless two-line markdown caption at the top, full width, session-wide
      and on one pane of a split; the same at the bottom and in a corner; it keeps its height through a
      window resize and gains a row when narrowed until a line wraps; links open on ⌘-click; the search
      bar stays on top and usable over it; a default HUD looks as before; a frameless caption with
      `--font-size` and one under a non-default terminal font show every line of their text
- [x] stop the instance by pid and check `lsappinfo list | grep -A4 agterm.debug`

### Task 6: [Final] Update documentation

- [ ] `plugins/agterm/skills/agterm/reference.md` and `SKILL.md`: the two options, the read-back
      fields, the caption recipe, the rows-covered example, and the corrected statements about the 80%
      width bound and the height following a resize; a trigger for the pinned caption in SKILL.md's
      `description`; `examples.md` where it states the 80% cap and the 10% margin
- [ ] `site/commands.html` and `site/docs.html` mirror the same; bump `style.css?v=` only if the CSS
      changes
- [ ] `.claude/rules/control-api.md`: the sizing paragraph (points, remeasure on geometry, per-spec
      cap, wrap rule) and the search bar exclusion beside the `HudLinkClick` note
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

**Discussion reply** (not part of the build run; the maintainer's call after merge): a comment on
https://github.com/umputun/agterm/discussions/703 saying what shipped, with the caption command as the
how-to example and the stated limits (one slot, re-posted by the script, height follows the text).

Smells pre-check: skipped — non-Go project
