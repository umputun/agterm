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
still open. Tracked in `remove-surface-free-backport-after-ghostty-pin-bump.md`.

The zmx-side patch is fixed at the tag. `scripts/zmx-patches/ghostty/0001` closes the style before a blank
cell is buffered; the tag's page formatter instead steps over same-row blanks with CUF and closes the style
before blanks carried over a wrapped row, and its fast path also uses CUF. Tests "Page VT steps over a gap",
"Page VT unwrap writes blanks before a wrapped wide character" and "Terminal vt restores gaps and cells that
only have a background" cover it. Our patch also resets style in non-VT styled output, which the tag's fix
does not touch; zmx replay uses VT. So a zmx upgrade onto a ghostty at or past the tag can drop that patch
after the Live replay checks pass.

Moving `GHOSTTY_REV` does not move zmx's ghostty, which `setup.sh` fetches from zmx's own pin. The tag needs
`minimum_zig_version` 0.17.0, so zmx onto it rides `move-zmx-to-zig-0-17-to-drop-float-h-shim.md`.

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

Bump when an upstream fix we carry lands (either patch above) or a needed feature appears. The bump then
also re-runs the font-size-increase scrollback check from CLAUDE.md and `scripts/test-surface-teardown.py`.
