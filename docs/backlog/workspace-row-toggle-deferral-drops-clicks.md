---
worth: later
where: agterm/Views/WorkspaceSidebar+ContextMenu.swift:15
added: 2026-08-09
---
# the deferred workspace-row toggle drops one click and fires another under the wrong row

`handleSingleClick` parks the toggle in a single `pendingRowToggle` slot for `NSEvent.doubleClickInterval`
so a rename double-click can cancel it. Two consequences fall out of the guard ordering, both reachable
with ordinary clicking:

- **A click on a second workspace row eats the first.** The `pendingRowToggle?.cancel()` at line 28 is
  unconditional and the slot holds one item, so clicking workspace A's row and then workspace B's inside
  the interval cancels A and toggles only B. A's click is gone with nothing on screen to say so.
- **A session-row click does not disarm a pending workspace toggle.** The guard at lines 17-18 returns for
  `node.kind == .session` before reaching that cancel, so clicking workspace A and then a session in
  another workspace selects the session immediately and then, a beat later, expands A underneath it and
  shifts every row below.

Both are worse than they look because a workspace row is not selectable
(`WorkspaceSidebar+RowRendering.swift:15-18` returns `shouldSelectItem` only for sessions), so the whole
deferral window carries no feedback at all - no pill, no press state, no disclosure movement. The click
reads as dropped either way.

Three approaches were weighed and none taken: drop double-click rename on workspace rows (rejected -
double-click rename is the discoverable path and the macOS convention, whatever the other entry points);
toggle optimistically and invert on double-click (rejected - trades a dead pause for a visible flicker on
rename); and keep the deferral but add press feedback (rejected - a custom-drawn disclosure triangle or a
transient row pill is too much machinery for the size of the defect). Revisit only if the delay starts
costing more than it looks like it does.

Not fixed alongside #407's animation because the fix is a behavior decision, not a rendering one. #407
itself names the two candidates for the delay - toggle optimistically and reverse on a double-click, or
move workspace rename off double-click - and either would settle these two as a side effect, while
patching them in isolation (per-node pending toggles, or hoisting the cancel above the guards) preserves
a half-second of silent latency that is itself the complaint.

Worth weighing that workspace rename already has five other entry points - the row context menu, the File
menu's Workspace section, the `rename_workspace` built-in, the command palette, and `workspace.rename` -
so the deferral protects a sixth path to something already well covered.
