import Foundation

/// Host-free validation and configuration for a zmx-backed terminal surface.
public enum ZmxSupport {
    static let namePrefix = "agterm-"

    public enum LaunchDisposition: Equatable, Sendable {
        case ordinary
        case wrapped(Configuration)
        /// Live was requested but unavailable. Restored panes start plain shells without consuming rerun
        /// state; fresh primary panes still honor their creation command.
        case fallback

        public var backedByZmx: Bool {
            guard case .wrapped = self else { return false }
            return true
        }
    }

    public struct Inputs: Sendable {
        public let zmxExecutablePath: String
        public let passwordDatabaseShell: String?
        public let resourcesDirectory: String?
        public let stateDirectory: String
        public let paneIdentity: UUID
        public let baseEnvironment: [String: String]
        public let inheritedZdotdir: String?
        public let sessionHostExecutablePath: String?

        public init(zmxExecutablePath: String, passwordDatabaseShell: String?, resourcesDirectory: String?,
                    stateDirectory: String, paneIdentity: UUID, baseEnvironment: [String: String],
                    inheritedZdotdir: String?, sessionHostExecutablePath: String? = nil) {
            self.zmxExecutablePath = zmxExecutablePath
            self.passwordDatabaseShell = passwordDatabaseShell
            self.resourcesDirectory = resourcesDirectory
            self.stateDirectory = stateDirectory
            self.paneIdentity = paneIdentity
            self.baseEnvironment = baseEnvironment
            self.inheritedZdotdir = inheritedZdotdir
            self.sessionHostExecutablePath = sessionHostExecutablePath
        }
    }

    public struct Configuration: Equatable, Sendable {
        public let executablePath: String
        public let sessionHostExecutablePath: String?
        public var attachArguments: [String] { [executablePath, "attach", daemonName] }
        public var command: String { CommandRestore.shellQuotedLine(attachArguments) }
        public let environment: [String: String]
        public let daemonName: String
        public let socketDirectory: String
        public let paneID: String

        public init(executablePath: String, environment: [String: String], daemonName: String,
                    socketDirectory: String, paneID: String, sessionHostExecutablePath: String? = nil) {
            self.executablePath = executablePath
            self.sessionHostExecutablePath = sessionHostExecutablePath
            self.environment = environment
            self.daemonName = daemonName
            self.socketDirectory = socketDirectory
            self.paneID = paneID
        }
    }

    public enum Rejection: Error, Equatable, Sendable {
        case executablePathNotAbsolute
        case executableUnavailable
        case unsupportedLoginShell
        case missingZshIntegration

        public var message: String {
            switch self {
            case .executablePathNotAbsolute: "the zmx executable path is not absolute"
            case .executableUnavailable: "the zmx executable is unavailable"
            case .unsupportedLoginShell: "the password-database login shell is not zsh"
            case .missingZshIntegration: "the bundled zsh integration is unavailable"
            }
        }
    }

    public static func configuration(for inputs: Inputs) -> Result<Configuration, Rejection> {
        guard (inputs.zmxExecutablePath as NSString).isAbsolutePath else {
            return .failure(.executablePathNotAbsolute)
        }
        let executable = URL(fileURLWithPath: inputs.zmxExecutablePath).standardizedFileURL.path
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return .failure(.executableUnavailable)
        }
        guard let shell = inputs.passwordDatabaseShell, CommandRestore.basename(shell) == "zsh" else {
            return .failure(.unsupportedLoginShell)
        }
        guard let resources = inputs.resourcesDirectory else {
            return .failure(.missingZshIntegration)
        }
        let integrationDirectory = URL(fileURLWithPath: resources)
            .standardizedFileURL.appending(path: "shell-integration/zsh").path
        guard FileManager.default.fileExists(atPath: integrationDirectory + "/.zshenv") else {
            return .failure(.missingZshIntegration)
        }

        let daemonName = daemonName(for: inputs.paneIdentity)
        let socketDirectory = socketDirectory(forStateDirectory: inputs.stateDirectory)

        let paneID = inputs.paneIdentity.uuidString
        var environment = inputs.baseEnvironment
        environment["AGTERM_PANE_ID"] = paneID
        environment["SHELL"] = shell
        environment["ZDOTDIR"] = integrationDirectory
        if let inheritedZdotdir = inputs.inheritedZdotdir {
            environment["GHOSTTY_ZSH_ZDOTDIR"] = inheritedZdotdir
        }
        environment["ZMX_DIR"] = socketDirectory
        environment["ZMX_SESSION"] = ""
        environment["ZMX_SESSION_PREFIX"] = ""
        environment["ZMX_NO_DETACH_KEY"] = "1"

        let host = inputs.sessionHostExecutablePath.flatMap { path -> String? in
            guard (path as NSString).isAbsolutePath, FileManager.default.isExecutableFile(atPath: path) else { return nil }
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }

        return .success(Configuration(
            executablePath: executable,
            environment: environment,
            daemonName: daemonName,
            socketDirectory: socketDirectory,
            paneID: paneID,
            sessionHostExecutablePath: host
        ))
    }

    public static func launchDisposition(requested: RestoreMode, active: RestoreMode,
                                         configuration: Configuration?) -> LaunchDisposition {
        guard requested == .live else { return .ordinary }
        guard active == .live, let configuration else { return .fallback }
        return .wrapped(configuration)
    }

    public static func attachCommand(_ configuration: Configuration, replaying argv: [String]?,
                                     creationCommand: String? = nil, denylist: Set<String>) -> String {
        var arguments = configuration.attachArguments + creationArguments(configuration, replaying: argv, creationCommand: creationCommand, denylist: denylist)
        if let host = configuration.sessionHostExecutablePath {
            arguments = [host, "client", configuration.daemonName, "--"] + arguments
        }
        return CommandRestore.shellQuotedLine(arguments)
    }

    private static func creationArguments(_ configuration: Configuration, replaying argv: [String]?,
                                          creationCommand: String?, denylist: Set<String>) -> [String] {
        guard let shell = configuration.environment["SHELL"],
              let integrationDirectory = configuration.environment["ZDOTDIR"] else {
            return []
        }
        let inheritedZdotdir = configuration.environment["GHOSTTY_ZSH_ZDOTDIR"]
        let script: String
        if let argv {
            guard CommandRestore.shouldRestore(argv: argv, denylist: denylist) else {
                return []
            }
            script = ZmxReplayScript.render(
                argv: argv, integrationDirectory: integrationDirectory,
                inheritedZdotdir: inheritedZdotdir, shell: shell
            )
        } else if let creationCommand {
            script = ZmxReplayScript.render(
                commandLine: creationCommand, integrationDirectory: integrationDirectory,
                inheritedZdotdir: inheritedZdotdir, shell: shell
            )
        } else {
            return []
        }
        return [shell, "-lic", script]
    }

    public static func socketDirectory(forStateDirectory stateDirectory: String) -> String {
        let canonical = URL(fileURLWithPath: stateDirectory, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
        return "/tmp/agterm-zmx-\(stableHash(canonical))"
    }

    public static func daemonName(for paneIdentity: UUID) -> String {
        namePrefix + compactUUID(paneIdentity)
    }

    /// Whether `name` is one of OUR daemons: the exact shape `daemonName(for:)` emits. A prefix test is
    /// not enough — the namespace is a shared /tmp directory, so a user session called `agterm-notes`
    /// would otherwise read as an unclaimed app daemon and be pruned.
    public static func isDaemonName(_ name: String) -> Bool {
        guard name.hasPrefix(namePrefix) else { return false }
        // ASCII bytes, not `Character.isHexDigit`, which is Unicode-aware: 32 fullwidth digits satisfy it
        // and are neither uppercase nor anything `daemonName(for:)` can emit.
        let body = name.utf8.dropFirst(namePrefix.utf8.count)
        return body.count == 32 && body.allSatisfy {
            ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9")) ||
                ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "f"))
        }
    }

    private static func compactUUID(_ id: UUID) -> String {
        id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}
