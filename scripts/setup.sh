#!/usr/bin/env bash
# Build pinned libghostty and zmx artifacts from upstream source.
#
# We build from source rather than downloading a prebuilt artifact so the toolchain is fully
# self-owned: pinned upstream revisions, local patches, zig, and Xcode's Metal Toolchain.
#
# GHOSTTY_REV selects the upstream commit; local patches are applied after checkout. It was held at a
# 2026-04-30 pre-regression commit while later builds blanked the scrollback on a font-size increase; that is
# fixed upstream and re-verified by hand before this bump. Re-test the font-increase case when moving
# it, and check `minimum_zig_version` in build.zig.zon against ZIG_FORMULA.
#
# One-time cost: the build (a few minutes, plus a Metal Toolchain download on first run) is skipped
# whenever the staged artifacts match the current revision and patch digest. Presence alone is not
# enough — the stamp, not the directory, determines whether the staged artifacts can be reused.
set -euo pipefail
cd "$(dirname "$0")/.."

GHOSTTY_REPO="https://github.com/ghostty-org/ghostty"
GHOSTTY_REV="83fb95624b0439ee660c2679b43b38c8b63769cd"  # v1.4.0, 2026-10-27
ZMX_REPO="https://github.com/neurosnap/zmx"
ZMX_REV="a35f00a2118b15a5e9d522a43035c8d7487df9b7"  # v1.0.1, 2026-11-06; SessionHostRuntime/DeviceAttributeResponder.swift copies its DA replies
# zig defaults to the builder's OS version and CPU; ship the app's arm64/macOS 14 baseline.
ZMX_TARGET="aarch64-macos.14.0"
# setup-zmx-linux.sh builds the same pin for a Linux target into its own stage dir and stamp. Unquoted, so
# CI's `^ZMX_TARGET="` read of the line above matches it alone.
ZMX_TARGET=${AGTERM_ZMX_TARGET:-$ZMX_TARGET}
# Pin the Homebrew minor line and the Linux CI release.
ZIG_FORMULA="zig@0.17"
ZIG_LINUX_VERSION="0.17.1"
XCFRAMEWORK_DIR="GhosttyKit.xcframework"
# terminfo/ is the marker: it must extract as a SIBLING of ghostty/ so libghostty's
# TERMINFO=dirname(GHOSTTY_RESOURCES_DIR)/terminfo derivation resolves xterm-ghostty.
RESOURCES_MARKER="agterm/Resources/terminfo"
STAMP_FILE=".ghostty-build-stamp"
GHOSTTY_PATCH_DIR="scripts/ghostty-patches"
GHOSTTY_PATCH_DIGEST="$(cat "$GHOSTTY_PATCH_DIR"/*.patch | shasum -a 256 | cut -c1-16)"
GHOSTTY_STAMP="$GHOSTTY_REV $GHOSTTY_PATCH_DIGEST"
ZMX_STAGE_DIR="${AGTERM_ZMX_STAGE_DIR:-agterm/Resources/zmx}"
ZMX_STAMP_FILE="${AGTERM_ZMX_STAMP_FILE:-.zmx-build-stamp}"
# applied in name order over the plain pin; scripts/zmx-patches/README.md says what each one is for.
# The stamp carries their digest, so editing a patch rebuilds zmx exactly as a ZMX_REV change does.
ZMX_PATCH_DIR="scripts/zmx-patches"
ZMX_PATCH_DIGEST="$(cat "$ZMX_PATCH_DIR"/*.patch | shasum -a 256 | cut -c1-16)"
ZMX_COMPILER="$ZIG_FORMULA"
if [[ -n "${AGTERM_ZMX_ZIG:-}" ]]; then
  ZMX_COMPILER="$("$AGTERM_ZMX_ZIG" version)"
fi
ZMX_STAMP="$ZMX_REV $ZMX_TARGET $ZMX_COMPILER $ZMX_PATCH_DIGEST"

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
   [[ "$(cat "$ZMX_STAMP_FILE")" == "$ZMX_STAMP" ]]; then
  need_zmx=false
fi

# a stale stamp restages BOTH: they come out of one build, and an artifact built from another revision
# cannot be told apart from a current one.
if [[ ! -f "$STAMP_FILE" || "$(cat "$STAMP_FILE")" != "$GHOSTTY_STAMP" ]]; then
  need_xc=true
  need_res=true
fi

# --zmx-only serves CI's Unit tests job, whose session-host fixtures need zmx and nothing from libghostty.
# It overrides the stale-stamp check above, so a libghostty pin change cannot pull Metal or a ghostty build in.
case "${1:-}" in
  "") ;;
  --zmx-only) need_xc=false; need_res=false ;;
  *) echo "usage: $0 [--zmx-only]" >&2; exit 2 ;;
esac

if ! $need_xc && ! $need_res && ! $need_zmx; then
  echo "staged artifacts already current"
  stage_custom_themes
  exit 0
fi

# Resolve the Homebrew keg directly so the user's PATH can still point at a different Zig.
# Linux CI passes its unpacked compiler for the zmx build.
zig_for() {
  local zig="${1:-}" want="${ZIG_FORMULA#zig@}" ver
  if [[ -z "$zig" ]]; then
    zig="$(brew --prefix "$ZIG_FORMULA" 2>/dev/null || true)/bin/zig"
    if [[ ! -x "$zig" ]]; then
      echo "installing $ZIG_FORMULA..." >&2
      brew install "$ZIG_FORMULA" >&2 || return 1
      zig="$(brew --prefix "$ZIG_FORMULA")/bin/zig" || return 1
    fi
  fi
  ver="$("$zig" version)" || return 1
  if [[ "$ver" != "$want".* ]]; then
    echo "error: $zig is zig $ver, need $want" >&2
    return 1
  fi
  printf '%s\n' "$zig"
}

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

  for ghostty_patch in "$GHOSTTY_PATCH_DIR"/*.patch; do
    echo "applying libghostty/$(basename "$ghostty_patch")..."
    git -C "$ghostty_build" apply --whitespace=nowarn "$PWD/$ghostty_patch"
  done

  GHOSTTY_ZIG="$(zig_for)"
  echo "building GhosttyKit.xcframework with zig (a few minutes)..."
  ( cd "$ghostty_build" && "$GHOSTTY_ZIG" build -Doptimize=ReleaseFast -Demit-xcframework=true \
      -Dxcframework-target=native -Demit-macos-app=false )
  # before staging, so a red test never leaves artifacts under a stamp that marks them current
  echo "testing the libghostty patches..."
  ( cd "$ghostty_build" && "$GHOSTTY_ZIG" build test -Dtest-filter=teardown -Dtest-filter="url regex" \
      -Dtest-filter="agterm session link" -Demit-macos-app=false )

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
  printf '%s\n' "$GHOSTTY_STAMP" > "$STAMP_FILE"
fi

if $need_zmx; then
  zmx_build="$BUILD_DIR/zmx"
  echo "fetching zmx $ZMX_REV..."
  git init -q "$zmx_build"
  git -C "$zmx_build" remote add origin "$ZMX_REPO"
  git -C "$zmx_build" fetch -q --depth 1 origin "$ZMX_REV"
  git -C "$zmx_build" -c advice.detachedHead=false checkout -q FETCH_HEAD

  for zmx_patch in "$ZMX_PATCH_DIR"/*.patch; do
    echo "applying $(basename "$zmx_patch")..."
    git -C "$zmx_build" apply --whitespace=nowarn "$PWD/$zmx_patch"
  done

  ZMX_ZIG="$(zig_for "${AGTERM_ZMX_ZIG:-}")"

  echo "building zmx with zig..."
  ( cd "$zmx_build" && "$ZMX_ZIG" build -Doptimize=ReleaseSafe -Dtarget="$ZMX_TARGET" )
  echo "testing the zmx patches..."
  ( cd "$zmx_build" && "$ZMX_ZIG" build test )
  rm -rf "$ZMX_STAGE_DIR"
  mkdir -p "$ZMX_STAGE_DIR"
  install -m 0755 "$zmx_build/zig-out/bin/zmx" "$ZMX_STAGE_DIR/zmx"
  cp "$zmx_build/LICENSE" "$ZMX_STAGE_DIR/LICENSE"
  printf '%s\n' "$ZMX_STAMP" > "$ZMX_STAMP_FILE"
fi

stage_custom_themes
echo "setup complete"
