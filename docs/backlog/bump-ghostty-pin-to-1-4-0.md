---
worth: yes
where: scripts/setup.sh
added: 2026-10-27
---
# bump GHOSTTY_REV to ghostty 1.4.0

Ghostty 1.4.0 (`v1.4.0`, `83fb956`) requires zig 0.17. `zig@0.17` exists as an alias of the rolling `zig`
formula and resolves to 0.17.0, the same alias phase `ZIG_FORMULA` was set in for 0.16, so nothing blocks
the bump.

The scrollback compression, 50 MB default limit, reflow and throughput work is already in `683d8db`.
The bump adds the fixed-memory trims (ghostty PRs 14130, 14137, 14138) and the idle display-link pause
(14035), which the embedded build reaches.

Cost:

- `ZIG_FORMULA` also builds zmx, which has its own patched ghostty dependency (`zmx-patches/0002`).
  Keeping zmx on `zig@0.16` is the narrow route and needs no zmx stamp or cache change. Moving it to 0.17
  needs a cold build, and since neither `ZMX_STAMP` nor the three CI zmx cache keys record the compiler,
  all of them invalidated. `patch_zig_float_h` runs against whichever compiler zmx uses.
- `scripts/ghostty-patches/0001` no longer applies to v1.4.0 (`src/App.zig`, `src/Surface.zig`). Rebase it
  to the acceptance conditions in its README, unless PR 14444 has landed in the form
  `remove-surface-free-backport-after-ghostty-pin-bump.md` requires.
- Re-test the rendering contracts in `.claude/rules/libghostty.md`, the font-size-increase scrollback
  case, and the `ghostty.h` check that `program-status-waits-on-an-upstream-app-action.md` asks for.
