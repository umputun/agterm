import Foundation
import os

/// LaunchTrace logs each launch milestone once per process, so a launch that stops short shows which
/// milestone it never reached.
final class LaunchTrace: Sendable {
    static let shared = LaunchTrace { stage, detail in
        logger.notice("launch: \(stage.rawValue, privacy: .public) \(detail, privacy: .public)")
    }

    enum Stage: String, Sendable {
        case initEntry = "init entry"
        case initExit = "init exit"
        case willFinishLaunching = "will finish launching"
        case windowsRestored = "windows restored"
        case didFinishLaunchingEntry = "did finish launching entry"
        case didFinishLaunchingExit = "did finish launching exit"
        case sceneTask = "scene task"
        case socket
        case windowRegistered = "window registered"
    }

    private static let logger = Logger(subsystem: "com.umputun.agterm", category: "launch")
    private let seen = OSAllocatedUnfairLock(initialState: Set<Stage>())
    private let sink: @Sendable (Stage, String) -> Void

    init(sink: @escaping @Sendable (Stage, String) -> Void) {
        self.sink = sink
    }

    func mark(_ stage: Stage, _ detail: String = "") {
        guard seen.withLock({ $0.insert(stage).inserted }) else { return }
        sink(stage, detail)
    }
}
