# Remote (teleport) sessions

## Overview

Attach a local agterm to a session running on another Mac that also runs agterm, so it appears in the
local sidebar as an ordinary session marked remote. One session at a time, including its split.
Whole-workspace teleport is out of scope.

Two new control commands:

- `zmx tree <host>` — ssh to the host, ask its agterm what sessions exist in its frontmost window, and
  return each pane's daemon plus the endpoint metadata needed to attach.
- `zmx attach <host> <session>` — create one local session whose panes run ssh into that remote
  session's daemons.

The picker stays in user space: a keymap custom command pipes the tree into `pick.open`.

Everything runs on the current pinned zmx (`ZMX_REV fb1b6b6`). No upstream change, no fork.

## Context (from discovery)

- `agtermCore/Sources/agtermCore/ControlProtocol.swift` — `ControlCommand`, `zmxList/zmxPrune/zmxKill`.
- `agtermCore/Sources/agtermCore/ControlPayloads.swift` — `ControlZmxInventory`, `ControlZmxEntry`.
- `agtermCore/Sources/agtermCore/ControlProjection.swift` — `ControlSessionNode` (no daemon name today).
- `agtermCore/Sources/agtermCore/ControlDispatcher.swift` — `ControlActions`, the effect seam.
- `agtermCore/Sources/agtermctlKit/ZmxCommands.swift` — the `zmx` CLI group.
- `agterm/Ghostty/ZmxClient.swift` — holds the executable path and socket directory, both private.
- `agterm/Ghostty/GhosttySurfaceView.swift:550` — `shouldCloseOnChildExitAction`.
- `agterm/Ghostty/GhosttyCallbacks.swift:64` — `GHOSTTY_ACTION_SHOW_CHILD_EXITED`.
- `agtermCore/Sources/agtermCore/AppStore+Snapshot.swift:41,78` — `initialCommand` persistence.
- `agtermCore/Sources/agtermCore/AppStore+RecentClosed.swift` — the second persistence producer.

## Development Approach

- **testing approach**: regular (code first, then tests in the same task)
- complete each task fully before the next; tests are a required deliverable of every task
- all tests pass before starting the next task
- update this plan when scope changes

## Testing Strategy

- Host-free logic — ssh argv construction, the tree merge, endpoint payloads, dispatcher
  parsing/validation — is unit tested in `agtermCore` against fixtures and a fake ssh runner.
- App-side lifecycle — surface routing, persistence exclusion, ownership claims — uses hosted tests in
  `agtermTests`.
- End-to-end coverage goes in `agtermUITests/ControlAPIUITests`, scoped with `-only-testing:`, driven by
  the injected fake runner so no second Mac is needed.
- Anything that genuinely needs a second Mac lives in Post-Completion, never as a completion gate.

## Solution Overview

A remote pane is an ordinary command surface. Its command is ssh, its process is ssh, and everything
that already happens to a command surface happens to it. That is the whole design decision: no new
provenance, no new lifecycle, no daemon ownership.

Consequences that follow for free:

- Closing locally tears down the surface, ssh dies, the remote daemon survives. Detach-on-close is not
  built. No command ever asks the remote zmx to kill anything.
- Window close behaves identically, provided remote panes are never wrapped in local zmx.

One ephemeral `remoteHost` on `Session` drives the sidebar icon and lives exactly as long as the row.

### Why remote panes must not be wrapped by local zmx

Local wrapping exists so a pane survives a local app restart. Remote sessions are excluded from
snapshots and never restored across relaunch, so wrapping buys nothing — and it creates a real defect:
under live restore mode, window close drops the local zmx client while the local daemon keeps ssh
connected to the far side with no UI showing it. Route remote sessions before `ZmxLaunch.disposition`
in both surface factories.

### Why remote sessions must be excluded from every persistence producer

`initialCommand` is persisted (`AppStore+Snapshot.swift:41`) and restored (`:78`). A persisted remote
session would silently reconnect on a `rerun` launch, and under `none` would start a plain local shell
while a persisted remote icon lied about what it is.

Launch snapshots are not the only producer. `recordRecentClosedSession` calls `sessionSnapshot`
directly, and a workspace record computes `sessionCount` and retains `selectedSessionID` before
`workspaceSnapshot`. So filtering `AppStore.snapshot()` alone is not enough: a filtered workspace would
claim a count and a selection that include a session no longer in it. Every producer needs the
exclusion, and the workspace metadata has to be recomputed after filtering.

The three-second undo is in-memory and must keep working. Omit remote sessions from the Recent Closed
entry written to disk, not from the pending-close record that Reopen reads.

### Why local ownership needs its own projection

`WindowLibrary.liveClaims` converts every live session's pane UUIDs into local `agterm-<uuid>` claims
unconditionally. Unfiltered, each remote pane shows up in `zmx list` as a fabricated claimed-but-absent
local daemon, and the zmx ownership commands resolve a session they do not manage. Finalization derives
names the same way, and `closeSplit` calls `paneFinalizer` directly rather than through
`finalizePaneIdentities`.

Pinned `zmx kill` ignores an unmatched name, so the current behavior happens to be a harmless no-op — but
relying on that is the wrong ownership boundary. One model-derived `locallyManagedPaneIdentities` is
empty when `remoteHost != nil` and otherwise returns primary plus existing split, consumed everywhere
local zmx ownership is read.

Structural `paneIdentity` stays intact: swap, promotion and control addressing still need a stable pane
identity even when it is not a local daemon identity.

## Technical Details

### Endpoint metadata

Neither `tree --json` nor `zmx list --json` exposes the remote zmx executable path or its `ZMX_DIR`, and
both are derived from the far side's state directory, so neither is guessable from here. `zmx list` gains
them as header fields.

They must be **injected**, not recomputed. `WindowLibrary.directory` and `ZmxClient`'s executable and
socket directory are private, and recomputing from the process environment inside `ControlServer+Zmx`
would duplicate runtime selection and break hosted tests that inject a client. Expose them from
`ZmxClient` and thread them through the restored runtime.

Teleport therefore requires the remote agterm to be new enough to report endpoints. An older remote
returns a clear error rather than a partial attach.

### Scope: the remote's frontmost window

`tree --json` without `--window` projects the remote's frontmost window; `zmx list --json` is app-wide
across every window including closed claims. Merging them unfiltered would mix scopes.

v1 is **frontmost remote window only**, which is where the session you are looking at on the other
machine lives. `zmx list` rows belonging to other windows are dropped during the merge. Widening to all
remote windows means `window list` plus a `tree --window` per window and is deliberately deferred.

Both remote commands run inside **one** ssh invocation so the two projections come from one moment. A
topology change between them is still possible in principle; the merge rejects a session whose panes do
not resolve rather than guessing.

### ssh invocation

Two different shapes, and the difference matters:

- **tree** — `-T`, `BatchMode=yes`, `ConnectTimeout`, plus an outer process deadline. `ConnectTimeout`
  ends at handshake and cannot bound a hung remote command.
- **attach** — `-tt` (a remote command does not reliably get a pty, and zmx reads termios and window
  size), `BatchMode=yes`, connection timeout, no lifetime deadline.

`BatchMode=yes` is what keeps a host-key or password prompt from hanging a dispatcher that cannot answer
it, so key-based non-interactive auth is a documented precondition. Host, session and remote command are
argv- or shell-quoted, never interpolated raw.

The ssh runner is **async and off the main actor**, behind an injected seam. `ControlActions` is
`@MainActor`, so a blocking `Process.wait` would freeze the UI for the whole network deadline. The seam
is also what lets the end-to-end tests run against a fake instead of a second Mac.

### The create-only guard

`zmx attach <name>` on a **missing** daemon creates one (`loop.zig:661`, `should_create = !exists`) and
runs a fresh shell under the old name. A daemon that vanished between `zmx tree` and the attach would
therefore hand you a brand-new remote shell that looks like the session you asked for. That is worse
than a failed attach.

The attach argv passes a command after the daemon name that exits non-zero. An existing daemon ignores
it — zmx logs "session already exists, ignoring command" — while a vanished daemon creates the session,
runs that command, and fails immediately and visibly. This is the same create-only attach payload the
live-restore fallback already uses.

The merge is the first line of defence: every expected pane must resolve to a `claimed` endpoint
observed `running`, and an absent, unreadable or partial row is rejected outright. The guard covers the
race the merge cannot.

### Disconnect

Set `commandWait`/`splitCommandWait` on the remote ssh commands. `shouldCloseOnChildExitAction`
(`command != nil && !waitAfterCommand`) then returns false, so `GHOSTTY_ACTION_SHOW_CHILD_EXITED`
returns false without dispatching anything, Ghostty shows its own "press any key to close", and
`close_surface_cb` runs today's `closePrimaryPane`/`closeSplitPane` after the key.

The ssh wrapper prints one sanitized line before exiting: host, remote session, pane, exit status. It
says nothing about reconnecting — the picker is a keymap custom command the user supplies, so agterm
cannot name a path it does not own.

**There is no timer, notification or session-wide coalescing.** An earlier draft had them, and they
cannot work: returning false schedules no app callback, so app code does not learn ssh exited until the
keypress. Adding them would mean a new child-exited callback plus transient pending-close state — new
plumbing for a case the held prompt already covers. A caller's overlay does not block command-wait; it
only hides the held pane until the overlay closes. Each pane holds and closes on its own, which is also
the right behavior when only one half of a split dies.

`zmx attach` reports synchronously only pre-model failures — unresolvable host, auth refused, a session
whose panes do not resolve. Once the model is inserted, transport startup failure and later loss are
ordinary pane exits on the held path.

### Placement and re-resolution

`zmx attach <host> <session>` carries no endpoint payload from the picker, so it re-runs the remote
resolution itself before inserting anything. A daemon that vanished in between is a pre-model failure
and creates no session.

The new row lands in the frontmost window's current workspace and becomes selected, matching what
`createSession` does today. Placement options are out of scope.

## Accepted v1 limitations

Document these; do not build around them.

Pinned zmx keeps one `leader_client_fd`. Our attach is a follower, so `handleInit` sends a snapshot at
the **far side's** geometry and does not resize. The first classified keystroke (printable, Enter, Tab,
Backspace, modified/kitty keys) calls `setLeader`, which asks our client for its size and reflows the
shared pty.

- Before that keystroke, follower input is **dropped**, not merely non-claiming. Mouse, focus and Ctrl-L
  (`0x0C` is not among `util.zig:719`'s accepted execute controls) never reach the remote, so a
  mouse-first TUI looks dead.
- Leadership is per **daemon**. Typing in the primary reflows only its pty, so a correctly sized primary
  can sit beside a split still at the far side's geometry; the far side sees the mirror image.
- On detach, each daemon we led clears its leader and the far side keeps our geometry until that pane
  receives qualifying input or a resize report. Panes we never claimed stay correct.

A later optional upstream improvement — opt-in `zmx attach --take-leadership` plus handback to the exact
displaced leader — would remove all three. It is **not** part of this work.

## Progress Tracking

- mark completed items `[x]` immediately
- new tasks get a ➕ prefix, blockers a ⚠️ prefix

## What Goes Where

- **Implementation Steps**: code, tests, docs in this repo, verified against a fake ssh runner.
- **Post-Completion**: anything needing a second Mac.

## Implementation Steps

### Task 1: Endpoint metadata and the ssh invocations

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlPayloads.swift`
- Create: `agtermCore/Sources/agtermCore/RemoteSession.swift`
- Modify: `agterm/Ghostty/ZmxClient.swift`
- Modify: `agterm/agtermApp.swift`
- Modify: `agterm/Control/ControlServer.swift`
- Modify: `agterm/Control/ControlServer+Zmx.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift`
- Create: `agtermCore/Tests/agtermCoreTests/RemoteSessionTests.swift`
- Modify: `agtermTests/ControlServerZmxTests.swift`

- [x] add the zmx executable path and `ZMX_DIR` to `ControlZmxInventory` as header fields, both optional
      on the wire so an older server still decodes
- [x] expose them from `ZmxClient` and thread them through the restored runtime into `ControlServer`,
      never recomputed from the process environment
- [x] add a host-free builder for the tree invocation: `-T`, `BatchMode=yes`, `ConnectTimeout`, running
      both remote commands in one invocation
- [x] add a host-free builder for the attach invocation: `-tt`, `BatchMode=yes`, remote `ZMX_DIR` and
      executable, daemon name, and the create-only guard command that exits non-zero
- [x] quote host, session and remote command as argv; reject control characters and an empty host
- [x] write payload tests for the populated and nil-omitted cases
- [x] write tests for both argv shapes, for hostile-input quoting, and for the rejection cases
- [x] write a hosted test that the endpoint comes from the injected client, not the environment
- [x] run tests — must pass before task 2

### Task 2: Remote session model

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Session.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+Snapshot.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+RecentClosed.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+Panes.swift`
- Modify: `agtermCore/Sources/agtermCore/WindowLibrary.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlProjection.swift`
- Modify: `agterm/Views/WorkspaceSidebar.swift`
- Modify: `agterm/Views/WorkspaceSidebar+RowRendering.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/SnapshotRoundTripTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/RecentClosedTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/WindowLibraryClaimsTests.swift`
- Modify: `agtermTests/SidebarRowViewsTests.swift`

- [x] add ephemeral `remoteHost: String?` to `Session`, not persisted
- [x] add `locallyManagedPaneIdentities` — empty when `remoteHost != nil`, else primary plus existing split
- [x] consume it in `finalizePaneIdentities`, the direct `closeSplit` finalizer path, `liveClaims`, live
      `finalizeWindowPanes`, and any live-versus-persisted inventory comparison
- [x] exclude remote sessions from the launch snapshot, the Recent Closed session record, and
      workspace-close records, recomputing `sessionCount` and `selectedSessionID` after filtering
- [x] keep the in-memory pending-close record intact so the three-second undo still restores a remote row
- [x] surface `remoteHost` on `ControlSessionNode`, omitted when nil, and draw the sidebar icon from it
- [x] write snapshot tests: remote-only selected session, mixed workspace, remote-only workspace
- [x] write Recent Closed tests: session record, grouped soft close, workspace record metadata
- [x] write claims tests: a remote pane produces no local claim and no finalizer name
- [x] write sidebar tests: remote single and split rows, and that a flag still takes precedence
- [x] write tree read-back tests, populated and omitted
- [x] run tests — must pass before task 3

### Task 3: `zmx tree <host>`

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher+Zmx.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlActionsDefaults.swift`
- Modify: `agtermCore/Sources/agtermCore/RemoteSession.swift`
- Modify: `agterm/Control/ControlServer+Zmx.swift`
- Modify: `agtermCore/Sources/agtermctlKit/ZmxCommands.swift`
- Modify: `agtermCore/Sources/agtermctlKit/SocketClient.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherZmxTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/MockControlActions.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/CommandsTests.swift`
- Modify: `agtermUITests/ControlAPIUITests.swift`

- [x] add the `zmxTree` command and its response: sessions with pane roles, split axis, per-pane daemon,
      remote executable and `ZMX_DIR`
- [x] add a pure `RemoteTreeMerger` joining the two remote projections, scoped to the frontmost window
- [x] require every expected pane to resolve to a `claimed` endpoint observed `running`; reject absent,
      unreadable, partial and cross-window rows
- [x] add the async ssh runner behind an injected seam so the action never blocks the main actor
- [x] give `ControlActions` its default and mock implementations so the agterm-linux build still compiles
- [x] return a clear error when the remote reports no endpoint metadata
- [x] add the CLI subcommand with readable rows and `--json`
- [x] write merge tests over fixtures: no split, missing split endpoint, mismatched window/session ids,
      a daemon that disappeared, and rows from another window
- [x] write dispatcher tests for validation and error text, and CLI parsing tests
- [x] write a scoped end-to-end test against the fake runner
- [x] run tests — must pass before task 4

### Task 4: `zmx attach <host> <session>`

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher+Zmx.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlActionsDefaults.swift`
- Modify: `agterm/Control/ControlServer+Zmx.swift`
- Modify: `agterm/agtermApp.swift`
- Modify: `agtermCore/Sources/agtermctlKit/ZmxCommands.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherZmxTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/MockControlActions.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/CommandsTests.swift`
- Modify: `agtermTests/ControlServerZmxTests.swift`
- Modify: `agtermUITests/ControlAPIUITests.swift`

- [x] add the `zmxAttach` command taking host and remote session
- [x] re-run the remote resolution before inserting anything; an unresolvable session is a pre-model
      failure that creates no session
- [x] create one local session in the frontmost window's current workspace, selected, with `remoteHost`
      set, primary running the attach invocation, and the split against the second daemon with the
      remote session's axis when it has one
- [x] set `commandWait`/`splitCommandWait` so each pane holds with Ghostty's own press-any-key prompt
- [x] route remote sessions before `ZmxLaunch.disposition` in both surface factories so they are never
      wrapped by local zmx and never set `backedByZmx`
- [x] have the attach invocation print one sanitized line on exit: host, session, pane, exit status —
      and no reconnect advice, the picker being user-supplied
- [x] add the CLI subcommand
- [x] write dispatcher tests for validation and the pre-model failure, and CLI parsing tests
- [x] write tests for the single-pane and split cases, and for the diagnostic line with a hostile
      session name
- [x] write hosted tests that a remote surface is unwrapped, reports `backedByZmx == false`, and that
      its exit closes only its own pane
- [x] write a scoped end-to-end test that a remote session's row carries `remoteHost` in `tree`
- [x] run tests — must pass before task 5

### Task 5: Update documentation

- [x] update `site/docs.html` and `site/commands.html` with both commands and their read-back
- [x] update `plugins/agterm/skills/agterm/` — the source for installed Claude/Codex copies
- [x] update `.claude/rules/control-api.md` with the remote-session contract, the endpoint-metadata
      requirement, the frontmost-window scope, and the create-only guard
- [x] record the accepted v1 limitations where the contract lives, not scattered across surfaces
- [x] update `README.md` and `site/llms.txt` only if the synchronized facts change

### Task 6: [Final] Verify and gate

- [x] verify against the fake runner: a split session attaches both panes to the right daemons
- [x] verify a remote session is absent from every persistence producer after close and after quit
- [x] verify a vanished daemon fails visibly instead of creating a fresh remote shell
- [x] verify an older remote without endpoint metadata fails with a clear message
- [x] run `make build`
- [x] run `cd agtermCore && swift test`
- [x] run `make test-app`
- [x] run `make lint` — zero findings required
- [x] move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification** (needs a second Mac running agterm):

- attach to a live remote session and confirm the first keystroke reflows it
- confirm the far side keeps working after a local close
- pull the network mid-session and confirm the held prompt explains what happened

**Deferred, not part of this work:**

- opt-in `zmx attach --take-leadership` upstream, with handback to the displaced leader
- whole-workspace teleport

## Scope change during the run

Every task above was planned and executed against a **frontmost-window** scope, composing the far side's
`tree --json` and `zmx list --json` into one ssh invocation split by a framing marker. That is what the
ticked boxes record, and the sections describing it are left as written.

It is **not what shipped**. After the tasks completed, the frontmost limit was judged an arbitrary
restriction rather than a real constraint: `tree --window` already accepted any open window, so nothing
had forced it. Rather than widen the composition, `zmx.tree`'s host became optional — bare it builds the
whole all-window projection locally, and with a host it runs that same bare form once over ssh. The far
side answers with one already-joined document.

That removed the framing marker, the two-sequential-calls race, and the rule that the exit status had to
be read before the marker could be trusted, none of which have anything to answer for any more. It also
retired "remote windows beyond the frontmost one" from the deferred list above, and added
`windowID`/`windowName` and `workspaceID`/`workspaceName` to each row: names to display, ids to group by,
since neither rename path enforces uniqueness.

Read `.claude/rules/control-api.md` for the contract as it actually stands. Where this plan and that file
disagree, the plan is the older document.
