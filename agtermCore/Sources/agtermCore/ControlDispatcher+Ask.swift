import Foundation

/// ControlAskPlacement carries pane selectors for the host to resolve against the target session.
public struct ControlAskPlacement: Equatable, Sendable {
    /// pane is the parsed role used when no live paneID resolves.
    public let pane: OverlayPane?
    /// paneID is the caller's stable pane token, resolved by the host.
    public let paneID: String?

    public init(pane: OverlayPane? = nil, paneID: String? = nil) {
        self.pane = pane
        self.paneID = paneID
    }
}

extension ControlDispatcher {
    /// dispatchAskCommand validates caller input before the host resolves placement or changes modal state.
    func dispatchAskCommand(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .askOpen:
            return dispatchAskOpen(request)
        case .askResult:
            guard let target = request.target else {
                return ControlResponse(ok: false, error: "ask.result requires an ask id")
            }
            return actions.askResult(target, window: request.args?.window)
        case .askCancel:
            guard let target = request.target else {
                return ControlResponse(ok: false, error: "ask.cancel requires an ask id")
            }
            return actions.cancelAsk(target, window: request.args?.window)
        default:
            preconditionFailure("dispatchAskCommand called for \(request.cmd.rawValue)")
        }
    }

    private func dispatchAskOpen(_ request: ControlRequest) -> ControlResponse {
        guard let args = request.args, let title = args.title,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ControlResponse(ok: false, error: "ask.open requires a title")
        }
        guard let buttons = args.buttons else {
            return ControlResponse(ok: false, error: "ask.open requires buttons")
        }
        guard !buttons.isEmpty else {
            return ControlResponse(ok: false, error: "ask.open requires at least one button")
        }
        guard buttons.count <= ControlAskButton.maxButtons else {
            return ControlResponse(ok: false, error: "too many buttons (max \(ControlAskButton.maxButtons))")
        }
        guard buttons.allSatisfy({ !$0.label.isEmpty }) else {
            return ControlResponse(ok: false, error: "ask button label must not be empty")
        }
        var ids = Set<String>()
        guard buttons.allSatisfy({ ids.insert($0.id).inserted }) else {
            return ControlResponse(ok: false, error: "ask button ids must be unique")
        }
        guard !containsControlCharacters(title), !containsControlCharacters(args.message ?? ""),
              buttons.allSatisfy({ !containsControlCharacters($0.label) }) else {
            return ControlResponse(ok: false, error: "ask text must not contain control characters")
        }
        for (role, id) in [("default", args.defaultButton),
                           ("destructive", args.destructiveButton)] {
            if let id, !ids.contains(id) {
                return ControlResponse(ok: false, error: "unknown \(role) button: \(id)")
            }
        }
        if let destructive = args.destructiveButton {
            if args.defaultButton == destructive {
                return ControlResponse(ok: false, error: "default button must not be destructive")
            }
        }
        guard let style = ControlAskStyle(rawValue: args.style ?? "terminal") else {
            return ControlResponse(ok: false, error: "unknown style")
        }
        guard let align = ControlAskAlignment(rawValue: args.align ?? "right") else {
            return ControlResponse(ok: false, error: "unknown align")
        }
        if let width = args.width, !(10...100).contains(width) {
            return ControlResponse(ok: false, error: "width must be 10 to 100")
        }
        var hotkeys = Set<String>()
        for button in buttons {
            guard let hotkey = button.hotkey else { continue }
            guard hotkey.utf8.count == 1, let ascii = hotkey.utf8.first,
                  (65...90).contains(ascii) || (97...122).contains(ascii) else {
                return ControlResponse(ok: false, error: "ask button hotkey must be one ASCII letter")
            }
            guard hotkeys.insert(hotkey.lowercased()).inserted else {
                return ControlResponse(ok: false, error: "ask button hotkeys must be unique")
            }
        }
        if args.pane != nil || args.paneID != nil, request.target == nil {
            return ControlResponse(ok: false, error: "--pane requires a session")
        }
        let pane: OverlayPane?
        switch parsePane(args.pane, error: "--pane must be left or right",
                         parse: { OverlayPane(controlName: $0) }) {
        case .pane(let parsed): pane = parsed
        case .rejected(let response): return response
        }
        let ask = PendingAsk(
            id: UUID().uuidString, title: title, message: args.message,
            buttons: buttons.map { ControlAskButton(id: $0.id, label: $0.label, hotkey: $0.hotkey?.lowercased()) },
            defaultID: args.defaultButton, destructiveID: args.destructiveButton, style: style, align: align, width: args.width
        )
        return actions.openAsk(ask, target: request.target, window: args.window,
                               placement: ControlAskPlacement(pane: pane, paneID: args.paneID),
                               follow: args.follow == true)
    }
}
