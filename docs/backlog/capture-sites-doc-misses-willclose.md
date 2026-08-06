---
worth: yes
where: .claude/rules/settings.md:126
added: 2026-08-05
---
# capture-site docs name only applicationWillTerminate

`.claude/rules/settings.md:126` names `applicationWillTerminate` as the capture site, and
`Session.swift:186`'s `foregroundCommand` doc says the argv is "captured at the last clean quit".
PR #370 adds a second capture site in `WindowAccessor`'s `willClose`, and `windows.md`'s scene-lifecycle
bullet does not mention it either.

Fix is one sentence in settings.md naming both sites and the `isTerminating` skip, plus a matching
correction to the `Session.swift` doc. That file owns the capture contract, so it is the right place for
the rule text; `Session.swift` just needs to stop contradicting it.

Both only go stale once #370 merges. On current master "at the last clean quit" is still accurate.
