# session.text — read a session's buffer over the control API

Closes umputun/agterm#34.

## Overview

Add a `session.text` control command that returns a session's terminal buffer as
plain text in `result.text`, so an external script can pull the whole screen (or
scrollback) over the socket — today `session.copy` only returns an existing
selection and there is no select-all over the control channel.

Shape (settled with umputun in the issue, plus the maintainer's `--pane` addition):

- `agtermctl session text` — the **visible screen** by default
- `--all` — the full screen + scrollback
- `--lines N` — the last N lines of the full buffer
- `--pane left|right` — which pane to read; **default = the focused pane**.
  Vocabulary matches `session.focus --pane left|right|other` (uniform across the app;
  `session.type`/`session.copy` are intentionally left main-only, out of scope here).
- text comes back in `result.text`, exactly like `session.copy`
- **plain text only** — no `--ansi`. The pinned libghostty exposes only
  `ghostty_surface_read_text` (UTF-8, no per-cell color/SGR), and that pin is
  deliberate, so a styled dump is not possible against the pinned surface API.
  Dropped from this change by design — but it is a clean future follow-up: ghostty's
  core formatter already supports `vt` (SGR) output, and a surface-level styled read
  (`ghostty_surface_read_text_styled`, same contract as `read_text` but `emit = .vt`
  with palette resolved to direct RGB) was written as **closed-unmerged PR
  ghostty-org/ghostty#12909** — watch/subscribe at
  https://github.com/ghostty-org/ghostty/pull/12909 . It was auto-closed by the
  contributor-vouch bot, not on technical merit. Once a styled surface read lands in
  upstream `main` and the pin is bumped past it (the pin is also held pre-regression
  for the font-increase scrollback bug), `--ansi` can be added by pointing the reader
  at the styled call. Carrying the #12909 patch locally is the only other path and is
  rejected here (breaks the self-owned, upstream@SHA-only build property).

## Context (from discovery)

Modeled end-to-end on `session.copy`. The four (five, with the skill) keep-in-sync
surfaces and their exact spots:

- **Protocol** — `agtermCore/Sources/agtermCore/ControlProtocol.swift`
  - `Command` enum (line ~26, beside `case sessionCopy = "session.copy"`)
  - `ControlArgs` (line 57): already has `pane` (reused) and the result already has
    `text`; reuses the existing `pane` field (already `left|right|other` for
    `session.focus`); need two NEW fields `all: Bool?` and `lines: Int?` (+ init params).
- **Server** — `agterm/Control/ControlServer.swift`
  - dispatch switch (line ~458, beside `case .sessionCopy`)
  - `copySelection(_:window:)` (line 921) is the template for the new arm.
- **Surface reader** — `agterm/Ghostty/GhosttySurfaceView.swift`
  - `readSelection()` (line 323) is the near-clone; new reader uses
    `ghostty_surface_read_text(surface, selection, &t)` with a `ghostty_selection_s`
    instead of `ghostty_surface_read_selection`. Same `ghostty_text_s` +
    `ghostty_surface_free_text` copy-out idiom.
- **CLI** — `agtermCore/Sources/agtermctlKit/Commands.swift`
  - `Session.subcommands` list (line 208) — register the new `Text` command
  - `struct Copy: RequestCommand` (line 361) is the template.
- **Tests**
  - round-trip: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift` (line ~44)
  - CLI parse: `agtermCore/Tests/agtermctlKitTests/CommandsTests.swift` (line ~213, the
    `sessionCopy*` cases)
  - e2e: `agtermUITests/ControlAPIUITests.swift` (line ~415, `testSessionCopy*`)
- **Agent skill (HARD keep-in-sync, 5th surface)** — `agterm/Resources/agent-skill/`
  - `SKILL.md` (command summary + the count, **46 → 47**)
  - `reference.md` (per-command detail), `examples.md` (a recipe)
- **Rules note** — `.claude/rules/control-api.md` documents the catalog and the
  command count (46). Bump to 47 and add a `session.text` description sentence.

Pane → surface map (from `Session.swift`), `left|right` to match `session.focus`:
- `left` → `Session.surface` (the main pane)
- `right` → `Session.splitSurface` (the split pane; nil when no split → error)
- default (omitted) → `Session.activeSurface` (= split when `splitFocused` && a split
  exists, else main) — "the focused pane".

libghostty C API (`GhosttyKit.../Headers/ghostty.h`):
- `ghostty_selection_s { ghostty_point_s top_left; ghostty_point_s bottom_right; bool rectangle; }`
- `ghostty_point_s { ghostty_point_tag_e tag; ghostty_point_coord_e coord; uint32_t x; uint32_t y; }`
- tags: `GHOSTTY_POINT_VIEWPORT` (visible screen) vs `GHOSTTY_POINT_SCREEN` (whole
  buffer incl. scrollback); coords: `..._COORD_TOP_LEFT` / `..._COORD_BOTTOM_RIGHT`.
- visible: VIEWPORT top-left → VIEWPORT bottom-right. full: SCREEN top-left → SCREEN
  bottom-right. `rectangle = false` (line-wrapped, not block).

## Development Approach

- **Testing approach: Regular** (code first, then tests) per the maintainer's norm —
  protocol/CLI logic is host-free and unit-tested in `swift test`; the surface read +
  full wiring is covered by an XCUITest e2e (the only place a real surface exists).
- The surface reader itself (`ghostty_surface_read_text`) is NOT host-free and is
  exercised only through the e2e, like `readSelection`/`session.copy` — there is no
  unit test for the libghostty call, by design (`agtermCore` is GhosttyKit-free).
- Complete each task fully; `swift test` (in `agtermCore`) must stay green before the
  next task. The app must build.
- Small, focused changes. Backward compatible — purely additive.

## Testing Strategy

- **unit tests** (`agtermCore` `swift test`, host-free, run per task):
  - `ControlProtocolTests` — `session.text` request encodes/decodes round-trip with
    `all`/`lines`/`pane` args.
  - `CommandsTests` — `session text` CLI parses to the right `ControlRequest`
    (defaults; `--all`; `--lines N`; `--pane left|right`; and the mutual-exclusion /
    bad-value `validate()` errors).
- **e2e** (`agtermUITests/ControlAPIUITests.swift`, XCUITest — NOT run in CI, run
  locally): `testSessionText*` — create a session, `session.type` a known marker,
  then `session text` and assert the marker is in `result.text`; assert `--pane right`
  on a non-split session errors. Mirror the existing `testSessionCopy*` style.

## Solution Overview

A pure clone of the `session.copy` pipeline with three behavioral deltas:

1. The reader spans a screen region (`read_text`) instead of the selection
   (`read_selection`); region = VIEWPORT (default) or SCREEN (`--all`/`--lines`).
2. `--lines N` reads SCREEN then keeps the **last N lines** of the returned text
   (split on `\n`, take suffix). Simple and correct; for personal scripting the cost
   of reading the whole buffer then trimming is irrelevant. (Avoids fragile absolute-
   row coordinate math on the Swift side.) `--lines` already reads the full SCREEN, so
   `--all --lines N` is redundant rather than contradictory — rejecting the combo is a
   deliberate UX choice (one clear meaning per flag), not a technical necessity.
3. A `--pane left|right` selector picks the surface (`left`→main, `right`→split);
   default = `activeSurface` (the focused pane). Reuses `session.focus`'s vocabulary.

Empty/edge handling: an unrealized surface → `"session not realized"` error (same as
copy). A nil/empty read → return `ok` with an **empty string** (not an error) —
"read the screen" legitimately may be near-empty, and erroring is hostile to scripts
(differs from `session.copy`'s `"no selection"` on purpose).

Args reuse: `pane` (existing field, already `left|right|other`) carries `left|right`;
`text` (existing result field) carries the dump. Only `all: Bool?` + `lines: Int?` are new.

## Technical Details

- New `Command` case: `case sessionText = "session.text"`.
- New `ControlArgs` fields: `all: Bool?`, `lines: Int?` (added to the struct, the
  `init`, and the `init` call site — keep `Equatable`/`Codable` synthesized).
- Reader signature (app target, `GhosttySurfaceView`):
  `func readScreenText(all: Bool, lines: Int?) -> String?`
  - builds `ghostty_selection_s` (VIEWPORT vs SCREEN per `all || lines != nil`),
    calls `ghostty_surface_read_text`, copies out of `ghostty_text_s`, frees with
    `ghostty_surface_free_text` (defer), decodes UTF-8 — same shape as `readSelection`.
  - when `lines` is set, returns the last N lines of the decoded text.
- Server arm `readText(_ target:window:pane:all:lines:)`:
  - `resolveSession(target, window:)`; inside, pick the surface by `pane`
    (`left` → `surface`, `right` → `splitSurface` else `"session has no split pane"`
    error, default → `activeSurface`), cast to `GhosttySurfaceView`,
    `"session not realized"` if nil; call the reader; return `ControlResult(text:)`.
- CLI `struct Text: RequestCommand` under `Session`:
  - `@Flag --all`, `@Option --lines <n>`, `@Option --pane <left|right>`, the standard
    `TargetOptions` + `ClientOptions`.
  - `validate()`: reject `--all` together with `--lines`; reject `--lines` ≤ 0;
    reject a `--pane` value other than `left`/`right`.
  - `makeRequest()` → `ControlRequest(cmd: .sessionText, target: target.target,
    args: options.withWindow(ControlArgs(all: all ? true : nil, lines: lines,
    pane: pane)))`.

## Progress Tracking

- mark `[x]` immediately when done; ➕ for new tasks; ⚠️ for blockers.
- if the design shifts during implementation, update this file.

## What Goes Where

- **Implementation Steps** (checkboxes): protocol, server, reader, CLI, tests, skill,
  rules doc — all in-repo.
- **Post-Completion** (no checkboxes): the branch is already `feat/session-text`;
  manual smoke against a dev instance; PR back to umputun/agterm#34; the app build +
  XCUITest e2e are run locally (CI does not run XCUITests).

## Implementation Steps

### Task 1: Protocol — add the `session.text` command + args

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift`

- [x] add `case sessionText = "session.text"` to the `Command` enum (beside `sessionCopy`)
- [x] add `public var all: Bool?` and `public var lines: Int?` to `ControlArgs`, with doc comments, plus matching `init` params (default `nil`) and assignments
- [x] extend the `pane` doc comment to note it also carries `left|right` for `session.text`
- [x] write a round-trip test: `ControlRequest(cmd: .sessionText, target: "9f3c", args: ControlArgs(all: true, lines: 50, pane: "left"))` encodes → decodes equal (success case)
- [x] write a round-trip test for the bare/default form (`session.text` with no args) and `lines`-only (edge cases)
- [x] run `cd agtermCore && swift test` — must pass before Task 2

### Task 2: CLI — `session text` subcommand

**Files:**
- Modify: `agtermCore/Sources/agtermctlKit/Commands.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/CommandsTests.swift`

- [x] add `struct Text: RequestCommand` under `Session` (model on `Copy`), with `--all` flag, `--lines <n>` option, `--pane <left|right>` option, `TargetOptions`, `ClientOptions`, and an abstract help string
- [x] implement `validate()`: error on `--all` + `--lines` together, on `--lines` ≤ 0, and on a `--pane` value not in `{left, right}`
- [x] implement `makeRequest()` building the `.sessionText` `ControlRequest` (see Technical Details)
- [x] register `Text.self` in the `Session` `subcommands` array (line ~208)
- [x] write CLI-parse tests: defaults (`session text` → target `active`, no args); `--all`; `--lines 50`; `--pane right`; mirror the `sessionCopyDefaultsActive`/`…WithTarget` style
- [x] write CLI-parse tests for the `validate()` errors (all+lines, lines≤0, bad pane) — note: negative `--lines` (`-5`) is intercepted by ArgumentParser as a flag before `validate()`, so the CLI-reachable non-positive case is `0`
- [x] run `cd agtermCore && swift test` — must pass before Task 3

### Task 3: Surface reader — `readScreenText` on `GhosttySurfaceView`

**Files:**
- Modify: `agterm/Ghostty/GhosttySurfaceView.swift`

- [x] add `func readScreenText(all: Bool, lines: Int?) -> String?` beside `readSelection()`, with a doc comment explaining the VIEWPORT-vs-SCREEN region and the copy-out/free idiom
- [x] build the `ghostty_selection_s` (VIEWPORT top-left→bottom-right by default; SCREEN when `all || lines != nil`; `rectangle = false`), call `ghostty_surface_read_text`, copy `ghostty_text_s` → Swift `String`, `defer ghostty_surface_free_text`
- [x] set BOTH `tag` AND `coord` explicitly on each of `top_left`/`bottom_right` — a zero-init `ghostty_point_s` defaults to `GHOSTTY_POINT_ACTIVE`/`GHOSTTY_POINT_COORD_EXACT` (both enum 0), NOT viewport/top-left; do not rely on defaults
- [x] guard the `Bool` return of `ghostty_surface_read_text` (return nil on `false`) and the nil/empty `ghostty_text_s.text`, exactly like `readSelection`
- [x] when `lines` is set and > 0: strip a single trailing `\n` first (a buffer ending in newline would otherwise yield a trailing empty line), split on `\n`, return the last N lines
- [x] (no unit test — exercised via the e2e in Task 5, like `readSelection`; note this in the doc comment)

### Task 4: Server — `.sessionText` dispatch arm

**Files:**
- Modify: `agterm/Control/ControlServer.swift`

- [x] add `case .sessionText: return readText(request.target, window: request.args?.window, pane: request.args?.pane, all: request.args?.all ?? false, lines: request.args?.lines)` to the dispatch switch (beside `.sessionCopy`)
- [x] add `private func readText(_ target:window:pane:all:lines:)` modeled on `copySelection`: `resolveSession`, pick the surface by `pane` (`left`→`surface`, `right`→`splitSurface` else `"session has no split pane"` error, default→`activeSurface`), `"session not realized"` if not a `GhosttySurfaceView`, call `readScreenText`, return `ControlResult(text: text ?? "")`
- [x] (no host-free test — covered by the e2e in Task 5)
- [x] confirm the app target builds (`make build`)

### Task 5: e2e test

**Files:**
- Modify: `agtermUITests/ControlAPIUITests.swift`

- [x] add `testSessionTextReturnsBuffer`: create a session, `session.type` a unique marker string + Return, then `session.text` and assert `result.text` contains the marker (model on `testSessionCopyWithoutSelectionErrors` for the harness scaffolding)
- [x] add `testSessionTextSplitPaneWithoutSplitErrors`: `session.text --pane right` on a non-split session returns `ok:false` (asserts the SERVER `"session has no split pane"` arm — `right` passes CLI `validate()`, so the request reaches the server, unlike an invalid pane value that would fail at parse)
- [x] run the e2e locally (XCUITest; not in CI) — must pass before Task 6 (both tests passed: `Executed 2 tests, with 0 failures` in 8.9s)

### Task 6: Agent skill + rules doc (HARD keep-in-sync)

**Files:**
- Modify: `agterm/Resources/agent-skill/SKILL.md`
- Modify: `agterm/Resources/agent-skill/reference.md`
- Modify: `agterm/Resources/agent-skill/examples.md`
- Modify: `.claude/rules/control-api.md`

- [x] add `session.text` to the `SKILL.md` command summary and bump the count **46 → 47** at `SKILL.md` line ~91 ("(46 commands)")
- [x] add the full per-command entry to `reference.md` (args: `--all`, `--lines N`, `--pane left|right`; returns `result.text`; plain text only; default = visible screen / focused pane; note it reads the focused pane by default and `--pane` has NO `other` value, unlike `session.focus`)
- [x] add an `examples.md` recipe (e.g. extract URLs: `session text --all | grep -oE 'https?://...'`)
- [x] update `.claude/rules/control-api.md`: add a `session.text` sentence to the command catalog, and bump ALL THREE count sites — line 28 "46-command summary", line 32 "catalog (46 commands)", line 32 "bumped to 46" → 47
- [x] grep the skill + rules for the old `46` count (`grep -rn "46" agterm/Resources/agent-skill/ .claude/rules/control-api.md`) to confirm none remain (safety net beyond the four enumerated sites) — confirmed: no matches
- [x] run `cd agtermCore && swift test` (no-op for docs, but confirms nothing broke) — 809 tests passed

### Task 7: Verify acceptance criteria

- [x] `session text` (default) returns the visible screen; `--all` returns more (scrollback); `--lines N` returns ≤ N lines
- [x] `--pane left` and `--pane right` read the correct pane; `--pane right` on a non-split session errors
- [x] `--all` + `--lines` together is rejected at the CLI; bad `--pane` rejected
- [x] run full `cd agtermCore && swift test`; build the app; run the new XCUITests locally
- [x] all four control surfaces present (Command case, server arm, CLI subcommand, tests) + the skill mirror updated

### Task 8: Final — docs + housekeeping

- [x] confirm `README.md` needs no change (control commands aren't enumerated there) — confirmed — control commands not enumerated in README, no change needed (README shows usage examples like `session type`/`session copy`/`session overlay`, not a full command catalog)
- [x] move this plan to `docs/plans/completed/`

## Post-Completion
*Manual / external — no checkboxes*

**Manual verification:**
- Smoke against an isolated dev instance: `make build`, launch with
  `AGTERM_STATE_DIR`/`AGTERM_CONTROL_SOCKET` overrides, then
  `agtermctl session text --socket <tmp>/agterm.sock` against a session with known
  content; try `--all`, `--lines 5`, `--pane left|right`. Do NOT touch the deployed
  daily-driver instance.
- Sanity-check the umputun use cases from the issue: pipe `session text --all` into
  `grep`/`fzf` to extract URLs / file paths.

**External:**
- Open the PR against `umputun/agterm` (branch `feat/session-text`) closing #34;
  note in the PR that `--ansi` was intentionally dropped (plain text only, per the
  maintainer's comment) — link the upstream follow-up
  https://github.com/ghostty-org/ghostty/pull/12909 (`ghostty_surface_read_text_styled`,
  closed-unmerged) as the path to a future styled dump — and that the
  maintainer-requested `--pane` selector is included.
