# Live session supervisor

## Overview

A pane carried across a restart in Live sessions mode runs on a zmx daemon whose creating agterm has
exited. macOS resolves the responsible process dynamically, so at that instant every process in the
pane, and every command started in it afterwards, becomes its own responsible process. TCC then charges
each request to that command rather than to agterm: the microphone prompt returns for every Claude Code
version, and `docs/troubleshooting.md` documents the same loss for App Data. Reattaching from a new
instance does not repair it, and `responsibility_set_pid_responsible_for_pid` refuses an unprivileged
caller with EPERM.

Measured on 2026-09-08 in isolated instances, independently by two agents: a process spawned with
`responsibility_spawnattrs_setdisclaim` becomes a responsibility root that its descendants attach to,
the root outlives the process that spawned it, a child spawned after the spawner exited still resolves to
the root, and a Developer ID hardened-runtime child does the same. With that root bundled inside the app,
TCC attributed a real AVFoundation microphone request from a pane taken through an app restart to the
OUTER APP: one `client_type=0` row on the bundle id, granted once, already authorized after a further
restart. No helper row, no per-path rows, no entitlements on the helper.

This plan ships that root as a bundled helper with two modes: a persistent host, spawned once per state
directory with the disclaim attribute, and a short-lived client that runs as the pane's command under
the existing login path, asks the host to ensure the daemon, and then execs the ordinary `zmx attach`.
What is proven is the microphone. Other TCC services are expected to follow the same attribution but
are not claimed until tested, and panes created before the host existed stay as they are and are
reported as such on the tree.

## Context (from discovery)

- Live path: `ZmxLaunch.surfaceSeed` (`agterm/Ghostty/ZmxLaunch.swift`) builds the pane's command via
  `ZmxSupport.attachCommand`; it is called synchronously on the main actor from
  `LaunchSeedProvider.resolve` inside `GhosttySurfaceView.createSurface`, before `ghostty_surface_new`.
  The environment agterm passes there is overrides only (`SurfaceEnvironment.swift`); pinned libghostty
  (`src/termio/Exec.zig`) composes the full environment, cwd and initial pty size, and wraps the command
  in `login -q -flp`. Nothing on the app side has the finished environment.
- Stock zmx creates the daemon lazily by `fork()` then `setsid()` inside the attach client
  (`src/daemonize.zig:170`), so the root has to be an ancestor of the attach client that never exits.
  `zmx run -d` sets `is_task_mode`, which forces `bash`, so creation goes through `attach` in a pty.
- `ZmxClient` runs `zmx list` and maps leader pids with `ZmxLeaderMap`; `LaunchSeed.swift` documents
  `ReapOutcome.runningNames` as a scheduling hint only, a launch-time snapshot.
- `ControlServer` already models exclusive endpoint ownership with a held `flock` on `<socket>.lock`
  and bounded framing (`ControlServer.swift`), the pattern the host reuses.
- Helpers: `agtermctl` is an `.executable` product of the `agtermCore` package, built by `swift build`
  in a project.yml script phase and codesigned with `--options runtime`; `scripts/release.sh` re-signs
  and checks the explicit list `agtermctl zmx` after Xcode, in two loops.
- `agtermCore` is consumed by the `agterm-linux` fork, so Darwin-only code cannot live in it, and
  `agtermCoreTests` depends on `agtermCore` alone; helper runtime code that tests need has to sit in
  its own Darwin-only library target rather than in the executable.
- Debug and Release already carry different bundle ids (`project.yml`), which is what tells two
  instances sharing a state dir apart.
- Environment trap: an inherited `ZMX_SESSION` makes `zmx attach` SWITCH the caller's session; the
  client runs with the pane's finished environment, which `ZmxSupport.configuration` already scrubs.
- Remote sessions are excluded from the Live wrap by `ZmxLaunch.wrapsLocally`; their local process is
  `ssh` spawned by the running app and never persisted.

## Development Approach

- **testing approach**: TDD (tests first)
- complete each task fully before moving to the next; small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- private SPI (`responsibility_*`) lives in one Darwin-only package target reached by `dlsym`, with a
  fallback to today's behavior when a symbol is missing, so an OS change degrades rather than breaks
- no zmx changes, no new Settings toggle: the supervisor is on whenever Live sessions mode is active
- nothing after `fork()` in the helper runs Swift or Foundation: argv, env and buffers are built before,
  and the child path is C system calls to `execve` or `_exit`
- gates once at the end: `cd agtermCore && swift test`, `make test-app` scoped to touched classes,
  `make lint`

## Testing Strategy

- **unit tests** in `agtermCore`: protocol encoding and framing limits, paths, readiness parsing,
  ensure-decision logic, attribution classification, tree projection with split panes
- **hosted tests** in `agtermTests`: spawning the real host with disclaim in an isolated state dir and
  reading the chain back through `dlsym(responsibility_get_pid_responsible_for_pid)`. Skipped when the
  symbol is absent; when present, unexpected attribution FAILS. The test measures the test host's own
  responsible pid rather than assuming it equals its pid.
- **differential test** for the client seam: environment, cwd, initial pty size and login-shell
  behavior of a pane started through the client versus today's bare `zmx attach`, including a custom
  `ZDOTDIR`, must match
- no XCUITest: nothing here is chrome

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix; document blockers with ⚠️ prefix

## Solution Overview

```
pane surface (libghostty, login -q -flp) ──▶ agterm-session-host client <name> -- <zmx attach argv>
     │ captures its REAL env, cwd, winsize            │
     │ ensures the host exists (flock + spawn disclaimed if none)
     │ ──── ensure {name, argv, env, cwd, winsize} ──▶ agterm-session-host host  (setsid, flock owner)
     │ ◀─── ok {created|existing, leaderPid} ───────── │ existing: reply at once
     │                                                 │ missing:  C trampoline forkpty ▶ execve argv
     ▼                                                 │           └─fork▶ daemon ▶ shell ▶ …  (root = host)
execs plain `zmx attach <name>`, joining the daemon    │ poll `zmx list` for the leader, release own client
```

Decisions, each answering a review finding:

- **The client is the pane command; agterm never waits.** Waiting happens inside the pane after
  libghostty has composed the environment, so the UI never blocks and the daemon gets exactly the
  environment, cwd and winsize the pane itself has. `ZmxSupport` renders the pane command from a
  structured argv, never by splitting a rendered string; the `-lic` replay script and its creation-only
  semantics are preserved as the trailing argv the host uses for creation.
- **Ensure is idempotent and host-side.** The host answers `existing` for a daemon already in
  `zmx list`, without replaying any creation payload. `ReapOutcome.runningNames` stays a pacing hint
  and never gates creation.
- **No duplicate execution, decided by dispatch phase.** `existing` or `created`: exec plain
  `zmx attach <name>`. Any failure before an `ensure` could have reached the host (no host, handshake
  timeout or declined, request rejected with `error.stage == before`): exec today's full attach with the
  creation payload, which is still safe. Once an `ensure` may have reached the host (lost reply, deadline
  after dispatch, `error.stage == started`): exec plain `zmx attach <name>` and never replay, because the
  payload may have run; before exec the client prints one line to the pane saying creation could not be
  confirmed, the command may have started, and it was not retried, so a plain shell never looks like
  success. The host never terminates a daemon as timeout cleanup; it terminates only the client pid it
  forked, with bounded escalation. Re-run mode is unaffected: `wrapsLocally` wraps active Live mode only.
- **One root owns the endpoint.** The host holds an exclusive `flock` on `session-host.lock` for its
  lifetime, the same pattern as `ControlServer`. A client that cannot connect takes `session-host.spawn.lock`,
  re-checks, unlinks the SOCKET only when nobody holds the owner lock, spawns the host with disclaim, waits
  for the handshake, and releases. Lock files are never unlinked, only closed: a waiter holding the old
  inode while another client creates and locks a replacement inode would defeat the singleton. Only the
  socket and pidfile are removed, and only by the owner while it still holds its lock. Concurrent clients
  yield one root. A busy socket is never treated as a dead owner, and a stale pidfile never authorizes a
  signal. Every host-private descriptor, the owner lock, the listener and accepted connections, is
  close-on-exec, and the trampoline's descriptor contract says so explicitly: a daemon must never inherit
  the lock or the listener, or a dead host would live on inside its own descendant and block replacement.
- **Handshake before trust.** `hello` carries the protocol version, the canonical enclosing bundle
  location and its `CFBundleIdentifier` both ways. Each side derives its own location from the running
  process image, never `argv[0]`, which the login wrapper prefixes with a dash, and canonicalizes
  symlinks so `/tmp` and `/private/tmp` agree. The host's reported pid is tied to the socket peer. A
  host from another bundle location or bundle id, or one speaking a protocol the client cannot
  understand, is left alone and not used, and the client proceeds as a before-creation failure with the
  full payload. App version or build number is deliberately NOT compared: a root is meant to outlive
  app upgrades, and exact-build matching would turn every new pane into a fallback after each upgrade
  until the old root was stopped, which would orphan its panes. A live root is never killed to upgrade
  it. The endpoint is resolved from the pane's own `ZMX_DIR`, the same one the mediated attach uses,
  never from another state's default.
- **Bounded everything.** Owner-only permissions on the socket dir and socket; request size cap; read,
  write and overall deadlines on both sides; readiness polls `zmx list` every 100 ms up to a bounded
  deadline while draining the temporary pty and having passed the pane's winsize. A live leader pid is
  process readiness, not a shell prompt, and is documented as such.
- **The host has its own subdirectory.** All host files are under `<ZMX_DIR>/session-host/` through
  `SessionHost.paths`. Stock zmx probes every Unix socket directly in `ZMX_DIR`, so placing the host
  endpoint there would make readiness and inventory inspect the host as if it were a zmx daemon.
- **Lifecycle.** One host per state directory. Fresh shells and Re-run launches leave a live host alone;
  killing it would orphan daemons another instance may still be serving. Host death is not repaired:
  a later ensure spawns a fresh host for future daemons and the tree reports the old ones. `stop` exists
  as an administrative operation for fixtures and tests; it refuses while any daemon it roots is alive
  and also refuses when the inventory cannot be established, since an inspection error is not "none".
- **Attribution is read, not recorded**, once per tree build from one leader snapshot, probing each
  unique leader once. Measured cost over 100 leaders was 0.07 ms per batch, so there is no cache.
- **Remote sessions untouched.** Their panes never enter the Live wrap; helper-created daemons stay in
  the same socket dir under the same names, so `zmx tree` still offers them to a remote attacher.

## Technical Details

Package layout in `agtermCore`:

- `AgtermResponsibility` — Darwin-only library target: `dlsym` lookups of
  `responsibility_spawnattrs_setdisclaim` and `responsibility_get_pid_responsible_for_pid`,
  `isAvailable`, `spawnDisclaimed(executable:argv:env:)`, `responsibleProcess(of:)`. Products for both
  the app and the helper. Compiles to a stub with `isAvailable == false` on non-Darwin.
- `SessionHostTrampoline` — C target: `sh_forkpty_exec(argv, envp, cwd, winsize, &master, &execError) -> pid`,
  the only code that runs between `forkpty` and `execve`. The parent polls `execError` for a native errno
  from a child setup/exec failure; EOF alone does not establish daemon readiness.
- `SessionHostRuntime` — Darwin-only library target holding the host and client logic, sockets, locks
  and pty handling, depending on `agtermCore` for the protocol and `ZmxListParser` and on the two targets
  above; this is what the tests import, since `agtermCoreTests` depends on `agtermCore` alone.
  `PTYProcess` prepares C buffers before the trampoline and returns the PID and two owned descriptors.
- `agterm-session-host` — thin Swift executable over `SessionHostRuntime`: `host <socketDir>` and
  `client <name> -- <argv>` modes.
- Every Darwin-only target, dependency and entry point is conditional in `Package.swift`, so the
  `agterm-linux` consumer and the existing test path still build.
- `SessionHost.swift` in `agtermCore` — portable protocol types, paths, framing limits, readiness
  parsing, the client's three-way outcome decision, and attribution classification.

Protocol, newline-delimited JSON, one request per connection, 64 KiB frame cap, 2 s handshake deadline,
bounded ensure deadline:

```json
→ {"hello": {"protocol": 1, "bundleID": "com.umputun.agterm", "bundlePath": "/Applications/agterm.app"}}
← {"hello": {"protocol": 1, "bundleID": "com.umputun.agterm", "bundlePath": "/Applications/agterm.app", "pid": 4242}}
→ {"ensure": {"name": "agterm-…", "argv": ["…/zmx", "attach", "agterm-…", "/bin/zsh", "-lic", "…"],
              "cwd": "/Users/me/proj", "env": {…}, "rows": 40, "cols": 120}}
← {"ok": {"state": "existing" | "created", "leaderPid": 12345}}   |   {"error": {"stage": "before" | "started", "message": "…"}}
```

Tree read-back on `ControlSessionNode`, per pane and including a hidden split, following the paired
convention already used for other per-pane fields: `liveAttribution` and `splitLiveAttribution`, each
one of `supervisor` (leader's responsible pid is the live host), `app` (leader resolves to the running
agterm: a pre-host or fallback daemon, covered until the next restart), `orphaned` (resolves to itself
or to a dead pid), `unknown` (lookup failed or SPI absent). Absent for non-Live and remote sessions.
`supervisor` describes attribution only; it neither implies a grant nor covers every TCC service.

## What Goes Where

- **Implementation Steps**: everything below
- **Post-Completion**: confirmation on the deployed Release build after the isolated Release check

## Implementation Steps

### Task 1: Protocol, paths, framing and outcome logic in agtermCore

**Files:**
- Create: `agtermCore/Sources/agtermCore/SessionHost.swift`
- Create: `agtermCore/Tests/agtermCoreTests/SessionHostTests.swift`

- [x] write failing tests for `hello`, `ensure`, `ok` and `error` round-tripping through JSON, including
      argv with spaces, an env value with a newline, and an oversized frame rejected at the 64 KiB cap
- [x] write failing tests for `SessionHost.paths(socketDirectory:)` (socket, owner lock, spawn lock,
      pidfile, log) and the 104-byte socket-path limit surfacing as a `Rejection`
- [x] write failing tests for `SessionHost.leaderPid(in:name:)` over `ZmxListParser`: present with pid,
      present without, absent, unparseable
- [x] write failing tests for `SessionHost.ClientOutcome.decide(phase:reply:)`: `existing` and
      `created` yield plain attach; no host, handshake timeout, handshake declined and
      `error.stage == before` yield full attach with payload; `error.stage == started`, a lost reply and
      a deadline after dispatch yield plain attach plus the diagnostic line
- [x] write failing tests for `SessionHost.handshakeAccepts(local:remote:)`: same bundle id, canonical
      location and protocol accepts, including a different app version; other bundle id, other location
      (a `/tmp` versus `/private/tmp` pair canonicalizes to the same and accepts), or a newer protocol
      declines
- [x] implement to make them pass; run `swift test --filter SessionHostTests` - must pass before task 2

### Task 2: Darwin-only responsibility SPI target

**Files:**
- Create: `agtermCore/Sources/AgtermResponsibility/Responsibility.swift`
- Modify: `agtermCore/Package.swift`
- Create: `agtermTests/ResponsibilitySPITests.swift`

- [x] add the `AgtermResponsibility` library target and product; on non-Darwin it compiles to
      `isAvailable == false`
- [x] write a failing hosted test that reads the test host's own responsible pid, spawns `/bin/sleep`
      plain and disclaimed, and asserts plain resolves to that pid while disclaimed resolves to itself;
      skip when `isAvailable` is false, FAIL on any other outcome
- [x] write a failing test that a missing symbol makes `spawnDisclaimed` throw `.unavailable` rather
      than spawn without the attribute
- [x] implement `dlsym` lookups, `spawnDisclaimed` via `posix_spawn`, and `responsibleProcess(of:)`
- [x] run `make test-app` scoped to `agtermTests/ResponsibilitySPITests` - must pass before task 3

### Task 3: C fork/exec trampoline and the runtime test target

**Files:**
- Create: `agtermCore/Sources/SessionHostTrampoline/include/trampoline.h`
- Create: `agtermCore/Sources/SessionHostTrampoline/trampoline.c`
- Create: `agtermCore/Sources/SessionHostRuntime/PTYProcess.swift`
- Modify: `agtermCore/Package.swift`
- Create: `agtermCore/Tests/SessionHostRuntimeTests/SessionHostTrampolineTests.swift`

- [x] add the Darwin-only `SessionHostTrampoline` C target, the Darwin-only `SessionHostRuntime`
      library target depending on it, `AgtermResponsibility` and `agtermCore`, and a Darwin-only
      `SessionHostRuntimeTests` test target depending on `SessionHostRuntime`; all conditional so the
      Linux consumer and the existing `agtermCoreTests` path are unchanged

- [x] write failing tests: exec of `/bin/echo` with a given env and cwd reproduces both on the pty;
      a missing executable returns a failure the parent can read; winsize is applied before exec
- [x] implement `sh_forkpty_exec`: `forkpty`, `chdir`, `execve`, `_exit(127)`; no allocation after fork;
      return close-on-exec PTY/error descriptors so the parent can poll setup failures without blocking
- [x] run `swift test --filter SessionHostTrampolineTests` - must pass before task 4

### Task 4: The host mode

**Files:**
- Create: `agtermCore/Sources/SessionHostRuntime/Host.swift`
- Create: `agtermCore/Sources/SessionHostRuntime/HostBackend.swift`
- Create: `agtermCore/Sources/SessionHostRuntime/HostIdentity.swift`
- Create: `agtermCore/Sources/SessionHostRuntime/HostSocket.swift`
- Create: `agtermCore/Sources/agterm-session-host/main.swift`
- Modify: `agtermCore/Package.swift`
- Modify: `agtermCore/Sources/agtermCore/SessionHost.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/SessionHostTests.swift`
- Create: `agtermCore/Tests/SessionHostRuntimeTests/SessionHostServerTests.swift`

- [x] add the Darwin-only `agterm-session-host` executable target and product as a thin shell over
      `SessionHostRuntime`
- [x] write failing tests for `Host.handle(ensure:)` with injected spawner and lister: daemon already
      listed yields `existing` with no spawn; leader appears on the second poll yields `created`; leader
      never appears yields `error(started)` after the deadline and terminates only the forked client
      pid with bounded escalation; a client that exits early yields `error(started)`; a fast
      side-effecting creation command that finishes before the poll is reported, not re-run
      Startup exceptions without proof that execution never began are `started`, not permission to replay.
- [x] write failing tests for framing: malformed, oversized, stalled peer past the deadline, disconnect
      mid-request; each closes that connection only
- [x] write a failing test that `stop` refuses while any rooted daemon is alive, refuses when the
      inventory cannot be read, and otherwise removes socket and pidfile while leaving both lock files
      in place; then a contending client starts a replacement host against the same lock inode
      Resolve and verify the shell's zmx parent: the shell may have adopted a different responsibility root.
- [x] write a failing test that a daemon and shell created through the host hold none of the host's
      descriptors: kill the host, confirm the lock and listener are free, confirm a new host can start
- [x] implement: `setsid`, stdio to `/dev/null`, log to `session-host.log`, take the owner `flock`,
      owner-only socket dir and socket, pidfile, handshake tied to the peer, one request per connection,
      readiness loop draining the temporary pty; every host-private descriptor `FD_CLOEXEC`
- [x] run `swift test --filter SessionHostServerTests` - must pass before task 5

### Task 5: The client mode and its ensure-or-spawn

**Files:**
- Create: `agtermCore/Sources/SessionHostRuntime/Client.swift`
- Modify: `agtermCore/Tests/SessionHostRuntimeTests/SessionHostServerTests.swift`
- Create: `agtermTests/SessionHostClientTests.swift`

- [ ] write failing unit tests for `Client.run(name:argv:)` against a fake host: `existing` and
      `created` exec plain attach; no host, handshake timeout, handshake declined and `error(before)`
      exec the payload attach without touching the host further; `error(started)`, lost reply and
      post-dispatch deadline exec plain attach after writing the diagnostic line; a fast side-effecting
      creation command runs at most once across a lost reply
- [ ] write a failing test that the client resolves its own bundle location from the process image with
      a dash-prefixed `argv[0]`, and that the endpoint comes from the pane's `ZMX_DIR`
- [ ] write failing hosted tests for ensure-or-spawn in an isolated state dir: no host yields one
      disclaimed host; two clients racing yield one host; owner lock held but socket not listening is
      not treated as dead; a stale pidfile with a dead pid never signals anything; the spawned host's
      handshake pid resolves to itself through `responsibleProcess(of:)`
- [ ] implement the client: capture `environ`, cwd and `TIOCGWINSZ`, ensure host, send, decide, `execve`
- [ ] run both test classes - must pass before task 6

### Task 6: Pane command and the seam in agterm

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ZmxSupport.swift`
- Modify: `agterm/Ghostty/ZmxLaunch.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ZmxSupportTests.swift`
- Modify: `agtermTests/ZmxLaunchTests.swift`

- [ ] write failing tests that `ZmxSupport.attachCommand` renders `<helper> client <name> -- <zmx> attach
      <name> [shell -lic script]` from a structured argv, preserving the replay script and the
      creation-only payload exactly as today
- [ ] write a failing test that with the helper absent from the bundle the rendered command is today's
      bare attach, and that a Re-run launch never renders the client at all
- [ ] implement: structured attach argv, helper path resolution beside `ZmxLaunch.executablePath` with
      the same `AGTERM_*_PATH` Debug override, rendering through `shellQuotedLine`
- [ ] write the differential hosted test: environment, cwd, initial winsize and login-shell behavior
      of a pane through the client versus bare attach, with a custom `ZDOTDIR`
- [ ] run the touched classes - must pass before task 7

### Task 7: Bundling, signing and release

**Files:**
- Modify: `project.yml`
- Modify: `scripts/release.sh`
- Modify: `.github/workflows/ci.yml`

- [ ] build the `agterm-session-host` product beside `agtermctl` in the "Bundle helper executables"
      phase, copy to `Contents/MacOS/agterm-session-host`, codesign `--options runtime`, no entitlements
- [ ] add the helper to both loops in `scripts/release.sh` that re-sign and check helpers
- [ ] add the helper to CI's helper entitlement assertion
- [ ] on a `scripts/build.sh` output, which is ad-hoc signed: verify the runtime flag and no
      entitlements on the helper
- [ ] produce a release-signed bundle WITHOUT running `scripts/release.sh`, which rewrites plugin
      versions and submits for notarization: build Release in the worktree, then apply the script's own
      inside-out timestamped `codesign` sequence by hand with the Developer ID identity present in the
      keychain; the first signing attempt may pause on keychain authentication, which needs Eugene
- [ ] on that bundle: verify Developer ID identity, runtime flag, secure timestamp and no entitlements
      on the helper; task 9 uses this bundle

### Task 8: Tree read-back of attribution, per pane

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProjection.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift`
- Modify: `agterm/Control/ControlServer.swift`
- Modify: `agterm/Control/ControlServer+Zmx.swift`
- Modify: `agtermCore/Sources/agtermctlKit/SocketClient.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreTreeProjectionTests.swift`
- Modify: `agtermTests/ControlServerZmxTests.swift`

- [ ] write failing projection tests for `liveAttribution` and `splitLiveAttribution`: absent for
      non-Live and remote sessions; `supervisor`, `app`, `orphaned`, `unknown` each; a hidden split
      still reported; pane identity followed through swap and promotion
- [ ] add the two fields and `SessionHost.classify(leader:responsible:hostPid:appPid:)`, where
      `responsible == leader` is `orphaned`, `responsible == hostPid` is `supervisor`,
      `responsible == appPid` is `app`, a responsible pid positively identified as dead is `orphaned`,
      a failed or absent lookup is `unknown`, and a live responsible pid that is none of those is
      `unknown`, never `orphaned`
- [ ] wire one leader snapshot per `buildTree` in `ControlServer.swift` through
      `ZmxClient.sessionLeaderPIDs` and `AgtermResponsibility.responsibleProcess(of:)`, probing each
      unique leader once, so the fields appear on every tree read and not only the zmx handlers
- [ ] print both in the human tree beside the existing per-pane detail, only when present
- [ ] write a failing hosted test: a pane through the client reads `supervisor`; after the host is
      killed it reads `orphaned`; a bare-attach pane created this launch reads `app`
- [ ] run the touched classes - must pass before task 9

### Task 9: Verify acceptance criteria

- [ ] in an isolated Release-signed instance with Live mode: create a pane, tree reads `supervisor`,
      quit, relaunch, same pane still `supervisor`, a new command in it resolves to the host, and a real
      AVFoundation microphone request from inside it is charged to the app bundle after the restart —
      this is the first grant test of the production helper, not the earlier C fixture
- [ ] a pane whose daemon predates the host reads `app` this launch and `orphaned` after a restart
- [ ] a daemon that dies after the launch inventory and before its surface is realized, primary and
      split, is recreated through the host rather than by a bare attach
- [ ] kill the host while a pane it created stays alive: the pane keeps running, the tree reads
      `orphaned` for it, and the next new pane gets a replacement host
- [ ] `AGTERM_UITEST_ENABLE_ZMX` unset spawns no host and no client request
- [ ] a remote session has no attribution fields and made no host request; `agtermctl zmx tree --json`
      on the isolated socket still lists a host-created daemon as attachable
- [ ] run full suites once: `cd agtermCore && swift test`, `make test-app`, `make lint`

### Task 10: Update documentation

- [ ] rewrite the App Data section of `docs/troubleshooting.md`: the loss is process attribution; the
      supervisor keeps new Live panes attributed to agterm, verified for the microphone; App Data is
      expected to follow but keeps Full Disk Access as the documented remedy for `orphaned` and `app`
      panes until tested; `liveAttribution` on the tree says which panes are which
- [ ] `git rm docs/backlog/live-session-panes-lose-responsible-app-attribution.md` in the same commit
- [ ] document the two fields in `site/commands.html` and `plugins/agterm/skills/agterm/`, and add one
      sentence to the Live sessions section of `site/docs.html`
- [ ] add a `.claude/rules/windows.md` note: host lifecycle, the one-target SPI boundary, the
      no-Swift-after-fork rule, and that Fresh shells and Re-run never stop a live host
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

**Deployed confirmation:** on the deployed Release build, with Live mode on, take a pane through a quit
and relaunch and trigger a microphone request from Claude Code inside it. Expected: no prompt, and
System Settings shows only the existing Agterm entry. Additional confirmation after task 9, not the
first grant test.

**Not covered:** daemons created before this ships stay as they are; the remedy for those remains
recreating the pane. App Data and other TCC services are expected to follow the microphone result and
are claimed only once each is tested.
