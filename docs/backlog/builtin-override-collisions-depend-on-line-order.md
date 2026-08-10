---
worth: later
where: agtermCore/Sources/agtermCore/Keymap.swift:141
added: 2026-08-10
---
# swapping two colliding `map` lines can drop an unrelated custom command's shortcut

`resolveBuiltinOverrides` folds `map` lines last-wins per action, then iterates `firstBuiltinCollision` to a
fixpoint. A dropped override reverts the action to its shipped `defaultChord`, and that revived default can
then collide with something else. Which of two overrides gets dropped is decided by file order, so the
built-in chord set the later passes see depends on line order — and `validateBindings` computes a custom
command's shadowing against exactly that set.

Reproduced on master, with no `|` and no alternatives involved:

```
map cmd+shift+x toggle_split
map cmd+shift+x new_session
command "C" cmd+d echo c
```

`C` keeps `cmd+d` in this order. Reverse the two `map` lines and `C` loses its shortcut and becomes
palette-only, because `toggle_split` then reverts to its shipped `cmd+d` and shadows it. The user changed
nothing but the order of two lines that have nothing to do with `C`.

Surfaced by an external review of the keybind-alternatives branch, which verified it against master rather
than the branch: the alternatives work made conflict resolution order-independent within its own two passes,
and that made the surviving upstream asymmetry visible by contrast. It is not a regression — the last-wins
fold, the fixpoint, and the revert-to-default step are all unchanged upstream behaviour.

Left alone deliberately. Fixing it changes which chord wins for existing `keymap.conf` files that never used
alternatives, so it wants its own decision rather than riding along on a feature branch. The shape of a fix
is the same principle already applied one layer down: settle the override set once against the shipped
defaults instead of iterating over a set the drops keep mutating. Note that a fix must keep the diagnostics
byte-identical for configs with no collision at all, which `KeymapTests.pipeFreeKeymapParsesExactlyAsItDidBeforeAlternatives`
already pins.
