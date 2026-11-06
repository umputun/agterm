# Linux remote server

## Overview
- Run sessions and the agents in them on a headless Linux server and use them from the Mac's agterm as if they were
  local: create a session, split it, swap, rename, close, and see status, context, HUD, asks, pick, program overlays
  and HTML/image/markdown/text pages drawn on the Mac. Sessions keep running while the Mac sleeps or disconnects.
- Two pieces:
  - **`agterm-server`**, a headless Swift executable in the `agtermCore` package, built for Linux. It runs the same
    `AppStore`, `ControlDispatcher`, `PresentationHub`, `OverlayJobs` and page channel as the Mac app, with no GTK,
    no libghostty and no windows. Every pane is a detached zmx daemon; nothing is drawn on the server.
  - **A remote window on the Mac**, bound to one server host. Its sidebar mirrors the server's catalog, and every
    structural action in it (new session, split, swap, rename, close, companions, workspaces, order) is a command
    on the server. The window the user is in decides where an action goes, so no state hidden from the screen
    picks the host.
- Today's per-session attach (`zmx attach`, Mac-to-Mac or to agterm-linux) stays unchanged in ordinary windows,
  including its local-shell split.
- Replaces the Sept 28 draft `docs/remote-agent-server.md` (Go relay plus SQLite store). The presentation stream
  that landed since (#793, #849, #891) already carries what that relay was for, and a Swift server applies the
  same core rules itself, so no second store or relay is needed.
- Design argued out with codex in the session that produced this plan; its review notes were
  `/tmp/agterm-linux-origin-review.md`, `/tmp/agterm-headless-origin-review.md` and
  `/tmp/agterm-remote-window-review.md` (scratch files, not kept). The decisions below are the agreed result.

## Decisions carried from the draft
Each decision of `docs/remote-agent-server.md`, and what this plan does with it.

| Draft decision | Here | Why |
|---|---|---|
| agterm behavior stays in agterm's Swift handlers | changed | the server runs the same Swift core rules itself |
| server tool in Go with SQLite | dropped | Swift on `agtermCore`; one catalog store, no second authority |
| one owner per session, last attach wins | dropped | several Macs per catalog is out of this release |
| remote rows mixed into local windows | changed | a remote window per host decides where actions go |
| close asks: keep running or end | kept | Detach (default) / Terminate sheet, per-Mac detach |
| unplaced sessions only through a connect picker; agent sessions never auto-placed | changed | the window mirrors the catalog, as a local `session new` shows its row; the Detached Sessions picker restores hidden ones |
| confirmed-gone row stays as `Ended on HOST`; unreachable is `Disconnected`, never `Ended` | kept | see "Ended sessions" in Solution Overview |
| offline presentation calls return `queued` | changed | status/context/HUD ride the snapshot; asks, pick, pages and jobs wait with a deadline |
| offline notify dropped | kept | no stale banners on wake |
| no always-running coordinator | dropped | the server is a long-running service observing its daemons |

## Context (from discovery)
- Shared core, already Linux-built by the agterm-linux fork's CI (`swift test` on ubuntu-24.04, Swift 6.3.2):
  `agtermCore/Package.swift` (products `agtermCore`, `agtermctl`, `agterm-session-host`), `AppStore*.swift`,
  `ControlDispatcher*.swift`, `PresentationHub.swift`, `PresentationFrames.swift`, `OverlayJobs.swift`,
  `PageServeFrames.swift`, `RemotePageResources.swift`, `ZmxSupport.swift`, `ZmxLead.swift`, `RemoteTree.swift`,
  `RemoteSession.swift`, `RemotePresentationClient.swift`, `RemotePresentationState.swift`, `WindowLibrary*.swift`.
- Mac host adapters (AppKit, not portable as-is, about 7,000 lines): `agterm/Control/ControlServer*.swift`,
  `ControlStreamOwner.swift` (Darwin `shutdown`, `SO_NOSIGPIPE`, `os`), `ControlServer+PageServe.swift`
  (`OSAllocatedUnfairLock`, UTType, `HtmlOverlayRegistry`), `ControlTargetResolver.swift` (resolves through
  `WindowLibrary.activeStore`, else a throwaway empty store), `RemotePresentationProcess.swift`.
- Surface-bound contracts a windowless origin breaks:
  - `Session.zmxBacking` reads `surface.backedByZmx` (`Session.swift:155`), so a session with no surface is not
    attachable and `RemoteTreeMerger.remoteSession` drops it.
  - `Session.paneRole(forToken:)` (`Session.swift:805`) resolves `--pane-id` through surface tokens.
  - `swapPanes` requires realized surfaces (`AppStore+Panes.swift:108`).
  - `Session.followsRemotely` (`ZmxLead.swift:176`) requires a local zmx client's follower report.
  - `pick` has no session target (`ControlDispatcher+Pick.swift`, `agterm/Control/ControlServer+Pick.swift`).
- Remote-attach limits the remote window must not inherit: remote rows are never persisted
  (`Session.isPersistable`, `Session.swift:67`); `RemoteBinding`'s pane maps are immutable; `applyRemoteLayout`
  only swaps an existing realized pair (`AppStore+RemoteLayout.swift:6`); the viewer never creates a pane from a
  layout (`.claude/rules/control-api.md:1903`); `PresentationSnapshot` carries no asks, pages or jobs
  (`PresentationFrames.swift:444`).
- `WindowLibrary.loadStore` (`WindowLibrary.swift:420`) restores from a local `windows/<id>.json`, seeds local
  sessions, and wires local save, finalization and Recent Closed.
- Portability gaps: `OverlayRunJob.swift:177` uses Darwin `POSIX_SPAWN_START_SUSPENDED`; `setup.sh` hardcodes
  `ZMX_TARGET="aarch64-macos.14.0"`; `CommandPath.standardDirectories` adds only the CLI install directory and
  `/opt/homebrew/bin` to the far side's PATH, not `~/.local/bin`; `agterm-codex-status.sh` calls `/usr/bin/plutil`.
- agterm-linux (melonamin's fork) is a GTK app that already acts as a presentation origin over the same protocol
  (its `ControlServer+Presentation.swift`, `ControlServer+PageServe.swift`, `ControlServer+OverlayJobs.swift`). It is
  reference for Linux branches (Glibc spawn, socket options), not code this plan copies.

## Development Approach
- **testing approach**: Regular (code first, then tests in the same task)
- complete each task fully before moving to the next; make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - tests are not optional - they are a required part of the checklist
  - write unit tests for new and modified functions/methods, success and error scenarios
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- per task, run only what changed: `cd agtermCore && swift test --filter <Suite>` and
  `-only-testing:<Target>/<Class>/<test>` for hosted or UI tests; the full gates run once, in the acceptance task
- every task that changes `agtermCore` also builds it on Linux (the CI job from Task 2, or a local Linux container)
- keep `public` symbols stable: `agtermCore` is consumed by the agterm-linux fork; a new requirement on
  `ControlActions` gets a default in `ControlActionsDefaults.swift`
- read the matching `.claude/rules/*.md` before each subsystem (`control-api.md`, `windows.md`, `sidebar.md`,
  `menu-actions.md`, `ui-tests.md`)

## Testing Strategy
- **unit tests**: `agtermCore/Tests/agtermCoreTests` (Swift Testing) for every core change; a new
  `agtermCore/Tests/AgtermServerTests` target for the server; `agtermctlKitTests` for CLI portability. All run on
  macOS and on the Linux CI job.
- **hosted tests**: `agtermTests` for the Mac remote window store source, reconciliation and action routing.
- **UI tests**: `agtermUITests` for opening a remote window, new session, split, rename and close against a server
  running in a local Linux container.
- **end-to-end**: a scripted harness that starts `agterm-server` in a local Linux container with sshd and drives an
  isolated Debug instance against it over real ssh; never the live terminal's socket.

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- keep plan in sync with actual work done

## Solution Overview
- **Ownership.** The server owns everything that exists on it: workspaces, sessions, panes, split pair, axis, shown
  state, swap, names, cwd, companions, order, process launches, scratch, overlays' programs. The Mac owns how it
  shows them: selection, keyboard focus, font size, divider ratio, window frame and sidebar chrome. A second Mac
  opening the same server sees the same sidebar.
- **One catalog per host, one remote window per catalog per Mac app.** Opening it again raises the existing window.
- **Two channels, both over ssh.**
  - Structural writes go as `RemoteSession.controlCommand` (ssh running the server's `agtermctl`), so they work with
    zero sessions and survive the target's deletion. The server's dispatcher applies them with the same rules as a
    local window.
  - A new catalog subscription (`agtermctl catalog subscribe` over `ssh -T`, the same bridging as `zmx present`)
    streams an epoch/revision-numbered snapshot and deltas of the whole catalog. It is the single source the
    remote window reconciles from; a reply never mutates the mirror directly.
  - Session effects keep using today's per-session presentation stream unchanged.
- **Sessions with no surface.** On the server a pane is a detached zmx daemon (`zmx run NAME -d COMMAND`) recorded in
  the model with its stable pane identity; attachability, `--pane-id` resolution and swap read that state, never a
  surface. The Mac attaches each pane with today's `zmx attach` over ssh.
- **Presentation without a local client.** A headless origin delegates asks, pick, pages and program overlays to its
  elected presenter; a Mac origin keeps today's follower gate. zmx pane leadership stays the Mac attach clients'
  input/size contract, unchanged.
- **No Mac connected.** Status, context and HUD keep riding the existing snapshot. Asks, pick, pages and program
  overlays opened with no presenter wait with a deadline and are offered to the next Mac that connects; a claimed
  or unknown program job is never launched again. Pending interactions live in memory: a server restart cancels
  them and the waiting `agtermctl` call fails with an error. Notify stays dropped, as today.
- **Disconnected window.** Keeps the last sidebar and screens in memory, marked Disconnected; local navigation and
  window actions work; server mutations are disabled and never queued; there is no local fallback. A cold-reopened
  remote window shows Connecting until it has authoritative state and never seeds a local shell.
- **Close detaches by default.** Closing the remote window detaches its view. Closing a session, companion group or
  workspace in it opens a sheet naming the host: **Detach** (default button) keeps every pane and scratch running on
  the server and hides the row on this Mac; **Terminate** ends it on the server for every viewer; **Cancel**. The
  sheet says that running program overlays close either way, since they live only as long as their ssh terminal.
  Detached ids are this Mac's view state, persisted with the remote window entry, so detaching works while
  disconnected and never touches the server. A "Detached Sessions" picker in the remote window brings one back.
  Terminate has no undo grace and no Reopen Closed entry in this release.
- **Ended sessions.** A pane whose shell exits normally closes as it does locally. A pane whose daemon the server
  confirms gone without that exit (killed, crashed, host rebooted) is treated like any lost pane: a live split is
  promoted and keeps running. Only when no live pane is left does the session stay in the catalog as `ended`, its
  row where it is, marked `Ended on HOST`, with its last screen readable on a Mac that still holds it, until the
  user closes it. Closing skips the sheet only when nothing in the affected group still runs, and then removes the
  ended records on the server; an ended parent with live companions gets the normal Detach/Terminate sheet, so
  closing an Ended row never silently ends running work. An unreachable server or an incomplete answer is
  `Disconnected`, never `Ended`.
- **Stays local in a remote window:** settings, theme, keymap, the quick terminal, app-global maintenance, and custom
  commands. A custom command's session operations route to the server through `agtermctl`; its shell body runs on
  the Mac.
- **Out of this release:** server-owned undo/Reopen Closed, defined behavior for several Macs viewing one catalog
  at once beyond today's first-stream-wins presenter rule, and a macOS server target. Server code keeps its
  platform parts (service manager, process placement, cwd source, socket paths) behind one seam each, so a macOS
  target is an added implementation, not a rewrite (filed as a backlog item when this plan lands; see
  Post-Completion).

## Technical Details
- **Catalog wire types** (`agtermCore`, `CatalogFrames.swift`): `CatalogSnapshot {epoch, rev, catalogID, workspaces:
  [CatalogWorkspace]}`, `CatalogWorkspace {id, name, sessions: [CatalogSession]}`, `CatalogSession {id, name,
  parent?, cwd, panes: [CatalogPane], primary, axis?, shown, lifecycle}`, `CatalogPane {identity, daemon,
  endpoint}`, `CatalogDelta {epoch, rev, body}` with workspace/session/pane added, changed, removed. A new epoch
  means a server restart: the client discards its revision and takes the next snapshot whole. Newline-delimited
  JSON with the presentation stream's frame cap; unknown kinds skipped.
- **Catalog id** is a durable UUID in the server state dir; it fills `ControlRemoteSession.windowID`/`windowName`
  on the wire and the remote window's binding. Physical window commands on the server are refused.
- **Structural commands** are the existing ones (`session.new`, `session.split`, `session.split.close`,
  `session.swap`, `session.rename`, `session.close`, `workspace.*`, `session.move`, companion creation), each pinned
  to catalog, session and pane identities at invocation, with origin selection side effects suppressed.
- **Operation receipts.** Every structural command carries an `opID` and the epoch the Mac last saw; a command
  naming another epoch is refused. The reply is a receipt `{opID, epoch, outcome: applied(rev) | noop |
  refused(error)}`. The server keeps an op table, `opID → outcome` plus `fenced`, bounded to the most recent
  operations and written in the same save that commits each change to the persisted catalog, so an operation that
  committed before a restart is still answerable after it.
  The same `opID` sent again returns the recorded outcome and never runs twice. `agtermctl catalog op OPID` answers
  from the table; asking about an `opID` the server has not seen records it as `fenced`, so a delayed arrival of
  that command is refused. The mirror's per-target `pending(opID)` clears on its own receipt, for `applied` once the
  mirror has reached `(epoch, rev)`; revisions compare only within one epoch, and a receipt from an epoch the mirror
  has not reached waits for that epoch's snapshot. A timeout or lost reply turns it into `unknown(opID)`, settled
  only by that lookup, before or after a restart; an operation the table no longer holds stays visibly unknown,
  is never retried, and the user acts on the sidebar as it now stands. A snapshot never settles an operation, and
  the mirror itself still changes only from catalog state.
- **One writer of pane structure.** For rows of a remote window the catalog owns pane lifecycle: the per-session
  presentation stream's `layout` frames and snapshot layout are ignored for them, so a late presentation frame cannot
  swap, hide or close a pane the catalog installed. Per-session attach rows keep today's layout handling.
- **Job offers.** Each offer of a pending job carries its own claim token bound to the presenter generation; the
  run-job claim validates the token, and presenter loss invalidates it atomically. Job identity and offer identity
  are separate, so a late helper from an earlier presenter can never start a re-offered program.
- **Process placement.** Under a systemd user manager each zmx daemon starts in its own transient scope
  (`systemd-run --user --scope`), outside the server unit's cgroup, so stopping, restarting, upgrading or crashing
  the server never signals a pane; without systemd (tests) daemons spawn directly. The server never runs the
  zero-client reap (`ZmxReapPolicy.namesToKill`): with no Mac connected every pane has zero clients.
- **Shells.** Server panes accept zsh, fish and bash login shells, each with ghostty's shell integration (OSC 7 cwd,
  prompt marks, `AGTERM_*` environment); any other shell is refused with a message naming the supported ones. The
  Mac's Live-mode shell rule is unchanged.
- **cwd without a terminal.** The server reads each pane's cwd from `/proc/<pid>/cwd` of the pane's foreground
  process on every observation tick, so split and new session inherit it and `tree` reports it.
- **zmx sockets on Linux** live under `$XDG_RUNTIME_DIR/agterm-zmx-<hash>` (kept by linger), never `/tmp`, which
  distribution tmp cleanup can empty under a live daemon; the Mac attaches through the advertised endpoint as today.
- **Only a headless server serves the catalog.** The Mac app's `ControlActions` default refuses `catalog subscribe`
  and the receipt-bearing structural commands, and a remote window refuses an origin whose version advertisement
  has no catalog version, so a remote window can never drive a live Mac's windows.
- **Shared ssh connections per host.** A remote window keeps a small pool of ssh `ControlMaster` connections (with
  `ControlPersist`) per host, each carrying at most 8 session channels, below stock sshd's `MaxSessions 10`; pane
  attaches, presentation streams, control commands, page serve and port forwards take a channel from the pool, which
  adds a master when all are full. Reconnecting after sleep costs one handshake per master, not one per pane, and the
  server's sshd config is never changed.
- **Terminfo on the server.** The server ships ghostty's `xterm-ghostty` terminfo entry and sets `TERMINFO` for its
  panes and program overlays whose `TERM` names it; `TerminfoInstall` gains the Linux lookup.
- **Oversized snapshots.** A catalog or pending-interaction snapshot larger than the 256 KiB frame cap is sent as
  numbered chunk frames ending in a commit frame; the client applies nothing until the commit arrives.
- **Linux rendezvous.** On Linux, `agtermctl` with no `--socket` and no `AGTERM_STATE_DIR` resolves
  `$XDG_STATE_HOME/agterm` (default `~/.local/state/agterm`), the same default `agterm-server` uses, so a fresh
  ssh command with a bare environment reaches the server. The installed server always uses that default; a custom
  server state dir is not supported, so `remotes.conf` keeps its `destination [label...]` format unchanged and the
  remote window picks hosts from the same list as Attach Remote. The Mac CLI's precedence is unchanged.
- **Pending interaction states** (`agtermCore`): `unpresented`, `offered(generation)`, `claimed`, `terminal(outcome)`,
  negotiated through a new hello kind; a job's claim window starts at handoff, not at enqueue.
- **Server state dir**: `$AGTERM_STATE_DIR` or the Linux default above; holds the persisted catalog, the catalog id
  and the control socket; one server per state dir under the existing `flock` rule. The persisted catalog excludes
  scratch panes; the live catalog subscription includes them so a Mac can attach and read back. Scratch daemons
  carry their own name shape (`agterm-scratch-<uuid>`), so a restarted server ends only those and adopts the rest.

## What Goes Where
- **Implementation Steps** (`[ ]` checkboxes): code, tests, scripts, CI and docs in this repository.
- **Post-Completion** (no checkboxes): checks on a real remote Linux host and decisions needing Eugene.

## Implementation Steps

### Task 1: Mac-to-Linux attach gate against agterm-linux

**Files:**
- Create: `scripts/linux-origin-gate.sh`
- Create: `docs/remote-linux-gate.md`

- [ ] the script launches the Debug instance with a short `/tmp` `AGTERM_STATE_DIR` it creates itself, including
      the `windows` marker, and refuses to run when that variable is unset or names the live state dir
- [ ] build a local Linux container (arm64, sshd, key auth) running agterm-linux at a pinned commit in Live mode
      under a headless compositor with software GL, with its patched zmx and `agtermctl` on the ssh PATH
- [ ] attach to one of its sessions from an isolated Debug instance over real ssh (`zmx attach HOST ID
      --companions`): confirm presentation `connected`, status, context, HUD, ask, program overlay with `--block`,
      HTML file page and group attach
- [ ] detach during an ask, a page and a running program, reconnect, and relaunch the Debug instance; record what
      each does
- [ ] record results, failures and unsupported kinds (image/markdown/text pages, pick, loopback URLs) in
      `docs/remote-linux-gate.md`; a protocol incompatibility found here is fixed in core before Task 3
- [ ] stop the container and the Debug instance by pid and confirm with `lsappinfo` that nothing lingers

### Task 2: Linux build foundation

**Files:**
- Modify: `agtermCore/Package.swift`
- Modify: `agtermCore/Sources/agtermctlKit/OverlayRunJob.swift`
- Modify: `agtermCore/Sources/agtermctlKit/SocketClient.swift` (only if the Linux build needs it)
- Modify: `agtermCore/Sources/agtermctlKit/Commands.swift` (`BasicOptions.socketPath`)
- Modify: `.github/workflows/ci.yml`
- Modify: `.claude/rules/ci.md`
- Create: `scripts/setup-zmx-linux.sh`
- Modify: `scripts/zmx-patches/README.md`
- Modify: `agtermCore/Tests/agtermctlKitTests/OverlayRunJobTests.swift`

- [ ] make `agtermCore` and `agtermctlKit` build and test on Linux: a Glibc branch for the suspended-spawn
      handoff in `OverlayRunJob`, and any other Darwin-only call the build reports
- [ ] add a Linux CI job (ubuntu-24.04, pinned Swift 6.3.x, its own `timeout-minutes`) running `swift build` and
      `swift test` for the package, wired into the existing change filters
- [ ] build the patched zmx for `aarch64-linux-musl` and `x86_64-linux-musl` from the same `ZMX_REV` and patches,
      with its own stamp
- [ ] stage ghostty's shell-integration directory (zsh, fish, bash) and its `xterm-ghostty` terminfo entry at
      `GHOSTTY_REV` as Linux artifacts, with the same stamp rule
- [ ] probe the static Linux SDK (musl) with the existing package (`agtermctl`); record whether Foundation use builds
      there, which decides packaging in Task 12
- [ ] Linux CLI rendezvous: `BasicOptions.socketPath` resolves the Linux default when neither `--socket` nor
      `AGTERM_STATE_DIR` is set; Mac resolution unchanged
- [ ] tests: `OverlayRunJob` spawn handoff on both platforms; socket path resolution per platform and precedence;
      Linux CI green on the unchanged suite

### Task 3: Windowless core contracts

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Session.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift`, `AppStore+Panes.swift`
- Modify: `agtermCore/Sources/agtermCore/ZmxLead.swift`, `RemoteTree.swift`, `AppStore+Presentation.swift`,
  `AppStore+RemoteAsk.swift`, `AppStore+RemotePage.swift`, `AppStore+RemoteOverlay.swift` (every `followsRemotely`
  caller)
- Modify: `agtermCore/Sources/agtermCore/ControlProjection.swift` (pending pick on the session node)
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher+Pick.swift`, `ControlActionsDefaults.swift`,
  `PresentationFrames.swift`, `PresentationHub.swift`, `RemotePresentationClient.swift`
- Modify: `agtermCore/Sources/agtermctlKit/` (pick `--session`)
- Modify: `agterm/Control/ControlServer+Pick.swift`, `ControlServer+RemotePresentation.swift`
- Modify: matching tests in `agtermCore/Tests/agtermCoreTests/`

- [ ] model daemon backing as session state keyed by stable pane identity, so attachability (`zmxBacking`,
      `RemoteTreeMerger`) and `paneRole(forToken:)` work with no surface; the Mac keeps deriving it from surfaces
- [ ] decouple `swapPanes` and split on/off/close from realized surfaces for a store marked headless
- [ ] add a headless-origin presentation rule: with no local client, asks, pick, pages and jobs route to the elected
      presenter; the Mac origin's follower gate is unchanged
- [ ] session-bound pick, end to end: `agtermctl pick --session`/env, wire arguments, a session-targeted
      `ControlActions.openPick` overload with a default (the existing window/follow witness stays), presentation
      frames for pick request, result and cancel, the Mac presenter's receiver, and the origin's routing; today's
      window-scoped pick stays for untargeted calls; a session-bound pick in flight is reported on that session's
      `tree` node, beside the per-window `pickPending`
- [ ] a durable catalog root for a windowless store: logical window id/name on the wire, a default workspace, and
      refusal of physical window commands
- [ ] tests: backing and token resolution without surfaces, swap/split on a headless store, presenter routing for
      both origin kinds, pick request/result/cancel across the stream, old witness still compiles and behaves, Mac
      behavior unchanged; hosted `agtermTests` for the Mac pick receiver (`-only-testing`)

### Task 4: Server runtime and session lifecycle

**Files:**
- Modify: `agtermCore/Package.swift`
- Create: `agtermCore/Sources/agterm-server/` (executable target)
- Create: `agtermCore/Sources/AgtermServerKit/` (server library: socket server, provisioning, actions)
- Create: `agtermCore/Sources/agtermCore/ControlStreamFraming.swift` (portable framing extracted from
  `agterm/Control/ControlStreamOwner.swift`)
- Modify: `agterm/Control/ControlStreamOwner.swift`
- Modify: `agtermCore/Sources/agtermCore/ZmxSupport.swift` (Linux socket directory, server shell configuration)
- Modify: `.github/workflows/ci.yml` (real-zmx lifecycle run on the Linux job)
- Create: `agtermCore/Tests/AgtermServerTests/`

- [ ] `agterm-server` executable: main-actor run loop, state dir lock, durable catalog id, `AppStore` restored from
      and saved to the server state dir
- [ ] Linux control socket server on the shared framing (stream ownership, backpressure), with the Mac's
      `ControlStreamOwner` moved onto the same framing; only server-supported commands accepted, the rest refused
- [ ] `ControlActions` for the server: `session.new`, split on/off/close, swap, rename, close, workspace create,
      rename, delete and move, companions, `session text`/`type` through zmx; each provisions or ends detached zmx
      daemons (`zmx run NAME -d`) with the session environment
- [ ] process placement: under a systemd user manager each daemon starts in its own transient scope, outside the
      server unit's cgroup; the server never runs the zero-client reap
- [ ] shells: zsh, fish and bash login shells with ghostty's shell integration from the Task 2 artifact; other
      shells refused with a message naming the supported ones; Mac Live-mode shell rule unchanged
- [ ] Linux zmx socket directory under `$XDG_RUNTIME_DIR`; Mac resolution unchanged
- [ ] terminfo: `TerminfoInstall` finds the server's shipped `xterm-ghostty` entry on Linux, and panes and program
      overlays whose `TERM` names it get `TERMINFO` pointing at it
- [ ] continuous daemon observation replacing the renderer's callbacks: a primary or split shell that exits ends
      its pane (a live split is promoted, a parent with companions respawns as on the Mac), a daemon that vanishes
      while running ends that pane only (a live split is promoted), and a session left with no live pane stays in
      the catalog as `ended`, removed only by `session.close` on it; each
      pane's cwd is read from `/proc/<pid>/cwd` of its foreground process so split and new session inherit it
- [ ] restart reconciliation: a restarted server adopts surviving daemons from the catalog, marks missing ones
      ended, and never reaps a live pane
- [ ] `scripts/server-container.sh`: builds the Linux `agterm-server`, `agtermctl`, zmx and shell integration from
      this tree into a local container with sshd, key auth and a systemd user manager with linger, starts or stops
      it, and prints the ssh host; every later task's container checks use it
- [ ] Linux CI: the Linux job builds the musl zmx and runs the `AgtermServerTests` lifecycle suite against a real
      daemon (`AGTERM_REQUIRE_ZMX=1`), mirroring the macOS job
- [ ] tests: lifecycle of each command against a fake zmx runner and against a real daemon; natural primary and
      split exit, missing daemon while running, cd then split/new-session cwd, all with no Mac connected; restart
      adoption; zsh, fish and bash panes and a refused shell; socket directory per platform; a program overlay with
      `TERMINFO` unset and no system `xterm-ghostty` entry still resolves it; refusal of unsupported
      commands; framing on both platforms; in the container, a live pane survives `systemctl --user restart` and a
      killed server process

### Task 5: Server presentation, jobs and pages

**Files:**
- Modify: `agtermCore/Sources/AgtermServerKit/`
- Create: `agtermCore/Sources/agtermCore/PageServeStream.swift` (portable part of
  `agterm/Control/ControlServer+PageServe.swift`)
- Modify: `agterm/Control/ControlServer+PageServe.swift`, `ControlServer+Presentation.swift`,
  `ControlServer+OverlayJobs.swift`
- Modify: `agtermCore/Sources/agtermCore/CommandPath.swift`
- Create/modify: tests in `AgtermServerTests` and `agtermCoreTests`

- [ ] server `ControlActions` producing session effects: status, context, HUD, notify, ask, pick, overlay open
      (program and every page kind) and their follow-ups (close, resize, reload, cancel, result), feeding the hub
- [ ] serve `zmx tree`, `zmx present`, overlay job claim/run and page serve from the server through the same core
      engines the Mac uses; page bridge requests dispatch through the control dispatcher, not the GUI registry
- [ ] image, markdown and text pages and HTML/URL pages from a headless origin reach the presenter
- [ ] add `~/.local/bin` to the far-side PATH the Mac's ssh commands prepend, after the existing entries
- [ ] today's per-session `zmx attach` from the Mac to an `agterm-server` session works unchanged: the Task 1 gate
      re-run against `scripts/server-container.sh`
- [ ] tests: presentation snapshot and deltas from a headless store, job claim once, page fetch and bridge, PATH
      composition; hosted `agtermTests` for the changed `ControlServer+PageServe`, `+Presentation` and
      `+OverlayJobs` paths (`-only-testing`)

### Task 6: Catalog subscription

**Files:**
- Create: `agtermCore/Sources/agtermCore/CatalogFrames.swift`, `CatalogHub.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`, `ControlDispatcher.swift`
- Modify: `agtermCore/Sources/agtermctlKit/` (new `catalog subscribe` bridge command)
- Modify: `agtermCore/Sources/AgtermServerKit/`
- Create: `agtermCore/Tests/agtermCoreTests/CatalogHubTests.swift`

- [ ] catalog snapshot and deltas with epoch and revision, covering workspaces, sessions, panes, names, order,
      companions and lifecycle; subscriber registered before the snapshot so nothing falls between
- [ ] `agtermctl catalog subscribe` bridging stdio to the server's catalog stream, the same way `zmx present` does
- [ ] resnapshot on reconnect and on a new epoch; unknown kinds skipped without ending the stream; a snapshot over
      the frame cap goes as chunks plus a commit frame
- [ ] operation receipts: every structural command accepts an `opID` and the expected epoch, refuses a stale epoch,
      and replies `applied(rev)`, `noop` or `refused`; the bounded op table, saved with the catalog, answers a
      repeated `opID` with its recorded outcome, and `agtermctl catalog op OPID` answers lookups, fencing an unseen
      `opID`
- [ ] the Mac app's `ControlActions` default refuses `catalog subscribe` and receipt-bearing structural commands
- [ ] version advertisement: the catalog snapshot and `agtermctl version` against the server report server,
      protocol and catalog versions
- [ ] tests: snapshot/delta ordering, restart epoch, every structural command producing the right delta and
      receipt, refusal and no-op receipts, a repeated `opID` never running twice, a lookup fencing an `opID` that
      arrives later, a stale-epoch command refused, an operation that committed and lost its reply still answered
      by lookup after a server restart, chunked snapshot applied only at commit, version fields in the
      snapshot and in `agtermctl version`, the Mac app refusing `catalog subscribe`

### Task 7: Mac remote window store source

**Files:**
- Modify: `agtermCore/Sources/agtermCore/WindowLibrary.swift`, `WindowLibrary+RecentClosed.swift`
- Create: `agtermCore/Sources/agtermCore/RemoteCatalogMirror.swift`
- Modify: `agtermCore/Sources/agtermCore/RemotePresentationState.swift` (mutable bindings for catalog panes)
- Create: `agterm/Control/RemoteCatalogProcess.swift`
- Modify: `agtermCore/Sources/agtermCore/RemoteSession.swift` (ssh `ControlMaster` per host),
  `RemotePresentationClient.swift`, `AppStore+RemoteLayout.swift`, `agterm/agtermApp+RemoteLayout.swift` (layout
  frames ignored for catalog rows)
- Modify: `agterm/agtermApp+Menus.swift`, `agterm/AppActions.swift`, `agterm/ContentView.swift`
- Create: tests in `agtermCoreTests` and `agtermTests`

- [ ] window entries carry a source, local or remote(host, catalogID); a remote entry persists host, catalog id and
      local view state (selection, focus, font, ratio, frame), never sessions, and is skipped by seed, save,
      finalization and Recent Closed
- [ ] the mirror reconciles the catalog into its store by identity and revision: creates and removes replica
      sessions and panes, attaches each pane with `zmx attach`, keeps local view state, and never starts a local
      shell for a pane whose attach is starting or failed
- [ ] an ssh exit or removal settles the named attachment, not a newer occupant of the same slot
- [ ] ended sessions: a catalog session in the `ended` state keeps its row marked `Ended on HOST` with the last
      screen readable when this Mac held it (a relaunched Mac shows the row without a screen); closing it skips the
      sheet and removes the ended records only when nothing in the affected group runs, and otherwise opens the
      Detach/Terminate sheet; Disconnected never turns a row into Ended
- [ ] the catalog is the only writer of a remote window's pane structure: presentation `layout` frames and snapshot
      layout are ignored for its rows; per-session attach rows keep today's handling
- [ ] a per-host pool of ssh `ControlMaster` connections, each carrying at most 8 session channels, shared by pane
      attaches, presentation streams, control commands, page serve and forwards; a full pool adds a master, and a dead
      master is replaced once and its users reconnect through the pool
- [ ] Connecting, Connected and Disconnected states shown in the window; last sidebar and screens kept while
      disconnected; reconnect takes a fresh snapshot
- [ ] protocol check at connect: the Mac reads the server's protocol and catalog versions and refuses an
      unsupported server, or an origin with no catalog version (a Mac app), with a message naming both
- [ ] open from File ▸ Open Remote Window (hosts from `remotes.conf`) and from the control API: protocol command
      `window.remote.open {host}`, dispatcher, `ControlActions` with a default, `agtermctl window remote open HOST`;
      opening a host or catalog already open raises that window and returns its id; closing the window detaches;
      `tree` reports the window's `remote {host, catalogID, state}`
- [ ] checkpoint: build and launch an isolated Debug instance against `scripts/server-container.sh` and show Eugene the
      remote window (sidebar, connection state, a disconnected window) before writing its hosted and UI tests;
      adjust from his verdict
- [ ] tests: source persistence round trip, reconciliation (add, remove, reorder, epoch change), slot settlement,
      state transitions, no local seed on cold reopen, `window.remote.open` dedup and read-back; an older
      presentation snapshot delivered after a newer catalog split, swap and removal changes nothing; refusal of an
      origin without a catalog version; in the container with stock sshd (`MaxSessions 10`), opening and
      reconnecting a 20-session catalog after a dropped link brings back every pane and stream; a killed daemon
      leaving an Ended row with its screen, a killed primary with a live split promoting the split instead, an
      ended parent with live companions getting the sheet on close, a normal shell exit closing the row, an
      unreachable server staying Disconnected, and closing an inert Ended row removing the record

### Task 8: Structural actions routed to the server

**Files:**
- Create: `agtermCore/Sources/agtermCore/RemoteCatalogActions.swift`
- Modify: `agterm/AppActions*.swift`, `agterm/Views/SidebarRenameController.swift`,
  `agterm/Views/WorkspaceSidebar+DragDrop.swift`, `WorkspaceSidebar+ContextMenu.swift`,
  `WorkspaceSidebar+Companions.swift`
- Modify: `agterm/Control/ControlTargetResolver.swift`, `agterm/Control/ControlServer+SessionActions.swift`
- Create: tests in `agtermCoreTests`, `agtermTests`, `agtermUITests`

- [ ] one action seam scoped by window source: new session, split on/off/close, swap, rename (inline too), reorder,
      move between workspaces, companions, workspace create/rename/delete and session/workspace close go to the
      server as control commands in a remote window, and stay local in a local window
- [ ] per-operation pending and unknown states cleared by their own receipts compared on `(epoch, rev)`, repeat
      actions held while pending, an unknown outcome settled only by `catalog op` lookup, before or after a server
      restart, never from a snapshot, and left visibly unknown when the table no longer holds it; ssh runs off the
      main thread
- [ ] mutations disabled while Disconnected; drag between a remote and a local window refused
- [ ] close in a remote window (session, companion group, workspace) opens the Detach/Terminate/Cancel sheet naming
      the host, Detach the default button; Terminate ends it on the server, scoped from the full catalog including
      detached children, with no undo grace and no Reopen Closed entry; app quit never finalizes server state
- [ ] detach: the remote window's entry persists the detached session, group and workspace ids; detaching stops
      those panes' and scratch's attach clients and releases their presenter, so pending work follows the
      no-Mac-connected rules; running program overlays close as their ssh terminal ends; it works while
      Disconnected and sends nothing to the server
- [ ] detached rows stay hidden through natural exit, split promotion and parent respawn; a companion created under
      a detached parent is hidden with it; a detached session that becomes `ended` stays hidden, and an id is pruned
      from the set only when its record is removed from the catalog; nothing detached is ever relaunched
- [ ] "Detached Sessions" picker in the remote window (File menu and palette) lists the detached sessions and
      workspaces whose records still exist, ended ones marked as ended; it reattaches a live one, and offers an
      ended one only for record cleanup under the Ended close rule
- [ ] control coverage: new commands `session.detach` and `session.reattach` (and `workspace.detach`/
      `workspace.reattach`) for remote-window rows only, refused elsewhere, with dispatcher, `ControlActions` defaults
      and `agtermctl session detach|reattach`; `session.close` keeps its terminating meaning everywhere, so recipes
      such as `close-tab-when-done` and agents on the server are unchanged; `tree` lists the remote window's detached
      ids
- [ ] the local control API targets a remote window's sessions through the same seam, and `tree` reports
      per-session pending state
- [ ] tests: routing per source for every action; pending lifecycle for applied, no-op, refused, unrelated delta,
      delta before reply, lost reply settled by lookup, an unchanged snapshot followed by delayed execution (fenced),
      a delayed command crossing a server restart, a create that commits, drops its reply and survives a restart
      (settled as applied by lookup), and a receipt from a newer epoch; disabled-while-disconnected; the sheet's
      Detach, Terminate and Cancel paths for a session, a group and a workspace (including an empty one); detach
      while Disconnected; detached state across Mac relaunch, natural exit, respawn and a new companion; a detached
      session that becomes ended staying hidden through a Mac relaunch and listed as ended in the picker, pruned only
      when its record is removed; Terminate reaching detached children; `session.detach` refused on a
      local session and `session.close` still terminating; control API read-back; UI tests in `agtermUITests` for
      new session, split, rename, detach, reattach and terminate against `scripts/server-container.sh`, run with
      `-only-testing` and skipped when no server host is configured

### Task 9: Server scratch and custom commands in a remote window

**Files:**
- Modify: `agtermCore/Sources/AgtermServerKit/`, `agtermCore/Sources/agtermCore/` (scratch pane in the catalog)
- Modify: `agterm/AppActions*.swift` (scratch toggle), `agterm/Commands/CustomCommandRunner.swift`
- Create: tests in `AgtermServerTests`, `agtermTests`

- [ ] scratch in a remote window opens an ephemeral server-side zmx daemon attached like any pane; hiding it keeps
      the same shell, as `toggleScratch` does locally; closing the remote window detaches it like every pane; only
      its shell exiting, closing its session, or a server restart ends it; the live catalog shows it, the
      persisted catalog excludes it; scratch daemons use the `agterm-scratch-<uuid>` name shape, so a restarted
      server ends only those and adopts every other daemon
- [ ] control coverage: `session.scratch` against a remote window's session routes through the seam (protocol,
      dispatcher, `agtermctl`), and the session's `tree` node reports the server scratch's shown and backed state
- [ ] custom commands keep running on the Mac; `AGT_*` tokens in a remote window name the server session and host,
      and their `agtermctl` session operations reach the server through the seam
- [ ] tests: scratch survives hide and window detach, ends on shell exit, session close and server restart, and a
      restart leaves non-scratch daemons running;
      `session.scratch` routing and read-back; custom command token values in a remote window

### Task 10: Pending interactions with no Mac connected

**Files:**
- Modify: `agtermCore/Sources/agtermCore/PresentationFrames.swift`, `PresentationHub.swift`,
  `OverlayJobs.swift`, `AppStore+RemoteOverlay.swift`, `AppStore+RemotePage.swift`, `RemotePresentationClient.swift`
- Modify: `agtermCore/Sources/agtermctlKit/` (ask/pick `--timeout`)
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`, `ControlDispatcher+Ask.swift`,
  `ControlDispatcher+Pick.swift` (deadline argument and validation), `ControlProjection.swift` (read-back)
- Modify: `agterm/Control/ControlServer+RemotePresentation.swift`
- Create: tests in `agtermCoreTests` and `AgtermServerTests`

- [ ] ask/pick `--timeout` end to end: CLI flag, `ControlArgs` deadline, dispatcher validation, server expiry
- [ ] a new negotiated hello kind for pending interactions; the snapshot carries unpresented asks, picks, pages and
      unclaimed jobs with their deadlines, sent as chunks plus a commit frame when it exceeds the frame cap
- [ ] read-back: each session's `tree` node lists its pending interactions with kind, state (`unpresented`,
      `offered`, `claimed`) and deadline
- [ ] with no presenter, the server keeps them pending; the next presenter is offered each under its generation;
      answers from an old generation are rejected; a job's claim window starts at handoff
- [ ] per-offer claim tokens: each job offer carries a token bound to the presenter generation, `OverlayJobs.claim`
      and the run-job helper validate it before releasing launch context, and presenter loss invalidates it
      atomically; job identity stays separate from offer identity
- [ ] presenter loss mid-interaction returns it to pending instead of handing it back locally; a claimed or unknown
      job reports an honest outcome and is never launched again
- [ ] deadlines and cancellation withdraw pending work before any replay; server restart cancels all of them and the
      waiting `agtermctl` call fails with an error
- [ ] a presenter without the kind is never offered pending work: interactions stay pending on a headless origin
      until a capable presenter or their deadline, and a Mac origin keeps today's behavior
- [ ] tests: each state transition, generation rejection, deadline expiry and `--timeout` validation, restart
      cancellation, an old presenter's helper claiming while unpresented and after a re-offer (both refused),
      presenter loss racing a successful claim, an old presenter left without pending offers, a chunked pending snapshot applied only at
      commit, `tree` read-back; hosted `agtermTests` for the changed `ControlServer+RemotePresentation` path
      (`-only-testing`)

### Task 11: Localhost URL pages through an ssh forward

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore+RemotePage.swift`, `PresentationFrames.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+ReplicaPage.swift`
- Create: `agterm/Control/RemotePortForward.swift`
- Create: tests in `agtermCoreTests` and `agtermTests`

- [ ] a new presenter capability for forwarded loopback pages; a headless origin sends a loopback URL page only to a
      presenter that advertises it, as a forward request rather than a plain `.url` source, and refuses it for an
      older presenter, which would otherwise load its own 127.0.0.1
- [ ] the Mac opens `ssh -L` with `ExitOnForwardFailure` on a free local port for the page's lifetime, rewrites the
      URL to it, and shows a visible error when the forward fails; the forward closes with the page
- [ ] a Mac origin keeps refusing loopback URLs for remote handoff, as today
- [ ] tests: capability gating and old-presenter refusal, URL rewrite, forward lifetime tied to the page, failure
      path, Mac-origin refusal unchanged

### Task 12: Server install and agent setup

**Files:**
- Create: `scripts/install-server.sh`
- Modify: `agterm/Resources/agent-status/agterm-codex-status.sh` (portable replacement for `/usr/bin/plutil`)
- Modify: `agtermCore/Sources/AgtermServerKit/` (`agterm-server install-hooks`)
- Modify: `agtermCore/Sources/agtermCore/` (portable part of the app's `AgentHooksInstaller` hoisted here)
- Modify: `agtermCore/Package.swift` (hook scripts and the agent skill as resources of the server product)
- Create: tests for the hook change and the server-side install

- [ ] packaging from the Task 2 probe: a static musl build of `agterm-server` and `agtermctl`, or a bundled Swift
      runtime when the probe failed
- [ ] install `agterm-server`, the Linux `agtermctl`, zmx, ghostty's shell integration and terminfo entry, the hook
      scripts and the agent skill on a host over ssh (binaries into `~/.local/bin`), and start the server as a systemd user service
      with lingering enabled (`loginctl enable-linger`), refusing with the reason when linger cannot be enabled,
      since without it the user manager ends the server and every zmx daemon at the last ssh logout; upgrade
      replaces binaries and restarts the server without ending panes
- [ ] check under the real systemd user manager that the same pane processes survive the last ssh logout,
      `systemctl --user restart`, a crash with `Restart=`, and an upgrade
- [ ] clean-environment check: a bare `ssh HOST agtermctl tree --json` reaches the server through the Linux
      default
- [ ] agent hooks and the agent skill installed on the server by `agterm-server install-hooks` from its own
      resources, never from the Mac
- [ ] the installed service reports its versions through `agtermctl version` (produced in Task 6, refused on
      connect in Task 7)
- [ ] tests: hook script on Linux; `install-hooks` writes the expected files and points them at the server's
      `agtermctl`; the hoisted installer leaves the Mac's install unchanged

### Task 13: Update documentation
- [ ] `site/docs.html`: a Remote server section (install, open a remote window, what runs where, disconnect, close)
      and the scratch/custom-command rules in a remote window
- [ ] `site/commands.html`: `catalog subscribe`, `window remote open` and its read-back, `session detach|reattach`
      and `workspace detach|reattach`, pick `--session`,
      ask/pick `--timeout`, the new `tree` fields, and which commands a server refuses
- [ ] `site/index.html`: the remote server as a major feature
- [ ] `.claude/rules/control-api.md` (catalog protocol, receipts, pending interactions, headless presenter rule,
      Linux rendezvous), `windows.md` (window sources), `ci.md` (Linux job); `ARCHITECTURE.md` module map
- [ ] `plugins/agterm/skills/agterm/` SKILL.md trigger and reference for remote windows and the server
- [ ] `README.md` synopsis line and `site/llms.txt` index entry; delete `docs/remote-agent-server.md`

### Task 14: [Final] Verify acceptance criteria
- [ ] every Overview requirement works end to end against the container server through an isolated Debug instance:
      new session, split, swap, rename, close, companions, status, context, HUD, ask, pick, program overlay, all
      page kinds, localhost URL page, scratch, disconnect and reconnect, server restart, Mac relaunch
- [ ] per-session attach to a Mac and to agterm-linux behaves exactly as before
- [ ] on the final tree, once each: `make build`, `cd agtermCore && swift test`, `make test-app`, `make lint`, the
      Linux build and test, and the new `agtermUITests` classes with `-only-testing` against
      `scripts/server-container.sh`
- [ ] `lsappinfo list | grep -A4 agterm.debug` shows no leaked test process; container stopped
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion
*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Manual verification:**
- install on a real remote Linux host (x86_64 and arm64) with `scripts/install-server.sh` and use it for a day of
  agent work: Mac sleep and wake, network change, server reboot
- latency of structural actions over a slow link; if a split feels slow, a catalog-scoped duplex request channel can
  replace per-command ssh later with the same command semantics

**Decisions for Eugene:**
- executable name (`agterm-server` is the working name) and whether its release ships with the Mac release or
  separately
- whether several Macs viewing one catalog, and server-owned undo/Reopen Closed, become the next plan
- once merged, file `docs/backlog/headless-server-macos.md` for the macOS server target: a launchd LaunchAgent
  instead of the systemd unit and linger; panes surviving agent stop, restart, crash and upgrade, verified by test;
  TCC attribution for agents the server starts, through `agterm-session-host`/`AgtermResponsibility`, checked per
  service; cwd through `proc_pidinfo`; macOS state and socket paths; a Mac test host for the container checks

**External:**
- the agterm-linux fork compiles against changed `agtermCore` public API (backing state, pick binding, framing,
  new `Command` cases, the window-entry source field); tell its maintainer when the release lands

Smells pre-check: skipped — non-Go project
