# Annotate Claude's replies

Mark up a long Claude Code answer the way you would mark up a diff, and send the notes back to the prompt you are sitting at.

## What it does

One chord opens everything Claude has said since your last prompt in [revdiff](https://github.com/umputun/revdiff), inside an overlay on the session you pressed it in. You put a note on any line you do not follow or disagree with. On quit the notes are put at that session's prompt and sent, so annotating and quitting is the whole interaction.

A long answer is the case this is for. Quoting the parts you want to argue with is slow, and "the third paragraph" is worse.

One exchange usually produces several replies, because Claude writes, runs a tool, then writes again. They all go into one markdown file, each under its own heading, and revdiff builds its sidebar from those headings. The prompt that started the exchange opens the file, and the replies follow in the order they happened:

```
10:52 · what you asked
10:58 · reply 1
11:04 · reply 2, the one you just read
```

The notes that come back are not only your comments. Each one quotes the lines it points at and names the reply it landed on, so the answer you get is about the sentences you marked:

```
## Note 1 — 11:04 · the reply you just read, line 12
> the launcher already opens revdiff in an agterm overlay
which launcher? I never set this up
```

## Requirements

- agterm 0.13.0 or later. That is where `{AGT_PANE}` began reporting the pane a custom command fired from, which is how the notes get routed back into the right half of a split. Everything else it uses is older: `session overlay open --block` and `notify` shipped in 0.3.1, `session type --pane` in 0.7.0.
- [revdiff](https://github.com/umputun/revdiff), on your `PATH`
- Claude Code. The recipe reads Claude Code's own session transcripts, so no other agent will work without being ported.
- `python3`, which macOS ships

`AGTERMCTL`, `REVDIFF` and `PYTHON` at the top of the script take an absolute path if any of them is somewhere unusual. `REVDIFF` is worth knowing about if you keep more than one build: the script resolves whatever `revdiff` the widened `PATH` finds first, which is not necessarily the one your interactive shell picks.

## Setup

Copy the four files somewhere on your machine, say `~/.local/bin/agterm-annotate/`, and make them executable:

```sh
chmod +x annotate-replies.sh annotate-extract.py annotate-render.py save-transcript-path.py
```

The three helpers must sit **beside** `annotate-replies.sh`; it looks for them in its own directory.

Register the Stop hook by adding an entry to the `Stop` array in `~/.claude/settings.json`, alongside anything already there:

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

Then add the keybinding to `~/.config/agterm/keymap.conf` and apply it with File ▸ Reload Keymap or `agtermctl keymap reload`:

```
command "Annotate replies"  cmd+ctrl+e  ~/.local/bin/agterm-annotate/annotate-replies.sh "{AGT_SESSION_ID}" "{AGT_PANE}"
```

Pick a chord that is free in your own keymap. A custom command cannot shadow a built-in, so one that collides is quietly demoted to palette-only and the chord appears to do nothing. On 0.19.0 and later `agtermctl keymap list` shows what every chord resolved to; before that, read `keymap.conf` and the commented list of built-in defaults at the top of it. Either way the command is always reachable by name from the action palette, which is the quickest way to tell a bad chord from a broken script.

Two settings, read from the environment. Put them in front of the script in the keymap line, or change the defaults at the top of the script — a keymap change needs a reload before it takes effect, an edit to the script does not:

- `AGTERM_ANNOTATE_SUBMIT=0` leaves the notes at the prompt for you to read over and send yourself. The default sends them, so quitting revdiff is the whole interaction.
- `AGTERM_ANNOTATE_PROMPTS=2` reaches back a further exchange, and so on. The default of 1 is everything since your last prompt.
`AGTERM_ANNOTATE_REVDIFF_FLAGS` replaces the flags handed to revdiff, which default to `--wrap --wrap-indent=2`. Wrapping is on because a reply is prose rather than code, and the indent stops a wrapped bullet from reading as a new one. Adding `--tree-width=1` shrinks the side panel to its narrowest.

Two further flags are added automatically, but only when the binary advertises them, so a revdiff without them is never handed an unknown flag. `--no-tree` starts with the side panel hidden, which a single reply has no use for; it is in revdiff `master` but not in v1.12.0, so a released build simply will not get it yet. `--preview` starts in rendered markdown rather than source: annotations are placed in the source view, so the flow is read the rendered reply, toggle to source, mark it up. Setting `AGTERM_ANNOTATE_REVDIFF_FLAGS` yourself turns the probe off entirely and uses exactly what you give it.

Every setting can also live in `~/.config/agterm-annotate/config`, a plain shell file sourced on each run. That is the better place for anything machine-specific: it takes effect on the next press, while a keymap line needs a reload first, and it keeps the script itself identical to the published one. `AGTERM_ANNOTATE_REVDIFF_NAMES` belongs there — it lists the binary names to try in order, so a local build under its own name is a config line rather than an edit.

## Usage

Ask Claude something. When the answer lands, press the chord.

revdiff opens over the session. The sidebar lists what you asked and then each reply in the order it came, so the one you were reading is last and the earlier ones are a keypress away. Mark the lines you want to argue with, then quit.

The notes are sent as soon as you quit, so annotating and quitting is the whole interaction. Set `AGTERM_ANNOTATE_SUBMIT=0` if you would rather they waited at the prompt for you to read over and add to. Quitting with no annotations sends nothing either way.

`AGTERM_ANNOTATE_INLINE=0` sends a one-line pointer to the notes file instead of the notes themselves. That is also what happens automatically in a split or scratch pane, for the reason below.

A pane only becomes annotatable once a turn has finished in it, because that is when the hook runs. Pressing the chord in a plain shell says so and does nothing else.

## How it works

The hook records `transcript_path`, which is the one thing that cannot be worked out afterwards. A project directory holds one transcript per session, so picking the newest by modification time opens whichever session was busiest, not the one you are sitting in. It keys the record by session **and** pane, because a split session shares one session id while running an agent in each half.

The reply itself is read from the transcript when the chord fires, not copied by the hook. A hook only runs when a turn ends, so anything it copies is stale the moment it misses one, and it does miss them — across an app restart, or in a pane you have not returned to. The stored message survives only as the fallback for a transcript rotated by a resume.

A transcript keeps one content block per line, and the blocks of one reply share `message.id`. An exchange boundary is a user record whose content is a plain string, or an array carrying no `tool_result` block; that is what separates something you typed from a tool result Claude Code feeds back as a user record. Sidechain records are subagents and are skipped. At most 12 replies are written, so one very long exchange cannot fill the sidebar, and the opening prompt is truncated at 4000 characters so a pasted wall of text cannot bury the replies it opened.

Sections run oldest first, the order the exchange happened in, with the prompt at the top so the replies have something to be answers to. Every heading inside a section body is pushed down one level, because a reply — and especially a pasted prompt — can carry its own `#` heading, which would otherwise sit beside the section titles in the contents and read as another turn. Headings inside fenced code are left alone; a `#` there is a comment, not a heading.

Two things cost an hour each:

An overlay's command runs through `sh -c` with the app's **GUI** `PATH`, which has neither `/opt/homebrew/bin` nor `~/.local/bin`. A bare `revdiff` there exits 127 and the overlay flashes shut, so the script resolves it to an absolute path first. The same trap applies to the script itself, which agterm runs detached in a small-`PATH` `/bin/sh` with stdio on `/dev/null`. That is why it widens `PATH` at the top and logs to `/tmp/agterm-annotate.log` instead of printing.

`session overlay open --block` exits with the program's own status, so a non-zero code can equally mean agterm refused before revdiff ever ran. Reading only the code turns "overlay already open" into a meaningless "exited with 1", so the script reads the reply text as well.

Putting the notes at the prompt needs `session paste`, because `session type` sends a real Return for every newline and multi-line text would submit itself line by line. `session paste` reads the system clipboard, so the script saves what is on it, pastes, and puts it back. It also has no `--pane` and always targets the session's main pane, so a note taken in a split or scratch pane falls back to typing a one-line pointer at the notes file instead.

## Limits

- **It types into your session and sends.** The notes are injected at the prompt of the session you pressed the chord in and submitted for you, so the agent acts on them without you seeing them first. `AGTERM_ANNOTATE_SUBMIT=0` stops at the prompt instead.
- **It uses the clipboard.** Pasting is the only way to land multi-line text at a prompt without submitting it. What was on the clipboard is saved and put back, but only if it was plain text — an image or rich content is lost. `AGTERM_ANNOTATE_INLINE=0` avoids the clipboard entirely.
- **A promoted pane can open the wrong replies.** The record is keyed on the pane the agent's shell was started in, but the chord reports the pane it fires from now, and those diverge after a promote: closing the left half of a split promotes the right one, so a chord in the survivor can open the replies of the pane that closed. There is no `{AGT_PANE_ID}` keymap token to reconcile the two from a script.
- **The hook writes to `~/.cache/agterm-annotate/` on every finished turn**, in every agterm pane, whether or not you ever press the chord. Each file holds that pane's last reply in full, and `last-notes.md` holds the last set of notes. Delete the directory to clear them; nothing prunes it.
- **It reads your Claude Code transcripts**, and copies the replies into a file under `TMPDIR`. Anything in an answer is in that file, in the clear.
- Nothing under `${TMPDIR}/agterm-annotate/` is ever deleted. Old replies and notes stay until the system clears the directory.
- Claude Code only. No other agent hands a hook the transcript path.
- One reply set per pane at a time. Pressing the chord again while revdiff is open is dropped rather than stacking a second overlay.
- A session that already has an overlay open cannot take another, so the chord says so and stops. Close the overlay first.
- The `--only` view is read-only. Annotating a reply changes nothing but the note you send.
