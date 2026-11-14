import Foundation
import agtermCore

/// `session.companion.duplicate` and `session.companion.convert` on agterm-server, the Mac's contracts over the
/// server's daemons.
extension ServerActions {
    /// duplicateAsCompanion plans every pane of the source from one fresh listing before creating anything, then
    /// starts the copy's panes with their rebound creation commands. The copy is never selected.
    public func duplicateAsCompanion(_ target: String?, window: String?, select _: Bool) async -> ControlResponse {
        withSession(target, window: window) { source in
            guard source.content == .terminal else {
                return ControlResponse(ok: false, error: "a page session has no terminal to duplicate")
            }
            guard !source.ended else { return ControlResponse(ok: false, error: "session has ended") }
            // a visible program over the panes is what the user sees running; copying the covered shell instead is wrong
            guard !source.programOverlayVisible else {
                return ControlResponse(ok: false, error: "a program overlay covers the session; nothing was created")
            }
            guard let listed = try? panes.runner.list() else {
                return ControlResponse(ok: false, error: "could not read the zmx session list")
            }
            let leaders = Dictionary(listed.compactMap { record in record.leaderPID.map { (record.name, $0) } }) { first, _ in first }
            let left: DuplicateReplay.Plan
            switch duplicatePlan(of: source, pane: .left, leaders: leaders) {
            case .failure(let refusal): return refusal.response
            case .success(let value): left = value
            }
            var right: DuplicateReplay.Plan?
            if source.hasSplit {
                switch duplicatePlan(of: source, pane: .right, leaders: leaders) {
                case .failure(let refusal): return refusal.response
                case .success(let value): right = value
                }
            }
            guard case .success(let copy) = store.duplicateAsCompanion(of: source.id, left: left, right: right, axis: source.splitAxis,
                                                                       ratio: source.splitRatio, select: false) else {
                return ControlResponse(ok: false, error: "could not create companion")
            }
            if let refusal = startCopy(copy) { return ControlResponse(ok: false, error: refusal) }
            return ControlResponse(ok: true, result: ControlResult(id: copy.id.uuidString, parent: copy.parentID?.uuidString))
        }
    }

    /// duplicatePlan is what the copy of `source`'s `pane` runs, from the process holding that pane's terminal.
    private func duplicatePlan(of source: Session, pane: CommandContext.Pane,
                               leaders: [String: Int32]) -> Result<DuplicateReplay.Plan, ActionRefusal> {
        if source.paneOverlay(pane == .left ? .left : .right).map({ $0.html == nil && !$0.hidden }) == true {
            return .refused(ControlResponse(ok: false, error: "\(pane.rawValue) pane is covered by a program overlay; nothing was created"))
        }
        let identity = pane == .left ? source.paneIdentity : source.splitPaneIdentity
        guard let identity, let leader = leaders[ZmxSupport.daemonName(for: identity)] else {
            return .refused(ControlResponse(ok: false, error: "\(pane.rawValue) pane is not running; nothing was created"))
        }
        let shell = (panes.shellPath as NSString).lastPathComponent
        return DuplicateReplay.resolve(replayObservation(leader, shell), pane: pane.rawValue, fallbackDirectory: source.cwd(for: pane),
                                       shell: shell, denylist: CommandRestore.defaultDenylist)
            .mapError { ActionRefusal(response: ControlResponse(ok: false, error: $0.message)) }
    }

    /// startCopy starts a duplicated companion's panes with the commands the store rebound to the copy's ids; a pane
    /// that cannot start closes the copy again.
    private func startCopy(_ copy: Session) -> String? {
        let workspace = store.sessionLocation(ofSession: copy.id)?.workspace
        if let refusal = panes.start(.init(identity: copy.paneIdentity, session: copy, workspace: workspace, pane: .left,
                                           program: .creation(copy.initialCommand, wait: nil), directory: copy.effectiveCwd)) {
            store.closeSession(copy.id, alreadyFinalized: copy.paneIdentity)
            return refusal
        }
        guard copy.hasSplit, let split = copy.splitPaneIdentity else { return nil }
        if let refusal = panes.start(.init(identity: split, session: copy, workspace: workspace, pane: .right,
                                           program: .creation(copy.splitInitialCommand, wait: nil),
                                           directory: copy.cwd(for: .right))) {
            store.closeSession(copy.id, alreadyFinalized: split)
            return refusal
        }
        return nil
    }

    /// convertToCompanion nests the target and its companions under a fresh session started in its slot. A fresh
    /// parent that cannot start is undone before it is closed, so the close ends none of the regrouped sessions.
    public func convertToCompanion(_ target: String?, window: String?) -> ControlResponse {
        withSession(target, window: window) { session in
            let selected = store.selectedSessionID
            switch store.convertToCompanion(session.id) {
            case .failure(let refusal):
                return ControlResponse(ok: false, error: refusal.message)
            case .success(let parent):
                let workspace = store.sessionLocation(ofSession: parent.id)?.workspace
                if let refusal = panes.start(.init(identity: parent.paneIdentity, session: parent, workspace: workspace,
                                                   pane: .left, directory: parent.effectiveCwd)) {
                    store.revertConversion(parent.id, target: session.id, selected: selected)
                    store.closeSession(parent.id, alreadyFinalized: parent.paneIdentity)
                    return ControlResponse(ok: false, error: refusal)
                }
                return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString, parent: parent.id.uuidString))
            }
        }
    }
}
