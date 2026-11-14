import agtermCore

/// ServerCommandPolicy is what agterm-server accepts: a command not in `served` is refused before dispatch,
/// with the physical-window reason where one applies. Default-deny, so a command added to the protocol later
/// reaches the server's store only once someone serves it on purpose.
public enum ServerCommandPolicy {
    static let served: Set<Command> = [
        .tree, .version, .windowList,
        .sessionNew, .sessionRename, .sessionClose, .sessionMove, .sessionSplit, .sessionSplitClose, .sessionSwap,
        .sessionCompanionNew, .sessionPage, .sessionCompanionPage, .sessionCompanionPageAttach, .sessionText, .sessionType,
        .sessionScratch,
        .workspaceNew, .workspaceRename, .workspaceDelete, .workspaceMove,
        .pickOpen, .pickResult, .pickCancel, .askOpen, .askResult, .askCancel,
        .zmxTree, .zmxPresent, .catalogSubscribe, .catalogOp, .sessionOverlayJobRun, .sessionOverlayPageServe,
        .sessionStatus, .sessionContext, .notify, .sessionHudOpen, .sessionHudUpdate, .sessionHudClose,
        .sessionOverlayOpen, .sessionOverlayClose, .sessionOverlayResize, .sessionOverlayResult,
        .sessionOverlayReload, .sessionOverlayNavigate, .sessionOverlaySubmit,
        .sessionOverlayHide, .sessionOverlayShow, .sessionOverlayToggle,
        .sessionOverlayFollow, .sessionOverlaySearch, .sessionOverlayWrap, .sessionOverlayChanges, .sessionOverlayFiles,
        .msgSend, .msgRead, .msgAck,
    ]

    /// refusal is the error for a command the server does not serve, nil for one it does.
    public static func refusal(_ command: Command) -> String? {
        guard !served.contains(command) else { return nil }
        return HeadlessCommandPolicy.physicalWindowRefusal(command) ?? "\(command.rawValue) is not available on agterm-server"
    }
}
