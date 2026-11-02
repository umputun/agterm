import Foundation
import agtermCore

/// InfoAutoHide is a session's live info-line expiry and the revision that armed it, so a superseded callback
/// does nothing.
struct InfoAutoHide {
    let revision: Int
    let task: Task<Void, Never>
}

// app-side host for `session.info`: validation and parsing stay in `ControlDispatcher+SessionMetadata`, this layer
// resolves the session, stores the line and owns its expiry timer.
extension ControlServer {
    func setSessionInfo(_ target: String?, window: String?, info: SessionInfo?) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            guard let session = store.session(withID: id) else {
                return ControlResponse(ok: false, error: "no such session: \(target ?? "active")")
            }
            store.setInfo(info, forSession: id)
            // armed on every successful set, an identical one included, so a caller refreshing its line keeps it alive
            if let info { armInfoAutoHide(session, seconds: info.hideAfter) }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// armInfoAutoHide arms the local info line's expiry for `session`, replacing whatever was armed, and registers the
    /// cancellation `Session.discardInfo` fires. Zero seconds only cancels.
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
            self.library.store(forSession: id)?.setInfo(nil, forSession: id)
        }
        infoAutoHide[id] = InfoAutoHide(revision: revision, task: task)
        session.onInfoDiscarded = { [weak self] in
            MainActor.assumeIsolated {
                self?.infoAutoHide[id]?.task.cancel()
                self?.infoAutoHide[id] = nil
            }
        }
    }
}
