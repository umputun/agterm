import agtermCore
import Darwin
import Foundation
import os

enum ZmxLaunch {
    typealias Disposition = ZmxSupport.LaunchDisposition

    struct SurfaceSeed: Equatable {
        let command: String
        let initialInput: String?
    }

    private struct Runtime {
        let bundleURL: URL
        let environment: [String: String]
        let passwordDatabaseShell: String?
        let allowDebugOverride: Bool
    }

    /// Whether this pane may be wrapped in a LOCAL zmx daemon; both surface factories gate on it. A remote
    /// session never is — a wrapper would keep its ssh alive inside a surviving daemon after a window
    /// close, with no UI showing it.
    @MainActor
    static func wrapsLocally(mode: RestoreMode, session: Session) -> Bool {
        mode == .live && session.remoteHost == nil
    }

    static let uiTestOptInKey = "AGTERM_UITEST_ENABLE_ZMX"
    static let uiTestBypassReason = "Live sessions are disabled for default UI tests."
    private static let logger = Logger(subsystem: "com.umputun.agterm", category: "ZmxLaunch")

    static var allowDebugOverride: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    static func executablePath(bundleURL: URL, environment: [String: String],
                               allowDebugOverride: Bool) -> String {
        if allowDebugOverride, let override = environment["AGTERM_ZMX_PATH"], !override.isEmpty {
            return override
        }
        return bundleURL.appendingPathComponent("Contents/MacOS/zmx").path
    }

    @MainActor
    static func liveUnavailableReason(
        bundleURL: URL = Bundle.main.bundleURL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        passwordDatabaseShell: String? = passwordDatabaseLoginShell(),
        isUITestLaunch: Bool = ContentView.isUITestLaunch,
        allowDebugOverride: Bool = allowDebugOverride
    ) -> String? {
        if isUITestLaunch, environment[uiTestOptInKey] != "1" { return uiTestBypassReason }
        let runtime = Runtime(bundleURL: bundleURL, environment: environment,
                              passwordDatabaseShell: passwordDatabaseShell,
                              allowDebugOverride: allowDebugOverride)
        return switch configurationResult(runtime: runtime,
                                          paneIdentity: UUID(), baseEnvironment: [:]) {
        case .success: nil
        case .failure(let reason): reason.message
        }
    }

    @MainActor static func configuration(paneIdentity: UUID?, pane: String, environment base: [String: String])
        -> ZmxSupport.Configuration? {
        guard let paneIdentity else {
            logger.error("zmx configuration failed for \(pane, privacy: .public) pane: missing pane identity")
            return nil
        }
        let runtime = Runtime(bundleURL: Bundle.main.bundleURL,
                              environment: ProcessInfo.processInfo.environment,
                              passwordDatabaseShell: passwordDatabaseLoginShell(),
                              allowDebugOverride: allowDebugOverride)
        let result = configurationResult(runtime: runtime, paneIdentity: paneIdentity, baseEnvironment: base)
        switch result {
        case .success(let configuration): return configuration
        case .failure(let reason):
            logger.error("zmx configuration failed for \(pane, privacy: .public) pane \(paneIdentity.uuidString, privacy: .public): \(reason.message, privacy: .public)")
            return nil
        }
    }

    static func disposition(requested: RestoreMode, active: RestoreMode,
                            configuration: ZmxSupport.Configuration?) -> Disposition {
        ZmxSupport.launchDisposition(requested: requested, active: active, configuration: configuration)
    }

    @MainActor
    static func surfaceSeed(disposition: Disposition, session: Session, pane: StatusPane,
                            denylist: Set<String>) -> SurfaceSeed? {
        guard case .wrapped(let configuration) = disposition else { return nil }
        let replay = session.takePendingForegroundCommand(pane: pane)
        let creationCommand: String? = if replay == nil {
            switch pane {
            case .left: session.initialCommand
            case .right: session.splitInitialCommand
            case .scratch: nil
            }
        } else { nil }
        return SurfaceSeed(
            command: ZmxSupport.attachCommand(
                configuration, replaying: replay, creationCommand: creationCommand, denylist: denylist
            ),
            initialInput: nil
        )
    }

    static func passwordDatabaseLoginShell() -> String? {
        guard let entry = getpwuid(getuid()), let ptr = entry.pointee.pw_shell else { return nil }
        let value = String(cString: ptr)
        return value.isEmpty ? nil : value
    }

    private static func configurationResult(runtime: Runtime, paneIdentity: UUID,
                                            baseEnvironment: [String: String])
        -> Result<ZmxSupport.Configuration, ZmxSupport.Rejection> {
        let bundledResources = runtime.bundleURL.appendingPathComponent("Contents/Resources/ghostty").path
        let resources = runtime.environment["GHOSTTY_RESOURCES_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? bundledResources
        let stateDirectory = runtime.environment["AGTERM_STATE_DIR"] ?? PersistenceStore.defaultDirectory.path
        return ZmxSupport.configuration(for: .init(
            zmxExecutablePath: executablePath(bundleURL: runtime.bundleURL, environment: runtime.environment,
                                              allowDebugOverride: runtime.allowDebugOverride),
            passwordDatabaseShell: runtime.passwordDatabaseShell,
            resourcesDirectory: resources,
            stateDirectory: stateDirectory,
            paneIdentity: paneIdentity,
            baseEnvironment: baseEnvironment,
            inheritedZdotdir: runtime.environment["ZDOTDIR"]
        ))
    }
}
