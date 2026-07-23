---
paths:
  - "agterm/Control/ControlServer*.swift"
  - "agterm/Control/ControlTargetResolver.swift"
  - "agtermCore/Sources/agtermCore/ControlProtocol.swift"
  - "agtermCore/Sources/agtermCore/ControlResolve.swift"
  - "agtermCore/Sources/agtermctlKit/*.swift"
  - "agtermCore/Sources/agtermctl/main.swift"
  - "agterm/CLIInstaller.swift"
  - "agterm/AgentHooksInstaller.swift"
  - "agterm/SkillInstaller.swift"
  - "agtermCore/Sources/agtermCore/CLIInstall.swift"
  - "agtermCore/Sources/agtermCore/AgentHooksInstall.swift"
  - "agtermCore/Sources/agtermCore/SkillInstall.swift"
  - "agtermUITests/Control*.swift"
  - "agtermUITests/SessionTextUITests.swift"
  - "agterm/Resources/agent-skill/**"
---

## Control API

- A programmatic control channel lets an external script drive `agterm` over a local unix-domain socket,
  via the companion `agtermctl` CLI.
  It is a thin dispatcher onto the existing `AppActions`/`AppStore` seam — the third caller of that seam,
  alongside the toolbar/bottom bar and the menu bar — so no business logic is duplicated.
  Scope is personal scripting: fire-and-forget commands, no terminal-output/scrollback streaming and
  no event subscription (out of scope by design).
- **Three layers, matching the core/app split:**
  1. **Protocol + pure logic in `agtermCore`**
     (Foundation-only, `Codable`, `Sendable`): `ControlProtocol.swift` holds the `Command` enum,
     `ControlArgs`, `ControlRequest`, the tree node types (`ControlSessionNode`/`ControlWorkspaceNode`/`ControlTree`),
     `ControlResult`, and `ControlResponse`.
     `ControlResolve.swift` holds the pure target resolver (`resolve(_:candidates:active:) -> TargetResolution`)
     and the socket-path resolver (`socketPath(stateDir:appSupport:)`).
     Shared by both the app and the CLI so the wire contract cannot drift.
  2. **`ControlServer` in the app target**
     (`agterm/Control/ControlServer.swift`, `@MainActor`): owns the POSIX unix socket.
     The blocking accept/read loop runs on a background `DispatchQueue`;
     each newline-delimited `ControlRequest` is decoded, hopped to `@MainActor`,
     dispatched onto `AppActions`/`AppStore` (plus a thin `GhosttySurfaceView.inject(text:)` for input),
     and the `ControlResponse` written back before the connection closes.
  3. **`agtermctl` CLI**
     in the `agtermCore` SwiftPM package: an `agtermctlKit` library (the `ParsableCommand` tree — root
     `Agtermctl` + shared option/request plumbing in `Commands.swift`, subcommands split by family into
     `SessionCommands.swift`/`WorkspaceCommands.swift`/`WindowCommands.swift`/`MiscCommands.swift` — and
     the socket client in `SocketClient.swift`) plus a thin `agtermctl` executable.
     It links `swift-argument-parser`; the `agtermCore` library target stays dependency-free.
     Builds with `swift build`, needs no Xcode/GhosttyKit.
- **New/changed control commands are dispatcher-first** (the `refactor`/`hoist` migration, #78 onward).
  A host-free `ControlDispatcher` in `agtermCore` (`ControlDispatcher.swift`) now fronts layer 2's dispatch:
  its `dispatch(_:)` owns command parsing, argument validation, error strings, and the success-response
  shape, calling the app through the `ControlActions` protocol, which `ControlServer` conforms to and
  which supplies ONLY target resolution and the AppKit/process side effects.
  Commands migrate group-by-group; one the dispatcher doesn't yet own returns `nil` and falls through to
  `ControlServer`'s existing switch, so that switch is a fallthrough for not-yet-migrated commands, NOT the
  home for new ones.
  So when adding or changing a command: put every host-free part (arg checks, error text, the payload) in
  `ControlDispatcher` with a unit test, and put only the side effect behind a `ControlActions` method — do
  NOT add fresh validation/response logic inline in the `ControlServer` switch.
  (This is the control-channel case of the root `CLAUDE.md` "hoist host-free logic down into `agtermCore`"
  module-boundary rule.)
- **The four-point audit is the WRITE path; a state-mutating command also owes a READ-BACK field.**
  Whenever a command SETS or MUTATES per-session state, surface that state on `ControlSessionNode` (or
  the tree top-level) so a script can query the value it just wrote: record-then-restore, read-modify-write,
  and idempotency all depend on reading back what a `set`/`resize`/`toggle` changed.
  The read field is populated in `AppStore.controlTree` and, like the other optionals, omitted from the
  JSON when nil.
  Existing pairs to mirror: `session.background`/`background`, `notify`+`session.seen`/`unseen`,
  `session.status`/`status`+`statusPane` (+`statusBlink`/`statusColor` for `--blink`/`--color`),
  `session.flag`/`flagged`, `session.focus`/`splitFocused`, `session.resize`/`splitRatio`,
  `session.restore`/`restoreCommand`+`splitRestoreCommand`,
  `session.overlay.resize`/`overlaySizePercent`, `sidebar`/`sidebarVisible` (top-level),
  `sidebar.mode`/`sidebarMode`, `workspace.focus`/`focused` (workspace node),
  `workspace.collapse`+`workspace.expand`/`collapsed` (workspace node), `quick`/`quickVisible` (top-level),
  `font.*`/`fontSize`+`splitFontSize`+`scratchFontSize` (the per-pane LIVE font size — the split/scratch
  panes' fonts are otherwise unobservable, being live-only; supplied to `controlTree` by app-side closures
  reading `GhosttySurfaceView.currentFontSize()`, since the host-free tree can't read a surface),
  `window.move`+`window.resize`/`geometry`, `window.fullscreen`+`window.zoom`/`fullscreen`+`zoomed`
  (the last three on `window.list`).
  This is a SEPARATE obligation from the four-point audit (Command + arg + CLI + tests) and easy to forget:
  `session.overlay.resize` shipped write-only and `overlaySizePercent` was added only later, when a
  tmux-zoom script needed to restore an overlay's exact size.
  When adding a state-mutating command, add its read-back field in the SAME change and cover it with a
  `treeSessionNodeRoundTrips…`/`…OmitsWhenNil` round-trip test plus a `controlTree` populate test.
- **Bundling + install.**
  The `agterm` target's `Bundle agtermctl CLI` postBuildScript (`project.yml`) runs `swift build -c release --product agtermctl`,
  copies it to `agterm.app/Contents/MacOS/agtermctl`, ad-hoc signs the helper,
  then **re-signs the whole app `--deep`** — the phase can run AFTER Xcode's own code-sign on incremental
  builds, so without the re-seal the injected helper breaks the signature (and a shallow re-sign chokes
  on the Debug `agterm.debug.dylib`).
  **Help ▸ Install Command Line Tool…** (`agtermApp` `CommandGroup(replacing: .help)` → `CLIInstaller.run()`)
  symlinks the bundled binary into `/usr/local/bin` (first entry in macOS's default `/etc/paths`,
  unlike `~/.local/bin`): a direct `FileManager` symlink when the dir is user-writable,
  else a one-time GUI admin prompt via `osascript … with administrator privileges`.
  Pure path/quote logic is `agtermCore.CLIInstall` (host-free, unit-tested);
  the AppKit FS + auth glue is `CLIInstaller` (app-side, manually verified like the directory picker).
  Install is GUI-only and keep-in-sync EXEMPT — driving it over the socket is meaningless (you'd need
  `agtermctl` already installed to call it).
- **Agent-status hooks install.**
  A second Help entry, **Help ▸ Install Agent Status Hooks…** (`AgentHooksInstaller.run()`),
  wires coding agents to `session.status`.
  The hooks package bundles at `agterm/Resources/agent-status/` (`agterm-agent-status.sh` generic wrapper,
  `agterm-codex-status.sh` Codex adapter, `shell/integration.sh`, `shell/integration.fish`, and
  `pi/agterm-status.ts`, a `project.yml` Contents/Resources folder mirroring `Resources/ghostty`).
  The installer copies them to `~/.config/agterm/agent-status/`, bakes the bundled `agtermctl`'s absolute
  path (`Bundle.main.url(forAuxiliaryExecutable:)`) into both wrappers so the hooks fire even without the
  CLI on PATH, appends a marker-guarded `source` line to `~/.zshrc` + `~/.bashrc`,
  merges four Claude Code hooks into `~/.claude/settings.json` with a `.bak` (UserPromptSubmit→`active --blink`,
  PostToolUse→`active --blink`, Stop→`completed --auto-reset`, Notification[`permission_prompt`]→`blocked`;
  the unmatched PostToolUse re-asserts `active` after every tool so a `blocked` permission prompt clears
  back to active when work resumes — Claude Code has no "permission answered" event,
  and the gated tool's own PreToolUse fires BEFORE `blocked` is set, so the approved tool's PostToolUse
  is the first hook afterwards), and merges SIX Codex lifecycle hooks into `~/.codex/config.toml` with a
  `.bak`.
  Those six events call the dedicated `agterm-codex-status.sh` adapter with lifecycle actions.
  The adapter maps SessionStart to `idle` and UserPromptSubmit/PreToolUse/PostToolUse to `active --blink`.
  On Stop it reads Codex's final assistant message: a message containing `?`
  maps to `blocked`; every other message maps to `completed --auto-reset` through the generic wrapper.
  `PermissionRequest` is only a candidate signal because Codex fires it before Auto Review decides whether
  a person is needed.
  A per-session/pane watcher reads the visible terminal footer through `agtermctl session text` and reports
  `blocked` only after a real approval or structured-question dialog appears.
  Automatic approvals and denials never become `blocked`.
  This replaces a retired `codex-notify.sh` that broadly keyword-matched the turn's final message and
  misfired both ways (issue #193; the merge also strips the old
  `notify = [...codex-notify.sh...]` line).
  The Codex merge PARSES the config with `TOMLDecoder` (a pure-Swift, spec-compliant parser — the one
  dependency `agtermCore` links besides swift-argument-parser) to decide the outcome
  (`AgentHooksInstall.CodexMergeOutcome`): a marker block carrying an older agterm wrapper is refreshed
  while preserving Codex's trailing hook trust tables; a foreign marker block is unchanged;
  the file already defines its own `hooks` → `.hooksExist`; the file isn't valid TOML → `.unparseable`;
  else → `.merged`, a marker-guarded
  append (the same `rcMarkerBegin`/`End` markers as the shell rc files, so comments/layout survive) plus
  removal of a stale top-level `notify` ONLY when its PARSED value points at `codex-notify.sh` (a comment
  merely naming the file, or the user's own notifier, is never touched).
  On `.hooksExist`/`.unparseable` the app leaves the file untouched and surfaces the block for a manual
  add; the merge is gated on `~/.codex` existing (like the fish rc gate).
  Both the Codex and Claude write paths distinguish an ABSENT config from one that EXISTS-but-unreadable
  (the app-side `readExistingConfig`), so a permission/encoding read failure leaves the file untouched
  instead of clobbering it with no backup.
  Codex requires new or changed command hooks to be reviewed (`/hooks`) before they run.
  When `~/.pi/agent` exists, the installer copies the bundled `pi/agterm-status.ts` lifecycle extension to
  `~/.pi/agent/extensions/agterm-status.ts`.
  Pi's `agent_start` sends `active --blink`; its `agent_settled` sends `completed --auto-reset` only after
  retries, compaction retries, and queued continuations finish.
  Pi deliberately has no native permission/structured-question event, so the extension does NOT infer
  `blocked` from agent prose.
  The source carries `AgentHooksInstall.piExtensionMarker`; an unmarked same-named extension is user-owned
  and left untouched, and Pi must restart or run `/reload` after installation.
  Idempotent + re-runnable (re-run refreshes the baked path and the managed Pi extension).
  Like the CLI installer, the host-free JSON/TOML-merge / shell-rc-marker / backup-path / Pi-path-and-marker
  logic is `agtermCore.AgentHooksInstall` (unit-tested); `AgentHooksInstaller` (app-side) owns the AppKit
  FS glue, manually verified.
  Install is GUI-only and keep-in-sync EXEMPT — driving it over the socket is meaningless because the
  integration being installed is itself what uses `agtermctl`.
- **Agent skill install (Claude Code + Codex).**
  A third Help entry, **Help ▸ Install Agent Skill…** (`SkillInstaller.run()`),
  copies a bundled, personal-scope Agent Skill to `~/.claude/skills/agterm/` AND `~/.codex/skills/agterm/`
  so a coding agent running INSIDE an agterm session knows how to drive the app over the control channel.
  Claude Code and Codex use the SAME SKILL.md Agent-Skill format (`name`/`description`/`allowed-tools`
  frontmatter + optional reference files; verified against the user's `~/.codex/skills/`),
  so one authored skill serves both.
  The skill is a REFERENCE/knowledge skill (both user-invocable via `/agterm` and model-triggered,
  `allowed-tools: Bash(agtermctl *)`; the agent-neutral `description` carries the trigger nouns since
  Codex may ignore the extra `when_to_use` field — unknown frontmatter is harmless),
  authored at `agterm/Resources/agent-skill/` (`SKILL.md` overview + model + addressing + 64-command
  summary + the image-display helper + a troubleshooting/reporting pointer;
  `reference.md` full per-command detail + keymap format; `examples.md` agtermctl recipes;
  `troubleshooting.md` diagnosing the common problems (keymap editor, custom actions,
  logs) + the bug-issue / feature-Discussion reporting workflow (draft-first,
  scrub, never run `gh` without explicit user approval); `scripts/show-image.sh` the bundled image-display
  helper), bundled via a `project.yml` Contents/Resources FOLDER reference like `agent-status` (the whole
  dir, INCLUDING the `scripts/` subdir, copies verbatim; `SkillInstaller` uses `FileManager.copyItem`
  so the subdir reaches both installs).
  **Image display is NOT a control command** — it's a bundled shell helper:
  `show-image.sh <image> [size%]` opens an overlay (a real pty) and renders the image via the kitty graphics
  protocol, which the pinned ghostty draws NATIVELY — pure `base64` + chunked `\e_G` APC frames,
  NO kitty binary and NO external image tool.
  (The pinned ghostty renders ONLY the kitty graphics protocol; iTerm2 OSC-1337 inline images and sixel
  are `unimplemented` in that build — verified in upstream `src/terminal/osc/parsers/iterm2.zig`,
  the `.File`/`.FilePart`/`.FileEnd`/`.MultipartFile` keys land in the `unimplemented OSC 1337` bucket.
  The agent CANNOT print graphics escapes to its own tool stdout — the harness escapes the control bytes
  — nor run a viewer in its tool shell — no `/dev/tty`; the overlay sidesteps both,
  so the method is agent-harness-agnostic and works identically for Codex.) It is invoked by absolute
  install path (`~/.claude/skills/agterm/scripts/show-image.sh` or `~/.codex/...`),
  NOT `${CLAUDE_SKILL_DIR}` — that token is Claude-Code-only and would not expand in the Codex copy of
  the SAME authored `SKILL.md`.
  **Install policy:** write to each agent base that EXISTS (`~/.claude` and/or `~/.codex`);
  if neither, fall back to creating `~/.claude` (`SkillInstall.installTargets`).
  Pure file-drop (no manifest): per-target remove-then-copy for a clean reinstall,
  best-effort per agent (one failing doesn't abort the other), but it REFUSES to clobber a same-named
  skill the user authored (one whose `SKILL.md` lacks the `<!-- agterm-skill -->` marker — `SkillInstall.mayOverwrite`).
  Host-free path/target/marker logic is `agtermCore.SkillInstall` (unit-tested);
  `SkillInstaller` (app-side) owns the AppKit copy, manually verified.
  Install is GUI-only and keep-in-sync EXEMPT (a skill that documents the socket isn't itself driven
  over it).
  **KEEP-IN-SYNC (HARD): the bundled skill is a documentation mirror of the control surface — whenever
  you change the Control API (commands/args/returns), the keymap format,
  or the window/workspace/session/pane model, update `agterm/Resources/agent-skill/` (SKILL.md + reference.md
  + examples.md + `troubleshooting.md` + `scripts/`, incl. the command count) so the installed agent-driver
  doc stays accurate.
  It is the fourth keep-in-sync surface alongside the GUI/menu/CLI.
  The skill's `troubleshooting.md` mirrors the user-facing `docs/troubleshooting.md`;
  keep the two in step when a diagnostic path or the reporting workflow changes.**
- **Socket path / lifecycle.**
  The path is `<AGTERM_STATE_DIR>/agterm.sock` when `AGTERM_STATE_DIR` is set (state isolation),
  else `<app support>/agterm.sock` (`~/Library/Application Support/agterm`),
  via `ControlResolve.socketPath`.
  `ControlServer.defaultSocketPath()` adds an `AGTERM_CONTROL_SOCKET` env override that takes precedence
  (used by XCUITests, whose sandboxed `AGTERM_STATE_DIR` container path exceeds the `sun_path` ~104-byte
  limit); the CLI's `--socket` flag is the user-facing equivalent.
  The socket is `chmod 0600`.
  Each accepted connection sets `SO_RCVTIMEO` (5 s, alongside `SO_NOSIGPIPE`) so a stalled client can't
  wedge the serial accept loop — a timed-out `read()` returns `EAGAIN`, which `readLine` (any non-`EINTR`
  `n < 0` = end-of-read) maps to nil → close → `accept()` resumes.
  `start()` is idempotent (the scene `.task` may re-run) and unlinks any stale path before binding;
  it is best-effort (a bind failure logs and the app still launches).
  Lifecycle is asymmetric: started from the scene `.task`, stopped from `AppDelegate.applicationWillTerminate`;
  a force-quit that skips that leaves a stale socket file, which the next launch's unlink-first handles.
- **Protocol shape.**
  One request per connection, newline-delimited JSON: `{"cmd":…,"target":…,"args":{…}}` → one `{"ok":…,"result":…|"error":…}`
  → close.
  Mutating commands return the affected/new id in `result.id` (create-then-use without a second round-trip);
  `tree` returns `result.tree`.
  An unknown `cmd` fails to decode and comes back as a structured error,
  never a crash; a 1 MiB max-line cap bounds the read buffer.
  In `agtermctl`'s human (non-`--json`) output, `result.id` is echoed ONLY for the create commands (`session/workspace/window new`,
  via `RequestCommand.echoesResultID`) where the new id isn't known yet;
  every other mutation prints `ok` (the id you already named is noise).
  The id is always present under `--json`.
  Batch session mutations return the number of sessions actually changed in `result.affected`; human
  output is `1 session` / `N sessions`. `result.count` remains reserved for diagnostics and search.
- **Addressing.**
  UUID is canonical, with sugar: `active` (the selected session / current workspace),
  exact `uuidString` (case-insensitive), or a git-style unique prefix.
  Zero prefix hits → `notFound` error, ≥2 → `ambiguous` error listing the candidates.
  `--target` defaults to `active`, so scripts rarely type an id and never for "the current one".
  Batch-capable session commands (`session.close`, and `session.move` with workspace/after/before placement)
  accept repeated `--target` flags in the CLI; on the wire these are `args.targets: [String]`. The batch is
  scoped to one window/store: the first target resolves by the normal `--window`/frontmost/cross-window
  rules, then remaining targets resolve inside that same store so one command never mutates multiple windows.
  The top-level `target` also carries the first explicit batch target so a new CLI talking to a still-running
  pre-batch server degrades to a named session instead of accidentally acting on `active`.
- **Command catalog (64 commands):**
  - `tree`
  - `workspace.new`/`workspace.rename`/`workspace.delete`/`workspace.select`/`workspace.move`/`workspace.focus`/`workspace.collapse`/`workspace.expand`
  - `session.new`/`session.duplicate`/`session.close`/`session.select`/`session.rename`/`session.reveal`/`session.move`/`session.type`/`session.split`/`session.scratch`/`session.focus`/`session.resize`/`session.go`/`session.copy`/`session.paste`/`session.selectall`/`session.text`/`session.search`/`session.status`/`session.flag`/`session.seen`/`session.restore`/`session.background`/`session.overlay.open`/`session.overlay.close`/`session.overlay.resize`/`session.overlay.result`
  - `surface.zoom`
  - `dashboard`
  - `quick`/`quick.type`/`quick.text`
  - `sidebar`/`sidebar.mode`/`sidebar.expand`/`sidebar.collapse`
  - `notify`
  - `font.inc`/`font.dec`/`font.reset`
  - `window.new`/`window.list`/`window.select`/`window.close`/`window.rename`/`window.delete`/`window.resize`/`window.move`/`window.zoom`/`window.fullscreen` (see the Windows section)
  - `keymap.reload` (see the Keymap section)
  - `config.reload` (see the Settings section)
  - `theme.set`/`theme.list` (see the Theme picker section)
  - `restore.clear` (see the Settings section)

  One extra `Command` case is deliberately NOT part of the catalog: `debug.appearance` (`light`|`dark`
  via `args.name`) is a UI-TEST-ONLY seam that sets `NSApp.appearance` so an XCUITest can simulate a
  macOS light/dark flip (macOS XCUITest has no API for it); the arm ALSO posts
  `.agtermSystemAppearanceChanged` directly so the flip pipeline runs deterministically without depending
  on whether KVO fires on an explicit `NSApp.appearance` set (production follows the appearance via an
  app-level KVO observer on `NSApplication.effectiveAppearance` — see the theme-picker/libghostty rules).
  The `ControlServer` arm refuses it outside an XCUITest launch (`ContentView.isUITestLaunch`), it gets
  NO `agtermctl` subcommand, and it stays out of the agent skill — a documented keep-in-sync EXEMPTION
  (test scaffolding, not a control surface).
  Setting echoes the resulting effective side in `result.text`; the BARE form (no name) reads the side
  the last config feed applied (`SettingsModel.lastAppliedIsDark`), which the test polls to prove the
  flip actually drove the reload.
  `AppearanceFlipUITests` is its only consumer; the public command count stays 64.

  `workspace.delete` honors keep-at-least-one and returns an error instead of the GUI confirm alert (nothing
  blocks on a modal).
  `session.close` has a legacy single-target control path and a batch path. Single-target control close
  continues to call `AppStore.closeSession` (hard close; backward-compatible with the original control
  behavior). Repeated `--target` / `args.targets` is the GUI-equivalent batch close: it resolves all targets
  in one store and honors `closeGraceUndoEnabled`. When enabled it calls `AppStore.softCloseSessions`,
  producing one grace timer and one grouped undo/reopen record; when disabled it immediately hard-closes
  each resolved session like the GUI. Both return the number actually closed in `result.affected`
  (`ok` with the count — never an error for an empty result, matching the batch `session.move` shape).
  Batch target resolution (`resolveBatchSessions`) is all-or-nothing and deduplicating: any unknown or
  ambiguous target fails the WHOLE request before anything mutates
  (`ControlAPIUITests.testSessionCloseBatchIsAllOrNothing`), and a batch that deduplicates to a single
  session (e.g. `--target a --target a`) takes the single-target path — for close that is the legacy
  HARD close (no grace window), consistent with the one-element `session.move` routing.
  During the grace window, reopening any member restores the whole group but selects the specific Recent
  item the user chose, matching workspace close grouping without losing selection intent. Keep-in-sync: `ControlArgs.targets`, the
  `.sessionClose` dispatcher batch arm, `ControlActions.closeSessions`, `agtermctl session close --target`
  repeat support, round-trip/dispatcher/CLI tests, and `ControlAPIUITests.testSessionCloseMultipleTargets`.
  `session.move` is MODE-BEARING with THREE exclusive placement intents:
  `args.to` (`up`|`down`|`top`|`bottom`) REORDERS the session within its own workspace (parses `ReorderDirection`,
  drives `AppStore.reorderSession` → the existing `moveSession(at:)` primitive, returns the session id);
  `args.workspace` RELOCATES it to another workspace (still APPENDS at the end);
  and `args.after`/`args.before` (a session address — id / prefix / `active`) PLACE it directly after/before
  an anchor session (`ControlSessionMove.place(anchor:after:)`).
  The anchor CARRIES ITS OWN WORKSPACE — it is resolved against the store's FULL session set (all workspaces),
  so it names the destination workspace itself and relocates + positions in one shot (cross-workspace
  falls out for free).
  Placement reuses the drag-drop index math host-free: `SidebarDrop.resolveRelative` (the tested "after
  this row" `sessionIndex + 1` + the same-workspace post-removal off-by-one + the anchor==source no-op)
  feeding `AppStore.moveSession(_:toWorkspace:at:)`.
  Exactly one intent must be set: after+before is an error (`"use either --after or --before, not both"`),
  after/before + `--to` is an error (`"session.move takes --after/--before or --to, not both"`),
  after/before + a workspace is an error (`"session.move takes --after/--before or a workspace, not both"`
  — the anchor already names the workspace), both `--to`+workspace and neither are errors,
  and an invalid direction is an error.
  Repeated `--target` / `args.targets` makes `session.move` a batch move for workspace relocation and
  after/before placement. It uses the same host-free block semantics as sidebar multi-drag:
  all moved sessions are resolved in visual tree order, removed first, then inserted as one block via
  `SidebarDrop.resolveSessions`/`AppStore.moveSessions`. Batch `--to up|down|top|bottom` is deliberately
  rejected (`"session.move --target can be repeated only with a workspace or --after/--before"`) because
  relative one-step reorder is inherently per-session and order-dependent.
  The response reports only sessions actually moved in `result.affected`; members already in a workspace
  destination remain in place and are not counted. A one-element `args.targets` array is equivalent to the
  singular form (the dispatcher routes it through `moveSession`), including the `result.id` response and
  moving an existing destination member to the end.
  Keep-in-sync: `ControlArgs.after`/`before` + `ControlSessionMove.place` in `ControlProtocol.swift`/`ControlModes.swift`,
  the `.sessionMove` place-mode routing + guards in `ControlDispatcher`, the app-side `moveSession` place
  case (`ControlServer+SessionActions.swift`, resolving both target + anchor locations and calling
  `resolveRelative`), the `session move --after/--before` CLI, and round-trip / dispatcher / e2e
  (`testSessionMovePlaceWithinWorkspace`, `testSessionMovePlaceCrossWorkspace`, the reject-* guards) tests.
  Batch keep-in-sync additionally includes `ControlArgs.targets`, `ControlActions.moveSessions`,
  `agtermctl session move --target` repeat support, and `ControlAPIUITests.testSessionMoveMultipleTargetsWithinWorkspaceBeforeAnchor`.
  Keep-in-sync exemptions for sidebar batch actions: Flag/Unflag is loop-equivalent to repeated
  `session.flag on|off --target <id>` (the plural store API only saves once).
  The GUI's multi-select toggle is NOT a `toggle` loop: `AppActions.toggleFlags` computes ONE uniform
  value for the whole set (`allSatisfy(\.flagged)` — flag all unless every target is already flagged)
  and applies it, so on a mixed selection a per-row `session.flag toggle` loop diverges from the GUI.
  A script wanting the GUI semantics reads `flagged` off `tree`, computes the uniform value, and loops
  `on`/`off`.
  Clear Status is loop-equivalent to repeated `session.status idle --target <id>` and intentionally adds
  no batch command.
  `workspace.move` is the workspace REORDER (control-native, no separate verb):
  `args.to` (`up`|`down`|`top`|`bottom`) resolves the workspace target via the shared `resolveWorkspace`
  (honoring the global `--window` selector like other workspace commands),
  drives `AppStore.reorderWorkspace`, and returns the workspace id; a missing or invalid `to` is an error.
  Drag-and-drop stays the precise (drop-between-rows) surface; the control path is relative-only,
  mirroring `session.go --to`.
  Four-point keep-in-sync audit for `workspace.move`: (1) `case workspaceMove = "workspace.move"` in
  `ControlProtocol.swift` (reuses `ControlArgs.to`, no new field), (2) the `.workspaceMove` dispatch
  arm in `ControlServer`, (3) the `workspace move --to` subcommand in `agtermctlKit`,
  (4) round-trip tests in `ControlProtocolTests` plus the e2e in `ControlAPIUITests`.
  NOTE on `workspace.move --target active`: `active` for a workspace resolves to `AppStore.currentWorkspaceID`,
  which with NO selected session falls back to `workspaces.last` — so repeated `workspace.move --to top --target active`
  on a session-less window targets a DIFFERENT (newly-last) workspace each call (consistent with the
  `currentWorkspaceID` fallback contract; address a specific workspace by id/prefix to step the same
  one).
  `session.split` resolves the target id and drives `AppStore.toggleSplit` directly (NOT the argument-less
  `AppActions.toggleSplit()`, which only acts on the active session) — `off` HIDES the split keep-alive,
  mirroring ⌘D (the pane's surface is NOT torn down; `closeSplit` stays the shell-exit-only path,
  so there is no on-demand destroy over the control channel, matching the GUI).
  `session.scratch` (mode `on`|`off`|`toggle`, mirrors `session.split` exactly) shows/hides the **scratch
  terminal** — a THIRD per-session login shell (alongside main + split) that RENDERS like a full overlay
  (full-pane, hides the session, translucent) but BEHAVES like the split:
  lazily spawned on first show, kept alive when hidden (`off` is `AppStore.toggleScratch` keep-alive,
  never a teardown), recreated fresh after its shell's own `exit`.
  NOT persisted (absent from `SessionSnapshot`, like the overlay) — `Session.scratchActive`/`scratchSurface`,
  `AppStore.toggleScratch`/`closeScratch` (the latter only on `exit` + session/workspace/window teardown).
  Full-overlay rendering only (never floating): a conditional `sessionDetail` ZStack sibling at `.zIndex(1)`
  (the structural pattern the now-removed `if fullOverlay` sibling used), BELOW the ephemeral `overlayPanel`
  (`.zIndex(3)` — a normal overlay launched over the scratch sits on top); the panes' opacity/hit-testing gate is `hideForOverlay = fullOverlay || scratchActive`
  (still false for a FLOATING overlay, preserving the NSSplitView-overrun invariant).
  GUI half: ⌘J (`BuiltinAction.toggleScratch`), title-bar `scratch-toggle` button,
  View ▸ Show/Hide Scratch, the ⌃⇧P palette "Toggle Scratch" — all through `AppActions.toggleScratch()`.
  The scratch surface is NOT operationally wired to the session (no `view.session`, like the overlay) so
  its PWD/title never clobber the sidebar name; a separate weak `watermarkSession` link carries only the
  owning session's visual config, so its background watermark/color renders on the scratch too. `autoFocus`
  grabs first responder on show,
  the detail pane's `.onChange(of: scratchActive)` reclaims it on hide.
  Four-point keep-in-sync audit: (1) `case sessionScratch = "session.scratch"` + the new `ControlSessionNode.scratch`
  flag in `ControlProtocol.swift` (reuses `ControlArgs.mode`), (2) the `.sessionScratch` dispatch arm
  (`scratchSession`) in `ControlServer` + `scratch:` in the tree builder,
  (3) the `session scratch` subcommand in `agtermctlKit`, (4) round-trip in `ControlProtocolTests` +
  the e2e `testSessionScratchToggle` in `ControlOverlaySplitUITests`.
  `session.focus` moves keyboard focus between the two split panes — `args.pane` is `left`|`right`|`other`
  (`other` toggles, the default); it errors when the session has no split (works whether the split is
  shown side-by-side or hidden — when hidden, focusing a pane swaps which one shows maximized),
  drives `AppActions.setSplitFocus(_:of:)`, and is the control half of the ⌘⌥←/→ keyboard nav + the "Focus
  Left/Right Pane" menu/palette items.
  Its READ side is `ControlSessionNode.splitFocused` (`true`=split/right, `false`=main/left, nil=no split;
  see the `tree` read-side fields below), so a script can record the focused pane and restore it.
  `session.resize` moves the split DIVIDER — it is control-NATIVE (the divider is otherwise mouse-drag
  only; NO GUI/menu/keymap action, so a key is bound by mapping a `command "agtermctl session resize …"`
  custom action).
  `args.ratio` sets the absolute left-pane fraction; `args.ratioDelta` is a signed relative nudge (the
  CLI's `--grow-left`/`--grow-right` map to ±`ratioDelta`, applied to the current fraction,
  `AppStore.splitRatioDefault` = 0.5 when never moved); exactly one must be set (neither/both error).
  It errors when the session has no split (mirroring `session.focus`), clamps + persists via the host-free
  `AppStore.applySplitRatio` (→ `AppStore.clampSplitRatio`, `splitRatioMin...splitRatioMax`),
  then posts the object-scoped `.agtermApplySplitRatio` (object = the `Session`) so the matching `SplitProbeView`
  (`SplitRatioAccessor.swift`) moves the LIVE divider via `setPosition` — a no-op when the split is hidden (no live
  `NSSplitView`; the stored fraction applies on next show).
  It echoes the applied (clamped) fraction in the new `ControlResult.ratio` (the CLI prints it as a bare
  `%.3f` number, scriptable).
  Four-point keep-in-sync audit for `session.resize`: (1) `case sessionResize = "session.resize"` +
  `ControlArgs.ratio`/`ratioDelta` + `ControlResult.ratio` in `ControlProtocol.swift`,
  (2) the `.sessionResize` dispatch arm (`resizeSplit`) in `ControlServer` (+ the `SplitProbeView` re-apply
  observer in `SplitRatioAccessor`), (3) the `session resize --split-ratio|--grow-left|--grow-right` subcommand
  (`Resize`, `validate()`-guarded exactly-one) in `agtermctlKit` + the `result.ratio` format arm in `SocketClient`,
  (4) round-trip in `ControlProtocolTests` + `AppStoreTests` (clamp/apply) + `CommandsTests` (validate/mapping)
  + `SocketClientTests` (format) + the e2e `testSessionResizeSplitDivider` in `ControlOverlaySplitUITests`.
  `session.go` navigates BETWEEN sessions — `args.to` is `next`|`prev`|`first`|`last`|`next-attention`|`prev-attention`
  and acts on the target store's CURRENT selection (it is RELATIVE, so it resolves the placement store
  via `resolvePlacementStore` rather than a session target — there is NO `--target`),
  WRAPS around on next/prev (an end lands on the opposite end, within the filtered set), jumps to the ends for first/last,
  and for `next-attention`/`prev-attention` steps through ONLY the sessions needing attention (`AgentStatus.needsAttention`
  = `blocked`/`completed`) WRAPPING around (skipping idle/active), drives `AppStore.navigateSession`,
  and returns the newly-selected id in `result.id`.
  It mirrors the `session.focus --pane` one-command-with-arg precedent and is the control half of the
  ⌥⌘↑/⌥⌘↓ session-nav + ⌃⌥↑/⌃⌥↓ attention-nav menu/palette items (First/Last have no hotkey).
  `notify` posts a desktop notification attributed to a session (default:
  the active session of the frontmost window via `resolveSession`): `args.body` is required,
  `args.title` defaults to the session name.
  It is control-NATIVE (no GUI/menu equivalent, like `session.type`/`session.copy`) and goes through
  `NotificationManager.send(toSession:title:body:)` — which, unlike the OSC 9/777 path,
  does NOT focus-suppress (the caller asked for it) but still bumps the badge + carries the `<windowID>:<sessionID>:main`
  click-to-reveal identity.
  It is the ONLY app-level way to post a banner; the terminal OSC path remains the other source.
  `session.new` creates a session.
  The destination workspace is addressed one of two MUTUALLY-EXCLUSIVE ways:
  `args.workspace` (id / unique prefix / `active`, the default) OR `args.workspaceName` (the sidebar
  label, name-matched first-exact-trimmed via `AppStore.workspace(named:)`) — the latter optionally with
  `args.createWorkspace` to reuse-or-create the named workspace (idempotent;
  `AppStore.ensureWorkspace(named:)`).
  A `workspaceName` with no match and no `createWorkspace` errors, both addressing modes set is an error,
  and `createWorkspace` without `workspaceName` is an error (nothing to create by id);
  the same two rules are pre-validated CLI-side by `session new`'s `validate()`.
  `args.after`/`args.before` (a session address — id / prefix / `active`) instead PLACE the new session
  directly after/before an anchor session rather than appending at the end (`ControlSessionCreateOptions.after`/`before`).
  The anchor CARRIES ITS OWN WORKSPACE (resolved across all workspaces), so it names the destination
  itself — after/before is a self-contained placement mode, mutually exclusive with each other and with
  `--workspace`/`--workspace-name` (errors: `"use either --after or --before, not both"` and
  `"session.new takes --after/--before or a workspace, not both"`, dispatcher-owned + CLI-pre-validated).
  The app-side `createSession` resolves the anchor, takes its `(workspace, index)`, and inserts via
  `AppStore.addSession(…, at: before ? index : index + 1)` (the new optional `at index:`, clamped).
  `agtermctl session new --after active` = create right after the current session in one round-trip.
  `args.command` runs that command AS the session's process instead of the login shell (like kitty's
  `launch <cmd>` / ghostty's `command`) — NO echoed command line, and the session closes when the command
  exits (the normal single-pane `onExit` → `closePrimaryPane`).
  `Session.initialCommand` is `@ObservationIgnored` but PERSISTED via `SessionSnapshot.initialCommand`, so it
  re-runs on restore (through the same `config.command` exec path) when the **restore-running-command** opt-in
  is on — gated via the transient `Session.wasRestored` so a fresh session always runs its command while a
  restored one honors the toggle (default off → a restored session is a plain shell); a live captured
  foreground preempts it, and `closePrimaryPane` clears it when a command pane exits and its split
  survivor is promoted to the session's single pane.
  The arm threads `request.args?.command` into `AppStore.addSession(…, command:)`,
  which `makeSurface` passes to `GhosttySurfaceView(command:)` → `config.command` RAW (`strdup`,
  NO wrapper). libghostty tokenizes it into argv (shell-like word-splitting that RESPECTS quotes) and
  execs argv[0] DIRECTLY — there is NO `sh -c`, so shell operators (`;`,
  `&&`, `|`, `$VAR`, redirects, globs) are NOT interpreted: `ssh host -p 22 -t "ssh inner"` works (the
  nested command rides as one quoted arg, runs with no echo — verified empirically),
  but `clear; ssh …` execs a program literally named `clear;` and fails.
  This is NOT the overlay's path — `makeOverlaySurface` explicitly wraps its command in `sh -c '…'` (so
  the overlay DOES get shell semantics); a session `--command` that needs shell features must wrap ITSELF,
  e.g. `--command "sh -c '…'"`.
  Either way the command runs under the app's GUI environment, whose `PATH` is the launchd default (no
  `/opt/homebrew/bin`), NOT a login shell's PATH, so a bare Homebrew or other non-default binary is not
  found and exits 127 — the session/overlay opens then vanishes and `session.overlay.result` reports 127.
  The fix is an absolute path or a LOGIN-shell wrapper (`zsh -lc '…'`); a plain `sh -c` gets shell
  operators but NOT the login PATH, so the overlay's built-in `sh -c` wrapper does not by itself solve it
  (the bundled agent-skill documents this caveat on the three `--command`/overlay entries).
  `args.noSelect` (the CLI's `--no-select`) creates the session in the BACKGROUND — `makeSessionResponse`
  passes `select: !noSelect` to `AppStore.addSession` (which gates `selectedSessionID`/`autoUnfocusIfOutsideFocus`/`recordRecency`
  on `select`) AND suppresses the `focusActiveSession()` call, so the current selection and focus are left
  untouched.
  It ALSO threads through the workspace-focus filter: the `--create-workspace` path calls
  `store.ensureWorkspace(named:, clearFocus: !options.noSelect)`, and `AppStore.addWorkspace`/`ensureWorkspace`
  gained a `clearFocus: Bool = true` parameter gating the `focusedWorkspaceID = nil` auto-reveal — so a
  `--no-select --create-workspace` create does NOT drop a focused workspace (all GUI/other `addWorkspace`
  callers keep the default `clearFocus: true`, unchanged).
  It is the inverse of the overlay's `--follow` (overlay opens in the background by default and opts INTO
  selecting; `session.new` selects by default and opts OUT), and like `--follow` it rides the existing
  command as a new optional ARG — NO new `Command` case.
  It is state-mutating-with-read-back EXEMPT: `--no-select` is a creation-time behavior, not queryable
  per-session state, and the read-back is the EXISTING `tree` `active` flag (the new node is not `active`),
  so no new `ControlSessionNode` field is owed.
  Do NOT overload the existing `ControlArgs.select` (that is `session.type --select`, opposite polarity) —
  `noSelect` is its own opt-in-true bool, mirroring `createWorkspace`/`follow`.
  Keep-in-sync: the `.sessionNew` case carries `ControlArgs.command` plus `ControlArgs.name` (custom
  name) and `ControlArgs.workspaceName` + `ControlArgs.createWorkspace` (name-addressing + ensure) +
  `ControlArgs.noSelect` (threaded into `ControlSessionCreateOptions.noSelect`);
  the arm pre-validates the mutual-exclusion / create-needs-name rules and shares `makeSessionResponse`
  across the id- and name-addressed paths; the `session new` CLI carries `--command`/`--name`/`--workspace-name`/`--create-workspace`/`--no-select`
  (the two workspace flags also `validate()`-guarded); and round-trip + e2e (`testSessionNewWithCommandRunsAsProcess`,
  `testSessionNewWithName`, `testSessionNewWorkspaceNameCreatesThenReuses`, `testSessionNewNoSelectKeepsActiveSelection`)
  cover them.
  `session.duplicate` (target = session) creates a fresh session in the SAME workspace as the target,
  inserted directly AFTER it, rooted at the target's focused-pane cwd (`Session.focusedCwd` — the live
  OSC 7 directory the sidebar row shows and `session.reveal` opens), then selects + focuses it and returns
  the NEW id (`echoesResultID`, like `session.new`; it focuses only when the duplicate lands in the frontmost
  window, the same rule `session.new` follows).
  It is exactly `session.new --cwd <source cwd> --after <source>` in ONE atomic round-trip, so it takes NO
  options beyond `--target` (default `active`) and the global `--window` — the target session names BOTH the
  destination workspace and the cwd.
  ONLY the directory carries over: the duplicate is a plain login shell with the auto basename and does NOT
  inherit the source's `customName`, `initialCommand`, split, scratch, status, flag, font size, or watermark
  — it is "New Session seeded with the source's cwd", NOT a clone of state.
  Errors are the standard resolver ones for an unresolvable / ambiguous target, plus `could not duplicate
  session` when creation fails.
  It is the control half of the sidebar row's **Duplicate Session** context-menu item (SINGLE-selection only, like
  Rename / Reveal in Finder — not batch-capable; see the Sidebar rule).
  READ-BACK: it adds NO `ControlSessionNode` field — `tree` ITSELF is the read-back, since the new session
  node appears directly after its source, which is what a script checks.
  The duplicate's `cwd` is seeded from the source's `focusedCwd` (the focused pane), while `tree` reports
  each node's `cwd` from `effectiveCwd` (always the PRIMARY pane), so the duplicate's `cwd` equals the
  source node's `tree.cwd` for a non-split source (and a split focused ON its primary) but DIFFERS when the
  source is a split focused OFF its primary pane — there the source node's `tree.cwd` shows the primary
  while the duplicate carries the focused pane's directory.
  `session.type` injects into the target surface.
  `args.pane` picks the pane like `session.text` (`left`|`right`|`scratch`, no `other`):
  omitted/`left` is the MAIN pane (omitted deliberately keeps the pre-pane behavior — always the main
  pane, NOT the focused/on-screen one, so existing automation is unaffected);
  `right` injects into the split surface, `session has no split pane` without one;
  `scratch` injects into the session's scratch terminal, typable even while HIDDEN (its surface is kept
  alive), `session has no scratch terminal` when none has been opened;
  and an unknown value is an `invalid pane` error — all validated SERVER-SIDE in `injectText`
  (mirroring the CLI `validate()`), so a raw socket client can't bypass it.
  Every session is realized eagerly (the deck mounts all at startup), so any session is normally typable
  WITHOUT `select`; `select:true` remains for the brief window before a just-created session is mounted
  (select, then a bounded poll, the `focusSplitPane` idiom), with `session not realized` the fallback
  if the surface still isn't up.
  The realize/select path applies to the MAIN pane only — a split pane is never created by selecting,
  so `pane:right`/`pane:scratch` inject into the existing surface or error.
  Four-point keep-in-sync audit for `session.type --pane`: (1) reuses `ControlArgs.pane` in
  `ControlProtocol.swift` (no new field), (2) the pane switch in `injectText`
  (`ControlServer+SurfaceIO.swift`), (3) the `session type --pane left|right|scratch` option
  (`validate()`-guarded) in `agtermctlKit`, (4) round-trip in `ControlProtocolTests` + CLI mapping in
  `CommandsTests` + the e2e (`testSessionTypePaneRightReachesSplitPane`,
  `testSessionTypePaneRightWithoutSplitErrors`, `testSessionTypeRejectsInvalidPaneServerSide`) in
  `SessionTypePaneUITests` (a `ControlAPITestCase` subclass like `SessionTextUITests`).
  `GhosttySurfaceView.inject(text:)` types via `ghostty_surface_key` keystrokes (printable runs as key-with-`text`,
  each `\n`/`\r`/`\r\n` as a Return keypress, keycode 36) — NOT `ghostty_surface_text`,
  whose bracketed-paste wrapping suppresses Enter and leaks `\e[200~`/`\e[201~` markers when fired rapidly.
  Do not "simplify" it back to `ghostty_surface_text`.
  `session.copy` reads the target surface's selection via `GhosttySurfaceView.readSelection()` (`ghostty_surface_has_selection`
  + `ghostty_surface_read_selection`, freed with `ghostty_surface_free_text`) and returns it in `result.text`
  — it does NOT touch the system clipboard (automation pipes the returned text into another `session.type`);
  selection is surface state independent of focus, so any realized session can be read,
  and no/empty selection is a `no selection` error.
  `session.paste` pastes the SYSTEM clipboard (`NSPasteboard.general`) into the target session's MAIN
  surface — the socket analogue of ⌘V / Edit ▸ Paste.
  `session.selectall` selects the target's ENTIRE terminal buffer (main surface) — the analogue of ⌘A /
  Edit ▸ Select All.
  Both run a libghostty binding action on the resolved surface — `paste_from_clipboard` /
  `select_all` — through the shared `ControlServer+SurfaceIO.surfaceBindingAction` helper
  (resolve session → guard the surface is realized, `session not realized` otherwise → `performBindingAction`
  → return the id), so paste takes the normal libghostty paste path (bracketed paste, PASTE requests are
  ungated so no OSC-52 prompt) and select_all covers the whole grid.
  They are the control half of the GUI Edit menu: agterm keeps the STANDARD SwiftUI Edit menu and
  implements `copy:`/`paste:`/`selectAll:` + `validateMenuItem:` on `GhosttySurfaceView` (`+Input.swift`,
  conforming to `NSMenuItemValidation`) so AppKit's automatic menu enabling routes Copy/Paste/Select All
  to the terminal when it holds first responder — Copy enabled on `ghostty_surface_has_selection`, Paste
  on `GhosttyCallbacks.hasPasteboardText()`, Select All on a realized surface (all three also require
  the surface, since `performBindingAction` no-ops without one) — while a focused text field (rename/palette/Settings)
  keeps its own editing (its field editor wins the responder chain), and Cut stays disabled for the terminal
  (deliberately NOT implemented) yet works in text fields.
  **Cut cannot be dropped on its own** — SwiftUI puts Cut/Copy/Paste/Delete/Select All in ONE `.pasteboard`
  `CommandGroup`, and replacing that group is what would take ⌘C/⌘V/⌘A away from the rename/palette/Settings
  fields.
  **Undo/Redo ARE dropped** (`CommandGroup(replacing: .undoRedo) {}` in `agtermApp+Menus.swift`): they are
  their own group, agterm registers no `NSUndoManager`, and their advertised ⌘Z is already owned by File ▸
  Reopen Closed Item (`BuiltinAction.undoClose`), whose menu precedes Edit and wins the key-equivalent search —
  so Edit ▸ Undo could only ever be CLICKED, never invoked by its own shortcut.
  AppKit did enable it for the sidebar's inline rename field (whose field editor supplies an undo manager),
  but a permanently-greyed item that duplicates another menu's shortcut for one narrow case is worse than no
  item; `EditMenuUITests.testEditMenuHasNoUndoOrRedoItems` asserts NON-EXISTENCE (an `isEnabled == false`
  check would pass vacuously on a missing element).
  **Paste MUST validate with the same branches the paste path reads**, and must agree with it in BOTH
  directions.
  Two ways to get this wrong, both found in review:
  a `canReadObject([NSString])` probe greys the item out for a Finder file copy (a file URL with NO string
  representation, which `pasteboardText` turns into a shell-escaped path) while ⌘V pastes the path anyway;
  and a `canReadObject([NSURL])` probe is a TYPE check, so a pasteboard merely DECLARING `public.file-url`
  with no usable value enables Paste while the reader returns nil and the paste inserts nothing.
  Either direction reintroduces the menu-vs-keyboard divergence these responders exist to remove.
  So `hasPasteboardText` runs the reader's own URL branch, short-circuiting on the first usable URL
  (`contains(where:)`) instead of mapping/escaping/joining the whole clipboard — validation fires on every
  menu open and every ⌘V key-equivalent lookup, so it must not materialize a Finder copy of thousands of files.
  Both share the single `urlText` helper so they cannot drift.
  **Keep the predicate and the reader in step; this invariant has NO automated test** (verified instead with a
  named-pasteboard probe across the empty / plain-text / empty-string / whitespace / file-url / web-url /
  multi-url / declared-without-data shapes).
  The file-URL case is NOT XCUITest-able: the runner is sandboxed (`com.apple.security.app-sandbox`), so a file
  URL it writes to `NSPasteboard.general` never becomes visible to the app — instrumenting `hasPasteboardText`
  showed the app reading `types=[]` for a full 8 s poll while the runner's own `canReadObject([NSURL])` returned
  true from its in-process cache.
  Such a test exercises the sandbox, not `validateMenuItem`, so it was removed rather than left red (verified
  instead with a cross-process probe outside the runner).
  Do not re-add it without an app-target `bundle.unit-test` (the project has only `bundle.ui-testing` today),
  which could exercise `hasPasteboardText` against a NAMED pasteboard in-process.
  A `NSPasteboard.general` read in the app also LAGS a writer process's `changeCount`, so any UI test that seeds
  the clipboard must POLL rather than read once.
  ⌘C/⌘V/⌘A therefore route through the Edit menu (fixed standard shortcuts, NOT rebindable — the maintainer's
  call); the `ghostty-defaults.conf` `super+key_c`/`super+key_v`/`super+key_a` binds stay as a non-Latin-layout
  backup.
  The mechanism is that AppKit matches a menu key equivalent against the character the layout PRODUCES: on a
  Cyrillic layout ⌘C yields `с`, no equivalent matches, the event reaches `keyDown` and the keycode-triggered
  `super+key_c` fires. (A DISABLED item likewise doesn't consume its equivalent, so ⌘C with no selection also
  falls through.) There is no AppKit "Latin fallback" doing this — the binds are load-bearing, not dead code.
  **`super+key_a=select_all` is one of them**: without it ⌘A silently does nothing on a Cyrillic/Greek layout,
  since libghostty's built-in `super+a` is character-matched too (found in review — the fallback set must cover
  every shortcut the Edit menu owns, not just copy/paste).
  **The session-scoped surface arms resolve `Session.addressableSurface`, not `Session.surface`.**
  `session.copy`/`session.paste`/`session.selectall` act on "the session" rather than a named `--pane`
  (and so does `font.*`'s omitted/`left` default — its `right`/`scratch` panes resolve `splitSurface`/`scratchSurface`
  instead, via its own pane switch rather than `surfaceBindingAction`),
  and `addressableSurface` is `surface ?? splitSurface`: identical to `surface` for every ordinary or split
  session — including a PROMOTED SPLIT SURVIVOR, which `closePrimaryPane` moves into the main slot
  (`AppStorePaneTests` asserts `splitSurface == nil` after promotion).
  The `?? splitSurface` term is a defensive fallback only, kept so the arms answer (instead of
  `session not realized`) should `surface` ever be nil while a split shell is still alive.
  It is deliberately NOT focus-aware (unlike `activeSurface`) — a shown split keeps addressing the main
  pane, which is what keeps `session.selectall` and its `session.copy` read-back on the SAME surface.
  READ-BACK: neither adds a `ControlSessionNode` field — `session.selectall`'s read-back is `session.copy`
  (reads the resulting selection) and `session.paste`'s is `session.text` (reads the inserted buffer), the
  sibling-command pattern (like `quick.type`↔`quick.text`).
  Four-point keep-in-sync audit: (1) `case sessionPaste = "session.paste"` + `case sessionSelectAll = "session.selectall"`
  in `ControlProtocol.swift` (no new args/fields), (2) the `.sessionPaste`/`.sessionSelectAll` arms in
  `ControlDispatcher.dispatchSessionSurfaceCommand` → `ControlActions.pasteSession`/`selectAllSession`
  (app-side `ControlServer+SurfaceIO`), (3) the `session paste` / `session select-all` subcommands in
  `agtermctlKit`, (4) round-trip in `ControlProtocolTests` + dispatcher routing in `ControlDispatcherTests`
  + CLI mapping in `CommandsTests` + the e2e `testSessionSelectAllThenCopyReturnsBuffer` /
  `testSessionPasteInsertsClipboardText` in `ControlAPIUITests`.
  `session.text` reads the target surface's screen buffer as PLAIN TEXT (no ANSI) via `GhosttySurfaceView.readScreenText(all:lines:)`
  (a `ghostty_selection_s` spanning VIEWPORT top-left→bottom-right by default,
  SCREEN when `args.all || args.lines != nil`, `rectangle = false`;
  `ghostty_surface_read_text` → copy out of `ghostty_text_s` → `ghostty_surface_free_text`) and returns it in `result.text`
  — `args.all` adds scrollback, `args.lines N` keeps the last N CONTENT lines (trailing blank grid rows
  trimmed so a non-scrolled screen returns content, not padding), and `args.pane` (`left`→main,
  `right`→split-else-`session has no split` error, `scratch`→the scratch terminal's surface, readable even
  while HIDDEN since it is kept alive (`session has no scratch terminal` when none opened),
  omitted→the ON-SCREEN surface via the shared `Session.onScreenSurface` (scratch-when-covering else the
  focused pane, the SAME resolution `session.search` uses), so a no-`pane` read returns what's visible,
  not a pane hidden under the scratch) picks the pane.
  `args.all`+`args.lines` are mutually exclusive and `args.lines` must be > 0 — validated SERVER-SIDE in
  the dispatcher (`ControlDispatcher.dispatchSessionText`, mirroring the CLI `validate()`), NOT only CLI-side, so a raw socket client can't bypass it
  (an unchecked `lines ≤ 0` would otherwise fall through to the full buffer).
  UNLIKE `session.focus`, the `pane` here is `left|right|scratch` (no `other`).
  A genuinely BLANK screen reads `ok` with an empty string (NOT an error, on purpose — differs from `session.copy`'s
  `no selection`), but a FAILED `ghostty_surface_read_text` is a `failed to read surface buffer` error:
  `readScreenText` returns `""` for the empty read and nil ONLY for a real failure, which the app-side `readSessionText` maps
  to the error (so a caller can tell a blank terminal from a broken read).
  Plain text only — the pinned libghostty exposes only `ghostty_surface_read_text` (no per-cell SGR),
  so `--ansi` is out of scope until a styled surface read lands upstream and the pin is bumped.
  Four-point keep-in-sync audit for `session.text`: (1) `case sessionText = "session.text"` + new `ControlArgs.all: Bool?`/`lines: Int?`
  (reuses `pane` + `ControlResult.text`) in `ControlProtocol.swift`, (2) the `.sessionText` dispatcher arm —
  `ControlDispatcher.dispatchSessionText` (validation + response shape) with the app-side `readSessionText` (the surface read) behind `ControlActions`,
  (3) the `session text [--all] [--lines N] [--pane left|right|scratch]` subcommand in `agtermctlKit`
  (`validate()` guards the flag combos, re-enforced SERVER-SIDE in the dispatcher), (4) round-trip tests in
  `ControlProtocolTests` + the e2e (`testSessionTextReturnsBuffer`, `testSessionTextSplitPaneWithoutSplitErrors`,
  `testSessionTextRejectsInvalidArgsServerSide`, `testSessionTextBlankScreenReturnsOkEmpty`) in `SessionTextUITests`
  (a `ControlAPITestCase` subclass in its own file, sharing the harness base with the `Control*UITests` suites).
  `session.search` searches the target session's live scrollback (target = session) — it SELECTS the
  target (so the bar + match highlights render and the surface is realized,
  bounded-realize-polled like `session.type`), then drives the FOCUSED surface over `ghostty_surface_binding_action`:
  `args.text` is the needle (`sendSearchQuery`, opening search first via `startSearch` if not already
  `searchActive`), `args.to` is `next`|`prev`|`close` (`navigateSearch(.next/.previous)`;
  `close` → `endSearch()` returns ok with no counter).
  The match count lands ASYNC via libghostty's `SEARCH_TOTAL` callback, so the arm bounded-polls `session.searchTotal`
  (the overlay-result idiom) before returning `result.count` = total matches + `result.text` = the "N
  of M" / "M matches" / "no matches" display string (`Session.searchDisplayText`,
  host-free; an empty display maps to nil `text` so the CLI prints `ok`).
  No needle + no `to` opens the empty bar.
  The four search state fields (`searchActive`/`searchNeedle`/`searchTotal`/`searchSelected`) are ephemeral
  on `Session`, absent from `SessionSnapshot`; the GUI bar (see the Menu/actions + ContentView placement
  notes) and the control channel read/write the SAME fields so they can't drift.
  Four-point keep-in-sync audit for `session.search`: (1) `case sessionSearch = "session.search"` in
  `ControlProtocol.swift` (reuses `ControlArgs.text` = needle + `ControlArgs.to` = next|prev|close,
  and `ControlResult.count` + `text` — no new field), (2) the `.sessionSearch` dispatch arm (`searchSession`)
  in `ControlServer`, (3) the `session search [needle] --next|--prev|--close` subcommand in `agtermctlKit`
  (`validate()` rejects flag combos), (4) round-trip tests in `ControlProtocolTests` + the e2e `testSessionSearch`
  in `ControlAPIUITests`.
  `session.overlay.open`/`session.overlay.close` run an ephemeral terminal on top of a session executing
  one program (`args.command`, e.g. a TUI); by default it is full single-pane size,
  hiding the single/split underneath, but `args.sizePercent` (1–100, clamped in `openOverlay`) makes
  it a *floating* opaque framed panel at that percent of the pane with the session still visible.
  `args.color` (`#rrggbb`, REUSING the `session.background` field — no new arg — validated by the shared
  `WatermarkConfig.isValidColorHex` at BOTH the CLI `validate()` and the server arm) gives the overlay
  pane its OWN solid background color, independent of the session's `session.background color`;
  the overlay is sessionless, so it is applied to the overlay SURFACE (not via the session) as the SAME
  `.color` per-surface config overlay (`WatermarkConfig.overlayText` → `configWithOverlay`,
  honoring window translucency), built in `GhosttySurfaceView.applyOverlayBackgroundColor` from the
  view's `overlayBackgroundColorHex` in `createSurface` — works identically for the full + floating variants.
  `AppStore.openOverlay`/`closeOverlay` set non-persisted `Session.overlay*` state (incl.
  `overlaySizePercent`, nil = full / non-nil = floating; and `overlayBackgroundColor`,
  set at open / cleared at close), and the surface runs `config.command` with
  `onExit → closeOverlay`.
  Both variants render IN the per-session eager deck, so the overlay program runs regardless of which
  session is active — the only visible difference is geometry.
  The overlay is ONE always-present, CONSTANT-SHAPE ZStack sibling in `WindowContentView.sessionDetail`,
  `overlayPanel(session:isActive:)` at `.zIndex(3)`, hosting BOTH variants from a single surface host (the
  pre-unify split — a `fullOverlay`-gated `.zIndex(2)` sibling PLUS a separate `floatingOverlayPanel` at
  `.zIndex(3)` — is GONE; `session.overlay.resize` below is why one host matters).
  The panel content (the overlay surface; the opaque `terminalColor` backing + hairline frame + shadow; the
  click-catcher) is gated INSIDE the always-present `GeometryReader` on `session.overlayActive`, so the
  ZStack child COUNT stays constant across open/close/resize — the same SHAPE as no-overlay, which is what
  keeps the AppKit `NSSplitView` from re-hosting and overrunning UP into the transparent titlebar.
  (The panel used to mount OUTSIDE `sessionDetail` as a `detailPane` `.overlay` for exactly this reason;
  the always-present constant-shape sibling holds the same invariant IN-deck.)
  FULL (`overlaySizePercent` nil): fraction 1.0, drawn translucent + blurred with NO opaque backing and NO
  chrome (`Color.clear` backing, 0 corner radius, 0 shadow), and the pane(s) behind hidden at `.opacity(0)`
  + `.allowsHitTesting(false)` via `hideForOverlay` (= `fullOverlay || scratchActive`; kept MOUNTED, shells
  alive like the deck's inactive sessions), so its transparency reveals the window backing (desktop, tint +
  blur), not the session.
  FLOATING (`overlaySizePercent` set): fraction = `percent/100`, drawn as an opaque `terminalColor`-backed,
  hairline-framed, shadowed panel centered in the detail area with the pane(s) VISIBLE around it.
  The modifier CHAIN is IDENTICAL across both variants — only the parameter VALUES flip (backing color,
  corner radius, shadow radius, frame fraction) — so `session.overlay.resize` switching full<->% is a
  value-update, never a child add/remove or a re-parent of the overlay surface NSView (a re-parent would
  blank its Metal drawable).
  Hit-testing on the PANES stays gated on `.allowsHitTesting(!hideForOverlay)` and must NOT flip when a
  FLOATING overlay opens: changing the panes' OWN `allowsHitTesting` on overlay-open (e.g. to
  `!session.overlayActive`) ALSO triggers the NSSplitView titlebar-overrun — the SAME class of perturbation
  as changing the ZStack's shape, even though it looks like a pure interaction change (Codex insisted
  hit-testing was layout-inert; a review-loop regression proved otherwise).
  So a floating overlay leaves the panes hit-testable, and the overlay's focus is protected by a transparent
  `Color.clear.contentShape(Rectangle())` catcher INSIDE `overlayPanel` that absorbs clicks AROUND the panel
  so they can't reach the panes and steal the overlay program's first responder.
  (Generalize the rule: ANYTHING in `sessionDetail`'s HSplitView-hosting subtree that CHANGES SHAPE when
  `overlayActive` flips — adding/removing a sibling, a flattened ZStack, or a toggled pane modifier —
  overruns the split into the titlebar; keep the subtree's shape identical across open/close/resize and gate
  the panel content INSIDE the constant-shape sibling.)
  This constant-shape invariant is load-bearing: a CONDITIONAL sibling inside `sessionDetail`'s ZStack (the
  HSplitView-hosting subtree) made SwiftUI re-host it and the `NSSplitView` overrun UP into the
  transparent titlebar, painting the split over the header (Codex-confirmed;
  the quick terminal renders at this level for the same reason and never hit it).
  `overlayPanel`'s `GeometryReader` reports the detail area EXACTLY — no manual sidebar/titlebar insets
  (computing those at the window level mis-centered the panel one line low) — so it sizes the floating panel
  to `sizePercent`% and centers it in the detail area, the pane(s) visible around it.
  `isActive` gates the overlay surface's focus, so a background floating overlay RUNS but does not steal
  focus (mirrors the full overlay).
  Because both kinds mount in the eager deck, `ControlServer` does NOT select on open by default; it SELECTS
  the target ONLY when the caller passes `--follow` (gated on `options.follow`, NOT on `sizePercent`) — the
  user-facing "pull me to the overlay" switch.
  Without `--follow` full and floating both open on `--target` and run in the background; a `--block` open
  completes without changing the active session.
  `follow` is a new optional ARG on the existing `overlay.open` command (NO new `Command` case): threaded
  `ControlProtocol` (`ControlArgs.follow`) → `ControlDispatcher` `.sessionOverlayOpen`
  (`ControlSessionOverlayOpenOptions.follow`) → `ControlServer` → the `agtermctl … --follow` flag,
  omitted = false for back-compat.
  On close an `.onChange(of: session.overlayActive)` drives `focusAfterReparent()` on the session's `activeSurface`
  so first responder returns to the underlying terminal — the pane re-activating only does a single `makeFirstResponder`,
  which loses the teardown/re-host race (same reason the open path needs the `autoFocus` retry).
  Two libghostty gotchas (confirmed against cmux/macterm, see the gotchas section):
  the surface must **handle `GHOSTTY_ACTION_SHOW_CHILD_EXITED`** (in `GhosttyCallbacks.action`) and return
  `true` to suppress ghostty's "Process exited.
  Press any key" prompt and close immediately — `config.wait_after_command` does NOT suppress it;
  and the overlay must grab focus via a **bounded run-loop `makeFirstResponder` retry** (`autoFocus`),
  since a single-shot loses the SwiftUI/AppKit responder race.
  `--wait`/`overlayWait` keeps the prompt (returns `false` from the action so `close_surface_cb` closes
  after a keypress).
  `handleProcessExit` is idempotent (both the action and `close_surface_cb` can fire).
  Both variants mount in the eager deck, so the caller does NOT need to select the target; `--follow`
  selects it only when the user should be pulled to the overlay.
  **Exit-status capture (`session.overlay.result` + `agtermctl … --block`).** `makeOverlaySurface` wraps
  the command in a FIXED `sh -c '( eval "$AGTERM_OVL_CMD" ); echo $? > "$AGTERM_OVL_CODE"'` — the real
  command + a per-surface temp path ride in env (`AGTERM_OVL_CMD`/`AGTERM_OVL_CODE`,
  never interpolated), and crucially there is **NO stdout/stderr redirect** so a TUI renders normally;
  only the exit status is captured.
  (libghostty's `GHOSTTY_ACTION_SHOW_CHILD_EXITED.exit_code` reflects the login-shell wrapper — always
  0 — so the status is taken from the wrapper's `echo $?`, NOT libghostty;
  the subshell makes an inline `exit N` propagate.) the surface's teardown reads the temp file → `AppStore.recordOverlayExit`
  (sets the non-persisted `Session.overlayExitCode`) → then deletes it, all in `GhosttySurfaceView.destroySurface`
  (via `onExitCodeCaptured`), so EVERY in-process close path — natural exit,
  explicit `session.overlay.close`, force-close (session/workspace/window) — captures the status before
  the file is removed, and the file's lifetime tracks the surface (no registry/sweep);
  `onExit` itself just drives `closeOverlay`.
  `session.overlay.result` (target = session) returns `result.exitCode` once the overlay has closed (`OverlayResultError.stillRunning`
  while up, `noResult` if none ran — both shared constants so the CLI poll matches exactly).
  `agtermctl session overlay open <command> … --block` wraps open → poll `session.overlay.result` (retry
  while still running; targets the returned id with NO window scope, so a frontmost-window change can't
  desync the poll) → exit with the captured status into ONE blocking command (rejects `--block` + `--wait`
  at parse via `validate()`); the program's OUTPUT is its own concern — a TUI like revdiff renders in
  the overlay and writes results to its own `--output` file, which the caller reads (the control channel
  does NOT capture stdout).
  `session.overlay.resize` (target = session) resizes an ALREADY-OPEN overlay IN PLACE between full and
  floating — the way to change size without closing and re-running the program.
  Exactly one of `sizePercent` (1...100 → floating) or `full: true` (→ the full-pane overlay) must be set;
  both, neither, or a percent outside 1...100 is a dispatcher error (mirrored by the CLI `validate()`), and
  `no overlay` when none is open.
  It is a NEW `Command` case (unlike the `--follow` arg, which rode the existing `overlay.open`) because it
  needs its own arg validation, and `full` is a NEW `ControlArgs` field added to distinguish "switch to
  full" (nil `overlaySizePercent`) from "unset" on the wire.
  The arm mutates the non-persisted `Session.overlaySizePercent` via `AppStore.resizeOverlay` (clamping
  1...100, guarding `overlayActive`), and the detail pane re-flows the SAME surface host: the unified
  `WindowContentView.overlayPanel` now renders BOTH variants (full = translucent, no chrome, panes hidden by
  `hideForOverlay`; floating = opaque framed panel over visible panes), so a full<->% switch never re-parents
  the overlay NSView (which would blank its Metal drawable) nor changes the ZStack shape — the old
  `if fullOverlay` z2 sibling is gone, and the always-present `overlayPanel` at z3 is the single host.
  Four-point keep-in-sync audit for `session.overlay.resize`: (1) `case sessionOverlayResize = "session.overlay.resize"`
  + `ControlArgs.full` in `ControlProtocol.swift`, (2) the `.sessionOverlayResize` dispatcher arm (exactly-one
  + range validation) → the app-side `resizeSessionOverlay` (→ `AppStore.resizeOverlay`) behind `ControlActions`,
  (3) the `session overlay resize --size-percent|--full` subcommand (`Resize`, `validate()`-guarded) in
  `agtermctlKit`, (4) round-trip in `ControlProtocolTests` + dispatcher routing/validation in `ControlDispatcherTests`
  + `AppStorePaneTests` (resize clamp/switch/no-overlay) + CLI mapping in `CommandsTests` + the e2e
  `testOverlayResizeSwitchesFloatingAndFull` in `ControlOverlaySplitUITests`.
  The READ side is `ControlSessionNode.overlaySizePercent` on each `tree` node (see the `tree` read-side
  fields below) — populated in `AppStore.controlTree`, round-tripped by `treeSessionNodeRoundTripsWithOverlaySizePercent`/`…OmitsOverlaySizePercentWhenNil`
  and `AppStorePaneTests.controlTreeReportsOverlaySizePercent`, and mirrored in the agent-skill `reference.md`
  tree schema — so a script can record an overlay's size before zooming to `--full` and restore it exactly.
  `surface.zoom` (mode `show`|`hide`|`toggle`) fills the target window with ONE terminal surface,
  hiding the sidebar and collapsing the title bar to a slim strip (traffic lights + an exit button;
  the zoomed terminal is inset below `titlebarHeight`, NOT borderless) — the control half of
  ⌘⇧Return / View ▸ Toggle Terminal Zoom (`BuiltinAction.toggleTerminalZoom`) and the title-bar exit button.
  Targets: omitted/`active` resolves the active surface (quick terminal first, else the active session's
  overlay > scratch > focused-split > primary via `TerminalZoomController.resolveTarget`, which derives the
  precedence from `TerminalZoomSurface.isActive`); an explicit `surface:<session-id>:<left|right|scratch|overlay>`
  id (from `tree`'s `surfaces` nodes) zooms that surface — hidden-but-alive splits/scratches included — and
  `quick` addresses a quick-terminal zoom (the API accepts the id it emits).
  State lives in the per-window, host-free `TerminalZoomController` (`agtermCore/TerminalZoom.swift`,
  registered in `TerminalZoomRegistry`); the app-side arm (`setSurfaceZoom`/`setActiveSurfaceZoom`) only
  resolves the target and shapes the response — ALL mode-vs-state semantics stay in `TerminalZoomController.set`,
  shared with the GUI toggle, so the three callers can't drift.
  Zoom is a VIEW mode with hard invariants: it must not mutate split ratios, focus, sidebar state, or
  split/scratch visibility (the zoom host mounts with `reportsFocusChange: false` → `suppressFocusChange`
  on ALL `onFocusChange` paths, incl. `clearUnseenOnRefocus`), and the zoomed session's deck entry stays
  mounted with a CONSTANT shape — only the zoom-owned slot swaps to its `deckHostsSurface` placeholder —
  so control-opened split/scratch/overlay surfaces still realize and run behind the zoom layer.
  Entering zoom closes the window's transient chrome (the palette — frontmost window only, it is
  app-global — an active ⌘F search, and, for a session zoom, a visible quick terminal); a
  notification-banner reveal exits zoom first; ⌘W exits zoom (the topmost cover, stepwise like the
  quick/overlay/scratch dismissal); font commands stay live (they act on the focused = zoomed surface).
  While zoomed, `quick show` and `session.search` (except `close`) are rejected; `quick hide` stays
  idempotent (a zoomed quick terminal un-zooms first, so a script can always dismiss it), and an
  explicit-target `surface.zoom hide` skips the availability check so hide is idempotent even after
  the surface vanished.
  The READ side is `ControlTree.zoomedSurface` at the tree TOP level — the zoomed surface's control id
  (`surface:<session-id>:<kind>` or `quick`), nil/omitted when nothing is zoomed — LIVE, resolved
  app-side in `buildTree` from the projected window's `TerminalZoomController.target?.controlID` and
  threaded as a `zoomedSurface: () -> String?` closure on `AppStore.controlTree` (the `quickVisible`
  seam), `tree`-only for the same staleness reason; so a script can check "is it already zoomed" and
  record-then-restore. The per-session `surfaces` nodes are the ADDRESSING list, not the state read-back:
  `ControlSurfaceNode.active`/`visible` derive from session flags (overlay/scratch/splitFocused), are
  identical zoomed or not, and `visible` reads false for a pane behind a FLOATING overlay even though
  that pane is visually on screen — documented as a caveat on the node type and in the skill.
  Four-point keep-in-sync audit: (1) `case surfaceZoom = "surface.zoom"` + `ControlSurfaceNode`/`ControlSessionNode.surfaces`
  + `ControlTree.zoomedSurface` in `ControlProtocol.swift`, (2) the `.surfaceZoom` arm (`setSurfaceZoom`) in `ControlServer+SessionActions.swift`
  + the `surfaces`/`zoomedSurface` population in `AppStore.controlTree`/`buildTree`, (3) the `surface zoom` subcommand in `agtermctlKit`,
  (4) round-trip in `ControlProtocolTests` (incl. `treeRoundTripsWithZoomedSurface`/`…OmitsZoomedSurfaceWhenNil`)
  + `TerminalZoomTests` + the e2e `ControlSurfaceZoomUITests` (incl. the tree read-back and the
  `--window`-scoped error paths).
  `dashboard` opens a per-window, VIEW-ONLY grid of live PANE cells
  (`agtermctl dashboard <ids…> [--font-size N | --auto-size] [--window W]`),
  or populates it from the window's most-recently-used sessions instead of explicit ids
  (`dashboard --mru [--font-size N | --auto-size] [--window W]`),
  or CLOSES the open one (`dashboard --close [--window W]`).
  The cell unit is a session+PANE (a `DashboardMember` = session UUID + `.primary`/`.split`): a non-split
  session is ONE `.primary` cell, and a SPLIT session (`hasSplit`, both shells alive) expands into TWO cells —
  its `.primary` and `.split` panes — so a split shows both panes side by side.
  It is the N-surface generalization of `surface.zoom`'s reparent, with focus inverted (zoom focuses
  its one surface; the dashboard focuses NONE while open).
  It is reachable BOTH over the socket AND from the GUI:
  the control open path is `dashboard`/`agtermctl dashboard` (unchanged),
  and the GUI opener is `BuiltinAction.dashboard` (⌘⇧D), Navigate ▸ Dashboard, and the command palette
  `Dashboard` entry — all TOGGLE the frontmost window's MRU grid auto-sized (the `dashboard --mru
  --auto-size` equivalent), reusing the existing socket command with NO new control command, so the catalog
  does not grow for it.
  Once open, the keyboard drives it: arrows move the highlight, Enter jumps into the highlighted session
  AND focuses that exact pane + closes, Esc closes.
  Host-free geometry + navigation + auto-size math live in `DashboardLayout`
  (`grid(count:) = ceil(sqrt(n))` cols, `move` clamped 2-D nav into a ragged last row,
  `dashboardFontSize(cols:rows:base:)`), per-window state in the `@Observable @MainActor DashboardController`
  (`members: [DashboardMember]`/`highlighted: DashboardMember?`/`fontMode`/`appliedFontSize`) reached through
  `DashboardControllerRegistry` — the exact `TerminalZoomController`/`TerminalZoomRegistry` precedent.
  Validation is host-free in `ControlDispatcher.dispatchDashboard`:
  `--close` takes no ids, `--mru`, or font flags, `--font-size` is mutually exclusive with `--auto-size`,
  a `--font-size` must be finite and positive, an open needs at least one id OR `--mru`,
  and `--mru` cannot be combined with explicit ids (but composes with the font flags + `--window`).
  **The 9-cell cap is NO LONGER in the dispatcher** — the cell unit is a PANE now, so a split session
  expands to two cells and the cap counts PANES, which needs the store; the dispatcher forwards ALL raw ids
  untouched and the cap lives APP-SIDE.
  The dispatcher routes to `ControlActions.setDashboard(targets:window:close:fontMode:mru:)`;
  the app-side `ControlServer` resolves ids via `ControlTargetResolver` inside `args.window ?? frontmost`,
  DEDUPS by resolved UUID, drops unresolved, then EXPANDS each resolved session IN ORDER into pane cells
  (always its `.primary`; plus `.split` when `hasSplit`), CAPS the resulting PANE list to
  `DashboardLayout.maxCells` (9) — so the drop counts panes, reported as
  `dropped N pane(s) beyond the 9-cell limit` in `result.text`, APPENDED to any `unresolved: …` text with
  `; ` (neither clobbers the other) — closes any active zoom (zoom ↔ dashboard are reciprocally exclusive),
  and drives that window's controller.
  `WindowContentView` reparents each cell's OWN pane surface (`.primary` → `\.surface`, `.split` →
  `\.splitSurface`) via the generalized `dashboardHostsSurface` (both panes of a split member are claimed,
  each yielding its deck slot's `Color.clear` placeholder).
  `--mru` skips the id-resolution entirely: it takes the sessions from `AppStore.recentSessions(limit:)`
  (host-free, on `AppStore+Recency.swift` — the window's `sessionRecency.top(9, in:validIDs)`, most-recent
  first, ≤ 9, fewer if fewer, stale/closed ids skipped) then expands + caps like the id path, erroring
  `no recent sessions` on an empty window; the font flags still apply and nothing goes `unresolved`.
  Enter (`selectDashboardMember`) selects the session, CLOSES the dashboard, then focuses the cell's EXACT
  pane — the split pane via `focusSplitPane(_:wantSplit:true)` for a `.split` cell (mirroring
  `revealActiveBlockedPane`'s `.right` branch), else the main pane; close-before-focus keeps the
  `dashboardActive` focus guards from blocking it.
  READ-BACK: FOUR `tree`-top-level fields (LIVE, `tree`-only like `zoomedSurface`) supplied to
  `AppStore.controlTree(...)` as app-side closures reading the target window's controller through the registry —
  `dashboardMembers` (PANE refs in grid order, `<session-id>:left`/`<session-id>:right` via
  `DashboardMember.controlRef`, so a split session appears as both),
  `dashboardHighlighted` (the highlighted cell's pane ref),
  `dashboardFontSize` (the applied absolute size in points, nil = untouched),
  and `dashboardFontMode` (`auto`/`fixed`/`untouched`).
  `--mru` adds NO new read-back — the members it resolves ARE the existing `dashboardMembers`,
  so a script reads back what it opened there (no tree field is owed for the mru intent itself).
  Four-point keep-in-sync audit: (1) `case dashboard` + `ControlArgs.close`/`fontSize`/`autoSize`/`mru`
  (ids reuse `targets`, window reuses `window`) + the four `ControlTree.dashboard*` fields in `ControlProtocol.swift`,
  (2) the `.dashboard` dispatch arm (`dispatchDashboard`) → `ControlActions.setDashboard` (app-side
  `ControlServer`) + the four read-back closures at the `controlTree` build site,
  (3) the `dashboard` subcommand (`validate()`-guarded flag combos) in `agtermctlKit/MiscCommands.swift`,
  (4) round-trip in `ControlProtocolTests` + dispatcher validation/routing in `ControlDispatcherTests`
  (now asserting the dispatcher forwards ALL ids un-capped) + `DashboardLayoutTests`/`DashboardControllerTests`
  (pane-cell open/move/highlight/reconcile, incl. a split member pruned when its split closes) +
  `AppStoreTests` (the pane-ref read-back closures) + CLI mapping in `CommandsTests` + the e2e
  `DashboardUITests` (incl. `testSplitSessionOpensTwoCellsAndEnterFocusesSplitPane`, which asserts the split
  session's two `:left`/`:right` cells AND that Enter on the split cell flips the tree `splitFocused`).
  The PANE expansion + the PANE cap + the dropped-pane text are app-side (`ControlServer.setDashboard`,
  they need the store), build-verified + exercised by the e2e; the dispatcher no longer caps.
  The `--mru` flag rides the same command with NO new command/read-back — its keep-in-sync is:
  `ControlArgs.mru` (`ControlProtocol.swift`), the dispatcher `--mru` validation + routing
  (`dispatchDashboard`, `--close`/id mutual-exclusion), the `mru:` param on `ControlActions.setDashboard`
  + the app-side `AppStore.recentSessions(limit:)` lookup (`ControlServer`), the `--mru` CLI flag
  (`MiscCommands.swift`), and its tests
  (`AppStoreTests.recentSessions*`, `ControlProtocolTests` round-trip/omit, `ControlDispatcherTests`
  `dashboardMru*`, `CommandsTests` `dashboardMru*`, and `DashboardUITests.testDashboardMruOpensRecentSessions`).
  It is state-mutating-with-read-back EXEMPT: the resulting state IS `dashboardMembers`,
  so no new tree field is owed.
  See the `libghostty.md` dashboard note for the reparent/overlay/view-only + transient-font-override mechanics.
  Mode-bearing commands (`session.split`/`quick`) compute the delta against current state so `on`/`off`/`show`/`hide`
  are idempotent, and an unknown mode is an error.
  `quick`'s visibility reads back on `ControlTree.quickVisible` at the tree TOP level — LIVE, resolved
  app-side in `buildTree` from the projected window's `QuickTerminalController.isVisible` (the window id
  found by store identity, `library.openIDs().first { library.store(for:) === store }`, since the quick
  terminal is per-window); `tree`-only like `sidebarMode` (the GUI ⌃` toggle bypasses the command path, so
  a cached `window.list` copy would go stale), so a script can make the `quick` toggle idempotent.
  Threaded as a `quickVisible: () -> Bool?` closure on `AppStore.controlTree` (defaulting nil for host-free
  tests), covered by `treeRoundTripsWithQuickVisible`/`treeOmitsQuickVisibleWhenNil` +
  `AppStoreTests.controlTreeReportsQuickVisibleFromClosure`; the app-side `QuickTerminalRegistry` read is build-verified.
  `quick.type`/`quick.text` are the input/read-back pair for the quick terminal, the twins of `session.type`/`session.text`
  (the quick terminal is the one typing surface the socket couldn't reach before — issue #170).
  Both are frontmost-window-only (no `--target`/`--window`/`--pane`; the quick terminal is a single per-window surface),
  dispatcher-owned via `ControlActions.typeQuick(text:)` / `readQuickText(all:lines:)` (both `async`), and inject/read
  through the same `GhosttySurfaceView.inject(text:)` / `readScreenText(all:lines:)` primitives the session commands use.
  They are `async` because `quick show` flips `isVisible` before SwiftUI mounts + libghostty realizes the surface, so
  a bounded main-actor poll (12×30 ms, the `session.type` realize-poll pattern) waits out the mount — `quick show; quick
  type` back-to-back is reliable rather than racing.
  Fast-fail when NOT racing: `quick terminal not open` when the overlay has never been shown (no surface AND not visible,
  so the poll returns at once), `quick terminal not realized` / `failed to read surface buffer` if a shown surface never
  comes up within the poll, `no open window` when there is no window.
  A shown-then-hidden quick terminal keeps its surface alive, so it types/reads while hidden (like `session.type --pane
  scratch`).
  `quick.text` is the read-back for `quick.type` (there is no NEW tree-node field — you read via the sibling `text`
  command, exactly as `session.text` reads back `session.type`).
  Covered by the `quickType*`/`quickText*` `ControlDispatcherTests` + the e2e `testQuickTypeAndReadText`
  (type a marker, read it back off the quick surface).
  `session.status` flags a per-session agent status on the sidebar row — `args.status` is `idle`|`active`|`completed`|`blocked`
  (`AgentStatus(rawValue:)` → an `invalid status` error on anything else),
  `args.blink` pulses the glyph, and `args.autoReset` (status-agnostic, caller-set,
  symmetrical with `blink`) makes it clear back to idle once the session is visited.
  `args.sound` plays a ONE-SHOT sound when the status is applied (caller-driven,
  NOT stored on `AgentIndicator` — `default`/`beep` = `NSSound.beep()`, any other value = the named system
  sound via `NSSound(named:)`, which also resolves custom sounds in `~/Library/Sounds`);
  it is validated UP-FRONT against the app-side `StatusSoundPlayer.shared` (a singleton that caches resolved
  `NSSound`s so a short clip isn't cut off when the local goes out of scope — also reused by the Settings
  picker preview), so an unknown name is an `unknown sound: X` error that leaves the status UNCHANGED,
  and the fire is inside `resolveSession` so a bad target still errors `notFound` without playing.
  When NO per-call `args.sound` is given and a session TRANSITIONS into `blocked`,
  the user's **Settings ▸ Appearance ▸ Agent Status ▸ Blocked sound** (`AppSettings.blockedStatusSoundName`,
  GUI-only, default None) plays as a best-effort default.
  The transition is gated by a `wasBlocked` read of the session's current status BEFORE `setAgentIndicator`,
  so a REPEATED `blocked` set does not replay the default (and an empty per-call `args.sound` counts
  as unset); the precedence is the host-free `AgentStatus.effectiveSound(perCall:blockedDefault:)` (explicit
  per-call wins; the default is blocked-only), with the transition gate itself in the server.
  That setting is keep-in-sync EXEMPT like the status colors, since the per-status sound already has
  full control coverage via `--sound`.
  `args.color` (`#rrggbb`, REUSING the `session.background`/`session.overlay.open` field — no new arg —
  validated by the shared `WatermarkConfig.isValidColorHex` in the dispatcher, an `invalid color (expected #rrggbb)`
  error that leaves the status UNCHANGED) is a per-call glyph-tint OVERRIDE.
  It rides the ephemeral `AgentIndicator` (`AgentIndicator.color`), so — because `setSessionStatus` builds
  a fresh indicator every call — the next `session.status` without a color naturally DISCARDS it (no explicit
  clear); nil renders the Settings-configured status color.
  Both glyph render sites resolve it through the SHARED `GhosttyApp.statusColor(for:override:)` (a valid
  hex wins, nil/malformed falls back to `statusColor(for:)`): the AppKit sidebar `StatusIconView` and the
  SwiftUI attention-list `StatusGlyph` (`PaletteItem.statusColor`), so they can't drift.
  It is keep-in-sync EXEMPT like the status colors/sound — the per-call color has full control coverage
  via `--color` and no GUI setter (the Settings colors are the app-wide default, not a per-session tint).
  Setting a non-idle status is control-driven (the hooks/agents call it;
  no GUI sets active/completed/blocked), but clearing to idle ALSO has a GUI — the **Clear Status** action
  (see the Agent-status glyph note) — so the idle case is keep-in-sync covered by `session.status idle`.
  Cross-window via the shared `resolveSession` (the install's Stop hook targets its own `$AGTERM_SESSION_ID`,
  which may live in a non-frontmost window).
  The arm (`setSessionStatus`) builds an `AgentIndicator{status, blink, autoReset, color}` (host-free,
  ephemeral — never in `SessionSnapshot`) and drives the single `AppStore.setAgentIndicator(_:forSession:)`
  mutation point (unknown id = clean no-op), returning the id.
  Four-point keep-in-sync audit for `session.status --color`: (1) `ControlArgs.color` (reused) +
  `AgentIndicator.color` + `ControlSessionStatusUpdate.color` in `agtermCore`, the dispatcher hex-validation,
  (2) the `.sessionStatus` arm threading `update.color` into the indicator + the two render sites via
  `GhosttyApp.statusColor(for:override:)`, (3) the `session status --color` option (`validate()`-guarded)
  in `agtermctlKit`, (4) round-trip in `ControlProtocolTests` + dispatcher validation in `ControlDispatcherTests`
  + `AgentStatusTests` (indicator color + Equatable) + CLI mapping in `CommandsTests` + the e2e
  `testSessionStatusColorValidatesHex` in `ControlSidebarStatusUITests` (asserts the command path — the
  glyph TINT itself is not accessibility-observable).
  `args.pane` (`left`|`right`|`scratch`, REUSING the shared `--pane` addressing vocabulary — parsed to the
  host-free `StatusPane` and validated by the dispatcher, an `--pane must be left, right, or scratch` error
  that leaves the status UNCHANGED) records WHICH pane set the status onto the ephemeral `AgentIndicator.statusPane`
  (nil/omitted is treated as `left` = the main pane).
  It drives two consumers.
  (1) Pane-scoped keystroke-clear: the main/split/scratch surface factories each wire `onUserInputClearsStatus`
  to a closure that clears only when the host-free `AgentIndicator.clearedBy(pane:isInterrupt:)` says the keystroke's
  OWN pane owns the current status, so a `right`- or `scratch`-tagged block SURVIVES foreground typing in the
  main pane (see the Notifications rule).
  (2) Pane-aware attention navigation: auto-follow and the GUI attention-nav (⌃⌥↑/⌃⌥↓, menu, palette) reveal
  and focus the tagged pane — flip `splitFocused` to the split, or show a hidden scratch via `AppStore.toggleScratch`
  — instead of always the main pane (the shared `AppActions.revealActiveBlockedPane`, wired into
  `selectNext/PreviousAttentionSession` + `autoFollowed`).
  The `session.go next-attention|prev-attention` control arm (`goSession`) only drives `AppStore.navigateSession`
  and does NOT call the reveal, so the socket steps the selection but does not itself move focus into the pane
  (see the Menu/actions rule).
  It reads back on each `tree` node as `ControlSessionNode.statusPane` (omitted when nil, gated on the SAME
  non-idle condition as `status` so an idle node reports neither).
  The `--blink` flag and `--color` override read back the same way — `ControlSessionNode.statusBlink`
  (`true` when blinking, omitted otherwise) and `statusColor` (the `#rrggbb`, omitted when using the default
  color), both populated in the tree builder gated on the SAME non-idle condition — so a script can record
  the FULL status (state + pane + blink + color) and restore it.
  Four-point keep-in-sync audit for `session.status --pane`: (1) the `StatusPane` enum + `AgentIndicator.statusPane`
  + `AgentIndicator.clearedBy(pane:isInterrupt:)` + `ControlSessionStatusUpdate.pane` + `ControlSessionNode.statusPane`
  + `SurfaceEnvironment.session(pane:)` (injects `AGTERM_PANE`) in `agtermCore`, plus the dispatcher `StatusPane`
  parse/validation, (2) the `.sessionStatus` arm threading `update.pane` into the indicator + the per-factory
  `AGTERM_PANE` env + the pane-scoped keystroke-clear closures + the `revealActiveBlockedPane` nav step,
  (3) the `session status --pane` option (`validatePaneArgument`-guarded) + the hook wrapper forwarding
  `$AGTERM_PANE` as `--pane`, (4) round-trip in `ControlProtocolTests` + dispatcher validation in `ControlDispatcherTests`
  + `AgentStatusTests` (the `clearedBy` truth table) + `SurfaceEnvironmentTests` + `AgentStatusWrapperTests`
  + CLI mapping in `CommandsTests` + the e2e in `PaneAwareStatusUITests`.
  It is control-native for the tag itself (no GUI sets a pane), the same keep-in-sync footing as `--color`/`--sound`.
  `session.status --pane-id <token>` is the robust companion to `--pane`, added for #199:
  the baked `AGTERM_PANE` role goes STALE when a split survivor is promoted into the main pane and the
  session is then re-split — both the promoted agent (baked `right`) and the fresh helper (baked `right`)
  emit `--pane right` with `hasSplit == true`, so the `setAgentIndicator` `!hasSplit` coercion cannot tell
  them apart and the block lands on the wrong pane.
  The fix bakes a STABLE per-surface token (`AGTERM_PANE_ID`, distinct from the mutable role) that the hook
  forwards as `--pane-id`; the app resolves it against the session's LIVE surfaces
  (`Session.paneRole(forToken:)` — `.left`/`.right`/`.scratch` from which slot currently holds the matching
  `TerminalSurface.paneToken`) and lets it OVERRIDE the stale `--pane`, falling back to `--pane` when the
  token is absent or unknown (older shells, a torn-down surface).
  This makes the status-SET path resolve the pane the same way the keystroke-clear already does via the
  live `GhosttySurfaceView.isSplitPane` (see [[notifications]]) — a per-surface token is irreducibly
  required because the role alone is degenerate once both live surfaces are baked `right`.
  It carries NO new read-back — `--pane-id` is alternative ADDRESSING for the same `statusPane` state
  (the RESOLVED role reads back on `ControlSessionNode.statusPane`), the `session.type --pane` pattern.
  Keep-in-sync: (1) `ControlArgs.paneID` + `ControlSessionStatusUpdate.paneID` + `Session.paneRole(forToken:)`
  + `TerminalSurface.paneToken` + `SurfaceEnvironment.session(paneToken:)` (injects `AGTERM_PANE_ID`) in
  `agtermCore`, plus the dispatcher threading `paneID` un-validated (opaque token), (2) the `.sessionStatus`
  arm resolving `update.paneID` to the live role in `setSessionStatus` + `GhosttySurfaceView.paneToken`
  (computed from the baked env) + `surfaceEnv` generating a fresh token per session-owned pane,
  (3) the `session status --pane-id` option + the hook wrapper forwarding `$AGTERM_PANE_ID`,
  (4) round-trip in `ControlProtocolTests` + dispatcher threading in `ControlDispatcherTests` +
  `SessionTests` (`paneRole` resolver, incl. the promote + re-split case) + `SurfaceEnvironmentTests`
  (`AGTERM_PANE_ID` bake) + `AgentStatusWrapperTests` (`--pane-id` forwarding) + CLI mapping in `CommandsTests`
  + the e2e `testPaneIDOverridesStaleRoleThenFallsBack` in `PaneAwareStatusUITests` (reads the pane's real
  `$AGTERM_PANE_ID` and proves override + fallback).
  Visibility is keep-state vs one-time, decided by `autoReset` alone: `AppStore.selectSession` resets
  an `autoReset` indicator (the `completed` flash) to idle on BOTH the session visited AND the one left
  (right after `clearUnseen`), so it never lingers on a row you switch away from,
  and leaves a non-`autoReset` one untouched.
  The glyph is NOT gated by selection — it shows on every non-idle session,
  the selected one included (see below).
  `keymap.reload` re-reads `keymap.conf` and returns the parse-diagnostic count in `result.count` (0
  reads as a clean reload; `agtermctl keymap reload` prints `ok` then, else `N diagnostic(s)`).
  It is the SAME `SettingsModel.reloadKeymap()` path the GUI's File ▸ Reload Keymap menu/palette item
  drives, so the GUI half and the control half can't diverge — control-native only in the count it reports
  back; no `--window` selector (the keymap is app-global — a single app-wide `SettingsModel`,
  constructed once in `agtermApp.init` and shared with `ControlServer`).
  Four-point keep-in-sync audit for `keymap.reload`: (1) `case keymapReload = "keymap.reload"` in `ControlProtocol.swift`
  (returns the new `ControlResult.count: Int?`, no target/args), (2) the `.keymapReload` dispatch arm
  in `ControlServer`, (3) the `keymap reload` subcommand in `agtermctlKit`,
  (4) round-trip tests in `ControlProtocolTests` plus the e2e in `ControlAPIUITests`.
  See the Keymap section for the parser/menu/monitor design.
  `config.reload` re-reads the agterm-scoped `ghostty.conf` and returns the ghostty config-diagnostic
  count in `result.count` (0 reads as a clean reload; `agtermctl config reload` prints `ok` then,
  else `N diagnostic(s)`).
  It is the SAME `AppActions.reloadGhosttyConfig()` path the GUI's File ▸ Reload Config menu/palette
  item + the Edit-ghostty overlay close drive (which posts the warning banner on a malformed file),
  so the GUI half and the control half can't diverge — control-native only in the count it reports back;
  no `--window` selector (the config is app-global — one `SettingsModel` + one `GhosttyApp`,
  shared with `ControlServer`).
  The arm calls `actions.reloadGhosttyConfig()` then returns `GhosttyApp.shared.lastConfigDiagnosticsCount`.
  Four-point keep-in-sync audit for `config.reload`: (1) `case configReload = "config.reload"` in `ControlProtocol.swift`
  (reuses `ControlResult.count`, no target/args), (2) the `.configReload` dispatch arm (`reloadGhosttyConfig`)
  in `ControlServer`, (3) the `config reload` subcommand in `agtermctlKit`,
  (4) round-trip tests in `ControlProtocolTests` plus the e2e in `ControlAPIUITests`.
  See the Settings section for the config layer + Edit/Reload.
  `sidebar` (mode `show`|`hide`|`toggle`, default toggle, frontmost window — mirrors `quick`,
  delta-computed so it's idempotent, unknown mode + no-open-window are errors) shows/hides the custom-split
  sidebar — the per-window `AppStore.sidebarVisible` (persisted per-window in `Snapshot`,
  restored on relaunch alongside `AppStore.sidebarWidth`; `toggleSidebar`/`setSidebar` call `save()`;
  the custom split replaced `NavigationSplitView`, so there is no system toggle).
  `AppActions.toggleSidebar()` flips `library.activeStore?.sidebarVisible` and `WindowContentView` animates
  it (`splitRoot`'s `.animation(value:)`, so every caller animates uniformly — the toolbar button no
  longer wraps its own `withAnimation`); shared by the title-bar `sidebar-toggle-button`,
  View ▸ Show/Hide Sidebar, the ⌃⇧P palette "Toggle Sidebar", and the ⌃⌘S keymap action (`BuiltinAction.toggleSidebar`,
  expressible so pure-`defaultChord`-driven).
  Four-point keep-in-sync audit: (1) `case sidebar` in `ControlProtocol.swift` (reuses `ControlArgs.mode`),
  (2) the `.sidebar` dispatch arm (`setSidebarVisibility`) in `ControlServer`, (3) the `sidebar` subcommand in
  `agtermctlKit`, (4) round-trip in `ControlProtocolTests` + the e2e `testSidebarShowHideToggle` (sidebar
  hide removes the `session-row`s from the AX tree) in `ControlSidebarStatusUITests`.
  `theme.set` sets + persists a theme (see the Theme picker section) PER SLOT, mirroring the two Settings pickers over the shared `SettingsModel.setLightTheme`/`setDarkTheme`/`setSystemThemes`.
  `args.name` (alias `args.light`; both together is an error) sets the light/single `theme` slot,
  KEEPING the `darkTheme` slot if one is set (they are separate fields, no recompose);
  nil/empty = ghostty's built-in / "default ghostty" (NOT the seeded `agterm` app default),
  and a bare `theme set` clears BOTH slots + turns syncing off.
  `args.dark` sets the `darkTheme` slot alone and turns appearance syncing ON (`followSystemAppearance`,
  the light side seeds from the current theme, else `Builtin Light`);
  the reserved value `none` clears the dark slot (syncing off, the light side survives as the plain theme).
  The `.themes` palette commit maps to the CURRENT appearance's slot (NO live preview over the socket — preview is interactive-only).
  An unknown name (not in `SettingsCatalog.themeNames()`) is an `unknown theme: X` error (a typo silently
  doing nothing is worse than a fail); the response always echoes the full post-change state
  (`result.theme`/`sync`/`light`/`dark`).
  `theme.list` returns `result.themes` = the bundled names + `result.theme` = the plain current one (nil =
  ghostty built-in; absent on a fresh install means the seeded `agterm` is current) + `result.sync`/`light`/`dark`;
  while syncing `result.theme` is ABSENT — the state rides the three sync fields.
  `agtermctl theme list` prints one name per line with a leading "default ghostty" row,
  the active marked `* ` (both sides + a header while syncing), and `theme.set` prints `ok` (non-create mutation).
  App-global like `keymap.reload` (one `SettingsModel`), so NO `--window` selector.
  Four-point keep-in-sync audit: (1) `case themeSet = "theme.set"` + `case themeList = "theme.list"`
  in `ControlProtocol.swift` (reuse `ControlArgs.name`; add `ControlResult.theme`/`themes`),
  (2) the `.themeSet` (`setTheme`, with name validation) + `.themeList` dispatch arms in `ControlServer`,
  (3) the `theme set [name] [--light] [--dark]` / `theme list` subcommands in `agtermctlKit` (+ `SocketClient.formatThemes`),
  (4) round-trip in `ControlProtocolTests` + the e2e `testThemeListAndSet` in `ControlAPIUITests` and `testThemeSyncWithSystemAppearance` in `ControlAPIThemeUITests`.
  See the Theme picker section for the GUI/preview half.
  `session.flag` (target = session) flags/unflags a session for the flagged working-set view — `args.mode`
  is `on`|`off`|`toggle`|`clear` (`clear` IGNORES the target and unflags every session in the resolved
  store via `AppStore.clearFlags()`, mirroring `session.scratch`/`session.split`'s mode-bearing shape),
  drives `AppStore.setFlag(_:forSession:)` (idempotent — no-op + no save when unchanged),
  surfaces the `flagged` bool on `ControlSessionNode` in the `tree` builder,
  and returns the session id; an unknown mode is an error.
  It is the control half of the row context-menu Flag/Unflag + the View-menu/palette Flag Session/Clear
  Flagged.
  Pair with `sidebar.mode flagged` to view just the flagged sessions.
  Four-point keep-in-sync audit for `session.flag`: (1) `case sessionFlag = "session.flag"` in `ControlProtocol.swift`
  (reuses `ControlArgs.mode`; adds `flagged` to `ControlSessionNode`), (2) the `.sessionFlag` dispatch
  arm (`setSessionFlag`) in `ControlServer`, (3) the `session flag on|off|toggle|clear` subcommand (`FlagCommand`)
  in `agtermctlKit`, (4) round-trip in `ControlProtocolTests` + the e2e `testSessionFlagAndSidebarModeFlagged`
  in `ControlSidebarStatusUITests`.
  `session.seen` (target = session) clears a session's unseen-notification badge WITHOUT changing the
  selection, focus, or agent status — the focus-free counterpart to `notify`, which raises the badge over
  the socket while the only clear paths (`AppStore.selectSession`, a pane's `onFocusChange(true)`) are
  both focus-coupled.
  It drives the already-public `AppStore.clearUnseen(_:)` (the same primitive `selectSession` calls),
  so it is idempotent (a no-op when already zero; the count is ephemeral, absent from `SessionSnapshot`,
  so it triggers no save) and returns the session id; NO args beyond target/window (leaner than `session.flag`
  — no mode).
  It is control-NATIVE (no GUI/menu equivalent — visiting the session is the GUI's only "mark seen", and
  it is inseparable from selecting) — the same footing as `notify`/`session.type`/`session.copy`.
  The read side is the new `unseen` field on `ControlSessionNode` (the `session.unseenCount`, populated
  in the `tree` builder, omitted when zero), so a script can query the count and clear it symmetrically.
  Four-point keep-in-sync audit for `session.seen`: (1) `case sessionSeen = "session.seen"` +
  `unseen: Int?` on `ControlSessionNode` in `ControlProtocol.swift` (no new `ControlArgs` field),
  (2) the `.sessionSeen` dispatch arm (`markSessionSeen`) in `ControlDispatcher`/`ControlServer` + the
  `unseen` population in `AppStore.controlTree`, (3) the `session seen` subcommand (`Seen`) in `agtermctlKit`,
  (4) round-trip (`sessionSeenRoundTrips` + `treeSessionNodeRoundTripsWithUnseen`/`…OmitsUnseenWhenNil`)
  in `ControlProtocolTests` + dispatcher routing in `ControlDispatcherTests` + `AppStoreTests`
  (`controlTreeReportsUnseenCountWhenPositive`/`…OmitsUnseenCountWhenZero`) + CLI mapping in `CommandsTests`
  + the e2e `testSessionSeenClearsBadgeWithoutFocus` in `ControlSidebarStatusUITests`.
  `sidebar.mode` (frontmost window) flips the sidebar VIEW between the workspace tree and the flat flagged
  working-set list — `args.mode` is `tree`|`flagged`|`toggle` (delta-computed against `AppStore.sidebarMode`
  so it's idempotent, unknown mode = error), drives `setSidebarViewMode` → `AppStore.setSidebarMode`.
  It is the control half of the bottom-bar `flagged-view-toggle` + the View-menu Show Flagged/Show All
  + `BuiltinAction.toggleFlaggedView`; the existing `sidebar [show|hide|toggle]` is now the default `sidebar visibility`
  subcommand alongside `sidebar mode`.
  Its READ side is `ControlTree.sidebarMode` at the tree TOP level (`AppStore.sidebarMode.rawValue`,
  `tree`|`flagged`), the read side of this write-only command so a script can record and restore the view
  mode — the sibling of `sidebarVisible`, except `tree`-ONLY (not mirrored onto the cached `window.list`,
  since the GUI `flagged-view-toggle` bypasses the command path and would leave a cached copy stale).
  Four-point keep-in-sync audit: (1) `case sidebarMode = "sidebar.mode"` in `ControlProtocol.swift` (reuses
  `ControlArgs.mode`), (2) the `.sidebarMode` dispatch arm (`setSidebarViewMode`) in `ControlServer`,
  (3) the `sidebar mode tree|flagged|toggle` subcommand (`Mode`, alongside the `Visibility` default)
  in `agtermctlKit`, (4) round-trip in `ControlProtocolTests` + the e2e `testSessionFlagAndSidebarModeFlagged`
  in `ControlSidebarStatusUITests`.
  `sidebar.expand`/`sidebar.collapse` expand every workspace / collapse all but the active one in a window's
  sidebar TREE — `expand` drives `AppActions.expandAllWorkspaces(in:)`, `collapse` drives `collapseOtherWorkspaces(in:)`
  (collapse keeps the ACTIVE session's workspace expanded and scrolls its row into view).
  UNLIKE `sidebar`/`sidebar.mode` (frontmost-only, no selector), these honor the global `--window` selector
  (`ControlArgs.window`): the arm resolves the target store via `resolvePlacementStore(window)` (frontmost
  by default; a named window must be OPEN, else the closed-window error;
  no open window at all → `no open window`), then posts a notification (`.agtermExpandWorkspaces`/`.agtermCollapseWorkspaces`)
  carrying THAT `AppStore` as the object.
  `WorkspaceSidebar.Coordinator` registers its observer with `object: store`,
  so NotificationCenter delivers ONLY to that window's sidebar Coordinator — this object-scoping (the
  rename notifications self-scope via the selected-session guard; expand/collapse have no such natural
  guard) is exactly what lets the control path target a specific (even background) window while the GUI
  menu/palette use the frontmost.
  A graceful no-op in `flagged` mode (no workspace rows: `expandWorkspacesNotified` gates on tree mode,
  `collapseOthers` gates internally); idempotent.
  GUI half (frontmost only): View ▸ Expand/Collapse Workspaces (plain keyless items,
  disabled with no active store or in flagged mode) + the ⌃⇧P palette "Expand Workspaces"/"Collapse Workspaces"
  (tree-mode only).
  Four-point keep-in-sync audit: (1) `case sidebarExpand = "sidebar.expand"` + `case sidebarCollapse = "sidebar.collapse"`
  in `ControlProtocol.swift` (reuse `ControlArgs.window`, no new field),
  (2) the `.sidebarExpand`/`.sidebarCollapse` dispatch arms (`expandSidebar(window:)`/`collapseSidebar(window:)`)
  in `ControlServer`, (3) the `sidebar expand`/`sidebar collapse` subcommands (`Expand`/`Collapse` on
  `ClientOptions` for `--window`, alongside the `Visibility` default + `Mode`) in `agtermctlKit`,
  (4) round-trip (incl. the windowed variant) in `ControlProtocolTests` + the e2e `testSidebarExpandCollapse`
  in `ControlSidebarStatusUITests`.
  `workspace.focus` (target = workspace) collapses the sidebar tree to a single workspace — `args.mode`
  is `on`|`off`|`toggle` (`off` unfocuses only when the target is the currently focused one,
  `toggle` flips; delta-computed against `AppStore.focusedWorkspaceID` so it's idempotent,
  unknown mode = error), drives `focusWorkspace` → `AppStore.setFocusedWorkspace`,
  honors the global `--window` selector, and returns the workspace id.
  Per-window + persisted, orthogonal to `sidebar.mode` (the flat flagged list ignores focus);
  selecting a session outside the focused workspace auto-unfocuses (see the Sidebar section).
  It is the control half of the workspace-row Focus/Unfocus + the `focus-pill` ✕ + `BuiltinAction.focusWorkspace`/`focusActiveWorkspace`
  + the Clear Focus menu/palette item.
  Its READ side is `ControlWorkspaceNode.focused` on each `tree` workspace node (`workspace.id == focusedWorkspaceID ? true : nil`
  in the tree builder — DISTINCT from `active`, the selected workspace), so a script can record which
  workspace is focused and restore it; omitted on the non-focused ones and absent when nothing is focused.
  Four-point keep-in-sync audit: (1) `case workspaceFocus = "workspace.focus"` in `ControlProtocol.swift`
  (reuses `ControlArgs.mode`), (2) the `.workspaceFocus` dispatch arm (`focusWorkspace`) in `ControlServer`,
  (3) the `workspace focus on|off|toggle` subcommand (`Focus`) in `agtermctlKit`,
  (4) round-trip in `ControlProtocolTests` + the e2e `testWorkspaceFocusHidesOtherWorkspaces` in `ControlSidebarStatusUITests`
  plus the `FocusWorkspaceUITests` XCUITest.
  `workspace.collapse`/`workspace.expand` (target = workspace) collapse/expand ONE workspace's subtree in
  the sidebar tree — the per-workspace analogue of the all-workspace `sidebar.expand`/`sidebar.collapse`
  (scope by prefix: `sidebar.*` acts on every workspace, `workspace.*` on the addressed one).
  They resolve the workspace via `resolveWorkspace` (honoring the global `--window` selector), drive
  `setWorkspaceExpansion` → `AppActions.setWorkspaceExpanded(_:expanded:in:)`, and return the workspace id.
  Unlike the GUI (a row click drives `expandItem`/`collapseItem` directly, keep-in-sync EXEMPT), there is
  no GUI caller — the row click is the only GUI path — so this is a control-only pair.
  The app-side flow keeps the source-of-truth persist OUT of the view: `AppActions.setWorkspaceExpanded(_:expanded:in:)`
  writes `AppStore.setWorkspaceExpanded` (delta-guarded) FIRST, THEN posts `.agtermSetWorkspaceExpanded`
  carrying the target `AppStore` as the object + the workspace id/desired-state in `userInfo`.
  The persist must NOT ride the notification alone: `WindowContentView` mounts `WorkspaceSidebar` only
  while `sidebarVisible`, so with the sidebar HIDDEN the Coordinator is torn down (its `.agtermSetWorkspaceExpanded`
  observer removed in `isolated deinit`) and a notification-only write would silently drop, leaving the
  `collapsed` read-back stale while the command still returns `ok` — the record-then-restore/toggle
  contract the feature exists for.
  So `WorkspaceSidebar.Coordinator.setWorkspaceExpandedNotified` is VIEW-SYNC ONLY: it keeps the tracked
  `expandedWorkspaceIDs` in step — so the intent survives a collapsed/focused-away/flagged row and a
  transient focus force-reveal — and drives the live outline row with `suppressExpansionPersist` when it
  is on screen (tree mode, row resolved).
  This mirrors `workspace.focus` (persists `setFocusedWorkspace` in the arm) and `session.resize`
  (persists `applySplitRatio` in the arm, posts only to move the live divider).
  Idempotent.
  Its READ side is `ControlWorkspaceNode.collapsed` (`workspace.isExpanded ? nil : true` in the tree
  builder, mirroring the persisted `WorkspaceSnapshot.collapsed`): `true` when collapsed, omitted when
  expanded, so a script can record a workspace's open/closed state, restore it, or toggle by reading it first.
  `workspace.new` gains a `--collapsed` flag (`ControlArgs.collapsed`, threaded into `AppStore.addWorkspace(name:collapsed:)`
  → `Workspace(isExpanded: !collapsed)`): a runtime-added workspace with `isExpanded == false` renders
  collapsed (the reconcile's `formUnion(filter(\.isExpanded))` excludes it), so it can be built and filled
  with `session.new --no-select` without opening.
  Four-point keep-in-sync audit: (1) `case workspaceCollapse = "workspace.collapse"` + `case workspaceExpand = "workspace.expand"`
  + `ControlArgs.collapsed` + `ControlWorkspaceNode.collapsed` in `ControlProtocol.swift`,
  (2) the `.workspaceCollapse`/`.workspaceExpand` dispatch arms → `ControlActions.setWorkspaceExpansion`
  (+ `createWorkspace(…collapsed:)`) in `ControlServer+WorkspaceCommands.swift`, the app-side
  `AppActions.setWorkspaceExpanded(_:expanded:in:)` + `WorkspaceSidebar.Coordinator.setWorkspaceExpandedNotified`
  (+ the `.agtermSetWorkspaceExpanded` name + the two userInfo keys) + the `collapsed` population in
  `AppStore.controlTree`, (3) the `workspace collapse`/`workspace expand` subcommands + `workspace new --collapsed`
  in `agtermctlKit`, (4) round-trip + omit-when-nil + raw-string decode in `ControlProtocolTests`,
  dispatcher routing in `ControlDispatcherTests`, CLI mapping in `CommandsTests`,
  `AppStoreTests.controlTreeReportsCollapsedWorkspace` + `AppStoreOrganizationTests.newWorkspaceCollapsedStartsCollapsed`,
  and the e2e `testWorkspaceCollapseAndExpand` + `testWorkspaceNewCollapsedStaysClosedWhenFilled` in
  `ControlSidebarStatusUITests`.
  The workspace-command adapter arms (create/select/rename/delete/move/focus + this pair + the all-workspace
  `expandWorkspaces`/`collapseWorkspaces` helpers) live in `ControlServer+WorkspaceCommands.swift`, split
  out of `ControlServer+SessionActions.swift` (the `+WindowCommands.swift` family-split precedent) to keep
  that file under the 1000-line limit; they still satisfy the `ControlActions` conformance declared there.
  `tree` now also surfaces, on each `ControlSessionNode`, `foreground`/`splitForeground` — the LIVE foreground-process
  argv of the main + split panes (nil/omitted at the shell prompt), the SAME `ForegroundProcess.command(for:shellBasename:)`
  capture the restore-running-command feature uses (`ghostty_surface_foreground_pid` → `sysctl(KERN_PROCARGS2)`
  → host-free `CommandRestore`), populated in the tree builder per session so a script can read "what
  is each pane running".
  It ALSO surfaces `background` on each node — the `BackgroundWatermark` spec set via `session.background`
  (omitted when none), the read side of set/clear so a script can query the current watermark.
  It ALSO surfaces `overlaySizePercent` on each node — an OPEN overlay's size (`session.overlayActive ? session.overlaySizePercent : nil`
  in the tree builder): nil/omitted = the full-pane overlay OR no overlay (so gate on `overlay` first),
  else the floating panel's percent (1...100).
  It is the READ side of `session.overlay.resize` (which had only the write side), so a tmux-style zoom
  script can record the current size before switching to `--full` and restore the EXACT original on un-zoom
  (not a guessed default).
  It ALSO surfaces `splitRatio` on each node — the left-pane divider fraction of a session that HAS a split
  (`session.hasSplit ? session.splitRatio : nil` in the tree builder, so shown OR hidden splits report it),
  nil/omitted when there is no split or the ratio was never explicitly set (divider then at the default 0.5).
  It is the READ side of `session.resize` (whose applied ratio was echoed ONLY on the resize call's own
  `ControlResult.ratio`), so a script can record the current ratio before maximizing a pane and restore the
  exact divider even if the USER dragged it.
  It ALSO surfaces `splitFocused` on each node — which pane holds focus in a session that HAS a split
  (`session.hasSplit ? session.splitFocused : nil` in the tree builder, so shown OR hidden splits report it):
  `true` = the split (right) pane, `false` = the main (left) pane, nil/omitted when there is no split.
  It is the READ side of `session.focus` (write-only), so a script can record which pane was focused and
  restore it via `session.focus --pane left|right` (a `false` is emitted, distinct from the nil no-split
  case — the left pane being focused is real state).
  `tree` ALSO carries, at the TOP level (alongside `idleMs`/`autoFollowMs`), `sidebarVisible` — the read
  side of the write-only `sidebar` command (per-window sidebar visibility), populated LIVE from the
  projected window's store in `AppStore.controlTree`.
  The SAME field also rides each `ControlWindowNode` on `window.list` (read from `stores[id]?.sidebarVisible`,
  omitted for a closed window), so a script can enumerate every window's sidebar state.
  BUT `window.list` is served from the background-thread `cachedWindowNodes` cache
  (refreshed after every dispatched command + on frontmost change), and a GUI-only ⌃⌘S toggle is neither —
  so `AppStore.setSidebarVisible` posts `.agtermSidebarVisibilityChanged` (agtermCore) and `ControlServer`
  observes it to `refreshWindowCache`, keeping the cached `sidebarVisible` honest.
  A script that reads-then-acts (e.g. the tmux-style zoom that must restore the sidebar only if it was
  visible) should still prefer `tree`'s LIVE `sidebarVisible` over the cached `window.list` one — the tree
  is built on the main actor per request, so it can never lag.
  Each `ControlWindowNode` ALSO carries `geometry` — the open window's live on-screen frame
  (`ControlWindowFrame{x, y, width, height, display}`, omitted for a closed window with no NSWindow).
  It is the READ side of the write-only `window.move`/`window.resize` (which set the frame but nothing
  reported it), in the SAME coordinate system those accept: `x`/`y` are the top-left relative to `display`
  (y down), `width`/`height` the frame size, so a read-back round-trips straight back through
  `window.move`/`window.resize` (record → resize/move → restore the exact frame).
  Because the frame lives in AppKit (`WindowLibrary` is host-free), `controlWindowNodes` takes an app-side
  `geometry:` closure (default nil for tests) that `ControlServer.buildWindowList` fills from
  `WindowRegistry.geometry(for:)` — the exact inverse of `move`'s forward math.
  It rides the `cachedWindowNodes` cache (there is no LIVE tree copy — geometry is window-scoped, absent
  from the session tree), and since a user drag/resize/zoom/fullscreen changes it with NO control command
  AND a polling `window.list` is fast-path-served (so it never refreshes its own cache), `ControlServer`
  observes the NSWindow `didMove`/`didResize`/`didEnterFullScreen`/`didExitFullScreen` notifications and
  `refreshWindowCache`s on each (the fullscreen ones fire AFTER the async transition, so the settled
  `styleMask` is captured) — mirroring the `.agtermSidebarVisibilityChanged` refresh for the GUI-only
  sidebar toggle, so the read-back stays current.
  The notification is IGNORED, not captured — a non-Sendable `Notification` can't cross into the
  `MainActor.assumeIsolated` block under Swift 6 strict concurrency (the `sending 'note'` error), so the
  refresh fires for ANY window rather than filtering to an agterm one; harmless, since a non-agterm panel
  just rebuilds the same cheap agterm nodes.
  The host-free plumbing (the closure + node field) is unit-tested (`controlWindowNodesIncludeGeometryFromClosure`,
  the round-trips); the coordinate conversion + the NSWindow-notification cache refresh are app-side, build-verified.
  Each `ControlWindowNode` ALSO carries `fullscreen`/`zoomed` — the read side of the write-only
  `window.fullscreen`/`window.zoom` toggles (so a script can toggle idempotently), filled by a PARALLEL
  app-side `flags:` closure on `controlWindowNodes` (kept separate from `geometry:` so each stays a clean
  addition) that `buildWindowList` reads from `WindowRegistry.windowFlags(for:)`
  (`styleMask.contains(.fullScreen)` / `NSWindow.isZoomed`); both nil/omitted for a closed window, on the
  cache like `geometry`. The closure plumbing is unit-tested (`controlWindowNodesIncludeFullscreenZoomFromClosure`
  + the round-trips); the NSWindow reads are app-side, build-verified.
  `restore.clear` clears every open session's saved CAPTURED foreground command (`Session.foregroundCommand`/`splitForegroundCommand`)
  and persists via `library.saveAllOpen()`, so the next restart restores plain shells for those panes instead
  of re-running the captured commands (also closing the force-quit re-fire: the restored command is consumed
  in memory but its on-disk copy lingers until the next save, which a force-quit skips).
  It does NOT clear a `session.new --command` session's own `initialCommand` (the durable creation identity),
  which still re-runs on restore when the setting is on — `restore.clear` is scoped to captured foreground
  commands only.
  App-global like `keymap.reload` (clears all open windows, no `--window`).
  Four-point keep-in-sync audit for `restore.clear`: (1) `case restoreClear = "restore.clear"` in `ControlProtocol.swift`
  (no target/args; `foreground`/`splitForeground` added to `ControlSessionNode`),
  (2) the `.restoreClear` dispatcher arm → the app-side `ControlActions.clearRestoreCommands` + the foreground population
  in the tree builder, (3) the `restore clear` subcommand (`Restore`) in `agtermctlKit`,
  (4) round-trip (`restoreClearRoundTrips` + `treeSessionNodeRoundTripsWithForeground`/`…OmitsForegroundWhenNil`)
  in `ControlProtocolTests` + the e2e (`testTreeExposesForegroundProcess`,
  `testRestoreClearSucceeds`) in `ControlAPIUITests`.
  `session.restore` (target = session) is the PER-SESSION, per-pane restore-command OVERRIDE — distinct
  from the app-global `restore.clear`, which touches only the captured foreground.
  It pins persisted state that WINS over the captured foreground at the next restore, and is the fix for
  NON-IDEMPOTENT commands: `claude --resume <id> --fork-session` mints a NEW session on every restart, so
  restoring it verbatim never reattaches the session the user was in (discussion #264).
  Tri-state on a single `String?` per pane — `nil` = auto-capture (today's behavior), `""` = pinned to
  nothing (a plain shell, suppressing both the capture and `initialCommand`), a command = run that shell
  line — mapped from the wire `mode` `set`/`none`/`clear` via `ControlRestoreOverride`
  (`pin(String)`/`pinNone`/`unpin`; `pinNone` is NOT spelled `none` to avoid the `Optional<T>.none` compiler
  warning at the dispatcher's parse step).
  It is SET now and CONSUMED on the next launch — writing it never touches the running session — and it is
  STICKY: the override persists across restores and fires again on every restart until cleared, because a
  `SessionStart` hook rewrites it to the live child id on every start.
  This is the load-bearing safety property, split across two slots on `Session`: the PERSISTED
  `restoreCommand`/`splitRestoreCommand` (its own slot, never the capture's — sharing `foregroundCommand`
  would let the quit-time capture of the live `--fork-session` process clobber it) and the TRANSIENT
  `pendingRestoreCommand`/`pendingSplitRestoreCommand`.
  The surface factories read ONLY the pending slots (via `Session.takePendingRestoreOverride(pane:)`,
  take-and-nil so a second split this launch is a plain shell); `setSessionRestore` writes ONLY the
  persisted slots; and ONLY an app-bootstrap restore copies persisted → pending.
  An implementation where the factory falls back to the persisted field reintroduces every re-fire hazard
  (a socket write between `session.new` and the SwiftUI factory run would execute immediately).
  Precedence lives in host-free `CommandRestore`: `restorePlan(_ inputs: RestoreInputs)` (an options struct,
  since a 6th parameter fails `make lint --strict`) short-circuits on a present override — `command` is
  always nil (never the exec path), `initialInput` comes from
  `restoreInput(restoreEnabled:restoreOverride:capturedInput:)` — and reproduces today's logic byte-for-byte
  when the override is nil.
  It obeys the `restoreRunningCommand` setting (like `initialCommand`, so the toggle stays the single master
  switch) but BYPASSES the denylist: `restore-denylist.conf` is a basename heuristic for BLIND capture,
  while an override names its command deliberately, so it wins — the bypass is structural (the override
  never routes through the app-side `restoreInitialInput` denylist gate).
  The value is typed VERBATIM (never `shellQuotedLine`), so `cd x && claude --resume y` works as written; it
  is arbitrary shell code that persists in `windows/<id>.json` and reads back via `tree`, so the docs say
  plainly it may enter shell history and must not carry secrets (no privilege boundary — a same-UID client
  can already inject keystrokes via `session.type` — but a buggy writer's mistake becomes durable).
  Wire args reuse `ControlArgs.command` + `mode` + `pane` + `paneID` (no new wire args).
  Dispatcher rejections (host-free, unit-tested): unknown or missing `mode` →
  `invalid restore mode: <x> (set|none|clear)`; `set` with
  no `command` → `session.restore set requires a command` (an EMPTY command is accepted, and is the same
  pinned-to-nothing state as `none`); a `command` with control characters (tab included) →
  `command must not contain control characters`; a `command` over `ControlRestoreOverride.maxCommandBytes` (1024 UTF-8
  bytes via `command.utf8.count`) → `command too long (max 1024 bytes)`; a bad `pane` → the shared
  `--pane must be left, right, or scratch`.
  Shell metacharacters are deliberately NOT rejected — verbatim shell syntax is the point.
  The app-side `setSessionRestore` (`ControlServer+SessionActions.swift`) resolves the session, then the
  pane: `paneID` → `session.paneRole(forToken:)` first, else the baked `pane`, as `setSessionStatus` does —
  with ONE deliberate divergence: an unresolvable `--pane-id` supplied WITHOUT an explicit `--pane` is an
  ERROR (`unknown pane id: <token>`), not a silent `.left` fallback, because a silent default here would
  overwrite the MAIN pane's persisted command when a hook meant the split (an EMPTY token counts as absent).
  A `.scratch` pane (`the scratch terminal is never restored`) and a `.right` on a split-less session
  (`session has no split`) are rejected; otherwise it calls `store.setRestoreCommand(value, pane:forSession:)`
  (`AppStore+Restore.swift`), which persists immediately — the override must survive a SIGKILL
  or a hook's write is lost — and does NOT touch the pending slots.
  That write is the ONE store mutation whose failure is REPORTED rather than swallowed: `setRestoreCommand`
  saves through the internal `AppStore.saveChecked()` (`save()` with the `Bool` kept, so the two can't drift),
  ROLLS the in-memory field back to its previous value when the write throws, and returns whether the
  requested value reached disk; the arm answers `failed to save the restore override, the previous value is
  still in effect` when it did not.
  The payload is what makes this different from `setFlag` and the rest of the swallow-and-log store: an
  arbitrary shell line re-typed on every launch, so acking a `clear` that never landed would leave the old
  command firing forever — and without the rollback the unchanged-value guard would swallow the retry as a
  no-op success.
  A successful `set` while `restoreRunningCommand` is OFF returns `ok` with a note in `result.text` so
  a hook author sees why nothing will fire; `none`/`clear` carry no note, since their outcome (a plain shell
  / back to auto-capture) is delivered regardless of the setting.
  The `--pane` selector for both `session.status` and `session.restore` is parsed by the shared
  `ControlDispatcher.parsePane`, so the rejection string cannot drift between them.
  Pane lifecycle: `closePrimaryPane` migrates BOTH the persisted and pending right-pane values into the main
  slots (mirroring the `foregroundCommand` migration); `closeSplit` clears both split slots; all three
  soft-close entry points (`softCloseSession`/`softCloseSessions`/`softRemoveWorkspace`) clear the pending
  slots via `clearPendingRestoreOverrides(of:)` before retaining the objects for undo; `session.duplicate`
  copies neither.
  Bootstrap seeding is gated by a `launchRestore` flag threaded through
  `WindowLibrary.loadStore(for:launchRestore:)` → `AppStore.restore(from:launchRestore:)` →
  `session(from:launchRestore:)`, passed `true` from ONLY the three `WindowLibrary` bootstrap sites (reopen,
  its frontmost fallback, orphan recovery) so a mid-process window reload (`ContentView.resolveStore`) and
  Reopen Closed Item arm nothing; and `pendingSplitRestoreCommand` is seeded only when
  `snapshot.isSplit == true` (a hidden split has no right surface at bootstrap, so a pending payload would
  fire on a later manual ⌘D — the same case the quit capture already dodges).
  A hidden split's PERSISTED pin is DROPPED by the same rebuild rather than kept: the split is not restored
  at all (`hasSplit` follows `isSplit`), so the pin describes a pane that no longer exists — keeping it
  would leave a value `tree` reports but no write can clear (`--pane right` is rejected without a split) and
  would re-arm into an unrelated fresh ⌘D split at the next quit.
  This is the `closeSplit` rule (pane gone → drop the pin) applied to the restore path.
  READ-BACK: `ControlSessionNode.restoreCommand`/`splitRestoreCommand`, populated in the tree builder from
  the PERSISTED fields (never the pending slots), so a read after the override fired still reports what is
  pinned; the tri-state survives JSON since `encodeIfPresent` omits `nil` while `""` emits an empty string.
  Four-point keep-in-sync audit for `session.restore`: (1) `case sessionRestore = "session.restore"` +
  `ControlRestoreOverride`/`ControlSessionRestoreUpdate` in `ControlProtocol.swift`/`ControlModes.swift`
  (reusing `command`/`mode`/`pane`/`paneID`) + `restoreCommand`/`splitRestoreCommand` on `ControlSessionNode`
  + the `Session`/`SessionSnapshot` persisted fields + `CommandRestore.RestoreInputs`/`restoreInput`,
  (2) the `.sessionRestore` dispatcher arm (parse + validate + response shape) → the app-side
  `ControlActions.setSessionRestore` (session/pane resolution + `AppStore.setRestoreCommand` + the off-setting
  note) + the `controlTree` population, (3) the `session restore` subcommand (`Restore`, `validate()`-guarded
  exactly-one-form) in `agtermctlKit/SessionCommands.swift`, (4) round-trip in `ControlProtocolTests` +
  dispatcher happy/rejection/byte-cap paths in `ControlDispatcherTests` + `CommandRestoreTests` (precedence)
  + `AppStoreRestoreTests`/`AppStoreRestoreSeedTests`/`AppStorePaneTests` (set/seed/lifecycle) +
  `SessionTests` (`takePendingRestoreOverride` + stickiness) + `SnapshotRoundTripTests` + `CommandsTests`
  (CLI mapping/validation) + the e2e in `RestoreCommandUITests` (incl. the two-relaunch stickiness and
  force-quit persistence cases) and the `tree` read-back/error cases in `ControlAPIUITests`.
  `session.background` (target = session) sets or clears a per-session background composited behind the
  terminal grid — `args.mode` is `image`/`text`/`color`/`clear`.
  `image`/`text` are watermarks driven by libghostty `background-image*` keys:
  `image` needs `args.path` (PNG/JPEG, validated for format + existence + no control chars in the path),
  `text` needs `args.text` (capped at 256 chars; + optional `args.color` #rrggbb, default the terminal
  foreground), and both accept `args.opacity` (0...1)/`args.fit`/`args.position`/`args.repeats`.
  `color` is a SOLID terminal background color driven by the `background` key: it needs `args.color` (#rrggbb)
  and takes NO per-call opacity — it is drawn at the Settings WINDOW translucency (solid when off),
  emitted as `background-opacity = <windowOpacity>` at apply time so the color honors the user's opacity/blur
  instead of forcing itself opaque (unlike the image/text watermark, which pins `background-opacity = 1`
  so the image shows).
  opacity/color/fit/position validated against the shared host-free `WatermarkConfig`,
  used by BOTH the CLI `validate()` and the server.
  The `BackgroundWatermark` spec (host-free, `Codable`) is persisted in `SessionSnapshot` (survives restart)
  via `AppStore.setBackgroundWatermark`, then applied to the session main + split + scratch surfaces as a PER-SURFACE
  ghostty config overlay: `GhosttyApp.configWithOverlay` builds the same base files + an overlay file
  (`WatermarkConfig.overlayText`: for image/text the `background-image*` lines + `background-opacity = 1`
  so the image shows even under window translucency, which pins the global `background-opacity` to 0;
  for `color` a `background = <hex>` line + `background-opacity = <windowOpacity>` (passed in from
  `GhosttyApp.shared.windowOpacity`) so the color honors translucency instead of forcing itself opaque;
  plus a `font-size` line so the per-session cmd-+/- zoom is not reset by the push), and `GhosttySurfaceView.applyWatermarkFromSession`
  calls `ghostty_surface_update_config`, RETAINING each per-surface config in `ownedConfigs` and freeing
  it only on surface teardown (safe — the consumer is gone — unlike the never-freed app-wide config).
  libghostty auto-fits the image to the surface and RE-FITS on resize (no app-side resize code);
  a `.text` watermark rasterizes to a PNG under `<stateDir>/watermarks/<sessionID>.png` via the app-side
  `WatermarkRenderer` (AppKit; default tint = the live terminal foreground), regenerated on restore +
  cleared on `clear`, on `text`→`image` switch, and on permanent session/workspace/window removal.
  A global `config.reload`/settings change broadcasts the SHARED config (no image) to every surface via
  `applyConfig`, WIPING any watermark — so `GhosttyApp.reloadConfig` re-resolves the theme colors and
  then calls `reapplyWatermarkIfNeeded` on each surface AFTER the broadcast to re-assert it (the theme
  colors first, so a default-tinted `.text` watermark re-renders with the new foreground, not the old).
  A `.color` background bakes the window opacity into its `background-opacity` at apply time, so it must
  RE-TRACK the Settings translucency slider: `SettingsModel.apply` re-asserts every `.color` surface
  (`GhosttySurfaceView.reapplyColorBackgroundIfNeeded`, guarded to `.color` so image/text aren't rebuilt
  per tick) right AFTER `applyWindowTranslucency` updates `GhosttyApp.windowOpacity`, on any opacity
  change — the `reloadConfig` re-assert alone reads a STALE opacity (it runs before the update) and a
  within-range drag doesn't reload at all, so neither path alone keeps a color session tracking the slider.
  `BackgroundWatermark.fit`/`position` are typed `Fit`/`Position` `CaseIterable` enums (like `Kind`), not
  raw `String` — the raw values match ghostty's keys so they serialize identically, and a bad value can't
  reach a config line (`imagePath`/`colorHex` stay free text, re-validated on emit by `overlayText`, closing
  the restore-path injection as defense-in-depth). The spec is READ back on each `tree` node's `background` field.
  Four-point keep-in-sync audit for `session.background`: (1) `case sessionBackground = "session.background"`
  + `ControlArgs.path`/`color`/`opacity`/`fit`/`position`/`repeats` in `ControlProtocol.swift` (+ `background`
  on `ControlSessionNode` for the read-back),
  (2) the `.sessionBackground` dispatcher arm — `ControlDispatcher.dispatchSessionBackground` validates + builds the spec,
  the app-side `setSessionBackground` does the filesystem checks (`isSupportedImage`/`fileExists`) + `applyWatermark`
  to the realized surfaces (+ `background:` populated in the tree builder), (3) the
  `session background image|text|color|clear` subcommands in `agtermctlKit` (shared opacity/color/fit/position
  `validate()`; `color` takes color only, no opacity), (4) round-trip in `ControlProtocolTests` (incl.
  `treeSessionNodeRoundTripsWithBackground` + `backgroundWatermarkColorKindSerializes`)
  + `WatermarkConfigTests` (incl. the `color*` overlay cases) + `WatermarkStorageTests` + `CommandsTests`
  (CLI parse + bad-arg rejection) + the e2e `testSessionBackgroundSetClearAndValidation` in `ControlAPIUITests`
  (image/text/color set/clear + tree read-back).
  **Agent-skill mirror (HARD keep-in-sync, 4th surface):** all commands are documented in the bundled
  `agterm/Resources/agent-skill/` (SKILL.md summary, reference.md detail,
  examples.md recipes) and the command count there is bumped to 64 to match.
  **Website mirror (HARD keep-in-sync):** the site's per-command reference `site/commands.html` documents
  EVERY `agtermctl` control command — one inline-styled card per command carrying its invocation, its
  arguments, and the `tree` read-back field, grouped into its command family's section.
  A new `Command` case REQUIRES a new `site/commands.html` entry (a changed command an updated one, a
  removed command a deleted one), in lockstep with the agent skill above and `README.md`/`site/docs.html`;
  the page's "64 commands" copy must track the catalog count.
  It drifted once because the site keep-in-sync convention named only `docs.html`/`index.html`, so
  `dashboard` and `surface.zoom` shipped undocumented here.
