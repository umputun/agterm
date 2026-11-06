import agtermCore
import Foundation

extension ControlServer: CompanionDuplicating {}

extension ControlServer {
    static let companionMoveError = "a companion moves only among its siblings"

    // a page companion's page is the row: these act on a terminal, or would cover or float the page
    private static let pageRefusedCommands: Set<Command> = [
        .sessionType, .sessionText, .sessionCopy, .sessionPaste, .sessionSelectAll, .sessionSearch, .sessionBackground,
        .sessionLead, .sessionSwap, .sessionFocus, .sessionResize, .sessionSplit, .sessionSplitClose, .sessionScratch,
        .sessionRestart, .sessionRestore, .sessionOverlayOpen, .sessionHudOpen,
    ]

    /// pageCompanionRefusal answers a request a page companion cannot take, before any command runs, so a
    /// socket client and a page's bridge meet one refusal.
    func pageCompanionRefusal(_ request: ControlRequest) -> ControlResponse? {
        let floats = request.cmd == .sessionOverlayResize && request.args?.full != true
        let terminalAsk = request.cmd == .askOpen && request.args?.style != "gui"
        // `active` for these means the window's zoom target, never the selection, and a hide is idempotent
        let namedSurface = (request.cmd == .surfaceCursor || (request.cmd == .surfaceZoom && request.args?.mode != "hide"))
            && request.target.map { $0 != "active" } == true
        guard Self.pageRefusedCommands.contains(request.cmd) || floats || terminalAsk || namedSurface else { return nil }
        let target = request.target.map(Self.sessionPart(ofSurface:))
        guard case .success(let (store, id)) = resolver.resolveSessionTarget(target, window: request.args?.window),
              store.session(withID: id)?.content == .page else { return nil }
        return ControlResponse(ok: false, error: "\(request.cmd.rawValue): not available on a page companion")
    }

    // a `surface:<session>:<slot>` address names its session in the middle
    private static func sessionPart(ofSurface target: String) -> String {
        let parts = target.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0] == "surface" ? String(parts[1]) : target
    }

    func createCompanion(_ target: String?, options: CompanionOptions, window: String?) async -> ControlResponse {
        let (store, id): (AppStore, UUID)
        switch resolver.resolveSessionTarget(target, window: window) {
        case .failure(let response): return response
        case .success(let resolved): (store, id) = resolved
        }
        if store.session(withID: id)?.remoteHost != nil {
            return await createRemoteCompanion(.terminal(options), of: id, in: store, select: options.select)
        }
        return createLocalCompanion(id, in: store, options: options)
    }

    private func createLocalCompanion(_ id: UUID, in store: AppStore, options: CompanionOptions) -> ControlResponse {
        switch store.addCompanion(to: id, options: options) {
        case .failure:
            return ControlResponse(ok: false, error: "could not create companion")
        case .success(let companion):
            if options.select, store === library.activeStore { actions.focusActiveSession() }
            return ControlResponse(ok: true, result: ControlResult(id: companion.id.uuidString,
                                                                   parent: companion.parentID?.uuidString))
        }
    }

    // a batch of companions alone that moved nothing was refused, while one carrying a parent may be a no-op
    func refusesCompanionMove(_ ids: [UUID], in store: AppStore) -> Bool {
        ids.allSatisfy { store.session(withID: $0)?.parentID != nil }
    }

    /// closeRoots are the ids a close acts on: a companion named beside its parent leaves the list, since the
    /// parent's close takes it and records it in the parent's group.
    func closeRoots(_ ids: [UUID], in store: AppStore) -> [UUID] {
        let named = Set(ids)
        return ids.filter { store.session(withID: $0)?.parentID.map(named.contains) != true }
    }

    func createPageCompanion(_ target: String?, window: String?, options: ControlSessionOverlayOpenOptions) async -> ControlResponse {
        if case .success(let (store, id)) = resolver.resolveSessionTarget(target, window: window),
           store.session(withID: id)?.remoteHost != nil {
            // the page would load the origin's loopback here, where nothing answers for it
            if case .url(let url) = options.page, HtmlSource.isLoopback(url.absoluteString) {
                return ControlResponse(ok: false, error: "a loopback page cannot be a companion of a remote session")
            }
            if options.persistent, let failure = HtmlOverlayRegistry.shared.persistentStoreFailure() {
                return ControlResponse(ok: false, error: "session.companion.page: \(failure)")
            }
            return await createRemoteCompanion(.page(options), of: id, in: store, select: options.follow)
        }
        return resolver.resolveSession(target, window: window) { store, id in
            guard let page = options.page else { return ControlResponse(ok: false, error: "a page companion needs --html or --url") }
            if options.persistent, let failure = HtmlOverlayRegistry.shared.persistentStoreFailure() {
                return ControlResponse(ok: false, error: "session.companion.page: \(failure)")
            }
            let overlay = HtmlOverlay(source: page, navigation: options.navigation, javascript: options.javascript,
                                      chromeless: options.chromeless, persistent: options.persistent, browse: options.browse)
            switch store.addPageCompanion(to: id, overlay: overlay, select: options.follow,
                                          backgroundColor: options.backgroundColor) {
            case .failure(.remoteParent):
                return ControlResponse(ok: false, error: "companions of a remote session are not supported yet")
            case .failure:
                return ControlResponse(ok: false, error: "could not create page companion")
            case .success(let companion):
                if options.persistent {
                    _ = HtmlOverlayRegistry.shared.page(for: overlay, store: store, backgroundColor: options.backgroundColor)
                }
                return ControlResponse(ok: true, result: ControlResult(id: companion.id.uuidString, pageID: overlay.id.uuidString,
                                                                       parent: companion.parentID?.uuidString))
            }
        }
    }

    func duplicateAsCompanion(_ target: String?, window: String?, select: Bool) async -> ControlResponse {
        let (store, id): (AppStore, UUID)
        switch resolver.resolveSessionTarget(target, window: window) {
        case .failure(let response): return response
        case .success(let resolved): (store, id) = resolved
        }
        if store.session(withID: id)?.remoteHost != nil {
            return await createRemoteCompanion(.duplicate, of: id, in: store, select: select)
        }
        switch duplicateCompanion(of: id, in: store, select: select) {
        case .failure(let failure): return ControlResponse(ok: false, error: failure.message)
        case .success(let copy):
            if select, store === library.activeStore { actions.focusActiveSession() }
            return ControlResponse(ok: true, result: ControlResult(id: copy.id.uuidString, parent: copy.parentID?.uuidString))
        }
    }

    /// duplicateCompanion plans every pane of the source before creating anything, so one refused pane
    /// leaves the tree as it was.
    func duplicateCompanion(of id: UUID, in store: AppStore, select: Bool) -> Result<Session, CompanionDuplicateFailure> {
        guard let source = store.session(withID: id) else { return .failure(.init(message: "no such session")) }
        guard source.remoteHost == nil else { return .failure(.init(message: "companions of a remote session are not supported yet")) }
        guard source.content == .terminal else { return .failure(.init(message: "a page companion has no terminal to duplicate")) }
        // a visible program over the panes is what the user sees running; copying the covered shell instead is wrong
        guard !source.programOverlayVisible else {
            return .failure(.init(message: "a program overlay covers the session; nothing was created"))
        }
        let leaders = zmxClient?.sessionLeaderPIDs()
        if zmxClient != nil { zmxForegroundResolver?.acceptLeaderSnapshot(leaders) }
        let shell = ProcessInfo.processInfo.environment["SHELL"].map(CommandRestore.basename)
        func plan(_ surface: TerminalSurface?, pane: CommandContext.Pane) -> Result<DuplicateReplay.Plan, CompanionDuplicateFailure> {
            if source.paneOverlay(pane == .left ? .left : .right).map({ $0.html == nil && !$0.hidden }) == true {
                return .failure(.init(message: "\(pane.rawValue) pane is covered by a program overlay; nothing was created"))
            }
            guard let view = surface as? GhosttySurfaceView, view.isRealized else {
                return .failure(.init(message: "\(pane.rawValue) pane is not realized; nothing was created"))
            }
            let observation = ForegroundProcess.replayObservation(
                for: view, shellBasename: shell, zmxResolver: zmxForegroundResolver,
                leader: view.zmxSessionName.flatMap { leaders?[$0] })
            return DuplicateReplay.resolve(observation, pane: pane.rawValue, fallbackDirectory: source.cwd(for: pane),
                                           shell: shell, denylist: GhosttyApp.shared.restoreDenylist).mapError { CompanionDuplicateFailure(message: $0.message) }
        }
        let left: DuplicateReplay.Plan
        switch plan(source.surface, pane: .left) {
        case .failure(let message): return .failure(message)
        case .success(let value): left = value
        }
        var right: DuplicateReplay.Plan?
        if source.hasSplit {
            switch plan(source.splitSurface, pane: .right) {
            case .failure(let message): return .failure(message)
            case .success(let value): right = value
            }
        }
        return store.duplicateAsCompanion(of: id, left: left, right: right, axis: source.splitAxis,
                                          ratio: source.splitRatio, select: select)
            .mapError { _ in CompanionDuplicateFailure(message: "could not create companion") }
    }

    /// The ids a close of `ids` removes, each root followed by its companions; computed before the close
    /// because the companions are gone after it.
    func closingGroup(_ ids: [UUID], in store: AppStore) -> [UUID] {
        closeRoots(ids, in: store).flatMap { [$0] + store.companions(of: $0).map(\.id) }
    }

    func setSessionExpansion(_ target: String?, window: String?, expanded: Bool) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            guard actions.setSessionExpanded(id, expanded: expanded, in: store) else {
                return ControlResponse(ok: false, error: "session has no companions")
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }
}
