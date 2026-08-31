# Live-session restore after a machine reboot

## Overview

Live mode keeps each pane's process in a zmx daemon, so an ordinary restart reattaches to it. A machine
reboot kills every daemon: the pane still runs `zmx attach <name>`, zmx creates a fresh daemon, and the pane
comes back as a bare login shell. The command it was running is gone and nothing replays it.

This makes a reboot restore what the pane was running, *inside* the new daemon, so the pane is live again
immediately and every later restart is an ordinary reattach. The reboot costs one replay, not a permanent
downgrade.

Two gaps have to close:

- **Nothing is captured.** `GhosttyApp.restoreRunningCommand` is `launchRestoreMode == .rerun` and quit
  capture is gated on it, so live mode records nothing. `captureForegroundCommands` also clears a
  `backedByZmx` primary outright and reads a split through `ForegroundProcess`, which sees the attach client
  rather than the daemon-side program.
- **Nothing replays.** In the `.wrapped` factory branches `initialInput` is nil for a restored primary and
  nil unconditionally for a split — right while the daemon survives, wrong once it is gone.

Deliberate product change: `README.md` currently promises *"A reboot, `agtermctl zmx kill`, or another
missing daemon restores that pane as a fresh shell."*

## Context (from discovery)

- **Two capture sites**: `AppDelegate.captureForegroundCommands` (quit) and `WindowAccessor`'s last-window
  close before surface teardown. Changing only the first still loses captures when the last window closes.
- **Injection chain**: the resolver is built in `agtermApp.swift:246`, not on `GhosttyApp`. Reaching
  `WindowAccessor` crosses `ContentView.swift:58` → `WindowContentView.swift:223`. All three are in scope.
- **Resolver**: `ZmxForegroundResolver` — a failed `refreshIfNeeded` **retains the old map**, so it cannot
  serve capture as-is. Its `LeaderProvider` takes no timeout and the closure built in `agtermApp` carries the
  fixed 3 s client.
- **Eligibility**: `CommandRestore.shouldRestore(argv:denylist:)` refuses an empty argv0, any control
  character or U+FFFD, and any denylisted basename.

Verified in pinned zmx `fb1b6b6`:

- `ensureSession` decides by **connecting**: a daemon that answers logs `session already exists, ignoring
  command`, and only the create path reaches `createCmdZ`. One zmx-controlled create-or-attach, no agterm
  preflight race — but **not** strictly atomic: the liveness probe closes before the attach connection, so a
  daemon dying in that window makes attach fail rather than create.
- `createCmdZ` with a command allocates argv **verbatim**, `argv[0]` as the executable. No shell composition
  and none of the `-shell` login-argv convention the no-command path uses.

## Development Approach

- **testing approach**: TDD — this closes observable regressions, so each task starts from a failing test.
- host-free logic (`agtermCore` tests): script, eligibility, argv composition. App behaviour: `agtermTests`.
- gates run ONCE, after documentation and the plan move, so the tree that passes is the tree that ships.
- no XCUITest run — nothing here changes UI.

**Isolation for every runtime and benchmark step.** A private short `AGTERM_STATE_DIR` under `/tmp` so the
derived `ZMX_DIR` is a private namespace; launch-and-signal-own-pid only, after confirming that pid's
environment names the state dir; explicit teardown of the accept-but-never-answer fixture and of every
daemon created in the private namespace.

## Solution Overview

**Capture (exit only, both exits).** Under live mode both sites force one **fresh** resolver snapshot and
read each pane's daemon-side foreground through it — primary and split, including a hidden split whose
backing surface exists. Non-live modes keep `ForegroundProcess` untouched. Capture runs under its own
wall-clock deadline; on refresh failure or expiry the affected slots go nil rather than being filled from
the retained map, because a stale leader PID can be recycled onto an unrelated process.

**Eligibility.** A captured argv is replayed only if `CommandRestore.shouldRestore` accepts it. A refusal
means bare attach and a fresh shell, as today. Without this, live replay would revive denylisted commands
and turn currently-refused bytes into shell text.

**Replay (create-only).** An eligible restored live pane attaches as `zmx attach <daemon> <shell> -lic
<script>`. agterm does not check whether the daemon exists — zmx decides. A survivor ignores the payload; a
missing daemon is created running the script.

**The script.** `createCmdZ` runs `argv[0]` directly, so the payload's first element is the validated
absolute login shell and `-lic` makes it login+interactive: that shell reads the injected `.zshenv`, the
user's startup files, and the ghostty integration. But that `.zshenv` **consumes** the injection — it
restores `ZDOTDIR` from `GHOSTTY_ZSH_ZDOTDIR` or unsets it, then unsets the carrier. So the script re-arms
both before the final shell, using **quoted** zsh builtins, which is what the bundled `.zshenv` itself does
and what the no-shadow claim actually requires — an unquoted `builtin` is alias-expandable:

```
<quoted argv> ; 'builtin' 'export' ZDOTDIR=<literal> ; 'builtin' 'export' GHOSTTY_ZSH_ZDOTDIR=<literal>|'builtin' 'unset' GHOSTTY_ZSH_ZDOTDIR ; 'builtin' 'exec' -- <abs shell> -il
```

`;` never `&&`, so a failed replay still leaves a usable shell.

**Excluded, deliberately.** Panes of a window closed before quit are not captured and come back as fresh
shells. A hard power loss captures nothing. A denylisted or control-byte command is never replayed. All
three are stated in the docs, not left implicit.

## Technical Details

**Deadline contract.** A `ZmxClient` invocation timeout is only the wait before TERM; `run` grants a further
250 ms before SIGKILL. The capture cap is therefore **wall clock including the termination grace**, or a
"250 ms" cap can return near 500 ms. It comes from repeated cold and warm trials against 55 healthy daemons
plus headroom — never from the unresponsive case, which exists only to prove the cap cuts off zmx's
one-second per-socket probe. That fixture must **accept and then never answer**; a socket that merely
refuses is cleaned up quickly and proves nothing. Slots captured before expiry are kept; only the remaining
ones go nil.

Measured on 2026-08-30, a full refresh across 55 healthy daemons took 10-30 ms cold and about 10 ms warm.
The accept-but-never-answer fixture took 1.01 s without a capture override; the 100 ms invocation timeout
cut it off in 109 ms before the 250 ms termination grace. The implemented 350 ms refresh ceiling leaves
150 ms of the 500 ms exit budget for per-pane sysctl reads.

**Policy flag.** Capture eligibility gets its own `capturesForegroundOnExit` rather than widening
`restoreRunningCommand`, which also governs rerun eligibility elsewhere. `restore.capture` stays rerun-only.

**Consume-once.** The factories call `ZmxLaunch.configuration` *before* the disposition is known. The replay
is built only after `.wrapped` is established and `pendingForegroundCommand` is consumed exactly once there;
sticky restore overrides are left alone. Taking the capture earlier would make `.fallback` consume state it
currently preserves.

## Verification Record

The isolated run used `AGTERM_STATE_DIR=/tmp/agtr3` and private zmx namespace
`/private/tmp/agterm-zmx-a53bf053842b803b`. A clean Cocoa quit used
`NSRunningApplication.terminate()`; POSIX SIGTERM does not run the quit callbacks and was excluded.

| Case | Result |
| --- | --- |
| Captured replay | The snapshot stored the foreground argv. After the old daemon was killed, the marker grew from 1 to 2 and the leader changed from 79657 to 85598. |
| Surviving daemon | The marker stayed at 1 and the leader stayed at 80728. The attach payload did not run. |
| Failed replay | Removing the executable before relaunch produced a shell with no foreground process; the shell accepted a verification command. |
| Denylisted replay | The marker stayed at 1. The new daemon had no foreground process and opened a shell. |
| Hidden split | The right pane stayed absent until shown. Showing it grew the marker from 1 to 2 and replaced leader 81113 with 86340. |
| Closed window | Its snapshot had no foreground command. Reopening kept the marker at 1, created leader 89948, and accepted a shell command. |

The final login shell contained `_ghostty_precmd` and `_ghostty_preexec`. A replay-created primary shell
reported `/tmp/agtr3/osc7-dir` through OSC 7 to the control tree and the private zmx listing. Teardown left
no app process, zmx session, private namespace, or state directory.

## Implementation Steps

### Task 1: Replay payload (host-free)

**Files:**
- Create: `agtermCore/Sources/agtermCore/ZmxReplayScript.swift`
- Modify: `agtermCore/Sources/agtermCore/ZmxSupport.swift`
- Create: `agtermCore/Tests/agtermCoreTests/ZmxReplayScriptTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ZmxSupportTests.swift`

- [x] failing tests first: custom original `ZDOTDIR`, nil original, argv needing quoting, denied basename,
      control character, U+FFFD, empty argv0
- [x] build the script from captured argv, integration dir, original `ZDOTDIR` and absolute shell, emitting
      QUOTED `'builtin' 'export'` / `'builtin' 'unset'` / `'builtin' 'exec' --` and `;` separators
- [x] gate payload construction behind `CommandRestore.shouldRestore(argv:denylist:)`; a refusal yields bare
      attach
- [x] compose the attach argv as `[shell, "-lic", script]`, outer-quoted exactly once
- [x] test with a hostile alias for `builtin`, `export` and `exec`, proving the script still re-arms and execs
- [x] test that a failed replay still reaches the final shell, and that quoting survives a shell round trip
- [x] run tests — must pass before task 2

### Task 2: Capture at both exits

**Files:**
- Modify: `agterm/Ghostty/ZmxForegroundResolver.swift`
- Modify: `agterm/Ghostty/ZmxClient.swift`
- Modify: `agterm/AppDelegate.swift`
- Modify: `agterm/Views/WindowAccessor.swift`
- Modify: `agterm/Views/WindowContentView.swift` (constructs `WindowAccessor` at line 223)
- Modify: `agterm/ContentView.swift` (constructs `WindowContentView` at line 58 — injection cannot cross the
  chain without it)
- Modify: `agterm/agtermApp.swift` (owns the resolver; injects the capture route)
- Create: `agtermTests/AppDelegateCaptureTests.swift`
- Modify: `agtermTests/ZmxClientTests.swift`

- [x] benchmark first: time a full refresh plus per-pane reads against ~55 healthy daemons, cold and warm,
      repeated; build the accept-but-never-answer fixture and confirm the chosen cap cuts zmx's one-second
      probe; pick the cap from the healthy trials plus headroom, replacing the 250/500 ms candidates if the
      measurement disagrees
- [x] settle Task 2's first design decision before writing code: `freshSnapshot` either takes a
      capture-specific provider or `LeaderProvider` gains a deadline — otherwise the "fresh" API still
      invokes the fixed three-second closure and the budget is unenforceable
- [x] add the fresh-snapshot entry point reporting failure instead of falling back to `leaders`; leave
      `refreshIfNeeded` unchanged for existing callers
- [x] add a capture-specific timeout to `ZmxClient` so capture stops inheriting the 3 s lifecycle default
- [x] add a `capturesForegroundOnExit` policy rather than widening `restoreRunningCommand`; keep
      `restore.capture` rerun-only
- [x] route the resolver to both capture sites by INJECTION through the chain above, not a global or an
      app-delegate lookup
- [x] read primary and split through the resolver when the surface is `backedByZmx`; keep `ForegroundProcess`
      for everything else; no process-group descent
- [x] bypass `session.isSplit` ONLY for a backed live hidden split; a hidden ordinary or rerun split keeps
      today's nil behaviour
- [x] enforce the wall-clock deadline between panes: keep slots already captured, nil the rest
- [x] tests: live primary and split captured via resolver, hidden LIVE split captured, hidden non-live split
      still nil, non-live path unchanged, refresh failure and mid-loop expiry produce nil not stale
- [x] test in `ZmxClientTests` that the wall-clock timeout INCLUDES the 250 ms grace, so a cap cannot be
      "honoured" while the call returns at twice the budget
- [x] hosted regression driving a real `willClose`: start with a non-nil live foreground, close the last
      window, assert the argv reached the PERSISTED snapshot before teardown
- [x] run tests — must pass before task 3

### Task 3: Wire the payload into the factories, and verify at runtime

**Files:**
- Modify: `agterm/agtermApp.swift` (both `.wrapped` branches)
- Create: `agtermTests/SurfaceFactorySeedTests.swift`
- Create: `docs/plans/notes/20260830-runtime-verification.md` (scratch; folded in before completion)

- [x] failing tests first: consume-once on primary and split, and `.fallback` does not consume. These are
      behaviours of the private factories and the session pending slots, so they belong in the APP target —
      `ZmxSupportTests` cannot reach them
- [x] build the replay only after `.wrapped` is established, never before `configuration` succeeds
- [x] consume `pendingForegroundCommand` exactly once; leave sticky restore overrides untouched
- [x] keep `initialInput` nil so the command cannot arrive twice
- [x] runtime, isolated instance: marker command captured on quit; kill only that daemon and relaunch, pane
      returns running the marker in a NEW daemon; ghostty integration live in the replayed pane (prompt
      marks and OSC 7); a surviving daemon ignores the payload with no duplicate; a failed replay still
      leaves a usable shell; a denylisted command yields a fresh shell; a hidden split replays on delayed
      show; closed-window panes come back fresh
- [x] run tests — must pass before task 4

### Task 4: Documentation, then gates

**Files:**
- Modify: `README.md`, `site/docs.html`, `plugins/agterm/skills/agterm/SKILL.md`
- Modify: `.claude/rules/control-api.md` if the restore contract text lives there
- Modify: this plan

- [x] replace the README sentence promising a fresh shell after a reboot with the new behaviour
- [x] state all three exclusions — window closed before quit, hard power loss, denylisted command — on all
      three surfaces
- [x] fold the benchmark and runtime measurements into this plan or into code comments, then delete the
      scratch notes, so the constants are not unexplained numbers
- [x] update `CLAUDE.md` if the capture/replay split is a pattern worth recording
- [x] move this plan to `docs/plans/completed/` — BEFORE the gates
- [x] verify every Overview requirement is implemented and all three exclusions behave as documented
- [x] run `make build`, `cd agtermCore && swift test`, `make test-app`, `make lint` — last, on the final tree

## Post-Completion

**Manual verification**
- a real machine reboot with live mode on, confirming panes return running their commands
- a restart straight after, confirming an ordinary reattach with nothing replayed twice

**Known exclusions, by decision**
- panes of a window closed before quit come back as fresh shells
- a hard power loss or force restart captures nothing
- a command refused by the restore denylist, or carrying control bytes, is never replayed
