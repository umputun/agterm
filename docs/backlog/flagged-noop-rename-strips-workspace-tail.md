---
worth: yes
where: agterm/Views/SidebarRenameController.swift:56
added: 2026-09-04
---
# flagged-mode no-op rename strips the row's ": workspace" tail

`beginEditing` seeds the field with the bare `displayName` so an edit cannot bake the ` : workspace`
decoration into the custom name, and nothing puts the decoration back on its own: `restore(field:kind:)`
resets editability, accessibility id and colors but not the text, and the decorated label is re-rendered
only when a reconcile sees a `RowContent` delta.

Repro: sidebar in flagged mode, a session already custom-named `api`, double-click its row, press Return
without changing the name. `AppStore.renameSession` returns early on an unchanged `customName`, so no
reconcile fires and the row reads `api` where its neighbours read `api : work`. A session with no custom
name reaches the same state by another route: accepting its automatic name sets `customName`, the
reconcile runs, but the `RowContent` label is unchanged so the row is not reloaded either. The row stays
stripped until a badge or status delta or a tree rebuild touches it; a title tick cannot, because the
custom name short-circuits the OSC title in `displayName`. Invisible in tree mode, where the label equals
`displayName`.

Surfaced by the revmux round on the #516 PR A branch, which relabels the row through the same decorated
`content.label` and neither causes nor worsens it. Fix candidates: rewrite the field from the current
`rowLabel` in `restore`, or have the rename-ended path reload the row regardless of the store outcome.
