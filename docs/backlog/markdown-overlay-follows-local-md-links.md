---
worth: maybe
where: agtermCore/Sources/agtermCore/HtmlOverlay.swift:HtmlNavigationPolicy
added: 2026-11-07
---
# markdown overlay could follow links to neighbouring local .md files

A user asked for links in a rendered markdown page to open neighbouring local `.md` files in the same
overlay. Today `agterm/Resources/markdown/render.js` strips every href except http(s) and `#fragment`,
so local links render as plain text: nothing is broken, the feature is absent. Undecided because it is
link following plus history, which the CLAUDE.md "the overlay is not a browser" rule declines, and
https://github.com/umputun/agterm/discussions/878 declined the same for web links.

The only shape that holds up: a click on a relative `.md`/`.markdown` link renders that file, and Back
returns to the previous file at its scroll position. Replacing the page without Back strands the reader.
Accepting it needs an explicit CLAUDE.md exception.

- Root frozen at the first document's canonical folder, never narrowed or widened; each link resolves
  against the current document and must stay inside the root both after lexical normalization and after
  symlink resolution (`HtmlOverlay.contains` does not resolve symlinks).
- render.js gets the current document's folder from the app, since the page loads with `baseURL: nil`;
  markdown-it's `validateLink` rejects `file:`; `other.md#section` keeps its fragment.
- App-side history of (path, scrollY) in agtermCore, one coherent Back/Forward with in-page anchors; a
  new click drops the forward branch; a missing target leaves the history usable.
- Bare reload keeps meaning the original file, toolbar and `--current` the shown one; theme refresh
  (`reloadShown`) neither resets nor adds history.
- `--markdown` rejects `--navigation` in CLI and protocol; read-back and `HtmlOverlay.identity` (original
  path) must follow the shown file.
- Pages on another Mac excluded: `PageServeStream` serves only the original source, so links stay text
  there. Extending that is what would make the work much larger.

Size estimate: a medium feature, somewhat larger than #880 (+312/-28, 17 files), with most of the
growth in tests; no new control command.
