#!/usr/bin/env bash
# Build pinned libghostty and zmx artifacts from upstream source.
#
# We build from source rather than downloading a prebuilt artifact so the toolchain is fully
# self-owned: the inputs are pinned upstream revisions, zig, and Xcode's Metal Toolchain. No fork or
# daily-build release is involved.
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
GHOSTTY_REV="683d8db643b95cf229bfb5fe9fab9ae677920343"  # 2026-08-25
ZMX_REPO="https://github.com/neurosnap/zmx"
ZMX_REV="fb1b6b66476fc83c1453b0cde8fe2a50166eb395"  # 2026-08-28
# ghostty pins minimum_zig_version 0.16.0. Name the MINOR LINE, not `zig`: that one rolls, so a fresh
# build once 0.17 is current would compile a fixed GHOSTTY_REV with a compiler it never supported. Today
# `zig@0.16` is still an alias for `zig`, so this buys nothing yet — it claims the name Homebrew uses when
# it cuts the real versioned formula, as it already has for zig@0.15 and zig@0.14.
ZIG_FORMULA="zig@0.16"  # resolved by prefix, so an unlinked keg works
XCFRAMEWORK_DIR="GhosttyKit.xcframework"
# terminfo/ is the marker: it must extract as a SIBLING of ghostty/ so libghostty's
# TERMINFO=dirname(GHOSTTY_RESOURCES_DIR)/terminfo derivation resolves xterm-ghostty.
RESOURCES_MARKER="agterm/Resources/terminfo"
STAMP_FILE=".ghostty-build-stamp"
ZMX_STAGE_DIR="agterm/Resources/zmx"
ZMX_STAMP_FILE=".zmx-build-stamp"

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
need_zmx=true
[[ -d "$XCFRAMEWORK_DIR" ]] && need_xc=false
[[ -d "$RESOURCES_MARKER" ]] && need_res=false
if [[ -x "$ZMX_STAGE_DIR/zmx" && -f "$ZMX_STAGE_DIR/LICENSE" && -f "$ZMX_STAMP_FILE" ]] &&
   [[ "$(cat "$ZMX_STAMP_FILE")" == "$ZMX_REV" ]]; then
  need_zmx=false
fi

# a stale stamp restages BOTH: they come out of one build, and an artifact built from another revision
# cannot be told apart from a current one.
if [[ ! -f "$STAMP_FILE" || "$(cat "$STAMP_FILE")" != "$GHOSTTY_REV" ]]; then
  need_xc=true
  need_res=true
fi

if ! $need_xc && ! $need_res && ! $need_zmx; then
  echo "GhosttyKit, resources and zmx already present"
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

# Metal Toolchain is needed only when the xcframework build runs.
if { $need_xc || $need_res; } && ! xcrun metal --version >/dev/null 2>&1; then
  echo "downloading Xcode Metal Toolchain (one-time)..."
  xcodebuild -downloadComponent MetalToolchain
fi

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

if $need_xc || $need_res; then
  ghostty_build="$BUILD_DIR/ghostty"
  echo "fetching ghostty $GHOSTTY_REV..."
  git init -q "$ghostty_build"
  git -C "$ghostty_build" remote add origin "$GHOSTTY_REPO"
  git -C "$ghostty_build" fetch -q --depth 1 origin "$GHOSTTY_REV"
  git -C "$ghostty_build" -c advice.detachedHead=false checkout -q FETCH_HEAD

  echo "building GhosttyKit.xcframework with zig (a few minutes)..."
  ( cd "$ghostty_build" && "$ZIG" build -Doptimize=ReleaseFast -Demit-xcframework=true \
      -Dxcframework-target=native -Demit-macos-app=false )

  if $need_xc; then
    echo "staging GhosttyKit.xcframework..."
    rm -rf "$XCFRAMEWORK_DIR"
    cp -R "$ghostty_build/macos/GhosttyKit.xcframework" "$XCFRAMEWORK_DIR"
  fi

  if $need_res; then
    echo "staging ghostty resources..."
    rm -rf agterm/Resources/ghostty agterm/Resources/terminfo
    mkdir -p agterm/Resources/ghostty
    cp -R "$ghostty_build/zig-out/share/ghostty/shell-integration" agterm/Resources/ghostty/
    cp -R "$ghostty_build/zig-out/share/ghostty/themes" agterm/Resources/ghostty/
    cp -R "$ghostty_build/zig-out/share/terminfo" agterm/Resources/terminfo
  fi
  printf '%s\n' "$GHOSTTY_REV" > "$STAMP_FILE"
fi

if $need_zmx; then
  zmx_build="$BUILD_DIR/zmx"
  echo "fetching zmx $ZMX_REV..."
  git init -q "$zmx_build"
  git -C "$zmx_build" remote add origin "$ZMX_REPO"
  git -C "$zmx_build" fetch -q --depth 1 origin "$ZMX_REV"
  git -C "$zmx_build" -c advice.detachedHead=false checkout -q FETCH_HEAD

  echo "building zmx with zig..."
  ( cd "$zmx_build" && "$ZIG" build -Doptimize=ReleaseSafe )
  rm -rf "$ZMX_STAGE_DIR"
  mkdir -p "$ZMX_STAGE_DIR"
  install -m 0755 "$zmx_build/zig-out/bin/zmx" "$ZMX_STAGE_DIR/zmx"
  cp "$zmx_build/LICENSE" "$ZMX_STAGE_DIR/LICENSE"
  printf '%s\n' "$ZMX_REV" > "$ZMX_STAMP_FILE"
fi

stage_custom_themes
echo "setup complete"
