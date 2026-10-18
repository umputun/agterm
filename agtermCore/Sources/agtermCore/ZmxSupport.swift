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
        /// Nil leaves the attach unmanaged, as a zmx without explicit leadership expects.
        public let lead: ZmxLeadAttachment?

        public init(zmxExecutablePath: String, passwordDatabaseShell: String?, resourcesDirectory: String?,
                    stateDirectory: String, paneIdentity: UUID, baseEnvironment: [String: String],
                    inheritedZdotdir: String?, sessionHostExecutablePath: String? = nil,
                    lead: ZmxLeadAttachment? = nil) {
            self.zmxExecutablePath = zmxExecutablePath
            self.passwordDatabaseShell = passwordDatabaseShell
            self.resourcesDirectory = resourcesDirectory
            self.stateDirectory = stateDirectory
            self.paneIdentity = paneIdentity
            self.baseEnvironment = baseEnvironment
            self.inheritedZdotdir = inheritedZdotdir
            self.sessionHostExecutablePath = sessionHostExecutablePath
            self.lead = lead
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
        case missingFishIntegration

        public var message: String {
            switch self {
            case .executablePathNotAbsolute: "the zmx executable path is not absolute"
            case .executableUnavailable: "the zmx executable is unavailable"
            case .unsupportedLoginShell: "the password-database login shell is not zsh or fish"
            case .missingZshIntegration: "the bundled zsh integration is unavailable"
            case .missingFishIntegration: "the bundled fish integration is unavailable"
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
        guard let shell = inputs.passwordDatabaseShell, let shellKind = shellKind(for: shell) else {
            return .failure(.unsupportedLoginShell)
        }
        guard let resources = inputs.resourcesDirectory else {
            return .failure(shellKind.missingIntegrationRejection)
        }

        let daemonName = daemonName(for: inputs.paneIdentity)
        let socketDirectory = socketDirectory(forStateDirectory: inputs.stateDirectory)

        let paneID = inputs.paneIdentity.uuidString
        var environment = inputs.baseEnvironment
        environment["AGTERM_PANE_ID"] = paneID
        environment["SHELL"] = shell
        switch shellKind {
        case .zsh:
            let integrationDirectory = URL(fileURLWithPath: resources)
                .standardizedFileURL.appending(path: "shell-integration/zsh").path
            guard FileManager.default.fileExists(atPath: integrationDirectory + "/.zshenv") else {
                return .failure(.missingZshIntegration)
            }
            environment["ZDOTDIR"] = integrationDirectory
            if let inheritedZdotdir = inputs.inheritedZdotdir {
                environment["GHOSTTY_ZSH_ZDOTDIR"] = inheritedZdotdir
            }
        case .fish:
            let integrationRoot = URL(fileURLWithPath: resources)
                .standardizedFileURL.appending(path: "shell-integration").path
            let marker = integrationRoot + "/fish/vendor_conf.d/ghostty-shell-integration.fish"
            guard FileManager.default.fileExists(atPath: marker) else {
                return .failure(.missingFishIntegration)
            }
            environment["GHOSTTY_SHELL_INTEGRATION_XDG_DIR"] = integrationRoot
        }
        environment["ZMX_DIR"] = socketDirectory
        environment["ZMX_SESSION"] = ""
        environment["ZMX_SESSION_PREFIX"] = ""
        environment["ZMX_NO_DETACH_KEY"] = "1"
        // a stale value inherited from the app's own environment would opt the client in under a
        // nonce no pane expects
        environment[ZmxLeadAttachment.nonceVariable] = nil
        environment[ZmxLeadAttachment.claimVariable] = nil
        environment.merge(inputs.lead?.environment ?? [:]) { _, new in new }

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
        if let shell = configuration.environment["SHELL"], shellKind(for: shell) == .fish,
           let integrationRoot = configuration.environment["GHOSTTY_SHELL_INTEGRATION_XDG_DIR"] {
            arguments = ["/usr/bin/env", "/bin/sh", "-c", fishXDGDataDirectoriesScript, "sh", integrationRoot] + arguments
        }
        return CommandRestore.shellQuotedLine(arguments)
    }

    /// Merged at launch because a surface `XDG_DATA_DIRS` would replace a `ghostty.conf` `env` entry.
    static let fishXDGDataDirectoriesScript = [
        "root=$1", "shift", "set -f", "merged=$root", "IFS=:",
        "for entry in ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do"
            + " if [ -n \"$entry\" ] && [ \"$entry\" != \"$root\" ]; then merged=$merged:$entry; fi; done",
        "unset IFS", "XDG_DATA_DIRS=$merged", "export XDG_DATA_DIRS", "exec \"$@\"",
    ].joined(separator: "; ")

    private static func creationArguments(_ configuration: Configuration, replaying argv: [String]?,
                                          creationCommand: String?, denylist: Set<String>) -> [String] {
        guard let shell = configuration.environment["SHELL"], let shellKind = shellKind(for: shell) else {
            return []
        }
        let script: String
        switch shellKind {
        case .zsh:
            guard let integrationDirectory = configuration.environment["ZDOTDIR"] else { return [] }
            let inheritedZdotdir = configuration.environment["GHOSTTY_ZSH_ZDOTDIR"]
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
        case .fish:
            guard let integrationRoot = configuration.environment["GHOSTTY_SHELL_INTEGRATION_XDG_DIR"] else {
                return []
            }
            if let argv {
                guard CommandRestore.shouldRestore(argv: argv, denylist: denylist) else {
                    return []
                }
                script = ZmxReplayScript.renderFish(argv: argv, integrationRoot: integrationRoot, shell: shell)
            } else if let creationCommand {
                script = ZmxReplayScript.renderFish(
                    commandLine: creationCommand, integrationRoot: integrationRoot, shell: shell
                )
            } else {
                return []
            }
        }
        return [shell, "-lic", script]
    }

    private enum ShellKind {
        case zsh
        case fish

        var missingIntegrationRejection: Rejection {
            switch self {
            case .zsh: .missingZshIntegration
            case .fish: .missingFishIntegration
            }
        }
    }

    private static func shellKind(for shell: String) -> ShellKind? {
        switch CommandRestore.basename(shell) {
        case "zsh": .zsh
        case "fish": .fish
        default: nil
        }
    }

    public static func socketDirectory(forStateDirectory stateDirectory: String) -> String {
        let canonical = URL(fileURLWithPath: stateDirectory, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
        return "/tmp/agterm-zmx-\(stableHash(canonical))"
    }

    public static func daemonName(for paneIdentity: UUID) -> String {
        namePrefix + compactUUID(paneIdentity)
    }

    /// The pane identity `daemonName(for:)` built `name` from, nil for any other name.
    public static func paneIdentity(fromDaemonName name: String) -> UUID? {
        guard isDaemonName(name) else { return nil }
        let hex = Array(name.dropFirst(namePrefix.count))
        let groups = [hex[0..<8], hex[8..<12], hex[12..<16], hex[16..<20], hex[20..<32]]
        return UUID(uuidString: groups.map { String($0) }.joined(separator: "-"))
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
