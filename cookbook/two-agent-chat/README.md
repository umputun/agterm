# Two-agent chat

Let Claude Code and Codex hold a conversation with each other in one agterm split.

*A simplified version of the setup I run myself, cut down to the part worth publishing. Tested for real, with two agents talking to each other through it, but this is a first version and it will be updated as it gets used.*

## What it does

Two coding agents run side by side in a split session, one per pane, and talk to each other directly. Each sends a single line into the other's composer with `peer-chat.py`, and the reply arrives in its own pane as an ordinary prompt. You watch both halves of the exchange without relaying anything by hand.

The value is disagreement. An agent working alone accepts its own reasoning; a second one with its own context attacks it first, and what comes back is a located disagreement or a checked fact rather than agreement.

That is not only for planning. It works on the code itself: two agents reviewing the same diff find different defects, and each can refute the other's finding before it reaches anyone. It works on a bug, where one traces the failure and the other tries to prove the diagnosis wrong. It works on a long investigation, where splitting the reading keeps them off the same files. Design discussion is one use among those, not the point.

You start it, and you have to name the other agent for the skill to fire. Say "work with codex on the retry bug" or "chat with codex about this" to Claude Code, or "work with claude on it" to Codex, and that agent sends the first message; from there each reply arrives in the other's pane on its own and the exchange continues without you. Both skill files list the phrases they answer to in their `description` field, so read that before inventing your own. Your part after the first message is reading both panes and stepping in when they need a decision that is yours.

## Requirements

agterm 0.24.0 or later, which added `surface cursor`. The recipe refuses to type anything without it. Python 3.10 or later. Claude Code and Codex, each already installed and runnable.

## Setup

1. Copy `peer-chat.py` somewhere on your `PATH`, keeping the executable bit.
2. Copy `SKILL-claude.md` to `~/.claude/skills/peer-chat/SKILL.md` and `SKILL-codex.md` to `~/.codex/skills/peer-chat/SKILL.md`. Both loaders require the installed file to be named exactly `SKILL.md`, so the suffix here only says which agent the file is for. Each one tells its own agent how to send, how to recognise an incoming message, and what it may not do to the other pane.
3. Edit both copies so the path they name for `peer-chat.py` matches where you put it.
4. If you start either agent through a wrapper script rather than as `claude` or `codex`, put that wrapper's name in the same file, as the `--target-command` value the agent should pass when sending to it. Without this the first send refuses, saying the target pane is not running the expected command.
5. To let Codex reserve and send file-backed messages without separate approvals, add these two entries to `~/.codex/rules/default.rules`, creating the file if needed and using the command name or path from step 1:

   ```python
   prefix_rule(pattern=["peer-chat.py", "--prepare-message"], decision="allow")
   prefix_rule(pattern=["peer-chat.py", "--to", "claude", "--message-file"], decision="allow")
   ```

6. Start Codex so it can tell which pane it is in. Codex strips `AGTERM_SESSION_ID` from tool subprocesses, so start it with `codex -c "shell_environment_policy.set.AGTERM_SESSION_ID=\"$AGTERM_SESSION_ID\""` to copy the current pane's session id into every tool command, adding your normal Codex options to the same command. Without this injection the script can still resolve one matching repository checkout, but it refuses when several sessions share that checkout. If you launch Codex through a wrapper, put the flag in the wrapper and it applies to every pane.

If your `agtermctl` is not on `PATH` under that name, set `AGTERMCTL` to its full path; the script reads that variable and falls back to `agtermctl`.

## Usage

Open a split in the session you want to use, then start one agent in each pane yourself: Claude Code on the left, Codex on the right. Neither the script nor the skills start an agent, by design.

Ask either agent to talk to the other, and it sends through the script:

```sh
peer-chat.py --to codex --stdin <<'MSG'
your message as one paragraph
MSG
```

`--to claude` sends the other way. `--session` names a session explicitly; without it the script uses `AGTERM_SESSION_ID` when the caller has one, and otherwise looks for a single session whose target pane is running the expected agent.

Codex can keep the send as plain command arguments by using a private one-shot message file. Reserve a fresh name first:

```sh
peer-chat.py --prepare-message peer-chat-codex-a91f.txt
```

The command prints the absolute `messageFile` path. Write the UTF-8 message to that exact file without replacing its mode, then send it by name:

```sh
peer-chat.py --to claude --message-file peer-chat-codex-a91f.txt
```

This form matches the two Codex execution rules in *Setup*. A heredoc uses shell redirection, so Codex evaluates the whole request as a shell wrapper and cannot match the inner command.

Before every send the script confirms that the pane it is about to type into really is running the agent named by `--to`, reading the command from agterm's own view of the pane. It looks for `claude` and `codex`. If you start an agent through a wrapper script, that name is what agterm sees instead, and the send is refused until you say so:

```sh
peer-chat.py --to claude --target-command cld --stdin <<'MSG'
your message as one paragraph
MSG
```

A path works as well as a bare name; only the last component is compared. `PEER_CHAT_CLAUDE_COMMAND` and `PEER_CHAT_CODEX_COMMAND` do the same thing through the environment, for an agent that cannot easily add a flag. Only the pane being sent to is checked, so a wrapped Claude Code can still send to a plain Codex without any of this.

On success it prints `{"sent": N}` and exits 0. Any refusal or failure exits 1 with the reason on stderr, and an interrupt exits 130.

## How it works

The message is typed into the other pane's composer through `agtermctl session type`, which is real typing rather than a paste, so a newline would submit a half-written line. The script collapses the message to one paragraph before sending, which is why the examples above are written as one.

Three checks guard every send. The script first confirms that the pane contains a recognisable composer prompt, then `agtermctl surface cursor` must report the caret at column 2, where it rests in an empty composer. The caret read is the final pre-write check. Pane text cannot prove the composer is empty: both agents draw a placeholder hint in an empty box, so a hint and something you half-typed read alike, while the caret sits past the chevron whenever real text is present. A pre-write refusal means nothing was written. After typing, the script confirms that the line is visible where a message goes before it sends the submit key, so a dialog can receive text but cannot be answered. A refusal there means the text may still be sitting in the composer, which is why the script stops instead of retrying.

The two agents need different submit keys. Codex takes Tab, which queues the line as a follow-up when it is mid-turn and submits on an idle composer; Return would steer a running turn instead. Claude Code takes Return. Getting this backwards is the single easiest way to break the exchange.

Messages carry a label, `Chat from Claude:` or `Chat from Codex:`, which is what lets the receiving agent read an arriving prompt as the next line of a conversation rather than as a fresh instruction from you. The script adds the label, so the skills tell each agent not to write one.

Sending requires exactly one of `--stdin` and `--message-file NAME`. Both keep the message text out of the process list and protect its punctuation from the shell. `--prepare-message NAME` creates the named file with mode 0600 in a per-user directory with mode 0700. A file-backed send resolves and checks the target session before opening the file. It accepts only a reserved basename, rejects links, non-regular files, files accessible to other users, and bodies over 64 KiB, then removes the directory entry before reading the message.

The recipe deliberately does not start agents. Deciding that a pane is safe to type a startup command into means guessing from what the pane has drawn, and agterm reports no foreground process for both an idle shell and a program that hides its argv. Every prompt looks different, so that guess is wrong on somebody's machine, and being wrong means typing a command into whatever holds focus.

## Limits

**The script types into another pane's composer, and it can submit text you did not write.** The caret check is one-way evidence: a caret at column 2 rules out a draft whose cursor sits after the text, but it cannot tell an empty composer from a draft whose cursor was moved back to the start. In that state the message is inserted in front of your draft and both are submitted together. The check made after typing cannot rule that out either: only the composer's first rendered row is identifiable, so once a message wraps, anything left on a continuation row is invisible to it, in both directions. Do not leave half-written input in a pane you are about to receive a message in.

**In practice it does not type into dialogs, but a short window exists where it could.** A dialog already on screen stops the send: the pane must contain a recognisable composer prompt and the caret must be at rest before a single character goes anywhere. The window is only the moment between the caret check and the typing, which are separate `agtermctl` calls, so a chooser or trust prompt appearing inside it would receive the message text. Even then the post-write check fails and the submit key is withheld, so nothing is answered and no choice is confirmed, though characters reaching a picker can move its selection.

**The first exchange may stop and wait for you.** An agent asked to run this script may put up its own approval request before running anything, and neither skill will answer it: a permission prompt carries your authority, so both are told to leave it alone. Until you approve it in that pane, the exchange simply sits there, which looks like a hang rather than a question.

**A busy composer is waited out, but only for about forty seconds.** If the other pane's composer is not confirmably empty, the script retries five times at ten-second intervals, printing each attempt to stderr, then gives up with exit 1 and types nothing. A pane left sitting on a dialog therefore costs about forty seconds before the send fails rather than blocking forever.

**A multi-row Codex shortcut overlay is treated as busy.** The parser ignores one trailing status row. It does not strip a whole indented region because shortcut rows and modal choices have the same shape; the send therefore retries and refuses until a multi-row overlay closes.

**Only the pre-write refusal is retried.** Nothing has been typed at that point, so trying again is safe. Every failure after the text has gone in stops on the first occurrence and is never retried, because retrying there would duplicate a message that is already sitting in the composer.

**A failed send can strand the message in the composer.** When the script types successfully but cannot verify the result, it stops with the text still sitting there. Read the pane before doing anything else: retrying blind either duplicates the message or leaves the old line to be submitted later by hand.

The two directions are not symmetric. Codex is sent Tab, which queues the line while it is busy and costs a running turn nothing. Claude Code has no queue-only key and is sent Return, so a message arriving while it works injects into the turn in progress and can interrupt it. Send to Claude when you have finished, not mid-thought.

It assumes Claude Code on the left and Codex on the right. Each agent's pane is fixed in the script's profiles, so a split arranged the other way sends every message to the wrong pane. A session with no split is refused outright, before any pane is read: without that check a send to the left pane would still pass after the right one had closed, which is no longer a two-agent layout at all.

**Codex cannot see which pane it is in unless you tell it at launch.** It strips `AGTERM_SESSION_ID` from every tool subprocess, and nothing inside its sandbox recovers the value: reading a parent process is blocked outright. Without the launch injection in *Setup*, the script falls back to matching the git checkout, and every worktree of one repository maps to the same checkout, so two sessions open on the same repository are indistinguishable and the send refuses. That refusal is the correct outcome, not a bug, but it is why the injection is worth doing once in your Codex launcher rather than remembering per session.

Session resolution never guesses. With `AGTERM_SESSION_ID` or `--session` it uses that session after checking the target pane. Without either, it matches only sessions in the same checkout as the caller, and refuses on none or several rather than picking a session elsewhere that happens to have the right shape. `--session` takes a full id or any unique prefix of one.

An agent whose launcher leaves no stable name in the pane's command line cannot be targeted at all. `--target-command` matches a name that agterm can actually see, so a wrapper that execs through something anonymous stays unsupported and every send to it refuses.

A reply is not promised. An agent's model can decline to answer a message that arrived perfectly well, and nothing on either side reports that. If an exchange goes quiet, read the other pane rather than waiting.

No transcript is kept. A one-shot message file remains untouched until the target session resolves. Once its identity, ownership and link checks pass, its directory entry is removed before mode, size and body validation, so those validation failures and every later send failure consume it. A prepared file that never reaches that point remains in the private spool. The conversation lives in the two panes and is gone when the session ends.
