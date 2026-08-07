# Kimi Code per-tab session resume

After a restart each tab reopens its own Kimi Code conversation instead of a fresh one.

## What it does

Same idea as the other session-resume recipes: each tab reopens its own conversation after a restart.

The mechanism differs from all of them. Kimi Code has lifecycle hooks of its own (`[[hooks]]` in `~/.kimi-code/config.toml`), and its SessionStart hook receives the new conversation's `session_id` on stdin — so instead of a shell function wrapping the launch, a hook script pins the tab's restore command directly with `agtermctl session restore "kimi -r <id>"`. No mapping file, no wrapper: the pin is rewritten on every kimi start, so it always points at the tab's current conversation, and `kimi` itself is never shadowed.

The hook also carries the `-m` model flag of the running kimi process into the pinned command, so a session launched against a specific model route resumes on the same one. The pinned line is shell code, so a model name outside a safe character set is dropped rather than quoted in.

## Requirements

- agterm 0.16.0 or later (`session restore` with `--pane-id` and the sticky per-pane override shipped in 0.16.0), with **Restore running commands on restart** turned on under Settings ▸ General ▸ Sessions.
- Kimi Code with `[[hooks]]` support in `~/.kimi-code/config.toml` (SessionStart event delivering JSON on stdin; tested on kimi-code 0.31.0).
- `python3` (ships with macOS command line tools) for the one-line JSON read.

## Setup

Copy the script somewhere stable and make it executable:

```sh
mkdir -p ~/bin
cp kimi-pin-resume.sh ~/bin/
chmod +x ~/bin/kimi-pin-resume.sh
```

Add the hook to `~/.kimi-code/config.toml`:

```toml
[[hooks]]
event = "SessionStart"
command = "$HOME/bin/kimi-pin-resume.sh"
```

Turn on **Restore running commands on restart** in Settings ▸ General, under Sessions.

To remove it, delete the `[[hooks]]` block and the script.

## Usage

Run `kimi` the way you always do. Every start (and every resume) re-pins the tab to that conversation; after agterm restarts, the tab relaunches `kimi -r <that conversation>`.

To detach a tab from its conversation, run `agtermctl session restore --clear` in it, or just start a new `kimi` — the pin follows the newest start.

## How it works

Kimi's SessionStart hook fires with `{"session_id": "session_…", …}` on stdin inside the session's shell environment, where agterm's `AGTERM_SESSION_ID`, `AGTERM_PANE_ID`, and `AGTERM_SOCKET` are already exported. The script reads the id, walks up the process tree to find the owning `kimi` process and lift its `-m` flag, and writes the pane's restore override over the control socket. agterm consumes the override on the next launch — it never touches the running session.

The gotcha that matters in agent setups: a kimi run spawned *by* another agent (a Claude Code session driving kimi as a worker) fires the same hook in the same pane, and would steal the pane's pin from the conversation that actually owns it. The script detects that case via `CLAUDE_CODE_SESSION_ID` in the environment and skips the pin.

## Limits

Nothing destructive: the script only writes a restore override; it never closes sessions or touches kimi state.

- The pin is sticky and follows the *newest* kimi start in the tab. If you run a quick throwaway `kimi -p "…"` in a tab that hosts a long-lived conversation, the throwaway becomes the pin. Restart kimi on the conversation you care about (or `session restore --clear`) to fix it.
- The restore override is one slot per pane, shared with anything else that sets one — a pin you set by hand in that tab is overwritten on the next kimi start.
- Inside the scratch terminal the hook is a silent no-op: the scratch terminal is never restored, and `session restore` rejects its pane id.
- The child-session guard only knows Claude Code (`CLAUDE_CODE_SESSION_ID`). A kimi worker spawned by some other orchestrator will still take the pin.
- The pinned command is stored in the window's state file in plain text, like every restore override; it carries only the session id and model name.
