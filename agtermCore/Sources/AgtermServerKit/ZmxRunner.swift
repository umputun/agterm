import Foundation
import agtermCore

/// PaneLaunch is one detached zmx daemon to start: its name, the program it runs (empty for the login shell
/// zmx starts from `SHELL`), the environment it starts in and its working directory.
public struct PaneLaunch: Equatable, Sendable {
    public let name: String
    public let argv: [String]
    public let environment: [String: String]
    public let directory: String

    public init(name: String, argv: [String], environment: [String: String], directory: String) {
        self.name = name
        self.argv = argv
        self.environment = environment
        self.directory = directory
    }
}

/// ZmxRunner is what agterm-server asks of zmx. A fake stands in for it in tests.
public protocol ZmxRunner: Sendable {
    /// create starts a detached daemon; the error is zmx's own message.
    func create(_ launch: PaneLaunch) throws
    /// kill ends the daemon and every process its shell started in the foreground.
    func kill(_ name: String) -> Bool
    /// list is every daemon in the server's socket directory; it throws rather than return a partial list.
    func list() throws -> [ZmxSessionRecord]
    func screen(_ name: String, all: Bool) -> ZmxScreen?
    func type(_ name: String, bytes: [UInt8]) -> Bool
}

/// ZmxRunnerError is a zmx call that did not do what was asked.
public enum ZmxRunnerError: Error, Equatable, CustomStringConvertible {
    case failed(String)

    public var description: String {
        switch self {
        case .failed(let message): message
        }
    }
}

/// ServerPlacement is where a new daemon lives: in a transient systemd scope of its own, outside the server
/// unit's cgroup, so stopping, restarting or crashing the server signals no pane; or, with no user manager to
/// ask, wherever zmx puts it.
public enum ServerPlacement: Equatable, Sendable {
    case direct
    case systemdScope(systemdRun: String)

    /// detect picks a scope when the user manager's private socket exists and `systemd-run` is on PATH.
    public static func detect(environment: [String: String], fileManager: FileManager = .default) -> ServerPlacement {
        guard let runtime = environment["XDG_RUNTIME_DIR"],
              fileManager.fileExists(atPath: (runtime as NSString).appendingPathComponent("systemd/private")) else {
            return .direct
        }
        let path = (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init)
        guard let run = path.map({ ($0 as NSString).appendingPathComponent("systemd-run") })
            .first(where: fileManager.isExecutableFile(atPath:)) else { return .direct }
        return .systemdScope(systemdRun: run)
    }

    /// prefix is what runs the zmx create. The unit name carries a random suffix: a scope that has not yet
    /// been collected keeps its name, and a respawned pane reuses its daemon name.
    func prefix(for name: String) -> [String] {
        switch self {
        case .direct: []
        case .systemdScope(let run):
            [run, "--user", "--scope", "--quiet", "--collect",
             "--unit=\(name)-\(UUID().uuidString.prefix(8).lowercased()).scope", "--"]
        }
    }
}

/// ProcessZmxRunner runs the zmx binary against the server's socket directory.
public struct ProcessZmxRunner: ZmxRunner {
    static let timeout: TimeInterval = 10

    let zmxPath: String
    let socketDirectory: String
    let placement: ServerPlacement
    let baseEnvironment: [String: String]

    public init(zmxPath: String, socketDirectory: String, placement: ServerPlacement, baseEnvironment: [String: String]) {
        self.zmxPath = zmxPath
        self.socketDirectory = socketDirectory
        self.placement = placement
        self.baseEnvironment = baseEnvironment
    }

    public func create(_ launch: PaneLaunch) throws {
        try FileManager.default.createDirectory(atPath: socketDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let argv = placement.prefix(for: launch.name) + [zmxPath, "attach", "--detached", launch.name] + launch.argv
        let output = try ServerProcess.run(argv, environment: launch.environment, directory: launch.directory,
                                           timeout: Self.timeout)
        guard output.status == 0 else {
            throw ZmxRunnerError.failed((output.stderr + output.stdout).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    public func kill(_ name: String) -> Bool {
        (try? invoke(["kill", name, "--force"]).status) == 0
    }

    public func list() throws -> [ZmxSessionRecord] {
        let output = try invoke(["list"])
        guard output.status == 0 else { throw ZmxRunnerError.failed(output.stderr) }
        // a cut-short listing leaves out live daemons, and the observer would end their panes
        guard output.stdoutComplete else { throw ZmxRunnerError.failed("zmx list output did not end") }
        return try ZmxListParser.parse(output.stdout)
    }

    public func screen(_ name: String, all: Bool) -> ZmxScreen? {
        guard let output = try? invoke(["screen", name] + (all ? ["--all"] : [])), output.status == 0,
              output.stdoutComplete else { return nil }
        return ZmxScreen(output: output.stdout)
    }

    public func type(_ name: String, bytes: [UInt8]) -> Bool {
        (try? invoke(["type", name], input: Data(bytes)).status) == 0
    }

    private func invoke(_ arguments: [String], input: Data? = nil) throws -> ServerProcess.Output {
        var environment = baseEnvironment
        environment["ZMX_DIR"] = socketDirectory
        environment["ZMX_SESSION"] = ""
        environment["ZMX_SESSION_PREFIX"] = ""
        return try ServerProcess.run([zmxPath] + arguments, environment: environment, input: input, timeout: Self.timeout)
    }
}
