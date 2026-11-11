# libghostty patches

`setup.sh` applies these patches in name order to `GHOSTTY_REV` before building GhosttyKit. The revision and
patch digest form `.ghostty-build-stamp`; CI keys its GhosttyKit cache on both. A changed patch rebuilds the
framework and resources. Never link a staged framework whose full stamp differs.

Each patch is generated against `GHOSTTY_REV` with every lower-numbered patch applied, and is checked with
`git apply --check` on a second pristine checkout carrying those same patches.

## 0001: teardown mailbox drain

`0001` backports the mailbox drain from [ghostty PR 14444](https://github.com/ghostty-org/ghostty/pull/14444)
to `83fb956` (v1.4.0). During surface teardown the main thread joins workers and waits for in-flight Metal
frames. Both workers and frame completion callbacks can block posting to the app mailbox. A temporary
consumer frees queue capacity until `renderer.deinit()` finishes, and preserves other surfaces' messages
for the next app tick. The drain stops after a bounded final pass, filters messages from previous
closes as well as the queue, and releases owned payloads for discarded messages.

Remove the patch when `GHOSTTY_REV` includes an equivalent upstream fix whose drain also stays active
through `renderer.deinit()`. Upstream PR 14444's current ordering does not yet meet that condition.
The patch's own Zig tests pin both regressions it fixes: a worker blocked on the full mailbox during teardown,
and the deferred backlog that a quadratic drain once stalled on. `setup.sh` runs
`zig build test -Dtest-filter=teardown -Demit-macos-app=false` after every libghostty build and stages nothing
when one fails. `scripts/test-surface-teardown.py` closes surfaces in the Release app in CI, one busy title
producer and one of eight idle surfaces, as a smoke of the built framework, failing only on a call unanswered
in 60 s. It has no eight-producer case: on the 3-vCPU runner that case met severe contention and its calls
stalled for seconds to minutes, so the Zig tests are what pin teardown under pressure.

Run `zig fmt --check src/App.zig src/Surface.zig` in the patched checkout when regenerating the patch.
Do not change queue capacity or move `ghostty_surface_free` off the app thread.

## 0002: color scheme report follows the system appearance

`0002` backports the non-GTK part of [ghostty PR 13605](https://github.com/ghostty-org/ghostty/pull/13605)
(issue #939). The pinned core answers `CSI ?996n` and mode 2031 from the config's conditional theme state,
which is tracked only when the light and dark theme names differ, so a single theme always reports light.
The patch keeps the scheme `ghostty_app_set_color_scheme` delivers in an app-level atomic, reports from it,
and pushes the live mode 2031 report through a surface binding action, `system_color_scheme_changed`.
Keep the `App`, `Surface`, `apprt/structs`, `input/Binding`, `input/command` and `termio` hunks together.

Remove the patch when `GHOSTTY_REV` includes PR 13605 or an equivalent upstream fix. The regressions are
`AppearanceFlipUITests.testColorSchemeQueryReportsDarkWithOneThemeForBothAppearances` and
`testColorSchemeSubscriptionReportsAppearanceFlipWithPlainTheme`.

## Removing the last patch

Remove `GHOSTTY_PATCH_DIR`, the digest calculation and apply loop in `setup.sh`, and either set
`GHOSTTY_STAMP="$GHOSTTY_REV"` or restore both the stamp comparison and stamp write to use `GHOSTTY_REV`
directly. Remove the patch digest from the CI cache key too.
