# Truthful agent lights

A Claude Code session's row reports what is still running when the turn ends, and a sweeper clears every glyph nothing backs.

## What it does

The stock hooks map Stop to `completed --auto-reset` unconditionally, which is right for a session that finished and wrong for one that did not. Three cases go wrong in agent-heavy use:

- **The turn ends, the work does not.** A session that started a test run in the background, or dispatched a second agent as a worker, goes green at Stop while that work runs on. Visit the row once and the glyph clears, so it is now indistinguishable from an idle shell.
- **The agent dies, the glyph lives.** A killed or crashed agent leaves its last `active` pulsing forever, because a pushed status is trusted until something pushes another one.
- **Thinking, machinery and waiting look identical.** A thirty-minute test run, a model composing a reply, and a session waiting on a lock are all `active`, so "is it working, waiting, or wedged?" cannot be answered from the sidebar.

This recipe replaces the Stop hook with a classifier that looks at what is still alive under the agent process and picks the glyph that matches, and adds a scheduled sweeper that enforces the same truth from the outside, in both directions: it clears a claim no process backs, and re-lights a row that is quietly working.

The other agent-status recipes — `kimi-agent-status`, `kiro-agent-status`, `container-agent-status` — wire one more agent's lifecycle hooks to the stock four-state vocabulary. This one goes the other way: it keeps that package installed and replaces only the decision Stop makes, then adds a sweeper that runs out of band, on a timer, with no hook involved. If you also run `status-announcer`, note that it speaks `blocked`, `completed` and `idle`: the sweeper's own clears are status changes like any other, so a row it corrects at three in the morning is a sentence spoken out loud.

Sub-states are drawn with the per-call `--color` and `--shape` overrides:

| glyph | means |
|---|---|
| pulsing default | a dispatched worker or subagent is still running, or the model is producing |
| work color, running shape (square) | machinery is executing: tests, a build, a remote run |
| work color, mixed shape (diamond) | machinery is executing *and* something else is queued behind it |
| work color, queued shape (triangle) | only waiting: a lock queue, a poll loop, a log watcher |
| stuck color, stuck shape (star), pulsing | the row claims to be working, nothing is running under it, and the transcript has not moved |
| completed | the turn ended and the scan found nothing running |

A per-call override beats what you picked in Settings ▸ Agent Status, for as long as that status stands. If a shape here collides with the vocabulary you configured there, change the shape variables in `lights-common.sh` rather than your settings — the recipe is the thing that should give way.

## Requirements

- agterm 0.17.0 or later — `agtermctl session status --shape` and the matching `statusShape` field on `tree` shipped there (#292, selectable status-glyph silhouettes picked per status in Settings or per call). Everything else the recipe uses is older: `--color` in 0.7.1 (#129), `--pane` and the injected `AGTERM_PANE` in 0.7.1 (#130), `--pane-id` in 0.13.0, the `statusBlink` read-back on `tree` in 0.10.0 (#169), and `--blink`, `--auto-reset`, `window list --json` and `tree --json` all predate the earliest tagged release.
- `jq`, and a BSD userland: the scripts use `ps -axo`, `ps eww`, `stat -f %m` and `find -mmin` as macOS provides them.
- Claude Code. The classifier reads a Claude Code implementation detail — see *Limits* — verified against 2.1.235.
- The agent-status hooks package (Help ▸ Install Agent Status Hooks…), optional but recommended: when its `agterm-agent-status.sh` is present the recipe posts through it, so socket, pane and pane-id handling stay upstream's. Without it the recipe calls `agtermctl` itself.
- `launchd` for the sweeper, or any scheduler that can run a command every couple of minutes.

## Setup

Copy the recipe somewhere stable and make the scripts executable:

```sh
mkdir -p ~/.config/agterm/truthful-lights
cp truthful-agent-lights/* ~/.config/agterm/truthful-lights/
chmod +x ~/.config/agterm/truthful-lights/*.sh
chmod -x ~/.config/agterm/truthful-lights/lights-common.sh
```

`lights-common.sh` is sourced by the others, never run, so it is the one file that does not want the executable bit. Everything machine-specific lives in it as a variable with a default:

| variable | default | what it is |
|---|---|---|
| `AGTERMCTL` | `agtermctl` | the CLI that talks to the control socket |
| `AGT_LIGHTS_STATE` | `~/.local/state/agterm-lights` | pid notes, turn stamps, heartbeats |
| `AGT_STATUS_SCRIPT` | the hooks package's `agterm-agent-status.sh` | the stock script to post through, when it exists |
| `AGT_AGENT_PATTERN` | `claude\|codex\|kimi\|opencode\|pi` | command names that count as an agent |
| `AGT_WORK_COLOR` / `AGT_STUCK_COLOR` | `#4A9EFF` / `#FF3B30` | the two tints |
| `AGT_SHAPE_RUNNING` / `_MIXED` / `_QUEUED` / `_STUCK` | `square` / `diamond` / `triangle` / `star` | the silhouettes |
| `AGT_HB_FRESH_SECS` / `AGT_HB_STALE_SECS` | 300 / 1500 | how recently a hook fired for the sweeper to keep its hands off, and how long is long enough to call a glyph unbacked |
| `AGT_OWN_LIVE_SECS` | 900 | how long an unfinished turn may claim to be live without a transcript write |
| `AGT_STALL_SECS` | 1500 | how long a running claim may make no progress before it reads as stuck |
| `AGT_SSH_WORK_SECS` | 120 | above this age an `ssh` is a remote run, below it a probe |
| `AGT_MACHINERY_PATTERN` | test and build commands | what the optional PreToolUse paint matches; set in `machinery-paint.sh`, not in `lights-common.sh` |
| `AGT_LIGHTS_LOG` | `sweep.log` in the state directory | where the sweeper records what it changed |

The hooks and the sweeper have to agree on `AGT_LIGHTS_STATE`, and the default is built so they cannot disagree: it hangs off `$HOME`, which is the same for both. `XDG_STATE_HOME` is deliberately not consulted, even though this is exactly the kind of file it names. The hooks run inside your shell, where an `XDG_STATE_HOME` exported from a shell rc is set; the sweeper runs from launchd, which starts with no such environment and would fall back to the default. Honoring the variable would therefore split the two halves across two directories on precisely the machines that set it, leaving the sweeper to read no stamps at all and report every live session as idle. If you do override `AGT_LIGHTS_STATE`, set it in both places, and keep it absolute.

The sweeper talks to agterm's default control socket. If yours is somewhere else, point `AGTERMCTL` at a small wrapper that adds `--socket <path>` and execs the real binary — the recipe passes no socket flag of its own.

Merge into `~/.claude/settings.json` (paths shown for the location above):

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "~/.config/agterm/truthful-lights/session-note.sh" }] }
    ],
    "UserPromptSubmit": [
      { "hooks": [
        { "type": "command", "command": "~/.config/agterm/truthful-lights/session-note.sh" },
        { "type": "command", "command": "~/.config/agterm/truthful-lights/set-status.sh active --blink" }
      ] }
    ],
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [{ "type": "command", "command": "~/.config/agterm/truthful-lights/machinery-paint.sh" }] }
    ],
    "PostToolUse": [
      { "hooks": [{ "type": "command", "command": "~/.config/agterm/truthful-lights/set-status.sh active --blink" }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "~/.config/agterm/truthful-lights/turn-end-status.sh completed --auto-reset" }] }
    ],
    "Notification": [
      { "matcher": "permission_prompt", "hooks": [{ "type": "command", "command": "~/.config/agterm/truthful-lights/set-status.sh blocked" }] }
    ]
  }
}
```

If the hooks package already wrote its own entries, **replace** them rather than adding these alongside. Leaving the stock `Stop` in place is the one mistake that breaks the recipe outright: two `Stop` entries fire on every turn, the stock one posting `completed --auto-reset` while the classifier posts what is actually running, and which of the two you end up looking at is a race. Repointing the other three events matters less but still matters — the recipe's heartbeat is written by `set-status.sh`, so an event still posting through the stock script leaves the sweeper half blind about whether this session's hooks are alive. The `PreToolUse` entry is optional; without it you see machinery only once the turn ends.

Running Help ▸ Install Agent Status Hooks… again after that re-creates the stock entries *beside* these, reopening exactly that race. The installer decides an event is already wired by looking for its own script path inside the command string, and these commands no longer contain it, so all four stock entries come back. If you re-run the installer, remove the duplicates again.

Then schedule the sweeper. Save as `~/Library/LaunchAgents/local.agterm-truthful-lights.plist`, replacing `USERNAME` with your own account:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.agterm-truthful-lights</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/USERNAME/.config/agterm/truthful-lights/status-sweep.sh</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>StartInterval</key><integer>120</integer>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
```

```sh
launchctl load ~/Library/LaunchAgents/local.agterm-truthful-lights.plist
```

That `PATH` is load-bearing, and it is the same trap `status-announcer` documents for custom commands. A LaunchAgent runs under launchd's own `PATH` — the system directories plus `/usr/local/bin`, with no `/opt/homebrew/bin` — so `agtermctl` resolves only because **Help ▸ Install Command Line Tool…** symlinks it into `/usr/local/bin`, while a Homebrew `jq` does not resolve at all. The sweeper says so in its log and exits rather than half-working; the line above is what stops it happening. Add any variable you overrode to the same dict, so the sweeper and the hooks see the same values.

To remove: `launchctl unload ~/Library/LaunchAgents/local.agterm-truthful-lights.plist` and delete the plist, delete the recipe's entries from `settings.json`, then run Help ▸ Install Agent Status Hooks… once. That last step is the same probe working in your favour: with no entry naming the stock script, the installer writes its four stock entries back, so you end up with the standard hook set instead of a session with no status at all. Then delete the state directory and the recipe directory.

## Usage

Nothing to run. Work as usual and read the row:

Start a test suite as a background tool call and end the turn — the row stays lit in the work color with the running shape instead of going green, and the sweeper turns it green within two minutes of the suite finishing. Dispatch a worker agent and end the turn — the row keeps pulsing until the worker exits. Hold a session in a lock queue and it shows the queued shape, so a row waiting for a slot is distinguishable at a glance from one burning CPU.

Green means the turn ended with nothing running, and it is posted with `--auto-reset`, so it stays on the row until you next visit that session and clears then. It is a flag you have not read yet, not a notification that times out.

Kill an agent mid-run and its row clears itself within the stale window instead of pulsing for the rest of the day. Leave a session sitting at its prompt and the glyph goes away, so no glyph reliably means nothing is happening here.

The sweeper's log records every change it made and why, and every reason it did nothing at all. It grows to two hundred lines and is then trimmed back to the last hundred, so it stays worth reading and never worth rotating. Read it when a row does something you did not expect: every branch that acts logs why it acted.

## How it works

Claude Code runs every tool command, foreground and background alike, under a recognizable wrapper: `zsh -c source …/shell-snapshots/snapshot-….sh && …`, a child of the agent process. MCP servers and harness helpers are direct children *without* that wrapper. So "is a tool still running" becomes a question about wrapper subtrees under the agent pid, and the helpers never pollute the answer. Answering it costs one `ps -axo pid=,ppid=,etime=,command=` pass and one `awk` program, with nothing watched or polled between calls; the sweeper is the part that runs on a timer.

Each wrapper subtree is classified by its leaves, and the leaves decide by shape rather than by name:

- a leaf that is another agent binary makes the subtree a worker: pulse
- `sleep`, `flock`, `pgrep`, `curl`, `date`, a short-lived `ssh` and friends make it a wait: something is queued, not executing
- `tail`, `grep` and their relatives make it a log watcher, counted apart from waits because a watcher rides along with a real run and must not make the row claim a queue
- anything else is real work
- `ssh` is disambiguated by age, not name: a reachability probe lives seconds, a remote build holds its pipe for minutes, so past `AGT_SSH_WORK_SECS` it counts as a run
- a subtree with no leaves at all is an idling loop shell, counted as a wait

Three details cost hours to find:

**The hook counts itself.** The Stop hook is itself a process under a wrapper under the agent, so the naive scan always finds work and never goes green. The caller's whole ancestor chain is excluded before anything is counted.

**Transcript mtime does not mean a turn is running.** The harness keeps appending to the transcript after a turn ends — notifications, system events — and using mtime alone held a false "still working" glyph for minutes after every turn. The recipe stamps turn boundaries instead: `UserPromptSubmit` touches a start stamp, Stop touches an end stamp, a start newer than an end means a turn is live, and the transcript is used only to cap that claim so an interrupted turn that never fired Stop cannot hold the glyph forever.

**A busy-looking subtree may only be waiting.** Before the sweeper re-lights a row as machinery it samples the subtree's summed CPU time twice, 1.5 seconds apart, and demands real movement. The turn-end classifier deliberately does not do this: at Stop the cost of a false "still running" is one extra glance, while a sweeper that re-lights on every poll loop would never let a row go quiet.

The sweeper reads `window list --json` and `tree --window --json`, and needs `statusBlink` and `statusShape` from the tree to know what a row is currently claiming, so it can leave a correct glyph alone instead of rewriting it every two minutes. Agents are discovered by scanning `ps eww` for `AGTERM_SESSION_ID`, which covers sessions that started before the hooks were installed, and pid notes are identity-checked before they are trusted, because pids get reused and the state directory outlives a reboot. Surviving a reboot is safe rather than merely tolerable: a pid note is believed only when that pid is alive, still an agent binary, *and* started at the moment the note recorded — so a pid recycled onto a different agent process is rejected rather than mistaken for the original — a heartbeat older than `AGT_HB_STALE_SECS` reads as no heartbeat, and a turn-start stamp from last week loses to any turn-end stamp after it. Stale state fails closed, so there is nothing to clean up between sessions or after a crash. The sweeper still prunes its own directory at the start of each pass, deleting state files older than a week: correctness does not need it, but a machine that opens sessions for a year should not accumulate a file per session per kind forever. The same pass collects the temporary map file a sweep killed with `SIGKILL` leaves behind before its cleanup trap can run.

Stuck detection is deliberately narrow. A row that claims to be working while the scan finds nothing running under it and the transcript has not moved for `AGT_STALL_SECS` is wedged, and gets the stuck glyph to summon you; any resumed write or turn boundary clears it on the next pass. An earlier version tried to detect this from the agent process's CPU time and it does not work — measured over seconds, a wedged agent is indistinguishable from a healthy idle one, because its runtime timers keep ticking. The transcript it stats is the `transcript_path` Claude Code puts in the hook payload, which `session-note.sh` records on the way past: a documented field handed to the hook, not a file path guessed from an internal directory layout, so this costs the recipe no dependency beyond the wrapper shape already named above.

## Limits

The sweeper writes a status for every session in every open window, so it will overwrite a glyph set by hand, by another recipe, or by a tool that pushes status for its own reasons — including clearing it to `idle` when nothing backs it. It closes nothing, kills nothing and touches no session content; the only thing it changes is the glyph. Its state lives under your home directory, readable by you rather than by everyone on the machine, and holds session ids, agent pids and the path of each session's transcript file — paths that name the directories you work in.

- **The classifier depends on an undocumented Claude Code implementation detail.** It discriminates tool subtrees by the `zsh -c source …/shell-snapshots/snapshot-….sh` wrapper Claude Code puts around every tool command. That shape is not part of any documented interface and is free to change between Claude Code versions. It was verified against Claude Code 2.1.235. If a later version drops or renames the wrapper, no subtree is ever recognized: turn-end falls back to the stock `completed --auto-reset`, and the sweeper never re-lights a row — the failure is silent and looks exactly like "nothing was running".
- **Leaves are classified by shape, so some commands are read wrong.** `rg` over a large tree is counted as a log watcher and reads as waiting although it is doing real work, and `tail -f` on a build log reads as a watcher when it is the only thing you are waiting on. A shell script that spends its time in `git`, `curl` or `jq` reads as a poll loop. The lists are in `work-scan.sh` and are meant to be edited for the commands you actually run.
- **Sub-state colors and shapes are per-call overrides, and per-call beats Settings.** While one of these statuses stands, the silhouette you configured in Settings ▸ Agent Status for that state is not what you see. Change the shape variables if that collides with your own vocabulary.
- **A worker agent spawned inside a session inherits the session's `AGTERM_*` environment**, so everything keyed by session id is written by the worker as if it were the session. Its hooks post status against the *spawner's* row; its `session-note.sh` overwrites the spawner's pid note and transcript note with its own, and stamps a turn start the spawner never took; and its `turn-end-status.sh` classifies the *worker's* process tree and paints that answer onto the spawner's row. The pid note repairs itself on the next sweep, because discovery prefers a pane-attached process, but the turn stamps and the transcript note do not — they stay wrong until the spawner's own next turn rewrites them, and in between the sweeper can read the spawner's turn as live when it is not. If you dispatch headless agents from inside a session, this is the cost. The underlying inheritance is a defect in the stock hook package, under discussion in [agterm discussion #456](https://github.com/umputun/agterm/discussions/456), not something this recipe fixes.
- **Which process the sweeper takes for a session's agent is decided by pid order.** A session is matched to an agent by scanning process environments for `AGTERM_SESSION_ID`, and a worker spawned inside the session inherits it. Workers are normally skipped because they have no controlling terminal, but one started under `script`, `expect` or `unbuffer` has one, and then two processes claim the same session. The lower pid wins, which is the pane's own agent in every ordinary case since it existed before it spawned anything; a pty-wrapped worker that somehow predates it would win instead, and the row would then be classified from the worker's process tree.
- **Stuck detection only fires when nothing is running under the agent.** A session wedged while it still holds a live tool subtree is never flagged, and a session whose dispatched workers are making progress while it makes none is deliberately not flagged either. It also depends on the transcript path from the hook payload, so a session that started before the hooks were installed is never flagged.
- **A tool subtree that neither burns CPU nor looks like a wait can read as nothing during a sweep** — an I/O-bound download or an idle-but-alive server. The turn-end classifier paints it as machinery; the sweeper, which needs CPU evidence, may leave the row dark until the next turn boundary.
- **The sweeper is only as good as the stamps in its state directory.** Sessions that were already running when you installed the recipe, or a state directory you cleared, have no turn stamps and no heartbeat, so the sweeper cannot tell "this session's own turn is producing" from "this session is sitting on a background wait" and will prefer the work glyph over the pulse until the session's next turn writes its stamps. Nothing is wrong afterwards; it is the first pass over an old session that reads oddly.
- **Non-Claude agents are recognized as workers but not analyzed.** Another agent binary found under a wrapper counts as a running worker, but a Codex or Kimi session's own tool commands do not run under this wrapper, so their sessions get no classification of their own.
- **A long-running foreground tool call and a hung one look alike** while the call is in flight: both leave a live subtree and a quiet transcript. Only the empty-subtree case is called stuck, so a wedged command is your call to make, not the sidebar's.
