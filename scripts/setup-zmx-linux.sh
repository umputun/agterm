#!/usr/bin/env bash
# linux artifacts for agterm-server under build/linux, from the pins setup.sh holds: the patched zmx per
# architecture (musl), ghostty's zsh, fish and bash integration at GHOSTTY_REV, and its terminfo.
# --shell-integration stages only the integration, which needs no zig or Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="build/linux"

# ghostty's build installs src/shell-integration verbatim, so the source at the pin is the shipped set; the Mac
# staging is not used for it because its stamp can claim a rev its files never came from
stage_shell_integration() {
  local rev stamp_file="$OUT/.shell-integration-stamp" work
  rev="$(sed -nE 's/^GHOSTTY_REV="([^"]+)".*/\1/p' scripts/setup.sh)"
  if [[ -f "$stamp_file" && "$(cat "$stamp_file")" == "$rev" ]]; then
    echo "linux shell integration already current"
    return 0
  fi
  work="$(mktemp -d)"
  curl -fsSL "https://codeload.github.com/ghostty-org/ghostty/tar.gz/$rev" \
    | tar -xz -C "$work" "ghostty-$rev/src/shell-integration"
  rm -rf "$OUT/ghostty"
  mkdir -p "$OUT/ghostty/shell-integration"
  for shell in zsh fish bash; do
    cp -R "$work/ghostty-$rev/src/shell-integration/$shell" "$OUT/ghostty/shell-integration/$shell"
  done
  rm -rf "$work"
  echo "$rev" >"$stamp_file"
  echo "linux shell integration staged in $OUT at $rev"
}

if [[ "${1:-}" == --shell-integration ]]; then
  stage_shell_integration
  exit 0
fi

for arch in aarch64 x86_64; do
  AGTERM_ZMX_TARGET="$arch-linux-musl" \
    AGTERM_ZMX_STAGE_DIR="$OUT/$arch/zmx" \
    AGTERM_ZMX_STAMP_FILE="$OUT/$arch/.zmx-build-stamp" \
    scripts/setup.sh --zmx-only
done
stage_shell_integration

# terminfo is compiled by ghostty's build, so it comes from the Mac's libghostty staging and that stamp
scripts/setup.sh
stamp_file="$OUT/.ghostty-resources-stamp"
if [[ -f "$stamp_file" && "$(cat "$stamp_file")" == "$(cat .ghostty-build-stamp)" ]]; then
  echo "linux terminfo already current"
  exit 0
fi
rm -rf "$OUT/terminfo"
# linux ncurses looks an entry up under its first letter, macOS under its hex code
mkdir -p "$OUT/terminfo/x" "$OUT/terminfo/g"
cp agterm/Resources/terminfo/78/xterm-ghostty "$OUT/terminfo/x/xterm-ghostty"
cp agterm/Resources/terminfo/67/ghostty "$OUT/terminfo/g/ghostty"
cp .ghostty-build-stamp "$stamp_file"
echo "linux terminfo staged in $OUT"
