# End-of-task offer

When the agent says its task is done, a dialog over the session offers Clear, Close session, or Continue.

## What it does

The [session-context-nudge](../session-context-nudge/) recipe has the agent keep the title-bar line saying what the session is working on, and clear that line once the work is finished. That clear is the agent declaring the task over, which is the moment you usually start a fresh conversation or close the tab. This recipe turns it into a question.

When the agent's turn ends after it cleared the line, a dialog opens over the session:

- **Clear**, the default, types `/clear` into every pane of the session that runs Claude Code or codex, so the next task starts with empty conversations.
- **Close session** closes the session, with the same undo grace as ⌘W.
- **Continue** closes the dialog and changes nothing. Esc does the same.

It works with Claude Code and codex. In a split the dialog comes from the main pane's agent, the one the nudge asks to clear the line, and Clear acts on the whole session.

## Requirements

- agterm 0.39.0 or later, which shipped `session close --undoable`
- [session-context-nudge](../session-context-nudge/) installed, since it is what asks the agent to clear the line
- Claude Code, codex, or both
- `jq`
- bash, which macOS ships as `/bin/bash`

## Setup

Copy the script somewhere and make it executable:

```sh
mkdir -p ~/bin
cp end-of-task-offer.sh ~/bin/
chmod +x ~/bin/end-of-task-offer.sh
```

**Claude Code.** Add two hooks to `~/.claude/settings.json`, alongside anything already in those arrays:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{ "type": "command", "command": "~/bin/end-of-task-offer.sh arm" }]
      }
    ],
    "Stop": [
      {
        "hooks": [{ "type": "command", "command": "~/bin/end-of-task-offer.sh offer" }]
      }
    ]
  }
}
```

**codex.** codex needs the nudge as well as the two hooks, because session-context-nudge registers it for Claude Code only. The nudge script works unchanged in codex, which adds a prompt hook's output to the model's context the same way. Add these to `~/.codex/config.toml`, with full paths:

```toml
[[hooks.UserPromptSubmit]]
[[hooks.UserPromptSubmit.hooks]]
type = "command"
command = "/Users/you/bin/context-nudge.sh"

[[hooks.PostToolUse]]
matcher = "^Bash$"
[[hooks.PostToolUse.hooks]]
type = "command"
command = "/Users/you/bin/end-of-task-offer.sh arm"

[[hooks.Stop]]
[[hooks.Stop.hooks]]
type = "command"
command = "/Users/you/bin/end-of-task-offer.sh offer"
```

codex runs a new or changed hook only after you approve it: start codex and review them with `/hooks`.

Two settings, both optional:

- `AGTERMCTL`: the CLI's full path, if yours sits somewhere unusual.
- `END_OF_TASK_AGENTS`: the regular expression that decides whether a pane runs an agent Clear may reset, matched against each element of the pane's running command. The default, `(^|/)(claude|codex)$`, matches the binaries themselves. If you start an agent through a wrapper script, add its name, and set it on the `offer` hook, since that is where the dialog starts:

  ```json
  "command": "END_OF_TASK_AGENTS='(^|/)(claude|codex|mywrapper)$' ~/bin/end-of-task-offer.sh offer"
  ```

## Usage

Nothing to press until the dialog appears. Work as usual; when the agent finishes a task and clears the title-bar line, the dialog opens as soon as its reply is done. Return picks Clear.

## How it works

Two hook calls carry one decision across the turn. On every shell command the agent runs, `arm` checks whether it was `agtermctl session context --clear` for this session, and if so leaves a marker file named after the pane. When the turn ends, `offer` finds the marker, deletes it, and starts the dialog in the background so the agent is not held waiting for your answer.

The marker is named after the pane rather than the session. Two agents in one split end their turns separately, and a marker shared by the session would let the other pane's agent open the dialog in the middle of this one's work.

Clear goes through the session's panes one at a time and checks two things before typing into each. First, that the pane runs an agent: `agtermctl tree --json` reports each pane's running command as `foreground` and `splitForeground`, and one of its elements must match `END_OF_TASK_AGENTS`. A pane running a shell or anything else is skipped, because a shell prompt can rest the caret at column 2 too and would run `/clear` as a command. Second, that the caret sits at column 2, where an empty Claude Code or codex composer rests it, just past the `›` prompt. Text you have started typing moves it further right, and then nothing is typed into that pane: a panel saying the prompt has text in it shows over it for four seconds instead.

The `/clear` and its Enter go as two writes 150 ms apart. codex reads a fast burst of characters as a paste, and an Enter arriving inside it becomes a newline instead of a submit; Claude Code accepts either form.

## Limits

**Close session closes the whole session, both panes and whatever runs in them, and its companion sessions with it.** It takes ⌘W's undo grace when Settings has undo after closing on, and closes at once when it is off.

**Clear in a split ends both agents' conversations.** The other pane's agent may be in the middle of its own work, and its conversation is reset with the main one's.

**Clear on codex also wipes the pane's scrollback.** codex's `/clear` clears the screen along with the conversation, so output you had not read yet is gone.

The caret check sees position only. A draft with the caret moved back to its start reads as empty, and Clear then types `/clear` in front of it and submits the line.

The dialog does not follow what happens after it opens. An empty composer looks the same whether the agent is idle or working, so a Clear clicked after you started a new prompt still types `/clear` into that conversation.

The dialog opens only when the agent clears the title-bar line itself. A line you clear by hand, or an agent that never clears it, produces no dialog.
