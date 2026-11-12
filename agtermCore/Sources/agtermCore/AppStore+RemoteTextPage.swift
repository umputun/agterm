import Foundation

/// RemoteTextOutcome is how a text page action addressed to a slot ended on the origin.
public enum RemoteTextOutcome: Equatable, Sendable {
    /// local: the slot holds no page the presenting Mac runs text actions on, so the local path answers, its
    /// refusals included.
    case local
    /// answered: the presenter's result, whose state this store already applied.
    case answered(PresentationPageResult)
    case failed(String)
}

/// TextPageAction is one control action on a text page. It travels to the presenting Mac as a page command and runs
/// there as the local command does.
public enum TextPageAction: Equatable, Sendable {
    case follow(ControlToggleMode)
    case wrap(ControlToggleMode)
    case search(TextSearchRequest)
    case changes(forward: Bool)

    /// init reads the action a page command carries; nil for one that is not a whole text action.
    public init?(_ command: PresentationPageCommand) {
        switch (command.action, command.toggle, command.query, command.step) {
        case (.follow, let mode?, nil, nil): self = .follow(mode)
        case (.wrap, let mode?, nil, nil): self = .wrap(mode)
        case (.search, nil, let query?, nil): self = .search(.query(query))
        case (.search, nil, nil, .next?): self = .search(.next)
        case (.search, nil, nil, .prev?): self = .search(.previous)
        case (.search, nil, nil, .close?): self = .search(.close)
        case (.changes, nil, nil, .next?): self = .changes(forward: true)
        case (.changes, nil, nil, .prev?): self = .changes(forward: false)
        default: return nil
        }
    }

    /// command is the page command carrying this action; a query is cut to `TextSearch.maxQuery`, which keeps the frame
    /// inside its cap.
    func command(page: String, seq: Int) -> PresentationPageCommand {
        switch self {
        case .follow(let mode): PresentationPageCommand(page: page, seq: seq, action: .follow, toggle: mode)
        case .wrap(let mode): PresentationPageCommand(page: page, seq: seq, action: .wrap, toggle: mode)
        case .search(.query(let query)):
            PresentationPageCommand(page: page, seq: seq, action: .search, query: String(query.prefix(TextSearch.maxQuery)))
        case .search(.next): PresentationPageCommand(page: page, seq: seq, action: .search, step: .next)
        case .search(.previous): PresentationPageCommand(page: page, seq: seq, action: .search, step: .prev)
        case .search(.close): PresentationPageCommand(page: page, seq: seq, action: .search, step: .close)
        case .changes(let forward): PresentationPageCommand(page: page, seq: seq, action: .changes, step: forward ? .next : .prev)
        }
    }
}

/// RemoteTextWait names one text page action waiting for its result: the page and the sequence number it was sent
/// under.
struct RemoteTextWait: Hashable {
    let job: String
    let seq: Int
}

// MARK: - Text page actions on a page the presenting Mac shows, on the origin

extension AppStore {
    /// remoteTextAction runs `action` on the page the presenting Mac shows in `pane`'s slot and waits for its result,
    /// at most `remoteTextDeadline`. A presenter that does not list `page.text` is never sent one: it cannot decode
    /// the action and would end the whole presentation.
    public func remoteTextAction(_ sessionID: UUID, pane: OverlayPane?, _ action: TextPageAction) async -> RemoteTextOutcome {
        guard let session = session(withID: sessionID), let slot = session.remoteOverlays.slot(pane), slot.page != nil,
              let hub = presentationHub, hub.presenterSupports(PresentationHub.pageTextKind, session: sessionID)
        else { return .local }
        guard hub.presenterGeneration(session: sessionID) == slot.owner else { return .failed(OverlayResultError.viewerGone) }
        var seq = 0
        session.remoteOverlays.updatePage(slot.job) { seq = $0.nextSeq() }
        let wait = RemoteTextWait(job: slot.job, seq: seq)
        let command = action.command(page: slot.job, seq: seq)
        let deadline = remoteTextDeadline
        return await withCheckedContinuation { continuation in
            // registered before the send, which can drop a stalled presenter and end the page synchronously
            remoteTextWaits[wait] = continuation
            guard hub.sendToPresenter(.pageCommand(command), session: sessionID) else {
                return settleRemoteText(wait, .failed(OverlayResultError.viewerGone))
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: deadline)
                self?.settleRemoteText(wait, .failed(OverlayResultError.presenterSilent))
            }
        }
    }

    /// receiveRemoteTextResult applies the state a result carries, then answers the action waiting for it. A result
    /// from a presenter that no longer holds the page is dropped.
    func receiveRemoteTextResult(_ result: PresentationPageResult, in session: Session) {
        guard let slot = session.remoteOverlays.slot(job: result.page),
              slot.owner == presentationHub?.presenterGeneration(session: session.id) else { return }
        var changed = false
        if let state = result.state { session.remoteOverlays.updatePage(result.page) { changed = $0.apply(state) } }
        if changed { scheduleTreeChanged() }
        settleRemoteText(RemoteTextWait(job: result.page, seq: result.seq), .answered(result))
    }

    /// settleRemoteTextWaits answers every action still waiting on page `job`, which ended or was taken back.
    func settleRemoteTextWaits(job: String) {
        for wait in remoteTextWaits.keys where wait.job == job { settleRemoteText(wait, .failed(OverlayResultError.viewerGone)) }
    }

    private func settleRemoteText(_ wait: RemoteTextWait, _ outcome: RemoteTextOutcome) {
        remoteTextWaits.removeValue(forKey: wait)?.resume(returning: outcome)
    }
}
