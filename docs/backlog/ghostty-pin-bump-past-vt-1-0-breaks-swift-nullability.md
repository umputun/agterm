---
worth: later
where: agterm/Ghostty/GhosttyCallbacks.swift
added: 2026-11-06
---
# ghostty pin bump past vt-1.0.0 breaks the Swift bridge on nullability

Upstream tagged `vt-1.0.0` ("libghostty-vt 1.0.0", commit `0fa3d577`) on 2026-11-06, 266 commits past our
`GHOSTTY_REV` (`83fb956`, v1.4.0) with nothing behind. There is no reason to bump to it yet, and the next
bump has a known Swift cost.

**What v1 covers.** `dist/doxygen/pages/stability.md` promises a stable C ABI for libghostty-vt only, the
`include/ghostty/vt*.h` headers: a 1.x minor release only adds functions, types, enum values and trailing
fields of sized structs, and snapshot bytes are excluded. `include/ghostty.h`, the app/surface/config API
agterm links through GhosttyKit, now heads itself "libghostty-internal", meant only for the macOS app, so it
keeps changing without notice. zmx imports ghostty as a Zig module, which the C ABI promise does not cover
either.

**Why wait.** The app-side patch is not fixed at the tag: `scripts/ghostty-patches/0001` is still needed
because `Surface.deinit` stops and joins the renderer and io threads with no mailbox drain, and PR 14444 is
still open. `scripts/ghostty-patches/README.md` holds each patch's removal condition and its regressions.

zmx v1.0.1 already pins a newer Ghostty that steps over same-row blanks and closes the style before
blanks carried over a wrapped row. The Live replay check covers this behavior. Changing `GHOSTTY_REV`
updates GhosttyKit and its resources. zmx gets its Ghostty dependency from its own build manifest.

**The Swift cost.** Between the pin and the tag, ghostty.h gained `#pragma clang assume_nonnull` plus
`GHOSTTY_NULLABLE` / `GHOSTTY_NULL_UNSPECIFIED` markings. Pointers imported as implicitly unwrapped become
plain or Optional, so these sites stop compiling (read statically against the tag header, not built):

- `GhosttyCallbacks.action`: `if let`/`guard let` on now non-null `pwd.pwd`, `set_title.title`,
  `open_url.url`, `config_change.config`; `.flatMap` on `desktop_notification.title`/`body` and
  `start_search.needle`.
- `GhosttyApp`'s diagnostics loop: `if let msg = diag.message`.
- Clipboard: `guard let mime = item.mime` in the write and confirm-read paths, `if let mime` over
  `available`; `ClipboardRead.mimes` and `cAvailable` use `UnsafePointer<CChar>?` elements where the
  header now gives non-null elements; request `state` is carried as `UnsafeMutableRawPointer?` through
  `ClipboardRead`, the deny helper and the completion helper into `ghostty_surface_complete_clipboard_request`
  / `deny_clipboard_request`, which now take it non-null.

Fields now marked nullable (surface config `nsview`, `userdata`, `working_directory`, `command`,
`env_vars`, `initial_input`) still accept our assignments. `ghostty_text_s.text` is `_Null_unspecified`, so
its guards stay valid. The new `GHOSTTY_ACTION_SET_WINDOW_THEME` falls through the action switch's `default`.

Bump when an upstream fix we carry lands (patch `0001`, or `0002` with ghostty PR 13605) or a needed feature
appears. The bump then also re-runs the font-size-increase scrollback check from CLAUDE.md and
`scripts/test-surface-teardown.py`.
