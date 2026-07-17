# Changelog

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
