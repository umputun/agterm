# Annotate pane output

Mark up whatever the pane just printed in [revdiff](https://github.com/umputun/revdiff), and get your notes back at the prompt with the lines they point at.

The sibling [annotate-claude-replies](../annotate-claude-replies/) recipe does the same for a Claude Code answer, and does it better where it applies: it reads Claude's own transcript, so it gets every reply of the exchange in full, formatted, however far it has scrolled. This one reads the terminal instead. That costs the transcript's fidelity — you get the visible screen, wrapped and truncated as the terminal drew it — and buys everything else: any agent, any program, any command output, and no hook to install.

## What it does

One chord takes the text in front of you, opens it in revdiff inside an overlay on that session, and waits. You put a note on any line you want to ask about. On quit the notes are pasted at that session's prompt, unsent.

What gets captured is whatever you selected, or the pane's last 50 lines when nothing is selected. So it works on an agent's answer, but equally on a stack trace, a failing test run, a `terraform plan`, or a config someone just `cat`-ed.

Each note comes back with the line it hangs on, quoted above it:

```
> ERROR failed to open /var/lib/thing/state.db: permission denied

which user is it running as?

> retrying in 30s (attempt 4/5)

why is it retrying a permission error at all?
```

Two lines of yours in that example, in the order they were made, each next to what it is about. The paste is not submitted, so you read it, edit it, add a sentence, and send when it says what you meant.

## Requirements

- agterm 0.13.0 or later. That is where `$AGT_PANE` began reporting which pane a custom command fired from, which is how the capture and the paste stay on the right half of a split. Everything else it uses is older: `session paste` shipped in 0.11.0, `session text` in 0.5.0, and `session overlay open --block` and `notify` before either.
- [revdiff](https://github.com/umputun/revdiff)
- `python3`, which macOS ships
- macOS `pbcopy` and `pbpaste`, which the reply goes through

## Setup

Copy `annotate-pane.py` somewhere on your machine, say `~/.local/bin/`, and make it executable:

```sh
chmod +x annotate-pane.py
```

Bind it in `~/.config/agterm/keymap.conf`, with the full path to wherever you put it:

```
command "Annotate" ctrl+a>k ~/.local/bin/annotate-pane.py
```

Then **View ▸ Reload Keymap**, or `agtermctl keymap reload`.

Nothing is passed on that line: the script reads `$AGT_SESSION_ID`, `$AGT_PANE`, `$AGT_SELECTION` and `$AGT_SOCKET` from the environment the runner gives it, and opens its own overlay.

A custom command runs under the app's `PATH`, not your shell's. That is the launchd default — `/usr/local/bin` plus the system directories, with no `/opt/homebrew/bin` and nothing your profile adds. `python3` resolves from `/usr/bin` and `agtermctl` from `/usr/local/bin`, where **Help ▸ Install Command Line Tool…** symlinks it. `revdiff` usually resolves from neither, so the script also tries `/opt/homebrew/bin/revdiff` and `~/go/bin/revdiff`; set `REVDIFF` to the full path when yours is somewhere else. `AGTERMCTL` overrides the CLI the same way.

Two knobs at the top of the script: `CAPTURE_LINES`, how much of the pane to take when nothing is selected, and `OVERLAY_PERCENT` with `OVERLAY_TINT`, the size and color of the panel.

## Usage

Press the chord. Either select the lines you care about first, or press it on whatever is on screen.

In revdiff: move to a line, press `a` to write a note, `Ctrl+E` while typing it to open `$EDITOR` for a long one, `A` for a note about the output as a whole, `d` to delete the one under the cursor, `q` to quit and send what you wrote, `Q` to throw it all away. Quitting with no notes does nothing at all — no paste, no empty line at the prompt.

Run it from a shell with `--print` to see the reply on stdout instead of pasting it, which is the way to check the formatting without a prompt catching it. A session's shell is given `AGTERM_*`, while the script expects the `AGT_*` a custom command gets, so map them across:

```sh
AGT_SESSION_ID=$AGTERM_SESSION_ID AGT_PANE=$AGTERM_PANE AGT_SOCKET=$AGTERM_SOCKET \
    ~/.local/bin/annotate-pane.py --print
```

## How it works

The capture is `session text --lines 50 --pane <pane>`, or `$AGT_SELECTION` when a selection exists. `--pane` is passed explicitly because the pane the chord fired from and the focused pane are not the same thing: a chord pressed in a split's right half while focus sits left would otherwise capture the wrong side. Whitespace does not count as a selection — a stray drag leaves one, and reviewing it would open an empty buffer instead of the screen you meant.

The text goes to a scratch file and revdiff opens on it with `--only`, which is its no-VCS mode: the file is shown in full as context, no `+`/`-` gutter, annotations working normally. The overlay is opened with `--block`, so the script sits there until you quit. `--exit-code-on-annotations` makes revdiff exit `10` when it wrote notes and `0` when you quit without any, which is how the script knows there is nothing to paste without reading the file.

Blank tail lines are trimmed from the pane capture but never from a selection. `session text` returns the whole screen, so a pane holding six lines hands over a screenful of padding and revdiff opens on the emptiness below the content. Only the tail is trimmed: dropping leading blanks would shift every line number the annotations come back with.

The reply goes through the **clipboard**, saved and restored around the paste. That is not a shortcut. `session type` sends real keystrokes, so a multi-line reply submits itself one line at a time — the first line goes as a command and the rest land wherever that left you. `session paste` is the only bracketed-paste path the control API exposes, and it reads the system clipboard. Against a pty with DECSET 2004 on, `type` produced bare lines and `paste` produced one `^[[200~…^[[201~` block. So the reply arrives whole and unsent. The clipboard is put back the way it was found, so using the chord never costs you what you were carrying.

## Limits

Nothing is closed, deleted, or killed. The reply is pasted, never submitted; the only thing it touches outside the session is the clipboard, which it restores.

What you can capture is what the terminal drew. A wrapped line comes back wrapped, a box-drawing TUI comes back as box-drawing characters, and anything above the top of the screen is gone — `session text` without `--all` does not reach into scrollback, and raising `CAPTURE_LINES` past the pane height gains nothing. When the pane holds a long agent answer that has scrolled, select what you want before pressing the chord, or use [annotate-claude-replies](../annotate-claude-replies/) if it is Claude Code.

A note lands on one line. revdiff has no visual range select, and its one range mechanism — the word "hunk" in the note text, which expands the header to the surrounding hunk — needs a real diff and does nothing here, where every line is context. So a point about six consecutive lines is either six notes or one note on the first of them. Notes themselves can be as long as you like: `Ctrl+E` opens `$EDITOR` and the whole file becomes the note, newlines included. A file-level note (`A`) comes back with no quoted line above it, which is the way to say something about the output as a whole.

Only one at a time per session. The chord blocks on the overlay, and pressing it again while the overlay is up opens a second one over the first.

macOS only, for `pbcopy` and `pbpaste` — which agterm is anyway.
