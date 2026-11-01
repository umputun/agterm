# Container overlays

Open agterm overlays — terminal programs, HTML pages and URLs — from inside a docker container, with the program running in the container and files opened by their Mac paths.

## What it does

An agterm session whose shell runs `docker exec` into a container can manage sessions and set statuses from inside, but `agtermctl session overlay open` fails there: agterm executes the overlay COMMAND on the Mac, reads `--html` files from the Mac's filesystem, and for `--url` pages `localhost` means the Mac. This recipe installs an `agtermctl` wrapper inside the container that rewrites exactly the overlay calls, so from inside the container:

- `agtermctl session overlay open -- htop` runs htop **in the container** (the Mac-side overlay terminal runs `docker exec` back into it), in the caller's working directory, with `--block` returning the program's real exit code.
- `agtermctl session overlay open --html FILE` opens the page. FILE under a bind mount is opened by its Mac path; a file anywhere else is copied into a bind-mounted staging directory (with its sibling assets) and the copy is opened. A read-access grant is always synthesized so relative assets load.
- `agtermctl session overlay open --url http://localhost:3004/` works when the port is published at `docker run -p 127.0.0.1:3004:3004` — on the Mac, `localhost` is the published port.
- Every other call (`tree`, `session status`, `session close`, …) passes through to the real agtermctl on the Mac unchanged.

## Requirements

- agterm 0.39.0 or later, which carries the `session overlay open` flag surface the wrapper's parser knows (`--companion`, its newest flag, shipped in it).
- docker, with `host.docker.internal` resolving to the Mac from inside containers (docker desktop setups do this; otherwise add `--add-host host.docker.internal:host-gateway`).
- Python 3.8 or later, standard library only, in the container and on the Mac.
- In the container image: `sh`, `printf` and `base64` (busybox counts).
- Optional: the `xterm-ghostty` terminfo entry compiled into the image (below) for full-color TUI programs; without it see Limits.

## Setup

Variables used below: `dev` is the container name (keep name and hostname equal — the wrapper learns the name from `hostname`), `3004` is an example dev-server port, and `$HOME/agterm-bridge` is a Mac directory shared with the container.

### On the Mac

```sh
mkdir -p ~/bin "$HOME/agterm-bridge"
cp agtermctl-receiver.py bind-map.py ~/bin/
chmod +x ~/bin/agtermctl-receiver.py ~/bin/bind-map.py
```

Run the receiver whenever you want container-side `agtermctl` to work — it is the hop every call crosses:

```sh
~/bin/agtermctl-receiver.py --port 59998 &
```

It binds `127.0.0.1` only, so nothing outside this Mac (plus its containers, via `host.docker.internal`) can reach it. It is a plain background job here; wrap it in a LaunchAgent if you want it to survive logout. The receiver's environment decides which agterm its calls drive: started from your account shell it drives your default instance; start it with a different `AGTERM_STATE_DIR` in its environment to drive another one — a request cannot retarget it (Limits). `--agtermctl` (or `AGTERMCTL` in its environment) points it at a specific binary, resolved before `AGTERMCTL` before PATH.

Update the container wrapper and the receiver together — rebuild the image's `agtermctl` when you update the receiver: an older wrapper's raw overlay COMMAND is refused with a message saying so.

Check where your docker CLI lives — the overlay terminal is spawned by the agterm app, which inherits the app's launch-environment PATH, not your shell's:

```sh
command -v docker   # must print /usr/local/bin/docker; if not, see below
```

### In the container image

```dockerfile
COPY agtermctl.py /usr/local/bin/agtermctl
COPY agt-ovl-expose.sh /usr/local/bin/agt-ovl-expose
RUN chmod +x /usr/local/bin/agtermctl /usr/local/bin/agt-ovl-expose
```

Optional, for full-color TUI programs: from an agterm pane run `infocmp -x xterm-ghostty > xterm-ghostty.terminfo` once, then add to the image (if `tic` is missing, install ncurses or skip this):

```dockerfile
COPY xterm-ghostty.terminfo /tmp/
RUN tic -x -o /usr/share/terminfo /tmp/xterm-ghostty.terminfo
```

### Running the container

Start it from an agterm shell so the session's `AGTERM_*` identity enters the container. The `-v` host path must be one your docker setup shares with the Mac — under your home directory that works everywhere:

```sh
docker run -d --name dev --hostname dev \
  -p 127.0.0.1:3004:3004 \
  -v "$HOME/agterm-bridge":/agterm-bridge \
  -e AGTERM_SESSION_ID -e AGTERM_WINDOW_ID -e AGTERM_WORKSPACE_ID \
  -e AGTERM_PANE -e AGTERM_PANE_ID \
  YOUR_IMAGE sleep infinity
```

Then write the bind map the wrapper translates paths with (rerun whenever the `-v` mounts change):

```sh
~/bin/bind-map.py dev "$HOME/agterm-bridge/bind-map.json"
```

If `command -v docker` did not print `/usr/local/bin/docker`, start the receiver with a copy of its `DEFAULT_EXEC_TEMPLATE` in which only the docker path differs: `--exec-template '<template>'` on its command line, or `AGT_OVL_EXEC_TEMPLATE` in its environment.

## Usage

From inside the container (or `docker exec -it dev sh` and then):

```sh
# a TUI program, running in the container
agtermctl session overlay open -- htop

# an exit code you can rely on
agtermctl session overlay open --block -- 'sh -c "exit 7"'; echo "rc=$?"   # rc=7

# flags parse after COMMAND too, like the host CLI
agtermctl session overlay open htop --block --size-percent 80

# a page under a bind: opened by its Mac path, assets beside it load
agtermctl session overlay open --html /agterm-bridge/report.html

# a page anywhere else in the container: copied into ~/agterm-bridge/pages/ and opened
agtermctl session overlay open --html /var/app/build/coverage.html
echo "<h1>v2</h1>" > /var/app/build/coverage.html
agtermctl session overlay reload          # re-copies, then agterm re-reads

# a dev server in the container (port published at docker run)
python3 -m http.server 3004 &
agtermctl session overlay open --url http://localhost:3004/
```

Overlays open on the session that started the container (the wrapper injects `--target` from `AGTERM_SESSION_ID`); every other flag, size included, reaches agterm exactly as you passed it.

## How it works

The wrapper replaces `agtermctl` inside the container and rewrites only `session overlay open` and `session overlay reload`; everything else is forwarded to the receiver on the Mac, which runs the real `agtermctl` and streams back stdout, stderr and the exit code over one connection per call. The receiver only ever starts its one resolved `agtermctl` binary: it refuses `--socket` in any request, and refuses a raw COMMAND on `session overlay open` (the container wrapper never sends one).

- **COMMAND** never crosses as text. The wrapper sends a structured exec request — the container name, the base64 of `cd '<cwd>' && <COMMAND>` (your `--cwd` when given, else the caller's cwd) and the open flags — and the receiver builds the one shell line it is willing to pass: `docker exec -it -e TERM=xterm-ghostty -e COLORTERM=truecolor -e AGTERM_* … dev sh -c "$(printf %s <base64> | base64 -d)"`, from its own template. The base64 armor keeps the double shell evaluation (Mac `/bin/sh` evals the overlay command, container `sh` evals the payload) from ever mangling it. The explicit `-e` forwards matter because a shell inside the exec does not inherit what the caller's shell exported after the container started. The docker path is absolute because the app, not your shell, spawns this line.
- **`--html`** is translated through the bind map (longest matching mount prefix). A `--cwd` grant is always passed: without one, agterm loads the page via `loadHTMLString` at about:blank with **zero** file access, so relative assets silently vanish. Files not under any bind are staged: the file's parent tree is copied (capped at 200 files / 20 MiB, then file-only) into `/agterm-bridge/pages/<id>/`, and the copy's Mac path is opened. `overlay reload` re-copies every live staged entry before passing through — that is what makes the edit/reload loop above work.
- **`--url`**: loopback URLs (`localhost`, `127.0.0.1`, `::1`, and names the container's `/etc/hosts` maps to 127.0.0.1) are rewritten through the expose command. With docker, publishing already happened at `-p`, so the default `agt-ovl-expose` is an identity that echoes the expected reply line; a two-column `/agterm-bridge/port-map.txt` (container port, host port) translates ports published under a different number. Set `AGT_OVL_EXPOSE=""` in the container to pass every `--url` through unrewritten instead.
- The parser knows agterm 0.39.0's closed flag list and reads flags before and after COMMAND, as the host CLI does. An unparsable call carrying `--html`/`--url` passes through unrewritten — the host may know a newer flag; any other unparsable open is refused on the spot, because sent as-is it would run its COMMAND on the Mac.
- Two agterm behaviors the wrapper compensates for: `--target` defaults to the *active* session (an overlay from a container would land on whatever terminal is focused), and a session's overlay slot holds one overlay, program or page — a second open of either kind fails with `overlay already open`; close the first. `--block` on COMMAND and page opens is one long-held call, not polling — the receiver never times a subprocess, and when the container side of a held call goes away the receiver terminates and reaps its `agtermctl` (the overlay itself belongs to the app and keeps running).

## Limits

**Anyone who reaches the receiver — every local process, and every container on this machine through `host.docker.internal` — drives your terminal as you: it still accepts `session new --command`, typing into your shells, closing sessions, rearranging windows.** It binds 127.0.0.1, which keeps other machines out but no one else on this Mac. Run it only on a single-user machine you control, and stop it when you are done.

What it will not do, even if asked: it never starts anything but its one resolved `agtermctl` binary; it refuses `--socket` in any request, so a caller cannot retarget it at another agterm instance — the receiver's own environment decides which one it drives; and it refuses a raw COMMAND on `session overlay open`, so no caller-written shell line reaches the Mac — overlay COMMANDs cross only as the structured exec request above.

- Staged pages are snapshots: edits show up only through `overlay reload`, and Show in Finder / open in browser reveal the staged copy, not the source file. A staged page nobody reloads for over 24 h can be deleted by the next staged open, and its manifest entry goes with it, so a later `overlay reload` cannot restore it — `overlay reload` refreshes the age.
- Closing the container side of a `--block` call stops the waiting call, not the overlay: the overlay program belongs to the app and keeps running.
- `--url` pages never get agterm's in-page command bridge (`data-agterm` buttons); interactive pages must go the `--html` route.
- URL pages send `Host: 127.0.0.1:<port>`; dev servers with strict host checks (Django's `ALLOWED_HOSTS`, some Vite configs) must allowlist loopback.
- Without the terminfo entry in the image, full-screen TUI programs fall back to degraded colors or fail; the receiver template's alternative is `TERM=xterm-256color`.
- Paths in non-overlay calls reach agtermctl unchanged and resolve on the Mac — pass Mac paths there. The one translated exception is `overlay open --html`, whose file (and `--cwd` beside it) the wrapper absolutizes against the container cwd and maps through the bind map.
