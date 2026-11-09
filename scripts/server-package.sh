#!/usr/bin/env bash
# agterm-server's tarball for one architecture, as a release ships it: agterm-server, agtermctl, zmx, the shell
# integration, terminfo, the agent hooks, the skill, zmx's license and install.sh, at the archive root.
# usage: scripts/server-package.sh aarch64|x86_64 [VERSION]
#   -> build/server/agterm-server-VERSION-linux-ARCH.tar.gz and its .sha256
# needs scripts/setup-zmx-linux.sh's artifacts under build/linux; builds with scripts/server-build.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { echo "server-package: $*" >&2; exit 2; }

arch="${1:-}"
version="${2:-0.0.0}"
case "$arch" in
  aarch64 | x86_64) ;;
  *) die "usage: $0 aarch64|x86_64 [VERSION]" ;;
esac
zmx="$ROOT/build/linux/$arch/zmx/zmx"
[[ -x "$zmx" && -f "${zmx%/*}/LICENSE" ]] || die "no staged zmx and LICENSE in ${zmx%/*}; run scripts/setup-zmx-linux.sh"
[[ -d "$ROOT/build/linux/ghostty/shell-integration" && -d "$ROOT/build/linux/terminfo" ]] \
  || die "no staged shell integration under build/linux; run scripts/setup-zmx-linux.sh"

"$ROOT/scripts/server-build.sh" "$arch" "$version"

stage="$(mktemp -d "${TMPDIR:-/tmp}/agterm-server-stage.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/resources/skill" "$stage/licenses/zmx"
cp "$ROOT/build/server/$arch/agterm-server" "$ROOT/build/server/$arch/agtermctl" "$zmx" "$stage/"
cp -R "$ROOT/build/linux/ghostty/shell-integration" "$ROOT/build/linux/terminfo" "$ROOT/agterm/Resources/agent-status" \
  "$stage/resources/"
cp -R "$ROOT/plugins/agterm/skills/agterm" "$stage/resources/skill/"
cp "$ROOT/build/linux/$arch/zmx/LICENSE" "$stage/licenses/zmx/"
cp "$ROOT/scripts/server-host-install.sh" "$stage/install.sh"

name="agterm-server-$version-linux-$arch.tar.gz"
COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -C "$stage" -czf "$ROOT/build/server/$name" .
(cd "$ROOT/build/server" && shasum -a 256 "$name" >"$name.sha256")
echo "packaged build/server/$name"
