# Claude clear

One chord clears the Claude Code run in the pane you pressed it in, and does nothing at all when Claude is not running there.

## What it does

`/clear` is the slash command you reach for most and the one that is most annoying to type: the context is long, the reply is slow, and you have to click into the right pane first. This binds it to a chord.

The part worth copying is the guard. A slash command is meaningful to Claude Code and to nothing else, so the script reads what the pane is actually running before it sends anything, and sends only when that is Claude. Anywhere else it exits without a keystroke rather than pushing text at a program that never asked for it.

That check is the reusable half of the recipe. Swap the line for `/compact`, `/model opus`, or anything else you would rather press than type, and the same guard keeps it aimed at Claude Code alone.

## Requirements

- agterm 0.13.0 or later, which shipped `$AGT_PANE` reporting `scratch` for a chord fired from a scratch terminal — the value that keeps such a chord off the main pane's Claude run.
- Python 3.9 or later, which macOS ships as `/usr/bin/python3`
- Claude Code

## Setup

Copy the script somewhere and make it executable. Anywhere works as long as the keymap line points at it:

```sh
mkdir -p ~/bin
cp claude-clear.py ~/bin/
chmod +x ~/bin/claude-clear.py
```

Add an entry to `~/.config/agterm/keymap.conf` and apply it with File ▸ Reload Keymap or `agtermctl keymap reload`:

```
command "Claude Clear" ctrl+a>x ~/bin/claude-clear.py
```

Any free chord works. Bind a second line for another slash command by passing it as an argument. A command of several words needs no quoting; the arguments are joined:

```
command "Claude Compact" ctrl+a>shift+x ~/bin/claude-clear.py /compact
command "Claude Opus"    ctrl+a>shift+o ~/bin/claude-clear.py /model opus
```

Leave the chord out entirely and the entry is palette-only.

Fired from a chord or the palette, the script runs under the app's `PATH` rather than your shell's. That is the launchd default: `/usr/local/bin` plus the system directories, with no `/opt/homebrew/bin` and nothing else your profile adds. Both binaries this recipe needs resolve there — `python3` from `/usr/bin`, and `agtermctl` from `/usr/local/bin`, where **Help ▸ Install Command Line Tool…** symlinks it. Set `AGTERMCTL` to the binary's full path if yours sits somewhere unusual.

Two other environment variables, both optional:

- `CLAUDE_FG_MATCH` — the regular expression that decides whether a pane's foreground process is Claude Code. The default, `(^|/)claude$`, matches the binary itself. If you launch Claude through a wrapper script, add it: `CLAUDE_FG_MATCH='(^|/)(claude|mywrapper)$'`. Set it in the keymap line as a prefix assignment, since the script is run by `/bin/sh -c`.
- `AGTERMCTL` — the CLI's full path, as above.

## Usage

Press the chord in a pane running Claude Code. The line is typed into it and submitted, exactly as if you had typed it yourself.

Press it in a pane that is not running Claude Code and nothing happens. There is no message and no error; the chord is simply inert there.

```sh
AGT_SESSION_ID=<id> AGT_PANE=left ~/bin/claude-clear.py
```

Run it from a shell when a chord does nothing you expected. It prints nothing either way, but running it with the two variables set by hand tells you whether the detection or the binding is at fault. It exits 1 when the write itself failed, which is also what makes agterm show its own command-failed notice; a pane that is simply not running Claude exits 0.

## How it works

One read, then one write.

`agtermctl tree --json` reports, for every session, the live argv of what each pane is running: `foreground` for the main pane, `splitForeground` for the split. A pane sitting at its shell prompt reports neither. So "is Claude running here" needs no process inspection and no `ps`: find this session in the tree, read the field for this pane, and test its argv.

Which field to read comes from `$AGT_PANE`, which the custom-command runner sets to `left`, `right` or `scratch` for the surface the chord fired from. Ignoring it is the mistake this recipe exists to avoid: both panes of a split share one session id, so a chord pressed on the right that reads `foreground` decides on the left pane's process and then clears the left pane's run.

The argv test matches any element rather than only the first, because a wrapper that execs Claude shows up as `/bin/sh /usr/local/bin/mywrapper` with the real launcher further along the line. The pattern is anchored to a whole path component, so `claude-helper` does not count as `claude`.

The write is `agtermctl session type '/clear\n' --target <session> --pane <pane>`. The trailing newline is what submits it; without one the command would sit unsent in Claude's prompt. `--pane` matters for the same reason the read did: omitted, it defaults to the main pane rather than to the focused one, so a chord pressed in a split's right half would clear the left half's run.

Every call carries `--socket "$AGT_SOCKET"`, the socket of the instance the chord came from, so a second agterm running from a different state directory is never the one that gets typed into.

## Limits

**`/clear` throws away the conversation.** That is the point of the command, but it is worth saying plainly: the Claude run in that pane loses its context, and there is no undo. A chord makes that one keypress away, and the guard only ensures it lands on an agent — it does not ask whether you meant it.

The scratch pane is invisible to this. `tree --json` reports the main and split panes only, so a chord pressed in a scratch terminal running Claude finds no argv and does nothing.

Detection is a name match on the argv macOS will show. A `claude` running under `sudo`, or under another setuid program, has its argv withheld from a non-root caller and reads as an idle pane. So does a `claude` started under `tmux` or any other multiplexer, whose panes agterm cannot see into.

It misreads in the other direction too. The match tests every argv element, not only the launcher, so a long-running program holding a path that ends in `claude` — an editor open on a wrapper script, say — reads as a Claude run and receives the line. `~/.claude/settings.json` does not match, the character before `claude` being a dot, but `~/bin/claude` does.

The read and the write are two calls. If Claude exits in the gap between them — a rare few milliseconds — the line lands in the shell that took its place, which will report `/clear: command not found`.

`session type` writes into a line buffer you share with it. If you were part-way through typing a prompt when you pressed the chord, `/clear` concatenates onto what is already there and the merged line is what gets submitted.

The chord fires against the session that is active in the frontmost window. It cannot reach a pane in a background window; nothing happens there either.
