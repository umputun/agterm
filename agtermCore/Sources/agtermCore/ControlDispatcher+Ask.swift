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
        let form: AskForm?
        switch parseAskForm(args) {
        case .form(let parsed): form = parsed
        case .rejected(let response): return response
        }
        let generated = args.buttons == nil && form != nil
        guard let buttons = args.buttons ?? (generated ? Self.askFormButtons : nil) else {
            return ControlResponse(ok: false, error: "ask.open requires buttons")
        }
        let defaultButton = args.defaultButton ?? (generated ? "ok" : nil)
        let cancelButton = args.cancelButton ?? (generated ? "cancel" : nil)
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
        for (role, id) in [("default", defaultButton),
                           ("destructive", args.destructiveButton),
                           ("cancel", cancelButton)] {
            if let id, !ids.contains(id) {
                return ControlResponse(ok: false, error: "unknown \(role) button: \(id)")
            }
        }
        if let destructive = args.destructiveButton {
            if defaultButton == destructive {
                return ControlResponse(ok: false, error: "default button must not be destructive")
            }
        }
        if case .input = form, buttons.contains(where: { $0.hotkey != nil }) {
            return ControlResponse(ok: false, error: "ask input does not take hotkeys")
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
        if style == .gui, args.pane != nil || args.paneID != nil, request.target == nil {
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
            defaultID: defaultButton, destructiveID: args.destructiveButton, style: style, align: align, width: args.width,
            form: form, cancelID: cancelButton
        )
        return actions.openAsk(ask, target: request.target, window: args.window,
                               placement: ControlAskPlacement(pane: pane, paneID: args.paneID),
                               follow: args.follow == true)
    }

    private static let askFormButtons = [ControlAskButton(id: "ok", label: "OK"), ControlAskButton(id: "cancel", label: "Cancel")]

    private enum AskFormParse {
        case form(AskForm?)
        case rejected(ControlResponse)

        static func reject(_ error: String) -> AskFormParse { .rejected(ControlResponse(ok: false, error: error)) }
    }

    /// parseAskForm validates the optional text field or choice list, refusing arguments of the other form.
    private func parseAskForm(_ args: ControlArgs) -> AskFormParse {
        if args.input != nil, args.choices != nil { return .reject("input and choices are exclusive") }
        if args.input == nil {
            for (name, present) in [("value", args.value != nil), ("placeholder", args.placeholder != nil)] where present {
                return .reject("\(name) requires input")
            }
        }
        if args.choices == nil {
            for (name, present) in [("checked", args.checked != nil), ("multiple", args.multiple != nil),
                                    ("other", args.other != nil)] where present {
                return .reject("\(name) requires choices")
            }
        }
        if let input = args.input { return parseAskInput(input, value: args.value ?? "", placeholder: args.placeholder) }
        if let choices = args.choices {
            return parseAskChoices(choices, checked: args.checked ?? [], multiple: args.multiple ?? false, other: args.other)
        }
        return .form(nil)
    }

    private func parseAskInput(_ input: String, value: String, placeholder: String?) -> AskFormParse {
        guard let mode = ControlAskInputMode(rawValue: input) else { return .reject("unknown input") }
        guard value.utf8.count <= AskInputForm.maxTextBytes else {
            return .reject("ask text too long (max \(AskInputForm.maxTextBytes) bytes)")
        }
        guard !containsControlCharacters(placeholder ?? ""), !AskInputForm.hasForbiddenControls(value, mode: mode) else {
            return .reject("ask text must not contain control characters")
        }
        return .form(.input(AskInputForm(mode: mode, value: value, placeholder: placeholder)))
    }

    private func parseAskChoices(_ choices: [ControlAskChoice], checked: [String], multiple: Bool, other: String?) -> AskFormParse {
        guard (1...ControlAskChoice.maxChoices).contains(choices.count) else {
            return .reject("ask choices must be 1 to \(ControlAskChoice.maxChoices)")
        }
        guard choices.allSatisfy({ !$0.label.isEmpty }) else { return .reject("ask choice label must not be empty") }
        var ids = Set<String>()
        guard choices.allSatisfy({ ids.insert($0.id).inserted }) else { return .reject("ask choice ids must be unique") }
        guard choices.allSatisfy({ !containsControlCharacters($0.label) && !containsControlCharacters($0.subtitle ?? "", allowing: ["\n"]) }) else {
            return .reject("ask text must not contain control characters")
        }
        var seen = Set<String>()
        guard checked.allSatisfy({ seen.insert($0).inserted }) else { return .reject("ask checked ids must be unique") }
        if let unknown = checked.first(where: { !ids.contains($0) }) { return .reject("unknown checked choice: \(unknown)") }
        guard multiple || checked.count <= 1 else { return .reject("radio choices accept one checked id") }
        if let other {
            guard !AskChoiceForm.isBlank(other) else { return .reject("ask other placeholder must not be blank") }
            guard !containsControlCharacters(other) else { return .reject("ask text must not contain control characters") }
        }
        return .form(.choices(AskChoiceForm(choices: choices, multiple: multiple, checked: checked, other: other)))
    }

    private func containsControlCharacters(_ text: String, allowing allowed: Set<Unicode.Scalar>) -> Bool {
        text.unicodeScalars.contains { ($0.value < 0x20 || $0.value == 0x7f) && !allowed.contains($0) }
    }
}
