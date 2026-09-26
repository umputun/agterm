# HTML overlay pages without JavaScript by default

## Overview
- Page JavaScript is off by default for `--html` and `--url` overlays; `session overlay open --js` turns it
  on for that page. Eugene's decision: one rule for both sources, and the caller passes the flag when the page
  needs script (a dev-server app, an interactive artifact).
- Every guard from the security fixes stays in both modes: grants, paste and drop refusal, link confirmation,
  the identity strip and document-start-only theme injection. The flag restores page scripting only.
- No automatic enabling: not for localhost, not for a blank or failed page.

## Context (from discovery)
- Measured: with `WKWebpagePreferences.allowsContentJavaScript = false` a page's inline script and inline
  event handler do not run, while document-start `WKUserScript`s (the `agterm-theme` world and the page
  world) still run, so the theme survives. Native `evaluateJavaScript` also still runs, so a test cannot use
  it to show page script ran.
- The flag follows `navigation`: `HtmlOverlay` field, `ControlArgs`, dispatcher, CLI, tree node
  (`AppStore+HtmlOverlay.swift`), and the page's `WKWebViewConfiguration` in `HtmlOverlayRegistry.swift`.
- A form submission is not a link activation: an off-origin main-frame submission stays cancelled.

## Development Approach
- Claude writes inline, codex reviews each commit; TDD in `agtermCore`, hosted tests for the WebKit setting.
- Full gates once at the end; the HTML UI class runs only with Eugene's go-ahead.

## Implementation Steps

### Task 1: Model and control API
- [ ] failing core tests: `HtmlOverlay.javascript` defaults to false; the dispatcher passes `--js` through for
      `--html` and `--url` and refuses it without a page; the tree node reports `javascript` as an explicit
      true or false; the CLI parses `--js` and refuses it with a command
- [ ] `HtmlOverlay(source:navigation:javascript:id:)`, `ControlArgs.javascript`, `OverlayHtmlError.jsWithoutPage`,
      dispatcher, CLI flag, `ControlHtmlOverlayNode.javascript`, `ControlSessionOverlayOpenOptions.javascript`, and
      the app factory in `ControlServer+SessionActions.swift` (`openHtmlOverlay`) passing it into `HtmlOverlay`
- [ ] core suites pass

### Task 2: WebKit setting
- [ ] failing hosted tests: without the flag, inline, external and iframe scripts do not run for a
      text-loaded page (iframe through `srcdoc`, since the navigation policy blocks remote and ungranted file
      frames), a granted page and a URL page, while theme variables and file styling still apply; with
      the flag they run; the setting holds across reload and a same-origin navigation
- [ ] `configuration.defaultWebpagePreferences.allowsContentJavaScript = overlay.javascript` before the web
      view exists
- [ ] existing hosted tests that need page script (hook and observer, click loop, paste listener, storage,
      title, redirect-by-script) open with JavaScript on
- [ ] hosted suite passes

### Task 3: UI tests
- [ ] UI tests whose pages need script pass `--js`; a page whose script sets its title opens through the control
      API without the flag (script did not run, `javascript: false`) and with `--js` (it ran, `javascript: true`)
- [ ] build-for-testing; the HTML UI class runs at the gates

### Task 4: Documentation and skill
- [ ] SKILL.md: static HTML/CSS/SVG is the artifact recipe; enable `--js` only when the interaction or the
      web app needs it; the dev-server example passes `--js`; description stays within 1024
- [ ] reference.md, `site/commands.html`, `site/docs.html`, `.claude/rules/control-api.md`: the flag, the
      default, the read-back, and that Open in Browser uses the browser's own JavaScript settings

### Task 5: Verify
- [ ] full gates, codex review, move this plan to `docs/plans/completed/`
