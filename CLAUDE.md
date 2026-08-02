# agterm project notes

agterm is a native macOS SwiftUI terminal on libghostty with a workspace-to-session sidebar.
Read `README.md` for product behavior and `ARCHITECTURE.md` for modules, surface ownership, and C-boundary
concurrency before changing the bridge.

## Working norms

- For nonstandard or risky UI requests, first explain the AppKit/SwiftUI cost and offer the standard
  alternative. Proceed if the user still prefers the custom behavior.
- For every new capability, propose useful control API/CLI coverage: protocol command and arguments,
  dispatch, `agtermctl`, read-back, and tests. Control-native features count; skip only chrome with nothing
  meaningful to drive.
- For each hideable titlebar/sidebar element, ask whether it should join host-free `InterfaceElement` and
  Settings > Interface. Never add that preference without approval.
- Start Swift work with the relevant skills: `swiftui-expert` for UI/AppKit/Observation/rendering,
  `swift-testing-expert` for tests, and `swift-concurrency` for actors, Sendable, async, and C callbacks.
- “Show me” means build and launch a separate interactive Debug instance, not a screenshot. Use isolated
  state and socket paths, leave it running, and explain how to reach the feature.
- An isolated state dir also redirects config to `<stateDir>/config`. Copy
  `keymap.conf`, `ghostty.conf`, and `restore-denylist.conf` when real custom behavior is required.
  Set only a short `/tmp` `AGTERM_STATE_DIR` so app and inherited CLI derive the same socket.
  Prepend the Debug app's `Contents/MacOS` to PATH for custom commands; login shells may restore the
  deployed CLI, so manual commands should use the Debug binary's full path.
- A fresh isolated state dir reads as a first launch and opens the welcome alert.
  `mkdir -p "$AGTERM_STATE_DIR/windows"` before launching to skip it: `FirstRunWelcome.hasPriorState`
  looks for `settings.json`, `workspaces.json`, or `windows` before the app writes anything.
  Leave the marker out only when the welcome itself is under test.
- The control socket binds from the window scene's task, so a backgrounded `open -n -g` can leave the app
  running with no socket until a window renders. Activate the instance when the socket never appears.
- `agtermctl` never reads `AGTERM_SOCKET`; it resolves `--socket`, then `AGTERM_STATE_DIR`, then
  `~/Library/Application Support/agterm`. A shell inside the live terminal therefore defaults onto the
  live socket, and exporting a short `AGTERM_STATE_DIR` is what keeps inherited commands off it.
- After launching an instance for manual testing, do not touch it. For an assisted experiment, announce
  every action. Ask before acting when unclear.
- Put nontrivial work in an isolated worktree and remove it after merge. See the build section for artifact
  links and cleanup.
- Comments and docs are liabilities kept short. Keep only non-obvious constraints, rejected alternatives,
  or reasons the obvious implementation fails. Never narrate code, repeat a fact across surfaces, use a
  paragraph where a clause works, or preserve change history. Own each contract once and cross-reference it.
  If 25 lines of logic seem to need 100 lines of comment, fix the code.
- Test comments are rare and one line. Add one only when neither the test name nor setup reveals the goal.
  Never label arrange/act/assert, restate an assertion, or explain why a test exists.
- Review severity follows user-visible consequences: critical for data loss or broken primary paths, major
  for wrong results or broken secondary paths, minor otherwise. Documentation inaccuracies are never
  critical or major. Documentation-heavy review findings usually call for less prose.

## Toolchain and gates

- Xcodegen creates the app project; Xcode 26 builds it. Call `xcodegen`, `xcodebuild`, and `swift`
  directly through repository scripts; `mise` is unused.
- Swift 6 `agtermCore` uses complete concurrency checking and has no Xcode/libghostty dependency.
- `scripts/setup.sh` builds pinned libghostty with Homebrew zig 0.15.2 and Xcode's Metal Toolchain.
  It is idempotent after artifacts exist.
- Commands:
  - `scripts/run.sh`: setup, generate, Debug build, launch.
  - `scripts/build.sh`: setup, generate, Release build.
  - `cd agtermCore && swift test`: host-free tests; `scripts/test.sh` wraps it.
  - `scripts/test-app.sh`: isolated hosted AppKit tests.
  - `make prep|build|run|release|deploy|test|test-app|lint|clean`; `make dist VERSION=x.y.z [PUBLISH=1]`.
- `make lint` runs strict SwiftLint from the root. Root limits are 200-column lines, 1000-line source
  files, and 800-line types; test configs raise file/type limits to 2000 and inherit all other rules.
  Disabled/tuned rules reflect deliberate conventions. Zero findings are required.
- Every change must build, pass `swift test`, `make test-app`, and `make lint`.
- Run each gate ONCE, at the end, and scope everything else to what changed: a new or changed test runs
  via `-only-testing:<Target>/<Class>/<test>`. Never re-run a whole XCUITest suite to verify a narrow
  change; `agtermUITests/ControlAPIUITests` alone is about 7 minutes and tells you nothing the targeted
  run did not.
- For maintainer work, ask before splitting a touched long file and do not raise limits reflexively.
  Contributors need not refactor preexisting length; mention it without blocking or suggesting a limit bump.

## Worktrees and local builds

- Fetch `origin master` before creating a native Claude worktree so it forks the current remote tip.
  Do not manually `git worktree add`.
- Fresh worktrees lack ignored `GhosttyKit.xcframework` and
  `agterm/Resources/{ghostty,terminfo}`. Symlink all three from the main checkout instead of rebuilding;
  use absolute targets for resources. They remain untracked and disappear with worktree removal.
- After merge, verify the PR merge commit on fetched `origin/master`, then remove the worktree without
  changing the main checkout's branch. Squash/rebase makes removal report unmerged commits; after
  verification, discard the worktree safely. Native removal may leave a renamed branch, which must be
  deleted separately after checking the remote.
- Debug Swift code lives in `agterm.debug.dylib`; inspect it or object files, not the stub executable.
- For throwaway launch-time probes, append to a temp file. `NSLog` from `open -n` is unreliable; production
  logging uses `os.Logger`.
- `scripts/run.sh` activates an existing instance instead of loading a rebuild. Use a distinct isolated
  launch for current code.
- `make deploy` copies Release to `~/Applications`, whose app, PATH CLI, and installed hooks shadow Debug.
  Test fresh CLI/hooks with the Debug binary or redeploy and reinstall them. Debug uses
  `com.umputun.agterm.debug`, distinct from Release, but state/socket paths still require isolation.

## Protect the live terminal

- Never run a mutating `agtermctl` command on the default socket. It controls the user's live deployed
  terminal. Read-only `tree` and `window list` are tolerable; writes require explicit isolated socket.
  Never execute bundled recipes against the default instance.
- Every delegated agent that might touch the app or CLI must receive verbatim:
  “never execute `agterm`/`agtermctl` against the default socket, never launch or quit the app, static
  reading only.”
- Never kill or relaunch `~/Applications/agterm.app`, and never `pkill agterm` or `osascript … to quit`
  (both also reach dev instances). Deployment replaces files but the user decides when to restart.
- Manual Debug UI work uses a separate `open -n` instance with isolated state and short socket. Address
  its CLI with `--socket` after the subcommand. Stop only its known PID with SIGTERM; clean quit triggers
  the visible quit-confirmation alert. Use clean quit only when testing its final cwd/running-command flush.
- Unix socket paths cap near 104 bytes. A long scratch path lets the app launch while control bind fails.
- Use absolute repo-root paths for existence checks. Tool cwd persists across calls and often drifts into
  `agtermCore`.
- CI and release mechanics live in `.claude/rules/ci.md` and `release.md`. `CHANGELOG.md` is release-only;
  feature PRs update relevant product, skill, or engineering docs instead.

## GhosttyKit

- `scripts/setup.sh` builds upstream `ghostty-org/ghostty` at `GHOSTTY_REV` using
  `zig build -Demit-xcframework=true -Dxcframework-target=native`. No fork or disposable daily build is used.
- The pin stays at or before `4dcb09ada` (2026-04-30) because later renderer builds blank scrollback on
  font-size increase; decrease works and no app-side fix exists. Re-test increase before advancing.
- Setup stages the xcframework and `zig-out/share/{ghostty,terminfo}`. All are ignored build artifacts.
- Link the xcframework with `embed: false`; embedding breaks non-Developer-ID signatures.

## Module and callback boundaries

- `agtermCore` imports no GhosttyKit, AppKit, Metal, or CoreGraphics. Use Double-backed geometry and
  convert in the app target. Darwin Foundation can expose CG types that pass Debug/tests but crash Xcode
  26.5 Release WMO deserialization with an unresolved CoreFoundation cross-reference.
- Put model, persistence, parsing, validation, routing, response shaping, and static catalogs in
  `agtermCore`; keep the app target a side-effect adapter, continuing the #78 hoist series. Control uses `ControlDispatcher` plus
  `ControlActions`, with unmigrated commands returning nil to the app switch. Installers, status sound,
  and watermark follow the same split.
- `GhosttyCallbacks` is `@unchecked Sendable`, not `@MainActor`. C closures capture nothing and reach
  `GhosttyApp.shared`. Copy `char*` before hopping; every main-actor touch uses
  `DispatchQueue.main.async`.
- Rendering is demand-driven. Wakeup coalesces through an `OSAllocatedUnfairLock` into one main-queue
  `ghostty_app_tick`; RENDER calls `renderNow`. Never restore the rejected continuous 120Hz poll or use
  `assumeIsolated`.
- `close_surface_cb` only recovers the view and dispatches; it never frees synchronously.

## Cross-surface contracts

- A new user action is incomplete until protocol, dispatcher, CLI, and protocol/end-to-end tests exist.
  Toolbar/footer, menu, and control share the same action/store seam. Call out genuine visual-only exemptions.
- A state-setting command must expose its result on `ControlSessionNode`, window node, or tree top level.
  Examples include background, unseen, status and overrides, flag, split focus/ratio, overlay size,
  sidebar state/mode, workspace focus, quick visibility, geometry, fullscreen, zoom, and minimize.
- Event arguments must appear in `EventFormatter.human`, not only JSON payloads.
- Control API, keymap, and model changes also update bundled
  `plugins/agterm/skills/agterm/`, the sole source for installed Claude/Codex copies.
- `site/docs.html` mirrors README. `site/index.html` reflects major features and current
  `softwareVersion`; `site/commands.html` mirrors every command, arguments, and read-back field.
- `cookbook/` is not a synchronized surface. Recipes pin a minimum version and are fixed reactively;
  its CI checks structure and shell hygiene, not current API parity.
- Cookbook recipes are third-party work published by their author, not code the project owns.
  Review asks only three things: it does no harm, deliberately or accidentally; it does what it claims;
  and it follows `cookbook/CONTRIBUTING.md`.
  Edge cases, minor bugs, and other small findings never block the PR: approve and merge, leaving a note
  for the contributor.

## Website

- `agterm.com` is the static `site/` directory on Cloudflare Pages with no build step or repository deploy
  config. Dashboard-owned wiring deploys every master push. Canonical URLs omit `.html` because Pages
  redirects with 308.
- Assets are self-hosted: CSS, latin woff2 fonts, WebP screenshots, 1200x630 social card, and favicons.
  Inline page styles come from a design-tool export whose source archive is on the maintainer's Desktop.
- Hero images must match the fixed `1187 / 696` ratio, about 1.70:1; capture dense dashboards at that
  ratio before WebP conversion; existing shots are 2374x1392. Dashboard images may floor near 200k versus
  85-172k for single-window shots. Crossfade duration is slides times 5 seconds, delays advance by
  5 seconds, and the opaque keyframe plateau is about `1/slides`.
- Auto-fit feature grids can strand orphan cards. Use a fixed column count, explicit spans, and narrow
  media fallbacks as in `.surfaces-grid`.

## Path-scoped rules

Read the matching `.claude/rules/*.md` before subsystem work, including cross-cutting hub-file changes.
Keep these notes in semantic lines: one sentence per line, split long clauses near 100 columns, keep code
spans intact, and format long catalogs as lists.

- `sidebar.md`: outline, reorder, flagged/focus views, scoped navigation, reconciliation, persistence.
- `menu-actions.md`: actions, menus, split panes, navigation, palettes, MRU, rename, search.
- `windows.md`: window library, restoration, quick terminal, active-store resolution, quit, controls.
- `control-api.md`: protocol layers, catalog, addressing, CLI/hooks/skill installers.
- `settings.md`: settings model/UI, Ghostty config emission, translucency.
- `theme-picker.md`: preview/commit/cancel and seeded default.
- `keymap.md`: keymap parser, built-ins, custom commands/tokens, reload/edit.
- `notifications.md`: OSC/control notifications, suppression, reveal, badges, status.
- `ui-tests.md`: launch isolation including FB11763863, AppKit/XCUITest traps, cadence.
- `libghostty.md`: surfaces, rendering, AppKit, theme, overlays, cursor.
- `app-icon.md`: adaptive Icon Composer build.
- `ci.md`: jobs, filters, coverage, badge.
- `release.md`: local signing, notarization, release, Homebrew, changelog.
