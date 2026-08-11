---
worth: later
where: agterm/AppActions+Focus.swift:146
added: 2026-08-11
---
# focusSplitPane moves first responder into a session that is not selected

`focusSplitPane` gates on terminal zoom, the dashboard, a pending picker, inline rename, an open palette
and the quick terminal, but never on `store.selectedSessionID`. `detailPane` mounts every session and only
gives the non-selected ones `.opacity(0)` / `.allowsHitTesting(false)`
(`agterm/Views/WindowContentView+Detail.swift:18-23`), so a background session's surface still has a
non-nil `window` and still accepts first responder. A control command addressing a background session
therefore calls `makeFirstResponder` on a session the user cannot see, and typing meant for the visible
one lands in the hidden one.

`TerminalView.updateNSView` resigns an inactive pane's first responder (`agterm/Views/TerminalView.swift:63-70`),
but only on a render pass, while `focusSplitPane` re-asserts 12 times at 30ms with nothing re-rendering the
background entry after the first — so the retry loop wins.

Three call sites share the assumption, so the guard belongs inside the helper rather than at one of them:

- `ControlServer+SessionActions.swift:268` — `splitSession`
- `ControlServer+SessionActions.swift:287` — `closeSessionSplit`
- `AppActions.setSplitFocus`, behind `session.focus`

Surfaced by the codex peer reviewing the Close Split branch (#404). Deferred there because guarding only
the new arm would make `session.split.close` diverge from `session.split` beside it, and changing the
helper changes background-target behavior for all three commands at once.
