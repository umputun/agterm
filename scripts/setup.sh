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
ZMX_REV="8bab1f0173b07e79835ea372d749af3dbf0d0842"  # v0.8.1, 2026-09-05
# zig defaults to the builder's OS version and CPU; ship the app's arm64/macOS 14 baseline.
ZMX_TARGET="aarch64-macos.14.0"
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
   [[ "$(cat "$ZMX_STAMP_FILE")" == "$ZMX_REV $ZMX_TARGET" ]]; then
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

# The macOS 27 SDK's math.h asks the compiler's float.h for INFINITY/NAN through clang's
# `__need_infinity_nan` protocol (LLVM PR #164348, Apple clang 21). Zig 0.16's bundled float.h does not
# implement it, so compiling zig's libc++ fails with "undeclared identifier 'INFINITY'". Both builds link
# libc++, but libghostty compiles against Ghostty's own apple-sdk math.h overlay and zmx's exported VT
# dependency path does not, which is why only the zmx build needs this. A shim for the two macros, not a
# backport of LLVM 22's header split: remove it once ZIG_FORMULA resolves to a release carrying zig's own
# fix (master has it in 520af696).
SHIM_MARK='Local patch (agterm scripts/setup.sh)'
patch_zig_float_h() {
  local zig_lib float_h source tmp
  zig_lib="$("$ZIG" env | sed -n 's/.*lib_dir"\{0,1\} *[=:] *"\([^"]*\)".*/\1/p')"
  float_h="$zig_lib/include/float.h"
  if [[ ! -f "$float_h" ]]; then
    echo "warning: zig float.h not found at $float_h; skipping __need_infinity_nan shim" >&2
    return 0
  fi
  # upstream's own implementation carries no marker of ours, and must never be replaced by the shim or
  # by a stale backup taken before the keg gained it
  if grep -q '__need_infinity_nan' "$float_h" && ! grep -qF "$SHIM_MARK" "$float_h"; then
    echo "zig float.h implements __need_infinity_nan upstream; no shim needed"
    return 0
  fi
  # both of our markers, so an interrupted run is re-derived rather than mistaken for a finished one
  if grep -qF "$SHIM_MARK" "$float_h" && grep -q '#endif /\* __need_infinity_nan \*/' "$float_h"; then
    echo "zig float.h already carries the __need_infinity_nan shim"
    return 0
  fi
  # only a half-applied shim of ours may fall back to the backup it was taken from
  source="$float_h"
  if grep -qF "$SHIM_MARK" "$float_h" && [[ -f "$float_h.orig" ]]; then
    source="$float_h.orig"
  fi
  tmp="$(mktemp "$float_h.XXXXXX")"
  perl -0pe 's|^#ifndef __CLANG_FLOAT_H\n#define __CLANG_FLOAT_H\n|/* Local patch (agterm scripts/setup.sh): honor the macOS 27 SDK\n * __need_infinity_nan protocol (LLVM PR #164348). */\n#if defined(__need_infinity_nan)\n#  undef INFINITY\n#  undef NAN\n#  define INFINITY (__builtin_inff())\n#  define NAN (__builtin_nanf(""))\n#  undef __need_infinity_nan\n#else\n\n#ifndef __CLANG_FLOAT_H\n#define __CLANG_FLOAT_H\n|m' "$source" > "$tmp"
  printf '#endif /* __need_infinity_nan */\n' >> "$tmp"
  # publish only a header that got the whole transformation: the substitution is silent when the guard
  # lines are spaced differently, and appending the closing #endif alone would corrupt the header
  if ! grep -q '^#if defined(__need_infinity_nan)$' "$tmp" || ! grep -q '^#ifndef __CLANG_FLOAT_H$' "$tmp"; then
    rm -f "$tmp"
    echo "warning: zig float.h not in the expected form; skipping __need_infinity_nan shim" >&2
    return 0
  fi
  chmod u+w "$float_h"
  [[ -f "$float_h.orig" ]] || cp -p "$float_h" "$float_h.orig"
  chmod --reference="$float_h" "$tmp" 2>/dev/null || chmod 0644 "$tmp"
  mv "$tmp" "$float_h"
  echo "shimmed zig float.h for the macOS 27 SDK: $float_h (backup: $float_h.orig)"
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

  patch_zig_float_h

  echo "building zmx with zig..."
  ( cd "$zmx_build" && "$ZIG" build -Doptimize=ReleaseSafe -Dtarget="$ZMX_TARGET" )
  rm -rf "$ZMX_STAGE_DIR"
  mkdir -p "$ZMX_STAGE_DIR"
  install -m 0755 "$zmx_build/zig-out/bin/zmx" "$ZMX_STAGE_DIR/zmx"
  cp "$zmx_build/LICENSE" "$ZMX_STAGE_DIR/LICENSE"
  printf '%s %s\n' "$ZMX_REV" "$ZMX_TARGET" > "$ZMX_STAMP_FILE"
fi

stage_custom_themes
echo "setup complete"
