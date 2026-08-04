import Foundation

extension ControlDispatcher {
    /// Validates host-free HUD arguments before the host measures the terminal font, writes the rendered
    /// message file, and takes the session's overlay slot. Only text, color, percent, and position are
    /// checked here; slot occupancy and sizing need the store and stay app-side.
    func dispatchHudCommand(_ request: ControlRequest) -> ControlResponse {
        if request.cmd == .sessionHudClose {
            return actions.closeHud(request.target, window: request.args?.window)
        }
        // open and update validate identically — an update replaces the whole spec — so only the effect differs
        let post: (String?, String?, HudSpec) -> ControlResponse
        switch request.cmd {
        case .sessionHudOpen: post = actions.openHud
        case .sessionHudUpdate: post = actions.updateHud
        default: preconditionFailure("dispatchHudCommand called for \(request.cmd.rawValue)")
        }
        switch parseHudSpec(request) {
        case .rejected(let response): return response
        case .spec(let spec): return post(request.target, request.args?.window, spec)
        }
    }

    private enum HudSpecParse {
        case spec(HudSpec)
        case rejected(ControlResponse)
    }

    /// Open and update take the same arguments and the same rejections — an update replaces the panel's whole
    /// text rather than patching it, so an update with no message is a close the caller must ask for.
    private func parseHudSpec(_ request: ControlRequest) -> HudSpecParse {
        let args = request.args
        // blank joins absent: `HudLayout.wrap` drops whitespace-only text, so the panel would paint an empty
        // frame while `tree` reported a live HUD. `session.background text` refuses the same input.
        guard let message = args?.message, !message.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .rejected(ControlResponse(ok: false, error: "\(request.cmd.rawValue) requires a message"))
        }
        // the helper prints these bytes straight into a live terminal, so an escape sequence would paint
        // outside the panel; a newline joins the rejected class because `detail` is the second line on offer.
        guard !containsControlCharacters(message), !containsControlCharacters(args?.detail ?? "") else {
            return .rejected(ControlResponse(ok: false, error: "hud text must not contain control characters"))
        }
        guard HudLayout.textLength(message) <= HudSpec.maxTextLength else {
            return .rejected(ControlResponse(
                ok: false, error: "hud message too long (max \(HudSpec.maxTextLength) characters)"))
        }
        guard HudLayout.textLength(args?.detail ?? "") <= HudSpec.maxTextLength else {
            return .rejected(ControlResponse(
                ok: false, error: "hud detail too long (max \(HudSpec.maxTextLength) characters)"))
        }
        if let color = args?.color, !WatermarkConfig.isValidColorHex(color) {
            return .rejected(ControlResponse(ok: false, error: "invalid color: \(color) (#rrggbb)"))
        }
        if let percent = args?.sizePercent, !(1...100).contains(percent) {
            return .rejected(ControlResponse(ok: false,
                                             error: "\(request.cmd.rawValue): --size-percent must be 1...100"))
        }
        var position = HudPosition.defaultPosition
        if let raw = args?.position {
            guard let parsed = HudPosition(rawValue: raw) else {
                return .rejected(ControlResponse(
                    ok: false, error: "invalid position: \(raw) (\(HudPosition.validNamesList))"))
            }
            position = parsed
        }
        // `none` is the read-back's spelling for a static panel, so a caller echoing one back means "no
        // spinner" rather than a style this rejects.
        var spinner: HudSpinner?
        if let raw = args?.spinner, raw != HudSpinner.noneName {
            guard let parsed = HudSpinner(rawValue: raw) else {
                return .rejected(ControlResponse(
                    ok: false, error: "invalid spinner: \(raw) (\(HudSpinner.acceptedNamesList))"))
            }
            spinner = parsed
        }
        return .spec(HudSpec(message: message, detail: args?.detail, spinner: spinner,
                             backgroundColor: args?.color, sizePercent: args?.sizePercent, position: position))
    }
}
