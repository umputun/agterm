# Persistent browser storage for URL overlays

## Overview
- A URL overlay keeps its cookies, `localStorage` and IndexedDB only in memory: every page gets its own
  `WKWebsiteDataStore.nonPersistent()`, so a login or cookie-saved app state is gone on every close.
- `agtermctl session overlay open --url URL --persistent` opens the page on one persistent store shared by
  all persistent pages of this agterm state directory. A login made there is still there on the next open
  and after an app relaunch.
- The default is unchanged: without the flag a page is isolated and in memory. File pages (`--html`) are
  always in memory.
- `agtermctl browser clear` removes everything the persistent store holds. Each `htmlOverlays` entry reports
  `persistent`.

## Context (from discovery)
- Store choice: `agterm/Views/HtmlOverlayRegistry.swift:155` (`HtmlOverlayPage.init`,
  `configuration.websiteDataStore = .nonPersistent()`). `HtmlOverlayRegistry.shared` owns every page by id,
  soft-closed ones included, until `HtmlOverlayReleases` releases it. `install()` is called with no
  directory from `AppDelegate.swift:83` and from tests.
- Model: `agtermCore/Sources/agtermCore/HtmlOverlay.swift` (`javascript`, `navigation`, `chromeless`).
- The path `--js` takes, which `--persistent` mirrors: CLI `agtermctlKit/SessionCommands.swift:566-618`,
  `ControlArgs.javascript` and `OverlayHtmlError` in `ControlProtocol.swift`, validation in
  `ControlDispatcher+Overlay.swift:40,131`, `ControlDispatcherOptions.swift`, host construction in
  `agterm/Control/ControlServer+SessionActions.swift:66`, read-back `ControlHtmlOverlayNode` in
  `ControlProjection.swift:400-450` (`chromeless` decodes with `decodeIfPresent ... ?? false`).
- State directory: `agtermApp.swift:70` resolves it once and hands it to stores built as
  `LiveResetMarkerStore(directory:)`, `SettingsStore(directory:)`.
- `ControlActions` already has `async` methods (`windowNew`, `typeSession`); the connection waits for
  `server.dispatch` before writing the reply (`ControlServer.swift:482`). App-wide adapters live in
  `agterm/Control/ControlServer+AppCommands.swift`.
- Page bridge: only file pages get it; `HtmlBridge.windowless` lists commands that take no window.
- Existing storage test: `agtermTests/HtmlOverlayRegistryTests.swift:488`
  (`testBrowserStorageLastsThroughAReloadButNotIntoTheNextOverlay`), on an in-process listener.
  Socket round trips: `agtermTests/ControlServerTests.swift`.
- "Gone when it closes" is stated in `.claude/rules/control-api.md:452`,
  `plugins/agterm/skills/agterm/SKILL.md:755`, `reference.md:851`, `site/commands.html:1783`.
- Deployment target is macOS 14 (`project.yml`), which `WKWebsiteDataStore(forIdentifier:)` requires.

## Development Approach
- **testing approach**: tests first for everything host-free in `agtermCore` (profile id file, protocol,
  dispatcher, projection, CLI); hosted tests on the in-process listener for the WebKit store and one hosted
  socket round trip. No new XCUITest.
- run only the tests a task touches; the full gates (`make build`, `swift test`, `make test-app`,
  `make lint`) run once, in the last task.
- `agtermCore` stays free of WebKit/AppKit: it owns the profile id and the wire contract, the app owns the
  store.
- **CRITICAL: update this plan file when scope changes during implementation**

## Testing Strategy
- **unit tests**: profile id is created when the file is missing and reused after; a second directory gets
  a different id; an unreadable or malformed file is an error and the file is left as it was;
  `--persistent` refusals; `persistent` on the node and a node encoded without it decodes as false; wire
  round trips; CLI flag conflicts and the `browser clear` request.
- **hosted tests** (`agtermTests`, local listener, a temporary state directory per test):
  - a server cookie with `Max-Age`, a `localStorage` value and an IndexedDB record survive close plus a new
    persistent overlay;
  - a non-persistent page sees none of them, before and after;
  - two persistent pages open at once share them;
  - two profile ids do not share them;
  - `browser clear` empties the store, is refused while a persistent page is registered, a soft-closed one
    included, and works when no profile was ever created;
  - a persistent open that arrives while a clear is in flight is refused, driven by holding the removal's
    completion, never by a sleep;
  - a persistent open against an unreadable profile file is refused and opens nothing.
- **hosted socket test**: `browser.clear` and `session.overlay.open --url --persistent` over the socket,
  the clear reply arriving after the removal completes.
- Each hosted test configures the registry with its own profile, and on teardown releases its pages and
  the registry's cached store, then calls `WKWebsiteDataStore.remove(forIdentifier:)`, then deletes the
  temporary directory. WebKit keeps the data under `~/Library/WebKit/<bundle id>/WebsiteDataStore/<UUID>`,
  outside the state directory, and refuses to remove a store still referenced.

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix, blockers with ⚠️ prefix

## Solution Overview
- **One profile per state directory.** `BrowserProfile` (agtermCore) reads a UUID from
  `<stateDir>/browser-profile`, creating it when the file is missing. The app builds the store with
  `WKWebsiteDataStore(forIdentifier:)`. A fixed UUID is rejected: WebKit keys the on-disk location by
  bundle id and UUID only, so every instance, an isolated test instance included, would share one jar.
- **A profile that cannot be read is an error, never a new profile.** A regenerated id would silently drop
  every saved login and orphan the old store. A persistent open then fails with the error and opens
  nothing; it does not fall back to in-memory storage. `browser.clear` fails the same way.
- **Opt-in per page.** `HtmlOverlay.persistent` travels with the page like `javascript`. The host resolves
  the profile store in the open adapter, before the overlay is accepted into the model, so the page
  constructor stays non-throwing. A persistent URL page gets the shared store and every other page
  `.nonPersistent()`, as today.
- **URL only.** `--persistent` with `--html` or a command is refused by name in the dispatcher and the CLI.
- **Clear.** `browser.clear` removes all website data types from the profile and keeps its UUID. It works
  with no overlay open. It is refused while any persistent page is registered, in any window and in the
  soft-close window, because a live page holds its login in memory and writes it back. While the removal
  is in flight the registry is in a clearing state and refuses a persistent open; in-memory pages are
  unaffected. The reply is sent after WebKit reports the removal done.
- **Bridge.** A file page may call `browser.clear` like any other command; it joins `HtmlBridge.windowless`.
  URL pages have no bridge.
- **Read-back and exemptions.** `ControlHtmlOverlayNode.persistent`. `browser.clear` has no tree
  read-back, no event and no menu item; `control-api.md` records these as deliberate.

## Technical Details
- `BrowserProfile(directory: URL)` with `identifier() throws -> UUID`: missing file writes a new UUID
  atomically; a read error or content that is not a UUID throws, naming the file. Foundation only.
- Wire: `ControlArgs.persistent: Bool?`; `OverlayHtmlError.persistentRequiresURL`
  (`session.overlay.open: --persistent requires --url`); `Command.browserClear = "browser.clear"`;
  `ControlActions.clearBrowser() async -> ControlResponse` with its unsupported default;
  `BrowserClearError.pagesOpen` (`browser.clear refused: N persistent page(s) still open`) and
  `BrowserClearError.clearing` (`browser storage is being cleared`).
- App: the registry gets `BrowserProfile` from `agtermApp.init`, set separately from `install()`. It
  builds the store on the first persistent open or the first clear, so an instance that never uses the
  feature writes no id file and no WebKit profile. A clear with no id file replies ok without creating one.
- Limits, stated in the docs and not solved here:
  - an external login (OAuth, SSO, a popup) still does not work: the page stays pinned to its origin and
    off-origin links go to the system browser, whose cookies are separate;
  - cookies ignore ports, so two apps on `localhost` with different ports share cookies in the profile;
  - a cookie with no `Max-Age`/`Expires` is a session cookie and is not promised to outlive the app;
  - clearing local data does not log the user out on the server.

## What Goes Where
- **Implementation Steps**: code, tests, docs in this repo.
- **Post-Completion**: nothing external.

## Implementation Steps

### Task 1: Profile id and the `--persistent` wire contract (agtermCore, CLI)

**Files:**
- Create: `agtermCore/Sources/agtermCore/BrowserProfile.swift`
- Create: `agtermCore/Tests/agtermCoreTests/BrowserProfileTests.swift`
- Modify: `agtermCore/Sources/agtermCore/HtmlOverlay.swift`, `ControlProtocol.swift`,
  `ControlDispatcher+Overlay.swift`, `ControlDispatcherOptions.swift`, `ControlProjection.swift`,
  `AppStore+HtmlOverlay.swift`
- Modify: `agtermCore/Sources/agtermctlKit/SessionCommands.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/{HtmlOverlayTests,ControlDispatcherOverlayTests,AppStoreTreeProjectionTests,ControlProtocolTests}.swift`,
  `agtermCore/Tests/agtermctlKitTests/OverlayCommandsTests.swift`

- [x] write `BrowserProfile` tests: created when missing, reused, distinct per directory, unreadable and
      malformed files throw and stay untouched
- [x] implement `BrowserProfile`
- [x] write protocol, dispatcher, projection and CLI tests for `persistent`: wire round trip, accepted
      with `--url`, refused with `--html` and with a command, reported on the node, a node without the
      key decodes as false, absent flag encodes nothing
- [x] carry `persistent` through `ControlArgs`, options, `HtmlOverlay`, the node and the CLI flag
- [x] run the touched `agtermCore` tests

### Task 2: The persistent store in the app

**Files:**
- Modify: `agterm/Views/HtmlOverlayRegistry.swift`, `agterm/Control/ControlServer+SessionActions.swift`,
  `agterm/agtermApp.swift`
- Modify: `agtermTests/HtmlOverlayRegistryTests.swift`

- [x] give the registry its `BrowserProfile` and a lazily built store, with a way to release the cached
      store; a persistent URL page uses it, every other page keeps `.nonPersistent()`
- [x] resolve the store in the open adapter before the overlay is accepted; a profile error refuses the
      open and opens nothing
- [x] hosted tests: cookie, `localStorage` and IndexedDB survive close and reopen; non-persistent page
      isolated; two live pages share; two profile ids do not share; unreadable profile refuses the open;
      each test removes its WebKit profile
- [x] measure where the installed framework writes the profile, for `control-api.md`
- [x] run the touched hosted tests

### Task 3: `browser.clear`

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`, `ControlDispatcher.swift`,
  `ControlActionsDefaults.swift`, `HtmlBridge.swift`
- Modify: `agtermCore/Sources/agtermctlKit/MiscCommands.swift`, `Commands.swift`
- Modify: `agterm/Views/HtmlOverlayRegistry.swift`, `agterm/Control/ControlServer+AppCommands.swift`,
  `agterm/Control/ControlServer.swift` (the unhandled-command list only)
- Create: `agtermTests/ControlServerBrowserTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/{ControlDispatcherTests,ControlProtocolTests,HtmlBridgeTests}.swift`,
  `agtermCore/Tests/agtermctlKitTests/CommandsTests.swift`, `agtermTests/HtmlOverlayRegistryTests.swift`

- [x] protocol command, awaited dispatch to `ControlActions.clearBrowser`, unsupported default,
      `windowless` bridge entry, CLI `agtermctl browser clear`, with tests
- [x] registry clear: refuse while a persistent page is registered; otherwise enter the clearing state,
      remove all data types, leave it, reply; a persistent open during the clearing state is refused
- [x] hosted tests: clear then reopen is empty; refused with a persistent page open and with one
      soft-closed; ok with no profile ever created; an open during a held removal is refused
- [x] hosted socket test: persistent open and `browser.clear` over the socket, reply after completion
- [x] run the touched tests

### Task 4: Update documentation
- [x] `.claude/rules/control-api.md`: replace the storage line with the two-mode contract, the profile id
      file and its error rule, the on-disk location, the clear rule, and the no-read-back, no-event,
      no-menu exemptions of `browser.clear`
- [x] `plugins/agterm/skills/agterm/SKILL.md` (a trigger in `description` and the URL section) and
      `reference.md`
- [x] `site/commands.html` (`--persistent`, `persistent` read-back, `browser clear`) and `site/docs.html`,
      limits included

### Task 5: Verify acceptance criteria
- [x] every Overview item is implemented and the default path is unchanged
      (`testBrowserStorageLastsThroughAReloadButNotIntoTheNextOverlay` still passes untouched)
- [x] relaunch persistence in an isolated Debug instance against a local fixture server: set a cookie with
      `Max-Age`, `localStorage` and IndexedDB, stop the instance, launch it again, read them back; then
      `browser clear` and read again; remove the instance's WebKit profile afterwards
- [x] `make build`, `cd agtermCore && swift test`, `make test-app`, `make lint`, each once
- [x] move this plan to `docs/plans/completed/`

## Post-Completion
**Not in this change:**
- named profiles (`--profile NAME`), a menu item for clearing, making persistence the default.

Smells pre-check: skipped — non-Go project
