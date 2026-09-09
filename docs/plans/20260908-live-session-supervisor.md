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
  `ZDOTDIR`, must match; runtime-generated differences are measured and bounded in task 6
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
  libghostty has composed the environment, so the UI never blocks and the daemon gets the
  environment, cwd and winsize captured by the client (see task 6 for the Foundation cache exception). `ZmxSupport` renders the pane command from a
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
  re-checks and probes the owner lock, spawns the host with disclaim only when it is free, waits
  for the handshake, and releases. The host removes a stale socket after acquiring its lifetime lock. Lock files are never unlinked, only closed: a waiter holding the old
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
- Create: `agtermCore/Sources/SessionHostRuntime/ClientConnector.swift`
- Modify: `agtermCore/Sources/SessionHostRuntime/HostSocket.swift`
- Modify: `agtermCore/Sources/agterm-session-host/main.swift`
- Create: `agtermCore/Tests/SessionHostRuntimeTests/SessionHostClientTests.swift`
- Modify: `agtermCore/Tests/SessionHostRuntimeTests/SessionHostServerTests.swift`
- Create: `agtermTests/SessionHostClientTests.swift`

- [x] write failing unit tests for `Client.run(name:argv:)` against a fake host: `existing` and
      `created` exec plain attach; no host, handshake timeout, handshake declined and `error(before)`
      exec the payload attach without touching the host further; `error(started)`, lost reply and
      post-dispatch deadline exec plain attach after writing the diagnostic line; a fast side-effecting
      creation command runs at most once across a lost reply
- [x] write a failing test that the client resolves its own bundle location from the process image with
      a dash-prefixed `argv[0]`, and that the endpoint comes from the pane's `ZMX_DIR`
- [x] write failing hosted tests for ensure-or-spawn in an isolated state dir: no host yields one
      disclaimed host; two clients racing yield one host; owner lock held but socket not listening is
      not treated as dead; a stale pidfile with a dead pid never signals anything; the spawned host's
      handshake pid resolves to itself through `responsibleProcess(of:)`
- [x] implement the client: capture `environ`, cwd and `TIOCGWINSZ`, ensure host, send, decide, `execve`
- [x] run both test classes - must pass before task 6

Implementation notes: the client probes the owner lock but leaves stale socket removal to the host,
which already removes it only after acquiring its lifetime lock. Startup is bounded to 5 s,
handshake to 2 s, and the ensure exchange to 12 s for the host's 10 s creation budget. A client
without a readable terminal size uses 24 rows and 80 columns. Hosted fixtures initially copied the helper
built by the package tests; task 7 switches them to the test host bundle. No additional app
dependency is needed.

Validated: 29 client/host package tests, five isolated hosted client tests, and `make lint`.
The hosted tests also verify environment, physical cwd and 43×132 terminal size, and assert
that fixture hosts exit during cleanup.

### Task 6: Pane command and the seam in agterm

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ZmxSupport.swift`
- Modify: `agterm/Ghostty/ZmxLaunch.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ZmxSupportTests.swift`
- Modify: `agtermTests/ZmxLaunchTests.swift`
- Modify: `agtermTests/LaunchSeedTests.swift` (configuration initializer)
- Modify: `agtermTests/SurfaceFactorySeedTests.swift` (configuration initializer)
- Create: `agtermTests/SessionHostSeamTests.swift`

- [x] write failing tests that `ZmxSupport.attachCommand` renders `<helper> client <name> -- <zmx> attach
      <name> [shell -lic script]` from a structured argv, preserving the replay script and the
      creation-only payload exactly as today
- [x] write a failing test that with the helper absent from the bundle the rendered command is today's
      bare attach, and that a Re-run launch never renders the client at all
- [x] implement: structured attach argv, helper path resolution beside `ZmxLaunch.executablePath` with
      the same `AGTERM_*_PATH` Debug override, rendering through `shellQuotedLine`
- [x] write the differential hosted test: environment, cwd, initial winsize and login-shell behavior
      of a pane through the client versus bare attach, with a custom `ZDOTDIR`
- [x] run the touched classes - must pass before task 7

Implementation notes: `Configuration` now takes `executablePath` instead of a rendered `command`;
`attachArguments` and the bare `command` are derived from that path and the daemon name.
`Inputs.sessionHostExecutablePath` defaults to nil, and only an absolute executable helper is
carried into configuration. `ZmxLaunch` supplies the bundled helper path or the Debug-only
`AGTERM_SESSION_HOST_PATH` override. No command string is split.

The differential uses real `GhosttySurfaceView` surfaces for plain login shells and creation
payloads with a custom `ZDOTDIR`. Both arms match on cwd, initial winsize, login/interactive
options and zsh startup markers. A prestarted host with an older environment receives the
new pane environment. Full environment comparison excludes per-surface IDs and separately
checks `__CF_USER_TEXT_ENCODING`: loading Foundation changes its UID field from `0x0` to the
current UID (`0x1F6` on this machine), while the encoding fields match. A standalone C probe
reproduced that change using only `dlopen(Foundation)`, before any client logic. This is a
measured exception to byte-for-byte environment equality, not an omitted comparison.

Validated: 17 `ZmxSupportTests`, 12 `LaunchSeedTests`, 13 `SurfaceFactorySeedTests`,
12 `ZmxLaunchTests`, two `SessionHostSeamTests`, strict lint and whitespace checks.
Final process inspection found no fixture hosts, clients or daemons remaining.

### Task 7: Bundling, signing and release

**Files:**
- Modify: `project.yml`
- Modify: `scripts/release.sh`
- Modify: `.github/workflows/ci.yml`
- Modify: `.claude/rules/ci.md`
- Modify: `.claude/rules/release.md`
- Modify: `agtermTests/SessionHostClientTests.swift`
- Modify: `agtermTests/SessionHostSeamTests.swift`

- [x] build the `agterm-session-host` product beside `agtermctl` in the "Bundle helper executables"
      phase, copy to `Contents/MacOS/agterm-session-host`, codesign `--options runtime`, no entitlements
- [x] add the helper to both loops in `scripts/release.sh` that re-sign and check helpers
- [x] add the helper to CI's helper entitlement assertion
- [x] on a `scripts/build.sh` output, which is ad-hoc signed: verify the runtime flag and no
      entitlements on the helper
- [x] produce a release-signed bundle WITHOUT running `scripts/release.sh`, which rewrites plugin
      versions and submits for notarization: build Release in the worktree, then apply the script's own
      inside-out timestamped `codesign` sequence by hand with the Developer ID identity present in the
      keychain; the first signing attempt may pause on keychain authentication, which needs Eugene
- [x] on that bundle: verify Developer ID identity, runtime flag, secure timestamp and no entitlements
      on the helper; task 9 uses this bundle

Validated: `scripts/build.sh` succeeded using the matching staged libghostty and zmx artifacts.
All three bundled helpers have valid ad-hoc signatures, hardened runtime and no entitlements.
Both hosted fixture classes now copy the helper from `Bundle.main/Contents/MacOS`; all seven
tests passed with the old SwiftPM debug helper temporarily moved aside and restored afterwards.
The package server fixture retains its SwiftPM-built helper. Strict lint, release script syntax
and whitespace checks passed; no fixture processes remained.

The separate Developer ID signed copy for task 9 is
`build/session-host-release-task7/agterm.app` in this worktree. Manual inside-out signing used
`Developer ID Application: Brave Elk LLC (H7K73622CK)` with secure timestamps on every executable.
All helpers have no entitlements; the outer app has exactly the shipping entitlement set and
passes `codesign --verify --deep --strict`. No keychain interaction was needed.
`scripts/release.sh` was not run, and the signed copy was not launched or submitted for notarization.
Signature evidence: `/tmp/session-host-task7-signatures.log`.

### Task 8: Tree read-back of attribution, per pane

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProjection.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift`
- Modify: `agterm/Control/ControlServer.swift`
- Modify: `agterm/Control/ControlServer+Zmx.swift`
- Modify: `agtermCore/Sources/agtermctlKit/SocketClient.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreTreeProjectionTests.swift`
- Modify: `agtermTests/ControlServerZmxTests.swift`
- Modify: `agtermCore/Sources/agtermCore/SessionHost.swift`
- Modify: `agterm/Ghostty/ZmxForegroundResolver.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/SessionHostTests.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/SocketClientTests.swift`
- Modify: `agtermTests/SessionHostClientTests.swift` (shared fixture)

- [x] write failing projection tests for `liveAttribution` and `splitLiveAttribution`: absent for
      non-Live and remote sessions; `supervisor`, `app`, `orphaned`, `unknown` each; a hidden split
      still reported; pane identity followed through swap and promotion
- [x] add the two fields and `SessionHost.classify(leader:responsible:hostPid:appPid:)`, where
      `responsible == leader` is `orphaned`, `responsible == hostPid` is `supervisor`,
      `responsible == appPid` is `app`, a responsible pid positively identified as dead is `orphaned`,
      a failed or absent lookup is `unknown`, and a live responsible pid that is none of those is
      `unknown`, never `orphaned`
- [x] wire one leader snapshot per `buildTree` in `ControlServer.swift` through
      `ZmxClient.sessionLeaderPIDs` and `AgtermResponsibility.responsibleProcess(of:)`, probing each
      unique leader once, so the fields appear on every tree read and not only the zmx handlers
- [x] print both in the human tree beside the existing per-pane detail, only when present
- [x] write a failing hosted test: a pane through the client reads `supervisor`; after the host is
      killed it reads `orphaned`; a bare-attach pane created this launch reads `app`
- [x] run the touched classes - must pass before task 9

Implementation notes: the classifier receives `ResponsibleProcess.live(pid)`, `.dead` or
`.unknown` so host-free code does not confuse an absent lookup with a confirmed dead process.
The app confirms liveness with `kill(pid, 0)`; only ESRCH becomes `.dead`. The optional string
fields preserve decoding and initializer compatibility. Projection follows each local wrapped
pane identity, including hidden splits; absent readings become `unknown`.

`buildTree` takes a fresh `ZmxClient.sessionLeaderPIDs` map and shares it with the foreground
resolver, avoiding its former second listing. A failed map clears stale foreground leaders.
Responsibility results, including failures, are memoized only within the current tree build.
The host PID is read from the endpoint's `SessionHost.paths`, checked against the sibling helper
process image and verified as its own responsibility root. Readback never takes the owner lock.
A stale PID naming another executable is rejected. No host connection or spawn occurs on reads.

Validated: 120 host-free tests across SessionHostTests, AppStoreTreeProjectionTests and
SocketClientTests; 57 hosted tests across ControlServerZmxTests, ZmxForegroundResolverTests
and SessionHostClientTests; strict lint and whitespace checks. The real client/bare fixture
proved `supervisor` to `orphaned` after host death while the bare pane remained `app`, using
the measured test process responsibility root as its app PID. No fixture processes remained.

### Task 9: Verify acceptance criteria

- [x] in an isolated Release-signed instance with Live mode: create a pane, tree reads `supervisor`,
      quit, relaunch, same pane still `supervisor`, a new command in it resolves to the host, and a real
      AVFoundation microphone request from inside it is charged to the app bundle after the restart —
      this is the first grant test of the production helper, not the earlier C fixture
- [x] a pane whose daemon predates the host reads `app` this launch and `orphaned` after a restart
- [x] a daemon that dies after the launch inventory and before its surface is realized, primary and
      split, is recreated through the host rather than by a bare attach
- [x] kill the host while a pane it created stays alive: the pane keeps running, the tree reads
      `orphaned` for it, and the next new pane gets a replacement host
- [x] `AGTERM_UITEST_ENABLE_ZMX` unset spawns no host and no client request
- [x] a remote session has no attribution fields and made no host request; `agtermctl zmx tree --json`
      on the isolated socket still lists a host-created daemon as attachable
- [x] run full suites once: `cd agtermCore && swift test`, `make test-app`, `make lint`

Acceptance evidence (2026-09-09, HEAD `31200c59`): rebuilt Release and manually signed
`build/session-host-release-task9/agterm.app` with Developer ID, runtime and secure timestamps.
No release script, notarization or deployed app was used.

- Main state `/tmp/ag9dolx7a_v`: app `16067` then `19569`, persistent host `16093`.
  The restored pane stayed `supervisor`; post-restart command `20799` resolved to `16093`.
  AVFoundation requester `20808` returned `granted=true`. TCC logged its responsible process
  as the production helper and `AUTHREQ_SUBJECT ... subject=com.umputun.agterm`. The existing
  allowed bundle row was used; no helper/requester row or new user dialog was needed.
- Removing host `16093` left the same shell/daemon alive and the old pane `orphaned`.
  A new pane created replacement host `23501` and read `supervisor`.
- Legacy state `/tmp/ag9h2jzvk23`: a separately signed helper-absent fixture created a bare
  daemon under app `24098` and read `app`. After adding the helper and relaunching as
  `25085`, the same legacy pane read `orphaned`.
- UI-test state `/tmp/ag9_1tu9tyi`, app `21414`, had the UI-test sentinel but no Live opt-in:
  no host directory, no wrapper and no attribution fields.
- Remote state `/tmp/ag9e1maihsm`, app `26824`, used a private local SSH shim pointing at
  the main fixture's existing daemon. Discovery and the real remote-session creation path
  ran; the attacher remained live, the source showed two clients, and the remote instance
  had no host directory or attribution fields. This tests the app boundary, not an external
  network connection. The isolated `zmx tree --json` offered the host-created source.
- Added `agtermTests/SessionHostAcceptanceTests.swift`: primary and split surfaces are
  held at zero size after inventory, their daemon is removed, and realization creates a new
  leader under the same host. The fixture first releases its original attach client so that
  an unfinished initial ensure cannot race the new surface and invalidate the experiment.
- Full gates ran exactly once each: `swift test` passed 3,148 tests; `make test-app` passed
  606 tests; `make lint` passed. No boxes were blocked or skipped.

All manually launched instances, hosts, daemons and commands were stopped, and a final
process scan found no acceptance fixtures remaining. Detailed PIDs and saved trees are in
`/tmp/agt9-record.json`; TCC evidence is `/tmp/agt9-tcc.log`; full gate logs are
`/tmp/session-host-task9-full-{core,app,lint}.log`.

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
