#!/usr/bin/env bash
# Build libghostty (GhosttyKit.xcframework) and ghostty resources from upstream ghostty source.
#
# We build from source rather than downloading a prebuilt artifact so the toolchain is fully
# self-owned: the only inputs are upstream ghostty-org/ghostty at a pinned SHA, zig, and Xcode's
# Metal Toolchain. No third-party fork, no daily-build release that can be pruned.
#
# GHOSTTY_REV is a plain pin for reproducibility, not a workaround. It was held at a 2026-04-30
# pre-regression commit while later builds blanked the scrollback on a font-size increase; that is
# fixed upstream and re-verified by hand before this bump. Re-test the font-increase case when moving
# it, and check `minimum_zig_version` in build.zig.zon against ZIG_FORMULA.
#
# One-time cost: the build (a few minutes, plus a Metal Toolchain download on first run) is skipped
# whenever the staged artifacts match the current rev. Presence alone is not enough — an xcframework
# built from a different rev is indistinguishable from a current one, so the stamp, not the directory,
# is what says a rebuild can be skipped.
set -euo pipefail
cd "$(dirname "$0")/.."

GHOSTTY_REPO="https://github.com/ghostty-org/ghostty"
GHOSTTY_REV="0ba6250388641f52135414b38c4259aa682c489b"  # 2026-08-16
ZIG_FORMULA="zig"  # ghostty pins minimum_zig_version 0.16.0; resolved by prefix, so an unlinked keg works
XCFRAMEWORK_DIR="GhosttyKit.xcframework"
# terminfo/ is the marker: it must extract as a SIBLING of ghostty/ so libghostty's
# TERMINFO=dirname(GHOSTTY_RESOURCES_DIR)/terminfo derivation resolves xterm-ghostty.
RESOURCES_MARKER="agterm/Resources/terminfo"
STAMP_FILE=".ghostty-build-stamp"

# stage agterm's own bundled theme(s) from the committed source into the (gitignored,
# setup-regenerated) ghostty themes dir. idempotent and called on both the cached and the
# fresh-build path so the theme survives a themes-dir wipe and shows in the Appearance picker.
stage_custom_themes() {
  local dst="agterm/Resources/ghostty/themes"
  [[ -d "$dst" ]] || return 0
  cp agterm/Resources/custom-themes/* "$dst/"
}

need_xc=true
need_res=true
[[ -d "$XCFRAMEWORK_DIR" ]] && need_xc=false
[[ -d "$RESOURCES_MARKER" ]] && need_res=false

# a stale stamp restages BOTH: they come out of one build, and the artifact that carries the patch
# cannot be told apart from the one that does not.
if [[ ! -f "$STAMP_FILE" || "$(cat "$STAMP_FILE")" != "$GHOSTTY_REV" ]]; then
  need_xc=true
  need_res=true
fi

if ! $need_xc && ! $need_res; then
  echo "GhosttyKit and resources already present"
  stage_custom_themes
  exit 0
fi

# resolved through the keg prefix rather than PATH, so a machine still linking an older zig for another
# project builds with the right one and keeps its own `zig` untouched.
ZIG="$(brew --prefix "$ZIG_FORMULA" 2>/dev/null || true)/bin/zig"
if [[ ! -x "$ZIG" ]]; then
  echo "installing $ZIG_FORMULA..."
  brew install "$ZIG_FORMULA"
  ZIG="$(brew --prefix "$ZIG_FORMULA")/bin/zig"
fi

# Metal Toolchain — the xcframework build compiles ghostty's Metal shaders
if ! xcrun metal --version >/dev/null 2>&1; then
  echo "downloading Xcode Metal Toolchain (one-time)..."
  xcodebuild -downloadComponent MetalToolchain
fi

# fetch ghostty at the pinned commit (shallow, single commit, no submodules — not needed here)
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT
echo "fetching ghostty $GHOSTTY_REV..."
git init -q "$BUILD_DIR"
git -C "$BUILD_DIR" remote add origin "$GHOSTTY_REPO"
git -C "$BUILD_DIR" fetch -q --depth 1 origin "$GHOSTTY_REV"
git -C "$BUILD_DIR" -c advice.detachedHead=false checkout -q FETCH_HEAD

echo "building GhosttyKit.xcframework with zig (a few minutes)..."
( cd "$BUILD_DIR" && "$ZIG" build -Doptimize=ReleaseFast -Demit-xcframework=true -Dxcframework-target=native -Demit-macos-app=false )

if $need_xc; then
  echo "staging GhosttyKit.xcframework..."
  rm -rf "$XCFRAMEWORK_DIR"
  cp -R "$BUILD_DIR/macos/GhosttyKit.xcframework" "$XCFRAMEWORK_DIR"
fi

if $need_res; then
  echo "staging ghostty resources..."
  rm -rf agterm/Resources/ghostty agterm/Resources/terminfo
  mkdir -p agterm/Resources/ghostty
  cp -R "$BUILD_DIR/zig-out/share/ghostty/shell-integration" agterm/Resources/ghostty/
  cp -R "$BUILD_DIR/zig-out/share/ghostty/themes" agterm/Resources/ghostty/
  cp -R "$BUILD_DIR/zig-out/share/terminfo" agterm/Resources/terminfo
fi

stage_custom_themes
printf '%s\n' "$GHOSTTY_REV" > "$STAMP_FILE"
echo "setup complete"
