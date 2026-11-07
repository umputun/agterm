import Foundation
import agtermCore

/// ServerPanes starts and ends the zmx daemons behind the server's panes. A pane joins
/// `Session.daemonBackedPanes` only once its daemon was created.
@MainActor
final class ServerPanes {
    static let exitRecordDirectory = "pane-exits"

    let configuration: ServerConfiguration
    let runner: any ZmxRunner
    let shell: ServerShell?
    let shellPath: String
    let catalogID: UUID
    let programVersion: String
    /// The server's own environment, without the variables a pane gets from the server itself.
    let baseEnvironment: [String: String]
    private var startedAt: [UUID: Date] = [:]
    /// scratches are the identities this run started under a scratch daemon name, which `end` kills by that name.
    private var scratches: Set<UUID> = []

    init(configuration: ServerConfiguration, runner: any ZmxRunner, shellPath: String, catalogID: UUID,
         programVersion: String, environment: [String: String]) {
        self.configuration = configuration
        self.runner = runner
        self.shellPath = shellPath
        shell = ServerShell.named(shellPath)
        self.catalogID = catalogID
        self.programVersion = programVersion
        baseEnvironment = environment.filter { key, _ in
            !["AGTERM_", "ZMX_", "GHOSTTY_"].contains { key.hasPrefix($0) } && key != "TERMINFO"
        }
    }

    /// exitRecord is where a pane's daemon writes that its shell exited.
    func exitRecord(_ identity: UUID) -> String {
        ((configuration.stateDirectory as NSString).appendingPathComponent(Self.exitRecordDirectory) as NSString)
            .appendingPathComponent(identity.uuidString)
    }

    /// Start is one pane for `start` to create; a `command` runs once in place of the login shell.
    struct Start {
        let identity: UUID
        let session: Session
        let workspace: UUID?
        let pane: StatusPane
        var command: String?
        let directory: String
        /// scratch starts the pane under `scratchDaemonName` and leaves `daemonBackedPanes` to the session's panes.
        var scratch = false
    }

    /// daemonName is `identity`'s daemon: the scratch name for a scratch this run started.
    func daemonName(for identity: UUID) -> String {
        scratches.contains(identity) ? ZmxSupport.scratchDaemonName(for: identity) : ZmxSupport.daemonName(for: identity)
    }

    /// start creates the pane's daemon. Nil when it is running, otherwise the refusal.
    func start(_ start: Start) -> String? {
        let identity = start.identity, session = start.session
        guard let shell else { return ServerShell.refusal(shellPath) }
        let record = exitRecord(identity)
        try? FileManager.default.createDirectory(atPath: (record as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        // removed before the daemon exists, so a record a previous daemon of this identity left cannot end it
        try? FileManager.default.removeItem(atPath: record)
        var environment = baseEnvironment.merging(agtermEnvironment(session: session.id, workspace: start.workspace,
                                                                    pane: start.pane, paneToken: identity.uuidString)) { _, pane in pane }
        environment["TERM"] = TerminfoInstall.entry
        environment["COLORTERM"] = "truecolor"
        environment["ZMX_DIR"] = configuration.zmxSocketDirectory
        environment["ZMX_SESSION"] = ""
        environment["ZMX_SESSION_PREFIX"] = ""
        environment["ZMX_NO_DETACH_KEY"] = "1"
        environment["ZMX_EXIT_FILE"] = record
        let integration = (configuration.resourcesDirectory as NSString).appendingPathComponent("shell-integration")
        let launch = shell.launch(integration: integration, environment: environment, command: start.command)
        let home = baseEnvironment["HOME"] ?? "/"
        let directory = FileManager.default.fileExists(atPath: start.directory) ? start.directory : home
        startedAt[identity] = Date()
        let name = start.scratch ? ZmxSupport.scratchDaemonName(for: identity) : ZmxSupport.daemonName(for: identity)
        do {
            try runner.create(PaneLaunch(name: name, argv: launch.argv, environment: launch.environment, directory: directory))
        } catch {
            return "could not start the pane: \(error)"
        }
        if start.scratch { scratches.insert(identity) } else { session.daemonBackedPanes.insert(identity) }
        return nil
    }

    /// started reports whether `identity`'s daemon was started at or after `date`, so a listing taken before it
    /// cannot hold it.
    func started(_ identity: UUID, since date: Date) -> Bool {
        startedAt[identity].map { $0 >= date } ?? false
    }

    /// end kills the daemons of panes the store finalized before the command that closed them replies, so a
    /// restart right after the reply cannot leave one running unbooked. A failed kill is logged; the pane stays
    /// closed, as on the Mac.
    func end(_ identities: [UUID]) {
        for identity in identities {
            let name = daemonName(for: identity)
            scratches.remove(identity)
            if !runner.kill(name) { FileHandle.standardError.write(Data("agterm-server: could not end daemon \(name)\n".utf8)) }
        }
    }

    /// endUnownedScratches kills every listed scratch daemon this run does not own: one a previous run left, since a
    /// scratch never outlives its server, or one whose kill failed. A later listing retries it. It returns the rest.
    func endUnownedScratches(_ records: [ZmxSessionRecord]) -> [ZmxSessionRecord] {
        let owned = Set(scratches.map(ZmxSupport.scratchDaemonName(for:)))
        let unowned = records.filter { ZmxSupport.isScratchDaemonName($0.name) && !owned.contains($0.name) }
        for record in unowned where !runner.kill(record.name) {
            FileHandle.standardError.write(Data("agterm-server: could not end daemon \(record.name)\n".utf8))
        }
        let ended = Set(unowned.map(\.name))
        return records.filter { !ended.contains($0.name) }
    }

    /// forgetScratch drops a scratch whose daemon is gone on its own.
    func forgetScratch(_ identity: UUID) {
        scratches.remove(identity)
        startedAt[identity] = nil
    }

    /// agtermEnvironment is what a program started for `session` sees of this server: its identities, the state
    /// directory `agtermctl` resolves the socket from, and the shipped terminfo, which an ssh-started overlay
    /// helper would otherwise lack.
    func agtermEnvironment(session: UUID, workspace: UUID?, pane: StatusPane? = nil, paneToken: String? = nil) -> [String: String] {
        var environment = SurfaceEnvironment.session(sessionID: session, windowID: catalogID, workspaceID: workspace,
                                                     socketPath: configuration.socketPath, programVersion: programVersion,
                                                     pane: pane, paneToken: paneToken)
        environment["AGTERM_STATE_DIR"] = configuration.stateDirectory
        if let terminfo = terminfoDirectory { environment["TERMINFO"] = terminfo }
        return environment
    }

    /// terminfoDirectory is the shipped `xterm-ghostty` entry's directory, nil when the resources lack it.
    var terminfoDirectory: String? {
        let directory = (configuration.resourcesDirectory as NSString).appendingPathComponent("terminfo")
        return FileManager.default.fileExists(atPath: "\(directory)/x/\(TerminfoInstall.entry)") ? directory : nil
    }
}
