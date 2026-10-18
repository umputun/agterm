# Ask dialog text input and choice list

## Overview
- `ask.open` gains two content variants on top of the existing title/message/buttons dialog:
  a text input (one-line or multiline) and a choice list (radio buttons, or checkboxes with `multiple`).
- Callers get a typed string or the selected item ids back through the existing `ask result` path,
  so scripts and agents can ask for a commit message, a name, or a subset of options without a custom
  overlay program.
- Both variants reuse the whole ask lifecycle: session and window slots, terminal and gui styles,
  pane anchoring, `AskRegistry` retention, cancel and teardown, remote presenter handover, CLI polling
  and exit codes. Plain button asks keep their exact current behavior.

## Context (from discovery)
- host-free model and validation: `agtermCore/Sources/agtermCore/Ask.swift` (`PendingAsk`,
  `AskRegistry`, `AskNavigation`), `ControlAsk.swift` (`ControlAskButton`, `ControlAskResult`),
  `ControlProtocol.swift` (`ControlArgs`), `ControlDispatcher+Ask.swift` (validation),
  `Session.swift` (terminal slot `askPending`, `openAsk`/`resolveAsk`), `Pick.swift`
  (`PickController.pendingAsk`, gui slot)
- CLI: `agtermCore/Sources/agtermctlKit/AskCommands.swift`, `MiscCommands.swift` (`ModalCommandRunner`,
  exit codes via `SocketClient.askExitCode`)
- remote: `PresentationFrames.swift` (`PresentationAsk`, `PresentationAskAnswer`), `PresentationHub.swift`
  (`supportedKinds`, hello negotiation, `sendToPresenter`), `AppStore+RemoteAsk.swift` (origin handover and
  answer validation), `AppStore+RemotePresentation.swift` (replica build), `RemotePresentationClient.swift`
- app: `agterm/Views/AskDialogView.swift` (`SessionAskInput`, `SessionAskOverlay`, `AskDialogView`,
  `AskKeyCatcher`), `agterm/AppActions+Focus.swift` (field-editor resign, `escapePendingSessionAsk`),
  `agterm/AppActions.swift` (Cmd-W ladder), `agterm/Control/ControlServer+Ask.swift`
- verified constraints the design answers:
  - `SessionAskInput.ownsInput` refuses whenever the window's first responder is any `NSText`
    (`AskDialogView.swift:58`), so a text editor inside the dialog would lose its own key ownership
  - `SessionAskOverlay` drops `AskDialogView` while the ask is hidden but pending (`:92`), so view
    `@State` would lose a draft on session switch, zoom, or a hidden pane
  - `AskKeyCatcher.key(for:)` maps Up/Down to the same intents as Tab/Left/Right (`:465`)
  - `escapePendingSessionAsk` reaches a terminal ask only through the key catcher's `canFocus`
    (`AppActions+Focus.swift:61`)
  - `ask.request` is not a negotiated presentation kind (`PresentationHub.supportedKinds`), so an older
    presenter decodes a form request, ignores the new fields, and answers with a bare button
- tests: `AskTests`, `ControlDispatcherAskTests`, `AskCommandsTests`, `AppStoreRemoteAskTests`,
  `PresentationFramesTests`, `PresentationHubTests`, `RemotePresentationClientTests`,
  `RemotePresentationStateTests` (host-free); `AskDialogViewTests`, `ControlServerAskTests` (hosted);
  `ControlAskUITests` (XCUITest)

## Development Approach
- **testing approach**: Regular, with tests written in the same task as the code they cover
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
- run tests after each change, scoped to what changed (`swift test --filter`, `-only-testing:`); the full
  gates (`make build`, `swift test`, `make test-app`, `make lint`) run once, at the end
- maintain backward compatibility: a plain button ask's wire shape, behavior and result are unchanged

## Testing Strategy
- **unit tests**: host-free Swift Testing in `agtermCore/Tests` for model, validation, navigation, draft
  state, CLI parsing/output and presentation negotiation/round trips
- **hosted tests**: `agtermTests/AskDialogViewTests` and `ControlServerAskTests` for focus ownership,
  editor key handling and server wiring
- **UI tests**: targeted `ControlAskUITests` methods for typing into a focused field, choosing items with
  the keyboard, and draft survival across a session switch; run with `-only-testing:` per method

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope
- keep plan in sync with actual work done

## Solution Overview
- one optional form on `PendingAsk`: `input` (line or multiline, prefill, placeholder) or `choices`
  (items, `multiple`, initially checked ids), mutually exclusive, normalized host-free in the dispatcher
- a `cancelButton` role: answering that button resolves `escaped` (exit 3) with no payload, exactly as
  Esc does. With a form and no caller buttons, the dialog gets `ok`=OK (default) and `cancel`=Cancel
  (cancel role). Without a form a caller may still name a `cancelButton`; plain asks without it are
  unchanged
- drafts (typed text, item cursor, checked set) live with the slot owner keyed by ask id, so hiding and
  revealing the dialog keeps them; resolution clears them. A remote handback restores the initial values
- the dialog's text editor becomes first responder, and keyboard ownership recognizes it as the dialog's
  own editor rather than an unrelated field; choice lists keep the key catcher with split item/button intents
- a negotiated `ask.form` presentation capability gates handing a form ask (or a `cancelButton` ask) to a
  presenter; without it the ask stays on the origin

## Technical Details

**Wire arguments on `ask.open`** (all optional; `value` reuses the existing `ControlArgs.value` of
`overlay.submit` with its description widened, the rest are new fields):
- `input`: `line` | `multiline`
- `value`: prefill text; `placeholder`: hint text shown in an empty field
- `choices`: `[{id, label, subtitle?}]`, 1...50 items, unique ids, nonempty one-line labels; `subtitle` is an
  optional description that may span lines (the name matches `pick` items)
- `multiple`: `true` for checkboxes; absent or false for radio buttons
- `checked`: ids initially selected; radio accepts at most one
- `cancelButton`: id of a supplied button that resolves `escaped`
- `buttons` becomes optional when `input` or `choices` is present; it stays required otherwise

**Validation errors** (host-free, before any host state changes):
- `input and choices are exclusive`, `unknown input`, `ask choices must be 1 to 50`
- `value`/`placeholder`/`checked`/`multiple` without the form they belong to: `<arg> requires input` or
  `<arg> requires choices`
- `ask choice ids must be unique`, `ask choice label must not be empty`
- `unknown checked choice: <id>`, `ask checked ids must be unique`, `radio choices accept one checked id`
- `unknown cancel button: <id>`; the cancel button may also be the default, so a caller can make
  cancellation the safe Return
- `ask input does not take hotkeys` when any button has a hotkey and `input` is present
- control characters rejected in placeholder, choice labels and a one-line value; a multiline value
  allows newline and tab, the same set a paste can put into the multiline editor's answer; a choice
  `subtitle` allows newline only
- `ask text too long (max 65536 bytes)` for `value` over 64 KiB UTF-8; the editor enforces the same cap
- the text cap does not bound the whole presentation frame (title and message are unbounded and the local
  request line allows 1 MiB), so remote handover encodes the `PresentationAsk` first and keeps a form ask
  whose frame would exceed `PresentationCodec.maxFrameBytes` on the origin. An answer stays inside the
  frame only by reservation: an input ask is handed over only when the encoded answer with the longest
  JSON-encoded button id and twice the text cap (escaping only doubles newline, tab, quote and backslash) also fits;
  `selected` can only name ids from a request that already fit

**Result payload** (`ControlAskResult`, new optional fields):
- `text`: the field's content on an answered non-cancel button, whitespace and newlines preserved
- `selected`: checked ids in caller order on an answered non-cancel button; radio always carries one,
  multiple may be empty
- `escaped`, `cancelled` and the cancel button carry neither
- CLI: `{"result":"answered","id":"ok","label":"OK","index":0,"text":"fix the bug"}`; exit codes unchanged

**Keys**:
- input, one-line: Return answers the highlighted button (default `ok`)
- input, multiline: Return inserts a newline; Cmd-Return answers the highlighted button, handled by the
  editor itself, never a window or global shortcut
- input, both: Tab/Shift-Tab move the button highlight through the editor delegate's `doCommandBy`
  (`insertTab:`/`insertBacktab:`) while focus stays in the field; arrows, selection, paste, undo and IME
  stay native; Esc escapes. No submit or escape path resolves while the editor has marked text
- choices: Up/Down move the item cursor, Space picks a radio or toggles a checkbox, Tab/Shift-Tab and
  Left/Right move the button highlight, Return answers it, button hotkeys keep working. The item cursor
  starts on the first checked item, else the first item; radio starts checked on `checked` or the first item
- the editor accepts no text past the 64 KiB cap

**Sizing**:
- `width` keeps meaning the panel width only; height follows content up to the existing cap
  (anchor height minus two cells)
- a multiline field prefers about five lines and grows with its text; a long choice list scrolls inside
  its own region while title, message and buttons stay pinned
- when title, message and buttons alone exceed a short pane, the five-line preference shrinks and the
  whole panel scrolls, as today

**Rendering**:
- terminal style: monospace field with theme colors and a theme-foreground outline; items as `( )`/`(•)`
  or `[ ]`/`[x]`; the cursor fills only the marker and label like a highlighted button, never the
  subtitle, which would vanish in its dimmed foreground over a foreground fill
- gui style: system text field/text view, native radio and checkbox appearance, accent-colored cursor row
- a choice `subtitle` sits under its label, wrapped, in the message's dimmed color (terminal) or the
  secondary color (gui); no italic, since the terminal font may lack it. URLs in it are plain text, not links

**Remote**:
- `PresentationAsk` gains the form and `cancelButton`; `PresentationAskAnswer` gains `text` and `selected`
- `ask.form` joins `PresentationHub.supportedKinds`; `presentAskRemotely` checks the current presenter's
  negotiated kinds and the encoded frame size before `openAsk` claims the slot, and keeps a form or
  `cancelButton` ask local when either check fails
- the replica's answer callback (`AppStore+RemotePresentation`, today `button: result.id` only) forwards
  `text`/`selected`; the replica's cancel button resolves `escaped`, which already travels as `button: nil`
- `resolveRemoteAsk` validates the payload against the stored ask: known and unique ids, radio exactly one,
  canonical caller order, text cap, the payload matching the form kind, no payload on a dismissal, and
  applies the cancel role itself
- a handback starts the dialog again from its initial values

**Not added**: no new tree read-back (the session node keeps `ask: {id, pane?}`), no events, no drafts
in the tree.

## What Goes Where
- **Implementation Steps** (`[ ]` checkboxes): tasks achievable within this codebase - code changes, tests,
  documentation updates
- **Post-Completion** (no checkboxes): items requiring external action - manual testing, changes in
  consuming projects, deployment configs, third-party verifications

## Implementation Steps

### Task 1: Form model, validation, cancel role and slot drafts (host-free)

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Ask.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlAsk.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher+Ask.swift`
- Modify: `agtermCore/Sources/agtermCore/Session.swift`
- Modify: `agtermCore/Sources/agtermCore/Pick.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AskTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherAskTests.swift`

- [x] add the form (`input` or `choices`) and `cancelButton` to `PendingAsk`, and `text`/`selected` to
      `ControlAskResult`, keeping a plain ask's encoded shape unchanged
- [x] extend `ControlArgs` with the new wire fields and validate them in `dispatchAskOpen` per Technical
      Details, generating `ok`/`cancel` buttons when a form has none
- [x] add a host-free draft value (text, item cursor, checked set) owned by `Session` for terminal asks and
      `PickController` for gui asks, keyed by ask id, cleared on every resolution path
- [x] build answered results from the draft in one host-free place: cancel role resolves `escaped` with no
      payload, others attach `text` or `selected` in caller order
- [x] add choice navigation (item cursor up/down, toggle/pick) beside `AskNavigation`, separate from button
      movement
- [x] write tests: every validation error (duplicate checked ids included), default buttons, cancel role
      and cancel-as-default, payload shaping, radio cardinality, draft survival and clearing, plain-ask
      encoding unchanged, `value` at exactly 65536 and 65537 UTF-8 bytes with multibyte text
- [x] run `swift test --filter` for the touched suites - must pass before next task

### Task 2: CLI flags and result output

**Files:**
- Modify: `agtermCore/Sources/agtermctlKit/AskCommands.swift`
- Modify: `agtermCore/Sources/agtermctlKit/MiscCommands.swift` (only if result printing needs it)
- Modify: `agtermCore/Tests/agtermctlKitTests/AskCommandsTests.swift`

- [x] add `--input line|multiline`, `--value`, `--placeholder`, repeatable `--choice ID=LABEL`,
      repeatable `--choice-subtitle ID=TEXT`, `--multiple`, repeatable `--checked ID`, `--cancel ID`;
      `--button` optional with a form
- [x] mirror the host-free validation messages client-side where `validate()` already does so
- [x] print `text`/`selected` in the blocking and one-shot result JSON; the cancel button exits 3
- [x] write tests: request building for each flag, missing-form errors, result output, exit codes
- [x] run `swift test --filter AskCommands` - must pass before next task

### Task 3: Remote presentation of form asks

**Files:**
- Modify: `agtermCore/Sources/agtermCore/PresentationFrames.swift`
- Modify: `agtermCore/Sources/agtermCore/PresentationHub.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+RemoteAsk.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+RemotePresentation.swift`
- Modify: `agtermCore/Sources/agtermCore/RemotePresentationClient.swift` (only if hello kinds need it)
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreRemoteAskTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/PresentationFramesTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/PresentationHubTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/RemotePresentationStateTests.swift`

- [x] carry the form and `cancelButton` in `PresentationAsk`, and `text`/`selected` in
      `PresentationAskAnswer`; build the replica's `PendingAsk` with them and forward the payload from the
      replica's answer callback
- [x] add `ask.form` to `supportedKinds` and a hub query for the presenter's negotiated kinds; check it and
      the encoded frame size in `presentAskRemotely` before the slot is claimed, keeping the ask local otherwise
- [x] validate the answer payload on the origin against the stored ask and apply the cancel role there
- [x] write tests: old presenter keeps the ask local, an oversized form frame keeps the ask local, an input
      ask whose longest button id plus the reserved text answer cannot fit stays local, a round
      trip for text and selections through the replica callback (not only synthetic frames), rejected
      payloads (unknown or duplicate id, zero or two radio ids, oversize text, payload of the wrong form
      kind, payload on dismissal), quotes/backslashes/newlines/multibyte text encoded within the frame,
      handback reset
- [x] run `swift test --filter` for the touched suites - must pass before next task

### Task 4: Dialog rendering, editor, choice list and sizing

**Files:**
- Modify: `agterm/Views/AskDialogView.swift`
- Create: `agterm/Views/AskFormViews.swift`
- Modify: `agterm/Views/WindowContentView.swift` (gui `askDialogOverlay`: bind `PickController`'s draft and
  use the shared result builder in place of its button-only result)
- Modify: `agterm/Control/ControlServer+Ask.swift`
- Modify: `agtermTests/AskDialogViewTests.swift`
- Modify: `agtermTests/ControlServerAskTests.swift`

- [x] add AppKit-backed one-line and multiline editors (`NSTextField`/`NSTextView` representables) bound to
      the slot draft, with the Tab/Return/Cmd-Return/Esc handling and the marked-text guard from Technical
      Details, and the 64 KiB input cap
- [x] add the choice list in both styles with item cursor, Space handling, and scroll-to-cursor in its own
      scroll region; split Up/Down from Tab/Left/Right in `AskKeyCatcher`
- [x] lay out pinned title/message/buttons with the scrolling middle region and the outer-scroll fallback
      for short panes; multiline prefers about five lines
- [x] pass the form through `ControlServer+Ask` for both styles and the remote takeback path
- [x] write hosted tests on the editor and list in isolation: Return/Cmd-Return/Tab behavior, marked-text
      guard, input cap, choice keys, draft binding, short-pane fallback; focus at open inside a live session
      is Task 5's acceptance, since it needs the ownership change
- [x] run the touched hosted tests with `-only-testing:` - must pass before next task

### Task 5: Keyboard ownership with an in-dialog editor

**Files:**
- Modify: `agterm/Views/AskDialogView.swift`
- Modify: `agterm/AppActions+Focus.swift`
- Modify: `agterm/AppActions.swift`
- Modify: `agterm/Ghostty/GhosttySurfaceView.swift` (terminal focus deferral, `:822`)
- Modify: `agterm/Views/HtmlOverlayRegistry.swift` (HTML focus deferral, `:687`)
- Modify: `agterm/Views/HtmlOverlayView.swift` (its `firstResponder is NSText` guard, `:198`)
- Modify: `agterm/Ghostty/HudLinkClick.swift` (HUD click coverage, `:75`)
- Modify: `agtermTests/AskDialogViewTests.swift`
- Modify: `agtermUITests/ControlAskUITests.swift`

- [x] register one dialog input owner per ask that knows its own editor, so `ownsInput` and
      `blocksTerminalFocus` treat that editor as the dialog's and still yield to unrelated editors, palettes,
      rename, picks and the quick terminal
- [x] keep `resignDismissedFieldEditor` from resigning the dialog's editor, and route Cmd-W and Esc to the
      owning form ask before the rest of the close ladder
- [x] move terminal focus deferral, HTML focus deferral and HUD click coverage onto the input owner;
      clicking the covered region focuses the editor or the choice list
- [x] write hosted tests for ownership, Cmd-W, typing, Return/Cmd-Return/Tab/Esc, focus at open, draft
      survival and a real layout swap; UI test: check choice items by keyboard and read the selection
- [x] run the touched hosted tests and the choice UI test with `-only-testing:` - must pass before next task
- ⚠️ XCUITest text typing (`typeText`) on this desktop delivered every key with Command set: Cmd-H hid the
  test app and the rest reached the live agterm (Cmd-O). The four typing UI tests were removed on the
  user's decision; typing, Return, Cmd-Return, Tab, Esc, Cmd-W, cap, composition, draft survival and a
  real layout swap are covered by hosted tests that call the editor directly. The choice-list UI test stays.
- ➕ review fixes: cap refuses an over-budget edit before it happens (composition included, one-line field
  through its own field editor), Cmd-W keeps a composing ask open, multiline height follows laid-out
  text, and a replaced editor takes focus that fell back to the window

### Task 6: Contract, user docs and agent skill

**Files:**
- Modify: `.claude/rules/control-api.md`
- Modify: `site/commands.html`
- Modify: `site/docs.html`
- Modify: `plugins/agterm/skills/agterm/SKILL.md`
- Modify: `plugins/agterm/skills/agterm/reference.md`

- [x] state the form contract once in `control-api.md`: arguments, defaults, cancel role, payloads, keys,
      sizing, drafts and handback reset, `ask.form` negotiation, and that drafts are not tree state
- [x] mirror the new arguments and result fields in `site/commands.html`; add a short text-input and choice
      example to `site/docs.html`
- [x] add the variants to the skill reference and a SKILL.md trigger ("ask for text", "let the user pick
      items") so agents find them unprompted

### Task 7: Verify acceptance criteria
- [x] verify a one-line and a multiline prompt return typed text, with the field focused at open
- [x] verify custom button labels work and the default OK/Cancel appear without `--button`
- [x] verify radio returns one id, checkboxes return any subset in caller order, Cancel/Esc return nothing
- [x] verify items with multi-line subtitles render dimmed under their labels, stay readable on the cursor
      row, and the cursor scrolls them in, using a 50-item list with three-line subtitles
- [x] verify a long list scrolls with buttons pinned and `width` affects width only
- [x] run full gates once: `make build` (Release), `cd agtermCore && swift test`, `make test-app`, `make lint`
- [x] run `lsappinfo list | grep -A4 agterm.debug` after the hosted and UI runs
- ➕ the 50-item check found a long list opening at the top with the checked cursor row out of view: the
  opening row now goes through `scrollPosition(id:)`, pinned by `testALongListOpensScrolledToTheCheckedItem`
- ⚠️ one full `swift test` run failed in `realHostStartupReplyAndClientlessControl` with the DA1-in-DA2
  signature of `docs/backlog/da-query-answered-twice-before-attach-init.md`; the same-tree retry passed.
  Not fixed here: the zmx patch it needs is deferred in that backlog item

### Task 8: [Final] Update documentation
- [x] update README.md only if the control-API demo should show the new variants
- [x] update CLAUDE.md if new patterns were discovered
- [x] move this plan to `docs/plans/completed/`

## Post-Completion
*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Manual verification** (unverified until performed; moving the plan to `completed/` does not mean these
passed):
- IME composition (Japanese/Chinese input) in both editors: Return and Esc stay with the composition
- a form ask on an attached remote session against a viewer running this build and one running the
  previous release (old viewer: the ask stays on the origin)
- visual check of both styles in light and dark themes in an isolated Debug instance

**External system updates**:
- the `agterm-linux` fork consumes `agtermCore`; new public fields are additive, but its dialog renderer
  needs the form to show these asks

Smells pre-check: skipped — non-Go project
