---
worth: later
where: agterm/Resources/markdown/text.js
added: 2026-11-06
---
# diff pages scroll long lines sideways instead of wrapping

A `.diff`/`.patch` text page keeps `white-space: pre`, so a long line runs off to the right and the page scrolls
sideways; webrev's diff view wraps it. Only diff pages should change: source, config and log pages keep scrolling.

Switching the `pre` to `pre-wrap` alone misaligns everything anchored to a row, since the gutter is one separate
column of numbers and the `--line` band, change marker and step geometry are placed at row index times 20px.
The agreed design, as webrev does it:

- each diff row is a block element that keeps its `\n` inside, so the page text stays the file as written
- the row number moves into the row as a CSS counter in `::before` (inline-block with a negative margin, not a grid
  per row, which matters near 4 MB), and the diff page drops the gutter column and `min-width: max-content`
- added and removed backgrounds, the current change and the `--line` target are classes on the rows, so they follow
  reflow after a resize; a band drawn from measured offsets would stay over the wrong text
- change stepping reads each row's own `offsetTop`/`offsetHeight`

Tests: a long row grows past one line with no horizontal scroll, and a selected change and a target line still
mark their rows after the page is resized. Re-measure the near-4 MB diff render time.
