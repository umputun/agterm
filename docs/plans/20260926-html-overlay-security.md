# HTML overlay security fixes

## Overview
- Security review of PR #659 (Claude, codex, Fable, runtime probes) found ways a hostile page can act
  without the user: it borrowed the re-theme script's user gesture to write the real clipboard, and a
  scripted `a.click()` made agterm open any https URL in the default browser. Open in Browser opens a
  file with its type's default app, and a dropped file hands its contents to the page.
- Eugene chose the fixes below, plus three design changes: an identity strip, refusing `--cwd` of `/` and
  the home directory, and marking page titles untrusted in the skill and reference.
- Out of scope: the pre-existing auto-confirm of Ghostty's unsafe-paste check.

## Context (from discovery)
- Probes (temporary hosted tests, deleted): `evaluateJavaScript` and `callAsyncJavaScript` run with a
  user gesture; a page `getElementById` override ran inside it (page world) and wrote the pasteboard; a
  page MutationObserver saw `navigator.userActivation.isActive` true during the call in the page world
  AND in an isolated `WKContentWorld`. A page timer never saw activation. Loads (`loadHTMLString`,
  `loadFileURL`) give no activation to the new page's early script or the old page's unload handlers.
- Synthetic `a.click()` arrives as `.linkActivated`, `buttonNumber` 0, `modifierFlags` 0, same as a click.
- Bounded: a `<script src>` through a symlink out of the grant does not run; `fetch` of any `file:` URL
  fails; `navigator.clipboard` is undefined on file and text pages.
- Code: `agterm/Views/HtmlOverlayRegistry.swift` (`applyTheme`, `decidePolicyFor`, `navigate(.browser)`,
  `HtmlOverlayWebView`), `agterm/Views/HtmlOverlayView.swift`, `agtermCore/Sources/agtermCore/HtmlOverlay.swift`
  (`grantError`).

## Development Approach
- Claude writes inline, codex reviews each commit (parallel), revmux loop at the end.
- TDD for `agtermCore`; hosted tests for the WebKit adapter, each fix pinned by a test that fails on the old
  code; UI tests for the strip.
- Full gates once at the end.

## Solution Overview
- **Theme without live script.** The theme user script runs at document start in an isolated
  `WKContentWorld`; nothing evaluates script in a live page. `.agtermAppearanceChanged` fires for many
  unrelated settings, so a page acts only when its computed `HtmlOverlayTheme` differs from the one it has.
  Then a file page reloads the page it shows (a text-loaded page, which is always the original file, loads
  the original again) and its backing changes in the same step; a URL page only replaces the script its next
  load gets.
- **Confirm external opens.** Every page-initiated hand-off to the browser (a clicked link or its redirect,
  a new-window link) asks first with a window-modal sheet naming the destination origin and URL, Cancel the
  default button. The sheet is nonblocking: no control request waits on it, since `ControlServer` serves
  requests one at a time and blocks on each dispatch. One sheet at a time, requests while one is up are
  dropped, and after a Cancel the page gets no further prompt until the next real mouse or key event reaches
  its view (script-dispatched events never do). The sheet captures the exact URL, and closing the overlay
  dismisses it without opening. Opener and confirmation sit behind a seam the tests replace.
- **No confirmation for Open in Browser** (Eugene's call). The toolbar button and `overlay navigate browser`
  are explicit requests from the user or the calling agent. A file overlay opens its original file; a URL
  overlay opens the page it shows, whose path and query the page can steer within its own origin. The
  command's success means the open was handed to the browser.
- **Open in Browser opens a browser.** A file page opens its original file, a URL page its current http(s)
  URL, explicitly with the default browser application resolved from an https URL; no browser means an
  error, never a generic open.
- **No file drops.** A page view refuses drags carrying file URLs, visible or hidden.
- **Identity strip.** An app-owned strip the page cannot cover names the source: a file's name, with the full
  path in its help, or a URL's origin with scheme and port. With `--navigation` the toolbar carries it. The
  page title never replaces it.
- **Grant guard.** `--cwd` of `/` or the home directory is refused.
- **Untrusted title.** The skill and reference say `title` and `error` are page-controlled text.

## Implementation Steps

### Task 1: Grant guard in agtermCore
- [x] failing tests: `--cwd /` and `--cwd` equal to the home directory are refused, a subdirectory of home
      is not; dispatcher refusal message
- [x] `grantError` takes the home directory (default `NSHomeDirectory()`) and refuses it and `/`
- [x] core suites pass

### Task 2: Theme without live script
- [x] failing hosted tests: during a theme change a page `getElementById` override is never called and a page
      MutationObserver never sees user activation, across the reload; a granted file page navigated to
      `b.html` shows `b.html` with the new variables after the change; an unchanged theme does not reload;
      a URL page keeps its old variables until reloaded
- [x] user script in an isolated content world, no `evaluateJavaScript` in `applyTheme`; file pages reload
      on a theme change
- [x] hosted suite passes

### Task 3: Confirmed external opens and Open in Browser
- [x] failing hosted tests: a page clicking links in a loop gets one prompt and zero opens when denied, and no
      second prompt until a real event reaches the view; an approval opens exactly the confirmed URL; requests
      while a sheet is up are dropped; closing the overlay with a sheet up opens nothing; detaching the view
      through its host ends the prompt; Open in Browser on a file page navigated elsewhere opens the original
      file with the browser application, and fails when none resolves; a URL page whose script moved it from
      `/a` to `/b` opens `/b`
- [x] opener and confirmation seam on the registry; `decidePolicyFor` and `navigate(.browser)` go through it
- [x] hosted suite passes

### Task 4: File drops and identity strip
- [x] failing hosted test: a page view refuses a drag carrying a file URL and accepts plain text
- [x] dragging overrides on `HtmlOverlayWebView`
- [x] identity strip in `HtmlOverlayView`, toolbar shows the identity; UI tests assert the source text stays
      shown for a page whose title imitates a prompt, with and without `--navigation`
- [x] hosted and UI tests pass

### Task 5: Documentation
- [x] skill: untrusted title, grant guard, external-open confirmation, theme on reload; reference,
      `site/commands.html`, `site/docs.html`, `.claude/rules/control-api.md`

### Task 6: Verify
- [ ] full gates, revmux loop, move this plan to `docs/plans/completed/`
