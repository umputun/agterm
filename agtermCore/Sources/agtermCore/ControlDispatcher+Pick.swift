import Foundation

extension ControlDispatcher {
    /// Validates host-free picker arguments before handing window-scoped state to the app host.
    func dispatchPickCommand(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .pickOpen:
            guard let items = request.args?.items else {
                return ControlResponse(ok: false, error: "pick.open requires items")
            }
            let allowCustom = request.args?.allowCustom == true
            // an empty list is a text prompt, which only makes sense when a custom answer is accepted
            guard !items.isEmpty || allowCustom else {
                return ControlResponse(ok: false, error: "pick.open requires at least one item")
            }
            guard items.count <= ControlPickItem.maxItems else {
                return ControlResponse(ok: false, error: "too many items (max \(ControlPickItem.maxItems))")
            }
            guard items.allSatisfy({ !$0.label.isEmpty }) else {
                return ControlResponse(ok: false, error: "pick item label must not be empty")
            }

            var ids = Set<String>()
            guard items.allSatisfy({ ids.insert($0.id).inserted }) else {
                return ControlResponse(ok: false, error: "pick item ids must be unique")
            }
            guard items.allSatisfy({ item in
                !containsControlCharacters(item.label)
                    && item.subtitle.map { !containsControlCharacters($0) } != false
            }) else {
                return ControlResponse(ok: false, error: "item text must not contain control characters")
            }

            let pick = PendingPick(
                id: UUID().uuidString,
                items: items,
                prompt: request.args?.prompt,
                query: request.args?.query,
                allowCustom: allowCustom
            )
            return actions.openPick(
                pick,
                window: request.args?.window,
                follow: request.args?.follow == true
            )

        case .pickResult:
            guard let target = request.target else {
                return ControlResponse(ok: false, error: "pick.result requires a pick id")
            }
            return actions.pickResult(target, window: request.args?.window)

        case .pickCancel:
            guard let target = request.target else {
                return ControlResponse(ok: false, error: "pick.cancel requires a pick id")
            }
            return actions.cancelPick(target, window: request.args?.window)

        default:
            preconditionFailure("dispatchPickCommand called for \(request.cmd.rawValue)")
        }
    }

    private func containsControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }
}
