---
worth: later
where: scripts/setup.sh:patch_zig_float_h
added: 2026-11-03
---
# move zmx to zig 0.17 and drop the float.h shim

`patch_zig_float_h` rewrites the zig@0.16 keg's bundled `float.h` so zmx's libc++ build sees
`INFINITY`/`NAN` under the macOS 27 SDK. The zig 0.17.0 keg implements `__need_infinity_nan` in its own
`float.h`, so moving `ZMX_ZIG_FORMULA` to
`zig@0.17` lets the shim and its comment go. #883 kept zmx on 0.16 to keep the bump narrow.

It cannot be done at the current `ZMX_REV` (`8bab1f0`, v0.8.1). Tried 2026-11-05 under zig 0.17.1: the
z2d and zf package build files use removed `Build` fields (`install_prefix`, `args`), zmx's pinned ghostty
uses `build_root` and `LazyPath.getPath`, and its `src/build/zig.zig` refuses outright (`does not meet the
required build version of v0.16.0`). Upstream zmx moved to 0.17 on master in `07c89c0d` (2026-10-24,
unreleased at the time) and moved its ghostty dependency to `22f100c`. So this rides the next `ZMX_REV`
bump: all four `scripts/zmx-patches` and `ghostty/0001` have to be re-ported to the new trees, and
`check.py` re-run.

The bump must also add the compiler to `ZMX_STAMP` and to the three CI `Cache zmx` keys, or a stamp and
cache built with 0.16 would be served as current. The stamp is the app's zmx build id, so the bump flags
existing Live sessions as outdated; `da-query-answered-twice-before-attach-init.md` should ship in the same
bump to share that one migration.
