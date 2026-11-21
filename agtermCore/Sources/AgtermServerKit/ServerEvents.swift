import Foundation
import agtermCore

/// ServerEvents is the server's event history for `events.read`: the store's events stamped with the catalog's
/// one window, and bursts of `tree.changed` folded into one, as a Mac window folds them.
@MainActor
final class ServerEvents {
    let ring: ControlEventRing
    private let window: String
    private let treeDebouncer = Debouncer()

    init(window: UUID, ring: ControlEventRing = ControlEventRing()) {
        self.window = window.uuidString
        self.ring = ring
    }

    /// receive is the store's event sink.
    func receive(_ draft: ControlEventDraft) {
        guard draft.kind != .treeChanged else {
            treeDebouncer.schedule(after: 0.1) { [weak self] in
                guard let self else { return }
                ring.append(ControlEventDraft(kind: .treeChanged, window: window))
            }
            return
        }
        ring.append(ControlEventDraft(kind: draft.kind, window: window, workspace: draft.workspace,
                                      session: draft.session, payload: draft.payload))
    }

    /// flushTree appends a pending `tree.changed` now.
    func flushTree() {
        treeDebouncer.flush()
    }
}
