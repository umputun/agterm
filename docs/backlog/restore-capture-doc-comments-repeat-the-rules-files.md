---
worth: later
where: agtermCore/Sources/agtermCore/WindowLibrary.swift:537
added: 2026-08-26
---
# the restore-capture doc comments run longer than their bodies and repeat the rules files

Four sites from PR #452 carry more prose than the code they document, and spell the same rationale across
three to five surfaces:

- `saveAllOpenChecked` is 6 doc lines over a 3-line body; its own cited precedent `AppStore.saveChecked`
  is 3 lines over 9.
- `ControlServer.captureRestoreCommands`'s third doc paragraph restates `.claude/rules/settings.md:135-141`
  nearly clause for clause, `session.restore` contrast included.
- `WindowAccessor`'s clearing branch carries 9 comment lines over 5 code lines, five of them explaining why
  the termination path takes neither arm. Its neighbouring capture branch does the same job in one line:
  "Contract in `.claude/rules/settings.md`."
- `Restore.Capture`'s CLI `discussion` is 21 lines, the longest in agtermctlKit against a next-longest of
  16 and a sibling `Restore.Clear` of 7; its freshness and self-capture paragraphs duplicate
  `reference.md:1186-1199`.

CLAUDE.md: a doc comment longer than the body it documents is wrong, and own each contract once. Nothing
is inaccurate today - the rules files are the authoritative copy and they are right - so this costs one
trimming pass whenever the area is next touched, replacing the duplicated paragraphs with the
cross-reference the sibling branch already uses.

Surfaced reviewing PR #452, merged as 22f3c7c. The `WindowAccessor` site is the same branch as
[capture-slot-reset-hand-rolled-in-two-places](capture-slot-reset-hand-rolled-in-two-places.md), which is
about the reset being hand-rolled rather than about its comments; doing that one first makes this part of
it moot.
