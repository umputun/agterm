#!/usr/bin/env bash
# a local Linux host for agterm-server from this tree: ubuntu 24.04, sshd with key auth, a lingering systemd
# user manager. start installs the server with scripts/install-server.sh, which needs the artifacts
# scripts/setup-zmx-linux.sh stages under build/linux.
# usage: scripts/server-container.sh build|start|stop|install|host|ssh [COMMAND...]|check
# shellcheck disable=SC2016,SC2088 # remote step bodies are single-quoted to expand on the host
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/build/server-container"
IMAGE=agterm-server-test
NAME=agterm-server-test
PORT="${AGTERM_SERVER_CONTAINER_PORT:-2222}"

die() { echo "server-container: $*" >&2; exit 2; }

SSH_OPTIONS=(-i "$OUT/id_ed25519" -o ConnectTimeout=5 -o UserKnownHostsFile="$OUT/known_hosts"
  -o StrictHostKeyChecking=yes -p "$PORT" agterm@127.0.0.1)
SSH=(ssh -o BatchMode=yes "${SSH_OPTIONS[@]}")

keys() {
  mkdir -p "$OUT"
  [[ -f "$OUT/id_ed25519" ]] || ssh-keygen -q -t ed25519 -N '' -C agterm-server-test -f "$OUT/id_ed25519"
  # a host key kept across rebuilds keeps known_hosts valid
  [[ -f "$OUT/ssh_host_ed25519_key" ]] || ssh-keygen -q -t ed25519 -N '' -C agterm-server-test -f "$OUT/ssh_host_ed25519_key"
  printf '[127.0.0.1]:%s %s\n' "$PORT" "$(cut -d' ' -f1-2 "$OUT/ssh_host_ed25519_key.pub")" >"$OUT/known_hosts"
  {
    cat "$OUT/id_ed25519.pub"
    ssh-add -L 2>/dev/null | grep -v '^The agent has no identities' || true
  } >"$OUT/authorized_keys"
}

image() {
  local ctx="$OUT/context"
  rm -rf "$ctx"
  mkdir -p "$ctx"
  cp "$OUT/ssh_host_ed25519_key" "$OUT/ssh_host_ed25519_key.pub" "$OUT/authorized_keys" "$ctx/"
  # lingering is set as an administrator would, before the install checks it
  cat >"$ctx/Dockerfile" <<'DOCKERFILE'
FROM ubuntu:24.04
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      systemd systemd-sysv dbus dbus-user-session openssh-server zsh fish bash procps jq busybox >/dev/null \
    && rm -rf /var/lib/apt/lists/* /etc/ssh/ssh_host_*
RUN useradd -m -s /bin/zsh agterm && mkdir -p /var/lib/systemd/linger && touch /var/lib/systemd/linger/agterm
COPY ssh_host_ed25519_key ssh_host_ed25519_key.pub /etc/ssh/
RUN chmod 600 /etc/ssh/ssh_host_ed25519_key \
    && printf 'HostKey /etc/ssh/ssh_host_ed25519_key\nPasswordAuthentication no\nKbdInteractiveAuthentication no\n' \
      >/etc/ssh/sshd_config.d/agterm.conf \
    && systemctl enable ssh.service >/dev/null 2>&1
COPY --chown=agterm:agterm authorized_keys /home/agterm/.ssh/authorized_keys
RUN cd /home/agterm && touch .zshrc && chmod 700 .ssh && chmod 600 .ssh/authorized_keys && chown -R agterm:agterm /home/agterm
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
DOCKERFILE
  docker build -q -t "$IMAGE" "$ctx" >/dev/null
}

install() { "$ROOT/scripts/install-server.sh" "${SSH_OPTIONS[@]}"; }

start() {
  docker image inspect "$IMAGE" >/dev/null 2>&1 || die "no $IMAGE image; run $0 build"
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  # systemd as pid 1 needs its own writable cgroup tree and a tmpfs /run
  docker run -d --name "$NAME" --privileged --cgroupns=private --tmpfs /run --tmpfs /run/lock \
    -p "127.0.0.1:$PORT:22" "$IMAGE" >/dev/null
  for _ in $(seq 30); do
    if "${SSH[@]}" true </dev/null >/dev/null 2>&1; then
      install
      host
      return 0
    fi
    sleep 1
  done
  docker logs "$NAME" 2>&1 | tail -20 >&2
  die "the container did not serve ssh within 30s"
}

host() { echo "ssh://agterm@127.0.0.1:$PORT (key $OUT/id_ed25519, known_hosts $OUT/known_hosts)"; }

remote() { "${SSH[@]}" "$@"; }

# shared by every remote step of check; each step is its own ssh session
PRELUDE='set -euo pipefail
ctl="$HOME/.local/bin/agtermctl"
fail() { echo "FAIL: $*" >&2; exit 1; }
served() {
  local i
  for i in $(seq 50); do "$ctl" version >/dev/null 2>&1 && return 0; sleep 0.2; done
  fail "agterm-server did not answer after $1"
}
server_pid() { systemctl --user show -p MainPID --value agterm-server; }
catalog() { "$ctl" window list --json | jq -r ".result.windows[0].id"; }
# the shell writes its own pid, so the check follows the pane process rather than any daemon bookkeeping
probe() {
  local id="$1" marker="$2" i
  rm -f "/tmp/agterm-check-$marker"
  "$ctl" session type "echo \$\$ >/tmp/agterm-check-$marker"$'"'"'\r'"'"' --target "$id" >/dev/null
  for i in $(seq 50); do [[ -s "/tmp/agterm-check-$marker" ]] && { cat "/tmp/agterm-check-$marker"; return 0; }; sleep 0.2; done
  fail "the pane did not run its input ($marker)"
}
alive() {
  local id="$1" shell="$2" after="$3"
  kill -0 "$shell" 2>/dev/null || fail "pane shell $shell is gone after $after"
  [[ "$("$ctl" tree --json | jq --arg id "$id" "[.. | objects | select(.id? == \$id)][0].ended // false")" == false ]] \
    || fail "the session reads ended after $after"
  [[ "$(probe "$id" "$after")" == "$shell" ]] || fail "the pane answered from another shell after $after"
}
opened() {
  local id
  id="$("$ctl" session new --json | jq -r ".result.id")"
  [[ -n "$id" && "$id" != null ]] || fail "session new returned no id"
  echo "$id $(probe "$id" "$1") $(catalog)"
}
'

step() {
  local body="$1"
  shift
  remote bash -s -- "$@" <<<"$PRELUDE$body"
}

fail() { echo "FAIL: $*" >&2; exit 1; }

# no logind session left for the user, then the user manager's stop delay and a margin
logged_out() {
  local sessions delay
  for _ in $(seq 60); do
    sessions="$(docker exec "$NAME" loginctl show-user agterm -p Sessions --value 2>/dev/null || true)"
    [[ -z "$sessions" ]] && break
    sleep 0.5
  done
  [[ -z "$sessions" ]] || fail "sessions $sessions still open 30s after logout"
  delay="$(docker exec "$NAME" busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
    org.freedesktop.login1.Manager UserStopDelayUSec | cut -d' ' -f2)"
  sleep $((delay / 1000000 + 3))
}

check() {
  step '
served start
opening="$(opened first)"
read -r id shell _ <<<"$opening"
cgroup="$(cut -d: -f3 "/proc/$shell/cgroup")"
[[ "$cgroup" == *.scope* && "$cgroup" != *agterm-server.service* ]] || fail "pane cgroup is $cgroup"
echo "pane shell $shell in $cgroup"

before="$(server_pid)"
systemctl --user restart agterm-server
served restart
[[ "$(server_pid)" != "$before" ]] || fail "the server pid did not change on restart"
alive "$id" "$shell" restart
echo "restart: pane shell $shell kept"

before="$(server_pid)"
kill -9 "$before"
for _ in $(seq 50); do now="$(server_pid)"; [[ "$now" != 0 && "$now" != "$before" ]] && break; sleep 0.2; done
served kill
alive "$id" "$shell" kill
echo "killed server: pane shell $shell kept"

"$ctl" session close --target "$id" >/dev/null
for _ in $(seq 50); do kill -0 "$shell" 2>/dev/null || break; sleep 0.2; done
! kill -0 "$shell" 2>/dev/null || fail "session close left pane shell $shell running"
echo "close: pane shell $shell ended"
'

  local id shell catalog opening
  opening="$(step 'served upgrade; opened upgrade')"
  read -r id shell catalog <<<"$opening"
  # the upgrade runs with a fish login shell, which reads every remote command the install sends
  docker exec "$NAME" chsh -s /usr/bin/fish agterm
  install >/dev/null
  docker exec "$NAME" chsh -s /bin/zsh agterm
  step '
served "the upgrade"
[[ "$(catalog)" == "$2" ]] || fail "the catalog id changed across the upgrade"
alive "$1" "$3" upgrade
"$ctl" session close --target "$1" >/dev/null
echo "upgrade under a fish login shell: pane shell $3 and catalog $2 kept"
' "$id" "$catalog" "$shell"

  # a kept unit that moves the state directory, relative to the service's working directory
  remote 'mkdir -p ~/.config/systemd/user/agterm-server.service.d && printf "[Service]\nWorkingDirectory=%%h\nExecStart=\nExecStart=%%h/.local/lib/agterm-server/agterm-server --state-dir=alt-state\n" >~/.config/systemd/user/agterm-server.service.d/state.conf'
  local output
  output="$(install 2>&1)" || fail "the install with a moved state directory failed: $output"
  [[ "$output" == *"server: "* ]] || fail "the install did not print the moved server's versions"
  remote 'test -S ~/alt-state/agterm.sock' || fail "the moved server has no socket under ~/alt-state"
  remote 'rm -r ~/.config/systemd/user/agterm-server.service.d && systemctl --user daemon-reload && systemctl --user restart agterm-server'
  step 'served "the state move"'
  echo "moved state directory: the install reached the service's own socket"

  # lingering off and enabling it refused, through a stub loginctl ahead of the real one on PATH
  docker exec "$NAME" sh -c 'printf "#!/bin/sh\ncase \"\$1\" in show-user) echo no ;; *) exit 1 ;; esac\n" >/usr/local/bin/loginctl && chmod 755 /usr/local/bin/loginctl'
  remote 'systemctl --user stop agterm-server'
  if output="$(install 2>&1)"; then fail "the install succeeded with lingering refused"; fi
  [[ "$output" == *"loginctl enable-linger agterm"* ]] || fail "the refusal did not name the administrator's command: $output"
  [[ "$(remote 'systemctl --user is-active agterm-server' || true)" == inactive ]] || fail "the refused install started the service"
  docker exec "$NAME" rm /usr/local/bin/loginctl
  remote 'systemctl --user start agterm-server'
  step 'served "the linger refusal"'
  echo "lingering refused: the install stopped before the service and named the fix"

  [[ "$(remote '~/.local/bin/agtermctl tree --json' </dev/null | jq -r .ok)" == true ]] \
    || fail "a bare ssh agtermctl tree did not answer"
  echo "bare ssh: agtermctl tree answered"

  # descriptors the server opens on other threads while it spawns zmx must not reach the daemons
  step '
served descriptors
state="${XDG_STATE_HOME:-$HOME/.local/state}/agterm"
( for _ in $(seq 300); do "$ctl" tree >/dev/null 2>&1; done ) &
flood=$!
ids=()
for _ in $(seq 30); do ids+=("$("$ctl" session new --json | jq -r .result.id)"); done
wait "$flood"
inodes="$(awk -v sock="$state/agterm.sock" "\$8 == sock { print \$7 }" /proc/net/unix)"
daemons=0
for pid in $(pgrep -u "$(id -u)" -x zmx); do
  daemons=$((daemons + 1))
  for fd in /proc/"$pid"/fd/*; do
    link="$(readlink "$fd" 2>/dev/null || true)"
    case "$link" in
      socket:*)
        inode="${link#socket:[}"
        if grep -qx "${inode%]}" <<<"$inodes"; then fail "zmx $pid holds a control connection on $fd"; fi
        ;;
      "$state"/*) fail "zmx $pid holds $link on $fd" ;;
    esac
  done
done
[[ "$daemons" -ge 30 ]] || fail "only $daemons zmx daemons for 30 sessions"
for id in "${ids[@]}"; do "$ctl" session close --target "$id" >/dev/null; done
echo "descriptors: none of $daemons zmx daemons holds a control connection or a state file"
'

  opening="$(step 'served logout; opened logout')"
  read -r id shell _ <<<"$opening"
  logged_out
  docker exec "$NAME" kill -0 "$shell" || fail "pane shell $shell is gone after the last logout with lingering"
  step 'served relogin; alive "$1" "$2" relogin; "$ctl" session close --target "$1" >/dev/null' "$id" "$shell"
  echo "last logout: pane shell $shell kept"

  # the negative control: the same sequence without lingering must lose the shell, or lingering is not what kept it
  docker exec "$NAME" loginctl disable-linger agterm
  opening="$(step 'served nolinger; opened nolinger')"
  read -r id shell _ <<<"$opening"
  logged_out
  ! docker exec "$NAME" kill -0 "$shell" 2>/dev/null || fail "pane shell $shell survived the last logout without lingering"
  docker exec "$NAME" loginctl enable-linger agterm
  step 'served linger; "$ctl" session close --target "$1" >/dev/null' "$id"
  echo "last logout without lingering: pane shell $shell ended"
  echo "PASS"
}

case "${1:-}" in
  build)
    keys
    image
    echo "built $IMAGE"
    ;;
  start) start ;;
  stop) docker rm -f "$NAME" >/dev/null 2>&1 || true ;;
  install) install ;;
  host) host ;;
  ssh) shift; remote "$@" ;;
  check) check ;;
  *) die "usage: $0 build|start|stop|install|host|ssh [COMMAND...]|check" ;;
esac
