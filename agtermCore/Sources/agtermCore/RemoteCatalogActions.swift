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
    public var tint: SidebarTint?
    /// wait holds the pane open after its command ends, as `--wait` does.
    public var wait: Bool

    public init(name: String? = nil, cwd: String? = nil, command: String? = nil, tint: SidebarTint? = nil, wait: Bool = false) {
        self.name = name
        self.cwd = cwd
        self.command = command
        self.tint = tint
        self.wait = wait
    }

    /// words carry each value joined to its flag, so a value starting with `-` is never read as an option.
    var words: [String] {
        [("--name", name), ("--cwd", cwd), ("--command", command)].compactMap { flag, value in value.map { flag + "=" + $0 } }
            + (tint?.creationWords ?? []) + (wait ? ["--wait"] : [])
    }
}

extension SidebarTint {
    /// creationWords are `session new`'s and `workspace new`'s tint flags.
    var creationWords: [String] { ["--tint=" + color.rawValue, "--tint-on=" + parts.map(\.rawValue).joined(separator: ",")] }
}

extension ControlTintUpdate {
    /// init is the update that leaves a row with `tint`, its parts spelled out.
    public init(_ tint: SidebarTint?) {
        self = tint.map { .set($0.color, parts: Set($0.parts)) } ?? .clear
    }

    /// words are `session tint`'s and `workspace tint`'s mode argument and placement.
    var words: [String] {
        switch self {
        case .clear: ["clear"]
        case .set(let color, let parts):
            [color.rawValue] + (parts.map { ["--on", TintPart.allCases.filter($0.contains).map(\.rawValue).joined(separator: ",")] } ?? [])
        }
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

extension RemoteSessionPlacement {
    /// words are `session move`'s placement flags; a workspace goes as an operand.
    var words: [String] {
        switch self {
        case .workspace: []
        case .after(let anchor): ["--after", anchor.uuidString]
        case .before(let anchor): ["--before", anchor.uuidString]
        case .step(let step): ["--to", step]
        }
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
    /// newSessionInNamedWorkspace lands in the server's workspace of that name, made when `create` is set.
    case newSessionInNamedWorkspace(name: String, create: Bool, shell: RemoteShellOptions = RemoteShellOptions())
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
    /// closeSession and closeSessions with `undoable` keep the close inside the server's grace, answering an undo id.
    case closeSession(UUID, undoable: Bool = false)
    /// closeSessions and moveSessions act on several rows as one server command.
    case closeSessions([UUID], undoable: Bool = false)
    case moveSessions([UUID], to: RemoteSessionPlacement)
    case setFlag(UUID, on: Bool)
    /// clearFlags unflags every session on the server, the rows this window detached included.
    case clearFlags
    case setTint(UUID, ControlTintUpdate)
    case setWorkspaceFlag(UUID, on: Bool)
    case setWorkspaceTint(UUID, ControlTintUpdate)
    /// newWorkspace starts collapsed on this Mac when `collapsed` is set; folds are each Mac's own.
    case newWorkspace(name: String?, collapsed: Bool = false, tint: SidebarTint? = nil)
    case renameWorkspace(UUID, name: String)
    case deleteWorkspace(UUID)
    case moveWorkspace(UUID, to: String)
    /// restart replaces one pane's shell on the server with one running `command`, or the pane's program again.
    case restart(UUID, pane: ZmxPaneRole, command: String?)
    case duplicateCompanion(UUID)
    case convertCompanion(UUID)
    /// moveCompanion puts companion `UUID` under `parent`; `index` counts the server's group, detached rows included.
    case moveCompanion(UUID, parent: UUID, index: Int?)
    /// killDaemon ends one pane's daemon on the server; `paneID` pins it to that pane, as `zmx.kill.pane` does.
    case killDaemon(UUID, pane: ZmxPaneRole, paneID: String? = nil)
    /// undoClose undoes the server's pending close `undoID` while its grace lasts.
    case undoClose(String)
    /// reopenRecent reopens the server's Recent Closed entry, the newest when nil.
    case reopenRecent(String?)

    public var label: String {
        switch self {
        case .newSession, .newSessionInNamedWorkspace: "New Session"
        case .newCompanion: "New Companion"
        case .newPage(_, let companion, _): companion ? "New Page Companion" : "New Page Session"
        case .setSplit(_, let shown, _): shown ? "Show Split" : "Hide Split"
        case .setScratch(_, let shown, _): shown ? "Show Scratch" : "Hide Scratch"
        case .closeSplit: "Close Split"
        case .swap: "Swap Panes"
        case .renameSession: "Rename Session"
        case .moveSession: "Move Session"
        case .closeSession: "Close Session"
        case .closeSessions: "Close Sessions"
        case .moveSessions: "Move Sessions"
        case .setFlag(_, let on): on ? "Flag Session" : "Unflag Session"
        case .clearFlags: "Clear Flagged"
        case .setTint: "Tint Session"
        case .setWorkspaceFlag(_, let on): on ? "Flag All Sessions" : "Unflag All Sessions"
        case .setWorkspaceTint: "Tint Workspace"
        case .newWorkspace: "New Workspace"
        case .renameWorkspace: "Rename Workspace"
        case .deleteWorkspace: "Delete Workspace"
        case .moveWorkspace: "Move Workspace"
        case .restart: "Restart Pane"
        case .duplicateCompanion: "Duplicate as Companion"
        case .convertCompanion: "Convert to Companion"
        case .moveCompanion: "Move Companion"
        case .killDaemon: "Kill Daemon"
        case .undoClose: "Reopen Closed Item"
        case .reopenRecent: "Reopen Last Closed Item"
        }
    }

    public var target: RemoteOperationTarget? {
        switch self {
        case .newSession(let workspace, _, _): .workspace(workspace)
        case .newCompanion(let id, _), .newPage(let id, _, _), .setSplit(let id, _, _), .setScratch(let id, _, _), .closeSplit(let id), .swap(let id),
             .renameSession(let id, _), .moveSession(let id, _), .closeSession(let id, _), .setFlag(let id, _), .setTint(let id, _), .restart(let id, _, _),
             .duplicateCompanion(let id), .convertCompanion(let id), .moveCompanion(let id, _, _), .killDaemon(let id, _, _): .session(id)
        // a batch is marked on its first row
        case .closeSessions(let ids, _), .moveSessions(let ids, _): ids.first.map { .session($0) }
        case .newWorkspace, .newSessionInNamedWorkspace, .clearFlags, .undoClose, .reopenRecent: nil
        case .renameWorkspace(let id, _), .deleteWorkspace(let id), .moveWorkspace(let id, _), .setWorkspaceFlag(let id, _),
             .setWorkspaceTint(let id, _): .workspace(id)
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
        case .setSplit, .closeSplit, .swap, .restart, .killDaemon: true
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
        case .newSessionInNamedWorkspace(let name, let create, let shell):
            ["session", "new", "--workspace-name=" + name] + (create ? ["--create-workspace"] : []) + shell.words
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
        case .moveSession(let id, let placement): ["session", "move", "--target", id.uuidString] + placement.words
        case .moveSessions(let ids, let placement): ["session", "move"] + ids.flatMap { ["--target", $0.uuidString] } + placement.words
        case .closeSession(let id, let undoable): ["session", "close", "--target", id.uuidString] + (undoable ? ["--undoable"] : [])
        case .closeSessions(let ids, let undoable):
            ["session", "close"] + ids.flatMap { ["--target", $0.uuidString] } + (undoable ? ["--undoable"] : [])
        case .undoClose(let id): ["session", "undo", "--target", id]
        case .reopenRecent: ["recent", "open"]
        case .setFlag(let id, let on): ["session", "flag", on ? "on" : "off", "--target", id.uuidString]
        case .clearFlags: ["session", "flag", "clear"]
        case .setTint(let id, let update): ["session", "tint"] + update.words + ["--target", id.uuidString]
        case .setWorkspaceFlag(let id, let on): ["workspace", "flag", on ? "on" : "off", "--target", id.uuidString]
        case .setWorkspaceTint(let id, let update): ["workspace", "tint"] + update.words + ["--target", id.uuidString]
        case .newWorkspace(_, let collapsed, let tint): ["workspace", "new"] + (collapsed ? ["--collapsed"] : []) + (tint?.creationWords ?? [])
        case .renameWorkspace(let id, _): ["workspace", "rename", "--target", id.uuidString]
        case .deleteWorkspace(let id): ["workspace", "delete", "--target", id.uuidString]
        case .moveWorkspace(let id, let step): ["workspace", "move", "--target", id.uuidString, "--to", step]
        case .restart(let id, let pane, let command):
            ["session", "restart", "--target", id.uuidString, "--pane", pane.rawValue] + (command.map { ["--command=" + $0] } ?? [])
        case .duplicateCompanion(let id): ["session", "duplicate", "--companion", "--target", id.uuidString]
        case .convertCompanion(let id): ["session", "convert", "--companion", "--target", id.uuidString]
        case .moveCompanion(let id, let parent, let index):
            ["session", "move", "--target", id.uuidString, "--parent", parent.uuidString] + (index.map { ["--index", String($0)] } ?? [])
        case .killDaemon(let id, let pane, let paneID):
            ["zmx", "kill", "--target", id.uuidString, "--pane", pane.rawValue] + (paneID.map { ["--pane-id", $0] } ?? []) + ["--force"]
        }
    }

    var operands: [String] {
        switch self {
        case .renameSession(_, let name), .renameWorkspace(_, let name): [name]
        case .newWorkspace(let name, _, _): name.map { [$0] } ?? []
        case .moveSession(_, .workspace(let workspace)), .moveSessions(_, .workspace(let workspace)): [workspace.uuidString]
        case .reopenRecent(let id?): [id]
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
        /// refusedArguments is the far `agtermctl` rejecting its command line, so nothing reached the server.
        case refusedArguments
        case reply(ControlResponse)
    }

    /// mirror is the window's catalog, which detach and the Detached Sessions picker act on.
    @ObservationIgnored public let mirror: RemoteCatalogMirror
    @ObservationIgnored private let runner: RemoteCatalogClient.Runner
    @ObservationIgnored private let pool: SshConnectionPool?
    private var entries: [String: Entry] = [:] {
        didSet { onChange?() }
    }
    /// recentItems is the server's Recent Closed list from its catalog, nil from a server that keeps none.
    public private(set) var recentItems: [ControlRecentItem]?
    /// undoIDs are the undoable closes this Mac sent whose grace can still be running on the server, oldest first;
    /// each leaves by itself when its grace ends, so a menu reading the list updates with nothing else happening.
    public private(set) var undoIDs: [String] = []
    @ObservationIgnored var undoGrace: TimeInterval = AppStore.pendingCloseGraceInterval
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
            switch (session.panes.isEmpty, operation) {
            // an ended row has no pane to pin, and restart is what brings its shell back
            case (true, .restart): break
            case (true, _): return .refused(ControlResponse(ok: false, error: "the session has ended on \(host)"))
            case (false, _): panes = session.panes.map(\.identity)
            }
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
        let outcome = await run(words + ["--op-id", opID, "--epoch", prepared.sent.epoch], operands: operation.operands)
        if case .moveCompanion = operation, Self.tooOldForCompanionMoves(outcome) {
            entries[opID] = nil
            return ControlResponse(ok: false, error: "the agterm-server on \(host) is too old for companion moves")
        }
        switch outcome {
        case .notSent:
            entries[opID] = nil
            return ControlResponse(ok: false, error: "no connection to \(host)")
        case .reply(let reply) where reply.result?.receipt?.opID == opID:
            settle(opID, reply.result?.receipt)
            if selectingCreated, reply.ok, let id = reply.result?.id.flatMap(UUID.init(uuidString:)) {
                mirror.selectWhenShown(id, from: prepared.selection)
            }
            if case .newWorkspace(_, true, _) = operation, reply.ok, let id = reply.result?.id.flatMap(UUID.init(uuidString:)) {
                mirror.collapseWhenShown(id)
            }
            if reply.ok, reply.result?.undoable == true, let undoID = reply.result?.undoID { noteUndo(undoID) }
            return reply
        case .reply, .lost, .refusedArguments:
            settle(opID, nil)
            return ControlResponse(ok: false, error: "\(host) did not answer \(operation.label); its outcome is unknown until \(host) can be asked")
        }
    }

    /// takeUndo removes and answers the newest undo id whose grace can still be running on the server.
    public func takeUndo() -> String? {
        undoIDs.popLast()
    }

    private func noteUndo(_ undoID: String) {
        undoIDs = Array((undoIDs + [undoID]).suffix(Self.undoDepth))
        Task { @MainActor [weak self, grace = undoGrace] in
            try? await Task.sleep(for: .seconds(grace))
            self?.undoIDs.removeAll { $0 == undoID }
        }
    }

    /// request sends a command that changes no catalog row, a Recent Closed read or clear, and answers the server's
    /// reply. It carries no operation id: repeating it after a lost reply is harmless.
    public func request(_ words: [String]) async -> ControlResponse {
        switch await run(words, operands: []) {
        case .notSent: return ControlResponse(ok: false, error: "no connection to \(host)")
        case .lost, .refusedArguments: return ControlResponse(ok: false, error: "\(host) did not answer")
        case .reply(let reply): return reply
        }
    }

    private static let undoDepth = 20

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
        if recentItems != catalog.recent { recentItems = catalog.recent }
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

    // an older CLI refuses `--parent`, a newer CLI's request is refused by an older running server: either way
    // nothing ran there, unlike any other lost reply
    private static func tooOldForCompanionMoves(_ outcome: Outcome) -> Bool {
        switch outcome {
        case .refusedArguments: true
        case .reply(let reply): reply.refusesUnknown(.sessionCompanionMove)
        case .notSent, .lost: false
        }
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
        if result.status == 64, result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .refusedArguments }
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
