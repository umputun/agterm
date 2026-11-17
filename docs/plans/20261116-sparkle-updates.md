# In-app updates with Sparkle

## Overview
- agterm finds, downloads and installs its own updates with stock Sparkle 2, for both install channels: the
  notarized DMG and the Homebrew cask `umputun/apps/agterm`.
- Users see Sparkle's standard flow: Check for Updates in the app menu, its "check automatically?" question, its
  release-notes window, its admin prompt when `/Applications` is not writable, and its relaunch.
- Four additions of our own:
  - the cask gets `auto_updates true`, so a brew copy updates through Sparkle too;
  - the restart offer says whether Live sessions keep running and reconnect;
  - a bright-blue title-bar icon at the far right appears when a scheduled check finds an update;
  - `agtermctl update check` starts the same check as the menu item.
- Only builds made by `scripts/release.sh` run Sparkle. Debug, `make release` and `make deploy` builds have no feed and
  never check, so the maintainer's deployed master build is never replaced by a published release.
- Replaces the hand-built update-notices attempt of 2026-10-30, dropped as overcomplicated. Nothing here
  re-implements what Sparkle already does.

## Context (from discovery)
- Version: `project.yml` sets `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` to `0.0.0`; `scripts/release.sh:152` and
  `scripts/build.sh:21` pass a version to both. `build.sh` (`make release`/`make deploy`) uses the latest tag, under the real
  bundle id.
- Signing: `scripts/release.sh:158-175` Developer-ID signs `agtermctl`, `zmx` and `agterm-session-host` inside-out, then the
  app without `--deep`; `project.yml:171-183` ad-hoc re-seals other builds. Release runs the hardened runtime
  (`project.yml:117`) without `disable-library-validation`, which only `agterm-debug.entitlements` has, and Sparkle.framework is
  the first embedded dynamic framework (`GhosttyKit` is `embed: false`).
- Publish: `scripts/release.sh:222-250` creates the release, uploads the DMG and server tarballs in one `gh release upload`,
  then bumps `version`/`sha256` in the tap. `.claude/rules/release.md:22`: any other cask edit is made by hand in the tap too.
- Quit: `AppDelegate.applicationShouldTerminate` (`agterm/AppDelegate.swift:375`) returns `.terminateNow` for a system quit,
  an armed Live reset or zero open windows, otherwise shows "Quit Agterm?" with `QuitPrompt.message(windows:sessions:mode:)`
  (`agtermCore/Sources/agtermCore/QuitPrompt.swift`). The next launch's mode is `AppSettings.effectiveRestoreMode`
  (`AppSettings.swift:588`, read live as in `AppDelegate.swift:467`).
- Chrome: `InterfaceElement` (`agtermCore/Sources/agtermCore/AppSettings.swift:131`, contract in `.claude/rules/settings.md`),
  title-bar layout in `TitlebarComposition.swift` and `agterm/Views/WindowContentView+Titlebar.swift`, menus in
  `agterm/agtermApp+Menus.swift`. CLAUDE.md:37 forbids state-dependent visibility; Eugene approved an exception for the
  update icon (2026-11-16).
- Control: `version` is answered by `ControlServer+AppCommands.swift` `appIdentity()`; `ControlActionsDefaults` refuses
  commands an `agterm-server`/`agterm-linux` conformer does not implement.
- Sparkle 2.2+ gentle reminders: `supportsGentleScheduledUpdateReminders`,
  `standardUserDriverShouldHandleShowingScheduledUpdate(_:andInImmediateFocus:)`,
  `standardUserDriverWillHandleShowingUpdate(_:forUpdate:state:)`,
  `standardUserDriverDidReceiveUserAttention(forUpdate:)`, `standardUserDriverWillFinishUpdateSession()`.
  Neither relaunch hook is used: returning false from `updaterShouldRelaunchApplication` aborts the install, and a Later
  inside `shouldPostponeRelaunchForUpdate` strands Sparkle's window with a spent install handler. Codex traced
  `updater(_:willInstallUpdate:)` and `updaterWillRelaunchApplication` to one notification sent once before the first
  termination request (2.9.6 `SPUCoreBasedUpdateDriver.m:322-338`).

## Decisions carried from the draft
The draft is `docs/plans/20261030-update-notices.md` (deleted, recovered from the 2026-10-30 session transcript).

| draft decision | here | reason |
|---|---|---|
| installed-build-changed notice + Quit and Reopen | dropped | Sparkle installs and relaunches itself |
| consent question before any network request | changed | Sparkle's own automatic-check question |
| daily `releases/latest` check, ready only when the DMG is uploaded | changed | appcast uploaded in its own `gh release upload` after the DMG and tarballs |
| skip this version | kept | Sparkle's built-in Skip |
| title-bar button, far right, bright blue, on by default | kept | Eugene's choices, 2026-10-31 |
| button shows only while there is something to act on (#790 exception) | changed | shows only while an update is waiting; reworded exception approved 2026-11-16 |
| chromeless 90% HTML panel with sandboxed notes | dropped | Sparkle's release-notes window |
| Upgrade types `brew upgrade` into a visible session | dropped | cask `auto_updates true`, Sparkle updates the brew copy |
| DMG Upgrade opens the release page | dropped | Sparkle installs the DMG |
| Homebrew ownership detection (Caskroom appdir) | dropped | no channel-specific code |
| `update.check`, `update.skip`, `update.relaunch`, `update.upgrade` + state read-back | changed | `update.check` and Sparkle's setting/date read-back only |
| `ControlDispatcher` split to make room | dropped | the dispatcher is 736 lines |
| Debug `0.0.0` excluded from comparison | changed | only `release.sh` builds have a feed |
| "see it running" before the PR | kept | standing rule for visible changes |

## Development Approach
- **testing approach**: Regular (code first, then tests in the same task)
- complete each task fully before moving to the next; all tests pass before the next task starts
- every task includes new/updated tests for its code, success and error paths
- update this plan when scope changes
- scope test runs to what changed (`swift test --filter`, `-only-testing:`); run `swift test`, `make test-app` and `make lint`
  once at the end
- backward compatible: settings without the new key decode unchanged, new protocol fields are optional,
  `ControlActionsDefaults` refuses `update.check`
- never launch anything against the live state: every manual run uses `open -n --env AGTERM_STATE_DIR=<short /tmp dir>`
  with the inherited `AGTERM_*`/`GHOSTTY_*`/`CLAUDE*` variables unset, as CLAUDE.md describes

## Testing Strategy
- **unit tests** (`agtermCore`): `UpdateFlow` (below) for every reminder and quit transition, restart wording for every case,
  the new `InterfaceElement`, `update.check` parsing, response shape, refusal and CLI formatting
- **hosted tests** (`agtermTests`): no updater without a feed, the title-bar icon renders from `UpdateFlow` state
- **UI tests** (`agtermUITests`): `agtermctl update check` end to end in the existing control suite; a Debug build has no
  feed, so the refusal is the testable path there
- Sparkle itself, the bundle swap under Live daemons and the relaunch are verified by the updatetest runs (Tasks 4, 5)

## Solution Overview
- `UpdateFlow` (`agtermCore`, no Sparkle import) holds the decisions as plain state and inputs: reminder found
  (scheduled, Sparkle not showing it), attention, session end, element hidden, installer about to quit, quit requested.
  It answers `reminderPending`, whether a quit is an update quit, and which alert text a quit gets.
- `UpdateController` (app target) owns `SPUStandardUpdaterController`, forwards Sparkle's callbacks to `UpdateFlow` and
  publishes its state. It exists only when `SUFeedURL` is non-empty.
- Feed: the `AGTERM_UPDATE_FEED` build setting fills `SUFeedURL`, empty by default. `release.sh` passes
  `https://github.com/umputun/agterm/releases/latest/download/appcast.xml`; the updatetest recipe passes a local feed.
  `SUPublicEDKey` holds the EdDSA public key; the private key lives in the maintainer's login keychain. Sparkle is pinned to one
  exact version in `project.yml`.
- Restart: Sparkle's Install and Relaunch sends the normal quit. After the existing system-quit and Live-reset guards,
  `applicationShouldTerminate` asks `UpdateFlow`: for an update quit it shows "Restart to update?" (Restart / Later);
  Later returns `.terminateCancel`, and Sparkle's window and menu item can still restart. The update-pending mark is set from
  `updaterWillRelaunchApplication`, survives Later (Sparkle's retry sends another quit without repeating that callback), and
  clears in `updater(_:didFinishUpdateCycleFor:error:)` or `updater(_:didAbortWithError:)`. It only selects the alert text.
  A quit with zero windows open still terminates at once.
- Icon: with the `updates` element shown, `ShouldHandleShowingScheduledUpdate` returns `immediateFocus`, so a background find
  shows the icon instead of a window. `WillHandleShowingUpdate` sets the reminder only when its `handleShowingUpdate`
  argument is false, so a find Sparkle shows itself never flashes the icon. Attention and session end clear it. A click
  calls `checkForUpdates`. With the element hidden, Sparkle presents as usual. Hiding it while the icon waits only hides the
  icon (Eugene's choice, 2026-11-16): in Sparkle 2.9.6 the waiting session stops scheduled checks, so the update stays
  silent until Check for Updates, `update check`, or a relaunch whose next scheduled check finds it and Sparkle shows it.
- The menu item, the icon and `update.check` share one availability rule, so `update.check` works while the icon waits.

## Technical Details
- Restart wording (`QuitPrompt.restartMessage`), counting local Live sessions only:
  - this and the next launch Live, default state directory: "<n> sessions keep running and reconnect after the restart."
  - this and the next launch Live, custom `AGTERM_STATE_DIR`: sessions keep running; reopen agterm with the same
    `AGTERM_STATE_DIR` to reconnect.
  - this launch Live, the next not Live: sessions end at the next launch.
  - this launch not Live: running shells end.
  - windows attached from another Mac or an agterm-server host get their own line, worded from how they come back after
    a relaunch (Task 3 confirms that path first).
- `update.check`: no arguments; replies `started` with the host name of the Mac whose app answered, so a check sent from a
  session attached from another Mac says which Mac it started on. Refused without a feed or while that Mac cannot check.
  Read-back on the existing `version` response: `automaticChecks` (Bool) and `lastCheck` (ISO 8601, optional).
- `agterm-server` refuses `update.check`: updates apply to the Mac app; upgrade the server with `agterm-server install`.
- Updatetest recipe: `scripts/release.sh`-style build with `PRODUCT_BUNDLE_IDENTIFIER=com.umputun.agterm.updatetest`,
  `AGTERM_UPDATE_FEED=<local feed>` and two versions; Developer-ID signed so library validation matches a real release; a
  local appcast; `defaults write com.umputun.agterm.updatetest SULastCheckTime <old date>` and another app frontmost to force
  a scheduled, unfocused find. Its Sparkle preferences stay in its own defaults domain.

## What Goes Where
- **Implementation Steps**: code, tests, release script, cask template, docs
- **Post-Completion**: the tap cask edit and the first real update on Eugene's install

## Implementation Steps

### Task 1: Sparkle in the app, gated on a feed

**Files:**
- Modify: `project.yml`, `agterm/Info.plist`, `agterm/agtermApp+Menus.swift`, `agterm/AppDelegate.swift`, `ARCHITECTURE.md`,
  `.claude/rules/menu-actions.md`
- Create: `agterm/UpdateController.swift`, `agtermTests/UpdateControllerTests.swift`

- [x] Sparkle pinned to 2.9.6 (the version whose sources this plan was checked against) in `project.yml` for the app target only; `SUFeedURL` from `AGTERM_UPDATE_FEED`
      (empty by default)
- [x] the maintainer creates the EdDSA key pair with the package's `generate_keys` (Claude Code runs it after his yes); public
      key into `SUPublicEDKey`
- [x] `UpdateController` created only with a feed; Check for Updates… in the app menu, disabled without one
- [x] an ad-hoc `make release` build launches on an isolated state directory with Sparkle.framework loaded
- [x] ➕ ad-hoc Release builds sign with `agterm-adhoc.entitlements` (shipping set plus `disable-library-validation`):
      without it dyld refused Sparkle.framework on a Team-ID mismatch. `release.sh` rejects a Developer ID app carrying
      a `cs.` exception; CI pins both sets. Eugene approved 2026-11-16.
- [x] hosted tests: no updater and a disabled menu item without a feed; run them

### Task 2: Release signing, appcast and cask

**Files:**
- Modify: `scripts/release.sh`, `packaging/agterm.rb`, `.claude/rules/release.md`

- [x] pass `AGTERM_UPDATE_FEED`; sign Sparkle's nested code inside-out before the app (XPC services, `Autoupdate` and
      `Updater.app` before the framework that holds them), keeping the no-`--deep` rule
- [x] sign the DMG with `sign_update` from the resolved package's `bin/`, write `appcast.xml` (version, short version,
      `sparkle:minimumSystemVersion`, length, EdDSA signature, the CHANGELOG section as an embedded Markdown description),
      upload it in its own `gh release upload` after the DMG and tarballs succeed
- [x] `auto_updates true` in `packaging/agterm.rb`; the published tap cask gets the same line by hand (Post-Completion)
- [x] dry run without `--publish`: `codesign --verify --deep --strict` passes, notarization accepts the bundle, and the appcast
      passes `xmllint --noout` with Sparkle's `sign_update --verify` against the DMG
- [x] release rules document the key, the appcast and the cask line

### Task 3: Update flow and restart offer

**Files:**
- Create: `agtermCore/Sources/agtermCore/UpdateFlow.swift`, `agtermCore/Tests/agtermCoreTests/UpdateFlowTests.swift`
- Modify: `agtermCore/Sources/agtermCore/QuitPrompt.swift`, `agtermCore/Tests/agtermCoreTests/QuitPromptTests.swift`,
  `agterm/UpdateController.swift`, `agterm/AppDelegate.swift`
- ➕ Create: `agtermCore/Sources/agtermCore/WindowLibrary+Restart.swift`, `agtermCore/Tests/agtermCoreTests/WindowLibraryRestartTests.swift`
- ➕ Modify: `agtermCore/Sources/agtermCore/ControlResolve.swift`, `agtermCore/Tests/agtermCoreTests/ControlResolveTests.swift`,
  `agterm/agtermApp.swift`, `.claude/rules/windows.md`, `agtermTests/AppDelegateCaptureTests.swift` (unused-binding warning)

- [x] confirm in the pinned Sparkle sources the set and clear callbacks named in Solution Overview, and what Later leaves
      pending; correct this plan if they differ
- [x] confirm how attached-Mac and agterm-server windows come back after a relaunch, for their wording line
- [x] `UpdateFlow` quit state and `QuitPrompt.restartMessage`; `applicationShouldTerminate` asks `UpdateFlow` after its guards
- [x] `UpdateFlowTests`: update quit gets the update alert, Later cancels, a retry after Later gets it again, an ordinary quit
      after the session ends gets "Quit Agterm?"; `QuitPromptTests`: every wording case
- [x] run the task's tests
- [x] ➕ `WindowLibrary.restartCounts` counts this Mac's terminal rows (pages excluded) and flags rows from other hosts;
      `ControlResolve.isCustomStateDirectory` decides the AGTERM_STATE_DIR line (codex review)

### Task 4: Title-bar update icon

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppSettings.swift`, `agtermCore/Sources/agtermCore/UpdateFlow.swift`,
  `TitlebarComposition.swift`, `agterm/Views/WindowContentView+Titlebar.swift`, `agterm/UpdateController.swift`, `CLAUDE.md`,
  `.claude/rules/settings.md`
- Modify: `agtermCore/Tests/agtermCoreTests/UpdateFlowTests.swift`, `InterfaceMetricsTests.swift`, the existing title-bar render
  test file

- [ ] `InterfaceElement.updates` (title bar, shown by default) and its Settings ▸ Interface toggle; the approved #790
      exception line in `CLAUDE.md` and the element in `settings.md`
- [ ] reminder state in `UpdateFlow` and the gentle-reminder delegates as in Solution Overview; the icon at the far right,
      theme bright blue, outside the group counts
- [ ] show Eugene the icon in an updatetest build with a forced scheduled find; tests only after his verdict
- [ ] `UpdateFlowTests`: scheduled find sets the reminder, a find Sparkle shows does not, attention and session end clear it,
      hiding the element hides the icon and opens nothing; render test for the icon; Settings ▸ Interface still fits; run the task's tests

### Task 5: `agtermctl update check`, docs and acceptance

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`, `ControlDispatcher.swift`, `ControlActionsDefaults.swift`,
  `agtermCore/Sources/agtermctlKit/`, `agterm/Control/ControlServer+AppCommands.swift`, `AgtermServerKit` refusal text
- Modify: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests`-adjacent new file, dispatcher and CLI test files,
  `agtermUITests/ControlAPIUITests`-adjacent new file
- Modify: `site/docs.html` (update section, Interface settings entry, the `brew upgrade --cask` line at 2536),
  `site/commands.html`, `plugins/agterm/skills/agterm/SKILL.md`, `reference.md`, `.claude/rules/control-api.md`

- [ ] `update.check` through protocol, dispatcher, app action and CLI, with the host in the reply; `automaticChecks`/`lastCheck`
      on the `version` read-back; the `agterm-server` refusal
- [ ] protocol, dispatcher, CLI and UI tests: refused without a feed, refused on the server, accepted while a reminder waits
- [ ] docs: user guide update section (Sparkle flow, brew, restart wording, custom state directory), Interface entry, command
      reference, skill
- [ ] acceptance: confirm the live app holds `agterm.lock`; two updatetest builds, a local appcast, Live panes running work on
      an isolated state directory; after the update the same zmx and session-host PIDs are alive, `ps eww` shows where the
      relaunched app went (the isolated directory, or exited on the lock), and a manual reopen with the isolated directory
      reattaches
- [ ] `swift test`, `make test-app`, `make lint` once; move this plan to `docs/plans/completed/`

## Post-Completion
- add `auto_updates true` to the published tap cask by hand with the first release that ships Sparkle
- the first real update on Eugene's install (from the first Sparkle release to the next) verifies Sparkle's automatic reopen
  and Live reconnection; that path cannot be run on this Mac without touching the live state

Smells pre-check: skipped - non-Go project
