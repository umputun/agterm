---
worth: yes
where: site/docs.html#ghostty
added: 2026-11-09
---
# ghostty.conf global keybinds and toggle_visibility do nothing, with no word in the docs

A `keybind = global:...` line in agterm's `ghostty.conf` parses clean on `config reload` and then never
fires: the Ghostty app installs its own event tap for `global:` binds
(`macos/Sources/Features/Global Keybinds/GlobalEventTap.swift` upstream), and agterm installs none.
`toggle_visibility` is an action libghostty hands to the host, and `GhosttyCallbacks.action` has no case
for it. A Ghostty user moving over tries this first and gets silence, as in
https://github.com/umputun/agterm/discussions/943.

One sentence in the ghostty section of `site/docs.html` closes it: both are Ghostty-app features agterm
does not host, and `global-hotkey` in `keymap.conf` is the system-wide chord agterm registers.
