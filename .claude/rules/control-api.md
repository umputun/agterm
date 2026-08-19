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
- An action whose only effect is a system-pasteboard write gets no control command. The socket never
  writes the user's clipboard — `session copy` returns the selection so it does not have to,
  `session paste` reads it as input — and returning the value instead duplicates what `tree` carries.

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
- Every install-result alert line stays ONE LINE and embeds no generated block; two or three sentences on
  that line are fine, and `AgentHooksInstallerTests` pins exactly that. `NSAlert` sizes itself to fit
  `informativeText` with no scroll and no height cap, so embedding the hooks block grew the window past the
  bottom of the screen (#430) — the block's long `command =` lines wrap several times each in that narrow
  column. The two manual-merge cases open `site/docs.html#codex-hooks-manual` through a second button
  instead, `informativeText` being plain unselectable text that renders no link. Keep the button second so
  OK stays the default and Return still dismisses. That docs section carries a copy of `codexHooksBlock`
  and drifts from it silently.
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
  including EAGAIN. Start is idempotent and logs bind failure without blocking launch.
- `ControlServer.init` takes an exclusive non-blocking `flock` on `<socketPath>.lock`, and start refuses
  to bind while another process holds it. Ownership is decided at INIT, not at start: the launch window's
  surfaces are built during the initial render pass and snapshot `AGTERM_SOCKET` into the pty environment,
  while start runs from the scene's `.task` afterwards, so deciding there would hand the first shell the
  owner's live socket. Start retries acquisition for the instance refused while the owner was still alive,
  guarding on the held fd first — flock is per open file description, so re-opening a file this process
  already locked conflicts with itself. Nothing on disk distinguishes a live socket from a
  force-quit leftover, and unlinking a live one strands its owner: it keeps its listening fd, never
  learns, and only a restart recovers it. Do NOT probe with `connect` instead — on Darwin a live listener
  whose backlog is full refuses with the same `ECONNREFUSED` a socket nobody listens on returns, so one
  stalled client parking the serial accept loop would make a running instance read as stale. `flock` is
  also atomic against two instances launching together, and the kernel drops it on a force-quit, which is
  the case the unlink covers. Never unlink the lock file: the next instance would lock a fresh inode and
  exclude nobody.
- A refused instance advertises `<socketPath>.unavailable` through `resolvedSocketPath`, so its shells and
  `{AGT_SOCKET}` carry a path nothing serves instead of the resolved default, which would point them at
  the other instance — the user's live terminal, where shared state makes persisted session ids resolve
  too. Do NOT omit the variable instead: `agterm-agent-status.sh` drops `--socket` when it is absent and
  `agtermctl` then resolves that same default, so an unset value routes agent status onto the live app.
  `refused` clears on a later successful acquire, since `start()` re-runs per window scene and the owner
  may have quit. Its `stop()` returns early without unlinking, leaving the owner's socket intact.
- One newline-delimited JSON request and response uses each connection, capped at 1 MiB. Unknown commands
  return structured errors. Mutations may return `result.id`; trees use `result.tree`.
- Human output shows IDs only for created session/workspace/window, retains them in JSON, uses
  `result.affected` for session counts, and reserves `result.count` for diagnostics/search.
- Targets accept active, case-insensitive UUID, or unique prefix. Batch targets resolve within the first
  target's store, deduplicate, and fail atomically. Preserve the first target in the legacy top-level field
  so old servers degrade to it rather than active.

## Public catalog

The public commands, which no surface states a COUNT of: a total is stated nowhere and pinned by nothing, so
adding one is an edit to this list and the surfaces that document the command itself, never a synchronized
renumbering. Do not reintroduce a count anywhere.

- `tree`, `events.read`
- `workspace.new`, `.rename`, `.delete`, `.select`, `.go`, `.move`, `.focus`, `.filter`, `.collapse`, `.expand`
- `session.new`, `.duplicate`, `.close`, `.select`, `.rename`, `.reveal`, `.move`, `.type`, `.split`,
  `.split.close`,
  `.scratch`, `.focus`, `.resize`, `.go`, `.copy`, `.paste`, `.selectall`, `.text`, `.search`, `.status`,
  `.flag`, `.seen`, `.restore`, `.background`, `.overlay.open`, `.overlay.close`, `.overlay.resize`,
  `.overlay.result`, `.overlay.copy`, `.overlay.text`, `.hud.open`, `.hud.update`, `.hud.close`
- `surface.zoom`, `surface.cursor`, `dashboard`, `pick.open`, `pick.result`, `pick.cancel`
- `quick`, `quick.type`, `quick.text`
- `sidebar`, `sidebar.mode`, `sidebar.expand`, `sidebar.collapse`, `notify`
- `font.inc`, `font.dec`, `font.reset`
- `window.new`, `.list`, `.select`, `.close`, `.rename`, `.delete`, `.resize`, `.move`, `.zoom`,
  `.fullscreen`, `.minimize`
- `keymap.reload`, `keymap.list`, `config.reload`, `theme.set`, `theme.list`, `restore.clear`

`debug.appearance` is a private `Command` case, absent from the list above, used only by `AppearanceFlipUITests`.
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
- `workspace.go --to next|prev` steps the CURRENT workspace through `visibleWorkspaces`, wrapping, and
  routes through `selectWorkspace`, so it lands on the target's FIRST session and inherits the
  empty-workspace reveal. Relative like `session.go`, so it takes no target; `workspace.move` is the
  neighbouring verb that reorders instead. Returns the workspace id it landed on. Collapse state is NOT a
  term — a folded workspace is stepped into like any other, and issue #435 assumed otherwise. Errors with
  `no other workspace to navigate to` where there is nowhere to step: flagged mode, or one visible
  workspace. Read back through `tree` selection; the GUI twins are `previous_workspace`/`next_workspace`.
- `session.split` drives the addressed session, not active-only `AppActions.toggleSplit`. `--axis
  vertical|horizontal` selects left/right or top/bottom; omitting it preserves an existing split's axis
  and defaults a new split to left/right. Off hides and retains the shell; `session.split.close` and the
  split shell's own exit are what tear it down.
  `split` reports SHOWN, so a hidden split reads false;
  `hasSplit` reports the pane existing at all and is present exactly when `splitRatio`/`splitFocused`
  can be. Callers asking "does this session have a split" read `hasSplit`, and `agtermctl tree` tags the
  hidden case `(split hidden)`.
- `session.split.close` is the teardown verb, its own command rather than a fourth `ControlToggleMode`
  value, which is shared with `session.scratch`/`sidebar` and cannot express close (a hidden split is
  already `off`). Idempotent: a session with no right pane answers ok. The palette's Close Split is the
  GUI twin, a row gated on `hasSplit` with no `BuiltinAction`.
- `session.scratch` is a third, nonpersisted login shell with on/off/toggle. It spawns lazily, survives
  hiding, recreates after exit, and renders as a full translucent cover below overlay. It has no session
  PWD/title link but a weak watermark link. GUI surfaces are Command-J, titlebar, View, and palette.
- `session.focus primary|split|left|right|top|bottom|other` requires an existing split and works shown or
  hidden. The pane is positional; read `splitFocused`.
- `session.resize` accepts exactly one absolute ratio or one relative
  `--grow-left|right|primary|split|top|bottom` delta, defaulting an unset ratio to 0.5. Require a split,
  clamp through store limits, persist, then post the object-scoped live-divider notification. Hidden split
  stores for next show. Return clamped ratio as `%.3f`; read `splitRatio`.
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

- `session.type --pane` accepts `primary|left|top`, `split|right|bottom`, or `scratch`; omission defaults
  to primary for compatibility, not focused/on-screen. Read-back and the stable invalid-value error use
  canonical `left|right|scratch` names.
  Hidden live scratch is addressable; missing panes error. Main alone bounded-polls (12 × 30ms) a newly
  unrealized session, with or without `select`, so `session.new --no-select` plus an immediate type does
  not race the mount+layout gap (#349). The probe precedes every sleep, so a realized session pays nothing
  and `select` moves selection only when the surface was not ready. `right`/`scratch` still fail fast.
- `injectText` resolves only `surface`/`splitSurface`/`scratchSurface`, so like `session.text` every `--pane`
  addresses the pane UNDER a covering overlay: the keystrokes run in the hidden shell, unseen until it closes,
  while the call answers ok. This is the intended behavior, not a gap — the panes are the session's durable
  input surfaces and stay drivable whatever is drawn over them, so a cover never has to be torn down to keep
  automation running. Reads are the asymmetric half by design: `overlay.copy`/`overlay.text` exist because an
  overlay's output is otherwise unobservable, while its program is the caller's own and needs no second way in.
  Do not add a write twin, and do not make a covered `session.type` fail — a caller would lose the pane it
  still legitimately addresses.
- `session.type` ok means the keystrokes were queued to the pty, not that the shell read or ran them (#350).
  Nothing is lost in between: libghostty's write mailbox blocks instead of dropping, messages queued before
  the io thread starts are drained once the subprocess is up, and no code path flushes pending tty input.
  A NUL never reaches that path: `ghostty_input_key_s.text` is NUL-terminated and libghostty slices at the
  first zero, so `session.type`/`quick.type` reject text carrying one with `text must not contain a NUL
  byte` rather than typing the run up to it, sending its Return, and answering ok (#455).
  A caller needing execution polls `session.text`, which is what the e2e marker idiom does.
  `ghostty_surface_key`'s bool reports consumption, not delivery, so checking it would add no readiness.
- `inject` emits Ghostty key events and Return keycode 36 for newline/CR/CRLF. Never replace it with
  `ghostty_surface_text`, whose bracketed paste suppresses Return and can expose `\e[200~`/`\e[201~`
  markers under rapid use.
- `session.copy` returns the addressed main selection without touching clipboard; empty is `no selection`,
  and an unrealized pane is `session not realized` — `readSelection` cannot tell the two apart, and copy is
  select-all's read-back, so both name that state the same way. It stays on the PANE while an overlay covers
  it, so a selection made inside one is `session.overlay.copy`'s, not this command's.
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
  An UNREALIZED pane answers `session not realized`, not `failed to read surface buffer`, whether its slot
  is empty or holds a view whose libghostty surface never came up — one state to a caller, and the reading
  never happened. `failed to read surface buffer` is left to a real read failure on a realized surface.
  `quick.text` keeps its own vocabulary and still reports that string for an unrealized quick surface.
  Output is plain text because pinned Ghostty exposes no styled-cell read.
  `onScreenSurface` is pane-vs-scratch only, so every `--pane` and the default alike read the surface
  UNDER an overlay; the covering program is `session.overlay.text`.
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
- `--pane left|right` on open/close/result scopes the overlay to ONE split pane, leaving the sibling live.
  Slots are independent and always full-pane: reject `--pane` with `--size-percent` and on `overlay.resize`.
  Refuse a pane the deck does not lay out (`pane not visible`) and an occupied slot
  (`pane overlay already open`). Omitting `--pane` keeps the session-wide overlay byte-for-byte.
  Promotion moves the right pane's overlay into the left slot without rebuilding its surface, so that
  surface's callbacks resolve their pane through `Session.paneOverlayRole(of:)`, never a captured one.
  Read back `paneOverlays`, ordered left-then-right.
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
- `overlay.copy`/`overlay.text` read the COVERING surface, which `session.copy`/`session.text` cannot reach
  (#434) — those address the pane the overlay hides, so a selection made in the overlay reads as
  `no selection` and `--pane right` returns the shell underneath. Both take the overlay family's own
  `--pane`, never the shared `left|right|scratch` one: widening that would let `session.status`/`.restore`
  reach a `StatusPane` that has no overlay case, over persisted state. `ControlServer.overlayReadSurface`
  resolves both, so an empty slot (`no overlay`) and a filled one whose surface has not come up
  (`overlay not realized`, naming the cover rather than borrowing `session not realized`) cannot mean
  different things on one command than the other. A HUD is refused ahead of both with
  `OverlayHudError.noRead`: it paints the app's own message, and `overlayActive` alone cannot tell it from
  a caller's program. `overlay.text` validates `--all`/`--lines` through the same `parseBufferExtent` as
  `session.text`, before the pane, so identical flags produce the identical first error. These are reads,
  so they add no read-back field.
- `session.hud.*` puts a passive message panel in the SESSION-WIDE overlay slot rather than adding a cover,
  so the Command-W ladder, `coverHidesActiveSession`, `searchTarget`, and session-close teardown are
  unchanged. It is control-native: no menu item, chord, or palette entry, a deliberate exemption from
  [[menu-actions]]'s shared-action-seam rule because there is nothing here for a human to invoke by hand.
- Passivity is four deck exemptions plus two NSView-level gates, all reading ONE predicate,
  `Session.programOverlayActive` (`overlayActive && !hudActive`): `gates.overlaid`, the floating click
  catcher, `backdropWashActive`, the scratch's focus gate, `TerminalView.viewOnly` on the panel, and the
  program-only key for the overlay-close refocus. `viewOnly` owns the NSView layer, where `mouseDown` makes
  a surface first responder; the panel's ancestor `.allowsHitTesting(false)` currently blocks the click
  before that, so the two are belt and braces and neither is the place to economise.
  Keying the refocus on the raw slot instead yanks focus out of a search field or a rename on every
  close. Never spell it inline; two spellings will disagree. `OverlayPanelStyle` resolves
  every per-occupant parameter, so the modifier chain stays constant and only values flip. `overlayPanel`'s
  `.id` carries `Session.overlaySlotGeneration`, or a replacement keeping `overlayActive` true never re-runs
  `makeNSView` and `updateNSView` hits a torn-down view.
- The same predicate governs focus routing: `Session.topmostSurface`, `focusTarget(wantSplit:)`,
  `onScreenSurface`, `AppActions.searchTarget`'s scratch rung, and the scratch factory's `suppressAutoFocus`.
  A raw `overlayActive` read at any of them hands first responder or a buffer read to the HUD painter.
- One slot, asymmetric replacement: a second `hud.open` replaces the first, `overlay.open` closes a HUD and
  proceeds, and a HUD over a RUNNING program is refused `overlay already open`. `overlay.close`, Command-W,
  and session close tear a HUD down. `overlay.result` refuses with `OverlayHudError.noResult` because
  `overlayActive` alone would answer the misleading "overlay still running", and `overlay.resize` takes a
  percent but refuses `--full` (`OverlayHudError.fullResize`), which would cover the session it describes.
- Zoom narrows on the same predicate: `isActive`'s shared `uncovered` and its `.scratch`/`.overlay` arms,
  `isAvailable`'s `.overlay` arm, `isVisible`, and `paneVisible`. Widen `uncovered` and narrow the `.overlay`
  arm together or no case is active and the documented-unreachable `?? .primary` fallback runs. The explicit
  `surface:<id>:overlay` address is REFUSED for a HUD, and no overlay surface node is listed beside it.
- A HUD sizes each axis separately, through `HudLayout.panelSize` into one `HudPanelSize` that travels
  store-to-deck: width from the box's columns, height from its rows. One percent across both made every
  panel as tall as it was wide, which is a square box around two lines of text, so `OverlayPanelStyle`
  carries `widthFraction`/`heightFraction` and only a PROGRAM overlay sets them equal.
- `--size-percent` reaches the WIDTH alone, on open and on `overlay.resize` — the text wraps at
  `HudLayout.maxColumns`, not at the panel, so a resize changes no rows — and the height takes no caller
  override at all. Every HUD WIDTH passes `HudLayout.clampSizePercent` (10...80), the caller's included, so
  `--full`'s refusal and the never-cover invariant cannot disagree. The height is capped at the same 80 but
  takes NO minimum floor: the box already carries `verticalPadding`, and flooring it is the square again.
  The 80 cap is also what makes an edge anchor always fit its margin on EITHER axis, each axis' own extent
  being what decides how far the panel travels there; the centering fallback in `OverlayPanelStyle`'s two
  offsets is defensive only.
- `HudPosition` is the nine anchors of a 3x3 grid, spelled exactly as `BackgroundWatermark.Position` so
  `--position` means one thing across `session.background` and `session.hud`. The bare `top`/`bottom` it
  shipped with stay ACCEPTED as aliases for the middle column, and `HudPosition.parse` is the one entry
  point that resolves them — dispatcher, CLI validation and `init(from:)` all take it, so no path accepts a
  name another rejects. They NORMALIZE: the read-back reports the canonical anchor, which is what makes them
  aliases rather than a second vocabulary. Rejections and CLI help list `acceptedNamesList`, never the
  canonical set alone, for the same reason `HudSpinner` lists `none`. `verticalBand`/`horizontalBand` split
  an anchor into its row and column so `OverlayPanelStyle` runs one offset over each axis.
- An unmeasured pane splits the fallback: width takes `maxSizePercent` (nothing is known to fit), height
  takes `minSizePercent` (80% of a pane is a cover, not a message). `OverlayPanelStyle` falls back the same
  way for a HUD whose height has not been measured yet.
- `HudSpinner` owns the spinner: one case per style, each carrying its own FRAMES and tick interval, and
  both ride the body header so the helper holds no table and a case is one edit. Frames must be single
  scalars that render one column and contain no space — the header is word-split, and `spinnerWidth`
  reserves exactly two cells. `dot`'s blank frame is U+00A0, not a space, for that reason.
  The CLI keeps `--spinner` as the on switch for `HudSpinner.defaultStyle` and adds `--spinner-style`,
  which implies it; both resolve client-side, so `ControlArgs.spinner` always carries a style name or
  nothing and the dispatcher validates one thing. `noneName` is ACCEPTED by both, not just the socket —
  refusing it in the CLI would fail a value `tree` had just handed the caller — and beats a bare
  `--spinner` beside it. Rejection messages list it through `acceptedNamesList`, never the styles alone.
- The panel's two colors are owned by different layers, which is why only one is updatable:
  `backgroundColor` is a per-surface config the factory reads ONCE at creation, `textColor` rides the body
  file's header as SGR PARAMETERS the helper re-reads every tick. So `hud.update` recolors text in place and
  cannot touch the backing, and the CLI's `update` takes `--text-color` but no `--background-color`.
  `HudLayout.foregroundSGR` owns the encoding, host-free, and resolves a malformed hex to the
  `noTextColor` sentinel rather than a partial run; the helper converts nothing and wraps only digits and
  semicolons, so a malformed header cannot emit an arbitrary escape into the pane.
- Read back `ControlSessionNode.hud` with BOTH shares, `sizePercent` and `heightPercent`, `overlay` false
  and `overlaySizePercent` omitted beside it, plus `textColor` (omitted when the panel keeps the terminal
  foreground, and tracking the LATEST update unlike `backgroundColor`);
  `position` and `spinner` always report the effective value, defaults included — `spinner` names the STYLE
  and spells a static panel `HudSpinner.noneName`, which the dispatcher accepts back as "no spinner" so a
  caller can round-trip what `tree` gave it. HUD state is poll-only.
  `openOverlay`/`closeOverlay` emit no `scheduleTreeChanged()` and neither does a HUD, so document no event.
- The panel is a pty running bundled `Resources/hud/hud.sh`, spawned `autoFocus: false` with
  `AGTERM_HUD_FILE` as its only HUD-SPECIFIC variable (the surface still inherits the session environment
  and the overlay wrapper's `AGTERM_OVL_*` pair) and capturing no exit code. Grid, spinner (flag, interval
  and frames), text color and the APP'S PID
  ride the body file's HEADER line and are re-read every tick, so `hud.update` repaints in place with no
  respawn; write that file atomically. The frames are LAST because they alone are variable-length and the
  helper shifts the fixed fields off to reach them, so a new fixed field goes before them and owes the
  helper a matching shift count. It is per SESSION, so an update rewrites the path the running helper
  already opened. `Session.discardHudBody` is the only deleter and every store teardown runs it — close,
  ⌘W, session/workspace/window teardown — so a HUD closed before its surface realized cannot strand the
  message text in `/tmp`. An update carries the OPEN's background color forward, the factory reading it once
  at creation, so `hud.backgroundColor` never names a color the panel will not paint.
- The header's grid is `HudLayout.paintGrid` — the PANEL's own cells (`panelGrid`: the effective percent of
  the pane, less `window-padding-*`, over the measured cell), NOT `HudLayout.box`, which only decides the
  size. Both now measure the same message, so the two usually agree, but the panel is whole CELLS of a
  rounded percent and the box is not — centering on the box can still strand the message by a column or a
  row, and a `--size-percent` width detaches them outright. `box` remains the fallback when nothing is
  measured. Every path that changes the panel's size — open, update, `overlay.resize` — must rewrite the
  header through `ControlServer.writeHudBody`, which reads the size the STORE resolved; a window resize is
  the one skew left, until the next update.
- The helper forces `LC_CTYPE=UTF-8` on itself: `${#line}` counts BYTES otherwise, and a Dock-launched app
  inherits launchd's locale-less environment. Under it `${#line}` counts CODE POINTS, so the app measures in
  `HudLayout.cellCount` (Unicode scalars, precomposed first) rather than `String.count`, whose grapheme
  clusters disagree on every combining mark and ZWJ emoji. Neither side counts display columns, so a
  double-width glyph overflows the frame — accepted, not fixed.
- It skips a repaint whose frame is byte-identical to the last, so a spinner-less panel writes once and
  stops waking the renderer, and traps WINCH to invalidate that cache. This is a cache, not a measurement:
  the box still comes only from the body file.
- The helper stops on either the file disappearing or a builtin `kill -0` on that pid failing. The pid is
  the only stop a HARD-killed app has: `destroySurface` never runs, so the body file survives, and no SIGHUP
  arrives because the pty's session leader is the surviving `login`. Without it every crash, `kill -9` and
  XCUITest `terminate()` leaves a 2-10 Hz repaint loop running forever.
- `surface.zoom show|hide|toggle` reparents exactly one surface below a slim titlebar. Explicit IDs are
  `surface:<session-id>:<left|right|scratch|overlay|overlay-left|overlay-right>`, including hidden live
  panes. The active target is the single case `TerminalZoomSurface.isActive` accepts: the session overlay,
  then scratch, then the focused pane's own overlay, then that pane. Those
  predicates are mutually exclusive and total, resting on `Session.focusedPane`, so widening one without
  narrowing its neighbour silently picks the wrong surface.
- `surface.cursor` reports a zero-based COLUMN and nothing else, nested as `result.cursor.column` so a `row`
  could join it additively; the human form is the bare integer and must stay one value. libghostty exports no
  cursor accessor, so the column is solved for: `ghostty_surface_ime_point` gives the cell midpoint including
  an unknown padding term, and reading the viewport's top-left cell MEASURES that term as
  `ghostty_text_s.tl_px_x`, which cancels. Verified exact under asymmetric `window-padding-*` with
  `window-padding-balance`, across font sizes, on both split panes and on a hidden background session.
  There is NO row, and the vertical twin is not a near miss to be finished later: `tl_px_y` is the text
  BASELINE against an IME point at the cell bottom, and `adjust-font-baseline = 30` was measured reporting
  row 5 for a caret on row 4 while the column stayed right — a silent off-by-one, so a row waits for a real
  accessor. Use `TerminalZoomSurface.surface(in:)`, never a second inline switch over the six slots.
- It shares `surface.zoom`'s target vocabulary AND its gates, which is not cosmetic: `active` must consult
  the window's `TerminalZoomRegistry` target BEFORE the store's focused pane, or zooming a nonfocused pane
  reads the hidden one; and both paths must pass `TerminalZoomController.isTargetValid`, or a guessed
  `surface:<id>:overlay` reads a HUD the tree omits and zoom rejects. `quick` gates on
  `QuickTerminalController.isVisible`, not on `currentSurface()`, which `hide()` deliberately keeps alive.
  All three shipped as bugs once; `ControlSurfaceCursorUITests` pins each.
- It is a pure read that adds NO tree field, a deliberate exception to the state-command read-back rule
  (it sets no state) and to the temptation to project it: `ghostty_surface_read_text` allocates and takes the
  renderer lock, so paying it per live and hidden surface on every tree poll is the wrong trade.
- `quick` is the one target that names no window surface: it grows the quick-terminal PANEL to fill its
  screen. `setSurfaceZoom` routes it before resolving a window, so it takes no `--window` and never reaches
  `resolveSurfaceZoom`; it is refused `surface not available: quick` while the panel is hidden, and an
  omitted `--target` never resolves to it. See [[windows]].
- Host-free `TerminalZoomController` owns mode/state. Zoom must not change ratios, focus, sidebar, or pane
  visibility; deck slots remain constant and focus reporting is suppressed. Opening closes palette/search;
  banner reveal and Command-W exit. Font remains live. Reject search-open while zoomed, but keep hides
  idempotent even if the target vanished. Zoom neither closes nor blocks the quick terminal any more — the
  panel floats above every window instead of being hosted by one, so `quick show` is no longer refused with
  `terminal zoom active`. Read
  top-level live `zoomedSurface`; surface node active/visible describes pane state, not zoom.
- `dashboard` opens explicit IDs or `--mru`, or closes. Font-size and auto-size are exclusive; close accepts
  no IDs/MRU/font; open needs IDs or MRU; fixed size must be finite positive.
- A split expands to primary and split `DashboardMember`s, unless the id carries a `:left`/`:right` suffix
  (#331) selecting one pane. Host-free `DashboardTarget` owns that grammar: split on the FIRST colon,
  accept `primary`/`left`/`top` and `split`/`right`/`bottom` case-insensitively while readback stays
  `left`/`right`; reject `scratch`/`overlay` and a pasted `surface:<id>:<pane>`. The dispatcher rejects bad grammar outright; a
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
- Dashboard is per-window and view-only; GUI Command-Shift-G/menu/palette toggles MRU auto-size.
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
  and shape. Tree reports state, pane, true blink, per-call color, per-call shape, and `statusChangedAt`
  only while non-idle.
- `statusChangedAt` is `Session.statusChangedAt` as epoch seconds — a plain `Double`, since
  `ControlProtocol.swift` imports no Foundation. It shares the `ControlEvent.ts` clock so a poller can
  compare the two, and `setAgentIndicator` stamps it BEFORE the unchanged-indicator early return, which is
  what makes a re-pushed `active` refresh the age instead of freezing it. Ephemeral: cleared on idle, never
  persisted, absent after restore.
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
  custom commands; diagnostics. An action's `chord` is the menu key equivalent alone, so it keeps comparing
  against `menu`, while `alternates` holds its monitor-bound binds in kitty syntax and is omitted when
  empty; the human actions column joins the whole set with `|`. Both halves are canonical kitty syntax, not
  the file's own spelling — only a custom command's `shortcut` is preserved verbatim. `overridden` compares
  the MENU chord alone, so an action bound only by alternatives reports no override.
  The two chord sets may differ during deferred rebuild or collision.
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

- Session nodes include foreground/split foreground argv, background spec, overlay size, pane overlays,
  split axis, split ratio, split focus, status fields, flag, unseen, restore pins, surfaces, and `realized`.
- `realized` reports the MAIN pane's `TerminalSurface.isRealized`, populated host-free in
  `AppStore.controlTree` (no app closure — `isRealized` is on the protocol) and false for an empty slot, so
  only a server predating the field omits it. It exists because `session.new` answers `ok` for a model
  insert while libghostty refuses to create a surface with the display asleep, leaving a scheduled job's
  session unrealized until the displays wake (#416). It is the main pane because that is what `--command`
  spawns on and what `session.type`/`session.text` address by default; per-pane liveness stays with the
  `fontSize`/`splitFontSize`/`scratchFontSize` triple, so do not add a second per-pane spelling.
  `agtermctl tree` tags the row `(not realized)`, beside `(split hidden)`. Foreground shares the
  restore capture's pid/sysctl/host-free extraction but adds one step the capture must never take.
  libghostty's foreground pid is `tcgetpgrp`, a process GROUP id, and a pane with no job-control shell
  leaves its program in the group led by setuid-root `login`, whose argv `KERN_PROCARGS2` refuses. The tree
  read (`ForegroundProcess.running`) descends to the leader's own CHILDREN, lowest pid first, so a
  `--command` pane reports what it runs while a pipeline sibling under `sudo` and a post-pid-wrap
  grandchild stay out; a group whose leader already exited has no parentage to test, so every survivor
  qualifies. The capture (`.command`) stays leader-only, because a non-nil capture sets `hadForeground`,
  which preempts `initialCommand` in `restorePlan` and would drop the exec path.
- Top-level tree includes idle/auto-follow, live sidebar visibility/mode, workspace filter, quick
  visibility, zoom, dashboard, and picker state. Prefer live tree sidebar state over cached window list.
  `quickVisible` and a `quick` `zoomedSurface` are APP-level, so every projected window reports the same
  value for them; the rest stay per-window.
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

- Keep the bundled skill synchronized with commands, arguments, results, keymap, and model.
- `site/commands.html` documents every command, invocation, arguments, and read-back; `site/docs.html`,
  README and the skill link to it rather than restating the catalog.
