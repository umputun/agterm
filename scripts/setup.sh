#!/usr/bin/env bash
# Build libghostty (GhosttyKit.xcframework) and ghostty resources from upstream ghostty source.
#
# We build from source rather than downloading a prebuilt artifact so the toolchain is fully
# self-owned: the only inputs are upstream ghostty-org/ghostty at a pinned SHA, zig 0.15.2, and
# Xcode's Metal Toolchain. No third-party fork, no daily-build release that can be pruned.
#
# The pin is DELIBERATELY a pre-regression commit: a libghostty renderer regression introduced on
# main after this SHA blanks the terminal scrollback on a font-size increase.
# Bump GHOSTTY_REV deliberately once upstream fixes that, re-testing the font-increase case.
#
# GhosttyKit.xcframework is built as a UNIVERSAL binary (arm64+x86_64 macOS slice + iOS/iOS-sim
# slices), enabling cross-architecture support with no Intel hardware required for the build.
#
# One-time cost: the build (a few minutes, plus a Metal Toolchain download on first run) is skipped
# whenever GhosttyKit.xcframework and the resources are already present.
set -euo pipefail
cd "$(dirname "$0")/.."

GHOSTTY_REPO="https://github.com/ghostty-org/ghostty"
GHOSTTY_REV="4dcb09ada0c0909717d92547623b26eafa50ca8a"  # 2026-04-30, last pre-regression build we verified
ZIG_FORMULA="zig@0.15"  # ghostty pins minimum_zig_version 0.15.2; keg-only so it won't shadow system zig
XCFRAMEWORK_DIR="GhosttyKit.xcframework"
# terminfo/ is the marker: it must extract as a SIBLING of ghostty/ so libghostty's
# TERMINFO=dirname(GHOSTTY_RESOURCES_DIR)/terminfo derivation resolves xterm-ghostty.
RESOURCES_MARKER="agterm/Resources/terminfo"

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

if ! $need_xc && ! $need_res; then
  echo "GhosttyKit and resources already present"
  stage_custom_themes
  exit 0
fi

# zig 0.15.2 (keg-only formula, so it doesn't shadow a newer system zig)
ZIG="$(brew --prefix "$ZIG_FORMULA" 2>/dev/null || true)/bin/zig"
if [[ ! -x "$ZIG" ]]; then
  echo "installing $ZIG_FORMULA (zig 0.15.2)..."
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

echo "building GhosttyKit.xcframework with zig 0.15.2 (a few minutes)..."
( cd "$BUILD_DIR" && "$ZIG" build -Doptimize=ReleaseFast -Demit-xcframework=true -Demit-macos-app=false )

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
echo "setup complete"
