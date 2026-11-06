import AgtermServerKit
import ArgumentParser
import Foundation
import agtermCore

struct ServerCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agterm-server",
        abstract: "Run agterm sessions on this host for a Mac's remote window."
    )

    @Option(name: .long, help: "State directory; defaults to AGTERM_STATE_DIR, then ~/.local/state/agterm.")
    var stateDir: String?
    @Option(name: .long, help: "The zmx binary; defaults to zmx beside agterm-server.")
    var zmx: String?
    @Option(name: .long, help: "Shell integration and terminfo; defaults to resources/ beside agterm-server.")
    var resources: String?
    @Option(name: .long, help: "The catalog's name; defaults to the host name.")
    var name: String?
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

let command = ServerCommand.parseOrExit()
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
