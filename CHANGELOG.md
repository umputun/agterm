# Changelog

## v0.22.0 - 2026-08-09

### New Features

- voice dictation and other assistive tools work over the terminal. MacWhisper's hold-to-dictate widget never appeared in agterm though it does in NSTextView-based terminals: the Metal-backed surface was absent from the accessibility tree, and such tools probe `AXFocusedUIElement` for a focused text field before engaging, finding nothing at all over agterm. The interactive surface now reports itself as the minimal shape of an editable text field #246 @pbldbl
- `session hud --position` takes the nine anchors of a 3x3 grid, spelled exactly as `session background` spells them, so a panel can sit in a corner instead of over the text being read, and every anchor off center holds a fixed edge margin on each axis it names. The bare `top` and `bottom` it shipped with stay accepted as aliases for the middle column and normalize on read-back, so existing callers keep working and `tree` reports one spelling. `hud update` also recolors the panel's text in place #386 @umputun
- a workspace or session row's name can be copied from the sidebar context menu. The row's text field is not selectable outside rename mode, so reading a name to reuse elsewhere meant retyping it or entering rename mode and copying out of the field, which risks committing an edit to a name you only wanted to read #385 @skkap

### Improved

- `tree` reports `hasSplit` beside `split`, so a caller can tell a session with a hidden second pane from one with no split at all. `split` means the split is shown side by side, and a pane hidden with ⌘D read as `false` there while `splitRatio` and `splitFocused` stayed populated beside it; `agtermctl tree` tags that case `(split hidden)` a585694 @umputun
- a cookbook recipe that lists a session directory's past Claude Code conversations in the native picker, each named for what it turned out to be about rather than its opening prompt, and types the resume into the pane the chord fired from #381 @umputun
- a cookbook recipe that reopens each tab's own Kimi Code conversation after a restart, completing the session-resume family. Kimi's SessionStart hook receives the new conversation's id, so the recipe pins the tab's restore command from the hook instead of wrapping the launch #391 @x9x9x9x9x9x91
- a cookbook recipe joining Kiro CLI to the agent-status integration. Kiro declares hooks per agent with no global file, so it is the one agent that cannot reach the sidebar glyph through the bundled adapters #383 @bitcldr
- a cookbook recipe that syncs the active pane's working directory to the other half of a split, splitting first when none is shown, and refusing when the target pane is running a foreground program #388 @vladislav-yevtushenko
- the annotate-claude-replies recipe dropped revdiff's file-level notes, its header regex requiring a `:line` part that a file-level note does not carry #387 @denysshnurenko

### Bug Fixes

- a command-line tool run inside a session could never be granted Automation, Camera, Contacts, Calendars, Location or Photos. Under hardened runtime those services need an entitlement the app did not carry, and macOS treats agterm as the responsible process for everything it spawns, so `tccd` refused to prompt and recorded nothing. No dialog appeared, and with no record there was no entry in System Settings to grant by hand either. Grants agterm already held kept working, which is what made this easy to miss. The bundled `agtermctl` also stopped inheriting the app's entitlement set, which the build's re-seal had been stamping onto it #398 @skkap
- the View menu showed two full screen items, agterm's own and AppKit's, both carrying the same icon as Toggle Terminal Zoom. AppKit appends its item as the menu is prepared for display and the documented opt-out is ignored on macOS 26, so agterm's own item is gone instead and a key monitor keeps its chord #412 @umputun
- ⌘W with the Settings window open closed the active terminal session instead of Settings, and the same for the About and Open Directory panels. File ▸ Close Session is a main-menu item with no window scoping, so the keystroke reached the terminal deck whichever window was key #403 @umputun
- a custom command bound in `keymap.conf` could not run a bare `agtermctl` or a bare Homebrew binary. It spawns as a detached `/bin/sh -c` inheriting launchd's `PATH`, and that is neither a login nor an interactive shell, so the command exited 127 with the shell's own diagnostic discarded #395 @umputun
- a selected row at the bottom of the command palette painted over the panel's rounded corner and squared it off: the panel drew a rounded background and a stroke but never clipped to either. The `pick` free-text path showed it on every press that matched nothing #415 @umputun
- palette rows have been full-width click targets since they were built, but nothing painted under the pointer, so there was no way to tell what a click would run without clicking it #414 @umputun
- clicking a workspace row expanded or collapsed it without animation while the disclosure triangle beside it animated, so one toggle rendered two ways depending on where it was hit #413 @umputun
- the starter `keymap.conf` suggested uncommenting `map cmd+shift+d toggle_split`, a line that can never apply: `cmd+shift+d` is the dashboard's own default, so the override is dropped as a built-in collision. Both examples now use a free chord, and the header points at where a skipped line is reported #411 @umputun
- a literal substring match in a long path could rank below a scattered match on another row, the substring band being unbounded and able to score past the subsequence floor #390 @x9x9x9x9x9x91

## v0.21.0 - 2026-08-06

### New Features

- the command palette, the control-API picker and the Ctrl-Tab switcher rendered at a hardcoded 13pt with no way to change them. A new Settings ▸ Interface font size (9...20, default 13) drives all three plus the title-bar popover rows, separate from the sidebar's own size and with no fallback between them, since the sidebar is a density knob and the palette a readability one. All three now center over the terminal area rather than the whole window, which read as off-center whenever the sidebar was up, and each panel is bounded against the window so a cramped one degrades to whole-window centering instead of clipping #367 @umputun
- `session.hud` posts a small floating panel over a session while an agent prepares something slow: computing picker items, spawning an overlay program, waiting on a network call. It shows a message, an optional detail line and an optional spinner, and updates or closes from a later call. The panel is passive, so the session keeps first responder and typing into the terminal underneath still works #361 @umputun

### Improved

- a fish port of the claude-session-resume cookbook recipe, so a fish user gets the same per-tab conversation resume the existing versions give #365 @Arelav
- a cookbook recipe that opens Claude's replies in revdiff for inline annotation and sends the notes back #364 @p4elkin

### Bug Fixes

- a dark launch with a conditional `theme = light:X,dark:Y` spawned every restored surface with no `AGTERM_*` variables, no restore replay and no `session new --command`; only the cwd survived. The renderer rebuilds a surface's config whenever the app's conditional state disagrees with the config's, and that rebuild replays the config files alone, dropping the per-surface environment, initial input and command the host set. A host-built config always resolves light while the app is already dark, so the two disagree at launch and agree later, which is why this looked specific to restore. The app config is now re-sided before any scene mounts #378 @umputun
- with Restore running commands on restart enabled, quitting by closing the window lost every captured command and each pane came back a plain shell: the close tore each surface down before the quit-time capture could read it, so the save persisted nulls. ⌘Q was unaffected. Closing a window that was not the last captured nothing at all #370 @i-kozlov
- a captured foreground command could replay on more than one launch, re-running the program every time until it was cleared by hand a8b5252 @umputun
- exiting by closing every window brought back the wrong window on the next launch: a multi-window user got window 1 rather than the one he was working in, because closing the last window dropped the record of which was frontmost #377 @umputun
- ⌘D, the title-bar split button, View ▸ Split and the palette each flipped the split behind a shown scratch pane. The screen could not change, so the only sign was the glyph moving, and the layout you came back to was not the one you left. The press now dismisses the scratch, the same cover-first rule ⌘W already uses, and a second press splits #376 @umputun
- ⌘C with nothing selected typed a stray key report into the running program, which shows up in Claude Code and other TUIs that turn the kitty keyboard protocol on. The Edit menu disables Copy without a selection, so the press reached the key binding, failed to perform and fell through to key encoding. It is not layout-specific, contrary to how the report scoped it #375 @umputun
- with Settings ▸ Appearance ▸ Window ▸ Toolbar set to Hidden, a 1px line ran across the top edge of the window, most visible in native fullscreen on a notched display where it separated the black band from the terminal. It is the separator that belongs under the custom titlebar row, which has no height in that mode, and the dashboard drew its own copy in the same place #379 @umputun
- an unrecognized value in `workspaces.json`, written by a newer build or a hand edit, failed the whole snapshot decode, and the recovery path starts fresh: every workspace and session was wiped over one non-essential display field. Each optional now drops to nil on its own instead of taking the tree with it #363 @x9x9x9x9x9x91
- a non-interactive fish `claude` call did not pass through to the real binary, so anything scripting it broke under the session-resume wrapper #366 @Arelav

## v0.20.2 - 2026-08-03

### Improved

- double-clicking the divider between two split panes snaps the split back to even. A drag can never hit exactly 50/50, and the gesture is recognized only on the pixels the split already owns for its own drag, so word selection in the terminal is untouched. A re-grab after a nudge-drag, which macOS also reports as a double-click, does not throw the adjustment away #357 @umputun
- a cookbook recipe that grids the flagged sessions' panes that are running something, on one chord. The unit is a pane, so a split whose left half sits at a prompt while its right runs a build contributes one cell, and pressing the chord again closes the grid #355 @umputun

### Bug Fixes

- a pane started with `session new --command` always read as idle in `tree --json`: its `foreground` was omitted however hard the program worked, so nothing driving the control API could tell a busy agent session from an empty shell. Such a pane has no job-control shell, so its program stays in the process group led by setuid-root `login`, whose argv is refused to a non-root caller. The tree read now descends the group to the first readable member, while the quit-time restore capture deliberately does not, so a `--command` session still restores through the exec path with its `--wait` hold intact #358 @umputun
- a pane overlay opened on the unfocused side of a split rendered at full brightness, so both panes read as live and the split focus cue was gone. The overlay now carries the same wash an inactive pane gets, blended against the overlay's own background rather than the session's, so an overlay opened with `--background-color` fades its text instead of shifting its background #356 @umputun
- an interior newline in a session, workspace or window name, or in a session's `--cwd`, survived into the stored value and expanded unquoted into the `/bin/sh -c` line of a custom command through the `{AGT_SESSION_NAME}` / `{AGT_SESSION_PWD}` / `{AGT_WORKSPACE_NAME}` / `{AGT_WINDOW_NAME}` tokens, where a newline separates statements. The OSC path already sanitized these values; the control-socket and GUI rename paths trimmed surrounding whitespace only #354 @x9x9x9x9x9x91

## v0.20.1 - 2026-08-02

### Improved

- Settings ▸ General fits without scrolling again: the caption under the workspace row-click toggle is gone. It spelled out that the disclosure triangle keeps working either way, which the section did not need a whole line to say b35dd34 @umputun

## v0.20.0 - 2026-08-02

### New Features

- overlays can cover one pane of a split instead of the whole session: `session overlay open|close|result` take `--pane left|right`, the sibling pane stays visible and interactive, and both panes can hold their own overlay with its own command, cwd and background color. Pane overlays are always full-pane, so `--pane` is rejected with `--size-percent` and `session overlay resize` takes none #343 @umputun
- `agtermctl dashboard` accepts a `:left` or `:right` suffix on each positional id, so one pane of a split can go on the grid instead of the session always contributing both. It is the same form `tree --json` reports in `dashboardMembers`, so write and read round-trip, and it composes with any head #334 @umputun
- caller-supplied pickers match a row's label only and never its subtitle, closing a path where typing a refusal filtered the safe row out and left the destructive one preselected. An empty query now keeps the caller's item order instead of re-sorting alphabetically, `--query` prefills the field, and a picker with no items is allowed #339 @umputun
- clicking anywhere on a workspace row toggles its expansion, behind a new Settings ▸ General ▸ Mouse toggle that is on by default. The disclosure triangle is untouched and works either way #342 @umputun
- a first launch on a machine opens a welcome alert naming the Help menu's optional installers, with two checkboxes that install the agent skill and the agent status hooks in one pass, because nothing else tells a new user they exist #353 @umputun

### Improved

- a cookbook recipe that picks a project in the native picker and opens a session in its workspace, creating that workspace when it does not exist, and hands a prompt typed after the project's name to a configured command #352 @x9x9x9x9x9x91
- a cookbook recipe that lists what the Claude Code run in a session was working on, newest first, in a floating overlay, each item an age, a title, a one-sentence detail and a status #345 @umputun
- a cookbook recipe joining Kimi Code to the agent-status integration, so its sessions report status onto their sidebar row with the stock hook script and four config entries #336 @x9x9x9x9x9x91
- the opencode session-resume recipe's removal step and Usage paragraph named a flat state path while the function honors `$XDG_STATE_HOME`, so a reader with a custom state home cleaned the wrong directory and left his bindings behind. Both now name the path the function actually uses, and the `--session` passthrough claim is corrected #330 @cherkale

### Bug Fixes

- typing into a session right after `session new --no-select` failed with "session not realized", because the reply came from a synchronous store mutation that raced the mount and layout gap. The main pane now runs the same bounded poll with or without select, so the select-then-reselect workaround, which tears down the workspace focus filter and rewrites recency, is no longer needed #351 @umputun
- hovering the divider between two split panes showed the terminal's I-beam instead of the resize cursor, in any window with more than one session. Dragging always worked and only the pointer feedback was wrong; #324 fixed the flicker, but its fix held only while a single session was mounted #344 @umputun
- `agtermctl` died on signal 13 with no output when a request went over the server's 1 MiB cap. The client fd never set `SO_NOSIGPIPE`, so it took the signal before it could read the server's "request too large" reply #340 @x9x9x9x9x9x91
- a session's blinking status glyph strobed instead of pulsing when its terminal title updated rapidly, as Codex CLI does every ~100ms while working. The row builder reset every recycled cell to an idle indicator before re-applying the real one, which restarted the fade each time #335 @umputun

## v0.19.1 - 2026-07-31

### Improved

- a floating overlay and the quick terminal now mute the session behind them, the same wash an inactive split pane already gets and at the strength already in Settings, so a panel reads as sitting over the terminal rather than as part of it. A full-size overlay and the scratch pane hide their panes outright and take no wash #327 @umputun
- a cookbook recipe for the native picker that shipped in 0.19.0: press a chord and agterm's own fuzzy picker lists directories under your search roots, then types the pick into the session you pressed the key in, trailing slash and no Return #320 @umputun
- a third session-resume cookbook recipe next to the Claude Code and Codex ones, so each tab reopens its own opencode conversation after a restart #328 @cherkale

### Bug Fixes

- creating a workspace never moved the target, so a new one was never current while any session was selected: File ▸ Rename Workspace edited the workspace you came from, ⌘N put the new session there too, and `agtermctl session new --workspace active` right after `workspace new` targeted the previous one. A new workspace now holds the target until the selection moves to a different session, and `workspace select` retargets even when the workspace it names already owns the selection #329 @umputun
- hovering the sidebar handle or a split divider only flashed the resize cursor, which then alternated with the terminal's I-beam on every mouse move. Dragging worked, only the pointer feedback was broken; a regression from #207 #326 @umputun
- narrowing the sidebar could leave the window drawing a session no row pointed at: focusing a workspace that does not own the active session, applying the workspace filter while its workspace is unmarked, switching to the flagged view while the session is not flagged, or unflagging it there. The selection now moves to the most recent session still visible #322 @umputun

## v0.19.0 - 2026-07-29

### New Features

- a native picker any script can drive: `agtermctl pick` takes choices on stdin as plain lines or JSON, shows them in the same fuzzy palette the app uses, and prints back the one chosen, so a shell script can ask a question without drawing its own UI. Blocking and non-blocking forms, optional free-form answers, per-window targeting, `pick result`/`pick cancel` for the non-blocking case, and a `pickPending` read-back on `tree` #316 @umputun
- the agent skill also ships as a Claude Code and Codex plugin, installable with `plugin marketplace add umputun/agterm` instead of only from Help ▸ Install Agent Skill…. One directory feeds the app bundle and both plugin managers, so anyone whose agent config lives outside `~/.claude` or `~/.codex` gets an install their agent can actually find #318 @umputun
- OpenCode joins Claude Code, Codex and Pi in the agent-status integration. A bundled lifecycle plugin marks a session active while it works, blocked when it asks permission or hits an error, and completed when it settles, tracking child sessions so a subagent finishing does not clear a still-busy parent #289 @culler127
- New Window in the Dock menu, so a window can be opened without bringing agterm forward first. Unlike the other Dock items it belongs to no window, so it stays available whatever the last-active one is doing #319 @umputun

### Improved

- a workspace in the focus set draws the grid glyph at heavy weight rather than filled, so a marked workspace keeps one identity whether marked or not and no longer reads like a flagged session 6d403ae @umputun
- two more cookbook recipes: switching the sidebar between named groups of workspaces on one chord, and speaking agent status changes from a dedicated session #307 #308 @umputun
- a cookbook recipe that picks a workspace with fzf and starts a session in it #311 @skripalschikov

### Bug Fixes

- keybindings from `keymap.conf` did nothing on a non-English keyboard layout. Custom commands and ⌘Z undo-close matched the character the active layout produces, so on a Cyrillic layout the physical O key yields `щ` and a Latin-spelled `cmd+o` could never match. Chords now resolve per layout, binding by physical position on layouts that cannot type ASCII #310 @umputun
- a program that colors the terminal background and restores it on exit left the pane stuck on its color, because agterm honored OSC 11 to set the background but not OSC 111 to reset it #312 @umputun
- the Action Palette flickered while arrow keys moved the selection, repainting the whole list and re-running a scroll animation on every keypress #314 @umputun

## v0.18.1 - 2026-07-28

### Improved

- a `cookbook/` of installable `agtermctl` recipes: show one project's workspaces and hide the rest, snapshot a project and bring it back later, park every window but one in the Dock, pick a path in an overlay and type it into the session, open TUI launchers in an overlay or a split, and resume a Claude Code or Codex conversation per tab; each recipe carries its own README, its scripts, and the minimum agterm version it needs, and the repo now has a `CONTRIBUTING.md` #305 @umputun

### Bug Fixes

- a session was left showing a blank pane that took no keyboard input when the primary shell exited while a split was hidden, with the hidden split's shell still running and reachable from neither pane; the survivor was promoted in the model but the view kept hosting the torn-down surface #304 @umputun

## v0.18.0 - 2026-07-27

### New Features

- the sidebar focus filter now marks a set of workspaces instead of a single one, and the marked set survives turning the filter off, so a working set can be built member by member and the whole tree is one toggle away instead of a lost selection; a marked row draws the filled grid icon, the row context menu toggles membership, a bottom-bar button applies or suspends the filter, and `agtermctl workspace filter` plus the new `workspace focus add` mode drive both halves with per-workspace read-back on `tree` #297 @umputun
- `agtermctl keymap list` reports what a keybinding actually resolved to, the read side of `keymap reload`: every built-in action with its chord and whether it was overridden, keyless actions included so free chords are visible, alongside the key equivalents the live menu bar carries with their submenu path and enabled state, plus the config path, custom commands, and parse diagnostics with line and message; both halves render in the same syntax, so a binding that does not fire can be diagnosed by comparing them instead of pressing keys and reporting what happened #301 @umputun

### Improved

- the dashboard button is easier to tell apart from the workspaces glyph: the two were different symbols but both a 2x2 arrangement inside a square, close enough to be confused at title-bar and menu size, so the dashboard now carries a wider 2x2 split 5353785 @umputun

### Bug Fixes

- ⌘W closed the whole window instead of the active session once `close_session` had been rebound away from ⌘W and back again, and only a relaunch cleared it; the chord is now asserted from AppKit at launch, on keymap change, on activation, and on menu tracking, rather than waiting for a menu rebuild that never came #298 @umputun

## v0.17.1 - 2026-07-25

### Improved

- windows can be parked in the Dock over the control API with `agtermctl window minimize` (explicit `on`/`off`/`toggle`), created already parked with `window new --minimized`, and read back through the `minimized` field on `window list`, so a script can show one project's window and hide the rest #294 @umputun

### Bug Fixes

- `window new` replied before its window had attached, so an immediate `window resize` on the returned id failed with `window not open` #294 @umputun
- `window list` served a stale cache that never refreshed once a window attached, so a newly created window reported no geometry indefinitely #294 @umputun
- minimizing the frontmost window left it marked frontmost, so `tree`, `session new`, `quick`, and the palette kept routing into a window sitting in the Dock #294 @umputun
- `window select` reported success without taking frontmost while the app was inactive, which is the state a driving script runs in #294 @umputun

## v0.17.0 - 2026-07-25

### New Features

- an application Dock menu with New Session, Quick Terminal, and Dashboard, plus the window's recent sessions and the ones needing attention, so common actions and session jumps work from the Dock without bringing a window to the front #284 @melonamin
- selectable shapes for the agent-status glyphs, so blocked, active, and completed differ by silhouette instead of hue alone; picked per status in Settings ▸ Agent Status, or per call with `agtermctl session status --shape` #292 @umputun
- arrow keys are now part of the keymap chord grammar, so a binding like `map cmd+shift+left previous_session` works; the six actions that already shipped on arrows report their real chords, which also makes them visible to the conflict checker instead of silently double-binding #291 @umputun
- an opt-in Settings ▸ Interface toggle to show the sidebar only in the active window, collapsing it in the others so a multi-window layout spends its width on terminals #285 @umputun
- hovering a sidebar agent-status glyph now names the status it stands for #283 @umputun

### Bug Fixes

- honor the macOS Reduce Motion and Reduce Transparency accessibility settings #279 @melonamin
- a Codex session is marked blocked when its final assistant message asks a question anywhere in the text, not only when it ends in one #282 @umputun
- a notification banner suppressed because its session is already visible now says so in the log and in the control response, instead of reporting a delivered banner #287 @umputun
- renaming a session from the menu bar, the palette, or a keybinding no longer starts an inline edit in every other open window, which left a stray editor holding focus there and permanently wedged idle auto-follow off #295 @umputun
- `agtermctl session focus --pane` now moves focus in a background window while the frontmost window has its quick terminal showing, instead of silently reporting success without moving it f2745a8 @umputun

## v0.16.1 - 2026-07-22

### Bug Fixes

- mark a Codex session `blocked` when its final assistant message ends in `?`, so ordinary questions stay visible as waiting for user input #276 @umputun

## v0.16.0 - 2026-07-22

### New Features

- subscribe to status, notification, session-lifecycle, and tree-change events through the control API, with bounded cursor history and polling through `agtermctl events` #273 @umputun
- collapse or expand individual workspaces through the control API #272 @umputun
- pin a restore command for each session pane through `agtermctl session restore`, including persisted tree read-back and separate split-pane overrides #271 @umputun

### Bug Fixes

- render the session watermark on the scratch terminal instead of leaving the pane unidentified #275 @umputun

## v0.15.3 - 2026-07-20

### Improvements

- `agtermctl session new --command CMD --wait` holds the session open on the press-any-key prompt after the command exits, so a build/test/deploy's final output or an early failure stays readable instead of the session vanishing; the session-surface counterpart of `overlay open --wait`, opt-in with the default unchanged #255 @umputun

### Bug Fixes

- pressing a bare modifier key (⌘/⇧/⌥) no longer logs a repeated AppKit assertion on every keypress, and bare modifier press/release events reach the terminal again #261 @umputun
- double-clicking a word in the shell prompt (for example a branch name) no longer moves the input cursor to the start of the line, so a following paste inserts at the right position #263 @umputun

## v0.15.2 - 2026-07-18

### Improvements

- a Settings ▸ Interface toggle for the per-workspace add-session `+` (the glyph revealed on hovering a workspace row), so it can be hidden like the other chrome elements #252 @umputun
- idle auto-follow now shows each waiting block once instead of repeatedly pulling you back to the same blocked session; a session re-arms only when it leaves blocked and blocks again #251 @umputun
- an opt-in `--no-select` flag on `agtermctl session new` that creates a session in the background without selecting or focusing it, leaving the current selection and focus in place #250 @umputun
- `open -a agterm <path>` (or Finder's Open With ▸ agterm on a folder) adds a terminal session in that directory to the last-active window while agterm is running #244 @umputun

### Bug Fixes

- custom-command key chords now fire from a window that has drained to zero sessions (for example after an SSH session disconnects) instead of going dead #249 @umputun

## v0.15.1 - 2026-07-17

### Bug Fixes

- renaming a session in the flagged view no longer bakes the ` : workspace` suffix into the name; the inline editor now seeds the bare session name instead of the decorated row label #243 @umputun

## v0.15.0 - 2026-07-17

### New Features

- a new Interface tab in Settings to hide or show individual title-bar and sidebar-footer chrome elements (the sidebar toggle, the session and window names, the recent-sessions, scratch, split, dashboard, and quick-terminal buttons, and the new-workspace, new-session, and flagged-view footer buttons), each shown by default #241 @umputun
- a Duplicate Session action, reachable from the sidebar context menu, the menu bar, the action palette, a keybinding, and the control API #234 @dimetron
- per-pane OSC 11 dynamic background under window translucency, so a program that sets its own background color tints just its pane instead of staying hidden behind the window backing #240 @umputun
- closing the active session now returns to the previously-active session instead of the next one in the list #231 @olomix
- an optional notification sound on a delivered banner, off by default, chosen in Settings ▸ Notifications #232 @ZUBOV-ILLIA
- an inline `+` button on each workspace row to create a new session in that workspace #233 @wievtsal

### Bug Fixes

- make the site navigation responsive on mobile #229 @Hormold

## v0.14.1 - 2026-07-15

### Bug Fixes

- stop the mouse cursor flickering between shapes over a restored session's visible terminal, by scoping every cursor write to the on-screen deck pane so a hidden stacked surface can no longer paint its cached shape over the front one #228 @umputun

## v0.14.0 - 2026-07-14

### New Features

- Pi agent-status support in Install Agent Status Hooks, so a Pi agent running in a session reports active then completed onto its sidebar row, matching the Claude Code and Codex auto-wiring #208 @taras-mrtn
- a title-bar button that opens the dashboard, grouped with the quick-terminal button behind a separator #217 @umputun

### Improvements

- dashboard cells now enter on a single click instead of a double click, flashing the active frame first so the click reads as acknowledged #217 @umputun
- the dashboard and terminal-zoom modes now show the window title in their stripped title bars #217 @umputun

## v0.13.0 - 2026-07-14

### New Features

- title-bar recent-sessions clock and attention bell, each opening a popover to jump to a recent or waiting session when the sidebar is hidden #212 @umputun
- opt-in Dock-icon bounce on a background notification, off by default, with a None / Once / Until focused picker in Settings ▸ Notifications #215 @umputun
- agent-status glyphs on dashboard cells, so a session that needs attention stands out in the grid #209 @umputun
- `$AGT_PANE` now reports which pane a custom command fired from (`left` / `right` / `scratch`), so a keybinding can route a follow-up `agtermctl` call back into that pane #210 @umputun

### Bug Fixes

- resolve a session's agent-status pane from a stable surface token, keeping the status glyph and pane-aware reveal correct across split and scratch teardown #213 @umputun
- apply libghostty mouse cursor shapes via `cursorUpdate`, so the pointer shape tracks what the terminal program requests #207 @umputun

## v0.12.1 - 2026-07-13

### Bug Fixes

- stop agterm's embedded shells from identifying as Ghostty via `TERM_PROGRAM`, which could make a Ghostty-aware tool shell out to a standalone `ghostty` on the `PATH` and launch a windowless Ghostty.app while you were using agterm #203 @umputun
- fix the Codex agent status getting stuck on `blocked` during an auto review, where the permission prompt fired before the review resolved it #204 @umputun
- strip the dashboard's titlebar to a single exit button while the grid is open, so its sidebar, split, scratch, and quick-terminal buttons can no longer steal focus and leave Esc unable to close the grid #205 @umputun

## v0.12.0 - 2026-07-12

### New Features

- dashboard grid overlay: a per-window grid that shows a picked set of live terminal panes at once, so you can glance across several sessions and jump into one. `⌘⇧D` toggles it over the window's most-recently-used sessions, `agtermctl dashboard <id> <id> ...` opens it over an explicit set, up to nine cells and view-only (arrows move the highlight, Enter drops in, Esc closes) #202 @umputun
- sidebar Finder folder drops create sessions rooted at the dropped directories, plus `Reveal in Finder` for the active session and spring-open of collapsed workspaces while dragging over them #180 @melonamin
- promote the surviving split pane into the main slot when the primary pane's shell exits, so a collapsed-to-single session behaves like a fresh single pane, reports `left`, and a later `session.split` opens a fresh pane beside it #121 @fkirill
- drive Codex agent-status from its lifecycle hooks instead of keyword-matching the final message, so an approval prompt shows `blocked` the moment Codex asks and an ordinary turn no longer gets wrongly stuck on it #194 @umputun

### Bug Fixes

- stop split panes flickering on a rapid focus change, where two overlapping focus retry loops ping-ponged first responder between the panes for ~400ms #200 @umputun

## v0.11.0 - 2026-07-11

### New Features

- multi-select sessions in the sidebar to batch close, move, flag/unflag, or clear status, and drag selected groups between workspaces #179 @melonamin
- terminal zoom: `cmd+shift+return` renders the active surface full-window over the sidebar and chrome, also driveable over the control API with `surface.zoom` / `agtermctl surface zoom` #158 @melonamin
- Edit menu Copy/Paste/Select All now work when the terminal has focus, with `session.paste` and `session.selectall` added to the control API #181 @umputun
- configurable sidebar font size in Settings > Appearance > Window #187 @umputun

### Improvements

- drop the "Closed <name> / Reopen" toast; the undo window is unchanged (cmd-Z during the grace period, File > Reopen Last Closed Item after) cf43d5f @umputun

### Bug Fixes

- re-tint sidebar row text from the row view's live selection state so multi-selected rows stay legible #189 @melonamin
- let `agtermctl font` target a split or scratch pane #188 @umputun
- clear the active agent-status glyph on Ctrl-C, not just Escape #185 @umputun
- keep workspace and session ids unique across close, undo, and reopen #184 @umputun
- keep keyboard focus on the overlay/scratch, not the pane behind it #182 @umputun

## v0.10.2 - 2026-07-08

### Bug Fixes

- restore a saved window onto a connected display so one left on a now-disconnected external monitor no longer reopens off-screen #178 @melonamin
- hide a leftover titlebar decoration band that showed over the terminal in hidden toolbar mode df81d56 @umputun

## v0.10.1 - 2026-07-08

### Improvements

- type into the quick terminal and read its screen back over the control API with `quick type` / `quick text` #177 @umputun
- soften the sidebar workspace name to a medium weight so it reads a touch heavier than the sessions without the heavy bold f793fd3 @umputun

## v0.10.0 - 2026-07-08

### New Features

- hidden toolbar mode - a full-bleed terminal with no titlebar row and no traffic-light buttons #173 @umputun
- reopen recently closed sessions #174 @melonamin
- follow the macOS light/dark appearance automatically via ghostty's dual theme value #74 @paul-nameless
- read-back for the focused split pane, status blink/color, and quick-terminal visibility over the control API #169 @umputun
- read-back for split ratio, window geometry, workspace focus, sidebar mode, and window fullscreen/zoom over the control API #168 @umputun
- expose an open overlay's size on the tree read side #167 @umputun

### Improvements

- reveal file:// links in Finder instead of doing nothing #162 @i-kozlov

## v0.9.0 - 2026-07-07

### New Features

- native full screen support #160 @umputun
- resize an open overlay in place via session.overlay.resize #163 @umputun
- bind shifted-symbol keys in keymaps via shift+<base> #161 @umputun
- expose sidebar visibility over the control API #159 @umputun
- preserve split-pane focus when re-showing a hidden split #159 @umputun

### Bug Fixes

- clear the notification badge when refocusing the app on a visible session #164 @umputun

## v0.8.4 - 2026-07-06

### Bug Fixes

- hiding or showing the sidebar is now instant on windows with many sessions, instead of lagging as every terminal pane re-rendered 9440f1a @umputun

## v0.8.3 - 2026-07-06

### Improvements

- session.seen control command to clear a session's unseen-notification badge headlessly, without opening it #156 @umputun

### Bug Fixes

- mouse-wheel scroll and split-pane selection now work right after clicking back into an inactive window, instead of needing a mouse nudge #157 @umputun
- keep the sidebar disclosure triangle visible when the theme and system appearance mismatch #152 @umputun
- show the chrome hairlines on light themes #150 @umputun
- the selected-session label is now readable on light themes #146 @bigspawn

## v0.8.2 - 2026-07-05

### Bug Fixes

- microphone access for command-line tools running inside agterm now works: a hardened-runtime app also needs the audio-input entitlement, not just the usage description added in v0.8.1 @umputun

## v0.8.1 - 2026-07-05

### Bug Fixes

- declare a microphone usage description so command-line tools running inside an agterm terminal can request microphone access #143 @umputun

## v0.8.0 - 2026-07-05

### New Features

- unify overlay behavior: floating (in-deck) overlays now act like full-screen ones, opening in the background without switching the active session, plus a new --follow flag to switch to the target as the overlay opens #139 @umputun
- place a new session directly after or before another with session new --after/--before (and session move), instead of walking it up with repeated moves #134 @olomix
- persist workspace expand/collapse state across relaunch #133 @umputun

### Improvements

- continue routing control commands through the host-free dispatcher: the remaining commands and window controls now dispatch in agtermCore #137 #132 @melonamin
- link the About panel to agterm.com instead of the GitHub repo @umputun

## v0.7.1 - 2026-07-04

### Improvements

- tag agent status with the pane that set it, so a block raised in a split or scratch pane survives typing in another pane and navigation reveals the waiting pane #130 @umputun
- per-call --color override for the session.status glyph tint #129 @umputun
- pointing-hand cursor on ⌘-hover over a link, with ⌘-click opening validated web and mail links #125 @vnazarenko
- continue routing control commands through the host-free dispatcher #128 @melonamin
- clearer auto-follow settings: a "60 sec idle" timeout label and a forward-reading "auto-follow away from a running session" toggle @umputun

## v0.7.0 - 2026-07-04

### New Features

- auto-follow attention: after an idle timeout a window jumps to the oldest blocked session, opt-in per window #122 @umputun
- pane-addressable session.type and the AGT_PANE keymap token #90 @fkirill
- --pane scratch for session.text and session.type #117 @umputun
- wrap session next/prev navigation at the ends #85 @vnazarenko

### Improvements

- toggle workspace expansion on a full-row click @umputun
- launch the agterm.com website #118 @umputun
- continue routing control commands through the host-free dispatcher @melonamin

### Bug Fixes

- cap the Ctrl-Tab MRU list at 10 sessions @umputun
- use the title-case app name in the macOS menu bar #116 @umputun

## v0.6.1 - 2026-07-03

### Improvements

- releases are now Developer ID signed and Apple-notarized, so they open with no Gatekeeper workaround @umputun
- gate OSC 52 clipboard access (prompt reads, ask/deny writes) #112 @umputun
- persist Ctrl-Tab MRU order across relaunch #111 @umputun

### Bug Fixes

- sanitize OSC title and pwd control characters to close a shell-injection sub-case #109 @umputun
- hide the scratch terminal under a full-screen overlay so it can't show through #113 @umputun

## v0.6.0 - 2026-07-02

### New Features

- confirm before closing a session, opt-in via a setting #101 @umputun
- configurable directory for new sessions #70 @umputun
- per-overlay background color for session.overlay.open #88 @umputun

### Improvements

- move keymap, overlay-capture, and command-matching logic into agtermCore and hoist shared catalogs @melonamin
- split oversized source and test files to enforce the swiftlint 1000/2000-line limits #86 @umputun

### Bug Fixes

- drag-drop inserts multi-line text as a paste instead of auto-executing each line #102 @umputun
- escape newlines in dropped file paths to prevent command injection #96 @vlondon
- keep '#' inside single-quoted custom-command shell args #98 @vlondon
- single-quote-escape image paths in the show-image.sh overlay command #100 @vlondon
- source builds show the real version instead of 0.0.0 in About #73 @vnazarenko

## v0.5.2 - 2026-07-01

### Improvements

- per-session solid background color for session.background #68 @umputun
- split toolbar icon shows which pane is visible when collapsed #67 @umputun

## v0.5.1 - 2026-07-01

### Bug Fixes

- hide the sidebar scroll bar when the tree fits, instead of always showing a track under macOS "Show scroll bars: Always" ab1d4a8 @umputun

## v0.5.0 - 2026-07-01

### New Features

- per-session background watermark, set via session.background #32 @fkirill
- read a session's scrollback over the control API with session.text #46 @paul-nameless
- show the app-wide unseen-notification count as a Dock icon badge #48 @vnazarenko

### Improvements

- show the configured keyboard shortcut in toolbar and sidebar tooltips #62 @taras-mrtn

## v0.4.2 - 2026-07-01

### Bug Fixes

- right-click paste works out of the box, with a General settings toggle to disable it #63 @umputun
- file drops land on the visible session instead of an invisible background one #63 @umputun

## v0.4.1 - 2026-07-01

### Improvements

- double-click the window header to zoom, honoring the macOS title-bar double-click setting #33 @fkirill
- session.resize control command to move the split divider #59 @umputun
- reorganize Settings into five focused tabs #60 @umputun

### Bug Fixes

- restore sessions started with a command (e.g. ssh) on relaunch, instead of coming back as plain shells #61 @umputun

## v0.4.0 - 2026-06-30

### New Features

- session attention list and title-bar indicator #35 @umputun
- insert dropped file paths as text on drag-and-drop #52 @umputun
- optional one-shot sound on session.status #38 @umputun
- make the agterm agent skill user-invocable 58ff68f @umputun
- fish shell integration for agent-status hooks #56 @korjavin

### Improvements

- de-bounce repeated identical status sounds #40 @umputun
- enrich the About panel with repo link, copyright, and build commit 800add3 @umputun

### Bug Fixes

- forward right- and middle-click to libghostty #53 @umputun
- Esc cancels inline rename and focus returns to the terminal #42 @umputun

## v0.3.1 - 2026-06-29

### Improvements

- make global ghostty config inheritance opt-in (default off) #29 @umputun

### Bug Fixes

- ⌘C/⌘V copy/paste on non-Latin keyboard layouts #31 @umputun
- active status color default and "default ghostty" theme picker label bac948c
- clear the active agent-status glyph on Esc-interrupt #28 @umputun
