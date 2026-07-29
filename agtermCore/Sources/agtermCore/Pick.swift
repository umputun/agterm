import Foundation
import Observation

/// One picker request currently presented by a window.
public struct PendingPick: Equatable, Sendable {
    public let id: String
    public let items: [ControlPickItem]
    public let prompt: String?
    public let allowCustom: Bool

    public init(id: String, items: [ControlPickItem], prompt: String? = nil, allowCustom: Bool = false) {
        self.id = id
        self.items = items
        self.prompt = prompt
        self.allowCustom = allowCustom
    }
}

/// Owns the pending picker and most recent answer for one window.
@Observable
@MainActor
public final class PickController {
    public private(set) var pending: PendingPick?
    public private(set) var lastResult: ResolvedPick?

    public init() {}

    /// Opens `pick` unless another picker is already pending.
    @discardableResult
    public func open(_ pick: PendingPick) -> Bool {
        guard pending == nil else { return false }
        pending = pick
        lastResult = nil
        return true
    }

    /// Completes the pending picker with `outcome`.
    public func resolve(_ outcome: ControlPickResult) {
        guard let pending else { return }
        lastResult = ResolvedPick(id: pending.id, result: outcome)
        self.pending = nil
    }

    /// Completes the pending picker as cancelled.
    public func cancel() {
        resolve(ControlPickResult(result: .cancelled))
    }

    /// Returns the current or retained result for the exact picker id.
    public func result(for id: String) -> ControlPickResult? {
        if pending?.id == id {
            return ControlPickResult(result: .pending)
        }
        guard lastResult?.id == id else { return nil }
        return lastResult?.result
    }
}

/// Maps each window to the picker controller rendered in that window.
@MainActor
public final class PickRegistry {
    public static let shared = PickRegistry()
    private var controllers: [WindowInfo.ID: PickController] = [:]
    private var retainedResults: [WindowInfo.ID: ResolvedPick] = [:]

    private init() {}

    public func register(_ id: WindowInfo.ID, controller: PickController) {
        controllers[id] = controller
    }

    /// Remove a window's live controller, cancelling a pending pick first and retaining its terminal
    /// result so a control client whose next poll lands after window teardown can still read it.
    public func unregister(_ id: WindowInfo.ID) {
        guard let controller = controllers.removeValue(forKey: id) else { return }
        controller.cancel()
        if let result = controller.lastResult {
            retainedResults[id] = result
        }
    }

    public func controller(for id: WindowInfo.ID?) -> PickController? {
        guard let id else { return nil }
        return controllers[id]
    }

    /// The last result retained when a window unregistered, matched by the globally unique pick id.
    public func retainedResult(for pickID: String) -> ControlPickResult? {
        retainedResults.values.first { $0.id == pickID }?.result
    }

    /// A successfully opened next pick replaces the prior retained result for that window, mirroring
    /// `PickController.open` clearing its own `lastResult`.
    public func clearRetainedResult(for id: WindowInfo.ID) {
        retainedResults[id] = nil
    }
}
