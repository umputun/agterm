# Claude status with background subagents

## Overview
- The stock Claude Code hooks post `completed --auto-reset` on the main thread's `Stop` even while a background
  subagent (Agent with `run_in_background`, or a Workflow agent) keeps working. A visit resets the row to idle,
  and it stays idle until the subagent's next tool call finishes, which can be minutes.
- A subagent's `PostToolUse` posts `active` like the main thread's, so it erases a permission prompt the main
  thread is still waiting on (reproduced) and overwrites main's `completed`.
- Fix, stateless: a subagent's activity sets `active` only while the row is idle, through a new atomic
  `--if-idle` condition on `session.status`; main's `Stop` posts `active` instead of `completed` while Claude's
  own `background_tasks` lists a running agent.
- Rule from Eugene: a subagent sets the row active only when it is idle; nothing else changes.

## Context (from discovery)
- Claude Code 2.1.322 hook facts, measured with a payload-logging probe:
  - every subagent `PreToolUse`, `PermissionRequest`, `PostToolUse` carries its `agent_id`; main-thread events
    carry none;
  - only `Stop` and `SubagentStop` carry `background_tasks`: `[{id, type, status, ...}]`, `type` `subagent` or
    `workflow`. After the last agent finishes or is stopped, the next `Stop` lists none;
  - every background completion, and a user stop (ctrl+x ctrl+k), re-invokes the main thread with
    `UserPromptSubmit` then `Stop` (5 of 5 runs), so the final `completed` arrives when the last agent ends.
- Status writes: `agtermCore/Sources/agtermCore/AppStore+Status.swift` (`applyControlStatus`,
  `StatusWriteResult`); request path `ControlDispatcher.swift` session-status arm, `ControlSessionStatusUpdate`
  (`ControlModes.swift`), `ControlArgs` (`ControlProtocol.swift`), CLI `agtermctlKit/SessionMetadataCommands.swift`.
  Both hosts, `agterm/Control/ControlServer+SessionActions.swift` and
  `AgtermServerKit/ServerActions+Effects.swift`, check only `.refused` before the sound path.
- Adapter `agterm/Resources/agent-status/agterm-claude-status.sh` runs its ancestry guard, then forwards argv to
  `agterm-agent-status.sh`, and never reads stdin today. The Codex adapter already parses payloads with
  `/usr/bin/plutil` on Darwin and `jq` on Linux. Installed entries (`AgentHooksInstall.claudeHooks`) stay as
  they are.
- Recipes: `subagent-status` calls the adapter with `</dev/null`; `truthful-agent-lights` passes Claude's full
  payload on stdin with its own argv from its `PostToolUse` and `Stop` hooks (measured with its real scripts against
  a recording stub), while its optional `PreToolUse[Bash]` hook `machinery-paint.sh` drains stdin with `jq` first,
  so the adapter sees no payload there.
- agterm-linux consumes `agtermCore` public API: new parameters get defaults.

## Development Approach
- **testing approach**: TDD (bug fix): failing test first, confirm it fails, then the change.
- complete each task fully before moving to the next; every task includes its tests.
- run only the touched tests while working (`swift test --filter`, `-only-testing:`); the full gates run once,
  at the end of the last task.

## Testing Strategy
- unit: `AppStoreStatusTests`, `ControlDispatcherSessionMetadataTests`, `ControlProtocolTests`,
  `agtermctlKitTests/CommandsTests`, `AgtermServerTests/ServerActionsEffectsTests`, `ClaudeStatusHookTests`.
- hosted: `agtermTests/ControlServerStatusSoundTests`.
- the adapter tests run on the macOS job (plutil) and the Linux CI job (jq; no-`jq` case via a constructed bin
  directory).

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix, blockers with ⚠️ prefix

## Solution Overview
- `session status STATE --if-idle` applies only while the row is idle; otherwise it is an ok no-op. The check
  and the write happen in one store call, so no other write can land between them.
- The adapter reads the hook payload (when there is one) and changes two things:
  - an event carrying `agent_id` whose argv state is `active` gets `--if-idle` appended;
  - a `Stop` whose argv state is `completed` posts `active --blink` instead while `background_tasks` lists a
    running `subagent` or `workflow`.
- Everything else posts its argv exactly as today: main-thread events, `blocked` from any source, empty or
  unreadable payloads, and a `Stop` payload without `background_tasks` (a Claude Code predating it).

## Technical Details

**`--if-idle`**: `ifIdle` on `ControlArgs` and `ControlSessionStatusUpdate` (defaulted).
`applyControlStatus(_:forSession:ifIdle: Bool = false)` checks it first: a write with it on a non-idle row returns
a new `StatusWriteResult.skipped` before the pane-refusal check and before any change, so a block owned by the
other pane answers ok rather than an error. Both hosts return ok before the sound path: no event, timestamp,
presentation frame or sound. On an idle row it is an ordinary write. A running app older than the installed CLI drops the unknown field and applies
the write as today; documented as an upgrade note. An adapter that falls back to an older `agtermctl` on PATH
gets an unknown-option error for `--if-idle`, which the wrapper swallows, so that subagent `active` is not posted.

**Adapter input**: stdin is read only when it is not a terminal (`[ -t 0 ]`), with a bounded read
(`read -r -d '' -t 2`), so a hand-run adapter or an inherited open pipe never hangs a hook. bash 3.2 returns 1
from that `read` on a complete EOF read and on a timeout alike, and a timeout discards the partial data, so the
adapter tests for a non-empty payload, never the return code; a payload too large to arrive in time falls back to
argv. Fields come from
key paths only: `/usr/bin/plutil -extract KEYPATH raw` on Darwin (`agent_id`, `hook_event_name`,
`background_tasks.N.type|status`), `jq` on Linux; no regex over the payload. With no parser (Linux without
`jq`), the adapter posts argv as today. The ancestry guard stays first and unchanged.

**Argv rewrite**: only the state word is read from argv. Appending `--if-idle` keeps every flag the caller
passed. Rewriting `completed` posts plain `active --blink` and drops the caller's flags: they style a completion
(`--sound` would play the done sound while the agent still works, `--shape` would show a finished glyph), and a
carried `--auto-reset` would let `clearAutoResetIndicator` (`AppStore.swift:601`) reset the row to idle on
selection, which is the gap being fixed. A `Stop` whose argv state is not `completed` posts argv unchanged. Recipes get the same treatment where they pass the payload: truthful-agent-lights' subagent
`PostToolUse` `active` becomes conditional, and its `completed` at turn end becomes `active --blink` while Claude
lists running agents, which its own process scan cannot see for in-process agents. Its `machinery-paint.sh` paint
reaches the adapter without a payload and stays unconditional.

**Security**: the untrusted input is the hook payload, written by the same user's Claude Code process. It decides
only whether `--if-idle` is appended and whether `completed` becomes `active`; nothing from it reaches argv or is
executed.

Limitations, stated in the docs:
- a subagent's own permission prompt (`blocked`) can still be replaced by main's activity while main is busy;
- when the key that answers a subagent's prompt leaves the block in place (a digit under the `enter` reset mode,
  any key under `never`), the row stays blocked until main's next event, because the subagent's `active` applies
  only to an idle row; `firstKey`, and Return under `enter`, clear it on that key;
- the `completed` that ends a background run comes from the re-invocation's `Stop`; if Claude ever skipped that
  re-invocation the row would stay `active` until the main thread's next event;
- `background_tasks` needs a Claude Code that sends it; an older one keeps today's turn-end `completed`.

## Implementation Steps

### Task 1: `--if-idle` on session.status

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore+Status.swift`, `ControlModes.swift`, `ControlProtocol.swift`,
  `ControlDispatcher.swift`
- Modify: `agterm/Control/ControlServer+SessionActions.swift`, `agtermCore/Sources/AgtermServerKit/ServerActions+Effects.swift`
- Modify: `agtermCore/Sources/agtermctlKit/SessionMetadataCommands.swift`
- Modify tests: `AppStoreStatusTests`, `ControlDispatcherSessionMetadataTests`, `ControlProtocolTests`,
  `agtermctlKitTests/CommandsTests`, `AgtermServerTests/ServerActionsEffectsTests`,
  `agtermTests/ControlServerStatusSoundTests`, `agtermUITests/PaneAwareStatusUITests`

- [x] failing tests first in `AppStoreStatusTests`: `active --if-idle` applies on an idle row; returns
      `.skipped` with no event and no change on active, completed and blocked rows, the last including a block
      owned by the other pane (skipped, not refused); the visible regression: main `blocked`, then a subagent's
      `active --blink --if-idle`, stays blocked (the reproduced erasure)
- [x] `ifIdle` on `ControlArgs` and `ControlSessionStatusUpdate` (defaulted), dispatcher pass-through with a
      `ControlDispatcherSessionMetadataTests` case, `applyControlStatus(_:forSession:ifIdle:)` with `.skipped`
- [x] both hosts return ok before the sound path on `.skipped`; no-sound cases in `ControlServerStatusSoundTests`
      and `ServerActionsEffectsTests`
- [x] CLI `agtermctl session status STATE --if-idle` with parse tests; protocol round-trip tests
- [x] `fork:true` code search for agterm-linux switches over `StatusWriteResult` (a new case breaks an
      exhaustive switch); record the result here: none. `melonamin/agterm-linux` (shallow clone, 2026-11-10)
      reads the result only through `if case .refused` and `==` in tests
- [x] targeted XCUITest beside `testStatusFromTheOtherPaneCannotReplaceABlock` in
      `agtermUITests/PaneAwareStatusUITests.swift`, run with `-only-testing:`: blocked row, `active --if-idle`
      answers ok and the tree still reads `blocked`; idle row, the same write reads `active`
- [x] run the touched tests - must pass before task 2

### Task 2: Payload-aware Claude adapter, docs and gates

**Files:**
- Modify: `agterm/Resources/agent-status/agterm-claude-status.sh` (header comment rewritten: it reads stdin now)
- Modify tests: `ClaudeStatusHookTests` (the harness gains stdin, defaulting to an empty closed pipe so the
  existing cases never inherit the runner's stdin; the terminal case opens a pseudo-terminal with `openpty`,
  since Linux CI has no tty)
- Modify docs: `site/docs.html` (agent status section and the hook mapping), `site/commands.html`,
  `plugins/agterm/skills/agterm/SKILL.md` (the `session status` synopsis), `reference.md`,
  `.claude/rules/control-api.md` (the `session.status` flags bullet and the Claude hook mapping),
  `.claude/rules/notifications.md`

- [x] failing adapter tests first in `ClaudeStatusHookTests`, payloads on stdin through the process-chain harness,
      asserting the recorded writes:
      - subagent `PostToolUse` with argv `active --blink` posts `active --blink --if-idle`; main's posts argv;
      - subagent `PermissionRequest` posts `blocked` unchanged;
      - `Stop` with a running subagent or workflow in `background_tasks` posts `active --blink`; with none or an
        empty list, `completed --auto-reset`; without the key, argv;
      - extra flags: `active --color '#4A9EFF'` from a subagent event gains `--if-idle` and keeps the color;
        `completed --auto-reset --sound Glass --color '#4A9EFF'` at a `Stop` with a running agent posts exactly
        `active --blink`;
      - not rewritten: `SubagentStop` with argv `completed`; a `Stop` whose list holds only non-running entries
        posts `completed --auto-reset`; a `Stop` with a running agent and argv `active --color X --shape Y` posts
        argv unchanged;
      - empty stdin, a terminal stdin and an unreadable payload post argv without hanging; Linux without `jq`
        posts argv
- [x] adapter: bounded stdin read, key-path parsing, the two argv rewrites
- [x] rerun the recipe probe, run from `/tmp` and isolated: `AGT_STATUS_SCRIPT` set to the worktree adapter, a
      recording wrapper via `AGTERM_STATUS_WRAPPER`, `AGTERMCTL` set to a recording stub, `AGT_SUBAGENT_STATE`,
      `AGT_LIGHTS_STATE` and a short `AGTERM_STATE_DIR` under `/tmp`, so nothing reaches the default socket or
      `$HOME` state; the payloads come from the scratchpad. Expected: truthful-agent-lights' `PostToolUse` and
      `Stop` argv as specified above, its `machinery-paint.sh` argv unchanged, `subagent-status` argv unchanged
- [x] docs: `site/commands.html` `--if-idle`; `site/docs.html` background subagents keep the row active, a
      subagent's `active` never overwrites main's status (its `blocked` still applies), the limitations, the minimum Claude Code version that sends
      `background_tasks` (from the `claude-releases` changelog), the upgrade note; `reference.md` `--if-idle`;
      `control-api.md` Claude mapping; `notifications.md` subagent rule
- [x] full gates once: build, `cd agtermCore && swift test`, `make test-app`, `make lint`
- [x] verify every Overview requirement against the tests; move this plan to `docs/plans/completed/`

## Post-Completion
- Manual check in an isolated Debug instance with the Debug CLI: a Claude session with a background subagent
  stays active after the main turn ends and turns completed when it finishes; main's blocked prompt stays blocked
  while the subagent works. The new adapter reaches the live hooks only through Eugene's Release redeploy and hook reinstall.
- The `subagent-status` recipe replaces the stock `Stop` to hold the row; the stock hooks now do that. Whether to
  tell its author (@bubakanov) is Eugene's call.
