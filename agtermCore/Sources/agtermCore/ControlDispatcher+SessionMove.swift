import Foundation

extension ControlDispatcher {
    /// The `session.move` form parser: exactly one placement intent out of a destination window, an
    /// anchor, a reorder direction, or a workspace. Extracted from the command switch, which the four
    /// mutually exclusive forms would otherwise dominate.
    func dispatchSessionMove(_ request: ControlRequest) -> ControlResponse {
        let args = request.args
        if args?.after != nil, args?.before != nil {
            return ControlResponse(ok: false, error: "use either --after or --before, not both")
        }
        // Cross-window mode: the destination is another store, where neither a reorder direction nor an
        // anchor's index means anything. A workspace parameter DOES, naming one inside that window.
        if let toWindow = args?.toWindow {
            if args?.to != nil {
                return ControlResponse(ok: false, error: "session.move takes --to-window or --to, not both")
            }
            if args?.after != nil || args?.before != nil {
                return ControlResponse(ok: false,
                                       error: "session.move takes --to-window or --after/--before, not both")
            }
            let move = ControlSessionMove.window(window: toWindow, workspace: args?.workspace)
            let select = args?.select ?? false
            if let targets = args?.targets {
                return dispatchSessionMove(targets: targets, window: args?.window, move: move, select: select)
            }
            return actions.moveSession(request.target, window: args?.window, move: move, select: select)
        }
        // Placement mode: the anchor sid self-identifies the destination workspace, so it's
        // mutually exclusive with --to and with a workspace parameter.
        if let anchor = args?.after ?? args?.before {
            if args?.to != nil {
                return ControlResponse(ok: false, error: "session.move takes --after/--before or --to, not both")
            }
            if args?.workspace != nil {
                return ControlResponse(ok: false, error: "session.move takes --after/--before or a workspace, not both")
            }
            let move = ControlSessionMove.place(anchor: anchor, after: args?.after != nil)
            if let targets = args?.targets {
                return dispatchSessionMove(targets: targets, window: args?.window, move: move, select: false)
            }
            return actions.moveSession(request.target, window: args?.window, move: move, select: false)
        }
        if args?.to != nil && args?.workspace != nil {
            return ControlResponse(ok: false, error: "session.move takes either --to or a workspace, not both")
        }
        if let to = args?.to {
            guard let direction = ReorderDirection(rawValue: to) else {
                return ControlResponse(ok: false, error: "session.move --to must be up|down|top|bottom")
            }
            if args?.targets != nil {
                return ControlResponse(ok: false, error: "session.move --target can be repeated only with a workspace or --after/--before")
            }
            return actions.moveSession(request.target, window: args?.window, move: .reorder(direction),
                                       select: false)
        }
        guard let workspace = args?.workspace else {
            return ControlResponse(ok: false, error: "session.move requires --to or a workspace")
        }
        let move = ControlSessionMove.workspace(workspace)
        if let targets = args?.targets {
            return dispatchSessionMove(targets: targets, window: args?.window, move: move, select: false)
        }
        return actions.moveSession(request.target, window: args?.window, move: move, select: false)
    }

    private func dispatchSessionMove(targets: [String], window: String?, move: ControlSessionMove,
                                     select: Bool) -> ControlResponse {
        guard let first = targets.first else {
            return ControlResponse(ok: false, error: "session.move requires at least one --target")
        }
        if targets.count == 1 {
            return actions.moveSession(first, window: window, move: move, select: select)
        }
        return actions.moveSessions(targets, window: window, move: move, select: select)
    }
}
