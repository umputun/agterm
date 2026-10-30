import Foundation

/// MessageAddress is a message bus `SESSION:PANE` address. A recipient may name the pane by role, resolved
/// once at send time; an identity must name the pane id, since a swap re-points every role.
public struct MessageAddress: Equatable, Sendable {
    public enum Pane: Equatable, Sendable {
        case id(UUID)
        case role(StatusPane)
    }

    public let session: String
    public let pane: Pane

    public init(session: String, pane: Pane) {
        self.session = session
        self.pane = pane
    }

    /// recipient parses an address a message is sent to: a pane id or a role.
    public static func recipient(_ text: String) throws(MessageAddressError) -> MessageAddress {
        try parse(text)
    }

    /// identity parses the address a caller acts as; a role is refused.
    public static func identity(_ text: String) throws(MessageAddressError) -> MessageAddress {
        let address = try parse(text)
        guard case .id = address.pane else { throw .roleIdentity(text) }
        return address
    }

    /// canonical is the address a resolved pane is reported under.
    public static func canonical(session: UUID, pane: UUID) -> String {
        "\(session.uuidString):\(pane.uuidString)"
    }

    private static func parse(_ text: String) throws(MessageAddressError) -> MessageAddress {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 1, !text.isEmpty { throw .bareSession(text) }
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { throw .malformed(text) }
        if let id = UUID(uuidString: parts[1]) { return MessageAddress(session: parts[0], pane: .id(id)) }
        guard let role = StatusPane(controlName: parts[1]) else { throw .malformed(text) }
        return MessageAddress(session: parts[0], pane: .role(role))
    }
}

/// MessageAddressError names the address text it refused.
public enum MessageAddressError: Error, Equatable, Sendable {
    case malformed(String)
    case bareSession(String)
    case roleIdentity(String)

    public var message: String {
        switch self {
        case .malformed(let text): "invalid address \"\(text)\": expected SESSION:PANE"
        case .bareSession(let text): "address \"\(text)\" names a session, not a pane"
        case .roleIdentity(let text): "identity \"\(text)\" must name a pane id, not a role"
        }
    }
}
