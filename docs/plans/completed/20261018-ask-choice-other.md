# Free-form "other" row for ask choice lists

## Overview
- `agtermctl ask --choice ... --other PLACEHOLDER` adds one optional single-line text row after the caller's
  items, in radio and checkbox lists alike. The placeholder is the row's label while it is empty.
- Typing a non-blank value enables and selects the row; clearing it (or leaving only spaces) disables and
  unselects it. Once enabled, the row navigates and toggles like any other item.
- The typed text comes back in the answer's existing `text` field; `selected` keeps only caller ids.

## Context (from discovery)
- Model and validation: `agtermCore/Sources/agtermCore/Ask.swift` (`AskChoiceForm`, `AskDraft`,
  `PendingAsk.answer`, `validatedAnswer`), `ControlDispatcher+Ask.swift` (`parseAskChoices`),
  `ControlProtocol.swift` (`ControlArgs`), `agtermctlKit/AskCommands.swift`.
- Remote: `PresentationFrames.swift` (`PresentationAsk.fitsFrames`, `needsFormSupport`),
  `PresentationHub.swift` (supported kinds), `AppStore+RemoteAsk.swift`, `AppStore+RemotePresentation.swift`.
- View and focus: `agterm/Views/AskFormViews.swift` (`AskChoiceList`, `AskTextEditor`, `AskEditorBox`),
  `agterm/Views/AskDialogView.swift` (`KeyCatcherView.grabFocus`, `onAttach`, choice keys).
- Contract and docs: `.claude/rules/control-api.md`, `site/commands.html`, `site/docs.html`,
  `plugins/agterm/skills/agterm/{SKILL.md,reference.md}`.

## Development Approach
- **testing approach**: TDD for model, validation, CLI and remote rules; hosted tests for editor, focus and
  marker behavior. Never XCUITest typing (see `.claude/rules/ui-tests.md`).
- complete each task fully before moving to the next; all touched tests pass before the next task
- every plan and result goes to the codex peer before building and after
- update this plan when scope changes

## Testing Strategy
- host-free `swift test` suites for draft transitions, answers, validation, CLI, remote gating and frame budgets
- hosted `agtermTests` for the row's editor focus, marker toggling, navigation and scrolling
- final gates once: `make release`, `cd agtermCore && swift test`, `make test-app`, `make lint`

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix, blockers with ⚠️ prefix

## Solution Overview
- Behavior is decided by Eugene and reviewed by codex:
  - the row is enabled iff its text has a non-whitespace character; enabled and selected are separate states
  - an edit leaving non-blank text selects the row; a blank result unselects and disables it
  - radio: when the row takes over from a caller item, that item is remembered as the previous pick; later
    keystrokes do not recapture it. A blank edit restores it only while the row is the pick (the first item
    when none was picked); clearing the retained text of an unselected row leaves the current pick alone.
    Picking another item unselects the row and keeps its text. Clicking or Space on an already picked
    caller radio row, and clicking the marker of an already picked radio free-form row, do nothing, so a
    radio list always holds exactly one pick. Space on the free-form row is always text.
  - checkbox: the row's marker toggles like any item while enabled; unchecking keeps the text
  - text is returned as typed; whitespace only decides enabled/blank
- One free-form row, appended after the 1...50 caller items, with an internal identity that cannot collide
  with caller ids; no synthetic id in `selected`.
- The row's real one-line field editor holds the keyboard only while the list cursor is on that row:
  printable keys and Space are text, Left/Right move the caret, Up/Down return to the list, Return answers,
  Tab moves the button highlight, Esc follows the composition guard. Elsewhere the key catcher keeps keys.
  The row editor's `doCommandBy` turns moveUp/moveDown into `onKey(.up/.down)` after the marked-text guard;
  only that editor does this, so the standalone input fields keep native arrows. Down on the last row
  clamps, as list navigation does today. Focus follows the cursor: crossing onto or off the row hands
  focus to the desired target, compared by identity, keeping the unrelated-responder, window and
  composition guards.
- Remote presenters get these asks only when they advertise a new `ask.other` kind; an `ask.form`-only
  presenter would drop the row, so the ask stays on the origin.

## Technical Details
- `AskChoiceForm.other: String?` (placeholder; nil means no row). Validation: requires choices, non-blank,
  no control characters, same length rule as a choice label.
- `ControlArgs.other: String?`; CLI `--other PLACEHOLDER`, rejected without `--choice`.
- `AskDraft` for a choice form with `other`: `text` holds the row's text (line-mode cap and control rule),
  `otherSelected`, `otherEnabled` (derived), `previousPick` for radio fallback; cursor range covers the row
  at index `choices.count`.
- Answer: `selected` always present for a choice answer; `text` present iff the row is selected.
  Radio: exactly one of one id or text. Checkbox: ordered subset plus optional text.
  `validatedAnswer` refuses text without an `other` row, blank text, text failing the line-mode control rule
  or the cap, and radio answers with both or neither.
- `fitsFrames`: checkbox worst case is every caller id selected plus the widest escaped text; radio worst
  cases are the widest id alone and the text alone; every answer button, widest counters.
- Tree read-back: no draft state, as for the other forms.

## What Goes Where
- Implementation Steps: code, tests, docs in this repo.
- Post-Completion: manual IME and mixed-version remote checks.

## Implementation Steps

### Task 1: Model, draft transitions, answers and validation (host-free)

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Ask.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher+Ask.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AskTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherAskTests.swift`

- [x] write failing tests for draft transitions: typing non-blank selects, blank unselects and disables,
      leading space stays unselected, radio B -> row -> more typing -> clear restores B, B -> row -> pick C ->
      clear retained text keeps C, then edit row again -> clear restores C, no initial pick falls back to the
      first item, caller radio re-toggle no-op, checkbox toggle while enabled and no-op while blank, unchecked
      non-blank row keeps its text, cursor reaches the row after 50 caller items and clamps on it
- [x] write failing tests for answers and `validatedAnswer`: radio id-or-text with `selected: []` for text,
      checkbox ids plus text, raw leading/trailing whitespace returned, unchecked row omits text, Cancel/Esc
      carry neither field, caller id literally `other`, text without a row, blank text, control characters,
      cap; one blankness rule shared by draft and validation
- [x] write failing dispatcher tests for `other` parsing and its errors
- [x] add `AskChoiceForm.other`, draft state and transitions, answer construction, validation, `ControlArgs.other`
- [x] run the touched suites - must pass before Task 2

### Task 2: CLI flag

**Files:**
- Modify: `agtermCore/Sources/agtermctlKit/AskCommands.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/AskCommandsTests.swift`

- [x] write failing tests for `--other` mapping, the without-`--choice` error, and output with `text`
- [x] add `--other PLACEHOLDER` and help text
- [x] run the touched suites - must pass before Task 3

### Task 3: Remote gating and frame budget

**Files:**
- Modify: `agtermCore/Sources/agtermCore/PresentationFrames.swift`
- Modify: `agtermCore/Sources/agtermCore/PresentationHub.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+RemoteAsk.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+RemotePresentation.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreRemoteAskTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/PresentationHubTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/RemotePresentationStateTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/PresentationFramesTests.swift`

- [x] write failing tests: an `ask.form`-only presenter keeps an `other` ask local, a presenter advertising
      `ask.form` and `ask.other` receives it, remote answers with text are applied and refused per Task 1 rules,
      checkbox frame boundary with all ids plus text, radio id-only and text-only shapes
- [x] write failing replica tests (real replica draft -> callback -> origin answer) and codec round trips with
      `other` present and old choice payloads without it
- [x] add the `ask.other` kind, the gate before claiming the remote slot, replica and answer forwarding of
      `other`/`text`, and the `fitsFrames` shapes
- [x] run the touched suites - must pass before Task 4

### Task 4: Row rendering, focus and keys

**Files:**
- Modify: `agterm/Views/AskFormViews.swift`
- Modify: `agterm/Views/AskDialogView.swift`
- Modify: `agterm/AppActions+Focus.swift` (only if the composition guard needs the row editor)
- Modify: `agtermTests/AskDialogViewTests.swift`

- [x] write failing hosted tests: initial focus on an ordinary row stays on the catcher although the field
      exists, cursor crossings move focus both ways, Up/Down from the field return to the list, Space and
      letters type without firing button hotkeys, leading Space stays editable but unselected, Return answers
      with `text`, checkbox marker click toggles while enabled, radio marker click picks an enabled unpicked
      row and does nothing on a picked one, any marker is inert while blank, a click in the field does not
      toggle, a checkbox uncheck survives Tab, focus changes and remount, composition keeps Up/Down/Return/Esc
      native, the row is reached and scrolled into view after 50 items, draft survives a real layout swap;
      waits use the bounded `waitUntil` helper
- [x] render the row in both styles: marker plus a one-line `AskTextEditor` with the placeholder, marker dimmed
      while blank, field excluded from the row's toggle gesture, scroll-to-cursor including the row
- [x] route focus by cursor in `grabFocus`/`onAttach`; editor `doCommandBy` handles Up/Down back to the list
- [x] run the touched hosted tests with `-only-testing:` - must pass before Task 5

### Task 5: Contract, user docs and agent skill

**Files:**
- Modify: `.claude/rules/control-api.md`
- Modify: `site/commands.html`
- Modify: `site/docs.html`
- Modify: `plugins/agterm/skills/agterm/reference.md`
- Modify: `plugins/agterm/skills/agterm/SKILL.md` (only if the trigger wording needs it)

- [x] state the `other` row contract once in `control-api.md`, including `ask.other`
- [x] mirror `--other`/`other` and the `text` result for choices in `commands.html`; extend the docs example
- [x] update the skill reference

### Task 6: Verify acceptance criteria
- [x] radio and checkbox lists with `--other` behave as described, in both styles, verified in an isolated Debug instance
- [x] run full gates once: `make release`, `cd agtermCore && swift test`, `make test-app`, `make lint`
- [x] run `lsappinfo list | grep -A4 agterm.debug` after the hosted runs

### Task 7: [Final] Update documentation
- [x] update README.md only if the demo should show the row
- [x] update CLAUDE.md if new patterns were discovered
- [x] move this plan to `docs/plans/completed/`

## Post-Completion
*Informational only*

**Manual verification:**
- IME composition in the row's field
- remote handover against a viewer running the previous release (row ask stays local) and this build
