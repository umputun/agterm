# Kiro CLI agent status

Kiro CLI sessions report active, blocked, and completed onto their sidebar row, from a shell function and the stock status script.

## What it does

Gives kiro the same per-session status glyph the installer wires up for Claude Code, Codex, Pi, and OpenCode: the row pulses active while kiro works, goes blocked while a real approval dialog is up, and flashes completed at the end of each turn, clearing when you visit the session. Turn, not session — a long `kiro-cli chat` reports every turn separately and stays quiet between them.

Kiro is the one agent that cannot get there through hooks. It declares hooks per agent inside each `~/.kiro/agents/<name>.json` with no global file, so a merge covers one agent and is overwritten by whatever manages the rest of them — and its only pre-tool event fires with the same payload whether a tool was auto-approved or is waiting on you, so nothing in its hook surface distinguishes blocked from ordinary work.

So this recipe drives the glyph from the shell instead. It defines `kiro-cli` (and `kiro`) as a shell function that shadows the real command. The function starts a small poller in the background, runs the real kiro-cli in the foreground, and kills the poller and clears the row the moment that foreground command returns — a normal exit or a crash alike, since that is how job control already works and needed no code of its own. The poller reads the pane's own recent text through `agtermctl session text` and reports each state from what kiro is actually drawing: active while its working footer is up, blocked while the approval dialog is up, completed when a turn's markers are gone.

## Requirements

- agterm 0.7.1 or later, with the hooks package installed via Help ▸ Install Agent Status Hooks… (that provides `~/.config/agterm/agent-status/agterm-agent-status.sh`, which this recipe calls). 0.7.1 is where `AGTERM_PANE` starts being injected into the session environment (#130); the poller forwards it verbatim, so on anything earlier it falls back to `left` and cannot read a kiro running in a right split. `--pane scratch` is part of that too — a kiro started in a scratch terminal sends it, and it needs 0.7.0 (#117).
- `agtermctl` reachable for the *read* side. The hooks package covers the status writes on its own — the installer bakes an absolute CLI path into the script it writes — but it does not export that path, and this recipe also reads the pane. So either run Help ▸ Install Command Line Tool…, or `export AGTERMCTL=/path/to/agterm.app/Contents/MacOS/agtermctl`. Failing both, the recipe looks for agterm.app in `~/Applications` and `/Applications` before giving up.
- Kiro CLI (tested on kiro-cli 2.16.1). No kiro-side setup: nothing is written to any kiro config.
- zsh, bash, or fish.

## Setup

Run Help ▸ Install Agent Status Hooks… once if you have not already (it is idempotent). Nothing else in that package is involved — this recipe owns kiro's whole lifecycle and only borrows `agterm-agent-status.sh`. Also run Help ▸ Install Command Line Tool… unless `agtermctl` is already on your `PATH`, since the read side needs it by name; see Requirements for the `AGTERMCTL` alternative.

### zsh or bash

```sh
mkdir -p ~/.config/agterm/kiro-agent-status
cp kiro-agent-status.zsh kiro-status-detector.sh ~/.config/agterm/kiro-agent-status/
chmod +x ~/.config/agterm/kiro-agent-status/kiro-status-detector.sh
```

then add to `~/.zshrc` or `~/.bashrc`:

```sh
source ~/.config/agterm/kiro-agent-status/kiro-agent-status.zsh
```

### fish

```sh
mkdir -p ~/.config/agterm/kiro-agent-status
cp kiro-agent-status.fish kiro-status-detector.sh ~/.config/agterm/kiro-agent-status/
chmod +x ~/.config/agterm/kiro-agent-status/kiro-status-detector.sh
```

then add to `~/.config/fish/config.fish`:

```fish
source ~/.config/agterm/kiro-agent-status/kiro-agent-status.fish
```

Either way, open a new shell for it to take effect. To remove it, delete the `source` line (or the copied files) — kiro-cli and kiro go back to being the real binaries the moment the function is gone.

The `chmod +x` is belt and braces: `cp` carries the bit over, but a copy that arrived by download, archive, or clipboard may not have had it to carry. If it is missing, the wrapper says so once per shell rather than silently reporting nothing.

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

It checks the poller is executable before launching it, which is worth more than it looks in fish: fish leaves `$last_pid` pointing at the *previous* background job when a launch fails, so an unreadable poller would have the wrapper kill some unrelated job of yours on the way out. (bash and zsh fork a child that fails to exec, so their `$!` is a fresh already-dead pid and the kill is harmless.) It also turns a silent no-op into one warning per shell.

Teardown confirms the pid is still the poller before signalling it, for the same reason from the other direction. The poller has stop conditions of its own, so it can exit long before kiro-cli does — five seconds of failed reads is enough — and the shell reaps it, which releases the number for reuse. A blind `kill` on a remembered pid would signal whatever inherited it, so the wrapper checks the process's own argv first and skips the kill if it no longer matches.

What the function does own is the poller's lifetime, and for a foreground job that returns — normally or by crashing — it needs no stop-condition logic of its own, since that is what shell job control already guarantees. Unlike a background process started from `preexec` and torn down from a separate `precmd`, the teardown cannot be skipped by the shell taking some other path to the next prompt. The exception is a signal that reaches the whole foreground group: a terminal SIGINT aborts the rest of the function body along with kiro-cli, so neither the `kill` nor the `idle` runs (see Limits).

`kiro-status-detector.sh` is the poller, invoked with no arguments and reading `$AGTERM_SESSION_ID`/`$AGTERM_PANE` from its environment. It reads the pane's last `KIRO_STATUS_TAIL_LINES` lines (12 by default), lowercased, and sorts them into three states: blocked (the approval anchor **plus** one of its option lines), active (the working footer), or neither. Approval needs both strings because the anchor alone appears in any buffer that merely prints the phrase — a diff, a log, this file in a pager — and would flip the row amber for it. Both strings on screen at once is much rarer, though not impossible; see the note on what the anchors do and do not exclude, below.

Both matches are **anchored to the line**, not searched as substrings, because kiro talking *about* its own UI is not kiro *running*. Ask kiro about this recipe and its answer quotes "kiro is working" mid-sentence; the footer it draws for real occupies a line of its own, preceded by nothing but indentation, a spinner glyph, or the cursor. So the working and option patterns require `^[^[:alpha:]]*` in front, and the approval anchor — which *ends* its line but begins with a tool name — requires only trailing whitespace behind it. Without that, a chat that discusses the markers pins the row blinking for as long as the text stays on screen.

That narrows the false positives; it does not eliminate them, and it is worth knowing which ones survive. A leading run of non-letters passes any bullet, quote, diff marker or line number, so a blockquoted `> Kiro is working` reads as working. The two-string rule for blocked is likewise a higher bar rather than a closed door: the two patterns scan the same 12 lines independently, so they need not describe the same line, let alone a real dialog. `- Shell requires approval` and `- Yes, single permission is one option` on separate lines raise a blocked with no dialog up, and so does the single line `> Yes, single permission -- shell requires approval`. Tightening further trades these for false *negatives* on the real dialog, which is the worse failure — a row that stops reporting is less use than one that occasionally over-reports — so the recipe accepts them. Setting any status in the session clears a stale one.

It reports only on a state *change*: re-asserting blocked every tick would defeat `--auto-reset` and re-fire the configured blocked sound, and re-asserting active would fight a status you already cleared by typing into the session. Its last-reported state starts at `idle`, so a chat sitting at an empty prompt is never announced; the flip into "neither" only reports completed if something was actually running, which is what keeps a finished turn's output on screen from looking like work.

A state counts as reported only once the write *succeeded*, so a failed one is retried on the next tick rather than remembered as delivered. That matters most for blocked: believed sent but never drawn, it sits wrong on the row until some later transition happens to repair it. Only a missing status script is detectable — the stock one ends in `|| true; exit 0` so a hook can never break a turn — and retrying while the classification still holds costs one extra call and needs no read-back.

That flip is also **debounced** over `KIRO_STATUS_DONE_FRAMES` frames (3 by default), because a single marker-free frame does not mean the turn ended. Kiro's screen goes briefly clear of both markers *within* a turn — between two tool calls, and in the frame after you answer an approval but before the working footer returns — and treating either as the end would fire the finish sound and drop the blink mid-turn, then start pulsing again a moment later. Any working or approval frame resets the counter, so only a screen that stays quiet ends the turn. So does a *failed* read: the screen it would have shown may well have held the working footer, and counting an unseen frame toward the streak would let interleaved failures fake a finished turn.

Statuses go through the stock `agterm-agent-status.sh`, which forwards `AGTERM_PANE` and, on 0.13.0 and later, `AGTERM_PANE_ID` from the environment for us.

It passes `--pane "$AGTERM_PANE"` on the read: `session text` with no `--pane` reads whatever is currently on screen (the focused pane, or an open scratch terminal covering it), which is not necessarily the pane kiro-cli is running in. It passes no `--pane` on the write, because the stock status script already forwards both the role and — from 0.13.0 (#213) — `AGTERM_PANE_ID`, the token that lets agterm correct a stale role after a pane is promoted. Before 0.13.0 the write carries the role alone, so a promoted pane's status lands on the role it started with.

It has two stop conditions and no check budget, because `kiro-cli chat` can sit at a prompt all day and a capped loop would stop reporting partway through a session that is still going. It exits when the shell that started it dies (`kill -0 $PPID`), which covers ordinary teardown. It also exits after `KIRO_STATUS_MAX_READ_FAILURES` consecutive failed pane reads (default 10), since no app means no socket; one failure is treated as transient and resets on the next success, so a busy socket does not end the poll. That second condition is what covers a hard-killed app: no teardown runs, and no SIGHUP reaches the poller because the pty's session leader is the surviving `login`, so the shell can outlive the app and the `$PPID` check alone would not notice. Neither path normally runs: the wrapper kills the poller as soon as kiro-cli returns.

A poller that dies mid-turn cannot strand a pulsing row for long: the wrapper's `idle` still clears it when kiro-cli exits. Within the session it would stop updating, which is why the poller's own stop conditions are the two above and not a check budget.

Leaving blocked happens on either exit from the dialog. Answering yes brings the working footer back, which reports active; answering no returns kiro straight to its prompt with no footer in between, and that path reports completed, because leaving it blocked would keep the row demanding attention it no longer needs — a false blocked is the one wrong state that actively summons you to a session that does not need you.

## Limits

Nothing destructive: the poller only posts status for its own session, the same as any other status hook, and the one signal the recipe sends — the wrapper's `kill` of its own poller — is checked against the target's argv first, so a reused pid is not signalled.

- Interactive only. Kiro's approval dialog renders on a tty; under `--no-interactive` kiro refuses the tool outright instead, and there is no human for the row to signal.
- One stuck-glyph path remains, and it is inherent: if the *shell* is killed outright while kiro-cli is running, the wrapper never reaches its `idle`, so the row keeps whatever the poller last set — usually a pulsing active. Nothing in the recipe can correct it, since both processes that would have done so are gone. Setting any status in that session clears it; so does quitting agterm, because status is not restored across launches.
- A Ctrl-C that reaches the shell leaves the poller behind. The SIGINT goes to the whole foreground process group, so it aborts the rest of the wrapper function along with kiro-cli: neither the `kill` nor the closing `idle` runs, and the disowned poller keeps polling — and reporting — for the life of that shell. Rare in practice, because kiro-cli holds the terminal in raw mode and handles Ctrl-C itself rather than letting it through, but it is reachable, and whether it bites depends on your shell and its version. Exiting the shell ends it; a `kill` on the leftover `kiro-status-detector.sh` ends it sooner.
- Completed lands about a second and a half after the turn actually ends, from `KIRO_STATUS_DONE_FRAMES` times `KIRO_STATUS_INTERVAL`. That delay is deliberate — it is what stops a mid-turn lull from reading as the end — and it is the wrong knob to shrink to 1 unless you want the flicker back. Blocked and active are not debounced and appear on the next tick.
- Text *about* the markers can be mistaken for the markers, since detection is a screen scrape. Line anchoring rejects the common case — kiro quoting a phrase mid-sentence — but not a bulleted or blockquoted copy of one, and not a screen that happens to hold the approval phrase and one option phrase on separate lines. The row then reports active or blocked with nothing running, for as long as that text stays on screen. Setting any status in the session clears it. The alternative, tightening the patterns until only a pixel-exact dialog matches, trades this for a row that silently stops reporting after any kiro UI tweak.
- The detection strings match literal UI text, so a kiro release that renames its working footer or approval dialog breaks the states that depend on it until the overrides above are updated. Nothing false appears in that case — the row simply stops reporting — and the wrapper's `idle` still clears it when the session ends.
- Two `kiro-cli`/`kiro` runs at once in the same session (a split's two panes, or a split pane plus main) share one `AGTERM_SESSION_ID`, so both write to the same row. Whichever reported last wins; this recipe does not try to arbitrate between them.
- `AGTERM_PANE` is set once when the shell starts and can go stale: if a split's other pane exits and this one is promoted to the main pane, the shell still reports its original role until you open a new one. Status *writes* survive that on 0.13.0 and later, since the stock script also forwards `AGTERM_PANE_ID` and agterm resolves the current slot from it. The *read* does not: `session text --pane right` with no split answers `ok: false` and exits nonzero, so every poll fails outright. A failed read is not a quiet frame, so nothing gets reported either way, and after `KIRO_STATUS_MAX_READ_FAILURES` of them — about five seconds — the poller gives up and exits. Whatever it last set then stays on the row, a pulsing active or a blocked, until you leave kiro-cli and the wrapper's `idle` clears it.
- CI lints `.sh`, `.zsh`, and `.py` files (`shellcheck`, `zsh -n`, `ruff`), but has no `.fish` step, so `kiro-agent-status.fish` gets no automated check — only manual `fish -n` and hand testing.
