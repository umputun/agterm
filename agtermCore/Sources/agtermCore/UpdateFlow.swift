/// UpdateFlow picks the alert for a quit while Sparkle may be installing an update.
public struct UpdateFlow: Equatable, Sendable {
    /// QuitAlert is the alert a quit gets.
    public enum QuitAlert: Equatable, Sendable {
        case none, quit, restart
    }

    /// relaunchPending survives Later because Sparkle announces each relaunch only once.
    public private(set) var relaunchPending = false

    public init() {}

    /// installerWillRelaunch marks Sparkle's relaunch announcement.
    public mutating func installerWillRelaunch() { relaunchPending = true }

    /// updateCycleEnded clears the mark when the cycle finishes or aborts.
    public mutating func updateCycleEnded() { relaunchPending = false }

    /// quitAlert answers none with no window open.
    public func quitAlert(openWindows: Int) -> QuitAlert {
        guard openWindows > 0 else { return .none }
        return relaunchPending ? .restart : .quit
    }
}
