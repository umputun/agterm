import Foundation

/// Host-free custom-command matcher: indexes parsed commands by id, builds a keybind matcher for the
/// commands with shortcuts, and resolves each chord to the command that should run.
public struct CustomCommandEngine: Sendable {
    private var matcher: KeybindMatcher
    private let commandsByID: [UUID: CustomCommand]

    public init(commands: [CustomCommand]) {
        commandsByID = Dictionary(commands.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let binds: [(Keybind, UUID)] = commands.compactMap { command in
            guard !command.shortcut.isEmpty, let keybind = parseKeybind(command.shortcut) else { return nil }
            return (keybind, command.id)
        }
        matcher = KeybindMatcher(binds)
    }

    public enum Outcome: Equatable, Sendable {
        case fired(CustomCommand)
        case armed
        case unmatched
    }

    public mutating func advance(_ chord: Chord) -> Outcome {
        switch matcher.advance(chord) {
        case .fired(let id):
            commandsByID[id].map(Outcome.fired) ?? .unmatched
        case .armed:
            .armed
        case .unmatched:
            .unmatched
        }
    }

    public var isArmed: Bool { matcher.isArmed }

    public mutating func reset() {
        matcher.reset()
    }
}
