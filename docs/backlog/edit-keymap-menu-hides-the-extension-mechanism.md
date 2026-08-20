---
worth: later
where: agterm/agtermApp+Menus.swift
added: 2026-08-20
---
# File ▸ Edit Keymap… does not read as "add features"

The seeded `keymap.conf` is the best explanation of custom commands anywhere in the project. It documents
the `command` directive, the detached-no-TTY limit, the PATH rule, the context tokens, and ships the
`agtermctl session overlay open 'zsh -lc lazygit'` pattern (`agtermCore/Sources/agtermCore/ConfigPaths.swift:39-116`).
It is better than the public docs were before the `#extend` lesson, and a user reaches it only by opening
a menu item named after key configuration.

Both menu entries name the mechanism rather than what it is for: `File ▸ Edit Keymap…` and
`Navigate ▸ Custom Commands`. A user looking for a file browser has no reason to open either. The docs
side of this is fixed (the lesson, the nav rename, the screenshot captions); the in-app affordance is not.

Worth considering, none of it obviously right: wording that advertises extension rather than
configuration, a Help entry that points at the lesson, or seeding the palette with one commented example
so `Custom Commands` is not empty on a fresh install. All of it is AppKit/menu work whose cost should be
priced on its own, which is why it was kept out of the docs change.

Surfaced while brainstorming the onboarding gap after a new user asked whether agterm has a file browser
and the answer turned out to be one keymap line.
