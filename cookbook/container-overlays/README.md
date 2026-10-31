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

It binds `127.0.0.1` only, so nothing outside this Mac (plus its containers, via `host.docker.internal`) can reach it. It is a plain background job here; wrap it in a LaunchAgent if you want it to survive logout. The receiver's environment decides which agterm its calls drive: started from your account shell it drives your default instance; start it with a different `AGTERM_STATE_DIR` in its environment to drive another one.

Check where your docker CLI lives — the overlay terminal is spawned by the agterm app, which inherits the app's launch-environment PATH, not your shell's:

```sh
command -v docker   # must print /usr/local/bin/docker; if not, see the run line below
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

If `command -v docker` did not print `/usr/local/bin/docker`, add
`-e AGT_OVL_EXEC_TEMPLATE='<template with your docker path>'`
to the run line — copy the template from the wrapper's `DEFAULT_EXEC_TEMPLATE` and change only the binary path.

## Usage

From inside the container (or `docker exec -it dev sh` and then):

```sh
# a TUI program, running in the container
agtermctl session overlay open -- htop

# an exit code you can rely on
agtermctl session overlay open --block -- 'sh -c "exit 7"'; echo "rc=$?"   # rc=7

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

The wrapper replaces `agtermctl` inside the container and rewrites only `session overlay open` and `session overlay reload`; everything else is forwarded verbatim to the receiver on the Mac, which runs the real `agtermctl` and streams back stdout, stderr and the exit code over one connection per call.

- **COMMAND** becomes `docker exec -it -e TERM=xterm-ghostty -e COLORTERM=truecolor -e AGTERM_* … dev sh -c "$(printf %s <base64> | base64 -d)"`. The payload is `cd '<caller cwd>' && <COMMAND>`, base64-armored so the double shell evaluation (Mac `/bin/sh` evals the overlay command, container `sh` evals the payload) can never mangle it. The explicit `-e` forwards matter because a shell inside the exec does not inherit what the caller's shell exported after the container started. The docker path is absolute because the app, not your shell, spawns this line.
- **`--html`** is translated through the bind map (longest matching mount prefix). A `--cwd` grant is always passed: without one, agterm loads the page via `loadHTMLString` at about:blank with **zero** file access, so relative assets silently vanish. Files not under any bind are staged: the file's parent tree is copied (capped at 200 files / 20 MiB, then file-only) into `/agterm-bridge/pages/<id>/`, and the copy's Mac path is opened. `overlay reload` re-copies every live staged entry before passing through — that is what makes the edit/reload loop above work.
- **`--url`**: loopback URLs (`localhost`, `127.0.0.1`, `::1`, and names the container's `/etc/hosts` maps to 127.0.0.1) are rewritten through the expose command. With docker, publishing already happened at `-p`, so the default `agt-ovl-expose` is an identity that echoes the expected reply line; a two-column `/agterm-bridge/port-map.txt` (container port, host port) translates ports published under a different number. Set `AGT_OVL_EXPOSE=""` in the container to pass every `--url` through verbatim instead.
- The parser knows agterm 0.39.0's closed flag list. Anything it does not recognize — a flag from a newer agterm, a malformed call — is passed through unrewritten rather than guessed at.
- Two agterm behaviors the wrapper compensates for: `--target` defaults to the *active* session (an overlay from a container would land on whatever terminal is focused), and a session's overlay slot holds one overlay, program or page — a second open of either kind fails with `overlay already open`; close the first. `--block` on COMMAND and page opens is one long-held call, not polling — the receiver never times a subprocess.

## Limits

**The receiver runs any agtermctl command that reaches it — including ones that close sessions, type into shells or rearrange windows — with your own terminal's authority.** It binds 127.0.0.1, which keeps other machines out but no one else on this Mac: every local process, and every container on this machine through `host.docker.internal`, can use it. Only the five session-identity variables cross with a request, so a caller cannot retarget it at another agterm instance — but within yours it still acts with full authority. Run it only on a single-user machine you control, and stop it when you are done.

- Staged pages are snapshots: edits show up only through `overlay reload`, and Show in Finder / open in browser reveal the staged copy, not the source file.
- `--url` pages never get agterm's in-page command bridge (`data-agterm` buttons); interactive pages must go the `--html` route.
- URL pages send `Host: 127.0.0.1:<port>`; dev servers with strict host checks (Django's `ALLOWED_HOSTS`, some Vite configs) must allowlist loopback.
- Without the terminfo entry in the image, full-screen TUI programs fall back to degraded colors or fail; the wrapper's template alternative is `TERM=xterm-256color`.
- Paths in non-overlay calls reach agtermctl unchanged and resolve on the Mac — pass Mac paths there. The one translated exception is `overlay open --html`, whose file (and `--cwd` beside it) the wrapper absolutizes against the container cwd and maps through the bind map.
