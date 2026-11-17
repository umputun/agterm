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

    /// Decision is what `update.check` does with the updater's current phase.
    public enum Decision: Equatable, Sendable {
        case busy, focus, probe
    }

    /// Outcome is what Sparkle's silent check found.
    public enum Outcome: Equatable, Sendable {
        case found(version: String), none, failed(String)
    }

    /// decide refuses while a session is checking or downloading: Sparkle's `canCheckForUpdates` turns false at a
    /// session's start, before the phase hears of it, and true again once a menu check shows its progress.
    public static func decide(phase: UpdateFlow.Phase, sparkleCanCheck: Bool) -> Decision {
        switch phase {
        case .offering: .focus
        case .checking: .busy
        case .idle: sparkleCanCheck ? .probe : .busy
        }
    }

    /// outcome prefers a find, then Sparkle's no-update answer, so its not-found error is not read as a failure.
    public static func outcome(found: String?, notFound: Bool, error: String?) -> Outcome {
        if let found { return .found(version: found) }
        if notFound { return .none }
        if let error { return .failed(error) }
        return .none
    }

    /// refusal is an error reply with the given text.
    public static func refusal(_ text: String) -> ControlResponse {
        ControlResponse(ok: false, error: text)
    }

    /// focusReply answers a check that brought up an offer already waiting.
    public static func focusReply(host: String) -> ControlResponse {
        ControlResponse(ok: true, result: ControlResult(text: "update window opened on \(host)"))
    }

    /// reply names the Mac, since a remote pane's socket can belong to another one; a skipped version is not offered.
    public static func reply(_ outcome: Outcome, host: String) -> ControlResponse {
        switch outcome {
        case let .found(version):
            ControlResponse(ok: true, result: ControlResult(text: "agterm \(version) is available on \(host); opening the update window"))
        case .none:
            ControlResponse(ok: true, result: ControlResult(text: "no update offered on \(host)"))
        case let .failed(error):
            ControlResponse(ok: false, error: "update check failed on \(host): \(error)")
        }
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
    /// phase is where the updater's session stands, as `update.check` needs it.
    public private(set) var phase = Phase.idle

    /// Phase separates a session still fetching or downloading from an offer waiting on the user.
    public enum Phase: Equatable, Sendable {
        case idle, checking, offering
    }

    public init() {}

    /// installerWillRelaunch marks Sparkle's relaunch announcement.
    public mutating func installerWillRelaunch() { relaunchPending = true }

    /// updateCycleEnded clears every mark when the cycle finishes or aborts.
    public mutating func updateCycleEnded() {
        relaunchPending = false
        reminderPending = false
        phase = .idle
    }

    /// reserveCheck claims the session for `update.check` before Sparkle's asynchronous start reports it.
    public mutating func reserveCheck() { phase = .checking }

    /// sessionStarted marks a session Sparkle began on its own schedule or from the menu.
    public mutating func sessionStarted() {
        if phase == .idle { phase = .checking }
    }

    /// updateFound records an offer; one Sparkle shows in its own window needs no icon.
    public mutating func updateFound(sparkleShows: Bool) {
        phase = .offering
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
