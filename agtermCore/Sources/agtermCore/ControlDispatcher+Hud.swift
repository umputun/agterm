import Foundation

extension ControlDispatcher {
    /// Validates host-free HUD arguments before the host measures the terminal font, writes the rendered
    /// message file, and takes the session's overlay slot. Text, color, percent, position, and pane spelling
    /// are checked here; slot occupancy, pane identity, and sizing need the store and stay app-side.
    func dispatchHudCommand(_ request: ControlRequest) -> ControlResponse {
        if request.cmd == .sessionHudClose {
            return actions.closeHud(request.target, window: request.args?.window)
        }
        let post: (String?, String?, HudSpec, ControlHudPlacement) -> ControlResponse
        switch request.cmd {
        case .sessionHudOpen: post = actions.openHud
        case .sessionHudUpdate: post = actions.updateHud
        default: preconditionFailure("dispatchHudCommand called for \(request.cmd.rawValue)")
        }
        let pane: OverlayPane?
        switch parsePane(request.args?.pane, error: "--pane must be left or right",
                         parse: { OverlayPane(controlName: $0) }) {
        case .pane(let parsed): pane = parsed
        case .rejected(let response): return response
        }
        let placement = ControlHudPlacement(pane: pane, paneID: request.args?.paneID)
        switch parseHudSpec(request) {
        case .rejected(let response): return response
        case .spec(let spec): return post(request.target, request.args?.window, spec, placement)
        }
    }

    private enum HudSpecParse {
        case spec(HudSpec)
        case rejected(ControlResponse)
    }

    /// parseHudSpec validates open and update alike except for `fontSize`, which only open takes. An update
    /// replaces the whole spec rather than patching it, so one with no message is a close the caller must ask
    /// for.
    private func parseHudSpec(_ request: ControlRequest) -> HudSpecParse {
        let args = request.args
        let markdown = args?.markdown ?? false
        // blank joins absent: `HudLayout.wrap` drops whitespace-only text, so the panel would paint an empty
        // frame while `tree` reported a live HUD. `session.background text` refuses the same input.
        guard let message = args?.message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .rejected(ControlResponse(ok: false, error: "\(request.cmd.rawValue) requires a message"))
        }
        // the helper prints these bytes straight into a live terminal, so an escape sequence would paint
        // outside the panel; a plain newline joins the rejected class because `detail` is the second line on
        // offer, while markdown needs LF for its blocks and TAB for its indentation.
        let messageIsSafe = markdown ? !containsMarkdownControlCharacters(message) : !containsControlCharacters(message)
        guard messageIsSafe, !containsControlCharacters(args?.detail ?? "") else {
            return .rejected(ControlResponse(ok: false, error: "hud text must not contain control characters"))
        }
        let cap = markdown ? HudSpec.maxMarkdownLength : HudSpec.maxTextLength
        guard HudLayout.textLength(message) <= cap else {
            return .rejected(ControlResponse(ok: false, error: "hud message too long (max \(cap) characters)"))
        }
        guard HudLayout.textLength(args?.detail ?? "") <= HudSpec.maxTextLength else {
            return .rejected(ControlResponse(
                ok: false, error: "hud detail too long (max \(HudSpec.maxTextLength) characters)"))
        }
        if let color = args?.color, !WatermarkConfig.isValidColorHex(color) {
            return .rejected(ControlResponse(ok: false, error: "invalid color: \(color) (#rrggbb)"))
        }
        if let textColor = args?.textColor, !WatermarkConfig.isValidColorHex(textColor) {
            return .rejected(ControlResponse(ok: false, error: "invalid text color: \(textColor) (#rrggbb)"))
        }
        if let fontSize = args?.fontSize {
            guard request.cmd == .sessionHudOpen else {
                return .rejected(ControlResponse(
                    ok: false, error: "session.hud.update: --font-size is fixed at open; reopen the hud to change it"))
            }
            guard HudSpec.isValidFontSize(fontSize) else {
                return .rejected(ControlResponse(
                    ok: false, error: "session.hud.open: --font-size must be \(Int(HudSpec.fontSizeRange.lowerBound))...\(Int(HudSpec.fontSizeRange.upperBound)) points"))
            }
        }
        if let percent = args?.sizePercent, !(1...100).contains(percent) {
            return .rejected(ControlResponse(ok: false,
                                             error: "\(request.cmd.rawValue): --size-percent must be 1...100"))
        }
        // rejected rather than clamped: a caller who asked for a duration nothing can schedule gets told so,
        // instead of a panel that hides after some number he never chose.
        if let hideAfter = args?.hideAfter, !HudSpec.isValidHideAfter(hideAfter) {
            return .rejected(ControlResponse(
                ok: false,
                error: "\(request.cmd.rawValue): --hide-after must be 0...\(Int(HudSpec.maxHideAfter)) seconds"))
        }
        // `parse` takes the `top`/`bottom` aliases beside the nine anchors, and the rejection lists them for
        // the same reason the spinner's does: naming only the canonical set would refuse values this accepts.
        var position = HudPosition.defaultPosition
        if let raw = args?.position {
            guard let parsed = HudPosition.parse(raw) else {
                return .rejected(ControlResponse(
                    ok: false, error: "invalid position: \(raw) (\(HudPosition.acceptedNamesList))"))
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
                             backgroundColor: args?.color, textColor: args?.textColor,
                             sizePercent: args?.sizePercent, position: position,
                             hideAfter: args?.hideAfter, markdown: markdown, fontSize: args?.fontSize))
    }

    /// containsMarkdownControlCharacters is `containsControlCharacters` less LF and TAB, which markdown
    /// structure needs; the renderer neutralizes what the parser decodes from entities.
    private func containsMarkdownControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { ($0.value < 0x20 && $0 != "\n" && $0 != "\t") || $0.value == 0x7f }
    }
}
