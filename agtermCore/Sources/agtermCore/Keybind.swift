import Foundation

/// The keyboard modifier flags a chord may require, as a host-free `OptionSet`.
///
/// The app target maps `NSEvent.ModifierFlags` onto this so the parser and matcher stay free of
/// AppKit. `parseKeybind` recognizes the modifier words `ctrl`/`control`, `cmd`/`command`,
/// `opt`/`option`/`alt`, and `shift`.
public struct Modifier: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = Modifier(rawValue: 1 << 0)
    public static let command = Modifier(rawValue: 1 << 1)
    public static let option = Modifier(rawValue: 1 << 2)
    public static let shift = Modifier(rawValue: 1 << 3)
}

/// The base keys a chord may name beyond a single printable character. These are exactly the named
/// keys the app-side runner can produce from an `NSEvent`, so `parseKeybind` rejects any other name
/// (a key the UI would accept but the runner could never fire). `esc` is reserved as the leader
/// abort and is intentionally NOT bindable.
public let bindableNamedKeys: Set<String> = ["tab", "space", "return", "delete"]

/// Whether a chord is owned by the app's always-on `NSEvent` monitors (NOT a menu key-equivalent), so a
/// keybind that starts with it would dead-race the monitor and must be rejected. This MIRRORS the
/// monitors' real predicates, not a fixed list:
/// - the Ctrl-Tab session switcher (`SessionSwitcher`) consumes Tab whenever Control is held, with ANY
///   other modifiers (`ctrl+tab`, `ctrl+shift+tab`, `ctrl+opt+tab`, `ctrl+cmd+tab`);
/// - the Ctrl-1/2 pane shortcuts (`PaneShortcuts`) consume 1/2 only when Control is the SOLE modifier.
/// Used by both the built-in `map` check and the custom-command cross-section validation so neither can
/// rebind a reserved chord. Host-free; kept next to the chord model so the rule is discoverable.
public func isReservedMonitorChord(_ chord: Chord) -> Bool {
    if chord.mods.contains(.control), chord.key == "tab" { return true }
    if chord.mods == [.control], chord.key == "1" || chord.key == "2" { return true }
    return false
}

/// A single key press: zero or more modifiers plus a base key (a lowercased single character or one
/// of `bindableNamedKeys`). Chords compose into a `Keybind` sequence.
public struct Chord: Equatable, Hashable, Sendable {
    public var mods: Modifier
    public var key: String

    public init(mods: Modifier, key: String) {
        self.mods = mods
        self.key = key
    }

    /// The chord rendered back to kitty syntax (e.g. `cmd+shift+e`), the same form the user writes in
    /// `keymap.conf`. Modifiers are emitted in a fixed `ctrl+cmd+opt+shift` order so the round-trip is
    /// stable; used to show a built-in's current binding consistently with how custom commands display
    /// their raw shortcut string.
    public var displayString: String {
        var parts: [String] = []
        if mods.contains(.control) { parts.append("ctrl") }
        if mods.contains(.command) { parts.append("cmd") }
        if mods.contains(.option) { parts.append("opt") }
        if mods.contains(.shift) { parts.append("shift") }
        parts.append(key)
        return parts.joined(separator: "+")
    }
}

/// A keybind: an ordered sequence of chords. Length 1 is a simple chord (e.g. `cmd+shift+e`),
/// length > 1 is a leader sequence (e.g. `ctrl+a > b`).
public typealias Keybind = [Chord]

/// Parse a keybind string into a `Keybind`, or `nil` when it is empty, malformed, or names an
/// unknown modifier.
///
/// The grammar is chords separated by `>`, each chord a `+`-joined list of modifier words and a
/// final base key, case-insensitive. Examples: `cmd+shift+e`, `ctrl+a>b`, `ctrl + a > b`. The base
/// key is a single printable character or one of `bindableNamedKeys` (`tab`/`space`/`return`/
/// `delete`) — the keys the app-side runner can actually produce; any other multi-char word (e.g.
/// `esc`, `f1`) is rejected. Returns `nil` for an empty input, an empty chord (e.g. a trailing `>`
/// or `+`), a chord with no base key, more than one base key in a chord, an unrecognized modifier
/// word, or an unproducible named key.
public func parseKeybind(_ s: String) -> Keybind? {
    let chordStrings = s.split(separator: ">", omittingEmptySubsequences: false)
    guard !chordStrings.isEmpty else { return nil }

    var keybind: Keybind = []
    for chordString in chordStrings {
        guard let chord = parseChord(String(chordString)) else { return nil }
        keybind.append(chord)
    }
    return keybind
}

/// Parse a single chord (a `+`-joined list of modifier words plus one base key), or `nil` when it
/// is empty, has no base key, has multiple base keys, names an unknown modifier, or names a base key
/// the runner can't fire (a multi-char word that is not in `bindableNamedKeys`).
private func parseChord(_ s: String) -> Chord? {
    let tokens = s.split(separator: "+", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    guard !tokens.isEmpty, !tokens.contains(where: { $0.isEmpty }) else { return nil }

    var mods: Modifier = []
    var key: String?
    for token in tokens {
        if let mod = modifier(for: token) {
            mods.insert(mod)
            continue
        }
        // a non-modifier token is the base key; only one is allowed per chord.
        guard key == nil else { return nil }
        key = token
    }

    // the base key must be a single character or a named key the runner can produce; reject any
    // other multi-char word (e.g. `esc`/`f1`) so the UI never accepts a chord that can't fire.
    guard let key, key.count == 1 || bindableNamedKeys.contains(key) else { return nil }
    return Chord(mods: mods, key: key)
}

/// Map a modifier word to its `Modifier`, or `nil` when the token is not a known modifier.
private func modifier(for token: String) -> Modifier? {
    switch token {
    case "ctrl", "control": return .control
    case "cmd", "command": return .command
    case "opt", "option", "alt": return .option
    case "shift": return .shift
    default: return nil
    }
}

/// A pair of custom commands whose shortcuts conflict — either identical or one a sequence-prefix
/// of the other (the wait-or-fire ambiguity). Carries both ids so the UI can point at the offenders.
public struct KeybindConflict: Equatable, Sendable {
    public let first: UUID
    public let second: UUID

    public init(first: UUID, second: UUID) {
        self.first = first
        self.second = second
    }
}

/// Find shortcut conflicts across a list of custom commands.
///
/// Two parseable, non-empty shortcuts conflict when one keybind is a prefix of the other (a
/// duplicate is the degenerate equal-length case). A prefix conflict means the shorter bind would
/// fire — or be forced to wait — ambiguously while the longer one is still being typed. Commands
/// with an empty or unparseable shortcut are skipped (palette-only / surfaced separately).
public func keybindConflicts(_ commands: [CustomCommand]) -> [KeybindConflict] {
    let parsed: [(id: UUID, keybind: Keybind)] = commands.compactMap { command in
        guard !command.shortcut.isEmpty, let keybind = parseKeybind(command.shortcut) else { return nil }
        return (command.id, keybind)
    }

    var conflicts: [KeybindConflict] = []
    for i in parsed.indices {
        for j in parsed.index(after: i)..<parsed.endIndex where isPrefix(parsed[i].keybind, of: parsed[j].keybind) {
            conflicts.append(KeybindConflict(first: parsed[i].id, second: parsed[j].id))
        }
    }
    return conflicts
}

/// Whether one keybind is a prefix of another (equal length counts — a duplicate is a prefix of
/// itself). Order-independent: it sorts the two binds by length itself and checks the shorter-or-equal
/// against the longer, so the caller need not pass them in both directions.
private func isPrefix(_ a: Keybind, of b: Keybind) -> Bool {
    let (shorter, longer) = a.count <= b.count ? (a, b) : (b, a)
    return Array(longer.prefix(shorter.count)) == shorter
}
