import Foundation

extension WindowLibrary {
    /// Which window a claim came from. Grouped so the walk's helpers take one origin rather than three
    /// loose fields that are always passed together.
    private struct ClaimOrigin {
        let id: UUID
        /// Nil for an unindexed window: names live only in `windows.json`, which by definition lacks it.
        let name: String?
        let state: ZmxOwnerWindowState
    }

    /// Every pane expecting a zmx daemon, read WITHOUT writing anything.
    ///
    /// Deliberately its own walk rather than `PaneIdentityInventory.upgrade`, which mints missing
    /// identities and whose every caller saves the result: a read command must not rewrite window files.
    /// A missing identity therefore makes the walk incomplete instead of being repaired.
    ///
    /// Enumerates `windows/*.json` and compares it against the index rather than trusting the index alone.
    /// `bootstrap()` only scans the directory when `loadIndex()` returns nil, so a valid-but-stale
    /// `windows.json` leaves a surviving window file unread — and its panes would then read as orphans.
    public func paneClaims() -> ZmxClaimWalk {
        var claims: [ZmxPaneClaim] = []
        var complete = true
        var indexed: Set<UUID> = []

        for window in windows {
            indexed.insert(window.id)
            if window.isRemote { continue } // its panes are daemons on its server
            let origin = ClaimOrigin(id: window.id, name: window.name,
                                     state: stores[window.id] != nil ? .open : .closed)
            let walk = stores[window.id].map { liveClaims($0, origin: origin) } ?? persistedClaims(origin: origin)
            claims.append(contentsOf: walk.claims)
            complete = complete && walk.complete
        }

        // an unenumerable directory hides unindexed panes entirely, so the silence must not read as "none"
        guard let strays = strayWindowFileIDs(indexed: indexed) else {
            log("zmx claim walk could not enumerate \(windowsDirectory.path)")
            return ZmxClaimWalk(claims: claims, complete: false)
        }
        for id in strays {
            let walk = persistedClaims(origin: ClaimOrigin(id: id, name: nil, state: .unindexed))
            claims.append(contentsOf: walk.claims)
            complete = complete && walk.complete
        }

        return ZmxClaimWalk(claims: claims, complete: complete)
    }

    /// A closed window's session label, mirroring `Session.displayName` from what the snapshot holds: no
    /// OSC title is persisted, so it falls straight from the custom name to the cwd's last component.
    private static func persistedName(_ session: SessionSnapshot) -> String {
        if let trimmed = session.customName?.trimmedOrNil { return trimmed }
        return session.cwd.isEmpty ? "~" : (session.cwd as NSString).lastPathComponent
    }

    /// One session's place in the tree, so a claim is built from a site plus a pane rather than from
    /// seven loose fields threaded through every call.
    private struct ClaimSite {
        let origin: ClaimOrigin
        let workspaceID: UUID
        let workspaceName: String
        let sessionID: UUID
        let sessionName: String?
        /// True for a soft-closed session waiting out its grace: hidden from the tree, daemon still owned.
        var pendingClose = false

        func claim(_ pane: ZmxPaneRole, identity: UUID) -> ZmxPaneClaim {
            ZmxPaneClaim(paneIdentity: identity, pane: pane, pendingClose: pendingClose, windowID: origin.id,
                         windowName: origin.name, windowState: origin.state, workspaceID: workspaceID,
                         workspaceName: workspaceName, sessionID: sessionID, sessionName: sessionName)
        }
    }

    private func liveClaims(_ store: AppStore, origin: ClaimOrigin) -> ZmxClaimWalk {
        var pairs: [(site: ClaimSite, session: Session)] = []
        for workspace in store.workspaces {
            for session in workspace.sessions {
                pairs.append((ClaimSite(origin: origin, workspaceID: workspace.id,
                                        workspaceName: workspace.name, sessionID: session.id,
                                        sessionName: session.displayName), session))
            }
        }
        // a soft close removes the session from `workspaces` for the grace window while its surfaces, and
        // so its daemons, stay alive; omitting these would report a claimed pane as an orphan
        for member in store.pendingCloseMembers() {
            pairs.append((ClaimSite(origin: origin, workspaceID: member.workspaceID,
                                    workspaceName: member.workspaceName, sessionID: member.session.id,
                                    sessionName: member.session.displayName, pendingClose: true),
                          member.session))
        }

        var claims: [ZmxPaneClaim] = []
        var complete = true
        for (site, session) in pairs {
            // through the ownership projection, so this stays one predicate: an empty list is a session
            // whose daemons are not ours to claim, and inventing rows for it would name daemons that do
            // not exist here
            let owned = session.locallyManagedPaneIdentities
            guard !owned.isEmpty else { continue }
            claims.append(site.claim(.left, identity: session.paneIdentity))
            if session.hasSplit {
                if let split = session.splitPaneIdentity { claims.append(site.claim(.right, identity: split)) } else { complete = false }
            }
            if let scratch = session.localScratchIdentity { claims.append(site.claim(.scratch, identity: scratch)) }
        }
        return ZmxClaimWalk(claims: claims, complete: complete)
    }

    private func persistedClaims(origin: ClaimOrigin) -> ZmxClaimWalk {
        guard let snapshot = try? persistenceStore(for: origin.id).loadChecked() else {
            log("zmx claim walk could not read window \(origin.id)")
            return ZmxClaimWalk(claims: [], complete: false)
        }
        var claims: [ZmxPaneClaim] = []
        var complete = true
        for workspace in snapshot.workspaces {
            // a page owns no daemon to claim
            for session in workspace.sessions where session.page == nil {
                let site = ClaimSite(origin: origin, workspaceID: workspace.id, workspaceName: workspace.name,
                                     sessionID: session.id, sessionName: Self.persistedName(session))
                // each pane is judged on its own: a session missing its primary identity can still own a
                // perfectly good split, and dropping that would leave its daemon reading as an orphan
                if let identity = session.paneIdentity {
                    claims.append(site.claim(.left, identity: identity))
                } else {
                    complete = false
                }
                if (session.hasSplit ?? false) || (session.isSplit ?? false) {
                    if let split = session.splitPaneIdentity { claims.append(site.claim(.right, identity: split)) } else { complete = false }
                }
                if let scratch = session.scratchPaneIdentity { claims.append(site.claim(.scratch, identity: scratch)) }
            }
        }
        return ZmxClaimWalk(claims: claims, complete: complete)
    }

    /// Window files on disk that the index does not list. A stale index short-circuits recovery, so these
    /// are real panes whose daemons would otherwise read as unclaimed. Nil when the directory itself could
    /// not be read, which is not the same answer as "no stray files"; Linux lists a non-directory as empty.
    func strayWindowFileIDs(indexed: Set<UUID>) -> [UUID]? {
        guard (try? windowsDirectory.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
              let contents = try? FileManager.default.contentsOfDirectory(at: windowsDirectory,
                                                                          includingPropertiesForKeys: nil) else {
            return nil
        }
        return contents
            .filter { $0.pathExtension == "json" }
            .compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) }
            .filter { !indexed.contains($0) }
            .sorted { $0.uuidString < $1.uuidString }
    }
}
