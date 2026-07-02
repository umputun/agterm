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
  The hooks scripts bundle at `agterm/Resources/agent-status/` (`agterm-agent-status.sh` wrapper + `shell/integration.sh`
  + `codex-notify.sh`, a `project.yml` Contents/Resources folder mirroring `Resources/ghostty`).
  The installer copies them to `~/.config/agterm/agent-status/`, bakes the bundled `agtermctl`'s absolute
  path (`Bundle.main.url(forAuxiliaryExecutable:)`) into the wrapper so the hooks fire even without the
  CLI on PATH, appends a marker-guarded `source` line to `~/.zshrc` + `~/.bashrc`,
  merges four Claude Code hooks into `~/.claude/settings.json` with a `.bak` (UserPromptSubmit→`active --blink`,
  PostToolUse→`active --blink`, Stop→`completed --auto-reset`, Notification[`permission_prompt`]→`blocked`;
  the unmatched PostToolUse re-asserts `active` after every tool so a `blocked` permission prompt clears
  back to active when work resumes — Claude Code has no "permission answered" event,
  and the gated tool's own PreToolUse fires BEFORE `blocked` is set, so the approved tool's PostToolUse
  is the first hook afterwards), and PRINTS the Codex `~/.codex/config.toml` `notify` line (never auto-edits
  TOML).
  Idempotent + re-runnable (re-run refreshes the baked path).
  Like the CLI installer, the host-free JSON-merge / shell-rc-marker / backup-path logic is `agtermCore.AgentHooksInstall`
  (unit-tested); `AgentHooksInstaller` (app-side) owns the AppKit FS glue,
  manually verified.
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
  authored at `agterm/Resources/agent-skill/` (`SKILL.md` overview + model + addressing + 50-command
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
- **Addressing.**
  UUID is canonical, with sugar: `active` (the selected session / current workspace),
  exact `uuidString` (case-insensitive), or a git-style unique prefix.
  Zero prefix hits → `notFound` error, ≥2 → `ambiguous` error listing the candidates.
  `--target` defaults to `active`, so scripts rarely type an id and never for "the current one".
- **Command catalog (50 commands):**
  - `tree`
  - `workspace.new`/`workspace.rename`/`workspace.delete`/`workspace.select`/`workspace.move`/`workspace.focus`
  - `session.new`/`session.close`/`session.select`/`session.rename`/`session.move`/`session.type`/`session.split`/`session.scratch`/`session.focus`/`session.resize`/`session.go`/`session.copy`/`session.text`/`session.search`/`session.status`/`session.flag`/`session.background`/`session.overlay.open`/`session.overlay.close`/`session.overlay.result`
  - `quick`
  - `sidebar`/`sidebar.mode`/`sidebar.expand`/`sidebar.collapse`
  - `notify`
  - `font.inc`/`font.dec`/`font.reset`
  - `window.new`/`window.list`/`window.select`/`window.close`/`window.rename`/`window.delete`/`window.resize`/`window.move`/`window.zoom` (see the Windows section)
  - `keymap.reload` (see the Keymap section)
  - `config.reload` (see the Settings section)
  - `theme.set`/`theme.list` (see the Theme picker section)
  - `restore.clear` (see the Settings section)

  `workspace.delete` honors keep-at-least-one and returns an error instead of the GUI confirm alert (nothing
  blocks on a modal).
  `session.move` is MODE-BEARING: `args.to` (`up`|`down`|`top`|`bottom`) REORDERS the session within
  its own workspace (parses `ReorderDirection`, drives `AppStore.reorderSession` → the existing `moveSession(at:)`
  primitive, returns the session id), while `args.workspace` RELOCATES it to another workspace (unchanged
  — still appends at the end); both-set and neither-set are errors, and an invalid direction is an error.
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
  Full-overlay rendering only (never floating) so it's a structural clone of the proven `if fullOverlay`
  ZStack sibling at `.zIndex(1)`, BELOW the ephemeral overlay (`.zIndex(2)` — a normal overlay launched
  over the scratch sits on top); the panes' opacity/hit-testing gate is `hideForOverlay = fullOverlay || scratchActive`
  (still false for a FLOATING overlay, preserving the NSSplitView-overrun invariant).
  GUI half: ⌘J (`BuiltinAction.toggleScratch`), title-bar `scratch-toggle` button,
  View ▸ Show/Hide Scratch, the ⌃⇧P palette "Toggle Scratch" — all through `AppActions.toggleScratch()`.
  The scratch surface is NOT wired to the session (no `view.session`, like the overlay) so its PWD/title
  never clobber the sidebar name; `autoFocus` grabs first responder on show,
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
  stops at the ends on next/prev (no wrap), jumps to the ends for first/last,
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
  `args.command` runs that command AS the session's process instead of the login shell (like kitty's
  `launch <cmd>` / ghostty's `command`) — NO echoed command line, and the session closes when the command
  exits (the normal single-pane `onExit` → `closePrimaryPane`).
  `Session.initialCommand` is `@ObservationIgnored` but PERSISTED via `SessionSnapshot.initialCommand`, so it
  re-runs on restore (through the same `config.command` exec path) when the **restore-running-command** opt-in
  is on — gated via the transient `Session.wasRestored` so a fresh session always runs its command while a
  restored one honors the toggle (default off → a restored session is a plain shell); a live captured
  foreground preempts it, and `closePrimaryPane` clears it when a command pane exits into a promoted split.
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
  Keep-in-sync: the `.sessionNew` case carries `ControlArgs.command` plus `ControlArgs.name` (custom
  name) and `ControlArgs.workspaceName` + `ControlArgs.createWorkspace` (name-addressing + ensure);
  the arm pre-validates the mutual-exclusion / create-needs-name rules and shares `makeSessionResponse`
  across the id- and name-addressed paths; the `session new` CLI carries `--command`/`--name`/`--workspace-name`/`--create-workspace`
  (the last two also `validate()`-guarded); and round-trip + e2e (`testSessionNewWithCommandRunsAsProcess`,
  `testSessionNewWithName`, `testSessionNewWorkspaceNameCreatesThenReuses`) cover them.
  `session.type` injects into the target surface.
  Every session is realized eagerly (the deck mounts all at startup), so any session is normally typable
  WITHOUT `select`; `select:true` remains for the brief window before a just-created session is mounted
  (select, then a bounded poll, the `focusSplitPane` idiom), with `session not realized` the fallback
  if the surface still isn't up.
  `GhosttySurfaceView.inject(text:)` types via `ghostty_surface_key` keystrokes (printable runs as key-with-`text`,
  each `\n`/`\r`/`\r\n` as a Return keypress, keycode 36) — NOT `ghostty_surface_text`,
  whose bracketed-paste wrapping suppresses Enter and leaks `\e[200~`/`\e[201~` markers when fired rapidly.
  Do not "simplify" it back to `ghostty_surface_text`.
  `session.copy` reads the target surface's selection via `GhosttySurfaceView.readSelection()` (`ghostty_surface_has_selection`
  + `ghostty_surface_read_selection`, freed with `ghostty_surface_free_text`) and returns it in `result.text`
  — it does NOT touch the system clipboard (automation pipes the returned text into another `session.type`);
  selection is surface state independent of focus, so any realized session can be read,
  and no/empty selection is a `no selection` error.
  `session.text` reads the target surface's screen buffer as PLAIN TEXT (no ANSI) via `GhosttySurfaceView.readScreenText(all:lines:)`
  (a `ghostty_selection_s` spanning VIEWPORT top-left→bottom-right by default,
  SCREEN when `args.all || args.lines != nil`, `rectangle = false`;
  `ghostty_surface_read_text` → copy out of `ghostty_text_s` → `ghostty_surface_free_text`) and returns it in `result.text`
  — `args.all` adds scrollback, `args.lines N` keeps the last N CONTENT lines (trailing blank grid rows
  trimmed so a non-scrolled screen returns content, not padding), and `args.pane` (`left`→main,
  `right`→split-else-`session has no split` error, omitted→the ON-SCREEN surface via the shared
  `Session.onScreenSurface` (scratch-when-covering else the focused pane, the SAME resolution `session.search`
  uses), so a no-`pane` read returns what's visible, not a pane hidden under the scratch) picks the pane.
  `args.all`+`args.lines` are mutually exclusive and `args.lines` must be > 0 — validated SERVER-SIDE in
  `readText` (mirroring the CLI `validate()`), NOT only CLI-side, so a raw socket client can't bypass it
  (an unchecked `lines ≤ 0` would otherwise fall through to the full buffer).
  UNLIKE `session.focus`, the `pane` here is `left|right` ONLY (no `other`).
  A genuinely BLANK screen reads `ok` with an empty string (NOT an error, on purpose — differs from `session.copy`'s
  `no selection`), but a FAILED `ghostty_surface_read_text` is a `failed to read surface buffer` error:
  `readScreenText` returns `""` for the empty read and nil ONLY for a real failure, which `readText` maps
  to the error (so a caller can tell a blank terminal from a broken read).
  Plain text only — the pinned libghostty exposes only `ghostty_surface_read_text` (no per-cell SGR),
  so `--ansi` is out of scope until a styled surface read lands upstream and the pin is bumped.
  Four-point keep-in-sync audit for `session.text`: (1) `case sessionText = "session.text"` + new `ControlArgs.all: Bool?`/`lines: Int?`
  (reuses `pane` + `ControlResult.text`) in `ControlProtocol.swift`, (2) the `.sessionText` dispatch arm (`readText`)
  in `ControlServer`, (3) the `session text [--all] [--lines N] [--pane left|right]` subcommand in `agtermctlKit`
  (`validate()` guards the flag combos, re-enforced SERVER-SIDE in `readText`), (4) round-trip tests in
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
  The two variants render in DIFFERENT places.
  The FULL overlay is an in-deck ZStack sibling in `WindowContentView.sessionDetail` (`.zIndex(1)` above the
  pane(s), gated on `fullOverlay`): it draws translucent + blurred (NO opaque backing) with the pane(s)
  behind hidden at `.opacity(0)` + `.allowsHitTesting(false)` (kept MOUNTED,
  shells alive like the deck's inactive sessions), so its transparency reveals the window backing (desktop,
  tint + blur), not the session.
  The FLOATING overlay (`overlaySizePercent` set) is rendered OUTSIDE `sessionDetail` — as `.overlay { floatingOverlayLayer }`
  on `detailPane` — so `sessionDetail` for the floating case adds NO sibling to its ZStack:
  just the pane(s) at opacity 1, the same SHAPE as no-overlay (which is what keeps the NSSplitView from
  moving).
  Hit-testing stays gated on `.allowsHitTesting(!fullOverlay)` and must NOT flip when a floating overlay
  opens: changing the panes' OWN `allowsHitTesting` on overlay-open (e.g. to `!session.overlayActive`)
  ALSO triggers the NSSplitView titlebar-overrun — the SAME class of perturbation as adding a sibling,
  even though it looks like a pure interaction change (Codex insisted hit-testing was layout-inert;
  a review-loop regression proved otherwise).
  So the floating panes stay hit-testable, and the overlay's focus is protected OUTSIDE `sessionDetail`:
  a transparent `Color.clear.contentShape(Rectangle())` catcher in `floatingOverlayLayer` (on `detailPane`)
  absorbs clicks AROUND the panel so they can't reach the panes and steal the overlay program's first
  responder.
  (Generalize the rule: ANYTHING in `sessionDetail`'s HSplitView-hosting subtree that CHANGES when `overlayActive`
  flips — a sibling, a flattened ZStack, or a toggled pane modifier — overruns the split into the titlebar;
  keep that subtree identical for the floating case and do everything else at the `detailPane` level.)
  This separation is load-bearing: adding a conditional sibling INSIDE `sessionDetail`'s ZStack (the
  HSplitView-hosting subtree) made SwiftUI re-host it and the AppKit `NSSplitView` overrun UP into the
  transparent titlebar, painting the split over the header (Codex-confirmed;
  the quick terminal renders at this level for the same reason and never hit it).
  Anchoring on `detailPane` also means `floatingOverlayLayer`'s `GeometryReader` reports the terminal
  area EXACTLY — no manual sidebar/titlebar insets (computing those at the window level mis-centered
  the panel one line low) — so it sizes the opaque framed panel (`terminalColor` backing + hairline frame
  + shadow, quick-terminal styling) to `sizePercent`% and centers it in the detail area,
  the pane(s) visible around it.
  Only the active session's floating overlay shows, so `ControlServer` SELECTS the target when a floating
  overlay (`sizePercent` set) opens — its surface only mounts for the active session,
  so without the select a non-active target's program would never run and a `--block` open would poll
  forever (the full overlay needs no select; it mounts in the eager deck regardless).
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
  The overlay is rendered only for the *active* session, so the caller selects the session first.
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
  Mode-bearing commands (`session.split`/`quick`) compute the delta against current state so `on`/`off`/`show`/`hide`
  are idempotent, and an unknown mode is an error.
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
  Setting a non-idle status is control-driven (the hooks/agents call it;
  no GUI sets active/completed/blocked), but clearing to idle ALSO has a GUI — the **Clear Status** action
  (see the Agent-status glyph note) — so the idle case is keep-in-sync covered by `session.status idle`.
  Cross-window via the shared `resolveSession` (the install's Stop hook targets its own `$AGTERM_SESSION_ID`,
  which may live in a non-frontmost window).
  The arm (`setSessionStatus`) builds an `AgentIndicator{status, blink, autoReset}` (host-free,
  ephemeral — never in `SessionSnapshot`) and drives the single `AppStore.setAgentIndicator(_:forSession:)`
  mutation point (unknown id = clean no-op), returning the id.
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
  (2) the `.sidebar` dispatch arm (`setSidebar`) in `ControlServer`, (3) the `sidebar` subcommand in
  `agtermctlKit`, (4) round-trip in `ControlProtocolTests` + the e2e `testSidebarShowHideToggle` (sidebar
  hide removes the `session-row`s from the AX tree) in `ControlSidebarStatusUITests`.
  `theme.set` sets + persists a theme by name (`args.name`; nil/empty = ghostty's built-in / "default
  ghostty", NOT the seeded `agterm` app default — see the Theme picker section) — the control half of
  the Settings picker / the `.themes` palette commit, the SAME `SettingsModel.setTheme` persist+apply
  path (NO live preview over the socket — preview is interactive-only).
  An unknown name (not in `SettingsCatalog.themeNames()`) is an `unknown theme: X` error (a typo silently
  doing nothing is worse than a fail); the applied name echoes in `result.theme` (nil = ghostty built-in).
  `theme.list` returns `result.themes` = the bundled names + `result.theme` = the current one (nil =
  ghostty built-in; absent on a fresh install means the seeded `agterm` is current);
  `agtermctl theme list` prints one name per line with a leading "default ghostty" row,
  the current marked `* `, and `theme.set` prints `ok` (non-create mutation).
  App-global like `keymap.reload` (one `SettingsModel`), so NO `--window` selector.
  Four-point keep-in-sync audit: (1) `case themeSet = "theme.set"` + `case themeList = "theme.list"`
  in `ControlProtocol.swift` (reuse `ControlArgs.name`; add `ControlResult.theme`/`themes`),
  (2) the `.themeSet` (`setTheme`, with name validation) + `.themeList` dispatch arms in `ControlServer`,
  (3) the `theme set [name]` / `theme list` subcommands in `agtermctlKit` (+ `SocketClient.formatThemes`),
  (4) round-trip in `ControlProtocolTests` + the e2e `testThemeListAndSet` in `ControlAPIUITests`.
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
  arm (`flagSession`) in `ControlServer`, (3) the `session flag on|off|toggle|clear` subcommand (`FlagCommand`)
  in `agtermctlKit`, (4) round-trip in `ControlProtocolTests` + the e2e `testSessionFlagAndSidebarModeFlagged`
  in `ControlSidebarStatusUITests`.
  `sidebar.mode` (frontmost window) flips the sidebar VIEW between the workspace tree and the flat flagged
  working-set list — `args.mode` is `tree`|`flagged`|`toggle` (delta-computed against `AppStore.sidebarMode`
  so it's idempotent, unknown mode = error), drives `setSidebarViewMode` → `AppStore.setSidebarMode`.
  It is the control half of the bottom-bar `flagged-view-toggle` + the View-menu Show Flagged/Show All
  + `BuiltinAction.toggleFlaggedView`; the existing `sidebar [show|hide|toggle]` is now the default `sidebar visibility`
  subcommand alongside `sidebar mode`.
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
  (2) the `.sidebarExpand`/`.sidebarCollapse` dispatch arms (`expandWorkspaces(window:)`/`collapseWorkspaces(window:)`)
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
  Four-point keep-in-sync audit: (1) `case workspaceFocus = "workspace.focus"` in `ControlProtocol.swift`
  (reuses `ControlArgs.mode`), (2) the `.workspaceFocus` dispatch arm (`focusWorkspace`) in `ControlServer`,
  (3) the `workspace focus on|off|toggle` subcommand (`Focus`) in `agtermctlKit`,
  (4) round-trip in `ControlProtocolTests` + the e2e `testWorkspaceFocusHidesOtherWorkspaces` in `ControlSidebarStatusUITests`
  plus the `FocusWorkspaceUITests` XCUITest.
  `tree` now also surfaces, on each `ControlSessionNode`, `foreground`/`splitForeground` — the LIVE foreground-process
  argv of the main + split panes (nil/omitted at the shell prompt), the SAME `ForegroundProcess.command(for:shellBasename:)`
  capture the restore-running-command feature uses (`ghostty_surface_foreground_pid` → `sysctl(KERN_PROCARGS2)`
  → host-free `CommandRestore`), populated in the tree builder per session so a script can read "what
  is each pane running".
  It ALSO surfaces `background` on each node — the `BackgroundWatermark` spec set via `session.background`
  (omitted when none), the read side of set/clear so a script can query the current watermark.
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
  (2) the `.restoreClear` dispatch arm (`clearSavedCommands`) in `ControlServer` + the foreground population
  in the tree builder, (3) the `restore clear` subcommand (`Restore`) in `agtermctlKit`,
  (4) round-trip (`restoreClearRoundTrips` + `treeSessionNodeRoundTripsWithForeground`/`…OmitsForegroundWhenNil`)
  in `ControlProtocolTests` + the e2e (`testTreeExposesForegroundProcess`,
  `testRestoreClearSucceeds`) in `ControlAPIUITests`.
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
  via `AppStore.setBackgroundWatermark`, then applied to the session main + split surfaces as a PER-SURFACE
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
  (2) the `.sessionBackground` dispatch arm (`setBackground`, validating + building the spec, then `applyWatermark`
  to the realized surfaces) in `ControlServer` (+ `background:` populated in the tree builder), (3) the
  `session background image|text|color|clear` subcommands in `agtermctlKit` (shared opacity/color/fit/position
  `validate()`; `color` takes color only, no opacity), (4) round-trip in `ControlProtocolTests` (incl.
  `treeSessionNodeRoundTripsWithBackground` + `backgroundWatermarkColorKindSerializes`)
  + `WatermarkConfigTests` (incl. the `color*` overlay cases) + `WatermarkStorageTests` + `CommandsTests`
  (CLI parse + bad-arg rejection) + the e2e `testSessionBackgroundSetClearAndValidation` in `ControlAPIUITests`
  (image/text/color set/clear + tree read-back).
  **Agent-skill mirror (HARD keep-in-sync, 4th surface):** all commands are documented in the bundled
  `agterm/Resources/agent-skill/` (SKILL.md summary, reference.md detail,
  examples.md recipes) and the command count there is bumped to 50 to match.

