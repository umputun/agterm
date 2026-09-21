import Foundation

/// Which client of a pane's zmx daemon owns the pty size. Only the leader's grid is applied, so every
/// other client draws output laid out for a grid it does not have. `scripts/zmx-patches/README.md`
/// describes the daemon side.
public enum ZmxLeadRole: String, Codable, Sendable, Equatable, CaseIterable {
    /// No client leads; the pty keeps its last size until one attaches.
    case unowned
    case leader
    case follower
}

/// One attachment of a pane to its daemon: the token its zmx client echoes in every role report, and
/// whether it asked for the lead.
public struct ZmxLeadAttachment: Equatable, Sendable {
    /// Read by the zmx client, which opts into explicit leadership when it is set.
    public static let nonceVariable = "ZMX_MANAGED"
    public static let claimVariable = "ZMX_MANAGED_CLAIM"

    public let nonce: String
    /// False for the automatic re-attach after the leader left: that one leads only if the session is
    /// still unowned when it arrives, so it cannot take a lead someone claimed in the meantime.
    public let claim: Bool

    public init(nonce: String = ZmxLeadAttachment.makeNonce(), claim: Bool) {
        self.nonce = nonce
        self.claim = claim
    }

    public static func makeNonce() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    public var environment: [String: String] {
        var environment = [Self.nonceVariable: nonce]
        if claim { environment[Self.claimVariable] = "1" }
        return environment
    }

    /// The same variables as `NAME=value` words for an `env` command line on another machine.
    public var assignments: [String] {
        environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }
}

/// A role report from a pane's zmx client, carried as a terminal title with a reserved prefix. A title
/// because libghostty delivers every one; it drops a desktop notification that follows another within
/// a second, app-wide, and a lost report leaves the app wrong about a role the daemon enforces.
public struct ZmxLeadNotice: Equatable, Sendable {
    public static let prefix = "zmx-role;"

    public let nonce: String
    public let role: ZmxLeadRole
    /// Counts the daemon's leadership changes, so a report that arrives late can be told from a newer one.
    public let generation: UInt32

    /// Nil for any other title, and for one that is not `zmx-role;<nonce>:<role>:<generation>`.
    public init?(title: String) {
        guard title.hasPrefix(Self.prefix) else { return nil }
        let fields = title.dropFirst(Self.prefix.count).split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 3, !fields[0].isEmpty, let role = ZmxLeadRole(rawValue: String(fields[1])),
              let generation = UInt32(fields[2]) else { return nil }
        self.nonce = String(fields[0])
        self.role = role
        self.generation = generation
    }
}

/// What one pane knows about its lead, fed by the reports of its current attachment only.
public struct ZmxLeadState: Equatable, Sendable {
    public private(set) var attachment: ZmxLeadAttachment
    /// Nil until the first report: a daemon or zmx client without explicit leadership never sends one,
    /// and such a pane behaves as it did before.
    public private(set) var role: ZmxLeadRole?
    /// True from a fresh attach that replaced a covered surface until its first report, so the cover
    /// stays up over a terminal that has nothing to show yet.
    public private(set) var reattaching: Bool
    private var generation: UInt32 = 0

    public init(attachment: ZmxLeadAttachment, reattaching: Bool = false) {
        self.attachment = attachment
        self.reattaching = reattaching
    }

    /// True when the pane draws output laid out for another client's grid, or nothing yet, and must be
    /// covered.
    public var covered: Bool { reattaching || role == .follower || role == .unowned }

    /// Applies `notice` and says whether the role changed. A report for another attachment's nonce is
    /// forged or left over from a surface this pane replaced; an older generation lost a race.
    public mutating func apply(_ notice: ZmxLeadNotice) -> Bool {
        guard notice.nonce == attachment.nonce else { return false }
        guard role == nil || notice.generation >= generation else { return false }
        generation = notice.generation
        // a re-attach starts with no role, so its first report always changes it
        guard role != notice.role else { return false }
        reattaching = false
        role = notice.role
        return true
    }
}

/// The reply of `zmx screen`: a line of six numbers, then the text of the daemon's own terminal.
public struct ZmxScreen: Equatable, Sendable {
    public let revision: UInt64
    public let columns: Int
    public let rows: Int
    /// Zero-based, in the active screen.
    public let cursorColumn: Int
    public let cursorRow: Int
    public let alternate: Bool
    public let text: String

    public init?(output: String) {
        let parts = output.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let header = parts.first else { return nil }
        let fields = header.split(separator: " ").map { UInt64($0) }
        guard fields.count == 6, !fields.contains(nil) else { return nil }
        let numbers = fields.compactMap { $0 }
        revision = numbers[0]
        columns = Int(numbers[1])
        rows = Int(numbers[2])
        cursorColumn = Int(numbers[3])
        cursorRow = Int(numbers[4])
        alternate = numbers[5] != 0
        text = parts.count > 1 ? String(parts[1]) : ""
    }

    /// The last `count` content lines, trailing blank rows dropped first, matching what a pane's own
    /// surface returns for the same request.
    public func lastLines(_ count: Int) -> String {
        var rows = text.components(separatedBy: "\n")
        while let last = rows.last, last.allSatisfy(\.isWhitespace) { rows.removeLast() }
        return rows.suffix(count).joined(separator: "\n")
    }
}

/// Every pane's lead state, keyed by pane identity so it follows a pane through a swap or a promoted
/// split. One book for the app: pane identities are unique across windows.
@Observable
@MainActor
public final class ZmxLeadBook {
    public static let shared = ZmxLeadBook()

    public private(set) var states: [UUID: ZmxLeadState] = [:]
    /// Counts attachments begun. A pane's surface slot is not observed, so a view hosting one reads this
    /// to learn that a fresh attach replaced the surface.
    public private(set) var attachments = 0

    public init() {}

    /// Starts over for `pane`: reports of its previous attachment no longer match and are dropped.
    public func begin(_ attachment: ZmxLeadAttachment, pane: UUID, reattaching: Bool = false) {
        states[pane] = ZmxLeadState(attachment: attachment, reattaching: reattaching)
        attachments &+= 1
    }

    /// The role `notice` moved `pane` to, nil when it changed nothing.
    public func apply(_ notice: ZmxLeadNotice, pane: UUID) -> ZmxLeadRole? {
        guard var state = states[pane], state.apply(notice) else { return nil }
        states[pane] = state
        return state.role
    }

    public func role(pane: UUID?) -> ZmxLeadRole? { pane.flatMap { states[$0]?.role } }

    public func covered(pane: UUID?) -> Bool { pane.flatMap { states[$0]?.covered } ?? false }

    public func reattaching(pane: UUID?) -> Bool { pane.flatMap { states[$0]?.reattaching } ?? false }

    public func forget(pane: UUID) { states[pane] = nil }
}

extension Session {
    /// The identity of the pane behind a surface slot, nil for the ephemeral ones, which have no daemon.
    public func paneIdentity(for surface: TerminalZoomSurface) -> UUID? {
        switch surface {
        case .primary: paneIdentity
        case .split: splitPaneIdentity
        default: nil
        }
    }

    public func paneIdentity(for pane: StatusPane) -> UUID? {
        switch pane {
        case .left: paneIdentity
        case .right: splitPaneIdentity
        case .scratch: nil
        }
    }
}

extension AppStore {
    /// A pane's `lead` read-back changed.
    public func leadRoleChanged() { scheduleTreeChanged() }
}
