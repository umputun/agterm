# Changelog

## v0.41.1 - 2026-11-07

### Improved

- **Diff pages color code by language and step between changes.** A `.diff` or `.patch` page colors each file's code in its own language over green and red row bands, where it used to color whole lines green and red. Previous and next buttons in the bar, or `]` and `[`, step from change to change with a "change 3 of 7" counter. `agtermctl session overlay changes --next|--prev` is the control form, and `htmlOverlays[].text.changes` reads back `{count, current}` #916 #921 @umputun
- ⌘-click on a local `.html` or `.htm` path opens the page over its session, as markdown and text files do, instead of revealing it in Finder. The page runs no script and makes no network connection; a missing or binary file, or one over 4 MiB, is revealed as before. `tree` reports it as `htmlOverlays[].document` #917 @umputun
- an animated window title, such as an agent's spinner, costs less: the hidden OS window title updates at most twice a second, and the visible title no longer re-lays out the titlebar on every frame #817 @dimonb
- a program writing the same title over and over queues one title update per pane at a time, not one per write #911 @umputun
- every cookbook recipe names its author, and a fix to another author's recipe comes as a pull request to it #920 @umputun

### Bug Fixes

- in Live mode, a clean quit with many busy panes could save them with no running command, so the next reboot restored bare shells #918 @umputun #915
- right after launch File ▸ Attach Remote… could stay disabled, so ⌘⇧R typed `R` into the terminal #912 @umputun
- the sidebar Tint submenu started every untinted row on the icon, so a Show On pick never carried to the next row. A new tint now starts on the last Show On pick of the app run #910 @umputun

## v0.41.0 - 2026-11-06

### New Features

- **Text files and `path:line` locations open as a page.** ⌘-click on a source, config, text or log file in terminal output shows it read-only in the terminal's theme, with line numbers and syntax highlighting. A location such as `./main.go:42:7` from compiler or grep output opens the file scrolled to that line and marks it, and a relative path resolves against the pane's directory. Reveal in Finder moves to ⌘⌥-click, which reveals any clicked local path. `agtermctl session overlay open --text FILE [--line N]` opens the same page #874 @umputun
- **Log pages follow the file.** A click on a `.log` or `.out` path opens the text page on up to the last 5,000 lines within a 2 MB read and follows the file's end as it grows, through rotation and truncation. A `path:line` click, and a log on a session another Mac presents, open the static page. Scrolling up pauses following; `F` toggles it, `G` or End jumps to the bottom and `g` or Home to the top. `session overlay open --text FILE --tail N --follow-file` and `session overlay follow on|off|toggle` are the control forms #899 @umputun
- **Search in text pages.** Every text and log page has a find box like the terminal's. `/` or ⌘F focuses it, `n`/`N` or Return/Shift-Return step through the matches, Esc clears. ⌘F now goes to what is on top, a visible page, an overlay or the quick terminal, never to the terminal behind it. `session overlay search TEXT | --next | --prev | --close` drives it #899 @umputun
- **Compact sidebar.** Settings ▸ Appearance ▸ Sidebar density picks Default or Compact, and Compact trims row padding and indent so more rows fit. `agtermctl sidebar density default|compact|toggle` sets it and `tree` reports `sidebarDensity` #884 @umputun
- **More tint colors.** Teal, pink, brown, indigo and mint join the sidebar tint palette, and `session tint`, `workspace tint` and `--tint` also take any `#rrggbb` hex. A row tinted with a hex shows a checked "Custom #rrggbb" entry in its menu #890 @umputun
- **Five more status shapes.** Triangle-down, play, seal, bolt and bell join the agent-status shapes, in Settings and through `session status --shape`. A Mac on 0.40.0 or older that attached the session draws its own Settings shape for them #898 @umputun
- Settings ▸ Interface ▸ Sidebar ▸ **Workspace chevrons** is on by default. Turning it off removes the collapse chevron from workspace rows to give names more width, and the workspace row menu gains Collapse Workspace and Expand Workspace #909 @umputun
- image, markdown and text pages opened on a session another Mac presents now show on that Mac, as HTML pages already did. Before, `session overlay open --image`, `--markdown` and `--text` on such a session were refused. A text page shown there stays static, without log follow or control-driven search #891 @umputun
- Live panes start the zsh or fish named in ghostty.conf `command`, so `command = /opt/homebrew/bin/fish --login` gives fish in Live mode as it already did with fresh shells. Before, Live always started the macOS login shell. A pane whose daemon is already running keeps its shell until Agterm ▸ Reset Live Sessions… #895 @umputun
- `tree` reports `snapshotUnsaved: true` on a window whose state saves keep failing, until the next save succeeds #900 @umputun
- `two-agent-mailbox-chat` cookbook recipe: two agents in a split, Claude Code or Codex in any pairing, talk through pane mailboxes instead of typing into each other's composer. It is the recommended replacement for `two-agent-chat` #876 #888 #896 @umputun #885
- `claude-git-info` cookbook recipe: each Claude Code session's info line shows the branch, changed-file count and commits ahead and behind for the repo it works in #872 @umputun
- `image-path-gallery` cookbook recipe: one chord shows the image paths on a pane's screen as a thumbnail gallery, copying them from the host first in an attached session #893 @wildsurfer
- `subagent-status` cookbook recipe: a Claude Code session's info line counts its running and finished subagents, the row stays active until the last one finishes, and a custom command pages any subagent's transcript over the session #906 #908 @bubakanov

### Improved

- libghostty moves to ghostty v1.4.0, which brings upstream's fixed-memory trims and pauses the display link while idle #883 @umputun

### Bug Fixes

- with Open links in set to an overlay, a ⌘-click over a page that an earlier click opened and then hid went to the browser, and the hidden page stayed out of sight. The click now replaces the hidden page and shows the new one #880 @umputun
- a clicked path that ends a sentence, such as `/tmp/review.md.`, revealed in Finder instead of opening, because the trailing punctuation stayed on the path #881 @umputun
- a markdown file with YAML frontmatter, such as any `SKILL.md`, showed a rule and one giant heading. The frontmatter now shows as a YAML code block above the body #897 @umputun
- Settings ▸ Key Mapping ▸ Lock in terminals let the earlier keyboard layout come back while an HTML overlay page had the keyboard. The lock now holds there too #904 @umputun
- the palette's Move Session rows moved the session that was selected when the palette opened, so a selection change under the open palette moved the wrong session #879 @umputun
- on macOS 27 the sidebar Tint submenu drew no color swatches #890 @umputun

## v0.40.0 - 2026-11-02

### New Features

- **Message bus between panes.** Each live pane has a mailbox for the current app run, so agents and scripts can pass text to each other without typing into another terminal. `agtermctl msg send TEXT --to SESSION:PANE`, repeatable or `--all [--workspace W]`, delivers to each recipient separately; `msg read [--ack] [--wait]` returns the oldest messages and `msg ack ID...` removes handled ones. The sender is the calling pane, from `AGTERM_SESSION_ID` and `AGTERM_PANE_ID` or `--as`. Closing the pane, its session, workspace or window, `session restart` and a respawn drop the mailbox, and nothing survives quitting the app. `tree` reports `pendingMessages` per pane, and a `message` event names the sender and recipient but never the text #847 @umputun
- **Session info line.** `agtermctl session info TEXT` puts one line under a session's sidebar row for its current activity: an agent's step, a count, a progress note. `--markdown` allows bold, italic, code, palette colors and dim text, and `--hide-after SECONDS` clears the line unless it is set again. The line is not saved across restarts, a session attached from another Mac shows the origin's line, and `tree` reports `info`, `infoMarkdown` and `infoHideAfter`. Settings ▸ Interface ▸ Session info shows it always, in the flagged view only, or never #864 @umputun
- **Markdown files open as a page.** ⌘-click on a `.md` or `.markdown` path in terminal output shows the file rendered in the terminal's theme over its session, with highlighted code blocks, task-list boxes and heading anchors, so a table of contents scrolls in place. Pictures from the file's own folder are embedded. The page loads nothing from the network, runs no script from the file, and turns every link other than http(s) and `#anchor` into plain text. `agtermctl session overlay open --markdown FILE` opens the same page #866 @umputun
- **Image paths open as a picture.** ⌘-click on an image path a program prints, such as `/tmp/shot.png`, `~/x.png` or a `file://` link, shows the picture over its session in a panel shaped like the image. Any other local path except a markdown file reveals in Finder, where a bare path did nothing before. A pane attached from another Mac ignores bare paths, since they name files on that Mac. `agtermctl session overlay open --image FILE` is the control form #844 @umputun
- **Attach a remote session with its companions.** File ▸ Attach Remote… and `agtermctl zmx attach HOST ID --companions` bring a session from another Mac together with all its companions, nested under it. A terminal companion attached alone joins its parent when exactly one row in the window is attached from that parent. If a companion cannot be attached, the rest stay and the error names the missing ones. `zmx tree` lists each top-level session's `companions` #849 @umputun
- Settings ▸ Interface ▸ **Workspace icons** and **Session icons** are on by default; turning one off removes the leading icon from that kind of sidebar row to give names more room in a narrow sidebar. A hidden icon also hides the state it shows; a remote session's connection notice moves to the name's tooltip #865 @umputun
- `session overlay open` and `session overlay resize` with `--width`/`--height` work on a session shown on another Mac: the overlay opens there sized in points, capped at 80% of the session. Before, the open was refused #850 @umputun
- `container-overlays` cookbook recipe: overlay programs started inside a docker container run in that container, and its files open by their Mac paths #855 #860 @Rulexec
- two more cookbook recipes. `end-of-task-offer` opens a Clear, Close session or Continue dialog when an agent clears its title-bar context at the end of a task. `named-companion` asks for a name, duplicates the session as a companion, names it and tints it #853 #846 @umputun

### Bug Fixes

- on macOS 27.2 a window dragged by the header could jump away from the pointer, mostly at a display edge #869 @menemy #856
- a Live `session new --command X --wait` pane lost its output when the command exited, because the attach client reset the terminal before the hold prompt showed. The output and scrollback now stay, and a command that ends before its pane attaches no longer leaves a fresh shell in its place. A very short command can still lose its output and show `agterm: session is gone` #859 @umputun #857
- with two split sessions in a window, an `ask` over a whole session could leave the resize cursor showing at the hidden session's divider until the app lost focus #858 @umputun
- on a session attached from another Mac, an overlay program such as `glow -p` could show an empty overlay because the origin Mac found no `xterm-ghostty` terminfo entry. It now gets the one bundled with agterm #854 @umputun
- Duplicate as Companion of a pane whose program carries its own session id in its arguments, such as codex with `AGTERM_SESSION_ID` set through `-c`, left the copy talking to the parent's panes. The copy's command now names its own session and panes #843 @umputun

## v0.39.1 - 2026-10-30

### Improved

- the GUI `ask` dialog's one-line text field matches the dialog around it: a lighter rounded box with a thin outline in place of AppKit's square border, with the text inset and vertically centered #842 @umputun

### Bug Fixes

- a companion row pushed every sidebar row's status glyph and unseen badge out of view until the sidebar was resized. The statuses were set all along #841 @umputun
- Duplicate as Companion showed a refusal only as a notification banner, so with banners hidden it seemed to do nothing. The refusal now shows in a panel over the session #841 @umputun
- Duplicate as Companion refused a pane running a program started by name after an upgrade removed its binary, such as a codex left running across a `brew upgrade`. It now starts the program the pane's own PATH names #841 @umputun
- Duplicate as Companion of a split session focused the copy's right pane. The copy now focuses its left pane #842 @umputun

## v0.39.0 - 2026-10-29

### New Features

- **Companion sessions.** A companion belongs to a parent session and nests under it in the sidebar: a side shell, a program beside the main one, or an HTML page. It folds with a disclosure triangle, reorders among its siblings, moves and closes with its parent, and close undo brings the whole group back. New Companion is in the row menu, the Session menu, the palette and the `new_companion` keymap action, and `agtermctl session new --parent SID` is the control form. `session overlay open --html|--url --companion` adds a page row with no shell, which is not restored after relaunch. Duplicate as Companion, or `session duplicate --companion`, copies the split layout and starts another copy of each pane's foreground program, and creates nothing when a pane cannot be copied. The palette, Ctrl-Tab and other flat lists label a companion `parent › child`, and a folded parent shows a marker for a blocked, completed or unseen companion. While a parent has companions, its shell exiting starts a fresh shell in the same directory. On a session attached from another Mac, the origin creates the companion and this Mac attaches it. `session collapse|expand` fold a parent, and `tree` reports `parent`, `collapsed` and `content` #840 @umputun
- **Tinted rows.** A session or workspace row can carry one of seven colors on its icon, its name or both, to mark which environment a session points at without renaming it. The row menu's Tint submenu works on a multi-row selection and the palette has Tint Session. `agtermctl session tint <color|clear> [--on icon|name|icon,name]`, `workspace tint`, and `--tint`/`--tint-on` on `session new` and `workspace new` are the control forms, read back as `tint` and `tintOn` in `tree`. A workspace tint colors only its own row #836 @umputun
- **Reorder the flagged view.** The flat and plain flagged layouts keep a saved order per window: drag a row anywhere in the list, across workspaces, and the order survives a restart. A newly flagged session goes to the end, and next/previous session navigation follows the displayed order. In the tree layout a drag reorders the workspace's sessions as the ordinary tree does. `agtermctl session flag move --before|--after ID` is the control form, read back as `flaggedOrder` in `tree` #833 @umputun
- **Edit the flagged set and workspace focus from the palette.** Edit Flagged Sessions and Edit Focused Workspaces list every session or workspace of the window with its mark. Return or a click toggles a row and the palette stays open on the same query. Both are in the action palette and the View menu, and as the keyless `edit_flagged_sessions` and `edit_focused_workspaces` actions; an empty flagged view links to the session editor #803 @umputun
- **Open links in a smaller overlay.** Settings ▸ General ▸ Open links in adds session overlays at 95%, 75% and 50%, also set with `agtermctl browser links overlay95|overlay75|overlay50` and read back as `linkOpenMode`. With any overlay mode set, ⌘⇧-click opens a link in the browser instead, and Shift-click extends a selection. Inside a program that captures the mouse, ⌘⇧-click keeps following the setting #812 #813 @umputun
- Settings ▸ Agent Status ▸ **Attention navigation crosses windows**, off by default, lets next/previous attention (⌃⌥↑/↓, the Navigate menu and the palette) step through every open window and bring forward the window it stops in. `session go --to next-attention|prev-attention` stays within its window. `tree` reports the setting as `attentionNavigationAcrossWindows` #824 @umputun
- Settings ▸ Agent Status ▸ **Attention navigation includes active sessions**, off by default, makes the attention steps and `session go --to next-attention|prev-attention` stop on active sessions too. Auto-follow, the bell and pane reveal are unchanged. `tree` reports the setting as `attentionIncludesActive` #807 @umputun
- Settings ▸ Appearance ▸ Window ▸ **Ignore Reduce Transparency**, off by default, keeps the saved opacity and blur on the window while macOS Reduce Transparency is on. Palettes and the session switcher still follow the system setting #814 @umputun
- `agtermctl session close --undoable` gives a single session the close grace ⌘W gets, so a custom command bound in place of `close_session` keeps ⌘Z. It falls back to a hard close when undo after closing is off, and `result.undoable` in the reply says which happened #804 @dbeliakov
- `tree` reports `lastSelectedAt` for each session, the last time it became or stopped being its window's selection, so a script can find sessions nobody has looked at in a while #818 @paul-nameless
- three cookbook recipes. `annotate-document` opens a plan, document or draft as a page whose notes on blocks and lines go back to the agent. `claude-pasted-images` draws each image pasted into a Claude Code prompt under that prompt row. `flag-recent-agents` replaces the flagged set with active and recently updated agent sessions after a pre-checked dialog #805 #830 08ccd78d @umputun

### Improved

- Settings ▸ Interface shows each title-bar and sidebar toggle beside its control's icon #810 @umputun
- the bundled Codex status hook checks for a blocked prompt every 2 seconds instead of every half second, about 75% fewer screen reads, so a blocked status can take up to 2 seconds to appear. Reinstall from Help ▸ Install Agent Status Hooks to pick it up #802 @umputun
- the troubleshooting docs show how to route agent status for `claude --bg`, whose background session does not inherit the pane's `AGTERM_*` variables. They no longer claim that `mouse-reporting = false` brings links back inside a program that captures the mouse: a link there still needs ⌘⇧-click #821 38806266 @umputun

### Bug Fixes

- closing a busy terminal could freeze every agterm window. The bundled libghostty carries a backport of the upstream teardown fix, ghostty-org/ghostty#14444 #819 @bot-rogerthat
- after an update, or on a fresh state directory, terminals could start with default or stale generated settings until a config reload, which left the terminal opaque inside a translucent window. The generated config is now written before libghostty loads it #814 @umputun
- in Live sessions mode, a session created with `--command` fell back to a shell prompt when its command exited, and `--wait` was ignored. **Behavior change:** the pane now closes when its command exits, as it does without Live sessions, and `--wait` keeps its final output. `session restart --command` and restored commands still return to the shell #840 @umputun
- `split-divider-color` in ghostty.conf had no effect, and the split divider was hard to see on dark themes. The divider now takes that color, or else a blend of the theme background toward its foreground, and follows config reloads #829 @umputun #825
- the bash agent-status hook changed the exit status that later `PROMPT_COMMAND` entries saw, so a prompt showing the last status read `[1]` after every successful command. Reinstall from Help ▸ Install Agent Status Hooks to pick it up #828 @umputun
- a Codex pane could show an active status with nothing running, because Codex's hidden memory-consolidation thread fires the prompt and tool hooks but never Stop. The hook now ignores that thread. Reinstall from Help ▸ Install Agent Status Hooks to pick it up #822 @umputun
- a pane overlay opened while a session-wide program or page was up drew underneath it, invisible behind a full overlay such as revdiff. It now draws on top while it is shown #831 @umputun
- a pane `ask` shaded only its own pane over a session-wide program or page, so the overlay turned two-toned at the split divider #832 @umputun
- the HTML page strip offered Hide while Settings ▸ Interface ▸ Hide overlays was off, the default, which left a hidden page no visible way back. Hide now shows only with that setting on #834 @umputun
- ⌘Z in a form field of an HTML page during a session's close grace brought the closed session back instead of undoing the edit #827 @umputun
- tooltips in the title bar, sidebar footer, search bar and page strip appeared late or not at all unless the pointer stayed still. They are now AppKit tooltips, which also hand off from one button to the next #816 @umputun
- `brew upgrade` run inside agterm could leave the quarantine flag on the app, so every upgrade ended with the first-launch prompt. The cask now strips it before moving the app into place. Diagnosed by @p1gmale0n #801 @umputun
- the `two-agent-chat` recipe left text stranded in Claude Code's composer for a message ending in a backslash or longer than 10,000 characters. It now refuses both before typing #806 @paskal

## v0.38.1 - 2026-10-22

### Improved

- `session overlay open` and `session overlay resize` take `--width` and `--height` in points, each replacing `--size-percent` on its own axis, so a local floating program or page keeps its percent width and fits its height to what it shows. A `--js` page sizes itself through `agterm.request('session.overlay.resize', ...)`. A point-sized axis is capped at 80% of the session, and `tree` reports the laid-out size as `overlayWidth`/`overlayHeight` #798 @umputun

## v0.38.0 - 2026-10-22

### New Features

- **HTML pages on a remote session.** A page opened with `session overlay open --html` or `--url` on a session another Mac presents now opens on that Mac, the way a program overlay already does. It used to be refused. A URL page loads on the presenting Mac with that Mac's `--persistent` storage, and a loopback URL is refused there because it names a server on the origin. A file page and the files its `--cwd` grants are served from the origin over ssh, and its `data-agterm` tags and `agterm.request` calls run on the origin. `result --page`, `--block`, `close`, `resize`, `reload` and `navigate` work as for a local page, and `tree` lists it with `remote: true`. A presenter running an older agterm keeps the refusal #793 @umputun
- **Hide overlays without closing them.** ⇧⌘J, View ▸ Hide Overlays and a Hide button on the page strip hide every program and page overlay of the session, and the same keys show them again. A hidden program keeps running and keeps its exit status, a hidden page stays loaded, and neither takes focus or keys. A HUD and an ask are never hidden. `agtermctl session overlay hide|show|toggle [--pane left|right]` is the control form, read back as `hiddenOverlays` and `htmlOverlays[].hidden` in `tree`. Settings ▸ Interface ▸ Hide overlays adds a title-bar button, off by default. A keymap that already binds `cmd+shift+j` keeps it #790 @umputun
- **Forms in `ask`.** `--input line` or `--input multiline` adds a text field, with `--value` and `--placeholder`, and the answer carries `text`. `--choice id=label`, up to 50 items, makes a radio list, or a checkbox list with `--multiple`, with `--choice-subtitle` and `--checked`; the answer carries `selected`. `--other PLACEHOLDER` adds a free-form line after the items. A form gets OK and Cancel without `--button`, and `--cancel id` names the button that acts like Esc. On a remote session a form goes to the presenting Mac only when its agterm supports forms #778 #779 @umputun
- **fish as the login shell for Live sessions.** Live sessions required zsh and fell back to fresh shells under fish. A fish pane now gets agterm's bundled fish integration, and a restored command line is quoted for fish. A Live `session new --command` or `session restart --command` line uses the login shell's syntax, so fish rejects zsh constructs like `[[ ]]`. The session host now answers the terminal's startup device-attributes queries while a new pane is created, which cost fish about ten seconds before its first prompt; zsh panes start as before #761 #760 #768 @vshuraeff #780 @umputun
- `agtermctl session wait --target S --until completed --until blocked [--timeout SEC]` blocks until a session's agent status is one of the given values and prints it. It returns at once when the status already matches, and it sees a `completed` that auto-reset clears right after. Exit 2 means the session left the tree, 124 the timeout #765 @umputun #758
- a new `pane.focused` event fires when focus moves between a session's split panes, by a click, the focus keys, `session focus`, a new split or a closed one. It carries the session, `pane` and `paneID`, and works in `hooks.conf` too. A move and back within 100 ms is not reported #785 @umputun
- **Flag All Sessions** on the workspace row menu flags every session of the workspace, including those the flagged tree layout hides, and reads Unflag All Sessions once all are flagged. `agtermctl workspace flag on|off|toggle [--target W]` is the control form #787 @umputun
- **Mark for Attention** on a session's row menu gives an idle session a `completed` status that survives a visit, so it stays in attention navigation until it clears like any completed status. A session already showing a status is left alone #763 @umputun #755
- the Ctrl-Tab switcher, the Ctrl-P session palette, the title-bar recent sessions and File ▸ Attach Remote show each session's agent status, and every session list draws it on the right like the sidebar. `pick` items accept `status`, `statusColor` and `statusShape`, and `zmx tree` rows carry them #774 @umputun
- two cookbook recipes for the Antigravity CLI (`agy`). `antigravity-agent-status` sets the sidebar status from its hooks, and `antigravity-session-resume` reopens each pane's own conversation after a restart #786 @stn1slv
- a new cookbook recipe, `scheduled-jobs`, lets a coding agent install cronn, manage its scheduled jobs and run jobs that open agterm sessions, with the cronn dashboard in a chromeless overlay #789 @umputun

### Improved

- the `html-doc-overlay` recipe gains a custom design the model lays out for the content, a collapsed markdown copy in every page, a filled page title with a link preview, and optional sharing of an approved snapshot on an expiring link through the reader's own Cloudflare tunnel. Pages open with `--navigation` and no longer switch sessions #766 434f7246 @umputun

### Bug Fixes

- a mouse selection replaced the system clipboard, because agterm wrote every selection to the general pasteboard. Selections now go to a private selection pasteboard, as in Ghostty, and middle-click pastes the last one. ⌘C and OSC 52 copy to the system clipboard as before. **Behavior change:** to keep every selection on the system clipboard, set `copy-on-select = clipboard` in the ghostty config #792 @umputun #791
- Ctrl-C on a Live pane's restored command, or on the `--command` of a new Live session, closed the pane and ended its daemon instead of leaving a shell prompt #773 @umputun
- on Dvorak - QWERTY ⌘ and 31 other layouts whose Command table differs from the plain one, a custom `command` cmd chord fired on a different key than a built-in `map` chord with the same spelling: `cmd+d` fired on physical H and took ⌘H from Hide. Custom commands now match cmd chords through the layout's Command table, as the menu does. A binding spelled with a non-Latin glyph under cmd, such as `cmd+ą`, no longer matches #796 @umputun
- `brew upgrade` or `brew reinstall` of the cask failed when macOS refused to remove the quarantine attribute, as it can when run inside agterm. The cask now warns and finishes the install #784 @umputun #781
- `agtermctl notify` shared its Notification Center slot with the session's OSC 9/777 banners, so the next terminal banner, Claude Code's "waiting for your input" for example, replaced the note #772 @umputun #770
- `ask --hotkey` letters were dead on non-Latin layouts such as Ukrainian. Hotkeys now follow the keymap's rule: an ASCII-capable layout matches the typed letter, any other layout the US letter at that physical position #771 @umputun #769
- the status sound, from `session status --sound` or the Settings blocked sound, played on the origin Mac for a session attached from another Mac. It now plays on the presenting Mac, which uses its own blocked-sound choice. A presenter on an older agterm keeps the old behavior #775 @umputun
- `zmx tree` left out a Live session whose split stayed hidden across a relaunch, so another Mac could not attach it #764 @korjavin #762
- a new Live session's daemon could keep running but become unreachable when the session list was read while it started, because zmx deletes a socket that refuses a connection as stale. The bundled zmx now publishes the socket only once it listens #793 @umputun
- Esc on an HTML page that did not handle it took a full-screen window out of full screen #754 @umputun #753
- the window-close sheet in Live sessions mode said closing ends the running sessions, where it only detaches them and the daemons keep running. It now says the window can be reopened from File ▸ Open Window #743 @umputun #741
- the `two-agent-chat` recipe lost a `--message-file` message the target refused before typing. The message is now kept for a resend #783 @umputun #640
- the `two-agent-chat` recipe withheld a long message to Codex once its first rows scrolled away, reading Codex's `↑` scroll indicator as message text #752 @Stuchalin #751

## v0.37.0 - 2026-10-15

### New Features

- **File ▸ Open Recent from the CLI.** `agtermctl recent list` prints the Open Recent entries newest first, `recent open [ID] [--window W]` reopens one by id or prefix, the newest with no id, through the menu's own restore path, and `recent clear` empties the list. A reopened session keeps its id, split, flag, context and restore pins, which `session new` could not bring back. It goes to `--window` or the frontmost window unless another window already holds its session or workspace, and the window is not raised. `--json` carries `closedAt`, the workspace id and the session ids each entry restores #744 @umputun
- **Lock a keyboard layout in terminals.** Settings ▸ Key Mapping ▸ Lock in terminals, off by default, picks one of the keyboard layouts enabled in macOS and holds it while a terminal has the keyboard: a layout switch made in a terminal is switched straight back, and the previous layout returns when focus moves to another app, a web overlay or a text field, and on quit. It covers main, split and scratch panes, program overlays and the quick terminal. macOS selects a layout system-wide, so a crash or force quit leaves the locked layout selected. The setting has no control command #727 @umputun
- **Launch hook and overlay events.** A new `app.launched` event fires once per app run after `hooks.conf` is loaded and the control socket accepts connections, so `on app.launched <cmd>` in `hooks.conf` runs a script once per launch. `tree.changed` now also fires when a program, page, pane overlay or HUD opens or closes, so a script no longer polls the tree for that. A `tree.changed` hook that opens a HUD unconditionally loops; the docs say to open only when no HUD is up #736 @umputun
- `session overlay open --url URL --chromeless` works for a page served from this Mac, on host `127.0.0.1`, `::1` or `localhost` exactly, so a local dashboard drops the overlay's strip and keeps its `--persistent` storage. Other hosts, `--browse` and `--navigation` are refused with it, and frame navigations stay on the page's origin. The page closes with ⌘W, `session overlay close`, or its own `window.close()` under `--js` #750 @umputun
- `agtermctl version` prints an `installed:` line when the app bundle on disk differs from the running build, after a background `brew upgrade` for example. `--json` carries it as `result.installed` #723 @umputun
- a new cookbook recipe, `session-snapshot`, snapshots every open window into JSON and a browsable HTML page, and restores any session or workspace later from a copied line. Claude Code sessions come back with `claude --resume`, each with its own conversation #742 @ne0r0mancer

### Improved

- `session scratch on --target A` starts the scratch on A in the background and no longer switches the window to A; the scratch takes the keyboard once A is selected. `--follow` selects the target, as with `session overlay open`. The forced switch also cleared A's unseen badge and reordered Ctrl-Tab recency. **Behavior change:** a script that relied on `scratch on` to switch sessions passes `--follow` #730 @umputun #728
- a custom command started in a session whose directory was removed, a deleted git worktree for example, now runs in HOME instead of being refused. `AGT_SESSION_PWD` still carries the path the session reported. The same applies after `ssh` from a local session, where the pane reports a remote path #740 @umputun
- the docs and the bundled agent skill describe upgrading with Live sessions active, and note that `AGTERM_WORKSPACE_ID` is fixed when the shell starts, so `tree` is the source for a session's current workspace #725 ed831ab3 @umputun

### Bug Fixes

- a second agterm launched on a state directory another instance was using kept running without a window, and once the owner quit, its first save rewrote the window files from a stale copy: sessions created after it started disappeared and their daemons kept running as orphans. `agterm --help` typed in a pane started one. Such a launch now exits with status 1 before it reads or writes anything #749 @umputun #741
- agterm was unresponsive at launch with many restored sessions, 96 in the report, spending its time on SwiftUI layout of the hidden terminals #747 @bot-rogerthat
- the selected sidebar row lost a custom theme's selection colors, or took them from a bundled theme with the same name, when the theme was set by path or kept in `~/.config/ghostty/themes`. Light-theme selections could be unreadable #746 @umputun #745
- supervised Live panes read `liveAttribution: unknown` after the session host ran for three days, because macOS deleted its pidfile from `/tmp`. A host started by an older build keeps the old behavior until it is replaced #733 @umputun #732
- `session scratch on --command CMD` against a scratch already shown answered ok and never ran CMD #730 @umputun
- with two OpenCode v1 permission prompts open at once, answering the first cleared `blocked` while the second still waited #734 @umputun

## v0.36.0 - 2026-10-09

### New Features

- **Open terminal links in a session overlay.** Settings ▸ General ▸ Open links in chooses where a command-clicked web link opens: the browser, still the default, or a full web overlay over its session with JavaScript, navigation buttons and saved logins. `agtermctl browser links [browser|overlay]` sets or prints it, and `tree` reports `linkOpenMode`. A link still opens in the browser when it sits in a HUD, a program overlay or the quick terminal, when the session's overlay slot is taken or its window has a zoomed terminal, and for plain http to a qualified host name outside `.local`. `session overlay open --url URL --browse` lets a URL page follow links, forms and redirects to other sites, and reads back as `htmlOverlays[].browse` #708 @umputun
- **Attach Remote from the File menu.** `remotes.conf` in the config directory lists one remote per line as `destination [label...]`, and File ▸ Attach Remote… attaches a session from one of them with no custom command. With several remotes it asks which Mac first, then shows the session picker. A HUD over the starting session shows the ssh waits and a failure. `attach_remote` is a built-in keymap action on ⌘⇧R, in the command palette too. A keymap that already binds that chord keeps it. The file is watched, so an edit updates the menu without a reload #710 @umputun
- **Sticky and frameless HUD panels.** `session hud --sticky` puts the panel flush against the edge or corner `--position` names and lets `--size-percent` reach 100 there. `--no-frame` drops the border, the rounded corners and the blank row above and below the text. Together they make a caption pinned to an edge. Both read back as `hud.sticky` and `hud.frame` #709 @umputun
- **Links in a markdown HUD.** A `[label](url)` link in `session hud --markdown` renders as its underlined label and opens on command-click, the same gesture as a link in the terminal. Web, mail and ftp links open, a local `file://` link is revealed in Finder. The link used to show its label only #707 @umputun
- `agtermctl clipboard set [TEXT]` copies text, or stdin when there is no argument, to the clipboard of every terminal showing the pane it runs in. In a session attached from another Mac `pbcopy` fills the clipboard of the Mac the program runs on; this one reaches the Mac you sit at. It needs a main or split pane started under Live sessions, and each terminal applies its own `clipboard-write` setting #722 @umputun
- the flagged view gets a third layout, `plain`: the flat list with the session name alone, without the `: workspace` suffix. It is "Flat list, names only" in Settings ▸ General ▸ Flagged view layout and `agtermctl sidebar flagged-layout plain` from the CLI. `flat` stays the default, and `flagged-layout toggle` still switches between `tree` and `flat` #718 @umputun
- a page opened with `--js` closes its overlay when it calls `window.close()`, and `session overlay result --page` reports `dismissed`. A URL page had no way to end itself. **Behavior change:** such a page can dismiss its overlay without a prompt #704 @umputun #702

### Improved

- `session restart (--pane-id ID | --pane left|right)` with no `--command` runs the pane's foreground program again, in the directory it is running in. It is refused with nothing changed when a shell holds the pane, when the program cannot be read (`sudo`, `top`) or when it is listed in `restore-denylist.conf`. Environment assignments, redirections and the rest of a pipeline are not replayed. The reply carries the argv as `restart.replayedArgv`. **Behavior change:** the call without `--command` used to fail with `session.restart requires a command` #701 @umputun
- a HUD keeps its height when the window grows, and a markdown panel on a narrowed pane gains the wrapped row where it used to cut text with `… N more`. Markdown wraps at the panel's own width; it used to wrap at 60 columns in a narrower pane and cut each row #707 #709 @umputun

### Bug Fixes

- a Claude Code session read `active` for about six seconds after a permission prompt opened, and never turned `blocked` while keys were pressed in the prompt. The installed hooks now set `blocked` as the prompt opens, and Esc or Ctrl-C in the prompt clears it when Status reset is On Enter. Re-run Help ▸ Install Agent Status Hooks… to update an existing install #721 @umputun #720
- with several event subscribers a short stall in the app made the control socket refuse connections, so status hooks and scripts failed with `Connection refused`. The socket now queues up to 128 waiting clients, where it queued 8 #717 @p4elkin #715
- `agtermctl events` exited on a refused connection and lost every event emitted until its restart. Once it holds a cursor it retries with a backoff from 250 ms to 4 s and reads on from the same cursor, and exits after about 30 seconds of refusals #716 @p4elkin #715
- ctrl+j and ctrl+k did not move the selection in the palettes and `agtermctl pick` on a non-Latin keyboard layout such as Cyrillic #705 @umputun
- a custom command started in a session whose directory was removed failed with `The file "name" doesn't exist.` It now says `session directory <path> no longer exists` 312987af @umputun
- the sidebar's remote icon stayed a crossed-out cloud after the connection to the other Mac came up #710 @umputun
- a custom `window-padding-y` could cut HUD text, and a `config-file` include that restated a key outranked a session background or a HUD's font size #709 @umputun

## v0.35.1 - 2026-10-05

### Improved

- **Restart the program in one pane.** `session restart --command LINE (--pane-id ID | --pane left|right)` ends one Live pane's shell and its foreground program, then starts a new login shell in the same pane that runs LINE and stays interactive. The pane keeps its place, its stable id and its `AGTERM_*` environment, and nothing is typed into it. The reply carries the old and new shell pids. It works on a hidden split, in a background window and with the display asleep. Non-live, remote and scratch panes are refused #699 @umputun

### Bug Fixes

- the command a Live pane was created with (`session new --command`) kept running after the pane or its session was closed. Ending a pane's shell now sends a hangup to its foreground job, the way closing a terminal does. Background jobs, including nohup and disowned ones, are left alone #699 @umputun

## v0.35.0 - 2026-10-04

### New Features

- **Address a pane by its stable id.** `session type` and `surface cursor` take `--pane-id`, the token a shell sees as `$AGTERM_PANE_ID`, and `tree --json` lists it as `surfaces[].paneID`. A script can read a pane, check its caret and type into it by that id, and the id keeps naming the same terminal after `session swap` or a split-pane promotion. `session text` and `session type` report the pane they acted on as `result.pane`. **Behavior change:** `session text --pane-id` with an unknown id and no `--pane` used to read the on-screen pane and answer ok. It now fails with `unknown pane id: <id>`, as `session type` and `surface cursor` do #698 @umputun
- **OpenCode 2 agent status.** Help ▸ Install Agent Status Hooks installs a separate plugin for OpenCode 2, by default at `~/.config/opencode/plugins/agterm-v2/tui.js` with `OPENCODE_CONFIG_DIR` and `XDG_CONFIG_HOME` honored, and the OpenCode 1 plugin stays as it was. The installer detects the major version; when it cannot, it offers a choice if an OpenCode config exists and skips otherwise. Each client reports its selected session and that session's subagents to its own pane #658 @LerikP #696 @umputun #637
- **Saved logins for URL overlays.** `session overlay open --url URL --persistent` keeps cookies, `localStorage` and IndexedDB in one saved store shared by every persistent page, so a login survives closing the overlay and restarting the app. `browser clear` removes the saved data and is refused while a persistent page is open. `tree` reads `persistent` back on each `htmlOverlays` node. A login that leaves the page's origin (OAuth, SSO, a popup) still fails #689 @umputun
- **`--repeat` for leader sequences**, like tmux `bind -r`. With `map ctrl+a>ctrl+l --repeat next_session` and `map ctrl+a>ctrl+h --repeat previous_session`, ⌃A ⌃L ⌃L ⌃H walks two sessions down and one back, and holding the tail repeats it. Any other key ends the window and is handled as usual. `keymap list` reports `repeats` #666 @dderg #682 @umputun
- **Page titles and chromeless pages in HTML overlays.** The strip over a page shows its `<title>` dimmed after the file name or URL origin. `session overlay open --html FILE --chromeless` hides the strip, so a small page can look like a native view; it is refused with `--url` and `--navigation`. A `--js` page that cancels every keydown can no longer swallow ⌘W #678 @umputun
- `keymap run NAME [--target T] [--window W]` runs a custom command from `keymap.conf` against the addressed session, as the palette does for the active one. The reply means the process started #694 @umputun
- `zmx screen NAME [--all|--lines N]` reads the screen of a Live session's daemon by the name `zmx list` prints, including one whose window is closed. It attaches nothing and changes no pane's size #694 @umputun
- a `session.selected` event fires on every selection change and carries the session that lost the selection as `previous` #694 @umputun
- ctrl+j and ctrl+k move the selection down and up in the palettes and in `agtermctl pick`, next to the arrow keys, and ctrl+k no longer deletes to the end of the query there #695 @umputun

### Improved

- a remote pane whose network goes away ends within about 15 seconds and shows the reconnect bar, where it used to freeze until the TCP timeout. The attach adds `ServerAliveInterval=5` and `ServerAliveCountMax=2` unless the user's ssh config sets a nonzero interval. A pane whose ssh joins an existing `ControlMaster` connection keeps that connection's settings #683 @wildsurfer
- panes waiting to reconnect and dropped presentation streams retry at once when the Mac wakes or the network returns, and their backoff starts over. A Mac that slept all night no longer waits up to five minutes per pane #687 @wildsurfer
- a pane waiting to reconnect shows why its last attempt failed, as one line along its bottom edge, and `tree` carries the same reason and the retry count as `reconnect` on the surface node. A refused key or a changed host key no longer looks like an offline host #694 @umputun

### Bug Fixes

- `session type` and `quick type` with a trailing newline could leave a line of about 100 characters or more sitting unsubmitted in Claude Code, which read the Return as part of a paste. The final Return now follows the text after 10 ms. Returns inside a multi-line payload are not spaced, and one very long line can still be read as a paste #681 @umputun #679
- a `map` onto a stock macOS menu shortcut could list the action as bound while the stock command fired: `map cmd+opt+w focus_workspace` asked to close the window. A built-in now takes the shortcut from the stock item and gives it back when released #680 @umputun
- halving a wide window in one step left one pane of a left/right split at zero width. The stored ratio is now applied again when the split's length changes #692 @umputun #691
- an HTML overlay page that was not on screen took file drops aimed at the pane under the cursor, and the drop was lost #685 @umputun #677
- a dashboard cell showed the shell under a full session overlay or the pane's own overlay. It now shows a cover naming the page or program that hides the pane #690 @umputun #688
- the Codex status hook reported a finished turn as blocked when its final message quoted a footer hint such as `"? for shortcuts"` #684 @umputun
- a minimized, ordered-out or app-hidden window kept the GPU surfaces of its panes. They are released while the window is hidden and return when it is shown #694 @umputun
- after a Live restore of an idle Claude Code session a black block sat between the logo and its title. A daemon already running keeps the old behavior until it is recreated #694 @umputun
- a failed `windows.json` write could drop a new window from the next restore after a crash. The write is retried on the next successful save and at exit, and `tree` reports `indexUnsaved` while it is outstanding #694 @umputun
- with auto-hide of inactive sidebars on, a window restored by Reopen from the quick terminal over another app came up with its sidebar collapsed #694 @umputun
- an overlay program ran `~/.profile` first when the `sh` on PATH is dash or zsh, because the wrapper started as a login shell. It now runs `/bin/sh` as a non-login shell #694 @umputun

## v0.34.0 - 2026-09-30

### New Features

- **HTML pages that drive agterm.** A page opened with `session overlay open --html` can run control commands. A button or form tagged `data-agterm="<command>"` sends that request with the page's JavaScript off, and a `--js` page also gets `agterm.request(cmd, {target, args})`, which resolves with the reply. A command left without a target acts on the page's own session, window or pane. A page can also answer the script that opened it: `session.overlay.submit` records a value and closes the page, and `session overlay open --html FILE --block` waits and prints the outcome, exiting 0 when answered and 2 when the page closes unanswered. `session overlay result --page ID` reads an outcome after the page is gone, and `session overlay submit --value TEXT` answers a page from the CLI. The open reply carries `pageID`, which `tree` reports as `htmlOverlays[].id`. URL pages and frames get no bridge, and commands that stream are refused #672 @umputun
- **Remote panes reconnect after ssh loses the connection.** A pane attached with `zmx attach` used to end for good when ssh exited 255. It now keeps its last screen, shows a bar naming the host, and attaches again once the host answers, retried on the stream's backoff. Any key retries at once and ⌘W still closes the session. A changed host key or a removed key also exits 255, so such a pane keeps saying it is reconnecting without showing ssh's reason #655 @wildsurfer
- Settings ▸ General ▸ Sessions gains **New sessions are added**: at the end of the workspace, as before, or right after the current session. It covers New Session from the menu, palette, keymap, Dock, sidebar footer and a workspace row's New Session and +. Open Directory, folder drops and `open -a` keep appending #665 @airs0urce

### Bug Fixes

- ⌘+, ⌘- and ⌘0 over an HTML overlay resized the terminal hidden under the page. They now zoom the page, and so does `font inc|dec|reset` when a page covers the addressed terminal. The zoom is one app-wide value that persists across pages and reads back as `tree`'s `htmlOverlays[].zoom` #670 @umputun
- a Control-click on a sidebar row selected or toggled it instead of opening its context menu, and on a workspace row's + it created a session. Both now open the row menu #669 @umputun #668
- reloading an HTML overlay whose first load never finished did nothing, so a failed page stayed failed. Reload now loads the source again ec925f62 @umputun

## v0.33.1 - 2026-09-28

### Improved

- **Show in Finder and Copy Link in HTML overlays.** With `--navigation`, a file page's bar gains Show in Finder, which reveals the currently displayed file in Finder, including a sibling page reached by navigation, and a URL page's bar gains Copy Link, which copies the current address with its query and fragment. `session overlay navigate finder` reveals the file from a script. Copy Link has no control command, since the socket never writes the clipboard; scripts read the current address from `tree`'s `htmlOverlays[].page` #663 @umputun
- a new cookbook recipe, `html-doc-overlay`, gives Claude Code an `/agdoc` skill that builds a static HTML page about the issue, PR, plan, change or topic in hand from one of three templates and opens it in an overlay. The cookbook contribution rules now accept skill-only and README-only recipes, and the bundled agent skill asks for `--socket "$AGTERM_SOCKET"` when it is set and names `--window` for reading an HTML overlay back #662 @umputun

## v0.33.0 - 2026-09-27

### New Features

- **HTML pages in overlays.** `session overlay open --html FILE` and `--url URL` show a generated report, chart or explainer, or a running dev server, in the session-wide, floating or per-pane overlay slots. A bar above the page names its file or origin and carries the close button, `--navigation` adds back, forward, reload and open in browser, and `overlay reload` and `overlay navigate back|forward|browser` drive it from the CLI. `tree` reads back the page metadata and load state. A page runs no JavaScript of its own unless opened with `--js`, a local file gets no file access beyond the directory `--cwd DIR` grants, and a browser open started by the page asks first. File pages follow the terminal theme through CSS variables for background, foreground and the 16 ANSI colors, and the bundled skill teaches agents to build explainers and reports on them. A page renders on the serving Mac, and opening one is refused while another Mac presents the session #659 @umputun

### Improved

- Ctrl-Tab and the recent and attention popovers read an attached session exactly like a local one, since it reports its cwd on the other Mac. Those rows now lead with the sidebar's cloud glyph and put the host ahead of the directory, e.g. `system · 192.168.1.33 · ~/.dot-files` #650 @umputun
- **Reset Live Sessions** also selects panes whose zmx daemon predates the bundled zmx, such as daemons started before 0.32.0 that miss the attach-time lead claim. Live sessions keep their daemons through app updates, and the reset used to select only orphaned and app-attributed panes. The dialog, `zmx.reset`'s `outdated` count and an `outdated` flag on `zmx list` rows say which sessions that covers. As with any reset, running work in them stops #650 @umputun

### Bug Fixes

- a new session overlay or ask went to the attached Mac holding the presenter role even when the origin led the pane. After taking a pane's lead back on the origin, a `--block` overlay ran there but drew on the other Mac's screen, so nothing showed locally and the caller waited until a manual close. The handover now also requires the origin's pane to be a follower, and one already handed over stays where it is when the lead changes #661 @umputun
- the Claude status hook silenced the pane's own agent when a compiled launcher started the real `claude` without `exec`, because every `claude` pid in the chain counted as a separate agent. A consecutive run of one agent name now counts once. Re-run **Help ▸ Install Agent Status Hooks** to pick it up #651 @TrevorBurnham #649
- a remote session's pane showed nothing when ssh ended, never its `disconnected, exit N` line. libghostty runs a pane command through `exec`, which replaced the shell with ssh and dropped the rest of the wrapper #654 @wildsurfer
- the `two-agent-chat` cookbook recipe refused every send to codex-cli 0.157, which draws two footer rows under its composer, and withheld the submit when the lower row was a right-aligned notice #656 3f066932 @umputun #652 #657

## v0.32.0 - 2026-09-24

### New Features

- **explicit pane lead for attached sessions.** a session attached from another Mac shares each pane's zmx daemon between two terminals, and only the one leading the pane sets its size. The lead used to follow whichever side last sent input, so a freshly attached pane kept the origin's size until a key was pressed there. A remote attach now claims the lead in every pane, so the panes take the attaching Mac's size at once. A pane that does not lead is covered by a panel saying where it is in use, and a keypress without Command, or `agtermctl session lead`, takes the lead back. When the leader goes away the pane re-attaches by itself, and `surfaces[].lead` in `tree` reads the role back. On the Mac a covered pane runs on, `session type`, `session text` and `surface cursor` keep working under the cover; commands that act only on the local surface refuse there and name `session lead`. Both Macs need 0.32.0, and a Live session still running an older zmx keeps the old behaviour until it is recreated #635 @umputun
- **attached Macs follow the origin's split layout.** the origin publishes its split layout on the presentation stream, and a Mac that attached the session applies the axis, hide and show, and swap to the panes it already has, and closes a pane the origin removed. A layout never opens a pane: a split opened on the origin after attach appears on the next attach. Local panes, the divider ratio and keyboard focus stay local #636 @umputun
- **title-bar context mirrored to attached Macs.** an attached session shows the origin's `session context`. A context set on the attached row overrides it, and `session context --clear` there brings the origin's latest value back #634 @umputun
- **markdown HUD.** `session hud open --markdown` renders headings, emphasis, lists, code blocks, quotes, rules and tables, with a 4096-character cap in place of plain text's 256, so an agent can keep a multiline status panel over the session. `--font-size PT` sets the panel's own font size at open and stays fixed for its life, an `update` must repeat `--markdown` or the panel returns to plain text, `--file FILE` reads the message from a file, and the tree's `hud` node reads back `markdown` and a requested `fontSize` #641 @umputun
- **per-pane session background.** `session background image|text|color|clear` take `--pane left|right|scratch`, so each pane of a split can carry its own tint or watermark over the session default. Left and right overrides follow their terminal through swaps and relaunch, a scratch override ends when that scratch terminal closes, and `tree` reports `paneBackgrounds` next to `background`. Asked for in discussion #643 #647 @umputun

### Improved

- `agtermctl` answered every refused or missing control socket with `is agterm running?`, although macOS refuses a live app with a full backlog the same way. It now checks the app's ownership lock and says the owner is present but not accepting connections when the lock is held #633 @umputun
- a new cookbook recipe, `remote-image-paste`, copies the image on this Mac's clipboard to the Mac a `zmx attach` session runs on with one chord, so ctrl+v pastes it there as a real image. Related to discussion #645 #648 @umputun
- the `two-agent-chat` cookbook recipe lets the two agents sit in either pane, where a split arranged the other way refused every send 8981b754 0d9a5471 @paskal

## v0.31.0 - 2026-09-20

### New Features

- **remote presentation for attached sessions.** a session attached from another Mac drew its agent status, control notifications, HUD, asks and overlays on the origin only, because the programs and their `agtermctl` run there. The attaching Mac now opens a presentation stream and mirrors status, control notifications and HUD onto its own row and pane. One attached Mac also becomes the session's presenter, the first whose stream asks for the role while none holds it, so an `ask open` or `session overlay open` newly aimed at that session opens there instead. The overlay's program still runs once on the origin, under an ssh terminal the presenting Mac opens, and its exit status answers the caller. Other viewers mirror and ask for the role again only when they reconnect. `presentation.mode` on an attached row reads `presenter` or `mirror`, `presenters` on the origin counts the streams mirroring it and says whether one presents it, and a remote row whose stream is connecting or failed swaps its cloud glyph for `icloud.slash` with the reason in the tooltip. Losing the stream is the only revocation: a terminal ask goes back to the origin and waits there like a local one, a GUI ask the origin cannot place ends cancelled with `presentation-lost`, a finished `--wait` surface closes, and a running overlay keeps its program until its own ssh ends. Two limits in this first version: closing a viewer pane can clear the origin's still-current mirrored status and HUD until the next update or reconnect, and a GUI ask replica hides rather than cancels when its target leaves the screen #629 #630 @umputun
- **workspace tree for the flagged view.** the flagged view can nest its rows under their workspaces instead of listing them flat; a workspace holding nothing flagged is left out. **Settings ▸ General ▸ Flagged view layout** picks it for every window, a workspace badge counts unseen notifications only from its flagged sessions, a group shares its collapse state with the ordinary tree, and switching mode or layout reveals the selected session. `agtermctl sidebar flagged-layout [flat|tree|toggle]` sets it and the tree reads it back #621 @umputun
- **f1 through f20 as keymap keys.** `keymap.conf` rejected every F-key name, so no built-in, custom command or global hotkey could use one. They now work with or without modifiers, as a leader, and as `global-hotkey f5`, which takes that key from every application including agterm. A bound F-key keeps ownership of its press through the repeats and the release, so a held key neither refires the action nor leaks the key into the terminal. On an Apple keyboard, use Fn/Globe or enable standard function keys to send F1-F12 #619 @umputun

### Improved

- the custom command failure panel is now opt-in per command, where 0.30.1 posted one for every custom command that failed. A command turns it on with `--error-hud` in `keymap.conf`, placed with `--error-position POS` and `--error-pane left|right`. macOS banners are unchanged, an opted-out command creates no stderr capture file, and `keymap list` reads all three options back #622 @umputun
- `statusChangedAt` is stamped on every accepted status set, idle included, and the tree reports it whenever it exists, so a script can tell when an idle session's status was last set. A session that never had a status, or was restored, still reads nil. Asked for in discussion #196 #617 @umputun
- a new cookbook recipe, `truthful-agent-lights`, replaces the Stop hook's unconditional `completed --auto-reset` with a classifier over the tool processes still running under Claude Code, and adds a scheduled sweeper that clears a stale glyph or restores an activity one #462 @x9x9x9x9x9x91

### Bug Fixes

- `tree` and `window list` stalled the app's main thread for the full three-second zmx timeout once four Live daemons existed, so the UI froze on every call and stuttered continuously while agent hooks polled it. The app read the child's stdout only after it exited and zmx writes its listing row by row, so the 512-byte pipe buffer filled and both sides blocked. Each pipe is now drained to EOF while the call waits, and the pipe fds are close-on-exec so a surface spawn cannot carry a write end into a long-lived `zmx attach` #624 @p4elkin #623
- a write end inherited by a long-lived surface child could leave reader threads, their descriptors and their buffers stuck for that child's lifetime. The zmx and ssh runners now share one cancellable capture, a missed output deadline cancels both read channels, and the ssh runner gets the same close-on-exec pipes and bounded post-exit join #627 @umputun
- `agtermctl --json` re-encoded the decoded response, so any field the CLI build did not model was dropped with `ok` true and exit 0. The server's line is now printed unchanged #628 @umputun #625
- deleting a window before its scene claimed it left the id queued, so the next window to appear popped the dead id and closed itself as a stray 11015c33 @umputun #626
- a cookbook stuck-shape comparison treated every row carrying no shape override as stuck when `AGT_SHAPE_STUCK` was blank, so the sweeper pulsed over the machinery tint #620 @x9x9x9x9x9x91
- the bundled agent skill's description exceeded the 1024-character agent skills limit after 0.30.0's event hooks additions, which pi warns about. It is trimmed to 975 and a test fails past the limit 8abf983b @umputun #631

## v0.30.1 - 2026-09-16

### Improved

- a custom command that fails posts a panel over the session carrying the command name, the exit status or launch error, and the last usable line of stderr when the command wrote one. A failure previously reported only through a macOS banner, so with notifications off a broken chord looked identical to one that did nothing. The panel clears after ten seconds and does not replace a running program overlay #613 @umputun
- `session hud open` and `session hud update` take `--hide-after SECONDS`, so a HUD can carry its own lifetime instead of staying until something takes it down #613 @umputun
- the bundled zmx 0.8.1 is rebuilt for the app's arm64 and macOS 14 baseline #616 @umputun

### Bug Fixes

- on macOS 27 with a comma-decimal locale, SF Symbols drew missing or malformed and a modal alert could take the app down. libghostty adopts the user's locale during init and CoreSVG parses symbol geometry through it, so a comma decimal separator mis-sized symbols and a zero-sized rasterization inside a modal's render aborted the process. A crash during quit also skipped the final session-state save. The numeric locale is now pinned after init, and spawned shells keep the user's locale #615 @umputun #611
- building zmx from source failed under the macOS 27 SDK, which needs a protocol zig 0.16's bundled `float.h` does not implement. Setup applies a compatibility shim to the installed zig's header and keeps the original as a backup #615 @umputun #611
- close the excess gap between sidebar disclosure triangles and row icons on macOS 27; earlier macOS layouts are unchanged a883cc18 @umputun

## v0.30.0 - 2026-09-15

### New Features

- **event hooks.** `hooks.conf`, next to `keymap.conf`, runs a command for matching control events with one `on <kind> <command>` line per hook, so a script reacts to status changes, notifications, sessions and the tree without a subscriber process of its own. The command runs through `/bin/sh -c` with the event JSON on stdin and the event and its target in `AGT_*` environment variables; the docs list the kinds and variables. Events queue in order while a hook is still running, and `agtermctl hooks list` shows failures and dropped events. `status` events now carry `previous`, and two new kinds, `pane.split` and `pane.scratch`, fire when a split or scratch pane is shown or hidden. **File ▸ Edit Hooks…** opens the file in an overlay and reloads it on close, and **Reload Hooks** and `agtermctl hooks reload` reload it. A hook that emits an event of its own kind can keep triggering itself, and nothing detects that loop #607 @umputun
- **remote.opened and remote.closed events.** A session created by `zmx attach` emits them beside `session.created` and `session.closed`, with the ssh destination as `host`, `AGT_EVENT_HOST` in a hook and `host=` on the human `agtermctl events` line. They follow the local row, not the ssh connection: a soft close emits `remote.closed`, undo emits `remote.opened`, and closing only the split emits neither #610 @umputun
- **agtermctl terminfo install.** `agtermctl terminfo install DESTINATION` copies the bundled `xterm-ghostty` entry into the remote account's `~/.terminfo` over one ssh connection, the fix for `less`, `vim` or `apt` on that host warning that the terminal is not fully functional. It passes only `-p`, `-i`, `-J` and `-F` to ssh, shows ssh's own password and host-key prompts, and exits 3 when the host has no `tic`. Nothing runs automatically and `ssh` stays the real `ssh` #609 @umputun #605
- **attention list across every open window.** ⌃⇧I and the title-bar bell list non-idle sessions from every open window in one blocked, active, completed order, with the window name in each row's subtitle once more than one window is open. Picking a session in another window raises that window first; a blocked or completed session reveals the pane that set its status. Rows for a closed or covered window, or a removed session, are disabled, and the bell popover scrolls past about ten rows. The Dock menu and ⌃⌥↑/↓ stay scoped to one window #596 @umputun
- **workspace name in the title bar.** A **Workspace name** toggle in Settings ▸ Interface, off by default, puts the active session's workspace in front of the identity as `workspace — session — window`, cut to 24 characters, so the bar says where a session lives while the sidebar is collapsed #601 @umputun #598
- **pick --select.** `agtermctl pick --select ID` opens the picker with that item highlighted and scrolled into view, so a picker of windows or sessions can start on the current one and Return on an untouched list stays put. A `--query` that filters the item out leaves the first visible row highlighted, and an id that names no supplied item refuses the open #597 @umputun
- **AGT_PANE_ID for custom commands.** `{AGT_PANE_ID}` and `$AGT_PANE_ID` carry the stable token of the pane a command fired in, the value its shell holds as `AGTERM_PANE_ID`, so a command keeps addressing the same terminal with `--pane-id` after a swap or promotion changed what `AGT_PANE` reports. A chord pressed in an overlay gets the covered pane's token, and a launcher fired with no session gets an empty value #603 @umputun

### Improved

- the bundled zmx moves to v0.8.1. A Live session answers terminal identification queries again once the last terminal detaches, where the old build stopped answering after the first attach and a query sent before a responding terminal attached could time out. Scrollback rises to 10,000 lines. A Live session started by an older agterm keeps its running zmx, and with it the old behaviour, until that session is recreated; attaching to it still works #604 @umputun
- `docs/troubleshooting.md` covers an Accessibility grant made for an older build, where tools are denied while Settings still shows agterm enabled, with the reset and re-grant steps. The bundled agent skill can check the stored grant against the running binary 566449f @umputun
- two cookbook recipes. `window-switcher` jumps to a window by its number in library order, closed windows included, or picks one from a native picker showing each window's blocked and completed sessions #599 #600 @anadale. `long-commands-status` wraps a shell command in `agst`, which sets the session's status to active while it runs and to completed or blocked when it exits #608 @Rulexec

### Bug Fixes

- the Interface and Agent Status tabs in Settings overflowed their fixed frame and scrolled after 0.29.0 added controls to both. The window is taller and the Typing hint is gone #593 @umputun

## v0.29.1 - 2026-09-11

### Bug Fixes

- the Reset Live Sessions… row in the Agterm menu had no icon, so it rendered indented in the blank icon slot, and it sat next to Settings… where it read as a preference. It now sits in Quit's group directly above Quit Agterm, with an icon, since it quits and reopens the app 3c91481 @umputun

## v0.29.0 - 2026-09-11

### New Features

- **Reset Live Sessions.** A Live pane created before the session host existed, or whose host has exited, keeps its own macOS permission identity, so a tool in it asks for the microphone again after every update and restarting agterm does not repair it. **Agterm ▸ Reset Live Sessions…** and `agtermctl zmx reset --force` replace every such pane at once: the dialog says how many live sessions it resets, agterm quits and reopens itself with the same sessions and layout, and each captured command starts again where possible. Other work running in those sessions stops, and agent conversations may need to be resumed by hand. Sessions already under the host keep their processes. The reset runs only while Live sessions is both the configured and the launched mode, the marker is narrowed to panes that still match before anything is killed, and a partial reset posts a notification saying how many sessions it covered. The tree and `zmx list` read a pending reset and this launch's outcome back under `liveReset` #587 @umputun
- **step between open windows.** Sessions, workspaces and panes had previous and next; windows did not, which left ⌘` or a script over `window list`. `previous_window` and `next_window` are keyless keymap builtins, Navigate ▸ Previous Window and Next Window have matching palette rows, and `agtermctl window go --to next|prev` does the same from the control API. The step walks the open windows in library order and wraps, so a closed window is not a stop on the way round; with fewer than two open windows the items disable and the command answers that there is no other open window #591 @umputun
- **a title-bar button for custom commands.** Hidden by default and switched on in Settings ▸ Interface, it lists every `keymap.conf` command with its chord in a popover, the mouse form of Navigate ▸ Custom Commands. A row runs through the same modal gate as a palette pick and returns focus to the terminal. Once the file holds more than five commands, up to five of the most-run ones lead the popover above a separator; every run counts, whether by chord, palette or popover, and use changes only which commands sit on top, never their order. A second `command` line with a name already taken is skipped with a diagnostic, since the name is the key a run count is stored under #582 #584 @umputun
- **choose when typing clears a blocked or completed status.** Settings ▸ Agent Status ▸ Status reset picks between On first key, today's behaviour and the default, On Enter, which clears on a bare Return or keypad Enter only so a reply you started and walked away from keeps the glyph until you send it, and Disabled, which leaves the status to the agent's hooks and Clear Status. Esc and Ctrl-C still clear an `active` glyph in every mode. `session type` follows the same setting, with a newline in the text counting as Return #585 @umputun
- **the attachment host in custom commands, and local launches from a remote session.** A session attached with `agtermctl zmx attach` reports a remote working directory, and a custom command, the scratch terminal, an overlay opened without `--cwd`, the quick terminal, a local split, Duplicate Session and a new session under the current-directory setting inherited it as if it were local. Custom commands now see `AGT_SESSION_HOST`, the ssh destination the session was attached from and empty for a local session, while `AGT_SESSION_PWD` keeps the reported path. Those local launches keep an existing local directory at the reported path, which supports mirrored checkouts, and start in the local home directory otherwise #576 @umputun

### Improved

- the environment reference states the `TERM_PROGRAM=agterm` identity, and documents the `FORCE_HYPERLINK=1` workaround for Claude Code, which prints links as plain URLs because agterm is missing from its terminal allowlist 9dd5294 @umputun
- the session-host tests build their own socket client instead of copying `/usr/bin/nc`, a copy of which is killed on exec on some macOS builds, seen on 26.0.1 with SIP enabled, so `swift test` passes on such a Mac again #578 @p4elkin

### Bug Fixes

- status sounds stalled typing in every session. Playback and the first lookup of a sound name both ran on the main thread, the one that delivers keystrokes, and a sound file on slow storage held it for seconds. Both now run on their own queues; cached names and the built-in sounds still answer at once, so an unknown name is still refused in the reply #579 #580 @umputun
- the quit alert warned that all running shells end while Live sessions mode leaves them running. It now follows the active launch mode and shows counts only in Live mode ce28343 @umputun
- the two-agent chat recipe refused to send to a Codex pane while Codex drew its idle animation, and a send with text in the composer failed because the animation kept drawing over typed characters. For the Codex pane only, animation rows count as blank and a particle stands for the cell it covers, so the prompt is found, typed text settles, and the body is verified once more before submit #588 @paskal
- the Homebrew cask seed carried a deprecated postflight block that Homebrew warns about on every install and a description `brew style` rejects. Both were fixed by hand in the tap and never came back here, so a reseed would have shipped them again c0b5a85 @umputun

## v0.28.0 - 2026-09-09

### New Features

- **Live panes keep their agterm attribution across a restart.** A Live pane's session outlives the agterm process that started it, and macOS then charges its microphone and App Data requests to each command inside the pane rather than to agterm, so the consent dialog returns on the next command and reattaching does not stop it. agterm now runs a small bundled host, one per state directory, that outlives the app and keeps those sessions resolving to agterm. Verified on a signed build: a microphone request from a pane created through the host was charged to the app under the existing grant, with no new dialog. Panes created before this version keep the old behaviour until they are recreated; restarting does not repair them. `agtermctl tree` reads the state back per pane #574 @umputun
- **the remote host on a session attached to another Mac.** The title bar shows a cloud and the ssh target after the session and window names, on line one in both normal and compact modes, and remote sidebar rows take the same cloud in place of the arrow-in-rectangle glyph. It is shown by default and hidden with **Remote host** in Settings > Interface. The host takes its natural width up to 240 points and truncates in the middle when space is short; on a narrow compact bar the identity and the host keep their place ahead of the session context #572 @umputun
- **three control-API additions.** The tree reports a split pane's working directory as `splitCwd`, the one thing a caller could not read about a split it could otherwise inspect; it falls back to the restored directory and then to the primary's, so the human `tree` line prints it only when it differs from the primary while the JSON carries it either way. `window resize` now answers with the size it actually applied, which can be smaller than asked when the window minimum or the display's visible frame clamps it, instead of a bare `ok` that left a second `window list` as the only way to find out. `zmx attach` takes `--window`, so a script can place a remote session in a background window without selecting that window first and moving the user's focus; an invalid or closed target fails without creating a session rather than falling back to the frontmost one #566 @umputun

### Improved

- two cookbook recipes. `remote-claude-session` runs Claude Code in a tmux session on a remote host from one chord, so closing the laptop no longer takes the agent with it: the tab reconnects by itself after a dropped connection, comes back reattaching after an agterm restart when **Restore sessions** is on **Re-run commands** or **Live sessions**, and the agent's status still reaches its sidebar row through a relay on the Mac that accepts one line and only if it is a status for the tab it was started for. `claude-account-swap` switches the left pane between two or more authenticated Claude accounts and carries a summary of the conversation you were having into the new one, so the work continues instead of restarting; it identifies both the transcript and the account it belongs to from the map Claude itself writes, and refuses the switch when that map's owning process is gone, replaced or backgrounded #563 @andr81 #571 @umputun

### Bug Fixes

- a chord fired from a scratch or overlay pane could run against a different session than the one on screen, with ordinary unique session ids. The sidebar selection moves ahead of the asynchronous focus handoff, and in that interval the chord matched no session and built its context from the active one instead, so every `$AGT_SESSION_*` value described a session the user was not looking at and a command typing back through `session type --pane` could write into the wrong shell #568 @umputun
- reopening a session from Recent Closed into a different window and then undoing the original close could leave the same session live in two windows, after which every lookup keyed on its id answered with whichever window came first. Reopen now restores into the window that still owns the session, its own window ahead of the one holding its workspace, and rebuilds nothing another open window already holds. An incomplete restore keeps the recent entry until every member is accounted for, since a member left in no window would otherwise become unreachable the moment the entry went #568 @umputun
- `window list` kept naming the previous window as active after another window was revealed, while untargeted commands already routed to the new one, so a script reading the active window acted on the wrong one. Revealing a window assigned the frontmost id without publishing the change, and the reporting path gates both the saved index and the change notification on that id having changed 9416408 @umputun
- renaming a session in the flagged sidebar view stripped the row's ` : workspace` tail, leaving it reading `api` where its neighbours read `api : work` until a badge or status delta redrew it. The editor seeds its field with the bare session name so an edit cannot bake the decoration into the custom name, and nothing put the tail back when the rendered label did not change f81b4db @umputun
- the two-agent chat recipe refused to send while Claude Code was drawing one of its own suggestions in an idle composer. agterm drops the dim styling that marks a suggestion, so on pane text alone it reads as a draft, and a mid-session suggestion is a free-form prediction with no fixed wrapper that no text pattern can separate from one. The check now gates on where the caret rests rather than on the composer's content #569 @umputun #564 @pySilver

## v0.27.1 - 2026-09-07

### Bug Fixes

- answering a terminal-style `ask` and then closing its session over the control socket left the reselected session without keyboard focus until the user clicked. A stale active update let the closing session's terminal view reclaim focus after its surface had been destroyed. The terminal deck now rejects focus requests for retired surfaces, so keyboard input stays with the reselected session #562 @umputun

## v0.27.0 - 2026-09-07

### New Features

- **`ask`, a question dialog driven from the control API.** `agtermctl ask` puts a question with a title, an optional message and one to six caller-named buttons in front of the user and returns the pressed button, `escaped` for Esc or Cmd-W, or `cancelled` when the dialog is withdrawn by `ask cancel`, quit or the loss of what it was anchored to. The CLI blocks until answered and reports the outcome in its exit code, so a hook or an agent can ask before acting and read the answer in one call. Return picks the highlighted button, Tab and the arrow keys move between them, and letter hotkeys pick directly. Two styles share the contract: the default `terminal` style draws in theme colors with the terminal font, and `gui` reuses the picker's material panel with native buttons. A terminal ask belongs to the session it targets, one per session and optionally narrowed to a pane, so it covers only that region and the rest of the window keeps working: an agent in one pane can ask about the other pane without losing its own keyboard, and asks can stand in several sessions at once. A GUI ask is window-modal and shares the pending slot with `pick`. The tree reads a pending ask back on the session node, or as `askPending` at the top level for the GUI style #556 #561 @umputun
- two cookbook recipes. `agent-reset` replaces `claude-clear`: one chord clears Claude Code or Codex in the pane it fires from, and fired from the main pane it also clears the split's agent and the session's title-bar context. Codex takes the command and its submit as two writes with a pause between, because its composer buffers a burst of characters as a paste and an Enter arriving inside that window becomes a newline instead of a submit. `session-context-nudge` is a Claude Code prompt hook that shows the model the current `session context` line so it replaces it when the task changes. Both need 0.26.0 #552 #554 @umputun

### Improved

- the bundled agent skill says that an alternate-screen buffer has no scrollback, so neither `session text --all` nor `--lines` reaches output an editor or a TUI has already scrolled away, and points an agent reading a finished Claude Code reply at the transcript file instead 7ab68107 @umputun

### Bug Fixes

- the system Dictation shortcut did nothing with agterm frontmost. Dictation asks the focused text client for its selection and an insertion rectangle before it starts, and the terminal view reported no selection at all, so it had nothing to anchor on and declined. The view now reports an empty caret outside IME composition, and the stale IME range that survived a finished composition is dropped #557 @umputun #555
- `surface cursor` answered `failed to read cursor position` for a hidden split pane while `session text` and `session type` reached the same pane. The cell width was converted at the view's window scale, and a hidden pane's view has no window. The width now comes from the scale libghostty keeps for the surface, so a hidden pane reads without being revealed #560 @umputun
- the Codex status adapter reported a finished turn as blocked whenever the final message contained a `?` anywhere, so a literal one in prose turned a completed row into a waiting one. Code blocks and spans are set aside, and a mark counts as a question only when it follows a word and is followed by optional closing punctuation, then whitespace or the end of the message #550 @umputun
- the cookbook's two-agent chat refused every send to a Claude Code pane whose `statusLine` pads its first segment, because a status row under the composer had to start with exactly two spaces. Two or more are accepted now, and the dialog and numbered-choice refusals are unchanged #558 @umputun #553

## v0.26.4 - 2026-09-04

### Bug Fixes

- a pane-scoped `session.hud` drew one detail-column origin off whenever the session was split: shifted right by the sidebar plus divider and up by the titlebar plus its hairline, with the width correct. `HSplitView` hosts its arranged subviews across an AppKit bridge that a SwiftUI named coordinate space does not cross, so inside a split the pane measured itself in window coordinates and the overlay layer applied that origin a second time. A lone pane sits outside the split, which is why only split sessions were wrong. The pane bounds now travel as anchors that the overlay layer resolves in its own space, on either split axis #545 @umputun #384
- a top/bottom split restored in the background laid its top pane under the compact titlebar on macOS 27 and stayed there until the window was resized. The pane was laid out at a stale 1pt safe-area inset, and on reveal macOS 27 never re-entered the layout pass that re-applied the divider at the real one. The divider is now also re-applied from the split's own resize notification. An inset change during a divider drag no longer snaps the divider back to the stored ratio under the pointer #546 @umputun #539
- a session whose program animates its title through OSC 2 made the sidebar rebuild that row's cell on every tick and re-ran the whole window body for the title bar. A label-only change now writes the live cell's text in place, and the OS title and the visible title row are read by two small child views, so a title tick no longer invalidates the window's view graph. Measured with a title changing at about 10 Hz, the parent body's main-thread samples went to zero #547 #548 @umputun #516

## v0.26.3 - 2026-09-04

### Bug Fixes

- a session restored by Live sessions mode could show its full path in the sidebar instead of its name. libghostty answers an OSC 7 with a synthetic title equal to the working directory, and that title does not reliably reach the app after the directory report it belongs to, so the guard meant to drop it was armed only some of the time. Measured across a restore of 60 sessions it hit about a third of the panes. Live restore is what made it stick rather than flicker: a reattached shell draws no new prompt, so nothing wrote a real title over the wrong one, and the path stayed until the pane was typed into. The title is now compared against the pane's own directory, which needs no ordering, and the split pane is compared against its own #544 @umputun

## v0.26.2 - 2026-09-03

### Improved

- `session.paste` takes `--pane`, so a split or scratch pane can be written to as well as read from. It was main-pane only while its documented read-back `session.text` already took `--pane`, so scripting a split meant writing one pane and reading another, and multi-line text could not reach a split at all: `session.type` sends a real Return per newline, which submits the text line by line #529 @ssgreg
- the two-agent-chat recipe survives a freshly started Claude Code, whose empty composer draws a `Try "..."` suggestion built from the user's own frequently-edited files. The recipe read that as a draft and refused the first send of every exchange. It also gets more reliable delivery, a stated rule for who writes when both agents are asked to work in one worktree, and a setup step that no longer tells the reader to edit a path the skill files do not contain #527 #534 #535 #538 #541 @paskal #543 @umputun
- `session.hud` can be placed in one pane of a split. `hud open` and `hud update` take `--pane` and `--pane-id`, resolved the way `session restore` resolves them, and the resolved pane identity is stored so a pane swap or a split-survivor promotion carries the panel with its shell. Anchors and `--size-percent` measure against that pane's live bounds, where before they measured the whole session rect, so an agent asking for `bottom-right` got the panel over the other pane and a long message could cross the divider. The pane comes back on the tree #536 @umputun
- the repeating "would like to access data from other apps" prompt is explained, and it now carries agterm's own wording through `NSAppDataUsageDescription`. macOS calls this App Data, holds the consent against a running process rather than storing it as a setting, and charges it to the process it holds responsible. A pane carried across a restart by Live sessions mode was started by an agterm that has since exited, so every command in it answers as its own responsible process and the dialog returns on the next one. Nothing here stops it coming back: App Data has no entry of its own in System Settings, and Full Disk Access is the only permanent answer #537 @umputun

### Bug Fixes

- a session restored in the background laid its split out against a stale 1pt safe-area inset, and the divider was never re-applied when the real inset arrived. The next window resize then fell back to SwiftUI's own even split, and the same reveal step grew the primary wrapper by 31pt, which is what showed as a top pane drawn under the compact titlebar. The split ratio is now measured below the titlebar, so an even ratio also renders even in compact mode #542 @umputun #539 @p1gmale0n
- `session.type`, `session.text` and the `font` commands refused the pane aliases they document. The shared CLI accepted `primary`, `split`, `bottom` and the rest, then the app matched raw spellings and rejected them, so `agtermctl session text --pane split` failed against 0.26.0 while `--pane right` worked. The spelling is parsed once in the dispatcher now #530 @ssgreg

## v0.26.1 - 2026-09-02

### Improved

- the bundled agent skill's description is less than half the size. Most of what it held sat past the 1536-character cap an agent listing applies, so nothing ever read it, and the trigger list that made up the bulk repeated the prose above it word for word. What reaches the model is now the whole of it #528 @umputun

### Bug Fixes

- in Live sessions mode a `session new --command` longer than 1024 bytes arrived truncated and was never submitted, leaving the command half-typed at a shell prompt. A freshly created live pane fed its command through the pty, where macOS keeps 1024 bytes of a line and silently drops the rest along with the newline that would have run it. The command now goes to zmx as a create-only payload, the route a restored pane already took, which also gives a fresh split pane the command that previously never ran at all #533 @umputun

## v0.26.0 - 2026-09-02

### New Features

- **Live sessions, an experimental restore mode.** Sessions have always come back after a restart with their directory, font size and split state, but what comes back is a fresh shell, so whatever was running is gone. Live mode keeps the process instead: each local primary and split pane runs through the bundled zmx multiplexer, so quitting agterm ends the connection to the pane while the process itself keeps running, and the next launch reattaches to it. A build still compiling or an agent halfway through a task is still there. Turn it on in Settings ▸ General ▸ Sessions, where **Restore sessions** now offers **Live sessions** beside the existing Fresh shells and Re-run commands, or with `agtermctl restore mode live`. The mode is frozen for the life of the process, so it takes effect after restarting agterm. It needs zsh as the macOS login shell; an unsupported shell falls back to fresh shells and Settings says why. Experimental because this is its first release and it changes what a quit means: `agtermctl zmx list` shows every daemon and the pane holding it, `agtermctl zmx prune` clears unclaimed daemons with no attached clients, and switching back to Fresh shells or Re-run commands and restarting reaps every detached agterm daemon in that state directory #515 @umputun
- **Remote sessions, a first and deliberately limited version.** A session running on another Mac can be attached here, where it appears in the sidebar as an ordinary session marked remote, its split included. `agtermctl zmx tree HOST` lists what that machine has to offer and `agtermctl zmx attach HOST SESSION` grabs one of them. Everything goes over ssh and nothing else: no agterm-to-agterm protocol, no port, no listener. Each attached pane is an ssh process holding a connection for as long as the session is open, so closing it here ends your side while the far-side processes carry on. What this version does not do: one attach imports one session rather than a whole workspace, and because the attach is a follower the remote screen arrives at the far side's geometry and does not reflow until the first classified keystroke reaches it, which also means mouse input and Ctrl-L do nothing until then. The requirements sit on the far side rather than this one: it runs 0.26.0 too, its restore mode is Live sessions since that is what puts a daemon behind each pane, and it has `agtermctl` on the PATH that ssh gives a remote command. Key-based ssh auth is a precondition, because a non-interactive connection has nobody to answer a password prompt #524 @umputun
- no built-in remote picker ships with this yet. The two commands are the whole feature, and the cookbook's `remote-session-picker` recipe is what turns them into something to use: it lists the far side, puts the rows through agterm's own picker with each one's window, workspace, purpose, directory and running command underneath, then attaches whatever you choose. Wire it to a chord or a palette entry in `keymap.conf`. Building a selector into the app is deliberately left until the shape settles #524 @umputun
- `session.context` sets a per-session line saying what a session is for, shown in the title bar and carried on the tree. It survives relaunch and restore, and `session.duplicate` does not copy it #522 @umputun
- `session.swap` exchanges a split's two panes, moving the terminals rather than the layout: axis and ratio stay put while focus, overlays, status ownership and wait policy follow their terminal #513 @umputun
- `sidebar.width` sets the sidebar divider position from the control API, per window, and echoes the stored width so a clamped request is distinguishable from an honored one #512 @umputun
- `restore.capture` fills the captured-command slots on demand instead of only at exit, for the cases where an orderly quit never happens #452 @ssgreg
- cursor shape and blink are settable in Settings ▸ Appearance, which also gets its cursor and font controls rearranged #487 @s1ovac #489 @umputun
- the tree names the shell holding a pane's foreground, so a caller can tell a pane held by a recognized shell from one whose foreground state could not be read. It is not a prompt signal: a shell builtin or a loop runs inside the shell process, so a pane blocked on input looks the same #525 @umputun

### Improved

- hidden panes release their GPU buffers instead of holding them for the life of the app. agterm reports occlusion for panes that are not on screen, so a hidden shell stays live while its Metal swap chain is freed after a short grace. Measured on a Debug build with 12 sessions all printing output: 1.1 GB peak with every surface realized, settling to 199 MB once the 11 hidden ones released. It comes with a libghostty pin bump to 683d8db, which carries upstream's hidden-surface GPU work #492 @paul-nameless
- a launch that replays commands paces its pane startup rather than spawning everything at once, which was enough to make a large window's restore stutter #526 @umputun
- a sidebar row whose name is truncated reveals it on hover #520 @umputun
- `session.restore` reports which pane it actually wrote, which a caller addressing by pane token could not otherwise work out #495 @ssgreg
- a cookbook recipe closing a session automatically once the command in it finishes #488 @andr81
- the bundled agent skill writes every command with its area prefix. Six families were missing it, so an agent copying a command out of the summary ran something that does not exist #507 @umputun
- the two-agent chat recipe survives labelled Claude composers, multi-agent Codex resume, and transcripts recovered from a bridge #496 #505 #509 #514 @paskal #506 @umputun

### Bug Fixes

- an agent spawned from another agent's session repainted the spawner's sidebar row, so the wrong session showed the status #461 @x9x9x9x9x9x91
- one split pane's agent status could erase the other pane's block. A blocked pane now owns the status until it is answered, and a write from the sibling is refused whole rather than half-applied #523 @umputun
- the agent-hooks installer overwrote existing Claude hook data it could not read, and a bad custom regex printed a compile error before every zsh prompt #500 @umputun
- a failed restore save was acknowledged as ok, so a pin the disk had rejected read back as if it were in place #485 @umputun
- `session.overlay.open` accepted a `--size-percent` outside 1 to 100 instead of refusing it #498 @ssgreg
- the cookbook's session-badging recipe failed open when it could not badge an armed session #491 @andr81
- `session type --stdin` and `quick type --stdin` emptied the whole payload on one invalid UTF-8 byte and still answered ok, having typed nothing. Both refuse now. CI jobs also run under timeouts, where all six previously inherited GitHub's 360-minute default #521 @umputun

## v0.25.0 - 2026-08-25

### New Features

- the quick terminal can be sized as a share of the screen instead of a fixed ceiling. It was sized `min(90% on each axis, 1100x700 points)`, so past roughly 1222x780 the cap was the only term acting: on a 2560x1440-point display that is 21% of the screen area where the 90% share intends 81%, which meant scrolling sideways through a wide `git diff` with empty space around the panel. Settings ▸ Interface now offers Default plus a discrete 40, 50, 60, 70, 80 or 90 percent, and leaving it unset keeps the old size exactly. Reported in discussion #453 #459 @umputun
- `agtermctl version` reports which agterm is serving the socket, with no target and no window needed. Its human output also names the resolved path of the `agtermctl` that ran, which catches a stale CLI sitting ahead of the bundled one on `PATH`. The bundled agent skill learns the cookbook in the same release, so an agent asked to list recipes or set one up has something to work from instead of a bare URL #476 @umputun
- the tree's session node reports `statusChangedAt`, so anything reasoning about how old a status glyph is stops keeping shadow state of its own. Epoch seconds on the same clock as `ControlEvent.ts`, and it records when the status was last WRITTEN rather than when it last changed, so a hook re-asserting `active` on every tool event refreshes it #465 @umputun

### Improved

- a cookbook recipe putting two coding agents in one split, each typing a line straight into the other's composer, so you watch both halves of the exchange without relaying anything by hand #466 @umputun
- a cookbook recipe giving GitHub Copilot CLI the same per-session sidebar glyphs the installer already wires up for Claude Code, through Copilot's own hook support #464 @rychkov
- the macOS permission story is documented and its prompts say why. The troubleshooting guide explains the seven entitlement-gated services and what a grant actually covers, then separately covers the Files & Folders family, a different mechanism a user whose `ls ~/Downloads` failed had reason to read as unfixable. macOS asks for Desktop, Documents, Downloads, removable and network volumes in agterm's own words now too: the app already explained its other privacy prompts, and those five previously fell back to Apple's generic copy 1f9d673 #470 #474 @umputun
- the docs teach how to extend agterm rather than only documenting the pieces: a four-step section between Install and the concepts tour, each step adding one building block, ending at asking an agent that carries the bundled skill. A file browser is one keymap line, and nothing in the docs used to put that within reach #471 @umputun
- the backlog-picker recipe stopped offering to delete the records whose whole job is stopping a rediscovery. Its rules told the agent to drop any item nobody will ever do, which is what a `worth: no` record is, and it named a field as the dedupe key that the same file calls stale. It also briefs the decision before asking now. Reported in #478 a322fa6 @umputun

### Bug Fixes

- `ssh` inside agterm died the moment it started for anyone who had turned on ghostty's `ssh-env` or `ssh-terminfo` shell integration, a regression in 0.24.0. Both features work by replacing `ssh` with a wrapper calling a `ghostty` CLI that agterm's bundle does not carry. agterm now loads both flags off after the user's config, so the wrapper is never defined. Reported in #463 #475 @umputun
- the agent-status hooks stopped working silently whenever the app bundle moved after they were installed, with installing from the mounted DMG and then ejecting it the easy way in. The installed wrapper baked an absolute path and never checked it still existed, and it suppresses output and exits 0 by design, so the only symptom was sidebar glyphs quietly not appearing. It now tests the baked path and falls back to `PATH` #473 @bot-rogerthat
- a NUL byte in `session.type` or `quick.type` text truncated the injection and still answered ok. Worse than silent: the text run and its Return are separate keystrokes, so when a newline followed that run, the shortened line still got its Return and ran. Both commands reject it now #458 @umputun
- restoring a captured running command could leave a pane at a continuation prompt or run a different command. The line is typed through `initial_input`, so control bytes in it reach the shell's line editor before anything parses them as a command. A capture carrying one is refused instead of replayed #457 @umputun
- a custom command or chord fired from the right split pane exported the primary pane's working directory as `$AGT_SESSION_PWD`, and spawned its child there #482 @vladislav-yevtushenko
- the seeded `keymap.conf`'s Lazygit example omitted `--target`, so the overlay it opens could land in whatever session you had switched to by the time the command reached the server rather than the one the chord fired in #474 @umputun

## v0.24.0 - 2026-08-17

### New Features

- the quick terminal is a floating panel with a system-wide hotkey, so it can be summoned over any application and dismissed straight back to it. `keymap.conf` gains a `global-hotkey` verb for the chord #441 @umputun
- keyboard navigation between workspaces: `previous_workspace` and `next_workspace` builtins, `workspace.go --to next|prev`, and `toggle_workspace_collapse` to fold the workspace you are in. All three ship keyless #436 @umputun
- `session.overlay.copy` and `session.overlay.text` read an overlay's own surface. Both `session copy` and `session text` address the pane underneath, so a selection made inside an overlay used to read as `no selection` #437 @umputun
- `surface.cursor` reports a surface's cursor column, printed as a bare number so it drops into a command substitution #451 @umputun

### Improved

- libghostty advances to upstream main, fixing a crash on surface teardown and lifting the pin held since April. Building now needs Zig 0.16 #449 @umputun
- the shipped app drops three hardened-runtime exceptions it never used. The TCC entitlements are untouched #450 @umputun
- `ControlServer` logs through `os.Logger`, so the control socket is queryable under the subsystem `docs/troubleshooting.md` tells you to filter on #442 @umputun
- a cookbook recipe reporting a hook-driven agent's status onto its sidebar row when the agent runs inside a container #428 @nquo

### Bug Fixes

- an unattended restart lost every captured running command. The quit confirmation went up even for a quit the system asked for, and with nobody there to answer it the app was killed before it could save. Shutdown, restart and logout skip the prompt now, while a scripted quit still gets it. Reported by @ssgreg, who also sent the follow-up #446 #447 @umputun @ssgreg
- two `keymap.conf` lines colliding on one chord were settled by file order, so reordering unrelated lines could silently take a custom command's shortcut away #444 @umputun

## v0.23.0 - 2026-08-13

### New Features

- splits can run top and bottom, not only side by side. `⌘⇧D` splits horizontally and `⌘D` keeps the vertical one, each action creating, revealing, hiding or transposing as needed, so a live split changes orientation without recreating either terminal. `session.split` and `agtermctl` take an optional `vertical`/`horizontal` axis, `top`/`bottom` join `left`/`right` as pane aliases, and the axis survives restore. Dashboard moves to `⌘⇧G` #427 @umputun
- Close Split tears a split pane down, from the palette and as `session.split.close`. ⌘D only hid one: `hasSplit` stayed set and the shell behind it stayed alive, so the only teardown was typing `exit` in the pane, which does nothing for a shell inside docker, an ssh or an agent sitting past a prompt. The palette row shows whenever a split exists, so a hidden pane is reachable #421 @umputun
- a `map` or `command` line in `keymap.conf` can carry several alternative keybinds separated by `|`, so a mac-native chord and a tmux-style leader sequence can both reach one action instead of forcing a choice. It also gives built-in actions their first leader sequence: they dispatch as menu key equivalents and `NSMenuItem` holds exactly one character, so the parser used to reject one outright #420 @umputun

### Improved

- a cookbook recipe listing the SQLite databases in the session's repo in the native picker, newest first with size and age, opening the pick in tabiew. Files are matched on the SQLite magic header rather than the extension, and dependency directories are pruned as a rule #426 @umputun
- a cookbook recipe listing the repo's `docs/backlog` items in the picker and handing the pick to Claude Code as `/backlog <slug>`, each row carrying the item's triage call, age and location #422 @umputun
- a cookbook recipe opening the pane's selection, or its last 50 lines when nothing is selected, in revdiff inside an overlay, pasting the notes back at the prompt with each one quoting the line it hangs on. Where annotate-claude-replies reads Claude's own transcript, this reads the terminal, so it works on any agent, a stack trace or a `terraform plan` #419 @umputun
- README is a product synopsis again rather than the full reference, with the depth it carried moved onto the site's docs page #424 @umputun

### Bug Fixes

- a session created while the display was asleep never started, so a scheduled job's `--command` never ran although `session new` had already answered `ok`. `ghostty_surface_new` returns NULL for as long as the display sleeps, measured at 21 consecutive failures over 40s with a valid backing size, and nothing re-attempted, because the deck's retries ride SwiftUI layout and that does not run for an off-display window. Creation retries on display wake now, and `tree` reports `realized` per session #417 @umputun
- `session.paste`, `session.selectall` and `session.copy` answered as though they had acted when the target pane had no terminal behind it, the state a session sits in while the display sleeps. All three checked only that the surface slot was filled, which a parked view passes, so a script branching on the error text took the wrong branch or believed a paste that never happened. All three report `session not realized` now #425 @umputun
- a second instance resolving the same socket path took the running app's control socket for good, and only a restart recovered it. Ownership is an exclusive `flock` now rather than the unconditional unlink before `bind`, and a refused instance advertises `<socket>.unavailable`, so the shells it spawns cannot reach the owner's terminal #418 @umputun
- a tool capturing system audio inside a session got silence and no permission prompt. Core Audio process taps go through TCC's audio-capture service, macOS holds agterm responsible for whatever it spawns, and the Info.plist carried no `NSAudioCaptureUsageDescription`, so `tccd` refused to prompt and left nothing to grant by hand in System Settings either #432 @umputun
- the Install Agent Status Hooks alert could grow past the bottom of the screen, taking its OK button with it, `NSAlert` sizing itself to fit text it will not scroll. The two Codex manual-merge cases embedded the full 29-line hooks block; every outcome is one short sentence now, with an Open Docs button where the printed steps used to be #430 @umputun

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
