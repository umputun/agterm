#!/usr/bin/env bash
# install or upgrade agterm-server on a Linux host over ssh, from this tree; every run does the same steps.
# usage: scripts/install-server.sh [SSH_OPTION...] DESTINATION
# needs scripts/setup-zmx-linux.sh's artifacts under build/linux; builds the server with scripts/server-build.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { echo "install-server: $*" >&2; exit 2; }

[[ $# -ge 1 ]] || die "usage: $0 [SSH_OPTION...] DESTINATION"
SSH=(ssh -o BatchMode=yes "$@")

arch="$("${SSH[@]}" uname -m </dev/null)"
case "$arch" in
  aarch64 | x86_64) ;;
  *) die "unsupported host architecture $arch; agterm-server builds for aarch64 and x86_64" ;;
esac
zmx="$ROOT/build/linux/$arch/zmx/zmx"
[[ -x "$zmx" ]] || die "no staged zmx at $zmx; run scripts/setup-zmx-linux.sh"
[[ -d "$ROOT/build/linux/ghostty/shell-integration" && -d "$ROOT/build/linux/terminfo" ]] \
  || die "no staged shell integration under build/linux; run scripts/setup-zmx-linux.sh"

"$ROOT/scripts/server-build.sh" "$arch"

stage="$(mktemp -d "${TMPDIR:-/tmp}/agterm-server-stage.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/resources/skill"
cp "$ROOT/build/server/$arch/agterm-server" "$ROOT/build/server/$arch/agtermctl" "$zmx" "$stage/"
cp -R "$ROOT/build/linux/ghostty/shell-integration" "$ROOT/build/linux/terminfo" "$ROOT/agterm/Resources/agent-status" \
  "$stage/resources/"
cp -R "$ROOT/plugins/agterm/skills/agterm" "$stage/resources/skill/"

# unpacked beside the live directory and swapped in by rename, so a running server keeps its open binary; the login
# shell may be fish, and a single-quoted word with no quote or backslash inside reads the same in every shell
# shellcheck disable=SC2016 # $HOME expands on the host
unpack='set -e
  lib="$HOME/.local/lib/agterm-server"
  mkdir -p "$HOME/.local/lib"
  rm -rf "$lib.new" "$lib.old"
  mkdir "$lib.new"
  tar -xzf - -C "$lib.new"
  if [ -e "$lib" ]; then mv "$lib" "$lib.old"; fi
  mv "$lib.new" "$lib"
  rm -rf "$lib.old"'
COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -C "$stage" -czf - . | "${SSH[@]}" "sh -c '$unpack'"

status=0
"${SSH[@]}" 'bash -s' <<'REMOTE' || status=$?
set -euo pipefail
lib="$HOME/.local/lib/agterm-server"
unit="$HOME/.config/systemd/user/agterm-server.service"
mkdir -p "$HOME/.local/bin" "$(dirname "$unit")"
ln -sfn "$lib/agtermctl" "$HOME/.local/bin/agtermctl"
ln -sfn "$lib/agterm-server" "$HOME/.local/bin/agterm-server"

# written once, so a user's edits and drop-ins survive an upgrade
if [[ ! -e "$unit" ]]; then
  cat >"$unit" <<'UNIT'
[Unit]
Description=agterm server

[Service]
ExecStart=%h/.local/lib/agterm-server/agterm-server
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin
Restart=on-failure
RestartSec=1

[Install]
WantedBy=default.target
UNIT
  echo "wrote $unit"
fi

# without linger the user manager stops at the last logout and takes the server and every pane with it
user="$(id -un)"
if [[ "$(loginctl show-user "$user" -p Linger --value 2>/dev/null || true)" != yes ]]; then
  if ! loginctl enable-linger "$user" 2>/dev/null; then
    echo "install-server: lingering is off for $user and enabling it was refused." >&2
    echo "Without it systemd stops agterm-server and every session at your last logout." >&2
    echo "Ask an administrator to run: loginctl enable-linger $user, then run this again." >&2
    exit 1
  fi
  echo "enabled lingering for $user"
fi

systemctl --user daemon-reload
systemctl --user enable agterm-server >/dev/null 2>&1
if systemctl --user is-active --quiet agterm-server; then
  systemctl --user restart agterm-server
else
  systemctl --user start agterm-server
fi

# a kept unit may move the state directory by environment, EnvironmentFile or --state-dir, so the CLI runs with the
# running server's own environment, state flag and working directory, and resolves the socket the way it did
pid=0
for _ in $(seq 50); do
  pid="$(systemctl --user show -p MainPID --value agterm-server)"
  [[ "$pid" != 0 && -r "/proc/$pid/environ" ]] && break
  sleep 0.2
done
[[ "$pid" != 0 ]] || { echo "install-server: agterm-server did not start" >&2; exit 1; }
mapfile -d '' environment <"/proc/$pid/environ"
mapfile -d '' arguments <"/proc/$pid/cmdline"
ctl=(env -i "${environment[@]}")
for ((i = 1; i < ${#arguments[@]}; i++)); do
  case "${arguments[i]}" in
    --state-dir) ctl+=("AGTERM_STATE_DIR=${arguments[i + 1]:-}") ;;
    --state-dir=*) ctl+=("AGTERM_STATE_DIR=${arguments[i]#--state-dir=}") ;;
  esac
done
ctl+=("$lib/agtermctl" version)
cd "/proc/$pid/cwd"
for _ in $(seq 50); do "${ctl[@]}" >/dev/null 2>&1 && break; sleep 0.2; done
"${ctl[@]}" || { echo "install-server: agterm-server is not answering" >&2; exit 1; }
cd "$HOME"

# a login shell, so the PATH and OpenCode variables are the ones an agent started in a pane sees
if ! "${SHELL:-/bin/sh}" -lc "$lib/agterm-server install-hooks"; then
  echo "install-server: the agent hooks install is incomplete; see above, then run ~/.local/bin/agterm-server install-hooks" >&2
  exit 3
fi
REMOTE

if ! "${SSH[@]}" 'command -v agtermctl' </dev/null >/dev/null 2>&1; then
  echo "note: a plain ssh command does not find agtermctl, because that shell's PATH lacks ~/.local/bin."
  echo "agterm's own remote commands add it themselves; for your scripts use ~/.local/bin/agtermctl or add it to PATH."
fi
case "$status" in
  0) echo "agterm-server installed" ;;
  3) echo "agterm-server installed; the agent hooks are incomplete" ;;
  *) die "the install on the host failed" ;;
esac
exit "$status"
