# agtermctl pick follow-ups (discussion #270)

## Overview

Four follow-ups to the `agtermctl pick` control command shipped in 0.19.0, accepted from discussion #270
after review. Two are behavior fixes to shipped defaults, two add new caller-facing arguments.

1. **Subtitle matching removed for caller-supplied pickers.** Subtitles are currently fuzzy-search keys.
   A confirm row subtitled `cannot be undone` matches the query `no` as a substring at offset 3, while
   `Cancel` matches it not at all, so typing a refusal filters the safe row out and leaves the destructive
   row alone and preselected. Enter then destroys. This is a reachable wrong-result path, not a preference.
2. **Caller-supplied item order preserved.** On an empty query every item scores 0 and the tie-break
   re-sorts A→Z, so a caller cannot express a default. The first row is preselected and Enter-on-open
   fires it, which means the caller's intended default is silently replaced by whatever sorts first.
3. **`--query TEXT` prefills the picker query field.** Lets a rename flow open with the current name, and
   pre-narrows a long list.
4. **An empty item list is accepted when `--allow-custom` is set.** Turns `pick` into a usable text prompt
   instead of requiring a dummy row.

Items 1 and 2 change defaults on behavior that is documented nowhere (not README, not the bundled skill,
not `site/commands.html`). That is what makes flipping them cheap now and expensive later.

Items 3 and 4 compose: empty items + `--allow-custom` + `--query "$current"` is a rename dialog, which is
the workflow the reporter still hand-rolls as an ANSI overlay with a temp-file protocol.

**Out of scope, declined publicly in the discussion** (do not implement, do not "improve" into existence):

- committing an empty custom answer (needs a caller-supplied row label; more API than items 3 and 4 together)
- a persistent context / message pane on the picker (row labels already wrap unbounded; put consequence text there)
- a caller-supplied correlation tag, or letting the caller mint the pick id (breaks the global id uniqueness
  that `PickRegistry.livePick` and `retainedResult` both scan on; a collision means one caller reads another's answer)

## Context (from discovery)

Files involved:

- `agterm/Views/Palette.swift` — `CommandPalette`; `updateFiltered()` (:126-145) and its doc comment
  (:124-125), the `.attention` order bypass (:128-135), the ranking call (:136-138), the custom-row block
  (:139-143), `@State query` (:93), `.onAppear { updateFiltered() }` (:207-209), row rendering (:299-311)
- `agtermCore/Sources/agtermCore/Fuzzy.swift` — `fuzzyScore` / `fuzzyRank`; **not changing**. Its godoc
  already states an empty query is an alphabetical sort and that a caller needing input order should skip
  ranking. `Palette.swift:136` is its only caller repo-wide, so the blast radius is that one closure.
- `agtermCore/Sources/agtermCore/PaletteCustomRow.swift` — precedent for a tiny host-free palette helper
- `agtermCore/Sources/agtermCore/ControlPick.swift` — `ControlPickItem`, `ControlPickResult`
- `agtermCore/Sources/agtermCore/Pick.swift` — `PendingPick`, `PickController`, `PickRegistry`
- `agtermCore/Sources/agtermCore/ControlDispatcher+Pick.swift` — validation (:8 the empty-items guard,
  :22-27 the control-character check)
- `agtermCore/Sources/agtermCore/ControlProtocol.swift` — `ControlArgs` pick fields (:209-214) and the
  explicit public memberwise init (:256-295)
- `agtermCore/Sources/agtermctlKit/MiscCommands.swift` — `// MARK: - pick` at :266, `struct Open` :277-411,
  `Result` :413, `Cancel` :463
- `agterm/Views/WindowContentView.swift` — `pickPaletteOverlay` (:804-828), built-in palette mount (:796)

Patterns found:

- Host-free helpers for palette decisions already exist (`pickCustomRowLabel`, a 9-line file with one
  public function, one call site, and its own 4-test file). This is the precedent item 1 follows.
- `agtermCore` tests use Swift Testing (`@Test`, `#expect`); `agtermTests` and `agtermUITests` use XCTest.
- Existing coverage: `PickTests` (12), `ControlDispatcherPickTests` (9), `PickCustomRowTests` (4),
  `FuzzyTests` (17), `ControlServerPickTests` (15), `ControlPickUITests` (12).
- **Coverage gap found during planning:** `CommandPalette.updateFiltered()`'s empty-query order bypass has
  no test at any level. `AppActionsPaletteTests` holds two tests, both about move destinations;
  `AttentionButtonUITests` covers the titlebar bell popover, not the palette; no UI test opens the
  attention palette at all. Task 3 modifies that guard, so it adds the coverage rather than relying on it.

Dependencies / constraints:

- `.claude/rules/control-api.md` cross-surface contract: a new argument needs protocol, dispatcher, CLI,
  tests, plus the bundled skill (`SKILL.md`, `reference.md`, **`examples.md`**, troubleshooting) and the
  site mirrors. The **command count does not change** (no new `Command` case), so `SKILL.md:146` and
  `SkillInstallTests.swift:26` keep saying 71 and are untouched.
- No new read-back field is required: `prompt` and `allowCustom` have none either, and `pickPending`
  already satisfies the state-write rule. `pick` emits no events, so there is no `EventFormatter` work.
- `site/commands.html:1768-1776` enumerates every pick error string verbatim, as does `reference.md`.
  Any new or changed string is a doc obligation.
- CLI needs no change for item 4: empty stdin already yields `[]` from `Pick.Open.parseItems`.

### Verified during planning (do not re-derive)

Each was checked against the code, not assumed. These are the facts the tasks below depend on.

- **`ControlArgs` JSON round-trip distinguishes `nil` from `[]`, end to end.** `ControlArgs` declares no
  `CodingKeys` and no custom `encode(to:)`/`init(from:)`, so `Codable` is synthesized and uses
  `encodeIfPresent`/`decodeIfPresent`; both wire ends use a plain, unconfigured `JSONEncoder()`/
  `JSONDecoder()` (`agtermctlKit/SocketClient.swift:32,40`; `agterm/Control/ControlServer.swift:248,289`).
  Measured on the same declaration shape: `nil` omits the key and decodes to `nil`; `[]` encodes as
  `"items":[]` and decodes to `[]`. **Item 4 needs no encoding change and is not gated.**
- **After item 1, the query `no` matches *neither* row of a Confirm/Cancel pair.** `termScore`
  (`Fuzzy.swift:43-55`) against `cancel`: no prefix, no `no` substring, and the subsequence walk finds `n`
  at index 2 then no later `o` → nil. Against `confirm`: same, nil. So the correct post-fix result is an
  **empty list**, not a surviving Cancel row. Enter on an empty list is already a no-op
  (`runSelected` guards `filtered.indices.contains`, `Palette.swift:261-264`). Task 1's oracle is written
  to this, not to the intuitive-but-false "Cancel survives".
- **`make test-app` runs `-scheme agtermTests`** (`scripts/test-app.sh:10`), the hosted AppKit suite. It
  does **not** run `agtermUITests`. UI cases need their own invocation (see Testing Strategy).
- `.onAppear` already calls `updateFiltered()` (`Palette.swift:207-209`), so a prefilled query filters on
  open with no extra wiring for item 3.
- `ControlArgs` has no `query` field today, so item 3 adds one without a collision.
  `ControlPickResult.query` is a different struct (the result payload).
- `ControlArgs.prompt` is **not** control-character validated today (`ControlDispatcher+Pick.swift:22-27`
  checks item label and subtitle only). See the Solution Overview decision on `query`.
- `Pick.Open.parseItems` on empty stdin takes the line-splitting branch and returns `[]`, not an error.
- Row labels are `Text(item.title)` with no `lineLimit` (`Palette.swift:305`); only subtitles clamp to one
  line (:307-308). This is why the declined "context pane" ask is unnecessary.
- `site/docs.html:1194-1224` carries its own picker section, so it is a real Task 7 surface.
- `ControlPickUITests.swift:35-37` already comments that an empty query "skips ranking entirely, so
  filtered order equals input order". That comment is **false today** and becomes true after Task 3.

## Development Approach

- **testing approach**: TDD for items 1-2 (bug fixes — write the failing test, run it, confirm it fails on
  *behavior* rather than on compilation, then fix), regular for items 3-4 (new surface — code, then tests
  in the same task)
- **start each Swift task with the required skill** (CLAUDE.md): `swiftui-expert` for the view work
  (tasks 2, 3, 5), `swift-testing-expert` for test authoring (tasks 1, 4, 6)
- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - tests are not optional - they are a required part of the checklist
  - cover both success and error scenarios
- **CRITICAL: all tests must pass before starting next task**
- **CRITICAL: update this plan file when scope changes during implementation**
- **CRITICAL: never weaken an assertion to make a task pass.** Item 1's oracle is deliberately unintuitive
  (see Verified above); if a test disagrees with the plan, re-read that block before touching the test.
- maintain backward compatibility for items 3-4; items 1-2 deliberately change defaults

Project gates (CLAUDE.md): every change must build and pass `cd agtermCore && swift test`, `make test-app`,
and `make lint` with zero findings. Root SwiftLint limits are 200-column lines, 1000-line files, 800-line types.

Comments follow the project rule: short, only non-obvious constraints or rejected alternatives. Test
comments are rare and one line; the one worth writing is the regression reason on the item 1 test.

## Testing Strategy

- **unit tests (host-free, `cd agtermCore && swift test`, ~0.2s)**: the search-key helper, dispatcher
  validation, protocol round-trip and nil-omission, CLI request building. Most coverage belongs here.
- **hosted tests (`make test-app`, scheme `agtermTests`)**: only where AppKit is genuinely required.
- **UI tests (`agtermUITests/ControlPickUITests.swift`)**: the two behavior flips have observable
  end-to-end oracles. Per `.claude/rules/ui-tests.md`:
  - **ask before running XCUITest** — a class is ~75s, the full suite ~460s
  - after changing a test run `xcodebuild build-for-testing`; an app-only `build` leaves a stale bundle
    that reports `Executed 0 tests`
  - target exact methods: `-only-testing:agtermUITests/ControlPickUITests/<method>`
  - never run while the user is testing a handed-off build (they send real keyboard/mouse events)
  - palette identifiers propagate to text children; reuse `ControlPickUITests.clickPaletteRow` rather than
    a bare `firstMatch`
- e2e/Playwright: not applicable, native macOS app.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope

## Solution Overview

**Item 1** hoists the search-key decision into `agtermCore` as a small pure function next to
`pickCustomRowLabel`, rather than leaving a ternary inline in the view. This follows the #78 hoist series
and turns a 75s XCUITest oracle into a 0.2s `swift test` one. The whole reason the item exists is that an
untested inline closure in a view shipped a reachable wrong-result path.

*Design decision:* one function taking a `callerSupplied` flag, rather than two functions with the choice
left inline. Two functions would hoist the bodies and leave the *policy* — the part that was wrong —
inline and untested.

**Item 2** stays in the view: the change is one condition on an existing guard, and hoisting a predicate
for `q.isEmpty && (a || b)` would be abstraction for its own sake.

**Items 3 and 4** are ordinary control-API additions following the four-point contract.

*Design decision on `query` validation:* **do not** control-character validate `query`, matching its
neighbour `prompt`, which is unvalidated today. Both are free text rendered into a single-line
`TextField`, neither reaches a shell, and validating one of the pair would add an error string plus two
doc entries to buy asymmetry. If control characters in picker text ever matter, that is one change
covering `prompt` and `query` together, not a rider on this one.

Order matters: item 1 first because it is the safety fix, then item 2, then the two additive arguments.

## Technical Details

New host-free helper (item 1), in `agtermCore`:

```swift
/// Search keys for one palette row. Caller-supplied pickers match the label only, so a subtitle can carry
/// consequence text ("cannot be undone") without a refusal word isolating a destructive row.
public func paletteSearchKeys(title: String, subtitle: String?, callerSupplied: Bool) -> [String]
```

Returns `[title]` when `callerSupplied`, otherwise `[title, subtitle]` when a subtitle exists, else `[title]`.
`public` is required — the app target is a separate module.

Call site becomes:

```swift
filtered = fuzzyRank(query: q, items: allItems) { item in
    paletteSearchKeys(title: item.title, subtitle: item.subtitle, callerSupplied: explicitItems != nil)
}
```

Order guard (item 2):

```swift
if q.isEmpty, explicitItems != nil || controller.mode == .attention {
    filtered = allItems
    selection = filtered.isEmpty ? 0 : min(selection, filtered.count - 1)
    return
}
```

Equivalent to the current guard for every built-in path: when `explicitItems == nil` the left disjunct is
false, leaving `mode == .attention`. Dropping the old `explicitItems == nil` term is safe because it only
mattered for a pick mounted while `controller.mode` happened to be `.attention`, which now takes the
bypass anyway.

Two consequences to record so nobody "fixes" them later:

- The early `return` skips the custom-row block (:139-143). Harmless: `pickCustomRowLabel` already returns
  nil for an empty query, so that block was a no-op on this path.
- **Item 3 defeats item 2 by design.** A prefilled `--query` makes `q` non-empty, so ranking runs and
  caller order is re-sorted by score then title. Correct — the caller asked to filter — but it means the
  rename recipe (items + `--query`) does not preserve input order. Document it.

Protocol (item 3): add `ControlArgs.query: String?` beside the other pick fields **and to the explicit
public memberwise init at `ControlProtocol.swift:256-295`** (all callers use labels, so a defaulted
parameter is safe). Then `PendingPick.query: String?` defaulted nil, and
`CommandPalette.init(initialQuery:)` seeding `_query = State(initialValue: initialQuery ?? "")`.
`WindowContentView.swift:826`'s `.id(pending.id)` guarantees fresh `@State` per pick, so the initial value
takes effect; the built-in mount at :796 uses defaults and is unaffected.

Dispatcher (item 4) must distinguish absent from explicitly-empty, which the current single guard collapses:

```swift
guard let items = request.args?.items else {
    return ControlResponse(ok: false, error: "pick.open requires items")
}
guard !items.isEmpty || request.args?.allowCustom == true else {
    return ControlResponse(ok: false, error: "pick.open requires at least one item")
}
```

This mints one **new** error string, `pick.open requires items`, and narrows the existing one to the
empty-without-allow-custom case. Both facts are Task 7 doc obligations.

Behavior note to document: empty items + `--allow-custom` + no `--query` shows an empty panel until the
user types (the custom row needs a non-empty query). Esc cancels. `--query` covers the case where a
starting value exists. Also, `agtermctl pick` reads stdin unconditionally, so the no-items recipe needs
`< /dev/null` or it blocks.

## What Goes Where

- **Implementation Steps** (`[ ]`): code, tests, and documentation in this repo
- **Post-Completion** (no checkboxes): manual verification and anything outside this repo

## Implementation Steps

### Task 1: Search-key helper in agtermCore (TDD)

**Files:**
- Create: `agtermCore/Sources/agtermCore/PaletteSearchKeys.swift`
- Create: `agtermCore/Tests/agtermCoreTests/PaletteSearchKeysTests.swift`

- [x] start with `swift-testing-expert`
- [x] create `paletteSearchKeys(title:subtitle:callerSupplied:)` returning the **current** rule for every
      case (`[title, subtitle]` when a subtitle exists) — this compiles, so the next step fails on
      behavior rather than on a missing symbol
- [x] write the regression test: `fuzzyRank` over a Confirm row (label `Confirm`, subtitle
      `cannot be undone`) and a `Cancel` row, keyed via `paletteSearchKeys(callerSupplied: true)`, query
      `no` → assert the result is **empty**, i.e. `Confirm` is filtered out and never left alone and
      preselected. One-line comment naming the defect it pins. Do **not** assert `Cancel` survives — it
      does not match `no` either (see Verified during planning)
- [x] add a second case proving the label path still works: query `can` → only `Cancel`
- [x] run `cd agtermCore && swift test`, confirm both FAIL on behavior
- [x] flip the implementation to return `[title]` when `callerSupplied`, and add the godoc
- [x] write unit tests: caller-supplied returns label only; built-in returns label plus subtitle; built-in
      with nil subtitle returns label only
- [x] re-run `cd agtermCore && swift test` — all pass before task 2

### Task 2: Wire the palette to the helper

**Files:**
- Modify: `agterm/Views/Palette.swift`
- Modify: `agtermUITests/ControlPickUITests.swift`

- [x] start with `swiftui-expert`
- [x] replace the inline keys closure at `updateFiltered()` (:136-138) with `paletteSearchKeys(...)`
- [x] update the `updateFiltered()` doc comment at :124-125 — it currently claims matching is on "title or
      subtitle", which is no longer true for caller-supplied pickers
- [x] confirm the built-in palettes still match on their subtitle (for `.sessions` that subtitle is
      `"<workspace> · <detail>"`, `AppActions+Palette.swift:170-171`); the real net is the Task 1
      host-free case, since nothing tests the built-in path end-to-end
- [x] add a UI test mirroring the Task 1 oracle: pick with a subtitled Confirm row plus Cancel, type `no`,
      assert no row is listed and Enter does nothing
- [x] `xcodebuild build-for-testing`, then ask before running
      `-only-testing:agtermUITests/ControlPickUITests/<method>` — must pass before task 3

### Task 3: Preserve caller-supplied order on an empty query (TDD)

**Files:**
- Modify: `agterm/Views/Palette.swift`
- Modify: `agtermUITests/ControlPickUITests.swift`

- [x] start with `swiftui-expert`
- [x] write the failing UI test first: open a pick with items in non-alphabetical order (e.g. `zebra`,
      `alpha`) and press Enter without typing; assert the returned result is `zebra` at index 0. Prefer
      this over asserting which row renders first — there is no cheap AX oracle for visual order
- [x] `build-for-testing`, run that one method, confirm it FAILS (`alpha` currently sorts first)
- [x] widen the guard per Technical Details so explicit picks skip ranking on an empty query
- [x] update the attention-only comment at :128-130 to describe both bypass cases
- [x] add attention-path coverage: the `.attention` palette's empty-query order (blocked → active →
      completed, newest first) must survive the widened guard. **There is no such test today** — that
      guard is entirely uncovered and this task modifies it, so the coverage is part of this task
- [x] verify a non-empty query still ranks normally for explicit picks
- [x] `build-for-testing`, then ask before running the affected methods — must pass before task 4

### Task 4: Protocol and dispatcher for `--query`

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Sources/agtermCore/Pick.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher+Pick.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherPickTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/PickTests.swift`

- [x] start with `swift-testing-expert`
- [x] add `ControlArgs.query: String?` with a doc comment beside the other pick fields, **and to the
      explicit memberwise init at :256-295**
- [x] add `PendingPick.query: String?`, defaulted nil so existing call sites are unaffected
- [x] pass it through in `dispatchPickCommand`. Per the Solution Overview decision, add **no**
      control-character validation, matching `prompt`
- [x] write dispatcher tests: query reaches `PendingPick`; omitted query stays nil
- [x] extend the existing `ControlProtocolTests.pickCommandsRoundTrip` rather than adding a parallel test,
      and add a nil-omission test for `query`
- [x] run `cd agtermCore && swift test` — must pass before task 5

### Task 5: CLI flag and palette prefill for `--query`

**Files:**
- Modify: `agtermCore/Sources/agtermctlKit/MiscCommands.swift`
- Modify: `agterm/Views/Palette.swift`
- Modify: `agterm/Views/WindowContentView.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/CommandsTests.swift`
- Modify: `agtermUITests/ControlPickUITests.swift`

- [x] start with `swiftui-expert` for the view half
- [x] add `@Option(name: .long, help:) var query: String?` to `Pick.Open` and pass it into `ControlArgs`
- [x] add `initialQuery` to `CommandPalette.init`, seeding `_query = State(initialValue: initialQuery ?? "")`
- [x] pass `pending.query` through from `pickPaletteOverlay`
- [x] write CLI tests: `--query` reaches the built request; its absence leaves it nil
- [x] add a UI test: a pick opened with a prefilled query shows the field populated and the list filtered
- [x] `swift test`, then `build-for-testing` and ask before the UI method — must pass before task 6

### Task 6: Accept an empty item list with `--allow-custom`

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher+Pick.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherPickTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift`
- Modify: `agtermUITests/ControlPickUITests.swift`

- [x] start with `swift-testing-expert`
- [x] **amend the existing test `openRejectsMissingAndEmptyItemsWithoutCallingHost`
      (`ControlDispatcherPickTests.swift:7-18`)** — it asserts missing and empty produce the *same* string,
      which this task deliberately changes. Split it and rename it accordingly
- [x] add a `ControlArgs` round-trip test pinning `[]` as distinct from `nil` (verified to hold today; the
      dispatcher now depends on it and nothing else asserts it)
- [x] split the guard per Technical Details, keeping `pick.open requires at least one item` for the
      empty-without-allow-custom case and minting `pick.open requires items` for absent
- [x] write tests: empty + allowCustom accepted; empty without allowCustom rejected with the unchanged
      string; absent rejected with the new string; the 1000-item cap and other validations still apply
- [x] add a UI test covering empty items + `--allow-custom` + `--query`, ending in a custom result
- [x] `swift test`, then `build-for-testing` and ask before the UI method — must pass before task 7

### Task 7: Documentation across every mirrored surface

**Files:**
- Modify: `README.md`
- Modify: `plugins/agterm/skills/agterm/reference.md`
- Modify: `plugins/agterm/skills/agterm/SKILL.md`
- Modify: `plugins/agterm/skills/agterm/examples.md`
- Modify: `site/commands.html`
- Modify: `site/docs.html`

- [x] README native-picker section: `--query`, the relaxed empty-list rule, caller order preserved on an
      empty query, and that only labels are matched
- [x] `reference.md` pick section (~:686-700): the same four points; correct "An empty list is rejected."
      at :695; record both error strings (`pick.open requires items` for absent,
      `pick.open requires at least one item` for empty-without-`--allow-custom`)
- [x] `SKILL.md` pick entry: add `--query` to the invocation line (leave the 71-command count alone)
- [x] `examples.md` (pick section ~:697-704): add the rename-dialog recipe — empty items +
      `--allow-custom` + `--query`, with `< /dev/null` so it does not block on stdin
- [x] `site/commands.html` pick section (~:1725-1790): `--query` in the usage line and arguments, and
      update the error-string list at :1768-1776 for **both** strings
- [x] `site/docs.html` (~:1194-1224): mirror the README changes
- [x] note in README/reference that a prefilled `--query` re-ranks, so it does not preserve caller order
- [x] confirm the command count is unchanged everywhere and `SkillInstallTests` still passes
- [x] run `cd agtermCore && swift test` — must pass before task 8

### Task 8: Verify acceptance criteria

- [x] typing a refusal word in a confirm pick can no longer leave the destructive row alone and preselected
      (`PaletteSearchKeysTests.refusalQueryLeavesNoRowInACallerSuppliedConfirm`,
      `ControlPickUITests.testRefusalQueryLeavesNoRowInACallerSuppliedConfirm`)
- [x] caller-supplied order survives to the Enter-on-open result
      (`ControlPickUITests.testEmptyQueryEnterPicksTheCallerSuppliedFirstItem`, with
      `testNonEmptyQueryStillRanksCallerSuppliedRows` and
      `testAttentionPaletteEnterKeepsStatusOrderOnEmptyQuery` bounding the bypass)
- [x] `--query` prefills and filters on open (`ControlPickUITests.testPrefilledQueryOpensPopulatedAndFiltered`)
- [x] empty items + `--allow-custom` + `--query` behaves as a rename prompt and returns a custom result
      (`ControlPickUITests.testEmptyItemsWithAllowCustomActAsAPrefilledPrompt`)
- [x] none of the declined items crept in (no empty-answer commit, no message pane, no correlation tag)
- [x] run `cd agtermCore && swift test` — 2074 tests, 83 suites, all pass
- [x] run `make test-app` — 87 tests, 0 failures
- [x] `build-for-testing`, then ask before running the full `agtermUITests/ControlPickUITests` class —
      18 tests, 0 failures
- [x] run `make lint` — zero findings required

### Task 9: [Final] Update rules and close out

- [x] update `.claude/rules/control-api.md` picker bullets for the new validation and matching rules
- [x] update `.claude/rules/menu-actions.md` — its palette contract says "sort by score then title" and
      names attention as the only empty-query exception; both are changed by items 1 and 2
- [x] update CLAUDE.md — nothing added; no new pattern emerged. The host-free hoist, the cross-surface
      contract, and the mirrored doc surfaces are all already stated there, and the picker specifics belong
      to the two path-scoped rules files
- [x] plan move (handled by the orchestrator after review phases)

## Post-Completion

*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Manual verification:**

- Drive a real picker from a shell against an isolated Debug instance (never the default socket): confirm
  the confirm-row trap is closed by typing several refusal words, and that a long caller-ordered list opens
  on the intended first row.
- Confirm the empty-items panel reads acceptably before the user types, since nothing is listed until then.

**Observed, deliberately not fixed here:**

- `ControlArgs.prompt` accepts control characters (`ControlDispatcher+Pick.swift:22-27` validates item text
  only). Left alone for parity with the new `query`; a fix should cover both fields in one change.

**External:**

- Reply on discussion #270 once merged, so the reporter can drop the ported ranker copy from his test suite
  and the ANSI input dialog.
- `CHANGELOG.md` is release-only per CLAUDE.md; this PR does not touch it.

---

Smells pre-check: skipped — non-Go project
