import Foundation
import Observation

/// Metadata for one window — a named bundle of workspaces + sessions rendered in its
/// own on-screen macOS window. Named `WindowInfo` (not `Window`) to avoid clashing with
/// SwiftUI/AppKit `Window` types in the app target.
public struct WindowInfo: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }

    /// Whether `name` is a user-set name rather than an auto-assigned default. The title bar shows
    /// the window name only when this is true, so default "window N" names stay hidden.
    public var hasCustomName: Bool { !Self.isAutoName(name) }

    /// Whether `name` matches the auto-assigned scheme `WindowLibrary.defaultWindowName` produces —
    /// the literal word "window" followed by a positive integer ("window 1", "window 2", …).
    public static func isAutoName(_ name: String) -> Bool {
        let parts = name.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0] == "window", let number = Int(parts[1]), number >= 1 else { return false }
        return true
    }
}

/// One entry in the persisted window index: identity, name, and whether the window was
/// open at quit (drives reopen-all on the next launch).
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

/// The persisted `windows.json` index: the ordered window list plus the frontmost id.
/// Carries its own `version`, deliberately independent of `Snapshot.version` (the
/// per-window file shape) so the two can evolve separately.
public struct WindowsIndex: Codable, Equatable, Sendable {
    /// Bumped when the index shape changes; a mismatch makes the loader treat it as absent.
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

/// The app-global owner of the window set: the ordered window metadata, the lazily-loaded
/// per-window `AppStore`s, the open-set, and the frontmost id, plus per-window + index
/// persistence.
///
/// `@Observable @MainActor` like `AppStore` — SwiftUI observes the window list and frontmost
/// id, and all access is main-actor isolated. A window is "open" iff its `AppStore` is loaded
/// (`stores[id] != nil`); the persisted open-set in `windows.json` records which to reopen on
/// the next launch.
///
/// Recovery contract (never throws to the caller, mirrors `PersistenceStore.load()`): a
/// corrupt or version-mismatched `windows.json` is treated as absent → migrate from legacy
/// `workspaces.json` if present, else seed one window. A missing/corrupt per-window file opens
/// that window with an empty `Snapshot` (one default workspace + session). The app always
/// reaches a valid, non-empty window set.
@Observable
@MainActor
public final class WindowLibrary {
    /// The ordered window metadata, for the menu/palette.
    public private(set) var windows: [WindowInfo]

    /// App-wide recent closed sessions/workspaces, newest first. Reopening inserts the saved item into
    /// the active window; this list is independent of window reopen semantics.
    public private(set) var recentClosedItems: [RecentClosedItem]

    /// The id of the frontmost on-screen window, mirrored into the index on change.
    public var frontmostWindowID: UUID?

    /// Live per-window stores. A window is open iff it has a loaded store. `@ObservationIgnored`:
    /// read imperatively (scene/control), not by any SwiftUI view.
    @ObservationIgnored private var stores: [UUID: AppStore]

    /// The state directory (AGTERM_STATE_DIR-aware); the index lives here and per-window files in
    /// the `windows/` subdirectory.
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let recentClosedStore: RecentClosedStore
    /// One bounded run-identified ring shared by every window store for this library/app lifetime.
    @ObservationIgnored private let controlEventRing: ControlEventRing
    @ObservationIgnored private var treeEventDebouncers: [UUID: Debouncer]
    @ObservationIgnored private var isBootstrapping = true

    /// Set once the launch reopen-all has run, so the scene `.task` (which fires per window) drives
    /// it exactly once. `@ObservationIgnored`: a launch-flow latch, not view state.
    @ObservationIgnored public private(set) var hasReopened = false

    /// FIFO of window ids each freshly-appearing SwiftUI window claims as its own. The scene is a
    /// plain `WindowGroup` (which auto-opens one window at launch and one per `openWindow()`), so a
    /// window has no presented id — it pops the next id here on appear instead. Seeded with the open
    /// set (launch window first) by `consumeReopen()`. `@ObservationIgnored`: a launch-flow queue.
    @ObservationIgnored private var pendingClaim: [UUID] = []

    /// The launch id the launch window adopted via the pre-seed fallback (`adoptLaunchWindowID()`),
    /// when its `.onAppear` ran before the scene `.task` seeded the queue. `consumeReopen()` excludes
    /// it from the seeded queue so the first reopened window can't claim it a second time (the
    /// duplicate-store collision). `@ObservationIgnored`: a launch-flow latch.
    @ObservationIgnored private var adoptedLaunchID: UUID?

    /// Set at quit so the per-window `willClose` close-reporting becomes a no-op — the open-set must
    /// be preserved for the next launch's reopen-all, not zeroed as each window tears down on quit.
    @ObservationIgnored public var isTerminating = false

    private static let indexFileName = "windows.json"
    private static let windowsSubdirectory = "windows"
    private static let legacyFileName = "workspaces.json"

    private var indexURL: URL { directory.appendingPathComponent(Self.indexFileName) }
    private var windowsDirectory: URL { directory.appendingPathComponent(Self.windowsSubdirectory, isDirectory: true) }

    /// Creates the library rooted at `directory`, running migration/recovery so the resulting
    /// window set is always valid and non-empty.
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

    /// The live store of an open window, or nil when the window is closed/unknown.
    public func store(for id: UUID?) -> AppStore? {
        guard let id else { return nil }
        return stores[id]
    }

    /// The frontmost open window's id, falling back to the first open window (in window order)
    /// when the frontmost id is unset/closed. The app-side seams that key off the window — the
    /// frontmost store and the frontmost quick terminal — resolve through this. Nil only in the
    /// degenerate all-windows-closed state (the app is quitting).
    public var activeWindowID: UUID? {
        if let frontmostWindowID, stores[frontmostWindowID] != nil { return frontmostWindowID }
        for id in windows.map(\.id) where stores[id] != nil { return id }
        return nil
    }

    /// The frontmost open window's store, falling back to the first open store (in window order)
    /// when the frontmost id is unset/closed. The app-side action/control/settings seams resolve
    /// the store to act on through this — it stays non-nil because the library is never windowless
    /// at launch. Nil only in the degenerate all-windows-closed state (the app is quitting).
    public var activeStore: AppStore? {
        store(for: activeWindowID)
    }

    /// Whether the window is currently open (its store is loaded).
    public func isOpen(_ id: UUID) -> Bool {
        stores[id] != nil
    }

    /// Auto-hide-inactive-sidebars driver: the frontmost open window shows its sidebar and every OTHER
    /// open window collapses its own. With a single open window it force-shows that (active) window's
    /// sidebar and collapses nothing. Host-free so it is unit-testable; the app-side caller gates it on the
    /// `autoHideSidebarInactiveWindows` setting and invokes it on every frontmost change (and once when the
    /// toggle flips on). `setSidebarVisible` no-ops a window already in its target state, so the
    /// write/persist/notify happens only for the windows that actually change.
    public func applyInactiveWindowSidebarHiding() {
        guard let active = activeWindowID else { return }
        for id in openIDs() {
            stores[id]?.setSidebarVisible(id == active)
        }
    }

    /// The window set projected into the `window.list` control payload (id/name + open/active flags),
    /// in window order.
    /// The `geometry` closure supplies each open window's live on-screen frame; it is app-side (the NSWindow
    /// handles live in `WindowRegistry`, not this host-free model), defaulting to nil so unit tests and any
    /// non-AppKit caller get a geometry-free list.
    public func controlWindowNodes(geometry: (WindowInfo.ID) -> ControlWindowFrame? = { _ in nil },
                                   flags: (WindowInfo.ID) -> (fullscreen: Bool, zoomed: Bool)? = { _ in nil })
        -> [ControlWindowNode] {
        let active = activeWindowID
        return windows.map {
            // reach each open store for its auto-follow timeout + sidebar visibility (per-window state); a
            // closed window has no store and reports nil for both. The frame + fullscreen/zoom flags come
            // from the app-side closures (nil for a closed window with no NSWindow).
            let live = flags($0.id)
            return ControlWindowNode(id: $0.id.uuidString, name: $0.name, open: isOpen($0.id), active: $0.id == active,
                                     autoFollowMs: stores[$0.id]?.autoFollowMs,
                                     sidebarVisible: stores[$0.id]?.sidebarVisible,
                                     geometry: geometry($0.id),
                                     fullscreen: live?.fullscreen, zoomed: live?.zoomed)
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

    /// Test/quit seam: synchronously fires every pending per-window structural invalidation,
    /// including one queued for a window that has just been removed from the catalog.
    func flushTreeEvents() {
        for debouncer in treeEventDebouncers.values { debouncer.flush() }
    }

    /// Resolve a control window target against the library's ordered window set. All known windows are
    /// candidates, including closed windows; `active` resolves to the frontmost open window, with the
    /// same fallback as `activeWindowID`.
    public func resolveWindow(_ target: String) -> TargetResolution {
        ControlResolve.resolve(target, candidates: windows.map(\.id), active: activeWindowID)
    }

    /// The persisted open-set in window order, for the launch reopen-all. A window is open iff
    /// its store is loaded.
    public func openIDs() -> [UUID] {
        windows.map(\.id).filter { stores[$0] != nil }
    }

    /// Every session across all open windows, flattened — the shared walk for the per-session sweeps
    /// (restore-running-command capture + `restore.clear`).
    public func allOpenSessions() -> [Session] {
        openIDs().compactMap { stores[$0] }.flatMap { $0.workspaces.flatMap(\.sessions) }
    }

    /// The total unseen-notification count across every session in every OPEN window — the number the
    /// Dock tile badge shows (`DockBadgeController`), the app-wide roll-up of the same `Session.unseenCount`
    /// the sidebar's red pills track. Reads the observable `windows` list, each open store's `workspaces`,
    /// and each session's `unseenCount`, so a `withObservationTracking` observer over this re-fires on a
    /// notification bump, a focus/select clear, and a session add/remove. A window CLOSE drops a store
    /// (`@ObservationIgnored stores`), which is NOT observable — the app refreshes the badge explicitly on
    /// the `willClose` teardown for that case.
    public var totalUnseenCount: Int {
        allOpenSessions().reduce(0) { $0 + $1.unseenCount }
    }

    /// The number of currently-open windows and the total number of sessions across them — the
    /// counts the quit confirmation reports. A window is open iff its store is loaded.
    public func openCounts() -> (windows: Int, sessions: Int) {
        let openStores = windows.map(\.id).compactMap { stores[$0] }
        let sessions = openStores.reduce(0) { total, store in
            total + store.workspaces.reduce(0) { $0 + $1.sessions.count }
        }
        return (openStores.count, sessions)
    }

    /// The id SwiftUI's auto-opened launch window claims: the frontmost open window, else the first.
    /// `nil` only in the degenerate all-windows-closed state. Guards the frontmost on openness (like
    /// `activeWindowID`) — a frontmost pointing at a closed window must fall through to the first open
    /// one, else `consumeReopen` seeds a closed id and undercounts the open set.
    private var launchWindowID: UUID? {
        if let frontmostWindowID, stores[frontmostWindowID] != nil { return frontmostWindowID }
        return openIDs().first
    }

    /// Latches the launch reopen-all so it runs once across the per-window scene `.task`s, seeding
    /// the claim queue with the open set and returning the *additional* `openWindow()` calls needed
    /// beyond the one window SwiftUI auto-opens at launch. So with N open windows it returns N-1 (each
    /// ≥0). Empty on every subsequent call.
    ///
    /// The launch window takes exactly one id: via the queue (when this runs before its `.onAppear`)
    /// or via `adoptLaunchWindowID()`'s fallback (when its `.onAppear` ran first). An already-adopted
    /// launch id is excluded from the queue so the first reopened window can't claim it a second time
    /// (two windows binding one store — the duplicate-store collision). The N-1 count is independent
    /// of which path the launch window took.
    public func consumeReopen() -> Int {
        guard !hasReopened else { return 0 }
        hasReopened = true
        let open = openIDs()
        // launch window first, then the rest in window order — minus any id the fallback already
        // handed the launch window (so it isn't claimed twice).
        let ordered = (launchWindowID.map { [$0] } ?? []) + open.filter { $0 != launchWindowID }
        pendingClaim = ordered.filter { $0 != adoptedLaunchID }
        return max(open.count - 1, 0)
    }

    /// Pops the next window id for a freshly-appearing SwiftUI window to render. Returns nil once the
    /// queue is drained (a window beyond the open set — e.g. a SwiftUI-restored extra — which the app
    /// dismisses).
    public func claimNextWindowID() -> UUID? {
        guard !pendingClaim.isEmpty else { return nil }
        return pendingClaim.removeFirst()
    }

    /// The launch window's fallback id when its `.onAppear` fires before the scene `.task` seeds the
    /// claim queue. Records the id as adopted so a later `consumeReopen()` excludes it from the queue
    /// — without this, `consumeReopen` re-seeds the launch id and the first reopened window claims it
    /// again, leaving two windows bound to one store. Idempotent-per-launch: only the FIRST caller gets
    /// the launch id; a second caller before `consumeReopen()` runs (SwiftUI restored more than one
    /// window, each hitting the empty-queue fallback) gets nil and dismisses itself, so two windows
    /// can't both bind the one launch store. Returns nil in the degenerate all-windows-closed state.
    public func adoptLaunchWindowID() -> UUID? {
        guard adoptedLaunchID == nil, let id = launchWindowID else { return nil }
        adoptedLaunchID = id
        return id
    }

    /// Enqueues a window id to be claimed by the next appearing window — used when the app opens a
    /// window (`newWindow` + `openWindow()`, or a `window.select` / reveal of a closed window), so the
    /// new SwiftUI window adopts that id. Pure queue-membership dedup: an id already pending (a repeated
    /// `window.select` of the same window before the first claim is consumed) is not appended again, so
    /// one bundle never spawns two windows. It does NOT skip an id whose store is loaded — `newWindow`
    /// pre-loads the store before enqueueing, so a store-loaded guard would silently drop the claim and
    /// the spawned window would self-dismiss. The "already on-screen, raise instead of spawn" check
    /// lives at the call site (`WindowRegistry.raise`), not here.
    public func enqueueClaim(_ id: UUID) {
        guard !pendingClaim.contains(id) else { return }
        pendingClaim.append(id)
    }

    /// The id of the open window that owns the given session, or nil when no open window has it.
    /// Searches only OPEN windows (closed windows aren't loaded).
    public func windowID(forSession sessionID: UUID) -> UUID? {
        for id in windows.map(\.id) where stores[id]?.session(withID: sessionID) != nil { return id }
        return nil
    }

    /// The open store that owns the given session, searching only OPEN windows. Backs cross-window
    /// session targeting (notification reveal + ControlServer).
    public func store(forSession sessionID: UUID) -> AppStore? {
        store(for: windowID(forSession: sessionID))
    }

    /// The id of the open window backed by `store` (by identity), or nil — the reverse of `store(for:)`,
    /// used to reach a window's per-window controllers (quick terminal / zoom / dashboard) from its store.
    public func windowID(for store: AppStore) -> UUID? {
        openIDs().first { stores[$0] === store }
    }

    /// The display name of the window with `id`, or "" when `id` is nil or no window has that id — the
    /// name half of the `{AGT_WINDOW_NAME}`/`$AGT_WINDOW_NAME` command context.
    public func windowName(for id: UUID?) -> String {
        guard let id else { return "" }
        return windows.first { $0.id == id }?.name ?? ""
    }

    /// The auto-generated name for the next new window (`window 1`, `window 2`, …).
    public var defaultWindowName: String {
        "window \(windows.count + 1)"
    }

    // MARK: - Mutation

    /// Creates a fresh window seeded with one default workspace ("workspace 1") and one session
    /// at $HOME (the seeding that used to live in the app's `restoredStore()`), opens it (loads
    /// its store), and persists the index. Defaults the name to "window N".
    @discardableResult
    public func newWindow(name: String? = nil) -> WindowInfo {
        let info = WindowInfo(name: name?.trimmedOrNil ?? defaultWindowName)
        let store = makeStore(for: info.id, persistence: persistenceStore(for: info.id))
        let workspace = store.addWorkspace(name: "workspace 1")
        store.addSession(toWorkspace: workspace.id, cwd: FileManager.default.homeDirectoryForCurrentUser.path)
        windows.append(info)
        stores[info.id] = store
        // a newly created window is the active one: mark it frontmost so the seams that key off the
        // window (the active store, the command palette, the quick terminal) target it immediately,
        // rather than waiting on the new on-screen window's first `didBecomeKey` (which loses to the
        // File-menu focus returning to the previous window after New Window).
        frontmostWindowID = info.id
        saveIndex()
        return info
    }

    /// Lazily builds (or returns the cached) `AppStore` for a window, loading its persisted
    /// `windows/<id>.json` (an empty `Snapshot` when missing/corrupt, per the recovery contract).
    /// No-op returning nil for an id with no index entry. Marks the window open and persists.
    ///
    /// `launchRestore` marks an APP-BOOTSTRAP load — passed only by `reopen`/`recoverOrphanedWindows`,
    /// and the only thing that arms a session's persisted `session.restore` override for this launch. It
    /// defaults to false because `ContentView.resolveStore()` calls this at RUNTIME when a closed window
    /// is reopened mid-process, which must not execute anything.
    @discardableResult
    public func loadStore(for id: UUID, launchRestore: Bool = false) -> AppStore? {
        guard windows.contains(where: { $0.id == id }) else { return nil }
        if let existing = stores[id] { return existing }
        let persistence = persistenceStore(for: id)
        let store = makeStore(for: id, persistence: persistence)
        store.restore(from: persistence.load(), launchRestore: launchRestore)
        stores[id] = store
        if !launchRestore {
            for workspace in store.workspaces {
                for session in workspace.sessions { store.emitSessionCreated(session, workspace: workspace.id) }
            }
            store.scheduleTreeChanged()
        }
        saveIndex()
        return store
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

    /// Closes a window: drops its store (marking it closed) and persists the index. The caller
    /// (app target) tears down the window's surfaces first — `WindowLibrary` only drops the store.
    /// No-op for an unknown/closed id, or while terminating (the open-set must survive for reopen-all).
    public func closeWindow(_ id: UUID) {
        guard !isTerminating else { return }
        // cancel any queued claim for this id so a window still attaching can't re-open it after a
        // close that raced its registration (window.new immediately followed by window.close).
        pendingClaim.removeAll { $0 == id }
        guard let store = stores[id] else { return }
        for workspace in store.workspaces {
            for session in workspace.sessions { store.emitSessionClosed(session, workspace: workspace.id) }
        }
        store.scheduleTreeChanged()
        stores[id] = nil
        if frontmostWindowID == id { frontmostWindowID = activeWindowID }
        saveIndex()
    }

    /// Renames a window (and its open store is unaffected — the name lives only in the index).
    /// An empty/whitespace-only name is ignored. Persists the index.
    public func renameWindow(_ id: UUID, to name: String) {
        guard let trimmed = name.trimmedOrNil, let index = windows.firstIndex(where: { $0.id == id }) else { return }
        guard windows[index].name != trimmed else { return }
        windows[index].name = trimmed
        scheduleTreeChanged(for: id)
        saveIndex()
    }

    /// Whether a window may be removed: one window is always kept, so removal is allowed only
    /// when more than one exists.
    public var canRemoveWindow: Bool { windows.count > 1 }

    /// Removes a window: drops its store, deletes its per-window file, removes the index entry,
    /// and persists. No-ops unless more than one window exists (the last one is kept). Clears
    /// `frontmostWindowID` if it pointed at the removed window.
    public func removeWindow(_ id: UUID) {
        guard canRemoveWindow, let index = windows.firstIndex(where: { $0.id == id }) else { return }
        if let store = stores[id] {
            for workspace in store.workspaces {
                for session in workspace.sessions { store.emitSessionClosed(session, workspace: workspace.id) }
            }
        }
        scheduleTreeChanged(for: id)
        // cancel the store's pending debounced save BEFORE deleting the file — a save scheduled by a
        // just-before-delete selectSession/setFontSize captures the store weakly and fires ~0.3 s out;
        // since the delete-path willClose teardown skips its own save() (the window is no longer open),
        // an un-cancelled pending save would fire after removeItem and re-create windows/<id>.json as an
        // orphan that a future index loss would resurrect via recoverOrphanedWindows().
        stores[id]?.cancelPendingSave()
        // sweep each session's rendered `.text` watermark PNG before dropping the store: deleting a window
        // permanently destroys its sessions (like closeSession/removeWorkspace), so their PNGs must go too —
        // window-CLOSE keeps the sessions and is handled elsewhere, but window-DELETE has no later sweep.
        // An OPEN window's session ids come from its live store; a CLOSED one has no store, so read them from
        // the persisted snapshot — else deleting a closed window orphans its PNGs in <stateDir>/watermarks/.
        // `directory` is the state-dir root WatermarkStorage resolves against (both default to
        // AGTERM_STATE_DIR else PersistenceStore.defaultDirectory), so passing it is production-identical
        // and lets a test sweep into an injected temp dir without touching process-global env.
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

    /// Clears every session's per-window font-size override across ALL windows — open ones through
    /// their live store, closed ones by rewriting the persisted `windows/<id>.json` in place. A global
    /// font/appearance change resets every surface to the new default, so a closed window must drop its
    /// stale per-session sizes too, else it reopens later overriding the new default. No-ops a window
    /// (open or closed) whose snapshot has no overrides.
    public func resetSessionFontSizesAllWindows() {
        for info in windows {
            if let store = stores[info.id] {
                store.resetSessionFontSizes()
                continue
            }
            clearClosedWindowFontSizes(info.id)
        }
    }

    /// Loads a closed window's snapshot, strips every `fontSize` override, and rewrites the file only
    /// when something changed (so it doesn't churn untouched windows). Best-effort: a missing/corrupt
    /// file loads as empty (no overrides to clear) and a write failure is swallowed by the store.
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

    /// Flushes every open window's store, so per-window cwd changes since the last structural
    /// mutation are persisted (the quit-time flush the app's terminate path drives).
    public func saveAllOpen() {
        for store in stores.values { store.save() }
    }

    /// Finalizes any grace-period session/workspace closes in open windows before a window/app teardown.
    public func finalizeAllPendingCloses() {
        for store in stores.values { store.finalizeAllPendingCloses() }
    }

    /// Writes `windows.json`: the ordered window list (with each window's open flag) and the
    /// frontmost id. A write failure is logged and swallowed.
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

    /// Resolves the window set on init: load `windows.json` if valid; else recover orphaned per-window
    /// `windows/<id>.json` files into a fresh index when any are present (so a future schema bump that
    /// invalidates the index doesn't lose the trees); else migrate from legacy `workspaces.json`; else
    /// seed one empty window. Reopens the persisted open-set (never windowless — falls back to the
    /// frontmost/first window).
    private func bootstrap() {
        if let index = loadIndex() {
            windows = index.windows.map { WindowInfo(id: $0.id, name: $0.name) }
            frontmostWindowID = index.frontmost
            reopen(index)
            return
        }
        // index unreadable but per-window files survive: recover them rather than discard the user's
        // sessions (a future schema bump that invalidates the index must not lose the trees).
        if recoverOrphanedWindows() { return }
        if migrateLegacy() { return }
        // no index, no orphans, and no legacy file: seed one empty default-named window ("window 1").
        newWindow()
    }

    /// Reads `windows.json`, treating a missing/corrupt/version-mismatched file as absent (nil),
    /// so the caller falls through to migration/seeding.
    private func loadIndex() -> WindowsIndex? {
        guard let data = try? Data(contentsOf: indexURL) else { return nil }
        guard let index = try? JSONDecoder().decode(WindowsIndex.self, from: data) else { return nil }
        guard index.version == WindowsIndex.currentVersion, !index.windows.isEmpty else { return nil }
        return index
    }

    /// Reopens the persisted open-set after loading the index: loads a store for each window
    /// marked open. If none were open, opens the frontmost (else the first) so the app is never
    /// windowless. The frontmost id is used only when it actually exists in `windows` — a stale
    /// frontmost (pointing at a deleted window) would otherwise no-op `loadStore` and leave the app
    /// windowless; in that case fall through to the first window.
    private func reopen(_ index: WindowsIndex) {
        for entry in index.windows where entry.isOpen { loadStore(for: entry.id, launchRestore: true) }
        guard openIDs().isEmpty else { return }
        let frontmostExists = index.frontmost.map { id in windows.contains { $0.id == id } } ?? false
        let fallback = (frontmostExists ? index.frontmost : nil) ?? windows.first?.id
        if let fallback { loadStore(for: fallback, launchRestore: true) }
    }

    /// When `windows.json` is unreadable/version-mismatched but per-window `windows/<id>.json` files
    /// survive, recovers them into a fresh index instead of falling through to legacy/seeding (which
    /// would discard the user's sessions). Each file whose name stem is a valid UUID becomes an OPEN
    /// window named "window N", numbered in filename order so the numbering and the frontmost pick are
    /// deterministic; the first recovered window becomes frontmost. Files with a non-UUID stem are
    /// skipped. Returns false when no recoverable per-window files exist (the caller then tries
    /// legacy migration, else seeds). Recovering every orphan as open means the launch reopen-all
    /// opens them all on screen at once — acceptable for this rare recovery path.
    @discardableResult
    private func recoverOrphanedWindows() -> Bool {
        let contents = (try? FileManager.default.contentsOfDirectory(at: windowsDirectory,
                                                                     includingPropertiesForKeys: nil)) ?? []
        // stable filename order so "window N" numbering and the frontmost pick are deterministic.
        let ids = contents
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) }
        guard !ids.isEmpty else { return false }
        let infos = ids.enumerated().map { WindowInfo(id: $0.element, name: "window \($0.offset + 1)") }
        // append ALL infos FIRST — loadStore(for:) guards on `windows.contains(id)`, so loading a
        // store before the append would silently no-op.
        windows.append(contentsOf: infos)
        for info in infos { loadStore(for: info.id, launchRestore: true) }
        frontmostWindowID = infos.first?.id
        saveIndex()
        return true
    }

    /// If `windows.json` is absent but legacy `workspaces.json` exists, wraps it into one window
    /// ("window 1"): writes the loaded snapshot to `windows/<id>.json` + the index marking it
    /// open/frontmost, and opens it. Returns false (no migration) when no legacy file exists.
    @discardableResult
    private func migrateLegacy() -> Bool {
        let legacy = PersistenceStore(directory: directory, fileName: Self.legacyFileName)
        let snapshot = legacy.load()
        guard !snapshot.workspaces.isEmpty else { return false }
        // first window, so `defaultWindowName` yields "window 1" (windows is empty at this point).
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

    /// The per-window persistence file `windows/<id>.json`.
    private func windowFileURL(for id: UUID) -> URL {
        windowsDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    /// A `PersistenceStore` pointed at the window's `windows/<id>.json` file.
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
