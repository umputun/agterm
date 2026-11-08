import Foundation
import agtermCore

/// ServerConfiguration is where agterm-server keeps its state, its zmx daemons and its shipped resources.
public struct ServerConfiguration: Sendable, Equatable {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case missingRuntimeDirectory
        case unusableRuntimeDirectory(String)
        case missingZmx(String)

        public var description: String {
            switch self {
            case .missingRuntimeDirectory:
                "agterm-server needs XDG_RUNTIME_DIR for its zmx sockets; log in through a session manager, or run "
                    + "`loginctl enable-linger` for a service"
            case .unusableRuntimeDirectory(let path):
                "XDG_RUNTIME_DIR \(path) is not a writable directory"
            case .missingZmx(let path):
                "zmx is not executable at \(path)"
            }
        }
    }

    public var stateDirectory: String
    public var runtimeDirectory: String
    public var zmxPath: String
    /// Holds `shell-integration/` and `terminfo/`, laid out as `scripts/setup-zmx-linux.sh` stages them.
    public var resourcesDirectory: String
    /// The catalog's display name; the host name unless set.
    public var catalogName: String
    /// The shell panes start; the account's password-database shell unless set.
    public var loginShell: String

    public init(stateDirectory: String, runtimeDirectory: String, zmxPath: String, resourcesDirectory: String,
                catalogName: String, loginShell: String) {
        self.stateDirectory = stateDirectory
        self.runtimeDirectory = runtimeDirectory
        self.zmxPath = zmxPath
        self.resourcesDirectory = resourcesDirectory
        self.catalogName = catalogName
        self.loginShell = loginShell
    }

    public var socketPath: String { ControlResolve.socketPath(stateDir: stateDirectory, appSupport: stateDirectory) }

    public var zmxSocketDirectory: String {
        ZmxSupport.socketDirectory(forStateDirectory: stateDirectory, runtimeDirectory: runtimeDirectory)
    }

    /// resolve fills what the caller left unset: the state dir from `AGTERM_STATE_DIR` or the platform default
    /// the CLI also resolves, zmx and the resources beside the executable, the catalog name from the host. A relative
    /// state dir resolves against `workingDirectory`, since panes inherit it wherever they start.
    public static func resolve(stateDirectory: String? = nil, zmxPath: String? = nil, resourcesDirectory: String? = nil,
                               catalogName: String? = nil, loginShell: String? = nil, environment: [String: String],
                               executableDirectory: String, workingDirectory: String? = nil,
                               fileManager: FileManager = .default) throws -> ServerConfiguration {
        guard let runtime = environment["XDG_RUNTIME_DIR"], !runtime.isEmpty else { throw Failure.missingRuntimeDirectory }
        var isDirectory: ObjCBool = false
        guard runtime.hasPrefix("/"), fileManager.fileExists(atPath: runtime, isDirectory: &isDirectory), isDirectory.boolValue,
              fileManager.isWritableFile(atPath: runtime) else {
            throw Failure.unusableRuntimeDirectory(runtime)
        }
        let named = stateDirectory ?? environment["AGTERM_STATE_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? ControlResolve.defaultStateDirectory(environment: environment)
        let base = URL(fileURLWithPath: workingDirectory ?? fileManager.currentDirectoryPath, isDirectory: true)
        let state = named.hasPrefix("/") ? named : URL(fileURLWithPath: named, relativeTo: base).standardized.path
        let zmx = zmxPath ?? (executableDirectory as NSString).appendingPathComponent("zmx")
        guard fileManager.isExecutableFile(atPath: zmx) else { throw Failure.missingZmx(zmx) }
        let resources = resourcesDirectory ?? (executableDirectory as NSString).appendingPathComponent("resources")
        let name = catalogName ?? ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? "server"
        return ServerConfiguration(stateDirectory: state, runtimeDirectory: runtime, zmxPath: zmx,
                                   resourcesDirectory: resources, catalogName: name,
                                   loginShell: loginShell ?? passwordDatabaseShell() ?? environment["SHELL"] ?? "/bin/sh")
    }

    private static func passwordDatabaseShell() -> String? {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
        let path = String(cString: shell)
        return path.isEmpty ? nil : path
    }
}
