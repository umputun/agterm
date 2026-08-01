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
  - "plugins/agterm/skills/agterm/**"
---

## Control API

- `agtermctl` drives app/store actions over a local Unix socket. One-shot commands and polled
  `events.read` are in scope; terminal-output streaming is not.
- `agtermCore` owns protocol types, target/socket resolution, and host-free dispatch.
  `ControlServer` owns the socket and app-side effects; blocking accept/read runs off-main and requests
  hop to the main actor. SwiftPM `agtermctlKit` owns ArgumentParser and `SocketClient`.
- New commands are dispatcher-first (#78). `ControlDispatcher` owns parsing, validation, error text, and
  response shape; `ControlActions` supplies resolution and effects. Nil falls through only for unmigrated
  commands. Never add validation to the fallback switch.
- Every change needs protocol/round-trip types, dispatcher and app action, CLI, and dispatcher/CLI/e2e
  tests. State writes also need tree/window read-back, nil omission tests, and population coverage.

## Installation and agent integrations

- Xcode's CLI phase builds Release, copies/signs `agtermctl`, then deep re-signs the app; shallow signing
  fails with `agterm.debug.dylib`. The Help installer links into `/usr/local/bin`, directly or through one
  admin prompt. Host-free `CLIInstall` owns paths/quoting; app code owns filesystem/auth.
- Agent Hooks installation copies generic, Claude, Codex, Pi, OpenCode, and shell assets under
  `~/.config/agterm/agent-status`, baking the bundled CLI. Marker merges are idempotent and preserve
  unrelated config; unreadable config is never treated as absent.
- Claude maps prompt/tool work to `active --blink`, Stop to `completed --auto-reset`, and permission
  prompt to blocked. PostToolUse clears a prior block because there is no answer event.
- Codex maps SessionStart idle; prompt/pre/post tool active; Stop ending `?` blocked, otherwise completed.
  `PermissionRequest` is insufficient under Auto Review, so a pane watcher reads `session.text` and blocks
  only for visible approval/question UI. Remove stale issue #193 `codex-notify.sh` values, not comments or
  foreign notifiers.
- TOML merging refreshes managed markers while preserving trust tables. Leave foreign markers, existing
  user hooks, and invalid TOML untouched; show manual instructions for the last two. Require `/hooks`
  review for command-hook changes.
- Install Pi only when `~/.pi/agent` exists. Start is active; settle only after retries, compaction, and
  queued continuations. Pi exposes no reliable blocked event, so never infer it from prose.
- Install OpenCode only when its config exists and export only `AgtermStatusPlugin`; the legacy loader
  treats every export as a plugin. Busy/retry and replies are active; asked permission/question is blocked.
  Latch a busy terminal error across sibling idle. Skip abort; defer ContextOverflow until idle unless busy
  resumes. Ignore deprecated `session.idle`.
- Preserve unmarked Pi/OpenCode files and require restart or reload. Host-free `AgentHooksInstall` owns
  merge, marker, backup, and optional-agent policy.
- Skill installation targets every existing Claude/Codex skill root, creating Claude only when neither
  exists. Refuse an unmarked `SKILL.md`. The sole source is `plugins/agterm/skills/agterm/` with
  `SKILL.md`, references, examples, troubleshooting, and `scripts/show-image.sh`.
- `show-image.sh` opens a PTY overlay and emits chunked kitty APC/base64. Pinned Ghostty has no OSC-1337
  or sixel, agent stdout escapes controls, and tool shells lack `/dev/tty`. Resolve relative to the loaded
  skill; hardcoded install paths and `${CLAUDE_PLUGIN_ROOT}` fail across app/plugin copies.
- Bundle the leaf at `Contents/Resources/agterm`. Claude uses array
  `skills: ["./skills/agterm"]`; Codex uses string `skills: "./skills/"`; the marketplace shapes differ.
  Keep plugin root `plugins/agterm` to avoid copying the roughly 21 MiB repository.
- Release bumps all three manifest versions and stops for commit because caches key on version.
  App-installed and plugin skills may coexist as `agterm` and `agterm:agterm` with undefined precedence.

## Transport and addressing

- Resolve socket from `AGTERM_CONTROL_SOCKET`, then `<AGTERM_STATE_DIR>/agterm.sock`, then Application
  Support. CLI `--socket` overrides. Explicit short paths avoid Unix `sun_path` near 104 bytes. Use 0600.
- Each connection sets `SO_NOSIGPIPE` and a 5-second receive timeout. Close on non-EINTR read failure,
  including EAGAIN. Start is idempotent, unlinks stale paths, and logs bind failure without blocking launch.
- One newline-delimited JSON request and response uses each connection, capped at 1 MiB. Unknown commands
  return structured errors. Mutations may return `result.id`; trees use `result.tree`.
- Human output shows IDs only for created session/workspace/window, retains them in JSON, uses
  `result.affected` for session counts, and reserves `result.count` for diagnostics/search.
- Targets accept active, case-insensitive UUID, or unique prefix. Batch targets resolve within the first
  target's store, deduplicate, and fail atomically. Preserve the first target in the legacy top-level field
  so old servers degrade to it rather than active.

## Public catalog

There are 71 public commands:

- `tree`, `events.read`
- `workspace.new`, `.rename`, `.delete`, `.select`, `.move`, `.focus`, `.filter`, `.collapse`, `.expand`
- `session.new`, `.duplicate`, `.close`, `.select`, `.rename`, `.reveal`, `.move`, `.type`, `.split`,
  `.scratch`, `.focus`, `.resize`, `.go`, `.copy`, `.paste`, `.selectall`, `.text`, `.search`, `.status`,
  `.flag`, `.seen`, `.restore`, `.background`, `.overlay.open`, `.overlay.close`, `.overlay.resize`,
  `.overlay.result`
- `surface.zoom`, `dashboard`, `pick.open`, `pick.result`, `pick.cancel`
- `quick`, `quick.type`, `quick.text`
- `sidebar`, `sidebar.mode`, `sidebar.expand`, `sidebar.collapse`, `notify`
- `font.inc`, `font.dec`, `font.reset`
- `window.new`, `.list`, `.select`, `.close`, `.rename`, `.delete`, `.resize`, `.move`, `.zoom`,
  `.fullscreen`, `.minimize`
- `keymap.reload`, `keymap.list`, `config.reload`, `theme.set`, `theme.list`, `restore.clear`

`debug.appearance` is a private 72nd `Command` case used only by `AppearanceFlipUITests`.
It accepts light/dark, sets `NSApp.appearance`, posts `.agtermSystemAppearanceChanged`, echoes the effective
side, and reads `lastAppliedIsDark` when bare. Refuse it outside XCUITest; provide no CLI or skill entry.

## Organization commands

- `workspace.delete` enforces at least one workspace and errors instead of showing the GUI alert.
- `session.close` keeps legacy one-target hard close. Repeated targets are atomic and deduplicated; one
  unique target remains the legacy hard path. Multi-target close follows `closeGraceUndoEnabled`, creates
  one grouped undo/reopen record, and returns actual `affected`; selecting any recent group member restores
  the group and selects that member.
- `session.move` accepts exactly one placement intent:
  - `--to up|down|top|bottom` reorders one session in its workspace.
  - workspace relocates and appends.
  - `--after`/`--before` resolves an anchor across the store, carrying destination workspace.
  Relative placement uses host-free `SidebarDrop.resolveRelative`; batches use tree-order remove-first
  `resolveSessions`. Reject batch `--to`. Count only actual moves. A one-member batch uses singular behavior.
- Sidebar batch Flag computes one uniform value: flag all unless all are already flagged. This is not
  equivalent to repeated toggle; scripts read state then loop on/off. Batch Clear Status is equivalent to
  repeated `session.status idle` and needs no batch command.
- `workspace.move --to up|down|top|bottom` reorders relative to the target. Drag remains the precise
  between-row surface. `active` resolves through `currentWorkspaceID` — a foreground-created workspace
  first, then the selected session's, then `workspaces.last` — so repeated moves may target a different
  workspace; use an ID to keep one target.
- `session.split` drives the addressed session, not active-only `AppActions.toggleSplit`. Off hides and
  retains the shell; only shell exit tears it down.
- `session.scratch` is a third, nonpersisted login shell with on/off/toggle. It spawns lazily, survives
  hiding, recreates after exit, and renders as a full translucent cover below overlay. It has no session
  PWD/title link but a weak watermark link. GUI surfaces are Command-J, titlebar, View, and palette.
- `session.focus --pane left|right|other` requires an existing split and works shown or hidden.
  Read `splitFocused`.
- `session.resize` accepts exactly one absolute ratio or relative grow-left/grow-right delta, defaulting
  an unset ratio to 0.5. Require a split, clamp through store limits, persist, then post the object-scoped
  live-divider notification. Hidden split stores for next show. Return clamped ratio as `%.3f`; read
  `splitRatio`.
- `session.go --to next|prev|first|last|next-attention|prev-attention` operates on current selection in
  the placement store, wraps within filtered scope, and returns selected ID. It has no target.
- `notify` requires body, defaults title and session, skips OSC focus suppression, increments unseen, and
  uses click identity. When banners are disabled, return `ControlNotify.bannersOffNote` (#286); delivered
  requests omit text. Read through `unseen`.

## Session creation and duplication

- `session.new` chooses one mutually exclusive destination:
  - workspace ID/prefix/active;
  - exact-trimmed workspace name, optionally create-or-reuse;
  - `--after`/`--before` anchor, which supplies workspace and insertion index.
  Reject both anchors, placement plus workspace, name plus ID, create without name, and missing name without
  create. Insert indices are clamped.
- `--command` becomes raw libghostty `config.command`, not shell input. Ghostty quote-splits into argv and
  executes directly, so operators, expansion, redirection, and globs require an explicit `sh -c` or
  `zsh -lc`. GUI launch PATH lacks `/opt/homebrew/bin`; missing binaries exit 127, so use absolute paths
  or a login shell.
- `initialCommand` persists and reruns only when restored-command support is enabled; fresh sessions always
  run it. Captured foreground takes precedence. Promoting a split survivor clears the exited pane's initial
  command.
- `--no-select` neither changes selection/recency/focus nor reveals a newly created workspace into an
  applied focus set. Foreground creates add their new workspace to the set instead of disabling filtering.
  Do not overload the opposite-polarity `ControlArgs.select`.
- `session.duplicate` atomically creates a plain login shell after the source in the same workspace from
  `focusedCwd`. Copy no name, command, pane, status, flag, font, or background state. The new tree node is
  the read-back. Source `tree.cwd` remains primary, so it can differ from the focused cwd copied.

## Surface input, output, and search

- `session.type --pane left|right|scratch` defaults to main for compatibility, not focused/on-screen.
  Hidden live scratch is addressable; missing panes error. Main alone may select and bounded-poll a newly
  unrealized session.
- `inject` emits Ghostty key events and Return keycode 36 for newline/CR/CRLF. Never replace it with
  `ghostty_surface_text`, whose bracketed paste suppresses Return and can expose `\e[200~`/`\e[201~`
  markers under rapid use.
- `session.copy` returns the addressed main selection without touching clipboard; empty is `no selection`.
  `session.paste` and `.selectall` run Ghostty bindings on main. They use
  `Session.addressableSurface = surface ?? splitSurface`, never focus-aware `activeSurface`, so select-all
  and copy share one pane. Read paste through text and select-all through copy.
- Keep standard SwiftUI Edit routing. `GhosttySurfaceView` implements Copy/Paste/Select All and validation;
  focused text fields retain their behavior, terminal Cut stays absent. Do not replace the combined
  pasteboard command group. Remove the separate Undo/Redo group because Command-Z belongs to Reopen Closed
  Item; assert menu-item absence.
- Paste validation must call the same URL/string branches as paste. Type-only probes disagree for Finder
  URLs and declared-without-data pasteboards. Short-circuit on the first usable URL and share `urlText`;
  validation must not materialize thousands of files. This has manual named-pasteboard coverage because
  sandboxed XCUITest exposed no app-side types during an 8-second Finder-URL poll. Poll general pasteboard
  after external writes.
- Fixed Edit shortcuts use AppKit-produced characters. Retain Ghostty
  `super+key_c/v/a` keycode fallbacks for non-Latin layouts and disabled menu items; there is no AppKit
  Latin fallback. Paste requests are not OSC 52 reads and must not prompt.
- `session.text` defaults to `onScreenSurface`: covering scratch, then focused pane. Explicit left/right/
  scratch addresses that pane, including hidden scratch. Default reads viewport; `--all` includes
  scrollback; `--lines N` returns last content lines after trimming blank grid rows. All and lines are
  exclusive; N must be positive and dispatcher-validated. Blank returns empty success; API failure errors.
  Output is plain text because pinned Ghostty exposes no styled-cell read.
- `session.search` selects and realizes the target, then searches its focused surface. Text opens/updates;
  to next/prev navigates; close ends; no arguments opens empty UI. Poll async SEARCH_TOTAL and return count
  plus `searchDisplayText`. Search fields are ephemeral and shared with the GUI.
- `quick.type`/`quick.text` mirror session input/read for the frontmost single quick surface, with no
  window/target/pane. Poll up to 12 times at 30ms after quick show; distinguish not open, not realized,
  read failure, and no open window. Hidden previously shown quick remains addressable (#170).
  Text is type's read-back.

## Overlay, zoom, dashboard, and picker

- Overlay open runs one shell-wrapped program in a nonpersisted per-session surface. Size nil is full;
  1...100 is floating. Optional color uses shared validated `#rrggbb` surface config and window opacity.
  Background target runs without selection; `--follow` selects. `--wait` retains Ghostty's exit prompt.
- Both full and floating use one always-present `overlayPanel` at z3. Gate content inside its
  `GeometryReader`; never change the `sessionDetail`/HSplitView shape or pane modifiers on overlay state.
  Full is translucent/chromeless and hides panes; floating is opaque/framed over visible panes with an
  internal click catcher. Value-only resizing must not reparent the Metal surface.
- Handle `GHOSTTY_ACTION_SHOW_CHILD_EXITED`. Return true for immediate close, false for wait; process-exit
  handling must be idempotent. Use bounded first-responder retries and refocus underlying surface on close.
- Exit status uses env-carried command/temp path in fixed
  `sh -c '( eval "$AGTERM_OVL_CMD" ); echo $? > "$AGTERM_OVL_CODE"'`, without output redirection.
  Read/delete during surface teardown before callbacks are cleared. `overlay.result` returns exit code,
  still-running, or no-result. CLI `--block` polls returned session ID, rejects `--wait`, prints no process
  output, and exits with captured status.
- `overlay.resize` requires an open overlay and exactly one valid percent or `--full`; mutate the same
  surface host. Read `overlaySizePercent`, gated by overlay-active because nil means either full or absent.
- `surface.zoom show|hide|toggle` reparents exactly one surface below a slim titlebar. Active precedence is
  quick, overlay, scratch, focused split, primary; explicit IDs are
  `surface:<session-id>:<left|right|scratch|overlay>` or `quick`, including hidden live panes.
- Host-free `TerminalZoomController` owns mode/state. Zoom must not change ratios, focus, sidebar, or pane
  visibility; deck slots remain constant and focus reporting is suppressed. Opening closes palette/search
  and conflicting quick terminal; banner reveal and Command-W exit. Font remains live. Reject quick show
  and search-open while zoomed, but keep hides idempotent even if the target vanished. Read
  top-level live `zoomedSurface`; surface node active/visible describes pane state, not zoom.
- `dashboard` opens explicit IDs or `--mru`, or closes. Font-size and auto-size are exclusive; close accepts
  no IDs/MRU/font; open needs IDs or MRU; fixed size must be finite positive.
- A split expands to primary and split `DashboardMember`s, unless the id carries a `:left`/`:right` suffix
  (#331) selecting one pane. Host-free `DashboardTarget` owns that grammar: split on the FIRST colon,
  accept only `left`/`right` case-insensitively, reject everything else including `primary`/`split`,
  `scratch`/`overlay`, and a pasted `surface:<id>:<pane>`. The dispatcher rejects bad grammar outright; a
  well-formed ref naming no pane (`:right` without a split) is a soft miss joining `unresolved`.
- Resolve targets in order and deduplicate by session+pane, then cap panes app-side at
  `DashboardLayout.maxCells` 9. Append dropped-pane text to unresolved text with `;`. Guard emptiness on the
  EXPANDED members, never the resolved ids: with pane refs they diverge, and opening on an empty set clears
  zoom and silently closes a live dashboard. MRU takes up to nine valid recency entries before expansion and
  errors on an empty window.
- `closePrimaryPane` promotes a split survivor into the primary slot, so `DashboardController`
  `promoteSplitMember` rewrites that session's `.split` cell to `.primary` from `agtermApp.handlePaneExit`.
  Reconcile cannot do this: `closeSplit` and `closePrimaryPane` leave identical `hasSplit == false` state,
  and only the exit path knows which happened.
- Dashboard is per-window and view-only; GUI Command-Shift-D/menu/palette toggles MRU auto-size.
  Arrows navigate ragged `ceil(sqrt(n))` grid, Enter closes then selects/focuses exact pane, Esc closes.
  It is reciprocal with zoom. Read live `dashboardMembers`, highlighted member, applied font size, and
  `auto|fixed|untouched` mode. See [[libghostty]] for reparent, input gates, and transient font.
- `pick.open` accepts 1...1000 unique ID items with nonempty labels, or an empty list when `allowCustom`
  is set, which makes it a text prompt. Absent items return `pick.open requires items`; an empty list
  without `allowCustom` returns `pick.open requires at least one item`.
  Optional subtitle/prompt/query/custom/follow; `query` prefills the field so the picker opens filtered.
  Reject duplicate IDs and control characters host-free; `prompt` and `query` stay unvalidated free text.
  One picker may be pending per window. Background remains background unless follow raises and publishes
  frontmost.
- Caller-supplied rows match on their label only. Subtitles are displayed but never searched, so
  consequence text cannot filter a safe row out and leave a destructive one preselected. An empty query
  preserves caller item order; a prefilled `query` re-ranks and drops that order. The palette trims
  whitespace and newlines before deciding, so a blank `query` counts as empty — `fuzzyScore` consumes a
  newline the trim would otherwise keep, scoring every row 0 and losing the order to the A→Z tie-break.
- Global picker ID pins result/cancel to its owner across frontmost changes; explicit window must match.
  Results are pending, picked with ID/label/index, custom with query, or cancelled. Cancel is idempotent
  after terminal state. Tree exposes `pickPending`.
- Selection/custom/Esc/Command-W/window close resolve. App termination may race polling. Retain eight
  terminal results per controller; on unregister move them into a 32-entry app-wide oldest-first store so
  deletion does not lose a pending poll.
- CLI reads JSON array when stdin begins `[`, otherwise nonblank lines become ID=label. Blocking poll is
  100ms for one second, then 500ms; print bare result JSON; exit 0 picked/custom, 2 cancelled, 1 failure.
  `--no-block` prints picker ID JSON; result/cancel are one-shot commands.

## Status, notifications, and flags

- `session.status` accepts idle/active/completed/blocked, blink, auto-reset, optional sound, `#rrggbb`
  color, fixed shape set, and pane. Build a fresh ephemeral indicator so omitted overrides clear.
- Validate sound before mutation and target playback. `default`/`beep` beeps; named system/custom sounds
  use cached `NSSound`. Without per-call sound, entering blocked may play configured default once;
  repeated blocked does not. Explicit per-call wins via `AgentStatus.effectiveSound`.
- Validate color and shape before mutation. Shapes are circle, square, triangle, diamond, capsule, star;
  derive validation/help from `StatusShape.allCases`. Idle accepts but does not render shape.
  AppKit and SwiftUI resolve through shared color/symbol helpers.
- `ControlEventPayload` and `EventFormatter.human` must include every override; human status prints color
  and shape. Tree reports state, pane, true blink, per-call color, and per-call shape only while non-idle.
- Pane is left/right/scratch, nil meaning left. It controls pane-scoped keystroke clearing and GUI
  blocked/completed reveal. Control attention navigation changes selection only.
- `--pane-id` (#199) is a stable per-surface token that overrides stale baked role after promote/re-split,
  then falls back to role when absent/unknown. Inject `AGTERM_PANE_ID`, resolve against live surface tokens,
  and report only resolved `statusPane`. This alternative addressing adds no read-back field.
- Auto-reset clears both session entered and session left. Status renders on selected sessions too.
- `session.flag on|off|toggle|clear` is idempotent; clear ignores target and clears the store.
  Read `flagged`.
- `session.seen` clears unseen without selection/focus/status or persistence. Read nonzero `unseen`.

## Keymap, config, theme, and sidebar

- `keymap.reload` shares GUI reload and returns diagnostic count. `keymap.list` reports:
  resolved built-in actions and override state; live AppKit menu equivalents/menu/title/selector; path;
  custom commands; diagnostics. The two chord sets may differ during deferred rebuild or collision.
  Host-free projection names arrow/return; represent AppKit globe as `fn+` even though grammar lacks it.
- `config.reload` shares GUI/Edit-overlay reload and returns Ghostty diagnostic count. Keymap and config are
  app-global and take no window.
- `theme.set` operates on light and dark slots. Name/light aliases conflict; setting light preserves dark.
  Nil/empty means Ghostty built-in, while bare set clears both and disables sync. Dark enables sync,
  seeding missing light from current or Builtin Light; reserved `none` clears dark and sync but preserves
  light. Validate bundled names and return full post-state. Palette commits current appearance slot only.
- `theme.list` returns bundled names and plain or sync state. While syncing, omit plain theme and return
  light/dark. CLI marks active entries and includes `default ghostty`. Theme is app-global.
- `sidebar show|hide|toggle` is per-frontmost-window, persisted and animated from one root value.
  It shares titlebar, View, palette, and Control-Shift-Command-S behavior.
- `sidebar.mode tree|flagged|toggle` is frontmost and reads live `sidebarMode`.
- `sidebar.expand` and `.collapse` target optional open window, post object-scoped store notifications, and
  no-op in flagged mode. Collapse preserves/scrolls active workspace. GUI forms are frontmost only.
- `workspace.focus on` replaces/enables; off removes and disables on empty; toggle clears sole applied
  target or replaces/enables; add inserts without changing enabled state. There is no membership toggle.
  Clear Focus loops off over members; `workspace.filter off` only suspends.
- Read membership independently as `focused`. A workspace row is visible exactly when
  `sidebarVisible && sidebarMode == "tree" && (!workspaceFilter || focused)`. Preserve all terms.
- `workspace.filter on|off|toggle` targets optional window, changes only enabled state, and refuses to
  enable empty membership. Read live top-level `workspaceFilter`.
- Focus/filter/mode/flag narrowing reselects the most recent visible session. Growing an empty visible set
  may also repair selection; flag clear and no-select creation do not.
- `workspace.collapse`/`.expand` persist model first, then post view-sync notification so hidden sidebar
  state is not lost. Coordinator updates tracked expansion under suppression. Read omitted/true `collapsed`.
- `workspace.new --collapsed` starts collapsed and does not reveal into focus membership. Plain create
  remains visible. Workspace adapters stay in `ControlServer+WorkspaceCommands.swift`.

## Tree and window read-back

- Session nodes include foreground/split foreground argv, background spec, overlay size, split ratio,
  split focus, status fields, flag, unseen, restore pins, and surfaces. Foreground uses the same
  pid/sysctl/host-free command extraction as restore capture.
- Top-level tree includes idle/auto-follow, live sidebar visibility/mode, workspace filter, quick
  visibility, zoom, dashboard, and picker state. Prefer live tree sidebar state over cached window list.
- Window nodes include open/active, open-store sidebar/auto-follow, geometry, fullscreen, zoomed, minimized.
  Closed live fields are omitted. Geometry is top-left display-relative y-down and round-trips move/resize.
- Window list is cached. Refresh after commands and frontmost/sidebar/attachment/move/resize/fullscreen/
  minimize changes. Ignore `Notification` payloads rather than carrying non-Sendable values into main actor.
  Minimized is live-only; restoration always reopens unminimized.
- Exact window behavior, readiness, cache ordering, and GUI interaction are owned by [[windows]].

## Restore commands

- `restore.clear` clears captured main/split foreground commands across open windows and saves immediately.
  It never clears durable `initialCommand`; it is app-global.
- `session.restore` pins per-session, per-pane next-launch behavior for discussion #264:
  - nil/unpin/clear uses capture;
  - empty/pinNone/none forces plain shell and suppresses capture plus initial command;
  - command/set types that shell line.
- Pins persist and repeat each launch until changed, but never affect the live shell. Keep persisted
  `restoreCommand`/`splitRestoreCommand` separate from one-shot pending slots. Only bootstrap copies pins
  to pending; factories take-and-clear pending. Never let factories fall back to persisted values.
- `CommandRestore.restorePlan` owns precedence. Honor the master `restoreRunningCommand` setting, bypass
  denylist for deliberate pins, and type text verbatim. Document that persisted shell code may enter
  history and must not contain secrets.
- Reuse command/mode/pane/paneID. Validate mode, required set command, no control characters including tab,
  maximum 1024 UTF-8 bytes, and left/right/scratch. Shell metacharacters are allowed.
- Pane ID resolves first. Unlike status, unknown pane ID without an explicit pane errors to avoid writing
  main accidentally. Reject scratch and right without a split.
- Save checked and roll back memory on failure; report that the previous value remains. This durable shell
  payload must never acknowledge an unsaved clear. When restore setting is off, successful set returns an
  explanatory note; none/clear do not.
- Promotion moves persisted and pending right pins to main; split close clears both. Soft-close paths clear
  pending before retaining objects; duplicate copies neither.
- Seed pending only at the three library bootstrap paths. Seed split only when snapshot restores a shown
  split. Drop hidden split pins because no pane exists to address or clear them.
- Tree reads persisted pins, including empty string, never pending state.

## Session backgrounds

- `session.background image|text|color|clear` persists a host-free `BackgroundWatermark`.
  Image requires existing PNG/JPEG path without controls. Text is capped at 256 characters and may set
  color. Image/text accept opacity 0...1, typed fit, position, and repeats. Color requires `#rrggbb` and
  uses window opacity, not a per-call value.
- Apply to main, split, and scratch through retained per-surface config overlays. Image/text force
  background opacity 1; solid color emits background plus current window opacity; include font size so
  session zoom survives. Free configs only when surfaces die.
- Text rasterizes under `<stateDir>/watermarks/<sessionID>.png` with live foreground default. Regenerate on
  restore/theme change; remove on clear, text-to-image, and permanent deletion.
- Shared config reload wipes surface overlays, so resolve theme colors then reapply. Opacity-slider changes
  must reapply color after `windowOpacity` updates, including within-range drags that do not reload.
- `Fit`/`Position` are CaseIterable typed enums. Revalidate free-text path/color during emission.
  Tree reads the stored background specification. See [[libghostty]] for live OSC 11 precedence.

## Documentation mirrors

- Keep the bundled skill synchronized with commands, arguments, results, keymap, model, and command count.
  `SkillInstallTests` checks its `Command summary (N commands)`.
- `site/commands.html` documents every command, invocation, arguments, and read-back. Keep its four count
  mentions, README, docs mirror, skill, and test aligned.
- Search count patterns, not an assumed old/new value, then inspect every two/three-digit number in this
  file. Counting only explicit raw-value assignments undercounts implicit cases.
