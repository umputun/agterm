---
worth: yes
where: scripts/ghostty-patches
added: 2026-11-10
---
# drop ghostty patch 0002 once upstream ships the color scheme fix

`scripts/ghostty-patches/0002-report-system-color-scheme.patch` carries the core of
https://github.com/ghostty-org/ghostty/pull/13605 so `CSI ?996n` and mode 2031 report the macOS appearance
with a single theme (https://github.com/umputun/agterm/issues/939). The PR was open, approved, and unmerged
on 2026-11-10.

When a `GHOSTTY_REV` bump includes that PR or an equivalent fix, delete the patch, follow the removal
steps in `scripts/ghostty-patches/README.md`, and keep the two `AppearanceFlipUITests` color scheme
regressions passing on the bumped pin.
