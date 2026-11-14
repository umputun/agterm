import Foundation

/// ZmxKillOutcome is what a single `zmx kill` actually did. `staleSocket` is its own case because zmx prints
/// `cleaned up stale session` and exits ZERO after merely unlinking a socket it could not connect to: the daemon
/// may still be running, unreachable by name, so counting that as a kill would report a process gone that is not.
public enum ZmxKillOutcome: Equatable, Sendable {
    case killed
    case staleSocket
    case failed(String)

    /// parse reads `output`, stdout and stderr merged; exit zero can mean an unreachable daemon, so only an exact
    /// confirmation line for `name` counts.
    public static func parse(_ output: String, name: String) -> ZmxKillOutcome {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains("killed session \(name)") { return .killed }
        if lines.contains("cleaned up stale session \(name)") { return .staleSocket }
        return .failed(lines.first ?? "no output")
    }
}
