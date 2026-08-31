# Zmx-backed persistent sessions

## Goal

Add one global restore mode with three values:

- `none`: restore the tree with fresh shells.
- `rerun`: keep today's captured-command replay.
- `live`: run primary and split panes through zmx so their processes survive app exit and relaunch.

The mode is fixed for the process lifetime. Settings changes apply after restart. There is no per-session
flag or control command that opts a pane out of `live`.

The implementation uses stock libghostty. A surface runs `zmx attach <name>` as its command, while zmx owns
the long-lived shell. Scratch, overlay and quick terminals stay ephemeral. Zsh is the only supported login
shell in v1; every other shell starts as an ordinary unwrapped shell and Settings explains why.

## Facts that replace the old plan

| Old assumption | Verified fact |
|---|---|
| libghostty forbids `command` with `initial_input` | `embedded.zig` applies them independently. Agterm owns the old exclusion. |
| zmx needs Zig 0.15 | The repository and zmx build with the pinned Zig 0.16 toolchain. |
| persistence should be enabled per session | Eugene chose one global mode. |
| primary and split daemon names can follow pane role | Promotion changes roles, so live mode needs a stable persisted pane identity. |
| shell integration requires a Ghostty fork | Zsh integration is environment-only and survives through the wrapper. |
| an attach client must detach cleanly | SIGTERM to agterm drops the client to zero while the daemon and shell remain alive. |
| a missing daemon needs recovery code | `zmx attach` creates a fresh daemon under the persisted name. |

The committed spike at `495accd7` also proves OSC 7 cwd updates, one-time `initial_input`, Claude Code input
after reattach, and preserved terminal color when `NO_COLOR` is absent.

## Pane scope

Primary and split panes are wrapped. A split is already part of persisted session state through its layout,
cwd, ratio and foreground fields. It needs one new stable identity so promotion cannot cross-wire daemon names.

A hidden split persists `hasSplit` and its identity, so launch inventory still claims the daemon. Split focus
is not added to the snapshot: after restart the hidden session defaults to its primary pane, and showing the
split reattaches the surviving split daemon.

Scratch, overlay and quick terminals stay unwrapped. Scratch has no snapshot representation, so a wrapped
scratch would leave a daemon that no restored model could claim; launch reap would correctly treat it as an
orphan. Making scratch persistent would change its product meaning and belongs outside this feature.

## Behavior

`live` is a launch mode, not a replacement for the existing restore commands:

- `restore.capture` works only in `rerun`. In `none` or `live`, it refuses and names the active mode.
- `session.restore set` and `session.restore --none` keep saving policy for a future `rerun` launch. Outside
  `rerun`, the response says the value is saved but inactive. Neither command bypasses `live`.
- `session.restore --clear` and app-global `restore.clear` remain available in every mode.
- Existing command names stay stable for scripts.

Changing modes does not clear older captured argv. Switching back to `rerun` has the same stale-capture
behavior as turning the current boolean off and on.

`tree` reports `backedByZmx` on each primary and split surface, plus a session aggregate that is true only when
every existing pane is backed. Eligibility failures are process-wide and appear in Settings. A later attach
failure for one pane is logged with its identity and reason. V1 adds no sidebar glyph for this rare state.

## Lifecycle table

Daemon action follows semantic deletion, never `TerminalSurface.teardown()`.

| Event | Action |
|---|---|
| SIGTERM, app quit, or reopenable window close | Attach clients end; daemons stay alive. |
| Session or workspace close with undo grace | Keep daemons until grace expires; undo restores the same objects. |
| Immediate session or workspace close | Kill every covered daemon immediately. |
| Window delete, open or closed | Kill every covered daemon from live or persisted state. |
| Explicit split close or split process exit | Kill that split daemon. |
| Hidden split | Persist `hasSplit` and identity so the daemon remains claimed; restore focus to primary and reattach the split when shown. |
| Primary exit with a split survivor | Move the survivor identity to primary; the dead daemon exits naturally. |
| Requested-live launch | Reap zero-client app daemons absent from a complete persisted-name set. Preserve claimed daemons even when eligibility falls back. Skip reap if inventory is incomplete. |
| Deliberate non-live launch | Reap every zero-client app daemon in this instance namespace. |

The zmx directory is a short hash-derived path under `/tmp`, scoped by the canonical agterm state directory.
A stale control socket pathname can remain after SIGTERM, so tests wait for a successful request rather than
checking only that the socket exists.

## Build and test rules

- `agtermCore` stays free of AppKit and GhosttyKit.
- Codex is the sole writer. Claude reads each task diff and runs its targeted checks before the next task.
- Each code task adds or updates focused tests. Full `swift test`, app tests, lint and build run in Task 9.
- Debug experiments use a short isolated state directory and an explicit socket. Capture the exact Debug PID
  from its bundle path and stop only that PID with SIGTERM.
- Never use the deployed app, the default control socket, `pkill`, AppleScript quit, or a Debug installer.
- Keep source files below 1000 lines and tests below 2000. Do not edit `CHANGELOG.md`.

## Implementation tasks

### Task 1: Add restore mode and persisted pane identity

**Files:**
- Create: `agtermCore/Sources/agtermCore/RestoreMode.swift`
- Modify: `agtermCore/Sources/agtermCore/AppSettings.swift`
- Modify: `Session.swift`, `Snapshot.swift`, `AppStore+Snapshot.swift`, `AppStore+Panes.swift`
- Modify: matching `agtermCore` tests

- [x] migrate legacy `restoreRunningCommand`: true becomes `rerun`; false or absent becomes `none`
- [x] decode unknown mode strings as `none` and write only the new key
- [x] persist primary and split pane identity and use it as `AGTERM_PANE_ID`; promotion moves the survivor
      identity to primary and a new split mints another
- [x] persist `hasSplit` for a hidden split without adding `splitFocused` to the snapshot
- [x] test migration, identity minting on a legacy snapshot, duplicate sessions, promotion then re-split, and
      a hidden split that stays claimed while focus resets to primary
- [x] run the focused core tests

### Task 2: Add zsh wrapping inputs and daemon naming

**Files:**
- Create: `agtermCore/Sources/agtermCore/ZmxSupport.swift`
- Create: `agtermCore/Tests/agtermCoreTests/ZmxSupportTests.swift`
- Modify/Delete: `agterm/Ghostty/ZmxSpike.swift` when its logic moves

- [x] accept only a password-database login shell whose basename is `zsh`
- [x] reproduce zsh integration with `ZDOTDIR`, preserved `GHOSTTY_ZSH_ZDOTDIR`, explicit `SHELL`, `ZMX_DIR`
      and `ZMX_NO_DETACH_KEY=1`; require the bundled zsh loader
- [x] name daemons from the full compact pane UUID and use it as `AGTERM_PANE_ID`
- [x] derive a fixed-length namespace from a canonical state path; its full UUID daemon name stays within the Unix socket budget
- [x] test supported, unsupported and missing-resource decisions plus stable names and namespace derivation

### Task 3: Build and sign zmx

**Files:**
- Modify: `scripts/setup.sh`, `project.yml`, `scripts/release.sh`, `.github/workflows/ci.yml`, `.gitignore`
- Stage: `agterm/Resources/zmx/zmx`, `agterm/Resources/zmx/LICENSE`

- [x] pin `ZMX_REV` and track zmx with its own stamp so zmx changes do not rebuild Ghostty
- [x] stage the binary and MIT notice with the existing Zig 0.16 toolchain
- [x] extend the existing helper phase so zmx and `agtermctl` are signed before one app seal
- [x] sign both helpers before Developer ID release signing and check zmx signature/entitlements in CI
- [x] run setup twice, then build and inspect the bundled binary

### Task 4: Latch mode and update restore-command contracts

**Files:**
- Modify: `GhosttyApp.swift`, `SettingsModel.swift`, `SettingsView.swift`, `AppDelegate.swift`
- Modify: `ControlServer.swift`, `ControlServer+SessionActions.swift`, `agtermctlKit/MiscCommands.swift`
- Modify with the command code: `.claude/rules/{settings,control-api}.md`, `site/commands.html`,
  `site/docs.html`, and agent-skill command pages
- Modify: focused app, control and Settings tests

- [x] create one immutable launch mode used by launch surfaces, new windows and reopened windows
- [x] replace the checkbox with a three-value picker that applies after restart and explains an unsupported
      login shell
- [x] implement the `restore.capture`, `restore.clear` and `session.restore` behavior above with checked saves
- [x] update every named command contract in the same task; retain command names
- [x] test late-window latching, both refusal modes, inactive set/none policies and both clear forms

### Task 5: Wrap primary and split panes and report actual backing

**Files:**
- Modify: `agterm/agtermApp.swift`, `GhosttySurfaceView.swift`, control-tree shaping and logging
- Create: focused app and UI tests

- [x] use the bundled binary and launch mode; keep `AGTERM_ZMX_PATH` as a Debug-only override
- [x] wrap primary and split panes and leave scratch, overlay and quick terminals unchanged
- [x] set wrapped state before surface creation and use native `command` plus `initial_input`
- [x] on fallback, a restored pane starts a plain shell without consuming capture or restore-override state;
      a fresh pane still runs its creation `--command` with its wait policy
- [x] add per-surface `backedByZmx`, a session aggregate, and pane-specific logging for attach failure; add no
      sidebar element
- [x] bypass zmx in default UI tests with the UI-test sentinel; add one explicit real-zmx test with cleanup

### Task 6: Add zmx lifecycle control and launch cleanup

**Files:**
- Create: `agterm/Ghostty/ZmxClient.swift`
- Create: host-free zmx list/reap parsing and tests
- Modify: `AppStore`, pending-close and pane lifecycle files, `WindowLibrary`, launch persistence wiring

- [x] add bounded injectable `zmx ls` and `zmx kill` operations plus list parsing
- [x] call one semantic-finalization sink from immediate and grace-based session/workspace deletion and window
      deletion; keep all zmx work out of surface teardown
- [x] finalize split identities on explicit close/exit and move identity on promotion
- [x] inventory all persisted names before surfaces mount; skip live reap on read/decode failure
- [x] reap unclaimed zero-client names in `live`, and every zero-client app name outside `live`
- [x] test undo, immediate close, window close/delete, selected split behavior, incomplete inventory and reboot upsert

### Task 7: Resolve real foreground processes

**Files:**
- Create: `agterm/Ghostty/ZmxForegroundResolver.swift`
- Modify: `ForegroundProcess.swift`, `ControlServer.swift`, zmx parser tests

- [x] map each wrapped pane name through the zmx leader to the daemon pty foreground group
- [x] cache the leader map, refresh on zmx lifecycle changes plus a slow reconcile, and evict dead entries
- [x] leave unwrapped lookup unchanged and avoid a `zmx ls` process per pane
- [x] test wrapped, stale and unwrapped cases

### Task 8: Update general documentation

**Files:**
- Modify: `README.md`, `site/docs.html`, `site/index.html`, agent skill and troubleshooting pages

- [x] document the three modes, zsh-only support, restart requirement and primary/split scope
- [x] document per-surface backing, the session aggregate, the deliberate lack of sidebar UI, SIGTERM recovery
      and missing-daemon fresh shells
- [x] document synthesized-screen losses and `--command` close/wait behavior
- [x] preserve command text owned by Task 4 and existing install/position facts
- [x] run writing and narrow documentation checks

### Task 9: Verify and finalize

- [x] verify the lifecycle table in an isolated Debug instance using its captured PID and explicit socket;
      the focused lifecycle test covers grace finalization before and after undo
- [x] verify Claude Code and colors after SIGTERM/reattach, then verify missing-daemon upsert
- [x] verify destructive actions remove covered daemons and non-destructive actions only detach
- [x] run `swift test`, `make test-app`, `make lint`, and `make build`
- [x] update `CLAUDE.md`, including Zig 0.16 and the final lifecycle rules
- [x] delete the superseded idea plan and move this plan to `docs/plans/completed/`

## Manual follow-up

- Eugene performs a clean quit only when the final flush path itself is under test.
- Exercise the selected mode for several days against a copied state directory before using the live state.

Smells pre-check: skipped because this is not a Go project.
