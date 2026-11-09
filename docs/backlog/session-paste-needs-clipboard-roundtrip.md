---
worth: later
where: cookbook/annotate-pane-output/annotate-pane.py:Agt.deliver
added: 2026-11-08
---
# session paste only reads the clipboard, so recipes round-trip it

`session paste` pastes `NSPasteboard.general` and takes no text of its own, so a recipe that wants
bracketed-paste delivery saves the clipboard with `pbpaste`, puts its text there, pastes, and restores
with `pbcopy`. The restore is plain text only: an image or file is lost (both READMEs say so), and an
item a password manager marked concealed or transient comes back as an ordinary clipboard entry that
clipboard-history apps can then record. `annotate-pane-output` does this, and the contributed
`annotate-in-plannotator-tui` (PR #936) copies the pattern.

A text-taking form (`session paste --stdin`, or text in the request) would let both recipes drop the
round trip. Surfaced reviewing PR #936.
