---
worth: yes
where: agtermCore/Sources/agtermCore/ControlDispatcher+Companions.swift:pageRowOptions
added: 2026-11-12
---
# page rows for markdown, text, image and document pages

A page row (`session overlay open --page|--companion`) shows only an HTML file or a URL. `pageRowOptions`
refuses an image, a markdown file and a text page (a log or a diff included), and a document page (an `.html`
file opened by ⌘-clicking it in a terminal) has no creation command at all, so none of them can be a sidebar row
on any host; they open only as an overlay over a terminal session.

Making them rows is a local feature first: creation and its refusals, a route for document pages, the saved
`PageSnapshot` for each source, restore, and the text-page controls (follow, search, wrap, changes) on a row with
no terminal under it. The remote half then follows the HTML page row: page-attach and page-serve for these pages,
the snapshot a viewer Mac renders from, and agterm-server page rows in the catalog. Remote parity is part of the
task, not a later step.

Surfaced when the remote text page controls plan dropped "content page rows attached from another Mac": the rows
it meant to attach do not exist anywhere yet.
