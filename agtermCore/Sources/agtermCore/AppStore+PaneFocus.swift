import Foundation
import Observation

// MARK: - pane.focused

extension AppStore {
    /// The stable identity of the pane each session has selected. Keyed on identity, not the left/right
    /// role, so a swap, which exchanges both identities and toggles `splitFocused`, reads as no change.
    func selectedPaneIdentities() -> [UUID: UUID] {
        var identities: [UUID: UUID] = [:]
        for session in workspaces.flatMap(\.sessions) {
            let right = session.focusedPane == .right
            identities[session.id] = right ? session.splitPaneIdentity ?? session.paneIdentity : session.paneIdentity
        }
        return identities
    }

    /// Starts reporting settled split-pane selection changes as `pane.focused`; a store with no event sink
    /// has nobody to tell.
    func observePaneFocus() {
        guard controlEventSink != nil else { return }
        paneFocusBaseline = selectedPaneIdentities()
        trackPaneFocus()
    }

    /// Re-registers on every change and re-arms the debounce, so the check runs once the selection has been
    /// quiet for 100 ms. A shown split's deck re-render moves first responder to the primary and the focus
    /// retry moves it back on a later main-queue turn (`AppActions+Focus`), and that round trip must not
    /// read as two selections.
    private func trackPaneFocus() {
        withObservationTracking {
            _ = selectedPaneIdentities()
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.paneFocusDebouncer.schedule(after: 0.1) { [weak self] in self?.emitPaneFocusChanges() }
                    self.trackPaneFocus()
                }
            }
        }
    }

    /// Emits one `pane.focused` per session whose selected pane identity moved since the last check. A
    /// session new to this store (created, moved in) or gone from it only updates the baseline.
    func emitPaneFocusChanges() {
        let current = selectedPaneIdentities()
        defer { paneFocusBaseline = current }
        for workspace in workspaces {
            for session in workspace.sessions {
                guard let previous = paneFocusBaseline[session.id], let identity = current[session.id],
                      previous != identity else { continue }
                let pane: CommandContext.Pane = session.focusedPane == .right ? .right : .left
                let token = session.paneToken(for: pane)
                emitControlEvent(.paneFocused, workspace: workspace.id, session: session.id,
                                 payload: ControlEventPayload(name: session.displayName, pane: pane.rawValue,
                                                              paneID: token.isEmpty ? nil : token))
            }
        }
    }
}
