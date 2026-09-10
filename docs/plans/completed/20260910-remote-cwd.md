# Remote panes: host token and local cwd for local shells

## Overview

A session opened with `agtermctl zmx attach HOST SESSION` runs `ssh -tt` to a remote `zmx attach`. Its
pane reports the REMOTE working directory through OSC 7, and every local shell or command the app
starts for that session inherits it as if it were local: a custom keymap command, the scratch
terminal, the overlay default, the quick terminal, and a split opened after the attach-time split is
closed. Nothing a command can read says which machine the path belongs to.

This change adds `AGT_SESSION_HOST` to the custom-command context (the SSH destination the session was
attached from, empty for a local session) and one rule for where a local shell on a remote pane
starts: the pane's reported path when it exists locally as a directory, else local HOME. The pwd token
keeps the reported path in both cases, so a command can still `ssh "$AGT_SESSION_HOST"` into it.

This is context, not a safety gate. No token is inspected to decide whether a command may run, and no
command is refused on a remote pane.

## Context (from discovery)

- `Session.remoteHost` (`agtermCore/Sources/agtermCore/Session.swift:129`) is the SSH destination,
  set only by `ControlServer+Zmx.swift:173` through `store.addSession(... remoteHost:)`, never
  persisted. The attach seeds the session cwd with local HOME (`ControlServer+Zmx.swift:168`), and
  only the remote shell's cwd report replaces it.
- `Session.cwd(for:)` (`Session.swift:544`) is the pane-aware cwd: the split's live `splitCwd`, then
  `initialSplitCwd`, then `effectiveCwd` for `.right`; `effectiveCwd` otherwise.
- `CommandContext` (`agtermCore/Sources/agtermCore/CustomCommand.swift`) holds the `AGT_*` token table;
  `expand`, `environment()` and `tokenNames` all derive from it, and the Settings token reference lists
  `tokenNames`.
- `CustomCommandRunner.context(for:in:selectionSurface:pane:)` builds the context with
  `sessionPWD: session.cwd(for: pane)`; `spawn` chdirs to `context.sessionPWD` when non-empty
  (`agterm/Commands/CustomCommandRunner.swift:316-364`). The sessionless context has an empty pwd and no
  chdir.
- Consumers seeding a local shell from the primary cwd, all in `agterm/agtermApp.swift`:
  `makeSplitSurface` (:525, `initialSplitCwd ?? effectiveCwd`), `makeOverlaySurface` (:588,
  `spec.cwd ?? effectiveCwd`), `makeScratchSurface` (:659, `effectiveCwd`), `wireQuickTerminal`
  (:723, `activeSession?.effectiveCwd`).
- The attach-time split command is durable: `LaunchSeed.durableCommand` reads
  `splitInitialCommand` without clearing it, so hide and show keeps the ssh split. `closeSplit`
  (`AppStore+Panes.swift:194-205`) clears it with `initialSplitCwd`, so a split created afterwards, or
  on an unsplit remote session, is a local login shell. `swapPanes` (:125) writes the primary's
  reported cwd into `initialSplitCwd`, so that field can hold a remote path and is not a local override.
- `GhosttySurfaceView.workingDirectory` is `private`; factory seed tests cannot read it today.
- `agtermCore` already queries `FileManager` directly (`OpenPathResolver.swift`,
  `DirectoryPanelDefaults.swift`) with real temp directories in tests. `DirectoryPanelDefaults` also
  expands tilde and normalizes through URL, which this rule does not want.
- Doc surfaces listing the tokens: `plugins/agterm/skills/agterm/reference.md:1275-1290`,
  `site/docs.html:1700` (token grid) and `:1556` (example), `.claude/rules/keymap.md:105-112`. Remote
  attach behavior: `reference.md:1460-1485`, `site/docs.html:2476`, `.claude/rules/control-api.md:921`.
- Test homes: `agtermCore/Tests/agtermCoreTests/SessionTests.swift`, `CustomCommandTests.swift`;
  `agtermTests/CustomCommandRunnerTests.swift` (`fired(_:from:writing:)` runs a real command and reads
  its output), `agtermTests/SurfaceFactorySeedTests.swift`.

## Development Approach

- Tests first: each task writes the failing test, runs it targeted, then the code.
- One writer in `/Users/umputun/dev.umputun/agterm/.claude/worktrees/remote-cwd`; Codex reads only.
- Run each gate once at the end (Task 8); everything before is targeted:
  `cd agtermCore && swift test --filter <Class>` and
  `scripts/test-app.sh -only-testing:agtermTests/<Class>/<test>`.
- Every task ends with its tests passing before the next starts.
- Update this plan when scope changes.

## Testing Strategy

- Host-free unit tests in `agtermCore` for the helper and the token.
- Hosted tests in `agtermTests` for the runner's actual `pwd` and environment, and for every factory
  seed, since a correct helper with a missed call site is the likely failure.
- No XCUITest: nothing here changes chrome or protocol.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix

## Solution Overview

- **One decision point.** `Session.localWorkingDirectory(reported:homeDirectory:)` answers "where does
  a local process for this session start". Every consumer calls it; nobody spells the remote check inline.
- **Raw context, separate execution cwd.** `CommandContext.sessionPWD` and `cwd(for:)` are unchanged.
  The runner resolves the local directory while it holds the `Session` and passes it to `spawn` as its
  own argument. Scratch and the other factories never build a `CommandContext`.
- **Host stays out of pane environments.** Exporting it on the local ssh client does not reach the
  remote shell, and on scratch it would name the owning attachment rather than the shell's own host.
  Local readers already have `remoteHost` on the tree node.
- **Explicit overlay `--cwd` stays a local override**; only the inherited default changes.
  `initialSplitCwd` is NOT an override: the remote check runs before it is read.
- **Existence, not identity.** The rule picks an existing local directory of the same spelling. It
  does not verify that the directory is the same repository, and detached commands display nothing,
  so the docs describe it as "an existing local path".

## Technical Details

```swift
// Session.swift, beside cwd(for:)
/// Where a LOCAL process for this session starts, given the pane path it would inherit: that path on a
/// local session; on a remote one, only when it exists here as a directory, else `homeDirectory`.
public func localWorkingDirectory(reported path: String, homeDirectory: String) -> String {
    guard remoteHost != nil else { return path }
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
    return exists && isDirectory.boolValue ? path : homeDirectory
}
```

The helper takes the candidate path rather than a pane so each caller keeps the precedence it has
today: the runner passes `cwd(for: pane)` (live `splitCwd` for a right-pane chord), the split factory
passes `initialSplitCwd ?? effectiveCwd`. A pane-keyed helper would have read `splitCwd` in the split
factory, and that field is not reliably nil there: `applyPwd` is queued on the main queue with no
destroyed-view guard, so a report in flight when `closeSplit` runs lands after the clear. That
inherited callback defect is out of scope here.

- `CommandContext.sessionHost: String` (default `""`), token `("AGT_SESSION_HOST", sessionHost)` placed
  after `AGT_SESSION_PWD`. `sessionScopedTokenBases` already covers the `AGT_SESSION` prefix, so a
  command using only the host token stays inert in an emptied window like the other session tokens.
- Runner: `context(for:)` sets `sessionHost: TerminalText.sanitized(session.remoteHost ?? "")`, where
  `TerminalText.sanitized` is the existing control-character strip already applied to names; attach
  validation rejects control characters anyway, so an accepted destination such as `user@alias` is
  preserved verbatim. `spawn(_:context:cwd:)` takes the directory explicitly; the session path passes
  `session.localWorkingDirectory(reported: session.cwd(for: pane), homeDirectory: NSHomeDirectory())`,
  the sessionless path passes `nil` and keeps no chdir.
- Factories, each passing the path it inherits today: scratch and quick terminal `effectiveCwd`;
  overlay `spec.cwd ?? localWorkingDirectory(reported: effectiveCwd, ...)`; split
  `localWorkingDirectory(reported: initialSplitCwd ?? effectiveCwd, ...)`.
- `GhosttySurfaceView.workingDirectory` stays an immutable `let` and becomes internal (read by
  `SurfaceFactorySeedTests`); `makeScratchSurface` and `makeOverlaySurface` become internal like
  `makeSplitSurface`.
- Docs state: the host token is the SSH destination or empty; the pwd token keeps the reported path,
  which can be remote; HOME seeds it until the first cwd report; with the scratch focused it still
  reports the primary pane; the host token marks only sessions opened by `zmx attach`, so an `ssh`
  typed into a local session leaves it empty while the pwd token still follows that shell's reports;
  examples quote `"$AGT_SESSION_HOST"` and `"$AGT_SESSION_PWD"` and pass no nested-quoted `cd` to a
  remote shell (local double quotes do not escape the inner single quotes; verified exit 2).

## Implementation Steps

### Task 1: `Session.localWorkingDirectory`

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Session.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/SessionTests.swift`

- [x] tests: local session returns the reported path untouched, a nonexistent one included
- [x] tests: remote session with the reported path an existing temp directory returns that path;
      a missing path returns `homeDirectory`; an existing regular FILE at the path returns `homeDirectory`
- [x] implement `localWorkingDirectory(reported:homeDirectory:)` beside `cwd(for:)`
- [x] run `swift test --filter SessionTests`

### Task 2: `AGT_SESSION_HOST` token

**Files:**
- Modify: `agtermCore/Sources/agtermCore/CustomCommand.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/CustomCommandTests.swift`

- [x] tests: `expand("{AGT_SESSION_HOST}")` and `environment()["AGT_SESSION_HOST"]` carry the value;
      the default context expands it empty; `tokenNames` includes it right after `AGT_SESSION_PWD`
- [x] test: `referencesSessionScopedContext` is true for a body using only `$AGT_SESSION_HOST`
- [x] add `sessionHost` to `CommandContext` (field, init parameter, token row)
- [x] run `swift test --filter CustomCommandTests`

### Task 3: runner wiring

**Files:**
- Modify: `agterm/Commands/CustomCommandRunner.swift`
- Modify: `agtermTests/CustomCommandRunnerTests.swift`

- [x] test: a remote-marked session (`addSession(... remoteHost: "user@alias")`) whose reported
      `currentCwd` is an existing temp directory; the fired command writes `$PWD`, `$AGT_SESSION_PWD`
      and `$AGT_SESSION_HOST`; expect the directory, the same raw path, `user@alias`
- [x] test: same with a nonexistent reported path; expect `$PWD` = `NSHomeDirectory()`, the raw path,
      the host; the command starts
- [x] test: same with a regular file at the reported path; expect `$PWD` = HOME
- [x] extend `testAChordFiredInSplitPaneResolvesSplitPaneWorkingDirectory` to also write `$PWD` and
      assert both equal the right directory (local session, live `splitCwd`)
- [x] test: local session writes an empty `$AGT_SESSION_HOST`
- [x] `context(for:)` fills `sessionHost`; `spawn` takes `cwd: String?`; session path passes
      `localWorkingDirectory`, sessionless path passes nil
- [x] run `scripts/test-app.sh -only-testing:agtermTests/CustomCommandRunnerTests`

### Task 4: scratch, overlay and split factories

**Files:**
- Modify: `agterm/agtermApp.swift`
- Modify: `agterm/Ghostty/GhosttySurfaceView.swift` (`workingDirectory` internal)
- Modify: `agtermTests/SurfaceFactorySeedTests.swift`

- [x] tests: for a remote session with a missing reported cwd, scratch, overlay-without-`cwd` and split
      factories seed HOME; with an existing temp directory they seed that path
- [x] test: overlay with an explicit `spec.cwd` keeps it on a remote session
- [x] test: local session factories keep `effectiveCwd`, split keeps `initialSplitCwd`
- [x] test: split lifecycle on a remote session: the attach-time split's seed is the ssh command and
      survives hide/show; after `closeSplit`, a new split resolves a nil durable command (login shell)
- [x] make `workingDirectory`, `makeScratchSurface`, `makeOverlaySurface` internal; call the helper at
      the three sites
- [x] run `scripts/test-app.sh -only-testing:agtermTests/SurfaceFactorySeedTests`

### Task 5: quick terminal cwd provider

**Files:**
- Modify: `agterm/agtermApp.swift` (`wireQuickTerminal`)
- Modify: `agtermTests/SurfaceFactorySeedTests.swift` (the file that already tests `agtermApp`'s seeds)

- [x] test: `agtermApp.quickTerminalCwd(library:)` returns HOME for a remote active session with a
      missing cwd, the reported path when it exists locally, `effectiveCwd` for a local session, and
      HOME with no active session
- [x] extract the provider body into that static helper (the app struct's `init` restores state, so the
      instance method cannot be built in a test) and call `localWorkingDirectory` there
- [x] run the targeted test

### Task 6: documentation

**Files:**
- Modify: `plugins/agterm/skills/agterm/reference.md` (token list ~1275, remote attach ~1460)
- Modify: `site/docs.html` (token grid :1700, remote section :2476)
- Modify: `.claude/rules/keymap.md` (token rule ~105)
- Modify: `.claude/rules/control-api.md` (remote attach entry ~921, one sentence on local cwd)

- [x] add `AGT_SESSION_HOST` to every token list with the qualifications from Technical Details
- [x] state the local cwd rule once under remote attach and cross-reference it from the token entry
- [x] under remote attach, add: "When another client leads at a different terminal size, local cursor
      and screen-text reads can disagree with the application's layout; automation relying on those
      reads, including the chat transport, is unsupported in that state." Backlog item
      `attached-pane-content-is-laid-out-for-the-leaders-grid` carries the mechanism.
- [x] examples quote both variables and send no nested-quoted `cd` to a remote shell
- [x] no surface states a token count

### Task 7: verify acceptance criteria
- [x] every consumer in Context calls the helper; grep `effectiveCwd` in `agterm/` for leftovers
- [x] `cd agtermCore && swift test`
- [x] `make test-app`
- [x] `make lint` with zero findings

### Task 8: final docs sweep
- [x] `ARCHITECTURE.md` mentions the local-cwd decision point if it lists `Session` cwd accessors
- [x] move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification** (needs a second Mac running agterm):
- attach a remote session whose cwd exists on both machines; fire a keymap command writing `pwd`,
  `$AGT_SESSION_PWD` and `$AGT_SESSION_HOST` to a file; open scratch and a new split after closing the
  attach-time split; each starts in the local twin
- `cd` the remote pane to a path absent locally; repeat; each starts in HOME, pwd token unchanged

Smells pre-check: skipped — non-Go project
