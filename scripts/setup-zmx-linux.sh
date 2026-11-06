#!/usr/bin/env bash
# linux artifacts for agterm-server under build/linux, from the pins setup.sh holds: the patched zmx per
# architecture (musl), and ghostty's zsh, fish and bash integration plus terminfo at GHOSTTY_REV.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="build/linux"

for arch in aarch64 x86_64; do
  AGTERM_ZMX_TARGET="$arch-linux-musl" \
    AGTERM_ZMX_STAGE_DIR="$OUT/$arch/zmx" \
    AGTERM_ZMX_STAMP_FILE="$OUT/$arch/.zmx-build-stamp" \
    scripts/setup.sh --zmx-only
done

# the shell integration and terminfo come from the Mac's libghostty staging, whose stamp says which
# GHOSTTY_REV and patches they were built from; that stamp is the Linux set's stamp too
scripts/setup.sh
stamp_file="$OUT/.ghostty-resources-stamp"
if [[ -f "$stamp_file" && "$(cat "$stamp_file")" == "$(cat .ghostty-build-stamp)" ]]; then
  echo "linux ghostty resources already current"
  exit 0
fi
rm -rf "$OUT/ghostty" "$OUT/terminfo"
# linux ncurses looks an entry up under its first letter, macOS under its hex code
mkdir -p "$OUT/ghostty/shell-integration" "$OUT/terminfo/x" "$OUT/terminfo/g"
for shell in zsh fish bash; do
  cp -R "agterm/Resources/ghostty/shell-integration/$shell" "$OUT/ghostty/shell-integration/$shell"
done
cp agterm/Resources/terminfo/78/xterm-ghostty "$OUT/terminfo/x/xterm-ghostty"
cp agterm/Resources/terminfo/67/ghostty "$OUT/terminfo/g/ghostty"
cp .ghostty-build-stamp "$stamp_file"
echo "linux ghostty resources staged in $OUT"
