# libghostty teardown patch

`setup.sh` applies these patches to `GHOSTTY_REV` before building GhosttyKit. The revision and patch
digest form `.ghostty-build-stamp`; CI keys its GhosttyKit cache on both. A changed patch rebuilds the
framework and resources. Never link a staged framework whose full stamp differs.

`0001` backports the mailbox drain from [ghostty PR 14444](https://github.com/ghostty-org/ghostty/pull/14444)
to `83fb956` (v1.4.0). During surface teardown the main thread joins workers and waits for in-flight Metal
frames. Both workers and frame completion callbacks can block posting to the app mailbox. A temporary
consumer frees queue capacity until `renderer.deinit()` finishes, and preserves other surfaces' messages
for the next app tick. The drain stops after a bounded final pass, filters messages from previous
closes as well as the queue, and releases owned payloads for discarded messages.

Remove the patch when `GHOSTTY_REV` includes an equivalent upstream fix whose drain also stays active
through `renderer.deinit()`. Upstream PR 14444's current ordering does not yet meet that condition.
When removing the final patch, remove `GHOSTTY_PATCH_DIR`, the digest calculation and apply loop in
`setup.sh`, and either set `GHOSTTY_STAMP="$GHOSTTY_REV"` or restore both the stamp comparison and stamp write to use
`GHOSTTY_REV` directly. Remove the patch digest from the CI cache key too. Preserve the three shutdown
regressions in `scripts/test-surface-teardown.py`: one title producer, eight title producers with one
closed, and eight idle surfaces with one closed. CI runs them against the Release app.

Apply the patch to a `GHOSTTY_REV` checkout before editing. Run `zig fmt --check src/App.zig src/Surface.zig`
and `zig build test -Dtest-filter=teardown -Demit-macos-app=false` there. Regenerate the patch with
`git diff -- src/App.zig src/Surface.zig` and verify `git apply --check` against a second pristine
checkout. Do not change queue capacity or move `ghostty_surface_free` off the app thread.
