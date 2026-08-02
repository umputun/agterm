# Claude recap

One keypress answers "what was this session doing?" from its Claude Code transcript, instead of scrolling the scrollback.

## What it does

You come back to a session, either one you left hours ago or one an agent has been driving while you were elsewhere, and you need to know where it got to. ⌃A then C reads that session's Claude Code transcript and lists the last few pieces of work in a floating overlay, newest first.

Each item is a relative age, an eight-word title, a one-sentence detail, and a status of done, in progress, blocked or abandoned. The header carries the directory and how long ago the session was last active, so a recap from yesterday does not read like a running one. Any key closes it.

## Requirements

- agterm 0.10.0 or later, which shipped the `{AGT_PANE}` keymap token and `session overlay open --background-color`. The overlay itself works from 0.8.0.
- `zsh`, for the script
- `jq`, for reading the transcript
- Claude Code CLI, for the summary. Tested with 2.1.220. The flags it depends on (`--safe-mode`, `--json-schema`, `--tools`, `--no-session-persistence`) are less stable than agterm's own API, so a much newer or older CLI may need the invocation adjusted.

## Setup

Put the script somewhere on disk, make it executable, and bind it. The example uses `~/.config/agterm/scripts`; anywhere works as long as the keymap line points at it.

```bash
mkdir -p ~/.config/agterm/scripts
cp claude-recap.zsh ~/.config/agterm/scripts/
chmod +x ~/.config/agterm/scripts/claude-recap.zsh
```

Add the line to `~/.config/agterm/keymap.conf` and apply it with File ▸ Reload Keymap or `agtermctl keymap reload`:

```
# ctrl+a>c: recap the claude code session running in this agterm session.
# {AGT_SESSION_ID} is passed twice: --target opens the overlay on THIS session, and the script
# argument lets it resolve the session's cwd, because a fresh overlay pty cannot read $AGT_*.
# zsh -c so the login shell puts jq and claude on PATH.
command "Claude Recap" ctrl+a>c agtermctl session overlay open 'zsh -c "$HOME/.config/agterm/scripts/claude-recap.zsh {AGT_SESSION_ID} {AGT_PANE}"' --size-percent 60 --background-color "#2e3a2e" --target {AGT_SESSION_ID}
```

### The pane map

Without this part the recap finds the transcript by working directory, which picks the wrong run for a split working in one repository and for a session whose Claude Code moved into a git worktree. Claude Code's status line is what fixes it: the command receives the live `transcript_path` on stdin, and it runs as a child of the pane's shell, so it knows which pane it is in.

If you already have a status line, paste these lines into it, after it has read stdin into `$input`:

```bash
# record which transcript is live in this agterm pane, for claude-recap
if [ -n "$AGTERM_SESSION_ID" ]; then
    transcript_path=$(echo "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
    if [ -n "$transcript_path" ]; then
        mkdir -p /tmp/claude/panes 2>/dev/null
        printf '%s\n' "$transcript_path" > "/tmp/claude/panes/${AGTERM_SESSION_ID}.${AGTERM_PANE:-left}"
    fi
fi
```

If you have none, `pane-map-statusline.sh` in this directory is a minimal status line that does only this and prints the model name. Install it and point Claude Code at it in `~/.claude/settings.json`:

```bash
cp pane-map-statusline.sh ~/.claude/scripts/
chmod +x ~/.claude/scripts/pane-map-statusline.sh
```

```json
{ "statusLine": { "type": "command", "command": "~/.claude/scripts/pane-map-statusline.sh" } }
```

Claude Code takes one `statusLine` command, so this is an either/or: extend the one you have, or install this one.

### Environment variables

All optional:

- `CLAUDE_BIN`, the Claude Code binary, default `claude`
- `RECAP_MODEL`, the summarizing model, default `claude-haiku-4-5-20251001`
- `CLAUDE_DIRS`, space-separated Claude Code config dirs to search, default `$HOME/.claude`. Set it if you run more than one config dir.
- `PANE_MAP_DIR`, where the status line records each pane's transcript path, default `/tmp/claude/panes`. Change it in both places or neither.

## Usage

Press ⌃A then C in a session that has, or recently had, a Claude Code run in it. The overlay draws a spinner while it resolves the session, reads the transcript and summarizes, then renders the list. Any key closes it, and nothing is left behind.

It works on a session an agent is driving right now, and on one whose Claude Code has already exited, as long as the transcript is still on disk.

## How it works

The overlay is a real pty and does not inherit `$AGT_*`, which is why the session id and pane are passed as arguments. With the id, the script asks `agtermctl tree --json` for that session's working directory.

Claude Code files transcripts under a slug of the working directory, so the obvious lookup is the newest `.jsonl` under the slug for this cwd. It picks the wrong run twice: two panes of one split in the same repository share a cwd and so share a slug, and a run that moves into a git worktree files its transcript under the worktree while the pane's shell stays put. The per-pane record is the reliable source, so the script reads `$PANE_MAP_DIR/<session-id>.<pane>` first and falls back to the slug lookup only for a pane that never rendered a status line.

The summary is a second Claude Code invocation, not an API call, so it runs on the same subscription. Two flags make it usable: `MAX_THINKING_TOKENS=0`, without which the model spends thousands of thinking tokens on six one-line items and the wait grows from seconds to a minute and a half, and `--safe-mode`, which drops CLAUDE.md, rules, skills, plugins, hooks and MCP so the request carries a few hundred tokens of harness context instead of tens of thousands. `--json-schema` pins the output shape; `--tools ""` and `--no-session-persistence` keep the run from touching anything.

The transcript is condensed with `jq` first: user prompts in full, assistant replies cut to 400 characters, tool traffic dropped, each prompt tagged with a relative age so the model dates an item without arithmetic. Only the last 120 KB is kept.

Rendering is by hand rather than through a markdown pager, which does not keep the two-line item shape. The list is sorted by parsing the age strings back into seconds, because the model ignores "newest first" often enough that the ordering has to be mechanical.

## Limits

Read-only. It opens an overlay, reads a transcript and closes; no session, pane or file is changed.

Each press sends up to 120 KB of the transcript to the model. That is your prompts and the assistant's replies, which on a work machine may include source, paths and anything else the session discussed. Nothing is written anywhere, but the data does leave the machine.

Skip the pane map and the recap can name the wrong run: both panes of a split working in one repository resolve to the same transcript, and a Claude Code run that moved into a git worktree is filed under the worktree rather than the pane's directory.

The pane map itself has one hole. A `claude` started under tmux, or under any daemon that outlives the shell, inherits the `AGTERM_*` of whichever session started that server, so its transcript is recorded against that session instead of its own. The recap then falls back to the working-directory lookup.

The summary is a model's reading of a condensed transcript. It is a signpost for picking work back up, not a record: statuses in particular are inferred from what the transcript shows, and a piece of work concluded outside the session reads as unfinished.
