---
worth: yes
where: agterm/Views/WindowControlArea.swift:WindowControlArea
added: 2026-11-02
---
# the titlebar drag contract omits the hit-testable shape that keeps the header out of the drag region

#869 made `WindowControlArea` put `Color.clear.contentShape(Rectangle())` behind its AppKit view, because
SwiftUI leaves non-hit-testable content in the window server's title-bar drag region and ignores
`mouseDownCanMoveWindow` there. Without the shape the server starts its own drag in the top 32pt strip,
`performDrag` follows, and on macOS 27.2 the window jumps off the pointer (#856).

Two places still describe the old mechanism:

- the type doc opens "A transparent AppKit layer" and credits `mouseDownCanMoveWindow` with keeping AppKit's
  automatic move away, in tension with the inline comment on the shape;
- `.claude/rules/windows.md` "Window state controls" says "Set `mouseDownCanMoveWindow = false`" and never
  mentions the shape.

Fix: one sentence in each. The type doc describes a SwiftUI layer wrapping the AppKit view and states the
drag-region constraint once; the rule adds that the area keeps a hit-testable shape behind the AppKit view.
No deterministic automated reproducer exists: fixed and broken differ only in private AppKit drag-region
state, and synthesized XCUITest drags do not trigger the jump.
