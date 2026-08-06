# Claude conversation picker

One chord lists the past Claude Code conversations of this session's directory, each under a name of what it was about, and resumes the one you pick in the pane you pressed it in.

## What it does

`claude --resume` gives you a list of conversations labelled by their opening prompt. After a week in one repository that is a column of "fix the test", "look at this", "continue" — accurate and useless. This recipe lists the same conversations named by what they turned out to be about, in the native picker, and sends the resume into the pane the chord fired from.

Naming costs a model call, so it happens once per conversation and is cached against the transcript's mtime. A press with a warm cache pays for the one conversation you have been working in, usually nothing else. The first press in a directory pays for all of them, which takes seconds, and that wait is why the recipe puts a HUD over the session while it works: the panel names each conversation as the model finishes it, and the session stays focused and typable underneath.

The HUD is the part worth copying on its own. Any script that makes the user wait before it can show anything can post one the same way, and take it down when it has something.

## Requirements

- agterm 0.21.0 or later, which shipped `session hud`, the passive message panel this recipe puts up while it works. Without it the recipe still runs; the wait is just silent.
- Python 3.9 or later, which macOS ships as `/usr/bin/python3`
- Claude Code, with its conversations in `~/.claude/projects/` (or wherever `CLAUDE_CONFIG_DIR` points), and a model to name them with

## Setup

Copy the script somewhere and make it executable. Anywhere works as long as the keymap line points at it:

```sh
mkdir -p ~/bin
cp claude-pick-conversation.py ~/bin/
chmod +x ~/bin/claude-pick-conversation.py
```

Add an entry to `~/.config/agterm/keymap.conf` and apply it with File ▸ Reload Keymap or `agtermctl keymap reload`:

```
command "Claude Resume" ctrl+a>r ~/bin/claude-pick-conversation.py
```

Any free chord works, and leaving the chord out makes the entry palette-only.

If you start Claude Code through an alias or a wrapper script rather than by running `claude` directly, name it in `CLAUDE_FG_MATCH` as well, or the recipe will not recognize a pane that is already running it:

```
command "Claude Resume" ctrl+a>r CLAUDE_FG_MATCH='(^|/)(claude|mywrapper)$' ~/bin/claude-pick-conversation.py
```

`mywrapper` stands for whatever you call yours; add as many as you have, and keep `claude` in the list so a direct run still matches. Getting this wrong is not fatal but it is visible: a pane running Claude Code through an unlisted wrapper reads as a bare shell, so the pick types `claude --resume <id>` and starts a second process beside the one already there, instead of sending `/resume <id>` into the one in front of you.

Fired from a chord or the palette, the script runs under the app's `PATH` rather than your shell's. That is the launchd default: `/usr/local/bin` plus the system directories, with no `/opt/homebrew/bin` and nothing your profile adds. `python3` resolves from `/usr/bin` and `agtermctl` from `/usr/local/bin`, where **Help ▸ Install Command Line Tool…** symlinks it. `claude` usually does not, so set `CLAUDE_BIN` to its full path if the naming pass never produces names.

Everything else is optional, set as prefix assignments in the keymap line since the script is run by `/bin/sh -c`:

- `AGTERMCTL` — the CLI's full path, when yours sits somewhere unusual.
- `CLAUDE_BIN` — the Claude Code binary's full path.
- `CLAUDE_FG_MATCH` — the pattern deciding whether a pane runs Claude Code, as described above. The default, `(^|/)claude$`, matches a direct run only. It is anchored to a whole path component, so a wrapper of your own is not matched by accident and neither is a neighbour like `claude-helper`.
- `CLAUDE_RESUME_CMD` — what to type at a shell prompt, when `claude` is not the command you start it with.
- `CLAUDE_RESUME_NAME_MAX` — how many of the newest conversations get a name (default 20). The rest are listed under their opening prompt.
- `CLAUDE_RESUME_MODEL` — the naming model. The default is a small fast one, named by its full id: a short alias is not recognized and silently falls back to your default model, which is slower and costs more for a six-word label.
- `CLAUDE_RESUME_PANE_POINTER` — a file naming the conversation open in a pane, as a template with `{sid}` and `{pane}`. Claude Code publishes no such thing, so this is off unless your own statusline hook writes one; when set, the conversation you are already in is dropped from the list instead of offered back to you.

## Usage

Press the chord. If the cache is warm the picker opens immediately; otherwise a panel appears at the top of the session, counting the conversations it reads and then naming them one by one, and the picker opens when it is done. Pick a row and the resume is typed into the pane you pressed in.

What gets typed depends on what is running there. In a pane already running Claude Code it is `/resume <id>`, its own slash command. At a shell prompt it is `claude --resume <id>`. Esc cancels the picker and nothing is typed.

```sh
CLAUDE_RESUME_DRY=1 AGT_SESSION_ID=<id> ~/bin/claude-pick-conversation.py
```

Run it from a shell when a chord does nothing you expected. Dry mode prints the rows it would have offered, plus the directory it read, the pane it resolved and whether it thinks Claude is running there, and never opens the picker or types anything. It still posts the panel and still names, so it is also how you watch the naming pass without committing to a resume.

## How it works

The conversations of a directory live in `~/.claude/projects/<slugged path>/`, one `.jsonl` per conversation, where the slug is the absolute path with every non-alphanumeric character replaced by a dash. The id and the opening prompt come from the first `last-prompt` entry near the top of each file, so building the list never reads a whole transcript.

Naming does read them, but only at the ends. A transcript can be tens of megabytes and a single assistant entry tens of kilobytes; the opening says what the conversation was for and the tail says where it got to, and the middle is what makes the file large. So the digest is the first prompts, a `--- latest ---` marker, and the last entries, and the model is told the work after the marker is what the conversation is currently about. Long sessions drift, and naming one from its opening prompt is how you get a list of names for work that was abandoned three hours in.

The cache key is the transcript's mtime, with slack. An exact key would re-name the conversation you are sitting in on every press, because its file grows while the script runs, so a name survives an hour of new activity or a bounded amount of growth, whichever comes first. The size rule is what catches a session that changed subject in one long sitting, which the clock alone misses.

The panel is `agtermctl session hud`: `open` the first time, `update` after that, `close` at the end. It is passive, so unlike an overlay it leaves the session focused and typable, which matters because the wait is seconds long and you may want to keep typing through it. Two details are worth copying. The width is pinned with `--size-percent`, since the panel otherwise sizes itself to its longest line and a step naming a longer conversation would resize it mid-run. And every HUD failure is ignored: an older agterm without the command, a session that went away, anything at all — a progress panel must never be the reason the thing it was reporting on fails.

Closing it before the picker opens is not tidiness. A session has one overlay slot, the picker is a cover of its own, and a panel left up is how a press ends with a panel and no picker.

The naming call is streamed rather than awaited. The schema output arrives as ordinary text deltas, so each name can be shown the moment it is complete, and the run's own result event still carries the finished object. The reader runs on its own thread so the panel keeps ticking through the model's first seconds, when nothing has been emitted yet. That thread is also the pipe's only drain, which is why it keeps reading past anything malformed: stopping early fills the pipe, blocks the model process on its next write, and leaves it running with the panel pinned — on a process spawned from a keybinding, with no terminal to interrupt.

Which pane to read and type into comes from `$AGT_PANE`. Both halves of a split share one session id, so a chord pressed on the right that ignores it reads the left pane's process and then types into the left pane's shell.

## Limits

**The pick types into your pane and submits.** In a pane running Claude Code that is a `/resume`, which replaces what that run was doing with the conversation you picked; at a shell prompt it is a command that starts one. Neither is undoable from here, and the picker's rows are named by a model, so read the row before you press Return.

`/resume` is Claude Code's own picker, and whether a single id auto-selects is undocumented, so the typed Return may land on a one-row picker that wants a second one.

Names are a model's summary of two ends of a transcript. They are wrong sometimes, and a conversation with nothing substantive in it keeps its opening prompt instead. The age in the subtitle is the transcript's mtime and is always accurate; when a name looks doubtful, that is the field to trust.

Resuming a conversation that another pane has open is refused by Claude Code itself, so the picker offers it and the resume then fails there rather than here.
