# agterm — project notes

`agterm` is a native macOS SwiftUI terminal on libghostty, with a two-level workspace -> session vertical
sidebar.
Read `README.md` for the overview and `ARCHITECTURE.md` for the module split,
surface ownership, and the C-boundary concurrency contract before changing the bridge.

## Working norms

- The maintainer and most expected contributors are NOT SwiftUI / macOS UI-UX experts.
  When a UI request is non-standard, risky, or trickier than it sounds (custom window chrome,
  fighting `NavigationSplitView`, reaching into private AppKit views, layout-direction hacks,
  etc.), push back gently FIRST: explain what it actually takes and the trade-offs,
  and offer the simpler/standard alternative.
  If the user still wants it after that, do it — the user is the boss.
- **Propose control-API/CLI coverage for every new feature (aim for completeness).** When adding ANY
  feature or capability, evaluate what of it makes sense to drive over the control channel and PROACTIVELY
  propose adding it — a `Command` case + `ControlServer` arm + `agtermctl` subcommand + round-trip/e2e
  tests.
  The goal is the most complete control-API coverage possible (the API is a first-class surface,
  not an afterthought), not merely parity with the GUI.
  This generalizes the HARD keep-in-sync convention (which covers GUI actions in `AppActions`/`AppStore`)
  to features with NO GUI surface at all — `notify`/`session.copy`/`session.type` are control-native.
  Only skip when exposure is genuinely meaningless (pure rendering/visual chrome with nothing to drive).
- **Use the Swift skills for Swift/SwiftUI work — proactively, from the START,
  not only when stuck.** agterm is Swift 6 + SwiftUI + AppKit; activate the relevant skill before/while
  working: `swiftui-expert` for any SwiftUI/AppKit view, layout, `@Observable`/state,
  focus, animation, or rendering work (this whole `ContentView`/window-chrome/overlay surface);
  `swift-testing-expert` for writing or modernizing Swift tests; `swift-concurrency` for actor / `@MainActor`
  / `Sendable` / async work (esp. across the C-callback boundary).
  Don't wait for a failure to reach for them.
- **"Show me" / "show it" for a UI feature = BUILD + RUN the app for the user to look at,
  NOT a screenshot.** When the user asks to see a visual change, `make build` then launch an ISOLATED
  dev instance (`open -n --env AGTERM_STATE_DIR=<tmp> --env AGTERM_CONTROL_SOCKET=<tmp>/agterm.sock build/DerivedData/.../Debug/agterm.app`)
  so it coexists with the deployed daily-driver and never touches the real `workspaces.json` — then leave
  it running and tell the user how to reach the feature.
  Do NOT take a screenshot (`screencapture`) or capture an image via XCUITest (`XCUIScreen.screenshot`/`XCTAttachment`)
  — the user wants to interact with the running app themselves.
  The XCUITest runner is sandboxed and can't write `/tmp` anyway.
- **After launching a dev instance for the user to test, default to HANDS-OFF.**
  For the user's MANUAL test (the common case — "run it for me to test",
  "I'll test manually"), do NOT touch the running instance after launch:
  no `agtermctl` calls, no `session status` pokes, no state changes — poking it mid-test corrupts what
  the user is observing.
  For an ASSISTED experiment (you drive part of it — e.g. set a session's status via `agtermctl` so the
  user can then act on it), acting is fine, but ANNOUNCE each action as you do it so the user can follow
  and help.
  When in doubt, treat it as manual and ask before touching.

## Toolchain

- The app target is generated with `xcodegen` and built with `xcodebuild` (Xcode 26).
  `mise` is not used; call `xcodegen`, `xcodebuild`, and `swift` directly through the scripts.
- The `agtermCore` package is built and tested with `swift test` (Swift 6,
  strict concurrency `complete`).
  It is independent of Xcode and libghostty.
- `scripts/setup.sh` builds libghostty from upstream ghostty source, so it needs `git`,
  Homebrew (for the `zig@0.15` keg = zig 0.15.2, what ghostty pins), and Xcode's Metal Toolchain (auto-downloaded
  on first run via `xcodebuild -downloadComponent MetalToolchain`).
  The build is one-time — cached by the present-check — so day-to-day work pays nothing.

## Build and test commands

- `scripts/setup.sh` — build `GhosttyKit.xcframework` and the ghostty resources from upstream ghostty
  source (pinned SHA, zig 0.15.2).
  Idempotent; skips the build if both are already present.
  First run takes a few minutes plus a one-time Metal Toolchain download.
- `scripts/run.sh` — setup, `xcodegen generate`, `xcodebuild` Debug, then launch.
- `scripts/build.sh` — same but Release, no launch.
- `cd agtermCore && swift test` — run the host-free unit tests (`scripts/test.sh` wraps this).
- `Makefile` — a thin front door over the scripts: `make prep`/`build` (Debug,
  no launch)/`run`/`release`/`deploy` (Release build + copy to `~/Applications`)/`test`/`lint`/`dist VERSION=x.y.z [PUBLISH=1]`
  (the `release.sh` DMG)/`clean`; a bare `make` lists them.
  The scripts stay the source of truth — only `build`, `deploy`, and `lint` carry their own recipe.
- `make lint` runs `swiftlint lint --strict` over the tree, configured by `.swiftlint.yml` at the repo
  root.
  The config disables only rules that fight deliberate conventions (`identifier_name`,
  `trailing_comma`, `force_try`, `optional_data_string_conversion` — the last keeps the lossy `String(decoding:as:)`
  for terminal/process bytes), exempts the deliberately-named `agtermApp`/`Go` types,
  tunes `line_length` (200) and `cyclomatic_complexity` (`ignores_case_statements`,
  so the flat 44-arm command dispatch isn't "complex"), allows 2-deep type nesting,
  and caps source files at 1000 lines / 800-line type bodies.
  Test files get a 2000-line budget via two nested `.swiftlint.yml` configs
  (`agtermUITests/` and `agtermCore/Tests/`) that override only `file_length`/`type_body_length` and inherit everything else from the root.
  `--strict` promotes warnings to failures, so the tree must stay swiftlint-clean (zero findings).

The app must build, `swift test` must stay green, and `make lint` must pass after every change.

- **Manage file sizes for real — source files stay under 1000 lines, tests under a hard 2000 (= 2×).**
  In OUR OWN work: when you touch a long file, PROPOSE splitting/relocating it toward that rather than
  growing it further — but ALWAYS ask the user first, never restructure a file unprompted; and don't
  reflexively bump the swiftlint `file_length`/`type_body_length` limits to fit new code.
  For a CONTRIBUTOR's PR: do NOT force this — a contributor shouldn't have to refactor a pre-existing long
  file to land their change; NOTIFY that a file is getting long and SUGGEST keeping it under 1000, but
  never make them address the line count or block the PR on it.
  And when REVIEWING a contributor's PR, never suggest the contributor RAISE a `file_length`/`type_body_length`
  (or any lint) limit to fit their change — bumping a size limit is a maintainer decision,
  so at most note the file is getting long, never offer the limit bump as the fix.

- **Working in a git WORKTREE: SYMLINK the prebuilt artifacts, don't re-run setup.** A fresh `git worktree`
  does NOT contain the gitignored `GhosttyKit.xcframework`, `agterm/Resources/ghostty`,
  or `agterm/Resources/terminfo` (they're build outputs, never committed).
  Running `scripts/setup.sh` there would REBUILD libghostty from upstream (a few minutes + the Metal
  Toolchain).
  Instead symlink all three from the main worktree, then `setup.sh`'s present-check skips the rebuild
  (prints `GhosttyKit and resources already present`): `ln -s <main>/GhosttyKit.xcframework GhosttyKit.xcframework`
  and `ln -s <main>/agterm/Resources/{ghostty,terminfo}` into the worktree's `agterm/Resources/`.
  **Use ABSOLUTE targets for the two Resources symlinks** — the relative depth from `<wt>/agterm/Resources/`
  is easy to miscount (`../../` lands inside the worktree, not the sibling).
  The symlinks show as untracked (`??`) in the worktree and never need committing;
  `git worktree remove --force <wt>` removes the worktree + its symlinks WITHOUT touching the symlink
  targets in the main repo.
  Build with the same `xcodegen generate` + `xcodebuild … -derivedDataPath build/DerivedData` as usual.
- **Debug build code lives in `agterm.debug.dylib`, NOT the main `agterm` executable.** Xcode Debug builds
  emit the Swift code (and its string literals) into a sibling `…/Contents/MacOS/agterm.debug.dylib`;
  the main `agterm` binary is a thin stub.
  So to verify that an edit/instrumentation actually compiled into the running app,
  `grep -a` the **dylib** (or the per-file `…/Objects-normal/arm64/<File>.o`),
  not the main executable — grepping `agterm` for a string you added will falsely come back empty.
- **For launch-time value capture, write to a temp FILE, not `NSLog`.**
  `NSLog` from a dev build launched via `open -n` does NOT reliably reach the unified log (`log show`
  showed only the `log show` command's own echoes, never the app's lines,
  even with the string confirmed present in the dylib and a window on screen).
  A tiny file appender (`FileHandle` append to `/tmp/<tag>.log`) is bulletproof and independent of unified-log
  capture — the reliable way to read what a value resolved to at `init` / first view render.
  (`os.Logger` with a subsystem is the production channel; this is just for throwaway investigation.)
- **`run.sh` re-activates a stale instance.**
  `scripts/run.sh` ends in `open agterm.app` with no kill, so if an instance is already running macOS
  just brings it to front — the freshly built binary is NOT loaded.
  To actually test a rebuild, fully quit the running app first (then `open`,
  or launch `…/Debug/agterm.app` directly / `open -n`); otherwise visual verification runs against the
  old build and a real fix looks like it failed.
- **A `make deploy`'d copy in `~/Applications` SHADOWS the dev build — for the CLI,
  the hooks, AND the app.** This machine has agterm installed via `make deploy` (Release → `~/Applications/agterm.app`),
  and the Help-menu installers run off that copy point `/usr/local/bin/agtermctl` and the agent-status
  hooks' baked `AGTERMCTL` (in `~/.config/agterm/agent-status/agterm-agent-status.sh`) at it.
  So once deployed, a bare `agtermctl …` on PATH, the agent-status hooks,
  AND a plain launch/activate (LaunchServices resolves `com.umputun.agterm` to `~/Applications`) all
  hit the DEPLOYED build — NOT whatever you just rebuilt into `build/DerivedData`.
  When iterating on `agtermctl` or the hook scripts, the change is therefore NOT exercised by the PATH
  CLI / the hooks until you either (a) invoke the fresh binary by full path — `build/DerivedData/Build/Products/Debug/agterm.app/Contents/MacOS/agtermctl …`
  (or `export AGTERMCTL=` to it for the hooks), or (b) `make deploy` again and re-run Help ▸ Install
  Command Line Tool… + Install Agent Status Hooks… to re-point PATH and the hooks at the new build.
  For APP-code changes, do NOT quit the deployed app (see the next note — it is the user's live daily
  driver); Debug builds carry a DISTINCT bundle id (`com.umputun.agterm.debug`,
  project.yml per-config) so they run as a SEPARATE instance alongside the deployed Release.
  The XCUITests no longer collide either: the `.debug` bundle id means XCUITest's launch-time terminate
  hits only the `.debug` instance, not the deployed `com.umputun.agterm`,
  and they still use an isolated `AGTERM_STATE_DIR`/socket.
- **NEVER kill or relaunch the deployed `~/Applications/agterm.app` — it is the user's REAL,
  in-use daily terminal with LIVE sessions.** BANNED: `pkill agterm` / `pkill -x agterm`,
  `osascript -e 'tell application "agterm" to quit'`, and ANY quit-then-relaunch of the deployed app
  (including the quit+`open` after `make deploy`).
  After `make deploy` the Release build is COPIED into `~/Applications`,
  but the RUNNING instance keeps the old code until the USER relaunches it on their own schedule (so
  their live sessions survive) — just report it's installed; do NOT relaunch it.
  For dev-build UI acceptance / socket probes, open a SEPARATE ISOLATED instance that coexists with the
  deployed app: `open -n --env AGTERM_STATE_DIR=<tmp> --env AGTERM_CONTROL_SOCKET=<tmp>/agterm.sock build/DerivedData/Build/Products/Debug/agterm.app`
  (verified: launches a second instance with the deployed app untouched and its socket not stolen).
  Probe via the temp socket (`agtermctl tree --socket <tmp>/agterm.sock` — `--socket` is a per-subcommand
  option, so it goes AFTER the subcommand, never before it) and quit ONLY that instance BY PID (`kill <pid>`,
  never `pkill`).
  The Debug bundle id (`com.umputun.agterm.debug`) makes the dev/test build a distinct LaunchServices
  identity from the deployed `com.umputun.agterm`, which is what lets XCUITest (it terminates the app-under-test's
  bundle-id instance on launch) run WITHOUT killing the deployed app — verified,
  the e2e leaves it alive.
  But state + socket are PATH-based (NOT bundle-id-derived, both default to `~/Library/Application Support/agterm/`),
  so the `AGTERM_STATE_DIR`/`AGTERM_CONTROL_SOCKET` env overrides are STILL required for a manual dev
  launch even with the distinct id — otherwise the dev instance reads/writes the user's real `workspaces.json`
  AND steals the deployed app's socket (its `start()` unlinks-then-binds the default path).
  **The socket override must be a SHORT path** (unix sockets cap the path at ~104 bytes):
  a long temp dir (e.g. a Claude session scratchpad) fails with `socket path too long` and the control
  server never binds, while the app itself launches fine — so keep the state dir wherever,
  but point the socket at something like `/tmp/<name>.sock`.
- **Anchor path/existence checks at an ABSOLUTE repo-root path — the Bash cwd DRIFTS.** The shell working
  directory persists across tool calls and silently drifts (e.g. a `cd agtermCore` for `swift test` leaves
  you there), so a later relative `find .github`/`ls`/`cd` runs from the WRONG place and returns a FALSE
  negative.
  NEVER assert "file/dir X doesn't exist" from a relative `find`/`ls` — confirm with an absolute path
  (`/Users/umputun/dev.umputun/agterm/...`) or `git -C <root> ls-files`,
  especially before claiming infra facts (CI presence, config files).
  The repo root vs the `agtermCore` SwiftPM subpackage makes root-vs-subdir confusion easy;
  verify the directory, don't trust a negative relative result.
- **CI and release mechanics live in path-scoped rules** — `.claude/rules/ci.md` (scoped to
  `.github/workflows/**`) for the `ci.yml` job graph (`test` → `coverage` uploading to Coveralls on Linux,
  the `SF:`-path rewrite, `lint`, `build`), and `.claude/rules/release.md` (scoped to `scripts/release.sh`)
  for the LOCAL, maintainer-only sign/notarize/staple + Homebrew-cask flow (there is NO `release.yml` —
  release is NOT CI).
  Read the matching rule before touching CI or the release script.
  One guardrail stays in this root file because it binds during FEATURE work, when no CI/release file is
  open to trigger those rules:
  **`CHANGELOG.md` is RELEASE-ONLY — never touch it in a feature PR.**
  It is written only at release time (the `docs: update changelog for vX.Y.Z` commit / the release flow).
  A feature's own doc updates go to `README.md`, the bundled `agterm/Resources/agent-skill/`,
  and the relevant `.claude/rules/*.md` note — not the changelog.

## GhosttyKit.xcframework

- Source: **built from upstream `ghostty-org/ghostty` source** by `scripts/setup.sh`,
  pinned to the `GHOSTTY_REV` SHA (`zig build -Demit-xcframework=true -Dxcframework-target=native …`
  with zig 0.15.2).
  Self-owned: the only inputs are upstream ghostty at a pinned commit and the zig/Metal toolchains —
  no third-party fork, no daily-build release that can be pruned.
  Bump `GHOSTTY_REV` deliberately when adopting a newer libghostty.
- **The pin is a pre-regression commit on purpose.**
  A libghostty `main` renderer regression introduced after `4dcb09ada` (2026-04-30) blanks the scrollback
  on a font-size *increase* (decrease is fine); it is NOT an agterm bug and no app-side change fixes
  it.
  Every thdxg/ghostty daily build (which agterm used to download) has it.
  Re-test the font-increase case before bumping past it.
- `setup.sh` stages the freshly-built `macos/GhosttyKit.xcframework` plus `zig-out/share/{ghostty,terminfo}`
  resources.
  The xcframework, `agterm/Resources/ghostty`, and `agterm/Resources/terminfo` are gitignored and never
  committed.
- The xcframework is linked with `embed: false` in `project.yml`.
  Never embed it; embedding breaks the signature on non-Developer-ID builds.

## Module boundary

- `agtermCore` must not import GhosttyKit, AppKit, or Metal.
  Keeping it host-free is what lets `swift test` run with no app host.
  Model, persistence, and naming logic go here; the surface contract is the `TerminalSurface` protocol,
  which the app target's `GhosttySurfaceView` conforms to.
- The app target owns all SwiftUI and libghostty code.
- **Also keep `agtermCore` CoreGraphics-free — no `CGSize`/`CGPoint`/`CGRect`/`CGFloat`.** They're Foundation-reachable
  on Darwin and compile + `swift test` fine, but a CoreGraphics member reference (e.g. `CGSize.width`)
  in a Foundation-only module serializes as an unresolvable cross-reference that crashes the app target's
  **release** whole-module-optimizer SIL deserializer (`*** DESERIALIZATION FAILURE *** Cross-reference to module 'CoreFoundation'`,
  Xcode 26.5) — so it passes Debug + tests but breaks `make release`/`make deploy`.
  Use plain `Double`-backed structs in `agtermCore` (see `WindowGeometry.Size`/`Point`/`Rect`) and convert
  to/from CG at the app-target call site.
  Treat CoreGraphics geometry types as if they were on the banned list above.
- **Hoist host-free logic DOWN into `agtermCore`; keep the app target a thin side-effect adapter.**
  The sustained refactor direction (the `refactor`/`hoist` PR series, #78 onward) moves command validation,
  argument parsing, dispatch routing, response shaping, and static catalogs OUT of the app target INTO
  `agtermCore`, so `swift test` exercises them with no app host.
  For the control channel this is the `ControlDispatcher` + `ControlActions` seam
  (`agtermCore/Sources/agtermCore/ControlDispatcher.swift`): `dispatch(_:)` owns parsing + validation +
  response shape, and the app-target `ControlServer` conforms to `ControlActions` supplying ONLY target
  resolution and AppKit/process side effects.
  Commands are migrated group-by-group; a command the dispatcher doesn't yet own returns `nil` and falls
  through to `ControlServer`'s existing switch.
  The same "logic host-free, side effects app-side" split already governs the installers
  (`CLIInstall`/`AgentHooksInstall`/`SkillInstall`), the status sound (`AgentStatus.effectiveSound`), and
  the watermark (`WatermarkConfig`).
  When adding a feature, ask which parts are host-free and put those in `agtermCore` by default — see the
  dispatcher-first rule in `.claude/rules/control-api.md` for the control-command case.

## C-callback isolation

- `GhosttyCallbacks` is `@unchecked Sendable`, not `@MainActor`.
  C closures capture nothing and reach Swift via `GhosttyApp.shared`.
- Copy any `char*` into a Swift `String` before hopping; every `@MainActor` touch goes through `DispatchQueue.main.async`.
- **Rendering is demand-driven, no poll timer.**
  `GhosttyCallbacks.wakeup` coalesces libghostty wakeups into one `DispatchQueue.main.async` `ghostty_app_tick`
  (an `OSAllocatedUnfairLock` flag dedupes the wakeup storm), and `GHOSTTY_ACTION_RENDER` draws the surface
  via `renderNow()` (`ghostty_surface_draw`).
  Mirrors Ghostty.app/conterm — an idle terminal does no work (the old 120Hz poll ticked continuously).
  The C callbacks never use `assumeIsolated`; every `@MainActor` touch hops through `DispatchQueue.main.async`.
- `close_surface_cb` only recovers the view and dispatches to the main actor;
  it never frees synchronously.

## Keep-in-sync conventions (HARD)

These cross-subsystem contracts apply when editing ANY feature, not just the files that own them.
They are restated in detail in the relevant path-scoped rules, but the principle lives here so it is
always in context:

- **A new user action is not "done" until it is drivable from the control socket.** Any action added
  to `AppActions`/`AppStore` requires all four: (1) a `Command` case (+ args) in `agtermCore`'s `ControlProtocol`,
  (2) a dispatch arm in `ControlServer`, (3) an `agtermctl` subcommand, (4) protocol round-trip + end-to-end
  tests.
  The toolbar/bottom-bar, the menu bar, and the control channel are three callers of the SAME `AppActions`/`AppStore`
  seam and must never drift.
  (The Working-norms bullet above generalizes this to control-native features with no GUI surface.) Genuinely
  meaningless exposure (pure visual chrome with nothing to drive — quit-confirm,
  CLI/skill installers, click-routing `reveal`) is the only exemption, and must be called out as such.
- **The bundled agent skill is the fourth keep-in-sync surface.**
  Whenever you change the Control API (commands/args/returns), the keymap format,
  or the window/workspace/session/pane model, update `agterm/Resources/agent-skill/` (SKILL.md + reference.md
  + examples.md + troubleshooting.md + scripts, incl. the command count) so the installed agent-driver
  doc stays accurate.
  The app-repo `agterm/Resources/agent-skill/` is the SINGLE source of truth — edit ONLY there.
  NEVER edit, copy into, or "mirror" the installed copies at `~/.claude/skills/agterm/` or `~/.codex/skills/agterm/`;
  they are install OUTPUTS that Help ▸ Install Agent Skill (`SkillInstaller`) regenerates from the bundle,
  so a manual edit there is wrong and must never even be offered (`~/.claude/skills/agterm/` is snapshotted
  in the dot-files repo, but that does not make it a source).
- **The website (`site/`) is the fifth keep-in-sync surface.**
  `site/docs.html` is a hand-authored mirror of `README.md` — when you add features, flags,
  keybindings, or modes, update both.
  `site/index.html` (the features grid and install copy) and the `softwareVersion` in its
  `SoftwareApplication` JSON-LD must reflect major features and the latest release.
  See the `## Website` section below for the deploy model.

## Website

`agterm.com` is a hand-authored static site in `site/`, deployed via Cloudflare Pages with no build step
(the revdiff pattern).
Cloudflare's Git integration auto-deploys `site/` on every push to `master`; there is no wrangler config
and no deploy workflow in the repo.
All Cloudflare wiring — the Pages project, the `agterm.com` custom domain, and the output directory (`site`)
— lives in the Cloudflare dashboard, not in git, so it is not reproducible from the repo.
Cloudflare Pages strips `.html` and 308-redirects `/docs.html` to `/docs`, so every canonical link,
`og:url`, and `sitemap.xml` entry uses the extensionless `https://agterm.com/docs`.

The site is lean and self-contained — nothing is embedded.
`site/style.css` holds the reset, keyframes, `@font-face`, and the hover classes;
the two pages keep the design's inline styles.
Assets are self-hosted under `site/assets/`: latin `woff2` fonts in `site/assets/fonts/`,
screenshots as `webp`, plus a generated 1200×630 `agterm-og.png` social card and favicons.
The pages were converted from a design-tool bundle export whose source zip lives on the maintainer's
Desktop, not in the repo, so a visual redesign means re-exporting the design and re-running that conversion.

## Subsystem notes (path-scoped rules)

Detailed per-subsystem engineering notes live in `.claude/rules/*.md`, each scoped with `paths:` frontmatter
so it loads into context only when you read a matching source file — that is what keeps this root file
lean.
When starting work on a subsystem, read its rule first: the auto-trigger covers the subsystem-owned files,
but a cross-cutting edit that touches only a hub file (`AppStore.swift`,
`ContentView.swift`, `agtermApp.swift`) may not match a glob, so consult this index and open the rule
yourself.

**When writing or editing these notes — this file and `.claude/rules/*.md` — use semantic line breaks: one sentence per line, never a giant single-line bullet.**
Break after every sentence (split a long sentence further at clause boundaries, around 100 columns), keep inline-code spans intact, and render any long enumeration (e.g. a command catalog) as a real markdown list rather than one inline run.
This only changes raw-text line breaks — the rendered markdown is identical — but it keeps a diff scoped to the sentence that changed and stops two branches that edit the same note from conflicting on the whole paragraph.

- `sidebar.md` — `NSOutlineView` sidebar: drag-reorder (sessions + workspaces),
  flagged working-set view, focus filter, scoped session nav, reconcile signal,
  persistence.
  Triggers on `WorkspaceSidebar.swift`, `SidebarDrop`/`SidebarMode`/`Reorder`,
  and the sidebar/reorder/flagged/focus UI tests.
- `menu-actions.md` — the `AppActions` seam: View vs Navigate menu split,
  split panes (one session two shells), session navigation, command palettes,
  Ctrl-Tab MRU switcher, inline rename, font/in-terminal-search.
  Triggers on `AppActions.swift`, `agtermApp.swift`, `Palette`/`PaneShortcuts`/`SessionSwitcher`,
  `RecencyStack`/`Fuzzy`, and the menu/palette/nav/switcher/split UI tests.
- `windows.md` — multi-window model: `WindowLibrary`, scene + claim-queue restoration,
  per-window quick terminal, frontmost-store resolution + quit-flush, quit confirmation,
  `window.*` control.
  Triggers on `WindowLibrary`/`WindowGeometry`/`QuitPrompt`, `QuickTerminal.swift`,
  and the multi-window/quick-terminal UI tests.
- `control-api.md` — the full 49-command control catalog, the three protocol layers,
  addressing, and the CLI/hooks/skill installers.
  Triggers on `ControlServer.swift`, `ControlProtocol`/`ControlResolve`,
  `agtermctlKit`/`agtermctl`, the three installers + their host-free `*Install` logic,
  `Resources/agent-skill/`, and the control UI tests.
- `settings.md` — `AppSettings`/`SettingsModel`, the 5-tab Settings scene,
  ghostty-config emission, window translucency.
  Triggers on `SettingsModel.swift`, `SettingsView`/`SettingsCatalog`/`WindowAppearance`/`NSColor+AgtermHex`,
  `AppSettings`/`SettingsStore`, and the settings UI tests.
- `theme-picker.md` — the live-preview theme palette mode, preview/commit/cancel,
  the seeded default theme.
  Triggers on `Palette.swift`, `SettingsModel`/`SettingsCatalog`, `AppActions.swift`.
- `keymap.md` — the kitty-flavored `keymap.conf` parser, built-in-override resolution,
  custom-command monitor, `{AGT_X}` tokens, reload + Edit Keymap.
  Triggers on `Keybind`/`KeybindMatcher`/`Keymap`/`BuiltinAction`/`CustomCommand`/`ConfigPaths`,
  `CustomCommandRunner.swift`, and the keymap UI tests.
- `notifications.md` — terminal OSC 9/777 + control `notify`, suppression,
  click-to-reveal identity, the unseen badge, the agent-status glyph.
  Triggers on `NotificationManager.swift`, `Notifications`/`AgentStatus`.
- `ui-tests.md` — XCUITest patterns: `launchForUITest` (FB11763863), Settings-tab retry helper,
  driving an `NSOutlineView` drag, the occlusion-timeout symptom, test cadence.
  Triggers on any `agtermUITests/` file.
- `libghostty.md` — rendering / AppKit gotchas: the eager-deck surface lifecycle,
  the NSSplitView-titlebar-overrun rule, cursor focus, theme-tracking chrome colors,
  search-bar / overlay placement, reparent repaint.
  Triggers on the `Ghostty/` surfaces, `ContentView.swift`, `TerminalView`/`TerminalSearchBar`.
- `app-icon.md` — the adaptive Icon Composer `.icon` build rules.
  Triggers on `AppIcon.icon/`, `project.yml`.
- `ci.md` — the `ci.yml` job graph: the `test`/`coverage`/`lint`/`build` split,
  coverage → Coveralls-on-Linux with the `SF:`-path rewrite, the paths-filter, and the badge scope.
  Triggers on `.github/workflows/**`.
- `release.md` — the LOCAL, maintainer-only `scripts/release.sh` flow:
  sign/notarize/staple the app + DMG, tag + GitHub release, Homebrew-cask push, the release-time
  changelog draft-approval.
  Triggers on `scripts/release.sh`.
