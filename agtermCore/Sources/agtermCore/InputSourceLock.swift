/// InputSourceLock decides when the keyboard input source is switched to the configured one and when the
/// earlier one comes back. It holds the source that was selected when the lock engaged; the app target
/// feeds it the system's state and performs the selection it returns.
public struct InputSourceLock: Equatable, Sendable {
    /// baseline is the source to return to, non-nil exactly while the lock holds an override.
    public private(set) var baseline: String?

    public init() {}

    /// reconcile returns the next source to select, or nil if no change is needed. A target outside
    /// `enabled` releases an existing override and cannot engage a new one.
    public mutating func reconcile(terminalFocused: Bool, target: String?, enabled: Set<String>,
                                   current: String) -> String? {
        guard terminalFocused, let target, enabled.contains(target) else { return release(current: current) }
        if baseline == nil { baseline = current }
        return current == target ? nil : target
    }

    /// release ends the override and returns the source to restore, nil when none is held or it is
    /// already selected.
    public mutating func release(current: String) -> String? {
        guard let held = baseline else { return nil }
        baseline = nil
        return held == current ? nil : held
    }

    /// selectionFailed drops an override whose selection macOS refused, leaving nothing to restore.
    public mutating func selectionFailed() { baseline = nil }
}
