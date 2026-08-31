import Foundation

extension AppStore {
    /// Preserves the pre-zmx initializer symbol for source and incremental-build compatibility.
    public convenience init(workspaces: [Workspace] = [], selectedSessionID: UUID? = nil,
                            persistence: PersistenceStore = PersistenceStore(),
                            recentClosedStore: RecentClosedStore? = nil,
                            recentClosedDidChange: (() -> Void)? = nil,
                            controlEventSink: ((ControlEventDraft) -> Void)? = nil) {
        self.init(workspaces: workspaces, selectedSessionID: selectedSessionID, persistence: persistence,
                  recentClosedStore: recentClosedStore, recentClosedDidChange: recentClosedDidChange,
                  controlEventSink: controlEventSink, paneFinalizer: nil)
    }
}
