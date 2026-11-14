import Foundation
import agtermCore

/// `session.info` on agterm-server: the line is the session's own, published to presenters by the store, and the
/// server owns its expiry so a host agent's read and a Mac that connects later both see it gone.
extension ServerActions {
    public func setSessionInfo(_ target: String?, window: String?, info: SessionInfo?) -> ControlResponse {
        withSession(target, window: window) { session in
            store.setInfo(info, forSession: session.id)
            if let info { armInfoAutoHide(session, seconds: info.hideAfter) }
            return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
        }
    }

    /// armInfoAutoHide replaces `session`'s expiry, re-armed on every set so a caller refreshing its line keeps it;
    /// zero seconds only cancels. The revision makes a superseded timer inert.
    func armInfoAutoHide(_ session: Session, seconds requested: Double) {
        let id = session.id
        let revision = (infoAutoHide[id]?.revision ?? 0) + 1
        infoAutoHide[id]?.task.cancel()
        infoAutoHide[id] = nil
        session.onInfoDiscarded = nil
        // clamped as well as validated: the conversion below traps on a large enough Double
        let seconds = min(requested, HudSpec.maxHideAfter)
        guard seconds > 0 else { return }
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.infoAutoHide[id]?.revision == revision else { return }
            self.infoAutoHide[id] = nil
            self.store.setInfo(nil, forSession: id)
        }
        infoAutoHide[id] = InfoTimer(revision: revision, task: task)
        session.onInfoDiscarded = { [weak self] in
            MainActor.assumeIsolated {
                self?.infoAutoHide[id]?.task.cancel()
                self?.infoAutoHide[id] = nil
            }
        }
    }
}

struct InfoTimer {
    let revision: Int
    let task: Task<Void, Never>
}
