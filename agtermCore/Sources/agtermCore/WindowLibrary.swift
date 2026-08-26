import Foundation
import Observation

/// Metadata for one window — a named bundle of workspaces + sessions in its own macOS window.
/// Named `WindowInfo`, not `Window`, to avoid clashing with the SwiftUI/AppKit `Window` types.
public struct WindowInfo: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }

    /// Whether `name` is user-set; the title bar shows it only when true, so "window N" stays hidden.
    public var hasCustomName: Bool { !Self.isAutoName(name) }

    /// Whether `name` matches `WindowLibrary.defaultWindowName`: "window" plus a positive integer.
    public static func isAutoName(_ name: String) -> Bool {
        let parts = name.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0] == "window", let number = Int(parts[1]), number >= 1 else { return false }
        return true
    }
}

/// One entry in the persisted window index: id, name, and open-at-quit, which drives reopen-all.
public struct WindowEntry: Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var isOpen: Bool

    public init(id: UUID, name: String, isOpen: Bool) {
        self.id = id
        self.name = name
        self.isOpen = isOpen
    }
}

/// The persisted `windows.json` index: ordered window list plus frontmost id. `version` is independent of
/// `Snapshot.version` (the per-window file shape) so the two evolve separately.
public struct WindowsIndex: Codable, Equatable, Sendable {
    /// Bumped when the index shape changes; a mismatch makes the index count as absent.
    public static let currentVersion = 1

    public var version: Int
    public var frontmost: UUID?
    public var windows: [WindowEntry]

    public init(version: Int = WindowsIndex.currentVersion, frontmost: UUID? = nil, windows: [WindowEntry] = []) {
        self.version = version
        self.frontmost = frontmost
        self.windows = windows
    }
}

/// The app-global owner of the window set: ordered window metadata, lazily-loaded per-window `AppStore`s,
/// the open-set, the frontmost id, and per-window + index persistence. `@Observable` so SwiftUI tracks the
/// window list + frontmost id; all access is main-actor isolated. A window is "open" iff its `AppStore` is
/// loaded; the persisted open-set in `windows.json` records which to reopen on the next launch.
///
/// Recovery contract (never throws, mirrors `PersistenceStore.load()`): a corrupt or version-mismatched
/// `windows.json` counts as absent → migrate legacy `workspaces.json` if present, else seed one window; a
/// missing/corrupt per-window file opens with an empty `Snapshot` (one default workspace + session), so the
/// window set is always valid and non-empty.
@Observable
@MainActor
public final class WindowLibrary {
    /// The ordered window metadata, for the menu/palette.
    public private(set) var windows: [WindowInfo]

    /// App-wide recent closed sessions/workspaces, newest first. Reopening inserts into the active window;
    /// independent of window reopen semantics.
    public private(set) var recentClosedItems: [RecentClosedItem]

    /// The id of the frontmost on-screen window, mirrored into the index on change. Outlives the window
    /// only when it was the last one closed, so the index records which window the user exited from.
    /// Resolving it to a live window guards on the store being loaded, so that survivor still reads as
    /// "none open"; sites that only compare or reassign the raw id are unaffected either way.
    public var frontmostWindowID: UUID?

    /// Live per-window stores. `@ObservationIgnored`: read imperatively (scene/control), never by a view.
    @ObservationIgnored private var stores: [UUID: AppStore]

    /// The state directory (AGTERM_STATE_DIR-aware): the index here, per-window files in `windows/`.
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let recentClosedStore: RecentClosedStore
    /// One bounded run-identified ring shared by every window store for this library/app lifetime.
    @ObservationIgnored private let controlEventRing: ControlEventRing
    @ObservationIgnored private var treeEventDebouncers: [UUID: Debouncer]
    @ObservationIgnored private var isBootstrapping = true

    /// Set once the launch reopen-all has run, so the per-window scene `.task` drives it exactly once.
    @ObservationIgnored public private(set) var hasReopened = false

    /// FIFO of window ids each freshly-appearing SwiftUI window pops on appear: the plain `WindowGroup`
    /// (one window at launch, one per `openWindow()`) gives a window no presented id. Seeded with the open
    /// set, launch window first, by `consumeReopen()`.
    @ObservationIgnored private var pendingClaim: [UUID] = []

    /// The launch id already adopted via `adoptLaunchWindowID()`'s fallback; `consumeReopen()` excludes it
    /// from the seeded queue so the first reopened window can't claim it twice.
    @ObservationIgnored private var adoptedLaunchID: UUID?

    /// Set at quit so per-window `willClose` close-reporting no-ops — the open-set must survive for the
    /// next launch's reopen-all instead of being zeroed as each window tears down.
    @ObservationIgnored public var isTerminating = false

    private static let indexFileName = "windows.json"
    private static let windowsSubdirectory = "windows"
    private static let legacyFileName = "workspaces.json"

    private var indexURL: URL { directory.appendingPathComponent(Self.indexFileName) }
    private var windowsDirectory: URL { directory.appendingPathComponent(Self.windowsSubdirectory, isDirectory: true) }

    /// Creates the library rooted at `directory`, running migration/recovery per the recovery contract.
    public init(directory: URL = PersistenceStore.defaultDirectory,
                controlEventRing: ControlEventRing? = nil) {
        self.directory = directory
        self.recentClosedStore = RecentClosedStore(directory: directory)
        self.controlEventRing = controlEventRing ?? ControlEventRing()
        self.treeEventDebouncers = [:]
        self.stores = [:]
        self.windows = []
        self.recentClosedItems = recentClosedStore.load()
        self.frontmostWindowID = nil
        bootstrap()
        isBootstrapping = false
    }

    // MARK: - Lookup

    public func store(for id: UUID?) -> AppStore? {
        guard let id else { return nil }
        return stores[id]
    }

    /// The frontmost open window's id, falling back to the first open window when the frontmost is
    /// unset/closed — the resolution every window-keyed seam uses. Nil only when all windows are closed
    /// (the app is quitting).
    public var activeWindowID: UUID? {
        if let frontmostWindowID, stores[frontmostWindowID] != nil { return frontmostWindowID }
        for id in windows.map(\.id) where stores[id] != nil { return id }
        return nil
    }

    /// The store for `activeWindowID` — how the action/control/settings seams resolve what to act on.
    /// Non-nil in practice (never windowless at launch); nil only when all windows are closed.
    public var activeStore: AppStore? {
        store(for: activeWindowID)
    }

    public func isOpen(_ id: UUID) -> Bool {
        stores[id] != nil
    }

    /// Auto-hide-inactive-sidebars driver: the frontmost open window shows its sidebar, every OTHER open one
    /// collapses (a lone window is force-shown). The caller gates on `autoHideSidebarInactiveWindows` and
    /// calls it on every frontmost change plus once when the toggle flips on. `setSidebarVisible` no-ops an
    /// already-correct window, so only changed windows write/persist/notify.
    public func applyInactiveWindowSidebarHiding() {
        guard let active = activeWindowID else { return }
        for id in openIDs() {
            stores[id]?.setSidebarVisible(id == active)
        }
    }

    /// The window set projected into the `window.list` payload, in window order. The `geometry` closure
    /// supplies each open window's live frame app-side (NSWindow handles live in `WindowRegistry`, not this
    /// host-free model); nil by default so tests and non-AppKit callers get a geometry-free list.
    public func controlWindowNodes(geometry: (WindowInfo.ID) -> ControlWindowFrame? = { _ in nil },
                                   flags: (WindowInfo.ID) -> (fullscreen: Bool, zoomed: Bool, minimized: Bool)? = { _ in nil })
        -> [ControlWindowNode] {
        let active = activeWindowID
        return windows.map {
            // auto-follow timeout + sidebar visibility come from the per-window store, the frame +
            // fullscreen/zoom/minimized flags from the app-side closures; both nil for a closed window.
            let live = flags($0.id)
            return ControlWindowNode(id: $0.id.uuidString, name: $0.name, open: isOpen($0.id), active: $0.id == active,
                                     autoFollowMs: stores[$0.id]?.autoFollowMs,
                                     sidebarVisible: stores[$0.id]?.sidebarVisible,
                                     geometry: geometry($0.id),
                                     fullscreen: live?.fullscreen, zoomed: live?.zoomed,
                                     minimized: live?.minimized)
        }
    }

    /// Reads the app-wide ring and maps both pages and cursor failures onto the stable control response.
    public func readEvents(_ options: ControlEventReadOptions) -> ControlResponse {
        switch controlEventRing.read(cursor: options.cursor, kinds: options.kinds, limit: options.limit) {
        case .batch(let batch):
            return ControlResponse(ok: true, result: ControlResult(events: batch))
        case .failure(let error, let anchor):
            return ControlResponse(ok: false, result: ControlResult(events: anchor), error: error.rawValue)
        }
    }

    /// Test/quit seam: fires every pending structural invalidation synchronously, even one queued for a
    /// window already removed from the catalog.
    func flushTreeEvents() {
        for debouncer in treeEventDebouncers.values { debouncer.flush() }
    }

    /// Resolve a control window target against the ordered window set. All known windows are candidates,
    /// closed ones included; `active` resolves like `activeWindowID`.
    public func resolveWindow(_ target: String) -> TargetResolution {
        ControlResolve.resolve(target, candidates: windows.map(\.id), active: activeWindowID)
    }

    /// The persisted open-set in window order, for the launch reopen-all.
    public func openIDs() -> [UUID] {
        windows.map(\.id).filter { stores[$0] != nil }
    }

    /// Every session across all open windows, flattened — the walk the per-session sweeps share
    /// (restore-running-command capture + `restore.clear`).
    public func allOpenSessions() -> [Session] {
        openIDs().compactMap { stores[$0] }.flatMap { $0.workspaces.flatMap(\.sessions) }
    }

    /// The total unseen count across every session in every OPEN window — what the Dock badge shows,
    /// rolling up the `Session.unseenCount` the sidebar's red pills track. Reads only observable state
    /// (`windows`, each store's `workspaces`, `unseenCount`), so a `withObservationTracking` observer
    /// re-fires on a bump, a focus/select clear, and a session add/remove. A window CLOSE drops a store,
    /// which is NOT observable — the app refreshes the badge explicitly in the `willClose` teardown.
    public var totalUnseenCount: Int {
        allOpenSessions().reduce(0) { $0 + $1.unseenCount }
    }

    /// Open-window count plus total sessions across them — the counts the quit confirmation reports.
    public func openCounts() -> (windows: Int, sessions: Int) {
        let openStores = windows.map(\.id).compactMap { stores[$0] }
        let sessions = openStores.reduce(0) { total, store in
            total + store.workspaces.reduce(0) { $0 + $1.sessions.count }
        }
        return (openStores.count, sessions)
    }

    /// The id SwiftUI's auto-opened launch window claims: the frontmost open window, else the first, nil
    /// when all are closed. Guards the frontmost on openness — one pointing at a closed window must fall
    /// through, else `consumeReopen` seeds a closed id and undercounts the open set.
    private var launchWindowID: UUID? {
        if let frontmostWindowID, stores[frontmostWindowID] != nil { return frontmostWindowID }
        return openIDs().first
    }

    /// Latches the launch reopen-all so it runs once across the per-window scene `.task`s, seeds the claim
    /// queue with the open set, and returns the ADDITIONAL `openWindow()` calls needed beyond SwiftUI's
    /// auto-opened launch window — N-1 for N open windows (≥0), 0 on every later call.
    ///
    /// The launch window takes exactly one id: from the queue (this ran before its `.onAppear`) or from
    /// `adoptLaunchWindowID()`'s fallback (its `.onAppear` ran first); an already-adopted id is excluded so
    /// the first reopened window can't claim it twice. The N-1 count is the same either way.
    public func consumeReopen() -> Int {
        guard !hasReopened else { return 0 }
        hasReopened = true
        let open = openIDs()
        let ordered = (launchWindowID.map { [$0] } ?? []) + open.filter { $0 != launchWindowID }
        pendingClaim = ordered.filter { $0 != adoptedLaunchID }
        return max(open.count - 1, 0)
    }

    /// Pops the next window id for a freshly-appearing SwiftUI window to render. Nil once the queue is
    /// drained — a window beyond the open set (e.g. a SwiftUI-restored extra), which the app dismisses.
    public func claimNextWindowID() -> UUID? {
        guard !pendingClaim.isEmpty else { return nil }
        return pendingClaim.removeFirst()
    }

    /// The launch window's fallback id when its `.onAppear` beats the scene `.task`'s queue seeding. Records
    /// it as adopted so a later `consumeReopen()` excludes it — else the first reopened window claims it
    /// again and two windows bind one store. Only the FIRST caller gets an id; a second (several restored
    /// windows all hitting the empty-queue fallback) gets nil and dismisses itself, as does an all-closed set.
    public func adoptLaunchWindowID() -> UUID? {
        guard adoptedLaunchID == nil, let id = launchWindowID else { return nil }
        adoptedLaunchID = id
        return id
    }

    /// Enqueues a window id for the next appearing SwiftUI window to adopt (`newWindow` + `openWindow()`, or
    /// a `window.select`/reveal of a closed window). Dedups on queue MEMBERSHIP only, so a repeated
    /// `window.select` before the first claim is consumed never spawns two windows; it must NOT also skip an
    /// id whose store is loaded, since `newWindow` pre-loads the store and the window would self-dismiss.
    /// The "already on-screen, raise instead of spawn" check lives in `WindowRegistry.raise`.
    public func enqueueClaim(_ id: UUID) {
        guard !pendingClaim.contains(id) else { return }
        pendingClaim.append(id)
    }

    /// The id of the OPEN window owning the given session, or nil — closed windows aren't loaded/searched.
    public func windowID(forSession sessionID: UUID) -> UUID? {
        for id in windows.map(\.id) where stores[id]?.session(withID: sessionID) != nil { return id }
        return nil
    }

    /// The open store owning the given session — backs cross-window targeting (reveal + ControlServer).
    public func store(forSession sessionID: UUID) -> AppStore? {
        store(for: windowID(forSession: sessionID))
    }

    /// The id of the open window backed by `store` (by identity) — the reverse of `store(for:)`, for
    /// reaching a window's per-window controllers (quick terminal / zoom / dashboard).
    public func windowID(for store: AppStore) -> UUID? {
        openIDs().first { stores[$0] === store }
    }

    /// The window's display name, "" for a nil or unknown id — the name half of the
    /// `{AGT_WINDOW_NAME}`/`$AGT_WINDOW_NAME` command context.
    public func windowName(for id: UUID?) -> String {
        guard let id else { return "" }
        return windows.first { $0.id == id }?.name ?? ""
    }

    public var defaultWindowName: String {
        "window \(windows.count + 1)"
    }

    // MARK: - Mutation

    /// Creates a window seeded with "workspace 1" and one $HOME session, opens it, and persists the index.
    /// Defaults the name to "window N".
    @discardableResult
    public func newWindow(name: String? = nil) -> WindowInfo {
        // the name feeds {AGT_WINDOW_NAME}; see TerminalText.
        let info = WindowInfo(name: name.map(TerminalText.sanitized)?.trimmedOrNil ?? defaultWindowName)
        let store = makeStore(for: info.id, persistence: persistenceStore(for: info.id))
        let workspace = store.addWorkspace(name: "workspace 1")
        store.addSession(toWorkspace: workspace.id, cwd: FileManager.default.homeDirectoryForCurrentUser.path)
        windows.append(info)
        stores[info.id] = store
        // mark frontmost now so the window-keyed seams target it immediately instead of waiting on its
        // first `didBecomeKey` — which loses to the File-menu focus returning to the previous window.
        frontmostWindowID = info.id
        saveIndex()
        return info
    }

    /// Lazily builds (or returns the cached) `AppStore` from `windows/<id>.json`, marks the window open, and
    /// persists. Nil for an id with no index entry.
    ///
    /// `launchRestore` marks an APP-BOOTSTRAP load — passed only by `reopen`/`recoverOrphanedWindows`, and
    /// the only thing that arms anything executable: a session's persisted `session.restore` override and
    /// the captured `foregroundCommand`/`splitForegroundCommand`. False by default because
    /// `ContentView.resolveStore()` calls this at RUNTIME for a mid-process reopen, which must not execute.
    @discardableResult
    public func loadStore(for id: UUID, launchRestore: Bool = false) -> AppStore? {
        guard windows.contains(where: { $0.id == id }) else { return nil }
        if let existing = stores[id] { return existing }
        let persistence = persistenceStore(for: id)
        let store = makeStore(for: id, persistence: persistence)
        let snapshot = persistence.load()
        store.restore(from: snapshot, launchRestore: launchRestore)
        stores[id] = store
        let carriedCaptures = snapshot.workspaces.contains { workspace in
            workspace.sessions.contains { $0.foregroundCommand != nil || $0.splitForegroundCommand != nil }
        }
        if launchRestore {
            // the replay is armed in the sessions' TRANSIENT slots, which `snapshot()` never serializes, so
            // strip the FILE now and nothing can put the argv back: the persisted fields are already nil,
            // and a save landing before the surfaces spawn writes that nil. Without the strip the argv
            // would outlive its one replay whenever no save happens at all, and a crash would run it again
            // next launch. If the strip fails, disarm instead: losing a restore to a disk error beats
            // re-running the user's command unasked.
            if carriedCaptures, !stripCaptures(from: snapshot, into: persistence) {
                for session in store.workspaces.flatMap(\.sessions) {
                    session.pendingForegroundCommand = nil
                    session.pendingSplitForegroundCommand = nil
                }
            }
        } else {
            // the launch-only gate just dropped any captured foreground command from the live sessions;
            // rewrite the snapshot too, or the stale argv survives on disk and a force-quit before the
            // next save replays it on the following launch — after the user last saw this window as a
            // plain shell.
            if carriedCaptures { store.save() }
            for workspace in store.workspaces {
                for session in workspace.sessions { store.emitSessionCreated(session, workspace: workspace.id) }
            }
            store.scheduleTreeChanged()
        }
        saveIndex()
        return store
    }

    /// Rewrites `snapshot` without the one-shot foreground captures, leaving every other field — including
    /// the sticky `restoreCommand` override, which fires again on the next launch. Returns whether the
    /// write landed; the caller disarms the live sessions when it did not.
    private func stripCaptures(from snapshot: Snapshot, into persistence: PersistenceStore) -> Bool {
        var stripped = snapshot
        for workspaceIndex in stripped.workspaces.indices {
            for sessionIndex in stripped.workspaces[workspaceIndex].sessions.indices {
                stripped.workspaces[workspaceIndex].sessions[sessionIndex].foregroundCommand = nil
                stripped.workspaces[workspaceIndex].sessions[sessionIndex].splitForegroundCommand = nil
            }
        }
        do {
            try persistence.save(stripped)
            return true
        } catch {
            log("stripCaptures failed: \(error)")
            return false
        }
    }

    @discardableResult
    public func reopenRecentClosed(_ itemID: UUID, into targetStore: AppStore? = nil) -> Bool {
        refreshRecentClosedItems()
        guard let item = recentClosedItems.first(where: { $0.id == itemID }),
              let store = targetStore ?? activeStore,
              store.restoreRecentClosed(item)
        else { return false }
        recentClosedStore.remove(itemID)
        refreshRecentClosedItems()
        return true
    }

    @discardableResult
    public func reopenLatestRecentClosed(into targetStore: AppStore? = nil) -> Bool {
        refreshRecentClosedItems()
        guard let item = recentClosedItems.first else { return false }
        return reopenRecentClosed(item.id, into: targetStore)
    }

    public func clearRecentClosedItems() {
        recentClosedStore.clear()
        refreshRecentClosedItems()
    }

    /// Closes a window: drops its store and persists the index. The app-target caller tears down the
    /// window's surfaces first. No-op for an unknown/closed id, or while terminating (see `isTerminating`).
    public func closeWindow(_ id: UUID) {
        guard !isTerminating else { return }
        // cancel any queued claim so a window still attaching can't re-open it after a close that raced
        // its registration (window.new immediately followed by window.close).
        pendingClaim.removeAll { $0 == id }
        guard let store = stores[id] else { return }
        for workspace in store.workspaces {
            for session in workspace.sessions { store.emitSessionClosed(session, workspace: workspace.id) }
        }
        store.scheduleTreeChanged()
        stores[id] = nil
        // the persisted `frontmost` is what the next launch's `reopen` fallback picks, and nil there
        // sends it to `windows.first`. Pin unconditionally on the close that empties the open set, so a
        // frontmost left nil or stale by `removeWindow` still reopens the exit window; otherwise hand it
        // to a live window, which guards on the store being loaded.
        if openIDs().isEmpty {
            frontmostWindowID = id
        } else if frontmostWindowID == id {
            frontmostWindowID = activeWindowID
        }
        saveIndex()
    }

    /// Renames a window; the name lives only in the index. An empty/whitespace-only name is ignored.
    public func renameWindow(_ id: UUID, to name: String) {
        // the name feeds {AGT_WINDOW_NAME}; see TerminalText.
        guard let trimmed = TerminalText.sanitized(name).trimmedOrNil, let index = windows.firstIndex(where: { $0.id == id }) else { return }
        guard windows[index].name != trimmed else { return }
        windows[index].name = trimmed
        scheduleTreeChanged(for: id)
        saveIndex()
    }

    /// Whether a window may be removed — one window is always kept.
    public var canRemoveWindow: Bool { windows.count > 1 }

    /// Removes a window: drops its store, deletes its per-window file, removes the index entry, and
    /// persists. No-ops on the last window. Clears `frontmostWindowID` if it pointed at the removed one.
    public func removeWindow(_ id: UUID) {
        guard canRemoveWindow, let index = windows.firstIndex(where: { $0.id == id }) else { return }
        if let store = stores[id] {
            for workspace in store.workspaces {
                for session in workspace.sessions { store.emitSessionClosed(session, workspace: workspace.id) }
            }
        }
        scheduleTreeChanged(for: id)
        // cancel the pending debounced save BEFORE deleting the file: a ~0.3 s save from a just-before-delete
        // selectSession/setFontSize outlives the delete-path willClose (which skips its own save, the window
        // being closed) and would land after removeItem, re-creating windows/<id>.json as an orphan that a
        // future index loss resurrects via recoverOrphanedWindows().
        stores[id]?.cancelPendingSave()
        // sweep each session's rendered `.text` watermark PNG before dropping the store: window-DELETE
        // destroys its sessions permanently and has no later sweep, unlike window-CLOSE. Ids come from the
        // live store when open, the persisted snapshot when closed — else a closed window's PNGs orphan in
        // <stateDir>/watermarks/. `directory` is the same root WatermarkStorage resolves against, so passing
        // it is production-identical and lets a test sweep into an injected temp dir.
        let sessionIDsToSweep: [UUID] = stores[id].map { $0.workspaces.flatMap(\.sessions).map(\.id) }
            ?? persistenceStore(for: id).load().workspaces.flatMap(\.sessions).map(\.id)
        for sessionID in sessionIDsToSweep {
            WatermarkStorage.removeRenderedText(sessionID: sessionID, stateDir: directory)
        }
        stores[id] = nil
        windows.remove(at: index)
        if frontmostWindowID == id { frontmostWindowID = nil }
        // best-effort: a missing/never-written per-window file is fine to "fail" to remove.
        try? FileManager.default.removeItem(at: windowFileURL(for: id))
        saveIndex()
    }

    /// Clears every session's font-size override across ALL windows — open ones through their live store,
    /// closed ones by rewriting `windows/<id>.json`. A closed window must drop its stale sizes too, else it
    /// reopens overriding the new global default. No-ops a window with no overrides.
    public func resetSessionFontSizesAllWindows() {
        for info in windows {
            if let store = stores[info.id] {
                store.resetSessionFontSizes()
                continue
            }
            clearClosedWindowFontSizes(info.id)
        }
    }

    /// Strips every `fontSize` override from a closed window's snapshot, rewriting only when something
    /// changed so untouched windows don't churn. Best-effort: a missing/corrupt file loads as empty (no
    /// overrides to clear) and a write failure is swallowed.
    private func clearClosedWindowFontSizes(_ id: UUID) {
        let persistence = persistenceStore(for: id)
        var snapshot = persistence.load()
        var changed = false
        for w in snapshot.workspaces.indices {
            for s in snapshot.workspaces[w].sessions.indices where snapshot.workspaces[w].sessions[s].fontSize != nil {
                snapshot.workspaces[w].sessions[s].fontSize = nil
                changed = true
            }
        }
        guard changed else { return }
        try? persistence.save(snapshot)
    }

    // MARK: - Persistence

    /// Flushes every open window's store — the quit-time flush persisting cwd changes made since the last
    /// structural mutation.
    public func saveAllOpen() {
        saveAllOpenChecked()
    }

    /// `saveAllOpen()` that REPORTS whether every window's write landed, for a caller whose acknowledgement
    /// must not outrun the disk. Every store is attempted before the verdict, so one unwritable window does
    /// not skip the others. Same shape as `AppStore.saveChecked` one layer down.
    @discardableResult
    public func saveAllOpenChecked() -> Bool {
        var allLanded = true
        for store in stores.values where !store.saveChecked() { allLanded = false }
        return allLanded
    }

    /// Finalizes any grace-period session/workspace closes in open windows before a window/app teardown.
    public func finalizeAllPendingCloses() {
        for store in stores.values { store.finalizeAllPendingCloses() }
    }

    /// Writes `windows.json`: ordered window list with open flags, plus the frontmost id. A write failure
    /// is logged and swallowed.
    public func saveIndex() {
        let entries = windows.map { WindowEntry(id: $0.id, name: $0.name, isOpen: stores[$0.id] != nil) }
        let index = WindowsIndex(frontmost: frontmostWindowID, windows: entries)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(index).write(to: indexURL, options: .atomic)
        } catch {
            log("saveIndex failed: \(error)")
        }
    }

    // MARK: - Bootstrap (migration + recovery)

    /// Resolves the window set on init: a valid `windows.json`; else recover orphaned `windows/<id>.json`
    /// files into a fresh index (so a schema bump invalidating the index doesn't lose the trees); else
    /// migrate legacy `workspaces.json`; else seed one window. Reopens the persisted open-set, never
    /// windowless — falls back to the frontmost/first window.
    private func bootstrap() {
        if let index = loadIndex() {
            windows = index.windows.map { WindowInfo(id: $0.id, name: $0.name) }
            frontmostWindowID = index.frontmost
            reopen(index)
            return
        }
        if recoverOrphanedWindows() { return }
        if migrateLegacy() { return }
        newWindow()
    }

    /// Reads `windows.json`; a missing/corrupt/version-mismatched file reads as nil, so the caller falls
    /// through to recovery/migration/seeding.
    private func loadIndex() -> WindowsIndex? {
        guard let data = try? Data(contentsOf: indexURL) else { return nil }
        guard let index = try? JSONDecoder().decode(WindowsIndex.self, from: data) else { return nil }
        guard index.version == WindowsIndex.currentVersion, !index.windows.isEmpty else { return nil }
        return index
    }

    /// Reopens the persisted open-set, falling back to the frontmost (else the first) so the app is never
    /// windowless. The frontmost is used only when it still exists in `windows` — a stale id (a deleted
    /// window) would no-op `loadStore` and leave the app windowless.
    private func reopen(_ index: WindowsIndex) {
        for entry in index.windows where entry.isOpen { loadStore(for: entry.id, launchRestore: true) }
        guard openIDs().isEmpty else { return }
        let frontmostExists = index.frontmost.map { id in windows.contains { $0.id == id } } ?? false
        let fallback = (frontmostExists ? index.frontmost : nil) ?? windows.first?.id
        if let fallback { loadStore(for: fallback, launchRestore: true) }
    }

    /// Recovers surviving `windows/<id>.json` files into a fresh index rather than falling through to
    /// legacy/seeding, which would discard the user's sessions. Each UUID-stemmed file becomes an OPEN
    /// window named "window N" in filename order, so numbering and the frontmost pick (the first) are
    /// deterministic; non-UUID stems are skipped. False when nothing is recoverable. All orphans open means
    /// the launch reopen-all puts them on screen at once — acceptable for this rare path.
    @discardableResult
    private func recoverOrphanedWindows() -> Bool {
        let contents = (try? FileManager.default.contentsOfDirectory(at: windowsDirectory,
                                                                     includingPropertiesForKeys: nil)) ?? []
        let ids = contents
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) }
        guard !ids.isEmpty else { return false }
        let infos = ids.enumerated().map { WindowInfo(id: $0.element, name: "window \($0.offset + 1)") }
        // append ALL infos FIRST — `loadStore` guards on `windows.contains(id)` and would silently no-op.
        windows.append(contentsOf: infos)
        for info in infos {
            guard let store = loadStore(for: info.id, launchRestore: true) else { continue }
            // recovery cannot tell a deliberately-closed window's surviving file from one open at the
            // loss (per-window snapshots carry no open marker), and a stale file — written by an older
            // build, or an exit capture resurrected abnormally — may carry a command the user last saw
            // closed. Drop the one-shot captures and persist; the sticky `session.restore` override
            // stays armed (the user pinned it to fire on every restart).
            // disarm the TRANSIENT slots: `loadStore` armed those, not the persisted fields, so clearing
            // the latter here would leave every recovered window's capture live and replaying.
            var stripped = false
            for session in store.workspaces.flatMap(\.sessions)
            where session.pendingForegroundCommand != nil || session.pendingSplitForegroundCommand != nil {
                session.pendingForegroundCommand = nil
                session.pendingSplitForegroundCommand = nil
                stripped = true
            }
            if stripped { store.save() }
        }
        frontmostWindowID = infos.first?.id
        saveIndex()
        return true
    }

    /// Wraps a legacy `workspaces.json` into one window ("window 1"): writes its snapshot to
    /// `windows/<id>.json` + an index marking it open/frontmost, and opens it. False when no legacy file.
    @discardableResult
    private func migrateLegacy() -> Bool {
        let legacy = PersistenceStore(directory: directory, fileName: Self.legacyFileName)
        let snapshot = legacy.load()
        guard !snapshot.workspaces.isEmpty else { return false }
        // windows is empty here, so `defaultWindowName` yields "window 1".
        let info = WindowInfo(name: defaultWindowName)
        let store = makeStore(for: info.id, persistence: persistenceStore(for: info.id))
        store.restore(from: snapshot, launchRestore: true)
        store.save()
        windows = [info]
        stores[info.id] = store
        frontmostWindowID = info.id
        saveIndex()
        return true
    }

    // MARK: - Helpers

    private func windowFileURL(for id: UUID) -> URL {
        windowsDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    private func persistenceStore(for id: UUID) -> PersistenceStore {
        PersistenceStore(directory: windowsDirectory, fileName: "\(id.uuidString).json")
    }

    private func makeStore(for windowID: UUID, persistence: PersistenceStore) -> AppStore {
        AppStore(
            persistence: persistence,
            recentClosedStore: recentClosedStore,
            recentClosedDidChange: { [weak self] in self?.refreshRecentClosedItems() },
            controlEventSink: { [weak self] draft in
                guard let self else { return }
                guard !self.isBootstrapping else { return }
                if draft.kind == .treeChanged {
                    self.scheduleTreeChanged(for: windowID)
                    return
                }
                self.controlEventRing.append(ControlEventDraft(
                    kind: draft.kind,
                    window: windowID.uuidString,
                    workspace: draft.workspace,
                    session: draft.session,
                    payload: draft.payload
                ))
            }
        )
    }

    private func scheduleTreeChanged(for windowID: UUID) {
        let debouncer = treeEventDebouncers[windowID] ?? Debouncer()
        treeEventDebouncers[windowID] = debouncer
        debouncer.schedule(after: 0.1) { [weak self] in
            self?.controlEventRing.append(ControlEventDraft(kind: .treeChanged, window: windowID.uuidString))
        }
    }

    private func refreshRecentClosedItems() {
        recentClosedItems = recentClosedStore.load()
    }

    private func log(_ message: @autoclosure () -> String) {
        NSLog("agterm: %@", message())
    }
}
