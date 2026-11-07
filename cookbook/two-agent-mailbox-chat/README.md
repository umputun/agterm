# Two-agent mailbox chat

Let two coding agents in one agterm split talk to each other through agterm's pane mailboxes.

Author: [@umputun](https://github.com/umputun)

## What it does

Two agents run side by side in a split session, one per pane, and talk to each other directly: Claude Code and Codex, or two of the same kind. You watch both halves of the exchange without relaying anything by hand. The value is disagreement: an agent working alone accepts its own reasoning, while a second one with its own context attacks it first, whether the subject is a plan, a diff, a bug or a long investigation.

This does the same job as [two-agent-chat](../two-agent-chat/) and is the recommended replacement for it. That recipe types each message into the other agent's composer, the same prompt you type into, and most of its code and most of its limits exist to make that safe. Here a message goes into the other pane's agterm mailbox and the receiving agent picks it up through its own hook, so nothing is ever typed into a terminal. That removes whole classes of problems the typed version has:

- **No contested prompt.** You and the agents no longer share one input line, so a half-written draft, you typing during a send, or a dialog that appears mid-send cannot mix with a message or swallow it.
- **No composer guessing.** Placeholders, prompt suggestions, queue hints, footer rows and Codex's scroll arrow no longer block a send or get mistaken for text, and no agent update to its composer can break delivery.
- **No delivery machinery.** The 197-byte chunks, screen read-back, temporary markers, backspace cleanup and retries are gone, along with the 10,000-character cap, the trailing-backslash rule and the reversed-split wrapper settings.
- **Any pair.** Messages are addressed by pane id, so the two agents can sit either way round, and two Claude Codes or two Codexes work too.

The cost is setup: each agent, and agterm itself, needs a hook installed once, described below.

## Requirements

agterm 0.40.0 or later, which added the per-pane message bus (`agtermctl msg`). Python 3.9 or later. Claude Code with `asyncRewake` hooks, tested with 2.1.317, and Codex with `codex queue` and hooks, tested with 0.166.0; either agent is optional when you pair two of the other.

## Setup

1. Copy `mailbox-chat.py` somewhere on your `PATH`, keeping the executable bit. The skills and the reply line inside every message invoke it as a bare command.
2. Copy `SKILL-claude.md` to `~/.claude/skills/mailbox-chat/SKILL.md` and `SKILL-codex.md` to `~/.codex/skills/mailbox-chat/SKILL.md`. Both loaders require the installed file to be named exactly `SKILL.md`; the suffix here only says which agent it is for.
3. For Claude Code, add this entry to each of `hooks.SessionStart`, `hooks.UserPromptSubmit` and `hooks.Stop` in `~/.claude/settings.json`. A Claude pane without it never receives mail.

   ```json
   {"hooks": [{"type": "command", "command": "mailbox-chat.py claude-hook", "asyncRewake": true, "rewakeSummary": "chat received", "timeout": 2000000}]}
   ```

   The undocumented `rewakeSummary` field (tested with Claude Code 2.1.317 and subject to change) only renames the collapsed pane line; without it, the line reads `Stop hook feedback`.

4. For Codex, add the SessionStart hook to `~/.codex/config.toml`, then trust it once in Codex's `/hooks` dialog; Codex does not run a new hook before that.

   ```toml
   [[hooks.SessionStart]]
   [[hooks.SessionStart.hooks]]
   type = "command"
   command = "mailbox-chat.py codex-hook"
   ```

5. For Codex, add these two lines to `~/.codex/rules/default.rules`, creating the file if needed, with the full path of the copy from step 1, then restart Codex. Codex's default sandbox refuses the connection to agterm's socket that every send makes, and the rule runs only the `say --file` form of that copy outside it. Without the `host_executable` line Codex matches the rule by file name alone, so a `mailbox-chat.py` it writes into the workspace or `/tmp` would run outside the sandbox too. Setting `network_access = true` under `[sandbox_workspace_write]` in `config.toml` also lets sends through, but it opens the network and agterm's whole control API to every command Codex runs.

   ```
   host_executable(name="mailbox-chat.py", paths=["/full/path/to/mailbox-chat.py"])
   prefix_rule(pattern=["mailbox-chat.py", "say", "--file"], decision="allow")
   ```

6. For agterm, add this line to `hooks.conf` beside your `keymap.conf` (`~/.config/agterm/hooks.conf` by default), with the full path to the script, then run `agtermctl hooks reload`. It is what hands mail to Codex.

   ```
   on message /full/path/to/mailbox-chat.py agterm-hook
   ```

7. Start Codex with `--no-daemon` and a first prompt that says nothing about any chat:

   ```sh
   codex --no-daemon "Answer with the single word READY."
   ```

   Put this in a launcher script or alias rather than typing it each time. Without `--no-daemon`, Codex can run its hooks inside a shared background process that carries another pane's ids. The READY prompt is there because Codex registers a conversation, and can take mail, only once its first prompt runs; it must stay free of any topic, since Duplicate as Companion starts the copy with the same command line. The script reads the pane's `AGTERM_*` variables in Codex's commands, which Codex passes through by default; a custom `shell_environment_policy` must keep them.

If your `agtermctl` is not on `PATH` under that name, set `AGTERMCTL` to its full path in both agents' environments.

## Usage

Open a split and start one agent in each pane yourself, with no topic on its command line: Claude Code bare, Codex with the launch line from *Setup*. Wait until Codex has answered READY, and after a `/clear` in Codex give it any prompt first, before the chat starts. Then ask either agent to talk to the other: "chat with codex about the retry bug", "work with claude on this", "ask the other agent what it thinks". The skill's `description` lists the phrases it answers to. That agent sends the first message, and from there each reply arrives in the other pane on its own. Your part is reading both panes and stepping in when they need a decision that is yours.

Claude Code sends with:

```sh
mailbox-chat.py say --stdin <<'MSG'
the message
MSG
```

Codex sends from a file instead, because its allow rule from *Setup* cannot match a heredoc, which Codex runs as a shell script. It writes the message to a file named after its pane's `AGTERM_PANE_ID` and then runs `mailbox-chat.py say --file /tmp/mailbox-chat-<pane>.txt` as a plain command. The script reads only a regular file of up to 64 KiB and never deletes it, so Codex reuses one file for the whole chat.

Either form prints JSON: `sent` means the other pane's mailbox accepted the message, `receiver` is `claude`, `codex` or `none` for who serves that pane, `peerBusy` is true while a Claude receiver is mid-turn, and `error` means the mailbox refused it. `mailbox-chat.py status` reports the same receiver without sending. `mailbox-chat.py deliver` hands a Codex pane's waiting mail to it by hand; run it from a plain shell with that pane's `AGTERM_SESSION_ID` and `AGTERM_PANE_ID`, never through Codex, whose sandbox refuses `codex queue`.

## How it works

`say` finds the other pane of the caller's own session in agterm's tree and sends there with `agtermctl msg send`. It adds a `[peer chat]` label and a closing line naming the reply command and asking for no acknowledgement-only replies. The label tells the receiver that this is conversation from the other agent, not a fresh instruction from you; the reply line tells it how to answer, because nothing else in the exchange does.

A Claude Code receiver is the `claude-hook` subcommand running as an `asyncRewake` hook. It waits on the pane's mailbox with `msg read --wait`, and when mail arrives between turns it acks it and exits with status 2, which Claude Code turns into a new turn carrying the message as hook feedback. `UserPromptSubmit` marks the pane busy and `Stop` clears the mark, so mail never interrupts a running turn; a mail-woken turn marks itself busy because it fires no `UserPromptSubmit`, and an auto-compaction mid-turn leaves the mark alone. One waiter serves a pane under a lock and exits when its Claude Code does.

Codex has no hook that can wake an idle session. Its `SessionStart` hook records the thread id and executable of the interactive Codex in that pane, skipping a nested headless `codex exec` and a start with no transcript, such as Codex's background memory session, and hands over any mail already waiting. After that, agterm's `on message` hook runs `agterm-hook` for each new message; for a pane with a live Codex registration it hands the mail to that thread with `codex queue`, acking each message only after Codex accepted it. The hand-over runs in agterm's hook rather than in `say`, because `codex queue` fails inside a Codex tool sandbox, so delivery to Codex runs outside the sending agent's sandbox. It uses the registered Codex executable, since the hook runs with agterm's own `PATH`, and the socket agterm passes it. A registration whose Codex process has exited is ignored, because `codex queue` would accept mail for a thread nobody runs.

Mail that is not from this recipe, such as a `msg send` from a script, is delivered to either agent marked `[agterm mailbox, not a peer chat message]` with its sender, and the skills tell the agents not to answer it through `say`.

## Limits

**A chat message reaches only the other pane of the sender's split.** `say` addresses the pane beside the sender, so a chat never reaches, or wakes, an agent in any other session.

**The Claude hook runs in every Claude Code you start, not only in chat panes.** It is installed in `~/.claude/settings.json`, so each Claude Code pane in agterm watches its own mailbox. This matters only when something other than this recipe sends mail to those panes: a script's `msg send`, or a `msg send --all` broadcast. Such mail arrives marked as not from the chat, as described above, and starts a turn in an idle Claude pane, so a broadcast starts one in every idle Claude pane it reaches. If nothing else uses agterm's mailboxes, nothing changes. Each waiter checks its mailbox about four times a second; the cost of many idle ones has not been measured.

**Another program that consumes a Claude pane's mail competes with the hook.** One that removes messages with `msg read --ack` or `msg ack` can take a message before the hook sees it.

**Codex can take mail only after its first prompt.** Codex registers a conversation on its first prompt, not at launch, which is why the launch line in *Setup* includes the READY prompt. A Codex started without one reports `receiver: none`, and its mail waits until you prompt it. After `/clear`, mail still goes to the cleared conversation until you give the new one a prompt, so give it one before the chat continues.

**Never put a topic on an agent's command line.** Duplicate as Companion starts each pane's program again with the same command line, so `claude "chat with codex about the retry bug"` in a pane makes the copy start that chat too, unasked. Ask in the pane instead. The Codex launch line in *Setup* is safe to copy: its READY prompt carries no topic.

**A failed hand-over to Codex may be incomplete.** agterm shows a banner for a hook that exits nonzero, and `agtermctl hooks list` keeps its last failure. The hand-over Codex's own start runs, and the Claude waiter, log to `codex-<pane>.log` and `claude-<pane>.log` in the script's state directory, `agterm-mailbox-chat-<uid>` under the system temp directory. Codex may already have accepted a message whose ack then failed, so read the Codex pane before retrying with `mailbox-chat.py deliver`, or the same message can arrive twice.

**Unread mail is lost** when agterm quits, and when the receiving pane closes or its program is restarted: agterm keeps mailboxes in memory and drops one with its pane. A Claude Code turn interrupted with Esc reports no end, so its mail waits until the next turn completes.

The recipe never types into a pane, starts, restarts or stops an agent, or closes anything. Remote panes are not supported.
