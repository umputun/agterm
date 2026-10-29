import agtermCore
import Foundation

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

    func createCompanion(_ target: String?, options: CompanionOptions, window: String?) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            switch store.addCompanion(to: id, options: options) {
            case .failure(.remoteParent):
                return ControlResponse(ok: false, error: "companions of a remote session are not supported yet")
            case .failure(.noSuchSession), .failure(.pageNotOpened):
                return ControlResponse(ok: false, error: "could not create companion")
            case .success(let companion):
                if options.select, store === library.activeStore { actions.focusActiveSession() }
                return ControlResponse(ok: true, result: ControlResult(id: companion.id.uuidString,
                                                                       parent: companion.parentID?.uuidString))
            }
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

    func createPageCompanion(_ target: String?, window: String?, options: ControlSessionOverlayOpenOptions) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
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
