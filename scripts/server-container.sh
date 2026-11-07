#!/usr/bin/env bash
# a local Linux host for agterm-server from this tree: ubuntu 24.04, sshd with key auth, a lingering systemd
# user manager. build needs the artifacts scripts/setup-zmx-linux.sh stages under build/linux.
# usage: scripts/server-container.sh build|start|stop|host|ssh [COMMAND...]|check
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/build/server-container"
IMAGE=agterm-server-test
NAME=agterm-server-test
PORT="${AGTERM_SERVER_CONTAINER_PORT:-2222}"
SWIFT_IMAGE=swift:6.3.2-noble
LIB=/home/agterm/.local/lib/agterm-server

die() { echo "server-container: $*" >&2; exit 2; }

arch() {
  case "$(uname -m)" in
    arm64 | aarch64) echo aarch64 ;;
    x86_64) echo x86_64 ;;
    *) die "unsupported architecture $(uname -m)" ;;
  esac
}

SSH=(ssh -i "$OUT/id_ed25519" -o BatchMode=yes -o ConnectTimeout=5 -o UserKnownHostsFile="$OUT/known_hosts"
  -o StrictHostKeyChecking=yes -p "$PORT" agterm@127.0.0.1)

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

compile() {
  local a="$1"
  mkdir -p "$OUT/bin"
  # the source tree is recreated each run so a removed file cannot reach the build; the named volume keeps only
  # SwiftPM's scratch path, at the same tree path so its incremental state stays valid
  docker run --rm -v "$ROOT:/src:ro" -v agterm-server-build:/build -v "$OUT/bin:/out" "$SWIFT_IMAGE" bash -euo pipefail -c '
    rm -rf /build/tree
    mkdir -p /build/tree
    tar -C /src --exclude=./build --exclude=./agtermCore/.build --exclude=./.git --exclude=./agterm/Resources -cf - . \
      | tar -C /build/tree -xf -
    cd /build/tree/agtermCore
    build=(swift build -c release --static-swift-stdlib --scratch-path /build/scratch)
    "${build[@]}" --product agterm-server
    "${build[@]}" --product agtermctl
    cp "$("${build[@]}" --show-bin-path)/agterm-server" "$("${build[@]}" --show-bin-path)/agtermctl" /out/
  '
  [[ -x "$OUT/bin/agterm-server" && -x "$OUT/bin/agtermctl" ]] || die "the $a build left no binaries in $OUT/bin"
}

stage() {
  local a="$1" ctx="$OUT/context"
  [[ -x "$ROOT/build/linux/$a/zmx/zmx" ]] || die "no staged zmx at build/linux/$a/zmx; run scripts/setup-zmx-linux.sh"
  [[ -d "$ROOT/build/linux/ghostty/shell-integration" && -d "$ROOT/build/linux/terminfo" ]] \
    || die "no staged shell integration under build/linux; run scripts/setup-zmx-linux.sh"
  rm -rf "$ctx"
  mkdir -p "$ctx/lib/resources"
  cp "$OUT/bin/agterm-server" "$OUT/bin/agtermctl" "$ROOT/build/linux/$a/zmx/zmx" "$ctx/lib/"
  cp -R "$ROOT/build/linux/ghostty/shell-integration" "$ROOT/build/linux/terminfo" "$ctx/lib/resources/"
  cp "$OUT/ssh_host_ed25519_key" "$OUT/ssh_host_ed25519_key.pub" "$OUT/authorized_keys" "$ctx/"
  cat >"$ctx/agterm-server.service" <<'UNIT'
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
  cat >"$ctx/Dockerfile" <<DOCKERFILE
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
COPY --chown=agterm:agterm lib $LIB
COPY --chown=agterm:agterm agterm-server.service /home/agterm/.config/systemd/user/agterm-server.service
RUN cd /home/agterm \
    && mkdir -p .config/systemd/user/default.target.wants .local/bin \
    && ln -s ../agterm-server.service .config/systemd/user/default.target.wants/agterm-server.service \
    && ln -s ../lib/agterm-server/agtermctl .local/bin/agtermctl \
    && touch .zshrc && chmod 700 .ssh && chmod 600 .ssh/authorized_keys && chown -R agterm:agterm /home/agterm
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
DOCKERFILE
  docker build -q -t "$IMAGE" "$ctx" >/dev/null
}

start() {
  docker image inspect "$IMAGE" >/dev/null 2>&1 || die "no $IMAGE image; run $0 build"
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  # systemd as pid 1 needs its own writable cgroup tree and a tmpfs /run
  docker run -d --name "$NAME" --privileged --cgroupns=private --tmpfs /run --tmpfs /run/lock \
    -p "127.0.0.1:$PORT:22" "$IMAGE" >/dev/null
  for _ in $(seq 30); do
    if "${SSH[@]}" 'systemctl --user is-active agterm-server' </dev/null >/dev/null 2>&1; then
      host
      return 0
    fi
    sleep 1
  done
  docker logs "$NAME" 2>&1 | tail -20 >&2
  die "the container did not serve ssh and agterm-server within 30s"
}

host() { echo "ssh://agterm@127.0.0.1:$PORT (key $OUT/id_ed25519, known_hosts $OUT/known_hosts)"; }

remote() { "${SSH[@]}" "$@"; }

check() {
  remote 'bash -s' <<'CHECK'
set -euo pipefail
ctl="$HOME/.local/bin/agtermctl"
fail() { echo "FAIL: $*"; exit 1; }
served() {
  local i
  for i in $(seq 50); do "$ctl" version >/dev/null 2>&1 && return 0; sleep 0.2; done
  fail "agterm-server did not answer after $1"
}
server_pid() { systemctl --user show -p MainPID --value agterm-server; }
# the shell writes its own pid, so the check follows the pane's process rather than any daemon bookkeeping
probe() {
  local marker="$1" i
  rm -f "/tmp/agterm-check-$marker"
  "$ctl" session type "echo \$\$ >/tmp/agterm-check-$marker"$'\r' --target "$id" >/dev/null
  for i in $(seq 50); do [[ -s "/tmp/agterm-check-$marker" ]] && { cat "/tmp/agterm-check-$marker"; return 0; }; sleep 0.2; done
  fail "the pane did not run its input ($marker)"
}
alive() {
  local after="$1"
  kill -0 "$shell" 2>/dev/null || fail "pane shell $shell is gone after $after"
  [[ "$("$ctl" tree --json | jq --arg id "$id" '[.. | objects | select(.id? == $id)][0].ended // false')" == false ]] \
    || fail "the session reads ended after $after"
  [[ "$(probe "$after")" == "$shell" ]] || fail "the pane answered from another shell after $after"
}

served start
id="$("$ctl" session new --json | jq -r '.result.id')"
[[ -n "$id" && "$id" != null ]] || fail "session new returned no id"
shell="$(probe first)"
cgroup="$(cut -d: -f3 "/proc/$shell/cgroup")"
[[ "$cgroup" == *.scope* && "$cgroup" != *agterm-server.service* ]] || fail "pane cgroup is $cgroup"
echo "pane shell $shell in $cgroup"

before="$(server_pid)"
systemctl --user restart agterm-server
served restart
[[ "$(server_pid)" != "$before" ]] || fail "the server pid did not change on restart"
alive restart
echo "restart: pane shell $shell kept"

before="$(server_pid)"
kill -9 "$before"
for _ in $(seq 50); do now="$(server_pid)"; [[ "$now" != 0 && "$now" != "$before" ]] && break; sleep 0.2; done
served kill
alive kill
echo "killed server: pane shell $shell kept"

"$ctl" session close --target "$id" >/dev/null
for _ in $(seq 50); do kill -0 "$shell" 2>/dev/null || break; sleep 0.2; done
! kill -0 "$shell" 2>/dev/null || fail "session close left pane shell $shell running"
echo "PASS"
CHECK
}

case "${1:-}" in
  build)
    keys
    compile "$(arch)"
    stage "$(arch)"
    echo "built $IMAGE"
    ;;
  start) start ;;
  stop) docker rm -f "$NAME" >/dev/null 2>&1 || true ;;
  host) host ;;
  ssh) shift; remote "$@" ;;
  check) check ;;
  *) die "usage: $0 build|start|stop|host|ssh [COMMAND...]|check" ;;
esac
