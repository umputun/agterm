# Annotate pane output

Mark up whatever the pane just printed in [revdiff](https://github.com/umputun/revdiff), and get your notes back at the prompt with the lines they point at.

Author: [@umputun](https://github.com/umputun)

The sibling [annotate-claude-replies](../annotate-claude-replies/) recipe does the same for a Claude Code answer, and does it better where it applies: it reads Claude's own transcript, so it gets every reply of the exchange in full, formatted, however far it has scrolled. This one reads the terminal instead. That costs the transcript's fidelity — you get the screen as the terminal drew it, wrapped where it wrapped — and buys everything else: any agent, any program, any command output, and no hook to install.

## What it does

One chord takes the text in front of you, opens it in revdiff inside an overlay on that session, and waits. You put a note on any line you want to ask about. On quit the notes are pasted at the prompt of the pane you pressed in: the main pane, a split's right pane or the scratch. They arrive unsent wherever the program there has bracketed paste on, as agent CLIs, shell prompts and editors do; *Limits* covers the rest.

What gets captured is whatever you selected, or the pane's last 50 lines when nothing is selected. So it works on an agent's answer, but equally on a stack trace, a failing test run, a `terraform plan`, or a config someone just `cat`-ed.

Each note comes back with the line it hangs on, quoted above it:

```
> ERROR failed to open /var/lib/thing/state.db: permission denied

which user is it running as?

> retrying in 30s (attempt 4/5)

why is it retrying a permission error at all?
```

Two lines of yours in that example, in the order they were made, each next to what it is about. Under bracketed paste the paste is not submitted, so you read it, edit it, add a sentence, and send when it says what you meant.

## Requirements

- agterm 0.45.0 or later. That is where `session paste --stdin --pane-id` arrived, which pastes the notes into the pane the chord fired from without touching the clipboard. Everything else it uses is older: `$AGT_PANE` shipped in 0.13.0 and `session text` in 0.5.0.
- [revdiff](https://github.com/umputun/revdiff)
- `python3`, which macOS ships

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

Nothing is passed on that line: the script reads `$AGT_SESSION_ID`, `$AGT_PANE`, `$AGT_PANE_ID`, `$AGT_SELECTION` and `$AGT_SOCKET` from the environment the runner gives it, and opens its own overlay.

A custom command runs under the app's `PATH`, not your shell's, and which `PATH` that is depends on the version. From 0.22.0 it is the system directories plus the app bundle's own CLI directory in front and `/usr/local/bin` and `/opt/homebrew/bin` behind, so `agtermctl` and a Homebrew `revdiff` both resolve. Before 0.22.0 it is launchd's bare `/usr/bin:/bin:/usr/sbin:/sbin` — which does not include the `/usr/local/bin` that **Help ▸ Install Command Line Tool…** writes to, so nothing but `python3` resolves. The script covers both: it falls back to `/usr/local/bin/agtermctl`, and for revdiff to `/opt/homebrew/bin` then `~/go/bin`. Set `REVDIFF` or `AGTERMCTL` to a full path when yours is somewhere else; both are checked first.

Two knobs at the top of the script: `CAPTURE_LINES`, how much of the pane to take when nothing is selected, and `OVERLAY_PERCENT` with `OVERLAY_TINT`, the size and color of the panel. `ANNOTATE_LOG` moves the run log, which is `$TMPDIR/agterm-annotate.log` by default and is where a chord that appears to do nothing explains itself.

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

The reply goes in as a **paste**, through `session paste --stdin`, never as keystrokes. `session type` sends real keystrokes, so a multi-line reply submits itself one line at a time — the first line goes as a command and the rest land wherever that left you. A paste is framed as one `^[[200~…^[[201~` block when the program has bracketed paste on, so the reply arrives whole and unsent — with the caveat in *Limits*. The clipboard is never touched.

The paste is addressed with `--pane-id $AGT_PANE_ID`, the token of the pane the chord fired from, rather than its role: a swap or a promotion during the review can give the role to another pane, while the token follows the one you annotated. A pane closed while revdiff was open is refused, and the banner says why.

A nonzero exit from the overlay call is ambiguous — agtermctl can refuse before revdiff ever starts — so the script carries agtermctl's own sentence out rather than reporting the status as revdiff's.

## Limits

Nothing is closed, deleted, or killed. Two things are touched outside the session: the run log at `$TMPDIR/agterm-annotate.log`, and revdiff's own annotation history, which it auto-saves under `~/.config/revdiff/history/` for any review you quit with `q`, so a durable copy of your notes outlives the temp file the script deletes.

The reply arrives unsent against a program with bracketed paste on, which is what an agent CLI, a readline shell prompt and any full-screen editor turn on. Bracketed paste is the program's mode, not a property of the paste, so a destination with it off — macOS `/bin/sh`, a `read` loop, a bare REPL — takes the newlines as Return and runs the lines. That is what a manual ⌘V of the same notes would do there, in whichever pane the chord fired from, and nothing in the control API can ask which mode a program is in, so the chord cannot check first.

What you can capture is what the terminal drew. A wrapped line comes back wrapped and a box-drawing TUI comes back as box-drawing characters. Scrollback is reachable, though: `--lines N` reads the whole screen buffer rather than the viewport, so raising `CAPTURE_LINES` past the pane height picks up lines that have scrolled off. For a long agent answer, select what you want before pressing the chord, or use [annotate-claude-replies](../annotate-claude-replies/) if it is Claude Code — it reads the transcript and gets the replies formatted rather than as the terminal drew them.

A note lands on one line. revdiff has no visual range select, and its one range mechanism — the word "hunk" in the note text, which expands the header to the surrounding hunk — needs a real diff and does nothing here, where every line is context. So a point about six consecutive lines is either six notes or one note on the first of them. Notes themselves can be as long as you like: `Ctrl+E` opens `$EDITOR` and the whole file becomes the note, newlines included. A file-level note (`A`) comes back with no quoted line above it, which is the way to say something about the output as a whole.

Only one at a time per session. The overlay slot holds one occupant, so a second press is refused with `overlay already open` and the banner says exactly that; the review already up is untouched.
