# Container agent status

Report a Claude Code (or any hook-driven agent) session's status onto its sidebar row when that agent runs inside a container instead of on the host.

## What it does

The installer's `Help ▸ Install Agent Status Hooks…` wires an agent's lifecycle hooks straight to `agtermctl` over the local control socket, which only works when the agent and agterm share an OS — the socket does not exist inside a Linux container. This recipe replaces that one hop with two: a small script inside the container turns each hook event into a JSON line and sends it over TCP to the host, and a listener on the host turns each line back into the same `agtermctl session status` call the installer's hooks would have made directly. The row pulses active while the agent works, goes blocked on a real permission prompt, and flashes completed at the end of a turn — the same behavior as a native session, one network hop removed.

## Requirements

- agterm 0.7.1 or later — `AGTERM_PANE` starts being injected into the session environment in that release (#130), which this recipe forwards so the row updates on the pane the container's shell actually runs in.
- `nc` (netcat) on both the host and inside the container.
- A container runtime that can pass environment variables through to the container (Docker, Podman, Apple's `container`, etc.) and reach the host over TCP — a bridge network or `host.containers.internal`-style hostname is enough; no port needs to be published to the outside world.
- Claude Code (tested) or another agent with the same four hook events used by `Help ▸ Install Agent Status Hooks…` — see that installer's hooks for the exact event/state pairing this recipe mirrors.

Tested end to end on macOS with Apple's own `container` CLI (`container machine run`, not Docker) running a Linux Claude Code container — see the Apple `container` note under Setup for what that runtime gets you for free.

## Setup

Variables used below: `HOST_IP` is the host's address as seen from inside the container, and `PORT` is the TCP port the two scripts agree on (9998 in the examples).

### On the host

```sh
mkdir -p ~/bin
cp agterm-remote-receiver.sh ~/bin/
chmod +x ~/bin/agterm-remote-receiver.sh

~/bin/agterm-remote-receiver.sh --port PORT --log-file ~/Library/Logs/agterm-remote.log &
```

`--socket` defaults to `$HOME/Library/Application Support/agterm/agterm.sock`; pass it explicitly if agterm's socket lives somewhere else. This process has to be running whenever you want statuses to show — it is a plain background job here, not a launchd service, so it does not survive a reboot or logout on its own; wrap it in a LaunchAgent if you want that.

### Passing identity into the container

Whatever starts the container needs to forward the session's own `AGTERM_*` variables plus where to send status. `AGTERM_SESSION_ID`, `AGTERM_WINDOW_ID`, `AGTERM_WORKSPACE_ID`, and `AGTERM_PANE` are already exported by agterm into any shell it spawns on the host — a session that opens a Claude Code pane runs that shell with these already set, so a wrapper function only has to pass them through; only `AGTERM_REMOTE_HOST` is new, and it is what tells the container script to use this recipe's TCP path instead of a control socket it does not have.

For example, a `claude` shell function that launches an Apple `container machine` container running Claude Code, with the current session's identity forwarded in (replace `CONTAINER_CLAUDE_BIN_DIR` with wherever the container image installs the `claude` binary, and `HOST_IP:PORT` with the receiver's address):

```sh
claude() {
  container machine run -it \
    -e PATH="CONTAINER_CLAUDE_BIN_DIR:$PATH" \
    -e AGTERM_SESSION_ID="${AGTERM_SESSION_ID:-}" \
    -e AGTERM_WINDOW_ID="${AGTERM_WINDOW_ID:-}" \
    -e AGTERM_WORKSPACE_ID="${AGTERM_WORKSPACE_ID:-}" \
    -e AGTERM_PANE="${AGTERM_PANE:-}" \
    -e AGTERM_REMOTE_HOST="${AGTERM_REMOTE_HOST:-HOST_IP:PORT}" \
    claude
}
```

Set `AGTERM_REMOTE_HOST` once in the shell that runs this function (e.g. in `~/.zshrc`, above the function) rather than hardcoding it here, so the same function keeps working if the receiver's port ever changes. The same `-e NAME="${NAME:-}"` shape works for any container runtime with an env-passthrough flag (Docker's and Podman's `-e NAME=$NAME` do the same thing).

#### A note on Apple's `container` runtime

This was built and tested against Apple's own `container` CLI, not Docker — and two things about how it handles networking are what make this recipe simpler than it would be otherwise. First, a container started with `container machine run` already has outbound access to every port on the host by default; nothing has to be published or bridged for the container's `nc` to reach the receiver listening on the host. Second, the reverse direction — the host seeing the container as if it were another local process — needs no container recreation or restart: if the container itself ever opens a listening port, the host can already reach it without any `-p`/`--publish` step or container rebuild. Neither of these is guaranteed on other runtimes; Docker and Podman need an explicit network mode or `--add-host`/`host.docker.internal` for the container→host leg this recipe relies on.

### Inside the container

```sh
mkdir -p ~/.config/agterm/agent-status
cp container-status-notify.sh ~/.config/agterm/agent-status/
chmod +x ~/.config/agterm/agent-status/container-status-notify.sh
```

Merge these four hooks into `~/.claude/settings.json` inside the container (the same event/state pairing the installer uses natively, pointed at this recipe's script instead):

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "~/.config/agterm/agent-status/container-status-notify.sh active --blink" }] }
    ],
    "PostToolUse": [
      { "hooks": [{ "type": "command", "command": "~/.config/agterm/agent-status/container-status-notify.sh active --blink" }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "~/.config/agterm/agent-status/container-status-notify.sh completed --auto-reset" }] }
    ],
    "Notification": [
      { "matcher": "permission_prompt", "hooks": [{ "type": "command", "command": "~/.config/agterm/agent-status/container-status-notify.sh blocked" }] }
    ]
  }
}
```

## Usage

Start Claude Code inside the container as usual. The row goes active (pulsing) on your prompt, re-asserts active on every tool call — which is what returns it from blocked to active after you answer a permission prompt, since Claude Code has no "permission answered" event of its own — goes blocked while a permission dialog is up, and flashes completed with `--auto-reset` at the end of a turn, clearing when you visit the session.

## How it works

`container-status-notify.sh` builds the same flat JSON shape a native install's control-socket call would carry (`cmd`, `state`, `session_id`, optionally `pane`, plus any extra flags as an `args` array) and writes it as one line to `nc "$remote_host" "$remote_port"` with a two-second timeout, then always exits 0 — a hook that blocks the agent's turn on a network hiccup is worse than a missed status update. `agterm-remote-receiver.sh` on the host runs `nc -l` in a loop (one TCP connection per event; the loop is there because each event closes its connection), greps the four fields it needs out of the JSON without a `jq` dependency, and calls `agtermctl session status <state> --target <session_id> [--pane <pane>] --socket <path>` — precisely the call the installer's own hooks make, just issued from the host instead of from inside the container.

The gotcha: the two scripts' JSON shape has to agree exactly, because the receiver's parser only recognizes `"cmd":"session-status"` and silently drops anything else — a mismatched or nested payload (e.g. wrapping the state in a nested `args` object) produces no error, no status, and no clue why, since the container side reports success as soon as `nc` delivers the bytes.

## Limits

Nothing destructive: this only posts status for the container's own session, the same as a native install.

- `agterm-remote-receiver.sh` trusts anything that reaches its port — any process able to open a TCP connection to the host can post an arbitrary status for any `session_id`. Fine on a private bridge network between a host and its own container; do not expose the port beyond that.
- The receiver is a foreground loop started by hand in the example above; if it dies (host sleep, terminal closed, crash) statuses silently stop arriving and the sidebar row freezes at its last state until you notice and restart it.
- `nc -l` handles one connection at a time; two events that land in the same instant can race, and the loop briefly drops connections while it restarts between them. In practice this only shows up as a very rare missed event, never a wrong one — the JSON stays a single complete line per connection.
- Like the kimi recipe's `PermissionRequest`, this depends on the agent's own hook firing exactly when — and only when — a real approval prompt is on screen; an agent whose hook set does not distinguish that from ordinary tool use will not track blocked accurately.
