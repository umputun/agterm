---
worth: later
where: agterm/AppActions+Palette.swift:paletteActions
added: 2026-10-28
---
# palette Move Session rows act on a stale selection

`paletteActions` builds the "Move Session to …" rows with `store.selectedSessionID` captured when the list
is built. `CommandPalette` refreshes its rows only on appear, query and mode, so a selection change while
the palette is open (a control `session.select`, or the session closing) leaves Return moving the session
that was selected at open, or doing nothing while the row stays enabled and closes the palette. That breaks
the menu-actions rule that a row's `isEnabled` reads live state. The fix is to read the selection when the
row runs and in its `isEnabled`, as the "Tint Session" rows do. Rare trigger, easy to undo.
