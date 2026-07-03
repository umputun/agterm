/// The direction of a clipboard access a terminal program requests over OSC 52: reading the system
/// clipboard into the terminal stream (exfiltration risk) or writing the terminal's data to it
/// (poisoning risk).
public enum ClipboardAccess: Sendable, Hashable {
    case read
    case write
}

/// What agterm should do with a clipboard access request.
public enum ClipboardDecision: Sendable {
    /// Perform it without asking (the user allowed it for the session, or the policy is permissive).
    case allow
    /// Refuse it silently (the user denied it for the session).
    case deny
    /// Ask the user with a dialog (no remembered choice yet).
    case prompt
}

/// ClipboardPromptPolicy remembers, per direction, whether the user has chosen to allow or deny OSC 52
/// clipboard access for the rest of the app session (the "don't ask again this session" choice). With no
/// remembered choice a direction defaults to `.prompt`. Read and write are independent so allowing writes
/// never silently allows reads. Pure value logic: the app owns an instance, shows the dialog on `.prompt`,
/// and records the outcome via `remember`.
public struct ClipboardPromptPolicy: Sendable {
    private var readChoice: Bool?
    private var writeChoice: Bool?

    public init() {}

    /// The decision for a direction: the remembered session choice, or `.prompt` when none is set.
    public func decision(for access: ClipboardAccess) -> ClipboardDecision {
        switch choice(for: access) {
        case .some(true): return .allow
        case .some(false): return .deny
        case .none: return .prompt
        }
    }

    /// Record the user's "don't ask again this session" choice for a direction.
    public mutating func remember(_ access: ClipboardAccess, allow: Bool) {
        switch access {
        case .read: readChoice = allow
        case .write: writeChoice = allow
        }
    }

    private func choice(for access: ClipboardAccess) -> Bool? {
        switch access {
        case .read: return readChoice
        case .write: return writeChoice
        }
    }
}
