import Foundation
import Observation

/// RemoteSessionPlacement is where `RemoteOperation.moveSession` puts a session: another workspace, beside an
/// anchor session, or one step within its own workspace (`up`, `down`, `top`, `bottom`).
public enum RemoteSessionPlacement: Equatable, Sendable {
    case workspace(UUID)
    case after(UUID)
    case before(UUID)
    case step(String)
}

/// RemoteShellOptions are what a new session or companion starts with on the server; nil leaves the server's default.
public struct RemoteShellOptions: Equatable, Sendable {
    public var name: String?
    public var cwd: String?
    public var command: String?

    public init(name: String? = nil, cwd: String? = nil, command: String? = nil) {
        self.name = name
        self.cwd = cwd
        self.command = command
    }

    /// words carry each value joined to its flag, so a value starting with `-` is never read as an option.
    var words: [String] {
        [("--name", name), ("--cwd", cwd), ("--command", command)].compactMap { flag, value in value.map { flag + "=" + $0 } }
    }
}

/// RemotePageOptions are the page a new page row on the server shows: a file there or a URL, and its page flags.
public struct RemotePageOptions: Equatable, Sendable {
    let source: HtmlSource
    let options: ControlSessionOverlayOpenOptions

    init?(_ options: ControlSessionOverlayOpenOptions) {
        guard let source = options.page else { return nil }
        self.source = source
        self.options = options
    }

    /// words carry each value joined to its flag, so a value starting with `-` is never read as an option.
    var words: [String] {
        let page: [String] = switch source {
        case .file(let path, let grant): ["--html=" + path] + (grant.map { ["--cwd=" + $0] } ?? [])
        case .url(let url): ["--url=" + url.absoluteString]
        default: []
        }
        let flags = [(options.navigation, "--navigation"), (options.javascript, "--js"), (options.chromeless, "--chromeless"),
                     (options.persistent, "--persistent"), (options.browse, "--browse")].filter(\.0).map(\.1)
        return page + flags + (options.backgroundColor.map { ["--background-color=" + $0] } ?? [])
    }
}

/// RemoteOperationTarget is the row an operation acts on, which its pending or unknown mark is shown with.
public enum RemoteOperationTarget: Equatable, Hashable, Sendable {
    case session(UUID)
    case workspace(UUID)
}

/// RemoteOperation is one structural action a remote window asks its server to make.
public enum RemoteOperation: Equatable, Sendable {
    /// newSession lands in `workspace`, beside `anchor` when it is `.after` or `.before`.
    case newSession(workspace: UUID, anchor: RemoteSessionPlacement? = nil, shell: RemoteShellOptions = RemoteShellOptions())
    case newCompanion(parent: UUID, shell: RemoteShellOptions = RemoteShellOptions())
    /// newPage is a page row: a page companion of `anchor`, or a top-level page session after its group.
    case newPage(anchor: UUID, companion: Bool, page: RemotePageOptions)
    case setSplit(UUID, shown: Bool, axis: String?)
    /// setScratch shows or hides the server's scratch; a command replaces the one there is with a scratch running it.
    case setScratch(UUID, shown: Bool, command: String? = nil)
    case closeSplit(UUID)
    case swap(UUID)
    case renameSession(UUID, name: String)
    case moveSession(UUID, to: RemoteSessionPlacement)
    case closeSession(UUID)
    case newWorkspace(name: String?)
    case renameWorkspace(UUID, name: String)
    case deleteWorkspace(UUID)
    case moveWorkspace(UUID, to: String)

    public var label: String {
        switch self {
        case .newSession: "New Session"
        case .newCompanion: "New Companion"
        case .newPage(_, let companion, _): companion ? "New Page Companion" : "New Page Session"
        case .setSplit(_, let shown, _): shown ? "Show Split" : "Hide Split"
        case .setScratch(_, let shown, _): shown ? "Show Scratch" : "Hide Scratch"
        case .closeSplit: "Close Split"
        case .swap: "Swap Panes"
        case .renameSession: "Rename Session"
        case .moveSession: "Move Session"
        case .closeSession: "Close Session"
        case .newWorkspace: "New Workspace"
        case .renameWorkspace: "Rename Workspace"
        case .deleteWorkspace: "Delete Workspace"
        case .moveWorkspace: "Move Workspace"
        }
    }

    public var target: RemoteOperationTarget? {
        switch self {
        case .newSession(let workspace, _, _): .workspace(workspace)
        case .newCompanion(let id, _), .newPage(let id, _, _), .setSplit(let id, _, _), .setScratch(let id, _, _), .closeSplit(let id), .swap(let id),
             .renameSession(let id, _), .moveSession(let id, _), .closeSession(let id): .session(id)
        case .newWorkspace: nil
        case .renameWorkspace(let id, _), .deleteWorkspace(let id), .moveWorkspace(let id, _): .workspace(id)
        }
    }

    /// replacesScratch is whether the operation ends the scratch the window saw, which the server must still have.
    var replacesScratch: Bool {
        if case .setScratch(_, true, let command?) = self { return !command.isEmpty }
        return false
    }

    /// pinsPanes is whether the server must find the session's panes as the window saw them.
    var pinsPanes: Bool {
        switch self {
        case .setSplit, .closeSplit, .swap: true
        default: false
        }
    }

    /// key groups the repeats a pending operation holds back: the same action on the same row.
    var key: String {
        let row = switch target {
        case .session(let id)?, .workspace(let id)?: id.uuidString
        case nil: ""
        }
        return label + ":" + row
    }

    /// words are the far side's `agtermctl` arguments; operands follow a `--` so a name starting with `-` stays a name.
    var words: [String] {
        switch self {
        case .newSession(let workspace, let anchor, let shell):
            ["session", "new"] + {
                switch anchor {
                case .after(let id)?: ["--after", id.uuidString]
                case .before(let id)?: ["--before", id.uuidString]
                default: ["--workspace", workspace.uuidString]
                }
            }() + shell.words
        case .newCompanion(let parent, let shell): ["session", "new", "--parent", parent.uuidString] + shell.words
        case .newPage(let anchor, let companion, let page):
            ["session", "overlay", "open", companion ? "--companion" : "--page", "--target", anchor.uuidString] + page.words
        case .setSplit(let id, let shown, let axis):
            ["session", "split", "visibility", shown ? "on" : "off", "--target", id.uuidString] + (axis.map { ["--axis", $0] } ?? [])
        case .setScratch(let id, let shown, let command):
            ["session", "scratch", shown ? "on" : "off", "--target", id.uuidString] + (command.map { ["--command=" + $0] } ?? [])
        case .closeSplit(let id): ["session", "split", "close", "--target", id.uuidString]
        case .swap(let id): ["session", "swap", "--target", id.uuidString]
        case .renameSession(let id, _): ["session", "rename", "--target", id.uuidString]
        case .moveSession(let id, let placement):
            ["session", "move", "--target", id.uuidString] + {
                switch placement {
                case .workspace: []
                case .after(let anchor): ["--after", anchor.uuidString]
                case .before(let anchor): ["--before", anchor.uuidString]
                case .step(let step): ["--to", step]
                }
            }()
        case .closeSession(let id): ["session", "close", "--target", id.uuidString]
        case .newWorkspace: ["workspace", "new"]
        case .renameWorkspace(let id, _): ["workspace", "rename", "--target", id.uuidString]
        case .deleteWorkspace(let id): ["workspace", "delete", "--target", id.uuidString]
        case .moveWorkspace(let id, let step): ["workspace", "move", "--target", id.uuidString, "--to", step]
        }
    }

    var operands: [String] {
        switch self {
        case .renameSession(_, let name), .renameWorkspace(_, let name): [name]
        case .newWorkspace(let name): name.map { [$0] } ?? []
        case .moveSession(_, .workspace(let workspace)): [workspace.uuidString]
        default: []
        }
    }
}

/// PreparedRemoteOperation is an operation with what it was decided on: the catalog position and, for a pane action,
/// the session's panes as the window showed them, so a change arriving before it is sent cannot retarget it.
public struct PreparedRemoteOperation: Equatable, Sendable {
    public let operation: RemoteOperation
    let sent: CatalogPosition
    let panes: [UUID]?
    /// scratch is the session's scratch identity, or `none`, when the operation replaces it.
    let scratch: String?
    /// selection is the window's selected row when the operation was asked for.
    let selection: UUID?
}

/// RemotePreparation is `RemoteCatalogActions.prepare`'s answer: an operation ready to send, or the refusal to report.
public enum RemotePreparation: Equatable, Sendable {
    case ready(PreparedRemoteOperation)
    case refused(ControlResponse)
}

/// RemoteOperationMark is an operation a remote window shows on its row: still pending, or with an outcome this
/// Mac could not learn.
public struct RemoteOperationMark: Equatable, Sendable {
    public let opID: String
    public let label: String
    public let target: RemoteOperationTarget?
    public let unknown: Bool
}

/// RemoteCatalogActions sends a remote window's structural actions to its server, each under an operation id, and
/// keeps every one marked until its receipt settles: applied once the mirror reaches the receipt's revision, gone at
/// once for no change, a refusal or a fence. A reply this Mac never got is settled only by `catalog op`, never by
/// what a snapshot shows; one the server itself cannot answer stays unknown until the user dismisses it or its row
/// goes.
@MainActor
@Observable
public final class RemoteCatalogActions {
    private struct Entry {
        enum State: Equatable {
            case sending
            case awaiting(CatalogPosition)
            case lookup
            case unknown
        }

        let opID: String
        let operation: RemoteOperation
        let sent: CatalogPosition
        let order: Int
        var state: State

        var holdsRepeat: Bool {
            switch state {
            case .sending, .awaiting: true
            case .lookup, .unknown: false
            }
        }
    }

    private enum Outcome {
        case notSent
        case lost
        case reply(ControlResponse)
    }

    /// mirror is the window's catalog, which detach and the Detached Sessions picker act on.
    @ObservationIgnored public let mirror: RemoteCatalogMirror
    @ObservationIgnored private let runner: RemoteCatalogClient.Runner
    @ObservationIgnored private let pool: SshConnectionPool?
    private var entries: [String: Entry] = [:] {
        didSet { onChange?() }
    }
    /// onChange runs after every change to the operations this window tracks, for read-back that caches them.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?
    @ObservationIgnored private var nextOrder = 0
    @ObservationIgnored private var stopped = false
    @ObservationIgnored var lookupTask: Task<Void, Never>?
    @ObservationIgnored private var lookupAgain = false
    @ObservationIgnored private var lookupRound = false

    public init(mirror: RemoteCatalogMirror, runner: @escaping RemoteCatalogClient.Runner, pool: SshConnectionPool? = nil) {
        self.mirror = mirror
        self.runner = runner
        self.pool = pool
        mirror.onCatalogMoved = { [weak self] snapshot in self?.catalogMoved(snapshot: snapshot) }
    }

    private var host: String { mirror.host }

    /// marks lists every operation still pending or unknown, oldest first.
    public var marks: [RemoteOperationMark] {
        entries.values.sorted { $0.order < $1.order }.map {
            RemoteOperationMark(opID: $0.opID, label: $0.operation.label, target: $0.operation.target,
                                unknown: $0.state == .lookup || $0.state == .unknown)
        }
    }

    /// pendingState is row `id`'s read-back: `unknown` when one of its operations' outcome was lost, `pending` while
    /// one is still on its way, nil otherwise.
    public func pendingState(of id: UUID) -> String? {
        let row = marks(for: .session(id))
        if row.contains(where: \.unknown) { return "unknown" }
        return row.isEmpty ? nil : "pending"
    }

    /// unknownCount is how many operations have an outcome this Mac could not learn.
    public var unknownCount: Int { marks.filter(\.unknown).count }

    public func marks(for target: RemoteOperationTarget) -> [RemoteOperationMark] {
        marks.filter { $0.target == target }
    }

    /// prepare captures what `operation` is decided on, at the moment the user or the caller asked for it. It is refused
    /// while the window is not connected.
    public func prepare(_ operation: RemoteOperation) -> RemotePreparation {
        guard !stopped, mirror.state == .connected, let catalog = mirror.catalog else {
            return .refused(ControlResponse(ok: false, error: "\(host) is not connected"))
        }
        var panes: [UUID]?
        if operation.pinsPanes, case .session(let id)? = operation.target {
            guard let session = catalog.session(id) else { return .refused(ControlResponse(ok: false, error: "no such session on \(host)")) }
            guard !session.panes.isEmpty else {
                return .refused(ControlResponse(ok: false, error: "the session has ended on \(host)"))
            }
            panes = session.panes.map(\.identity)
        }
        var scratch: String?
        if operation.replacesScratch, case .session(let id)? = operation.target {
            guard let session = catalog.session(id) else { return .refused(ControlResponse(ok: false, error: "no such session on \(host)")) }
            scratch = session.fields.scratch?.pane.identity.uuidString ?? "none"
        }
        return .ready(PreparedRemoteOperation(operation: operation, sent: CatalogPosition(epoch: catalog.epoch, rev: catalog.rev),
                                              panes: panes, scratch: scratch, selection: mirror.selectedSessionID))
    }

    /// send runs a prepared operation on the server and answers with the server's reply, the created ids and errors
    /// included. It is refused, sending nothing, while the window is not connected or the same action on the same row
    /// is still pending. `selectingCreated` selects the row it created once the window shows it, unless the selection
    /// moved after the operation was asked for.
    public func send(_ prepared: PreparedRemoteOperation, selectingCreated: Bool = false) async -> ControlResponse {
        let operation = prepared.operation
        guard !stopped, mirror.state == .connected else { return ControlResponse(ok: false, error: "\(host) is not connected") }
        if entries.values.contains(where: { $0.operation.key == operation.key && $0.holdsRepeat }) {
            return ControlResponse(ok: false, error: "\(operation.label) is still pending on \(host)")
        }
        var words = operation.words
        if let panes = prepared.panes { words += ["--expect-panes", panes.map(\.uuidString).joined(separator: ",")] }
        if let scratch = prepared.scratch { words += ["--expect-scratch", scratch] }
        let opID = UUID().uuidString
        nextOrder += 1
        entries[opID] = Entry(opID: opID, operation: operation, sent: prepared.sent, order: nextOrder, state: .sending)
        switch await run(words + ["--op-id", opID, "--epoch", prepared.sent.epoch], operands: operation.operands) {
        case .notSent:
            entries[opID] = nil
            return ControlResponse(ok: false, error: "no connection to \(host)")
        case .reply(let reply) where reply.result?.receipt?.opID == opID:
            settle(opID, reply.result?.receipt)
            if selectingCreated, reply.ok, let id = reply.result?.id.flatMap(UUID.init(uuidString:)) {
                mirror.selectWhenShown(id, from: prepared.selection)
            }
            return reply
        case .reply, .lost:
            settle(opID, nil)
            return ControlResponse(ok: false, error: "\(host) did not answer \(operation.label); its outcome is unknown until \(host) can be asked")
        }
    }

    /// dismissUnknown drops every mark whose outcome this Mac could not learn.
    public func dismissUnknown() {
        entries = entries.filter { !($0.value.state == .lookup || $0.value.state == .unknown) }
    }

    /// stop ends every lookup; the window is closing.
    public func stop() {
        stopped = true
        lookupTask?.cancel()
        lookupTask = nil
    }

    // MARK: settling

    private func settle(_ opID: String, _ receipt: CatalogReceipt?) {
        guard var entry = entries[opID] else { return }
        guard let receipt else {
            entry.state = .lookup
            entries[opID] = entry
            startLookups()
            return
        }
        switch receipt.outcome {
        case .noop, .refused, .fenced:
            entries[opID] = nil
        case .unknown:
            entry.state = .unknown
            entries[opID] = entry
        case .applied:
            // a marker answered before its command finished carries no revision; ask again later
            guard let rev = receipt.rev else { return settle(opID, nil) }
            let target = CatalogPosition(epoch: receipt.epoch, rev: rev)
            guard let catalog = mirror.catalog else { return }
            if catalog.epoch == target.epoch {
                if catalog.rev >= rev { entries[opID] = nil } else { entry.state = .awaiting(target); entries[opID] = entry }
            } else if target.epoch == entry.sent.epoch {
                // the mirror has already left the epoch this receipt belongs to, and that epoch never returns
                settle(opID, nil)
            } else {
                entry.state = .awaiting(target)
                entries[opID] = entry
            }
        }
    }

    /// catalogMoved settles what the mirror's new revision answers. A new snapshot also asks about every reply this
    /// Mac lost, and sends a receipt of an epoch the mirror is not in to a lookup.
    func catalogMoved(snapshot: Bool) {
        guard let catalog = mirror.catalog else { return }
        for (opID, entry) in entries {
            switch entry.state {
            case .awaiting(let target) where target.epoch == catalog.epoch:
                if catalog.rev >= target.rev { entries[opID] = nil }
            case .awaiting:
                if snapshot { entries[opID]?.state = .lookup }
            case .lookup, .unknown:
                if let target = entry.operation.target, !catalog.contains(target) { entries[opID] = nil }
            case .sending:
                break
            }
        }
        if snapshot { startLookups(round: true) }
    }

    /// startLookups asks about every lost reply once per round. A reply lost while a batch runs joins it; a `round`
    /// (a new snapshot) asks about every one again after it, so a lookup that failed is retried only then.
    private func startLookups(round: Bool = false) {
        guard !stopped, mirror.state == .connected, entries.values.contains(where: { $0.state == .lookup }) else { return }
        guard lookupTask == nil else {
            lookupAgain = true
            lookupRound = lookupRound || round
            return
        }
        lookupTask = Task { @MainActor [weak self] in
            var asked: Set<String> = []
            repeat {
                if self?.lookupRound == true { asked = [] }
                self?.lookupAgain = false
                self?.lookupRound = false
                asked.formUnion(await self?.runLookups(skipping: asked) ?? [])
            } while self?.lookupAgain == true
            self?.lookupTask = nil
        }
    }

    /// runLookups asks once about every lost reply not in `skipping` and answers which it asked about.
    private func runLookups(skipping: Set<String>) async -> Set<String> {
        let waiting = entries.values.filter { $0.state == .lookup && !skipping.contains($0.opID) }.sorted { $0.order < $1.order }
        var asked: Set<String> = []
        for entry in waiting {
            guard !stopped, !Task.isCancelled, mirror.state == .connected else { return asked }
            asked.insert(entry.opID)
            let words = ["catalog", "op", entry.opID, "--epoch", entry.sent.epoch, "--rev", String(entry.sent.rev)]
            guard case .reply(let reply) = await run(words, operands: []), let receipt = reply.result?.receipt,
                  receipt.opID == entry.opID, entries[entry.opID]?.state == .lookup else { continue }
            settle(entry.opID, receipt)
        }
        return asked
    }

    // MARK: transport

    private func run(_ words: [String], operands: [String]) async -> Outcome {
        let slot = pool?.leaseOnce()
        defer { slot.map { pool?.release($0.user) } }
        if let pool, let slot, !(await pool.ready(slot.path)) { return .notSent }
        guard let argv = try? RemoteSession.controlCommand(host: host, arguments: words, operands: operands, controlPath: slot?.path) else {
            return .notSent
        }
        let result = await runner(argv)
        guard let reply = try? JSONDecoder().decode(ControlResponse.self, from: Data(result.stdout.utf8)) else { return .lost }
        return .reply(reply)
    }
}

private extension CatalogSnapshot {
    func contains(_ target: RemoteOperationTarget) -> Bool {
        switch target {
        case .session(let id): session(id) != nil
        case .workspace(let id): workspaces.contains { $0.id == id }
        }
    }
}
