import Foundation

/// UpdateCheck answers `update.check` from what the app's updater reports.
public enum UpdateCheck {
    public static let noFeed = "update checks are off: this build has no update feed"
    public static let busy = "an update check is already running"

    /// hostName is the `gethostname()` name without `.local`; `Host.current()` would resolve over mDNS.
    public static let hostName: String = {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "this Mac" }
        let name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return name.hasSuffix(".local") ? String(name.dropLast(6)) : name
    }()

    /// response is ok only when Sparkle can start a check or bring up the update it found; the reply names the
    /// Mac, since a remote pane's socket can belong to another one.
    public static func response(hasFeed: Bool, canCheck: Bool, host: String) -> ControlResponse {
        guard hasFeed else { return ControlResponse(ok: false, error: noFeed) }
        guard canCheck else { return ControlResponse(ok: false, error: busy) }
        return ControlResponse(ok: true, result: ControlResult(text: "update check requested on \(host)"))
    }
}

/// UpdateFlow picks the alert for a quit while Sparkle may be installing an update.
public struct UpdateFlow: Equatable, Sendable {
    /// QuitAlert is the alert a quit gets.
    public enum QuitAlert: Equatable, Sendable {
        case none, quit, restart
    }

    /// relaunchPending survives Later because Sparkle announces each relaunch only once.
    public private(set) var relaunchPending = false
    /// reminderPending is a scheduled find the title-bar icon announces in place of Sparkle's window.
    public private(set) var reminderPending = false

    public init() {}

    /// installerWillRelaunch marks Sparkle's relaunch announcement.
    public mutating func installerWillRelaunch() { relaunchPending = true }

    /// updateCycleEnded clears both marks when the cycle finishes or aborts.
    public mutating func updateCycleEnded() {
        relaunchPending = false
        reminderPending = false
    }

    /// updateFound records a find; one Sparkle shows in its own window needs no icon.
    public mutating func updateFound(sparkleShows: Bool) {
        if !sparkleShows { reminderPending = true }
    }

    /// reminderEnded clears the icon once the user attends to the update or Sparkle ends its session.
    public mutating func reminderEnded() { reminderPending = false }

    /// showsIcon is whether the title bar shows the icon; a hidden element hides it and opens nothing.
    public func showsIcon(elementShown: Bool) -> Bool { elementShown && reminderPending }

    /// iconCanShow is whether a title bar exists to carry the icon; a hidden title bar leaves the find to Sparkle.
    public static func iconCanShow(elementShown: Bool, toolbarMode: ToolbarMode) -> Bool {
        elementShown && toolbarMode != .hidden
    }

    /// sparkleShowsScheduledUpdate is whether Sparkle presents a scheduled find itself: always without the icon,
    /// otherwise only when Sparkle proposes immediate focus (near launch or after the system idles).
    public static func sparkleShowsScheduledUpdate(iconShown: Bool, immediateFocus: Bool) -> Bool {
        !iconShown || immediateFocus
    }

    /// quitAlert answers none with no window open.
    public func quitAlert(openWindows: Int) -> QuitAlert {
        guard openWindows > 0 else { return .none }
        return relaunchPending ? .restart : .quit
    }
}
