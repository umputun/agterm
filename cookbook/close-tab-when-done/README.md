# Close tab when done

Arm a tab with one chord and it closes itself the moment the agent stops replying.

## What it does

The last prompt of a task is usually the last thing that tab is for. What is left is a finished agent sitting in a session you have to come back to and close by hand, and a sidebar that slowly fills up with them.

Asking the agent to close the tab itself does not work well. It closes the session in the middle of its own final message, so the reply you were waiting for is killed half-drawn, and it only happens at all if the agent remembers to run the command and is allowed to.

So the chord marks the tab instead, and the agent's stop hook is what closes it. Press it before you send the prompt you expect to be the last one, or while that prompt is being worked on. A `⏻` appears in front of the session's name in the sidebar, and the tab closes when the agent next finishes a turn. Press it again to disarm.

**Firing closes the session and kills every process in it, with no undo.** The agent, whatever ran in its split pane, and the scrollback all go with it. This is a chord that arms a destructive action a turn in advance, so *Limits* is the section of this README worth reading twice.

The marker is one shot: the hook consumes it on the first turn that ends, so a tab cannot close twice or take a second task down with it.

## Requirements

- agterm 0.22.0 or later, which fixed a custom command spawning with a `PATH` that could not resolve a bare `agtermctl`.
- `jq`
- Claude Code, whose `Stop` hook fires the close. Any agent that can run a command when it finishes a turn works the same way; *How it works* says what that hook has to inherit.

## Setup

Copy the script somewhere and make it executable. Anywhere works as long as the keymap line and the hook point at it:

```sh
mkdir -p ~/bin
cp agt-autoclose.sh ~/bin/
chmod +x ~/bin/agt-autoclose.sh
```

Add an entry to `~/.config/agterm/keymap.conf` and apply it with File ▸ Reload Keymap or `agtermctl keymap reload`:

```
command "Autoclose" ctrl+shift+w ~/bin/agt-autoclose.sh toggle "{AGT_SESSION_ID}"
```

Any free chord works; `agtermctl keymap list` shows what every chord currently resolves to. A custom command cannot shadow a built-in, so one that collides is quietly demoted to palette-only and the chord appears to do nothing — the entry is still reachable by name from the action palette, which is the quickest way to tell a bad chord from a broken script.

`{AGT_SESSION_ID}` is the session the chord fired in. Without it the script falls back to `$AGTERM_SESSION_ID`, which a chord does not have: a custom command inherits the app's launch environment, not a terminal's.

Then register the stop hook by adding an entry to the `Stop` array in `~/.claude/settings.json`, alongside anything already there:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/bin/agt-autoclose.sh fire",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

`fire` takes no argument: it reads `$AGTERM_SESSION_ID` from the environment the agent inherited from its session, so the same hook line serves every tab. Leave `async` off it, which is what lets the agent tear the hook down before it has detached the close.

Fired from a chord or the palette, the script runs under the app's `PATH` rather than your shell's. That is the launchd default: `/usr/local/bin` plus the system directories, with no `/opt/homebrew/bin` and nothing else your profile adds. Both binaries this recipe needs resolve there — `jq` from `/usr/bin`, which recent macOS ships, and `agtermctl` from `/usr/local/bin`, where **Help ▸ Install Command Line Tool…** symlinks it. A Homebrew `jq` is out of reach from a chord; set `AGTERMCTL` to the CLI's full path, and `PATH` in front of the keymap line, if either binary sits somewhere unusual. The hook half has no such problem: it runs under the agent's own environment, which is your shell's.

Three settings, all read from the environment, all optional:

- `AGT_AUTOCLOSE_DIR` — where the markers live, `~/.agterm-autoclose` by default. The chord and the hook must agree on it, and they read it from different environments, so change the default in the script rather than exporting it in one place only.
- `AGT_AUTOCLOSE_BADGE` — what goes in front of the session name while it is armed, `⏻ ` by default, trailing space included. Set it to an empty string for no badge at all, which also stops the recipe renaming sessions; the arming state is then invisible except through `agt-autoclose.sh status`.
- `AGT_AUTOCLOSE_GRACE` — seconds between the hook firing and the session closing, `0.4` by default. It is there so the agent finishes drawing its last reply before the terminal goes away, and it is the only delay involved: the close itself is immediate.

## Usage

Press the chord. A `⏻` appears in front of the session name, the tab closes when the agent finishes its next turn, and the row is gone from the sidebar as it does.

Press it again before that happens and the tab is disarmed, badge and all.

From a shell inside the session:

```sh
agt-autoclose.sh status            # on | off
agt-autoclose.sh on                # arm this session
agt-autoclose.sh off               # disarm it
agt-autoclose.sh on <session-id>   # arm another one
```

The id form is what to use from a script, or from an agent driving another session: everything except `fire` takes one, and `fire` deliberately does not, so a hook can never be pointed at a session other than its own.

## How it works

An armed session is an empty file named after its session id, under `~/.agterm-autoclose`. The chord creates or removes it; the stop hook looks for one, and does nothing at all when there is none — which is what makes it safe to leave the hook installed in every session forever.

The hook is the whole point of the recipe. `Stop` fires after Claude Code has finished the turn, so the reply is on screen and complete before anything closes; an agent that closes its own session does it from inside the turn, killing the message it is still writing. It also means no instruction, no tool permission, and no cooperation from the model is involved: the tab closes because the turn ended, not because the agent decided to.

`session close` kills the agent, and the agent is the hook's own parent process. A close called straight from the hook is a process closing the terminal its own caller lives in, and it can die with the session before the server acts on it. So `fire` detaches the work: `nohup` makes it ignore the `SIGHUP` that reaches the session's processes as the terminal goes away, and it re-enters this same script with an internal `close-later` verb rather than composing an `sh -c` line, which keeps the socket path — it holds a space on a default install — out of a second round of shell quoting.

That socket is read from `$AGT_SOCKET` when a chord fired the script, and from `$AGTERM_SOCKET` when a session's shell or one of its hooks did. Passing it explicitly keeps a second agterm, running from a different state directory, from being the one that gets closed.

Not every Claude Code run belongs to the tab whose id it carries. A background or adopted session runs inside a daemon-hosted worker — `claude daemon run`, `bg-spare`, `bg-pty-host` — and that worker keeps the `AGTERM_SESSION_ID` of whichever tab first started the daemon, which is usually a tab closed long ago and in any case says nothing about where this agent is running. Firing on that id would close a session that has nothing to do with the turn that just ended, so `fire` walks up from `$CLAUDE_PID` and stays silent when it finds one of those workers above it. The walk is bounded to twelve hops and reads `ps` only, so it costs nothing on an ordinary turn.

The session id is validated as a UUID before it is ever used as a file name, and upper-cased on the way in. Both halves matter: the id is an argument this README tells you to pass, so `on ../../notes.md` is a plausible typo, and it would truncate that file rather than arm anything. The case fold is what makes a hand-typed lower-case id arm the marker the hook will actually look for.

The badge costs a read that is easy to get wrong. `tree` reports one window — the frontmost — and an armed session is very often not in it: the agent works in a background window while you use another. So the script walks `window list` and reads each window's tree until it finds the session, rather than reading the frontmost tree and treating a miss as "no such session". `window list` also reports windows that are closed, and `tree` answers a null tree for one of those, so the walk filters on `open` or every read drags a jq error onto stderr. Addressing is the other way round: `session rename --target` and `session close --target` resolve a session id across every window, so the write half needs no window at all.

`fire` does none of that walking. It removes the marker, detaches the close and returns; the sidebar row is about to disappear, and a window walk there would spend the hook's timeout on a badge nobody will see. Every path out of it exits 0, and it is a silent no-op without `agtermctl` on `PATH` or `$AGTERM_SESSION_ID` in the environment — a hook that fails reports an error at the end of a turn that went fine, which the user can do nothing about.

## Limits

**Firing closes the session and kills everything in it.** Whatever ran there dies with it — the agent, a server in its split pane, an SSH connection — and the scrollback goes with the session. There is no undo: the grace-period reopen agterm offers covers closing sessions from the GUI, not a single close over the control API. `AGT_AUTOCLOSE_GRACE` only delays the close, it does not make it recoverable.

**A stop hook fires at the end of every turn, including one that ends with a question to you.** If the agent stops to ask which of two approaches you want, that is a finished turn, and an armed tab closes while the question is on screen. Arm the tab on the prompt you expect to be the last one, not at the start of a long task.

**A second agent started inside an armed session closes the tab when *it* finishes.** A `claude -p` run from a script in that shell inherits the session's environment and fires this same `Stop` hook, so the tab goes at the end of the child's turn rather than yours. The hook's payload does not say which agent it belongs to, and the process tree is no help: Claude Code's own daemon and pty-host processes are called `claude` as well, so counting agents among the ancestors finds several on a perfectly ordinary turn. Either arm the tab after that kind of work, or run the nested agent with its hooks disabled.

A run the daemon hosts never fires, by the rule above. An armed tab whose agent has been adopted that way stays armed and keeps its badge until a foreground turn ends in it, or until you disarm it.

**The badge renames the session.** A session that had an automatic name — the one agterm derives for you — comes back from a disarm with that same text as an explicit custom name, and it no longer follows what the session is doing. Set `AGT_AUTOCLOSE_BADGE=` to an empty string if you would rather keep automatic names, and lose the visible arming state with it.

The marker is per session, not per pane. A split running two agents shares one session id: whichever finishes first closes the tab, taking the other agent's pane with it.

Interrupting the agent does not fire the hook. Claude Code reports an interrupted turn as `StopFailure` rather than `Stop`, so an armed tab stays armed and closes at the end of the next turn instead — which may be one you did not mean to be the last.

A chord fired inside a scratch terminal or an overlay can resolve against whichever session is active rather than the one it was pressed in, so it may arm the wrong tab. The badge is the check: if it appears somewhere you did not expect, press the chord again in that session to disarm it.

A session closed by hand while armed leaves its marker behind. Session ids are never reused, so a stale marker can never fire; it is an empty file, and the directory is yours to clear whenever it bothers you.

Sub-agents are not covered. Claude Code reports those to `SubagentStop`, which this recipe deliberately does not hook: a finished sub-agent is not a finished task.
