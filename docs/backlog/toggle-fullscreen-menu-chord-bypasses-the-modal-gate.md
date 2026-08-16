---
worth: later
where: agterm/Commands/CustomCommandRunner.swift:132
added: 2026-08-10
---
# toggle_fullscreen's menu chord runs ungated while its own alternatives do not

`toggle_fullscreen` is the one built-in with no SwiftUI menu item to carry a key equivalent: AppKit appends
the only full screen item there is as the View menu is prepared, so an item of agterm's own beside it would
be a visible duplicate. Its resolved chord is therefore matched inside `handleKeyDown(_:in:)`, ahead of the
matcher, and calls `keyWindow.toggleFullScreen(nil)` directly.

Since bind alternatives landed, the same `map` line can carry more bindings for the same action, and those
take the ordinary route: the matcher reports `.firedBuiltin` and `AppActions.perform(_:in:)` runs the
`PaletteCommand` row behind `isEnabled(in:)`, which carries the modal rule of the row's MENU item.
`toggle_fullscreen` has no menu item to supply one, so it falls to the predicate's default arm, the whole
modal cover — deliberately, since making it an exception would settle this item rather than record it. So
`map ctrl+cmd+f|ctrl+a>f toggle_fullscreen` gives one action two
dispatch paths with two different gating rules: with a picker or another modal pending, `ctrl+a>f` no-ops
and `ctrl+cmd+f` still toggles.

Nobody has reported it, and the divergence favours the safer direction for the chord users actually press —
full screen is not destructive and the gate exists to stop palette actions racing a modal, not to stop
window management.

Collapsing it means deleting the special case and letting `toggle_fullscreen` be an ordinary built-in bind:
the menu chord would have to move from the menu path onto `builtinSequences` for this action alone, which
today is exactly the set of binds the menu CANNOT carry, so `Keymap` would grow a third state ("no menu item
exists for this action" as distinct from "menu-bound" and "explicitly unbound") and `resolveBuiltinOverrides`
would need to stop treating its chord as a menu chord while `validateBindings` starts treating it as a
monitor one. `keymap list`'s `chord`/`alternates` split and `overridden` follow from that same distinction,
so the control read-back moves with it. Deliberately left out of the alternatives plan
(`docs/plans/20260810-keymap-bind-alternatives.md`, Post-Completion) for that reason.

Worth doing only if a second action ever ends up without a menu item, which would make the third state pay
for itself, or if the gating difference is actually hit.

`undo_close` was recorded here on 2026-08-12 as sharing the divergence. It does not, and the claim was
withdrawn on 2026-08-16: `UndoCloseShortcut.handleKeyDown` is gated only on a pending close and text-field
focus, but the `AppActions.undoClose()` it calls opens with `guard uiActionsEnabled`, whose three terms are
`PaletteContext.modalActive`'s. Both dispatch paths therefore no-op behind a cover, and the chord is
consumed either way. `toggle_fullscreen` is alone here because it calls `keyWindow.toggleFullScreen(nil)`
rather than an `AppActions` method carrying the gate.
