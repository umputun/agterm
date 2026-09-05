# Session context nudge

Claude Code keeps the session's title-bar line saying what it is working on, without being asked and without being told when the task changed.

## What it does

`agtermctl session context` puts a line in the title bar saying what a session is for — a ticket number, a bug, the thing you are actually doing. It is genuinely useful with a dozen sessions open and genuinely never set, because setting it is one more thing to remember at exactly the moment you are thinking about something else.

Handing the job to the agent runs into a harder problem: a hook cannot tell when one task ends and the next begins. Nothing in a prompt marks a boundary, and guessing produces a line that is wrong more often than it is right.

So this hook does not try. On every prompt it prints the line that is currently set and leaves the judgment to the model, which knows what it is working on and can see whether the line still describes it. A turn that continues the same task produces no tool call at all; a turn that has moved on produces one `session context` write. When the work the line names is finished, the same nudge tells the model to clear it.

## Requirements

- agterm 0.26.0 or later, which shipped `session context`
- Claude Code
- `jq`
- bash, which macOS ships as `/bin/bash`

## Setup

Copy the script somewhere and make it executable:

```sh
mkdir -p ~/bin
cp context-nudge.sh ~/bin/
chmod +x ~/bin/context-nudge.sh
```

Register it as a `UserPromptSubmit` hook by adding an entry to `~/.claude/settings.json`, alongside anything already in that array:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/bin/context-nudge.sh"
          }
        ]
      }
    ]
  }
}
```

The hook writes nothing itself. What it prints becomes context on the model's next turn, and the model runs `agtermctl session context` if it decides the line needs replacing. That means the command has to be permitted: if you run Claude Code with an allowlist, add `Bash(agtermctl session context:*)` to it. A denial is worse than no nudge, because the model abandons the write for the rest of the turn.

Two settings, both optional:

- `AGTERMCTL` — the CLI's full path, if yours sits somewhere unusual.
- `CONTEXT_NUDGE_PANE` — the pane this agent is really in, `left`, `right`, or `scratch`. See *Limits*.

## Usage

Nothing to press. Start a task and the model sets the line once it knows what the task is; change subject and it replaces the line; finish and it clears it.

Read the line back at any time, from the title bar or from the tree:

```sh
agtermctl tree --json | jq -r '.result.tree.workspaces[].sessions[] | "\(.name)\t\(.context // "-")"'
```

## How it works

The hook reads the session's current `context` field out of `agtermctl tree --json` and prints one of two short blocks: "not set, here is how to set it" or "here is what it says, replace it if it no longer fits". Both blocks carry the exact command to run, with the session id already in it.

That literal id matters. A Claude Code permission rule cannot match a command containing `$AGTERM_SESSION_ID`, because the matcher refuses shell expansion, so a nudge that told the model to use the variable would be denied by an allowlist that was meant to permit it.

Four smaller things the script has to get right:

- `tree` reports the frontmost window only, so a session in a background window reads as absent and the hook would go quiet — which is exactly the case the nudge exists for. It passes `--window "$AGTERM_WINDOW_ID"` when the session has one.
- Absent and unset are different answers. A session that is not in the tree at all must produce silence, not "your context is not set", so the jq returns a control character for absent, which agterm can never store as a real value.
- The context belongs to the session, not to a pane, so in a split only the main pane's agent writes it. Otherwise two agents in one session overwrite each other's line all day.
- A headless `claude -p` inherits `AGTERM_*` from whoever spawned it and would write its spawner's line. Claude Code sets `CLAUDE_CODE_ENTRYPOINT` to `sdk-cli` for a headless run and `cli` for the agent in the pane, and the hook exits on anything but `cli`.

The `agtermctl` it calls is resolved in three steps: `$AGTERMCTL` if you set it, then `$GHOSTTY_BIN_DIR/agtermctl` if that names an executable, then whatever is on `PATH`. The middle step is the one that earns its place: the running app points `GHOSTTY_BIN_DIR` at its own bundle, so it finds the CLI belonging to the app actually serving this session rather than a symlink left by a different install. Other terminals set that variable too, which is why the file has to exist and be executable before it is used.

Everything fails open. A missing `agtermctl`, an unreadable tree, a session that has gone, a `jq` that is not installed: each of them exits silently. A quiet turn costs one stale line, and a stale line is cheaper than a wrong one.

## Limits

It is a nudge, not a guarantee. The model decides whether the line still fits, so a line can stay stale for a turn or several, and a model that is deep in something will sometimes leave it alone when it should not. Nothing here detects that.

It costs a hook run on every prompt you submit — one `agtermctl tree` call and one `jq`. On a machine where `timeout` is available the tree call is bounded at two seconds; macOS ships no `timeout`, so without GNU coreutils on `PATH` a hung CLI would stall the prompt until Claude Code's own hook timeout fires.

The pane check reads `$AGTERM_PANE`, the shell's spawn role rather than its live position. After a pane promotion or an `agtermctl session swap`, an agent that is now in the main pane can still report `right` and will never write the line. Set `CONTEXT_NUDGE_PANE` in that session to correct it.

The headless-run guard depends on `CLAUDE_CODE_ENTRYPOINT`. A Claude Code old enough not to set it makes the hook treat every headless run as the pane's agent, and a `claude -p` you spawn from a session will then overwrite that session's line with its own task.

This is a Claude Code recipe. Codex has no prompt-submit hook to hang it on, so a codex pane keeps whatever line was last set.
