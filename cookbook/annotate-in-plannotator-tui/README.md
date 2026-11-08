# Annotate in plannotator-tui

Mark up what a pane printed, or Claude Code's newest reply, in plannotator-tui, and send the notes back to the prompt you are sitting at.

Author: [@pySilver](https://github.com/pySilver)

## What it does

Two chords open [plannotator-tui](https://github.com/plannotator/plannotator-tui) in a floating overlay on the session you pressed them in:

- **Annotate pane output** reviews your selection, or the pane's last 50 lines when nothing is selected. Scroll back, select some old output and press the chord, and only that selection opens, however far up the scrollback it sits. It works on any program's output, not only an agent's.
- **Annotate replies** opens Claude Code's newest reply in that pane, rendered as markdown. `p` picks an older one.

You select text and mark it 👍 looks good, 💬 comment or ✗ delete, then press `S` to send and close. The notes come back as plannotator-tui's numbered feedback, each quoting what it is about:

```
# Annotations on terminal · claude in left pane

## Annotation 1
Comment on: "$ make test"
> why does this run twice?
```

Pane notes land at the prompt unsent, so you can add to them before pressing Return. Reply notes are submitted for you.

It covers the same ground as [annotate-pane-output](../annotate-pane-output/) and [annotate-claude-replies](../annotate-claude-replies/), with plannotator-tui in place of revdiff.

## Requirements

- agterm 0.26.2 or later. `session paste --pane` shipped there, which is how the notes reach a split or scratch pane; the `foregroundShell` fields in `tree`, which tell a pane holding a bare shell from one whose process could not be read, came in 0.26.0. Everything else is older: `session overlay open --block`, `--size-percent`, `--background-color` and `notify` shipped by 0.13.0.
- [plannotator-tui](https://github.com/plannotator/plannotator-tui) 0.9.9 or later: `brew trust plannotator/tap && brew install plannotator/tap/plannotator-tui`. The recipe drives the interface plannotator-tui built for Herdr (see *How it works*) and was written against 0.9.9. Herdr itself is not needed.
- Python 3.9 or later, standard library only. The `/usr/bin/python3` that comes with the Xcode Command Line Tools is 3.9.
- Claude Code, for the replies chord. The recipe finds the transcript through a Claude Code Stop hook, so replies from other agents are not reached. The pane chord works with anything.

## Setup

Copy `annotate.py`, `plannotator-host.py` and `save-transcript-path.py` into one directory, say `~/.local/bin/agterm-annotate/`, and make them executable:

```sh
chmod +x annotate.py plannotator-host.py save-transcript-path.py
```

`plannotator-host.py` must sit **beside** `annotate.py`, which finds it in its own directory.

Register the Stop hook by adding an entry to the `Stop` array in `~/.claude/settings.json`, alongside anything already there. If you run [annotate-claude-replies](../annotate-claude-replies/), its hook writes the same record and one of the two is enough.

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "python3 ~/.local/bin/agterm-annotate/save-transcript-path.py",
            "timeout": 5,
            "async": true
          }
        ]
      }
    ]
  }
}
```

Add the two chords to `~/.config/agterm/keymap.conf` and apply them with File ▸ Reload Keymap or `agtermctl keymap reload`:

```
command "Annotate replies"  ctrl+cmd+e  ~/.local/bin/agterm-annotate/annotate.py replies
command "Annotate pane output"  ctrl+cmd+a  ~/.local/bin/agterm-annotate/annotate.py pane
```

Pick chords that are free in your own keymap. A custom command cannot shadow a built-in, so one that collides is demoted to palette-only and the chord appears to do nothing; `agtermctl keymap list` shows what every chord resolved to.

Settings, read from the environment. Put them in front of the script in the keymap line:

- `AGTERM_ANNOTATE_LINES` is how many lines the pane chord reads when nothing is selected, 50 by default.
- `PLANNOTATOR_TUI` and `AGTERMCTL` take an absolute path when either binary is somewhere the script does not look. It tries `PATH`, both Homebrew prefixes and `~/.cargo/bin` for plannotator-tui.
- `AGTERM_ANNOTATE_DIR` moves the cache the hook writes, `~/.cache/agterm-annotate` by default. Set it for the hook too, or the two stop meeting.
- `AGTERM_ANNOTATE_LOG` moves the log, `/tmp/agterm-annotate.log` by default.

Whether each chord submits its notes is the `SUBMIT` table at the top of `annotate.py`.

## Usage

Select text in agterm first if you want a particular passage, then press the pane chord. With nothing selected it opens the last 50 lines. For a reply, wait until Claude's turn has finished in that pane, then press the replies chord.

In the viewer:

- Drag with the mouse to select, or press `i`, move with `hjkl` `w` `b` `0` `$`, press `v`, move again and press `Enter`. Then `a` looks good, `c` comment or `d` delete.
- In a reply, `j` and `k` step through the blocks and `c` comments on the whole block.
- `S` sends and closes. `E` sends and stays open; the notes are pasted once the viewer closes, and sending twice pastes the review once.
- `q` quits, and asks first when a note is unsent. ⌘W closes the overlay and sends nothing.
- `p` opens the picker of earlier replies.

A capture opens at its top. Scroll with the mouse wheel or PageDown; `G` does not jump to the end of a capture, because the capture is a single block.

## How it works

Outside Herdr, plannotator-tui sends feedback only to the clipboard. Inside Herdr it hands it to the agent by running `$HERDR_BIN_PATH agent prompt <pane> <feedback>`. So `annotate.py` opens `plannotator-tui herdr pane`, the entrypoint Herdr runs in a pane it opens, with `HERDR_ENV=1` and `HERDR_BIN_PATH` pointing at `plannotator-host.py`. The `PLANNOTATOR_TUI_*` variables tell it what to show: `PLANNOTATOR_TUI_TERMINAL_PANE` for a pane review, or `PLANNOTATOR_TUI_HOST`, `PLANNOTATOR_TUI_SESSION` and `PLANNOTATOR_TUI_NEWEST` for a reply. `PLANNOTATOR_TUI_DELIVER_TO` and `PLANNOTATOR_TUI_DELIVER_AGENT` name the target, which labels the Send button ("Send 1 to claude in left pane").

`plannotator-host.py` answers three calls. `pane read` returns the text `annotate.py` captured, `pane get` names the agent for the label, and `agent prompt` appends the feedback to an outbox file. Anything else gets an `unsupported` error in Herdr's own JSON shape, so a plannotator-tui release that calls something new says so in the viewer's footer rather than half working. A refusal works the same way: when the pane holds a bare shell, the host refuses the send, and the viewer keeps the notes, copies them to the clipboard and says why. A shell would read every quoted `> ` line as a redirect.

The paste waits until the overlay closes, because the overlay covers the pane the notes go to. Each send from a pane or reply review carries every note the review holds, so only the last send is pasted; pasting them all would repeat the early notes once per later send.

The gotchas that cost time:

- An overlay's command runs through `sh -c` with the app's GUI `PATH`, which has neither `/opt/homebrew/bin` nor `~/.local/bin`. A bare `plannotator-tui` there exits 127 and the overlay flashes shut, so the script resolves it to an absolute path. agterm runs the script itself detached with stdout on `/dev/null`, which is why it logs to a file.
- `session overlay open --block` exits with the program's status, so a non-zero code can also mean agterm refused before the viewer ran. The script reads the reply text: "overlay already open" and "not realized" become a banner, and the "no overlay result" that ⌘W produces is a dismissal, not an error.
- The theme is set to dark through `PLANNOTATOR_TUI_THEME`. On `auto` the viewer asks the terminal for its background color at startup, and a key typed into that window is lost.
- Putting text at a prompt unsent needs `session paste`, because `session type` sends a real Return for each newline. `session paste` reads the system clipboard, so the script saves it, pastes, and puts it back. Before the Return that submits reply notes it waits 0.4 s, since the agent is still reading a long paste when `session paste` returns.

## Limits

- **It types into your session, and the replies chord sends.** Pane notes are pasted at the prompt of the pane you pressed the chord in. Reply notes are pasted and submitted, so the agent acts on them without you reading them first; set `SUBMIT` in `annotate.py` to stop at the prompt instead.
- **It uses the clipboard.** What was on it is saved and put back, but only plain text; an image or rich content is lost.
- **plannotator-tui archives every sent review** under `~/.plannotator/feedback/<project>/`, quoting the text you marked. Turn that off with `"feedbackHistory": false` in `~/.plannotator/config.json`.
- **The hook writes to `~/.cache/agterm-annotate/` on every finished turn** in every agterm pane, whether or not you press the chord: one small file per session and pane, holding the transcript path. `last-notes.md` there holds the last notes sent. Nothing prunes the directory.
- It depends on plannotator-tui's Herdr interface, which that project documents for Herdr rather than as a public API. A release that changes it shows up as an error in the viewer's footer.
- A promoted pane can open the wrong replies. The hook keys its record on the pane the agent's shell started in, while the chord reports the pane it fires from now, and the two diverge after closing the left half of a split promotes the right one.
- No search inside the viewer, and a reply opens one message at a time rather than everything since your last prompt.
- One review per pane at a time; pressing the chord again while the viewer is open is dropped. A session that already has an overlay open cannot take another, so the chord says so and stops.
