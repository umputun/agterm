#!/usr/bin/env bash
# install or upgrade agterm-server on a Linux host over ssh, from this tree; every run does the same steps.
# usage: scripts/install-server.sh [SSH_OPTION...] DESTINATION
# packages the host's architecture with scripts/server-package.sh, then does what `agtermctl server install` does with
# a release tarball: unpack it beside the live directory, swap it in, and run its install.sh.
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

"$ROOT/scripts/server-package.sh" "$arch"
tarball="$ROOT/build/server/agterm-server-0.0.0-linux-$arch.tar.gz"

# unpacked beside the live directory and swapped in by rename, so a running server keeps its open binary. One line:
# the login shell parses the quoted command first, it may be fish or tcsh, and tcsh rejects a quoted newline; a
# single-quoted word with no quote or backslash inside reads the same in every shell. ServerInstall sends this string.
# shellcheck disable=SC2016 # $HOME expands on the host
unpack='set -e; lib="$HOME/.local/lib/agterm-server"; mkdir -p "$HOME/.local/lib"; rm -rf "$lib.new" "$lib.old"; mkdir "$lib.new"; tar -xzf - -C "$lib.new"; if [ -e "$lib" ]; then mv "$lib" "$lib.old"; fi; mv "$lib.new" "$lib"; rm -rf "$lib.old"'
"${SSH[@]}" "sh -c '$unpack'" <"$tarball"

status=0
# shellcheck disable=SC2016 # $HOME expands on the host
"${SSH[@]}" 'bash "$HOME/.local/lib/agterm-server/install.sh"' </dev/null || status=$?
case "$status" in
  0) echo "agterm-server installed" ;;
  3) echo "agterm-server installed; the agent hooks are incomplete" ;;
  *) die "the install on the host failed" ;;
esac
exit "$status"
