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

Cost: zmx and its patched ghostty dependency (`scripts/zmx-patches/0002`) have to build under 0.17,
which is a cold build. Neither `ZMX_STAMP` nor the three CI `Cache zmx` keys record the compiler, so the
change must add it to both, or a stamp and cache built with 0.16 would be served as current.
