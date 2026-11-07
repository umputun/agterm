import AgtermServerKit
import ArgumentParser
import Foundation
import agtermCore

// ahead of everything: a spawn helper must exec before this process starts threads or opens anything
CleanExec.runIfRequested()

struct ServerCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agterm-server",
        abstract: "Run agterm sessions on this host for a Mac's remote window.",
        subcommands: [Serve.self, InstallHooks.self],
        defaultSubcommand: Serve.self
    )
}

struct Serve: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Serve the catalog and its sessions (the default).")

    @Option(name: .long, help: "State directory; defaults to AGTERM_STATE_DIR, then ~/.local/state/agterm.")
    var stateDir: String?
    @Option(name: .long, help: "The zmx binary; defaults to zmx beside agterm-server.")
    var zmx: String?
    @Option(name: .long, help: "Shell integration and terminfo; defaults to resources/ beside agterm-server.")
    var resources: String?
    @Option(name: .long, help: "The catalog's name; defaults to the host name.")
    var name: String?
}

struct InstallHooks: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install the agent status hooks and the agterm skill for this user, pointing at this server's agtermctl."
    )

    @Option(name: .long, help: "OpenCode's major version, v1 or v2; defaults to what `opencode --version` reports.")
    var opencode: String?
    @Option(name: .long, help: "The hook scripts and the skill; defaults to resources/ beside agterm-server.")
    var resources: String?

    func validate() throws {
        guard let opencode, AgentHooksInstall.OpenCode.Version(rawValue: opencode) == nil else { return }
        throw ValidationError("--opencode takes v1 or v2")
    }
}

/// The running executable's directory: `/proc/self/exe` or `_NSGetExecutablePath`, resolved, never `argv[0]`.
func executableDirectory() -> String {
    #if canImport(Darwin)
    var size = UInt32(0)
    _ = _NSGetExecutablePath(nil, &size)
    var buffer = [CChar](repeating: 0, count: Int(size))
    _ = _NSGetExecutablePath(&buffer, &size)
    let resolved = realpath(buffer, nil)
    #else
    let resolved = realpath("/proc/self/exe", nil)
    #endif
    guard let resolved else { return FileManager.default.currentDirectoryPath }
    defer { free(resolved) }
    return (String(cString: resolved) as NSString).deletingLastPathComponent
}

// exits 1 when a step was skipped or refused, so an install script can report the hooks as incomplete
func installHooks(_ command: InstallHooks) -> Never {
    let directory = executableDirectory()
    let install = ServerHookInstall(
        resourcesDirectory: command.resources ?? (directory as NSString).appendingPathComponent("resources"),
        home: FileManager.default.homeDirectoryForCurrentUser,
        toolPath: (directory as NSString).appendingPathComponent("agtermctl"),
        environment: ProcessInfo.processInfo.environment,
        openCode: command.opencode.flatMap(AgentHooksInstall.OpenCode.Version.init(rawValue:)))
    do {
        let report = try install.run()
        print(report.lines.joined(separator: "\n"))
        exit(report.complete ? 0 : 1)
    } catch {
        FileHandle.standardError.write(Data("agterm-server: \(error)\n".utf8))
        exit(1)
    }
}

let parsed: ParsableCommand
do {
    parsed = try ServerCommand.parseAsRoot()
} catch {
    ServerCommand.exit(withError: error)
}
if let install = parsed as? InstallHooks { installHooks(install) }
guard let command = parsed as? Serve else { ServerCommand.exit(withError: CleanExit.helpRequest(ServerCommand.self)) }
// replies and streams write with MSG_NOSIGNAL; this covers the pipes to the zmx processes the server runs
signal(SIGPIPE, SIG_IGN)

let configuration: ServerConfiguration
do {
    configuration = try ServerConfiguration.resolve(
        stateDirectory: command.stateDir, zmxPath: command.zmx, resourcesDirectory: command.resources,
        catalogName: command.name, environment: ProcessInfo.processInfo.environment,
        executableDirectory: executableDirectory())
} catch {
    FileHandle.standardError.write(Data("agterm-server: \(error)\n".utf8))
    exit(1)
}

let server: AgtermServer
do {
    server = try AgtermServer.start(configuration: configuration, identity: AppIdentity(version: ServerVersion.current))
} catch {
    FileHandle.standardError.write(Data("agterm-server: \(error)\n".utf8))
    exit(1)
}
FileHandle.standardError.write(Data("agterm-server: serving \(configuration.socketPath)\n".utf8))

var stopSources: [DispatchSourceSignal] = []
for number in [SIGTERM, SIGINT] {
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    // @Sendable: written in top-level code the closure would inherit main-actor isolation, and after dispatchMain
    // libdispatch runs the main queue on another thread
    source.setEventHandler { @Sendable in
        Task { @MainActor in
            server.stop()
            exit(0)
        }
    }
    source.resume()
    stopSources.append(source)
}
dispatchMain()
