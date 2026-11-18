import Foundation

// MARK: - Companion membership for attached viewers

extension AppStore {
    /// presentationCompanions is `session`'s companion membership as its viewers follow it, nil for a row this store
    /// shows from another host, whose companions are that host's to hand out.
    func presentationCompanions(of session: Session) -> PresentationCompanions? {
        guard session.remoteHost == nil else { return nil }
        return PresentationCompanions(members: companions(of: session.id).filter { $0.remoteHost == nil }.map {
            PresentationCompanions.Member(id: $0.id, kind: $0.content == .page ? .page : .terminal)
        })
    }

    /// scheduleCompanionsFlush publishes the membership of every followed session one main-queue turn after a tree
    /// change, once per burst, so a soft close, an undo or a regroup is read only once it has completed.
    func scheduleCompanionsFlush() {
        guard presentationHub != nil, !companionsFlushDue else { return }
        companionsFlushDue = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.companionsFlushDue = false
                self.flushCompanions()
            }
        }
    }

    private func flushCompanions() {
        guard let hub = presentationHub else { return }
        for id in hub.subscribedSessions {
            guard let session = session(withID: id), let companions = presentationCompanions(of: session) else { continue }
            hub.publishCompanions(companions, session: id)
        }
    }
}
