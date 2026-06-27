# Known issues

## Font increase blanks the scrollback — libghostty regression (fixed by the pinned build)

**Symptom:** pressing cmd-+ (increase font size) when the terminal has more than one screen of
output blanks the scrollback — scrolling up shows empty lines, the data appears lost. Decreasing
the font (cmd--) is fine; it only happens on increase, and only when there is scrollback.

**Root cause: a libghostty `main` renderer regression — NOT agterm's code.** It is fixed by pinning
`scripts/setup.sh` to a pre-regression ghostty commit (`GHOSTTY_REV = 4dcb09ada`, 2026-04-30). Earlier
analysis blamed agterm's fixed-pixel pane and "macterm-style embedding" (a shrinking grid on a font
increase) — that was wrong. No app-side change fixes it, and a from-source build of a *different*
embedder (conterm) against the same post-regression libghostty blanks identically, while the same
embedder against a pre-regression libghostty does not.

**Bisect (all on `1.3.2-main`):**
- `d8d2849` (2026-04-11), bundled by conterm v2.2.0 — **good**.
- `4dcb09ada` (2026-04-30), our pin, built from upstream — **good** (verified in agterm).
- `11ab3c8` (2026-05-23), the *oldest* thdxg/ghostty daily build that still exists — **blanks**.
- `1036233` (06-16) … `de36cdf` (06-20), every later thdxg daily — **blanks**.

So the regression landed on ghostty `main` after 2026-04-30 and was present by 2026-05-23. agterm used to
download thdxg's pinned daily build (`build-2026-06-20`), which is well past it. thdxg prunes daily
releases to ~28 days, so no good daily build is downloadable — which is why `setup.sh` now builds
libghostty from upstream source at a pinned good SHA instead (see `CLAUDE.md` → GhosttyKit.xcframework).

**Why it's a silent blank, not a crash:** the data isn't lost — a `ghostty_surface_read_text` probe
returns the full screen+scrollback while the pane shows blank. A font increase shrinks the grid, which
drives libghostty's resize/reflow cursor math; the underlying fault traps in a safety build, but in
`ReleaseFast` (how we build libghostty) it silently reads zeros instead (cf. ghostty #11899), so the
scrollback region paints empty rather than panicking.

**Upstream tracking** — a cluster of resize/reflow/scrollback fixes on ghostty `main`:
- ghostty #12907 (saturate cursor subtraction in `resizeCols`) — merged 2026-06-04
- ghostty #12935 (guard wrap count when resize pushes cursor to scrollback; its repro is `cmd+=` font increase) — merged 2026-06-05
- ghostty #13000 / #13048 (`PageList.scroll` row-offset type) — open as of 2026-06-19

Those June 4–5 fixes did NOT clear it in thdxg's 2026-06-20 build (still blanks under test), and #13048 is
still open, so no good *recent* build exists yet — `4dcb09ada` (Apr 30) predates the whole churn.

**When to revisit:** watch the issues above (and newer resize/reflow fixes). Once a candidate build tests
clean on the font-increase-with-scrollback case, bump `GHOSTTY_REV` in `scripts/setup.sh` forward.

## Sidebar selection colors ignore `config-file` includes

The selected sidebar row draws its pill in the terminal theme's `selection-background` /
`selection-foreground`, but libghostty's `ghostty_config_get` cannot read those optional keys back, so
agterm re-parses the config files itself (`GhosttyApp.resolveSelectionColors`). That re-parse scans
only the four top-level sources (the bundled defaults, `~/.config/ghostty/config`, the agterm-scoped
`ghostty.conf`, and the UI settings file) plus the active theme. It does not follow `config-file`
includes that libghostty expands at load, so a `selection-*` set inside an included file is missed and
the sidebar pill falls back to the theme color or a soft white wash.

This predates the agterm-scoped `ghostty.conf` work and affects `~/.config/ghostty/config` includes
too. The terminal itself still renders the included selection color; only the sidebar chrome can
mismatch. Set `selection-background` / `selection-foreground` directly in one of the top-level files to
keep the chrome in sync.
