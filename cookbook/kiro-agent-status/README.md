# Kiro CLI agent status

Kiro CLI sessions report active, blocked, and completed onto their sidebar row, from a shell function and the stock status script.

## What it does

Gives kiro the same per-session status glyph the installer wires up for Claude Code, Codex, Pi, and OpenCode: the row pulses active while kiro works, goes blocked while a real approval dialog is up, and flashes completed at the end of each turn, clearing when you visit the session. Turn, not session — a long `kiro-cli chat` reports every turn separately and stays quiet between them.

Kiro is the one agent that cannot get there through hooks. It declares hooks per agent inside each `~/.kiro/agents/<name>.json` with no global file, so a merge covers one agent and is overwritten by whatever manages the rest of them — and its only pre-tool event fires with the same payload whether a tool was auto-approved or is waiting on you, so nothing in its hook surface distinguishes blocked from ordinary work.

So this recipe drives the glyph from the shell instead. It defines `kiro-cli` (and `kiro`) as a shell function that shadows the real command. The function starts a small poller in the background, runs the real kiro-cli in the foreground, and kills the poller and clears the row the moment that foreground command returns — for any reason, a normal exit, a crash, or a Ctrl-C, since that is how job control already works and needed no code of its own. The poller reads the pane's own recent text through `agtermctl session text` and reports each state from what kiro is actually drawing: active while its working footer is up, blocked while the approval dialog is up, completed when a turn's markers are gone.

## Requirements

- agterm 0.5.0 or later, with the hooks package installed via Help ▸ Install Agent Status Hooks… (that provides `~/.config/agterm/agent-status/agterm-agent-status.sh`, which this recipe calls). `session text` shipped in 0.5.0 already accepting the `--pane left|right` this recipe reads with; only the later `--pane scratch` value, which this recipe does not use, needed 0.7.0.
- `agtermctl` reachable for the *read* side. The hooks package covers the status writes on its own — the installer bakes an absolute CLI path into the script it writes — but it does not export that path, and this recipe also reads the pane. So either run Help ▸ Install Command Line Tool…, or `export AGTERMCTL=/path/to/agterm.app/Contents/MacOS/agtermctl`. Failing both, the recipe looks for agterm.app in `~/Applications` and `/Applications` before giving up.
- Kiro CLI (tested on kiro-cli 2.16.1). No kiro-side setup: nothing is written to any kiro config.
- zsh, bash, or fish.

## Setup

Run Help ▸ Install Agent Status Hooks… once if you have not already (it is idempotent). Nothing else in that package is involved — this recipe owns kiro's whole lifecycle and only borrows `agterm-agent-status.sh`. Also run Help ▸ Install Command Line Tool… unless `agtermctl` is already on your `PATH`, since the read side needs it by name; see Requirements for the `AGTERMCTL` alternative.

### zsh or bash

```sh
mkdir -p ~/.config/agterm/kiro-agent-status
cp kiro-agent-status.zsh kiro-status-detector.sh ~/.config/agterm/kiro-agent-status/
```

then add to `~/.zshrc` or `~/.bashrc`:

```sh
source ~/.config/agterm/kiro-agent-status/kiro-agent-status.zsh
```

### fish

```sh
mkdir -p ~/.config/agterm/kiro-agent-status
cp kiro-agent-status.fish kiro-status-detector.sh ~/.config/agterm/kiro-agent-status/
```

then add to `~/.config/fish/config.fish`:

```fish
source ~/.config/agterm/kiro-agent-status/kiro-agent-status.fish
```

Either way, open a new shell for it to take effect. To remove it, delete the `source` line (or the copied files) — kiro-cli and kiro go back to being the real binaries the moment the function is gone.

Do **not** also add `kiro` to `AGTERM_AGENT_RE` in the shipped `shell/integration.sh`/`.fish`. That integration reports active when the command starts and idle at the next prompt — which, for a REPL, means one active pinned across the entire chat session, exactly the between-turns pulsing this recipe exists to avoid. The two are alternatives, not layers. The shipped default does not list kiro, so out of the box there is nothing to undo.

## Usage

Run `kiro-cli chat` (or `kiro`) inside agterm as usual — an alias or abbreviation that expands to one of those also works, since the function intercepts by name, not by what you typed. The row pulses active while kiro works, goes blocked while its approval dialog is up, returns to active when you answer, and flashes completed at the end of **each turn**, not just when you leave the session. A chat you open and do not prompt reports nothing at all.

Override the detection strings before sourcing if a kiro release renames its working footer or approval dialog:

```sh
export KIRO_STATUS_APPROVAL_RE='requires approval'
export KIRO_STATUS_APPROVAL_OPTION_RE='yes, single permission|trust, always allow|no \(tab to edit\)|esc to close'
export KIRO_STATUS_WORKING_RE='kiro is working|esc to cancel'
export KIRO_STATUS_INTERVAL=0.5              # poll interval, seconds
export KIRO_STATUS_TAIL_LINES=12             # how many lines of the pane to match against
export KIRO_STATUS_MAX_READ_FAILURES=10      # consecutive failed pane reads before giving up
export KIRO_STATUS_DONE_FRAMES=3             # marker-free frames before a turn counts as finished
```

(`set -gx` instead of `export` in fish.)

## How it works

**If you only want to know whether kiro is running, you do not need this recipe.** The shipped hooks package already includes a generic shell integration that reports active and idle off an overridable command regex, and adding kiro to it is one environment variable:

```sh
export AGTERM_AGENT_RE='^(gemini|cursor-agent|aider|crush|goose|kiro|kiro-cli)([[:space:]]|$)'
```

That is no code and no poller — but for `kiro-cli chat` it reports one active for the whole session, since it keys off the command starting and the next shell prompt arriving, neither of which happens per turn. This recipe's delta is everything that needs turn granularity: **blocked** while kiro's approval dialog is up, **completed** at the end of each turn, and an active that stops pulsing in between. The two are alternatives rather than layers — see the note in Setup.

Kiro exposes exactly five hook events (`agentSpawn`, `userPromptSubmit`, `preToolUse`, `postToolUse`, `stop` — verified with `kiro-cli agent validate`, which rejects anything else) and none of them is a permission event. `preToolUse` fires identically whether a tool needed you or not, so there is nothing to wire that would not false-flag on every trusted tool call.

`kiro-cli`/`kiro` are shell functions rather than a preexec hook matching the typed command line, on purpose: `preexec` sees the literal text you typed, before your shell expands an alias or abbreviation, so a preexec-regex approach silently misses `alis` even when `alis` expands to `kiro-cli ...`. A function is looked up *after* alias/abbreviation expansion, so it catches both the bare command and anything that expands to it.

**Every status comes from the poller, not the wrapper**, because `kiro-cli chat` is a REPL. The wrapper function spans the whole *session*, while the states worth showing belong to a *turn*, which ends when kiro returns to its prompt with the process still running. A wrapper that reported active on entry would leave the row pulsing between turns — and for a chat you opened and never prompted. So the function's only status write is a plain `idle` after kiro-cli exits, clearing the row rather than leaving a `completed` that would outlive the session it described. It cannot delegate that one to the poller, which it kills a line earlier — and it waits one poll interval first, because killing the poller does not cancel a status write it had *already* spawned, and that grandchild would otherwise land after the `idle` and leave the row advertising a turn that is over.

What the function does own is the poller's lifetime, and it needs no stop-condition logic of its own: a foreground job returning (normally, killed, or crashed) is exactly what shell job control already guarantees. That also means a poller cannot outlive its kiro-cli through any path the wrapper itself survives, unlike a background process started from `preexec` and torn down from a separate `precmd`.

`kiro-status-detector.sh` is the poller, invoked with no arguments and reading `$AGTERM_SESSION_ID`/`$AGTERM_PANE` from its environment. It reads the pane's last `KIRO_STATUS_TAIL_LINES` lines (12 by default), lowercased, and sorts them into three states: blocked (the approval anchor **plus** one of its option lines), active (the working footer), or neither. Approval needs both strings because the anchor alone appears in any buffer that merely prints the phrase — a diff, a log, this file in a pager — and would flip the row amber for it.

Both matches are **anchored to the line**, not searched as substrings, because kiro talking *about* its own UI is not kiro *running*. Ask kiro about this recipe and its answer quotes "kiro is working" mid-sentence; the footer it draws for real occupies a line of its own, preceded by nothing but indentation, a spinner glyph, or the cursor. So the working and option patterns require `^[^[:alpha:]]*` in front, and the approval anchor — which *ends* its line but begins with a tool name — requires only trailing whitespace behind it. Without that, a chat that discusses the markers pins the row blinking for as long as the text stays on screen, and can raise a blocked the user never has to answer.

It reports only on a state *change*: re-asserting blocked every tick would defeat `--auto-reset` and re-fire the configured blocked sound, and re-asserting active would fight a status you already cleared by typing into the session. Its last-reported state starts at `idle`, so a chat sitting at an empty prompt is never announced; the flip into "neither" only reports completed if something was actually running, which is what keeps a finished turn's output on screen from looking like work.

A state counts as reported only once the write *succeeded*, so a failed one is retried on the next tick rather than remembered as delivered. That matters most for blocked: believed sent but never drawn, it sits wrong on the row until some later transition happens to repair it. Only a missing status script is detectable — the stock one ends in `|| true; exit 0` so a hook can never break a turn — and retrying while the classification still holds costs one extra call and needs no read-back.

That flip is also **debounced** over `KIRO_STATUS_DONE_FRAMES` frames (3 by default), because a single marker-free frame does not mean the turn ended. Kiro's screen goes briefly clear of both markers *within* a turn — between two tool calls, and in the frame after you answer an approval but before the working footer returns — and treating either as the end would fire the finish sound and drop the blink mid-turn, then start pulsing again a moment later. Any working or approval frame resets the counter, so only a screen that stays quiet ends the turn. So does a *failed* read: the screen it would have shown may well have held the working footer, and counting an unseen frame toward the streak would let interleaved failures fake a finished turn.

Statuses go through the stock `agterm-agent-status.sh`, which forwards `AGTERM_PANE` and `AGTERM_PANE_ID` from the environment for us.

It passes `--pane "$AGTERM_PANE"` on the read: `session text` with no `--pane` reads whatever is currently on screen (the focused pane, or an open scratch terminal covering it), which is not necessarily the pane kiro-cli is running in. It passes no `--pane` on the write, because the stock status script already forwards both the role and `AGTERM_PANE_ID`, and that token is what lets agterm correct a stale role after a pane is promoted.

It has two stop conditions and no check budget, because `kiro-cli chat` can sit at a prompt all day and a capped loop would stop reporting partway through a session that is still going. It exits when the shell that started it dies (`kill -0 $PPID`), which covers both normal teardown and a hard-killed app — the pty takes the shell down with it, so the poller goes too. It also exits after `KIRO_STATUS_MAX_READ_FAILURES` consecutive failed pane reads (default 10), since no app means no socket; one failure is treated as transient and resets on the next success, so a busy socket does not end the poll. Neither path normally runs: the wrapper kills the poller as soon as kiro-cli returns.

A poller that dies mid-turn cannot strand a pulsing row for long: the wrapper's `idle` still clears it when kiro-cli exits. Within the session it would stop updating, which is why the poller's own stop conditions are the two above and not a check budget.

Leaving blocked happens on either exit from the dialog. Answering yes brings the working footer back, which reports active; answering no returns kiro straight to its prompt with no footer in between, and that path reports completed, because leaving it blocked would keep the row demanding attention it no longer needs — a false blocked is the one wrong state that actively summons you to a session that does not need you.

## Limits

Nothing destructive: the poller only posts status for its own session, the same as any other status hook.

- Interactive only. Kiro's approval dialog renders on a tty; under `--no-interactive` kiro refuses the tool outright instead, and there is no human for the row to signal.
- One stuck-glyph path remains, and it is inherent: if the *shell* is killed outright while kiro-cli is running, the wrapper never reaches its `idle`, so the row keeps whatever the poller last set — usually a pulsing active. Nothing in the recipe can correct it, since both processes that would have done so are gone. Setting any status in that session clears it; so does quitting agterm, because status is not restored across launches.
- Completed lands about a second and a half after the turn actually ends, from `KIRO_STATUS_DONE_FRAMES` times `KIRO_STATUS_INTERVAL`. That delay is deliberate — it is what stops a mid-turn lull from reading as the end — and it is the wrong knob to shrink to 1 unless you want the flicker back. Blocked and active are not debounced and appear on the next tick.
- The detection strings match literal UI text, so a kiro release that renames its working footer or approval dialog breaks the states that depend on it until the overrides above are updated. Nothing false appears in that case — the row simply stops reporting — and the wrapper's `idle` still clears it when the session ends.
- Two `kiro-cli`/`kiro` runs at once in the same session (a split's two panes, or a split pane plus main) share one `AGTERM_SESSION_ID`, so both write to the same row. Whichever reported last wins; this recipe does not try to arbitrate between them.
- `AGTERM_PANE` is set once when the shell starts and can go stale: if a split's other pane exits and this one is promoted to the main pane, the shell still reports its original role until you open a new one. The status writes survive that, because the stock script also forwards `AGTERM_PANE_ID` and agterm resolves the current slot from it; the poller's *read* does not, so on a promoted pane `session text --pane right` fails and blocked detection quietly stops working (the reads return nothing, which reads as "nothing to report") until a new shell picks up the corrected role.
- CI here only lints `.sh` and `.zsh` files (`shellcheck` and `zsh -n`); `kiro-agent-status.fish` gets no automated check, only manual `fish -n` and hand testing.
