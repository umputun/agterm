# Two-agent chat

Let Claude Code and Codex hold a conversation with each other in one agterm split.

*A simplified version of the setup I run myself, cut down to the part worth publishing. Tested for real, with two agents talking to each other through it, but this is a first version and it will be updated as it gets used.*

## What it does

Two coding agents run side by side in a split session, one per pane, and talk to each other directly. Each sends a single line into the other's composer with `peer-chat.py`, and the reply arrives in its own pane as an ordinary prompt. You watch both halves of the exchange without relaying anything by hand.

The value is disagreement. An agent working alone accepts its own reasoning; a second one with its own context attacks it first, and what comes back is a located disagreement or a checked fact instead of agreement.

That is not only for planning. It works on the code itself: two agents reviewing the same diff find different defects, and each can refute the other's finding before it reaches anyone. It works on a bug, where one traces the failure and the other tries to prove the diagnosis wrong. It works on a long investigation, where splitting the reading keeps them off the same files. Design discussion is one use among those, not the point.

You start it, and you have to name the other agent for the skill to fire. Say "work with codex on the retry bug" or "chat with codex about this" to Claude Code, or "work with claude on it" to Codex, and that agent sends the first message; from there each reply arrives in the other's pane on its own and the exchange continues without you. Both skill files list the phrases they answer to in their `description` field, so read that before inventing your own. Your part after the first message is reading both panes and stepping in when they need a decision that is yours.

## Requirements

agterm 0.24.0 or later, which added `surface cursor`. The recipe refuses to type anything without it. Python 3.10 or later. Claude Code and Codex, each already installed and runnable.

## Setup

1. Copy `peer-chat.py` somewhere on your `PATH`, keeping the executable bit.
2. Copy `SKILL-claude.md` to `~/.claude/skills/peer-chat/SKILL.md` and `SKILL-codex.md` to `~/.codex/skills/peer-chat/SKILL.md`. Both loaders require the installed file to be named exactly `SKILL.md`, so the suffix here only says which agent the file is for. Each one tells its own agent how to send, how to recognise an incoming message, and what it may not do to the other pane.
3. Edit both copies so the path they name for `peer-chat.py` matches where you put it.
4. If you start either agent through a wrapper script instead of as `claude` or `codex`, put that wrapper's name in the same file, as the `--target-command` value the agent should pass when sending to it. Without this the first send refuses, saying the target pane is not running the expected command.
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

`--to claude` sends the other way. `--session` names a session explicitly; without it the script uses `AGTERM_SESSION_ID` when the caller has one, and otherwise looks for a single session whose target pane is running the expected agent. An explicit session is found across open windows, while `--window` constrains the lookup. The resolved window id stays pinned for the full send.

Claude Code normally sends to Codex with Return, the key Codex uses for steering an active turn. Codex can still queue it when its current state cannot accept a steer. Add `--queue` only for an informational note that can wait until the turn ends:

```sh
peer-chat.py --to codex --queue --stdin <<'MSG'
the background check finished; no action is needed in this turn
MSG
```

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

The message is typed into the other pane's composer through `agtermctl session type --stdin`, which treats a newline as Return. The script collapses the message to one paragraph and packs words into UTF-8-safe events. Each body event ends with a short marker absent from the message, and the complete event stays within 197 bytes. A live boundary test accepted a 1,627-byte event and began losing 1,022-byte windows at 1,663 bytes; the smaller cap also keeps one event visible in a narrow Claude composer. After every event the script waits for the marked composer to settle, checks the newly visible tail against that event and an overlap from the preceding text, backspaces the marker, and confirms its removal. The comparison permits a source space to become a terminal wrap, so it still works after the opening text has scrolled out of view. If a clipped periodic tail could represent either complete input or a truncated current event, the script refuses the send. The final unmarked body must stay settled for 500 ms before the script sends the submit key separately and confirms that the body cleared.

Before the body request, the script confirms that the target pane runs the expected agent and contains its known empty input: a blank Claude prompt, either shipped Claude queue hint, or Codex's `Ask Codex to do anything` placeholder. `agtermctl surface cursor` must also report the caret at column 2. Both checks are required because a full-width Codex draft can wrap its caret onto a reserved empty row at column 2. It checks the target process once more immediately before each write. The agterm window is fixed before these checks, so changing the frontmost window during a send cannot redirect or strand later pieces. A changed placeholder fails closed until the recipe is updated.

**Why the body is split and submit is separate:** Claude Code can lose the middle of an oversized text event, and it may absorb Return when that key reaches its parser in the same burst as the body. Bounded, separately observed events avoid the reproduced loss; the temporary marker makes each event change observable; the visible-tail comparison rejects visible mismatches and ambiguous clipped periodic alignments. The final settled-state interval makes the following Return distinct even when rendering is slow.

Return is the normal submit key in both agents. In Codex it requests steering of the running turn; `--queue` uses Tab for a note that should wait until the turn ends. The script confirms that the composer cleared, but cannot distinguish an accepted steer from Codex queueing the message because the current state cannot be steered. Claude Code accepts Return and manages its own busy queue.

Messages carry a label, `Chat from Claude:` or `Chat from Codex:`, which lets the receiving agent read an arriving prompt as the next line of a conversation instead of as a fresh instruction from you. The script adds the label, so the skills tell each agent not to write one.

When the conversation reaches shared files, the agent whose pane received your initiating request is the sole writer for that whole worktree until the task ends. The peer stays read-only there and may inspect, review, or pass a proposed patch through a mode-0600 file under `/tmp`; the writer works only from its private verified copy and cleans both paths before reporting an outcome or resuming after an interruption. Peer messages never transfer write authority. This fixed role prevents concurrent edits within one peer-chat task while still letting both agents work on the change.

Sending requires exactly one of `--stdin` and `--message-file NAME`. Both keep the message text out of the process list and protect its punctuation from the shell. `--prepare-message NAME` creates the named file with mode 0600 in a per-user directory with mode 0700. A file-backed send resolves and checks the target session before opening the file. It accepts only a reserved basename, rejects links, non-regular files, files accessible to other users, and bodies over 64 KiB, then removes the directory entry before reading the message.

The recipe deliberately does not start agents. Deciding that a pane is safe to type a startup command into means guessing from what the pane has drawn, and agterm reports no foreground process for both an idle shell and a program that hides its argv. Every prompt looks different, so that guess is wrong on somebody's machine, and being wrong means typing a command into whatever holds focus.

## Limits

**The script types into another pane's composer.** It accepts only the agent's known empty prompt together with a caret at column 2, which rejects ordinary drafts even when their caret is at the start or wraps onto an empty row. A draft whose complete text equals one of the recognised placeholders can still imitate that state. Do not leave half-written input in a pane you are about to receive a message in.

**Short dialog races remain.** A dialog already on screen stops the send: the pane must contain a recognisable empty composer before a single character goes anywhere. A chooser or trust prompt that appears during a body write could receive text; the next composer check withholds submit, but cleanup backspaces could still affect the dialog. The visible composer state must remain unchanged from the final settled chunk immediately before Return. A chooser that appears after that check and before the separate Return request can still receive the key because agterm has no conditional type operation.

**Do not type in the receiving pane during a send.** Recovery progressively checks that every visible row is one contiguous part of the script's attempted body before each bounded backspace batch. This permits cleanup after the opening has scrolled away and stops when newly revealed or appended text is foreign. A keystroke arriving after that ownership check but before its backspaces can still be erased.

**The first exchange may stop and wait for you.** An agent asked to run this script may put up its own approval request before running anything, and neither skill will answer it: a permission prompt carries your authority, so both are told to leave it alone. Until you approve it in that pane, the exchange simply sits there and looks like a hang, not a question.

**A busy composer is waited out, but only for about forty seconds.** If the other pane's composer is not confirmably empty, the script retries five times at ten-second intervals, printing each attempt to stderr, then gives up with exit 1 and types nothing. A pane left sitting on a dialog therefore costs about forty seconds before the send fails instead of blocking forever.

**A multi-row Codex shortcut overlay is treated as busy.** The parser ignores one trailing status row. It does not strip a whole indented region because shortcut rows and modal choices have the same shape; the send therefore retries and refuses until a multi-row overlay closes.

**Highly repetitive input can be refused after the opening scrolls away.** A rendered suffix such as a long run of one character can align with both the complete message and one missing part of the current event. The script stops and cleans up when it cannot distinguish those states.

**Rendered text cannot prove every source character.** Agterm exposes the terminal's plain screen text, which omits an ASCII space consumed at a visual line wrap. A correctly wrapped space and a missing space at that exact boundary therefore look identical to the script. The 197-byte event cap avoids the reproduced oversized-event loss, but the read-back is not a byte-level receipt from the agent's editor.

**Only a confirmed pre-body refusal is retried.** Nothing has been typed at that point, so trying again is safe. Once the body request starts, any failure stops on the first occurrence. Before submission, the script backspaces the text it owns and reports whether the empty composer was restored; it never sends an interrupt key to clear a busy agent. A failure during or after the submit request is ambiguous and retrying could duplicate the message.

**Shared-work ownership is conservative.** If an agent learns that both panes received direct requests authorising writes in the same worktree, it stops before another write and asks you to stop the other pane, then assign one writer directly in the chosen writer's pane. The protocol cannot prevent edits made before either agent learns about the second request. If an interrupted conversation no longer identifies the writer, use the same direct stop and assignment. To switch writers during a task, stop the current writer and assign the work directly in the other pane; a peer-chat message alone cannot do it.

The two directions are not symmetric. Codex exposes both steering Return and queued Tab, while Claude Code exposes only its normal Return submission and manages busy input itself. Use `--queue` only for a Codex-bound note that needs no action during the current turn.

It assumes Claude Code on the left and Codex on the right. Each agent's pane is fixed in the script's profiles, so a split arranged the other way sends every message to the wrong pane. A session with no split is refused outright, before any pane is read: without that check a send to the left pane would still pass after the right one had closed, which is no longer a two-agent layout at all.

**Codex cannot see which pane it is in unless you tell it at launch.** It strips `AGTERM_SESSION_ID` from every tool subprocess, and nothing inside its sandbox recovers the value: reading a parent process is blocked outright. Without the launch injection in *Setup*, the script falls back to matching the git checkout, and every worktree of one repository maps to the same checkout, so two sessions open on the same repository are indistinguishable and the send refuses. That refusal is the correct outcome, not a bug, but it is why the injection is worth doing once in your Codex launcher instead of remembering per session.

Session resolution never guesses. With `AGTERM_SESSION_ID` or `--session` it searches open windows for that session, pins its owning window and checks the target pane; `--window` restricts this to one window. Without a session id, it matches only sessions in the same checkout as the caller, and refuses on none or several instead of picking a session elsewhere that happens to have the right shape. `--session` takes a full id or any unique prefix of one.

An agent whose launcher leaves no stable name in the pane's command line cannot be targeted at all. `--target-command` matches a name that agterm can actually see, so a wrapper that execs through something anonymous stays unsupported and every send to it refuses.

A reply is not promised. An agent's model can decline to answer a message that arrived perfectly well, and nothing on either side reports that. If an exchange goes quiet, read the other pane instead of waiting.

No transcript is kept. A one-shot message file remains untouched until the target session resolves. Once its identity, ownership and link checks pass, its directory entry is removed before mode, size and body validation, so those validation failures and every later send failure consume it. A prepared file that never reaches that point remains in the private spool. The conversation lives in the two panes and is gone when the session ends.
