import agtermCore
import AppKit

/// App side of explicit zmx leadership: a pane's zmx client reports its role, a pane that does not lead
/// is covered, and taking the lead is always a FRESH attach into a new surface. The covered surface drew
/// output laid out for another grid, so repairing it in place would need a resize and a replay ordered
/// against libghostty's own queued resize; a new surface starts from the daemon's snapshot instead.
/// `.claude/rules/control-api.md` owns the contract.
@MainActor
enum PaneLead {
    /// Replaces a pane's surface with a fresh attach. Installed once by the app, which owns the factories.
    static var reattach: ((_ old: GhosttySurfaceView, _ claim: Bool) -> Void)?
    /// Tells the pane's store that read-back changed.
    static var roleChanged: ((_ view: GhosttySurfaceView) -> Void)?

    /// The key that took a pane over, swallowed until it is released so neither its repeats nor its
    /// release reach the program through the new surface.
    private static var takeoverKeyCode: UInt16?

    /// A role report parsed off the title callback. One from a surface this pane already replaced
    /// carries that attachment's token and the book drops it.
    static func report(_ notice: ZmxLeadNotice, from view: GhosttySurfaceView) {
        guard !view.isDestroyed, let pane = UUID(uuidString: view.paneToken),
              let role = ZmxLeadBook.shared.apply(notice, pane: pane) else { return }
        roleChanged?(view)
        // without the claim, so this attach leads only if nobody claimed the session in the meantime
        if role == .unowned { reattach?(view, false) }
    }

    /// True when `event` belongs to a takeover and must not reach the terminal.
    static func consumes(_ event: NSEvent, in view: GhosttySurfaceView) -> Bool {
        // the takeover key's release can land on the destroyed old view, or on nothing while the new one
        // mounts, and never reach this. A fresh press of the same key proves it was released.
        if event.type == .keyDown, !event.isARepeat, event.keyCode == takeoverKeyCode { takeoverKeyCode = nil }
        if event.type == .keyUp, event.keyCode == takeoverKeyCode {
            takeoverKeyCode = nil
            return true
        }
        if event.type == .keyDown, event.isARepeat, event.keyCode == takeoverKeyCode { return true }
        guard view.leadCovered else { return false }
        // a modifier alone is not the press the cover asks for, and app shortcuts stay the app's
        guard event.type == .keyDown, !event.modifierFlags.contains(.command) else { return true }
        // already on its way: the fresh surface is covered too until its first report
        guard !ZmxLeadBook.shared.reattaching(pane: UUID(uuidString: view.paneToken)) else { return true }
        takeoverKeyCode = event.keyCode
        reattach?(view, true)
        return true
    }
}

/// What a fresh attach of an existing pane spawns with. It attaches and never creates: the trailing
/// `/bin/sh -c` runs only when the daemon is gone, and fails, so a vanished session ends the pane
/// instead of handing back a new shell under the old identity.
struct PaneReattach {
    let command: String
    let wait: Bool
    let environment: [String: String]
    let workingDirectory: String

    @MainActor
    static func launch(replacing old: GhosttySurfaceView, session: Session, identity: UUID,
                       lead: ZmxLeadAttachment) -> PaneReattach? {
        if old.backedByZmx {
            guard let zmx = ZmxLaunch.configuration(paneIdentity: identity, pane: old.isSplitPane ? "split" : "primary",
                                                    environment: old.env, lead: lead) else { return nil }
            let gone = "printf '%s\\n' 'agterm: session is gone'; exit 1"
            return PaneReattach(command: CommandRestore.shellQuotedLine(zmx.attachArguments + ["/bin/sh", "-c", gone]),
                                wait: false, environment: zmx.environment, workingDirectory: old.workingDirectory)
        }
        guard let binding = session.remotePresentation?.binding, let origin = binding.origin,
              let daemon = binding.daemon(forLocalPane: identity),
              let command = try? RemoteSession.attachPaneCommand(
                  host: origin.host, endpoint: origin.endpoint, daemon: daemon, session: origin.sessionName,
                  pane: old.isSplitPane ? .right : .left, lead: lead)
        else { return nil }
        return PaneReattach(command: command, wait: true, environment: old.env, workingDirectory: old.workingDirectory)
    }
}

extension GhosttySurfaceView {
    /// Whether this pane's terminal must not be seen or typed into: it follows another client's grid, or
    /// it is a fresh attach that has not reported yet.
    var leadCovered: Bool { ZmxLeadBook.shared.covered(pane: UUID(uuidString: paneToken)) }
}
