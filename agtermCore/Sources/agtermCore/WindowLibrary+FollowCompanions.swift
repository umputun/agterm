import Foundation

// MARK: - Handled origin companions across every local copy

extension WindowLibrary {
    /// markOriginCompanionsHandled records origin companions `ids` of origin session `parent` on `host`'s zmx at
    /// `endpoint` as handled on every copy here that can show it again: open rows, rows an undoable close holds, and
    /// rows saved in closed windows. Each copy keeps its own baseline; only these handled ids are shared.
    public func markOriginCompanionsHandled(_ ids: [String], parent: String, host: String, endpoint: ControlZmxEndpoint) {
        let parent = Self.originID(parent)
        let shows = { (rowHost: String?, session: String, rowEndpoint: ControlZmxEndpoint?) in
            rowHost == host && rowEndpoint == endpoint && Self.originID(session) == parent
        }
        for store in openIDs().compactMap({ stores[$0] }) {
            let rows = store.workspaces.flatMap(\.sessions) + store.pendingCloseMembers().map(\.session)
            for row in rows {
                guard let binding = row.remotePresentation?.binding, shows(row.remoteHost, binding.remoteSessionID, binding.origin?.endpoint)
                else { continue }
                store.markFollowed(ids, forSession: row.id)
            }
        }
        let marks = ids.map(Self.originID)
        // a closed window's rows exist only in its saved snapshot, which its store reads again when it opens
        for info in windows where stores[info.id] == nil && info.source == nil {
            let persistence = persistenceStore(for: info.id)
            guard var snapshot = try? persistence.loadChecked() else { continue }
            var changed = false
            for workspace in snapshot.workspaces.indices {
                for index in (snapshot.workspaces[workspace].attached ?? []).indices {
                    guard var row = snapshot.workspaces[workspace].attached?[index],
                          shows(row.origin.host, row.origin.sessionID, row.origin.endpoint) else { continue }
                    let followed = Set(row.followedCompanions ?? [])
                    guard !followed.isSuperset(of: marks) else { continue }
                    row.followedCompanions = followed.union(marks).sorted()
                    snapshot.workspaces[workspace].attached?[index] = row
                    changed = true
                }
            }
            guard changed else { continue }
            do {
                try persistence.save(snapshot)
            } catch {
                log("could not record handled companions in closed window \(info.id): \(error)")
            }
        }
    }
}
