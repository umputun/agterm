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
///
/// The four arrows are here because the six arrow-bound built-ins ship their defaults on them, so the
/// grammar must be able to spell what `BuiltinAction.defaultChord` returns.
///
/// Adding a name here means updating five sites, two inbound and three outbound:
/// - `CustomCommandRunner` and `UndoCloseShortcut` resolve `NSEvent` → name via `namedKey(forKeyCode:)`,
///   so a name with no keycode parses in the file yet never fires;
/// - `namedKey(forKeyEquivalent:)` resolves a live `NSMenuItem`'s key-equivalent CHARACTER back to the
///   name for `keymap.list`, so a name missing there makes every menu item carrying that key render with
///   the key absent and stop comparing against the resolved chord (its own test pins the two sets equal);
/// - `Chord.glyphString` renders the name in palette hints and tooltips — it degrades to the raw name,
///   so a miss here is cosmetic;
/// - `agtermApp.toShortcut` maps the name to a SwiftUI `KeyEquivalent`, and its `default` arm is
///   `KeyEquivalent(Character(chord.key))`, which TRAPS on a multi-character string. That one is a
///   crash on the first menu render, not a degradation, so it is the site to update first.
public let bindableNamedKeys: Set<String> = Set(["tab", "space", "return", "delete"]).union(bindableArrowKeys)

/// The four arrow keys, a subset of `bindableNamedKeys`. Named separately because they carry one extra
/// rule: a built-in `map` may not bind a modifier-less arrow (`parseMapLine`), since an always-on menu
/// key-equivalent on a bare arrow swallows the key in the terminal, the palettes, the dashboard grid,
/// and every text field at once.
let bindableArrowKeys: Set<String> = ["left", "right", "up", "down"]

/// The named key for a macOS virtual key code, or `nil` for a key that carries a normal character
/// (which the caller derives from the event itself). The single source of truth for the keyCode→name
/// half of the `NSEvent`→`Chord` mapping, shared by every app-side monitor so a name added to
/// `bindableNamedKeys` can't parse in the file yet fail to fire at runtime.
public func namedKey(forKeyCode keyCode: UInt16) -> String? {
    switch keyCode {
    case 36: return "return"
    case 48: return "tab"
    case 49: return "space"
    case 51: return "delete"
    case 123: return "left"
    case 124: return "right"
    case 125: return "down"
    case 126: return "up"
    default: return nil
    }
}

/// The Latin base character at a physical ANSI key position, or `nil` for a position that carries no
/// Latin key (a named key, a function key, the keypad). The letters, digits, and punctuation of the ANSI
/// layout, keyed by macOS virtual key code — the values are exactly the single characters `parseKeybind`
/// accepts as a base key, so every entry is spellable in `keymap.conf`.
///
/// This is the layout-INDEPENDENT half of key resolution: a virtual key code names a physical position
/// and never changes with the active input source, unlike the character that position produces.
func latinKey(forKeyCode keyCode: UInt16) -> String? {
    switch keyCode {
    case 0: return "a"
    case 1: return "s"
    case 2: return "d"
    case 3: return "f"
    case 4: return "h"
    case 5: return "g"
    case 6: return "z"
    case 7: return "x"
    case 8: return "c"
    case 9: return "v"
    case 11: return "b"
    case 12: return "q"
    case 13: return "w"
    case 14: return "e"
    case 15: return "r"
    case 16: return "y"
    case 17: return "t"
    case 18: return "1"
    case 19: return "2"
    case 20: return "3"
    case 21: return "4"
    case 22: return "6"
    case 23: return "5"
    case 24: return "="
    case 25: return "9"
    case 26: return "7"
    case 27: return "-"
    case 28: return "8"
    case 29: return "0"
    case 30: return "]"
    case 31: return "o"
    case 32: return "u"
    case 33: return "["
    case 34: return "i"
    case 35: return "p"
    case 37: return "l"
    case 38: return "j"
    case 39: return "'"
    case 40: return "k"
    case 41: return ";"
    case 42: return "\\"
    case 43: return ","
    case 44: return "/"
    case 45: return "n"
    case 46: return "m"
    case 47: return "."
    case 50: return "`"
    default: return nil
    }
}

/// The base key for a key press. `produced` is the character the ACTIVE layout puts on that key with no
/// modifiers applied (the app-side monitors pass what the `NSEvent` reports), and
/// `layoutIsASCIICapable` says whether that layout can type ASCII at all.
///
/// The choice is made per LAYOUT, not per key. An ASCII-capable layout — US, Dvorak, Colemak,
/// US-International, French, German — binds by the character it produces, so a chord follows the letter
/// the user sees on the key and an alternative Latin layout keeps its own letter positions. A layout that
/// cannot type ASCII — Russian, Greek, Hebrew, Arabic, Thai — can never produce a character a
/// `keymap.conf` chord is spelled with, so every one of its keys binds by physical position via
/// `latinKey(forKeyCode:)`.
///
/// Deciding per key instead (keeping any produced character that happens to be ASCII) does not work:
/// Greek types `;` on the Q position and Hebrew types `/` there, so a Latin-spelled letter chord would
/// stay dead on exactly the layouts this exists to serve, and two physical keys could collapse onto one
/// chord — on Hebrew the `'` key produces `,` while the `,` key falls back to `,`. Resolving the whole
/// layout at once keeps `latinKey`'s one-key-per-position mapping intact, so no two TABLE positions can
/// collapse. A key code outside the table keeps what it types, which still aliases the table for the
/// keypad — keypad `5` and the number row both give `"5"` — exactly as it did before any of this, since
/// the keypad's output does not vary by layout.
///
/// This is a different rule from `InterruptKeystroke.isInterrupt`, which tests the produced character
/// itself (is it a Latin letter?) rather than the layout. That one classifies a single hardcoded key, so
/// it needs no layout context; a chord needs the whole ANSI vocabulary and does.
///
/// Returns `nil` when the press carries no usable base key. On a non-ASCII-capable layout that means a
/// position outside `latinKey`'s table that produced nothing, plus the ISO section key; a dead key at a
/// TABLE position resolves to its Latin key rather than to `nil`. On an ASCII-capable layout it means
/// anything that produced nothing at all, table position or not — that branch never consults the table.
public func chordKey(forKeyCode keyCode: UInt16, produced: String?, layoutIsASCIICapable: Bool) -> String? {
    // space is a named key (`namedKey(forKeyCode:)` claims keyCode 49); a produced space is not a base key.
    let base = produced?.first.map { String($0).lowercased() }.flatMap { $0 == " " ? nil : $0 }
    guard !layoutIsASCIICapable else { return base }
    if let latin = latinKey(forKeyCode: keyCode) { return latin }
    // the ISO section key — the extra key an ISO keyboard carries and an ANSI one does not — has no
    // position in the table AND types a layout-dependent character, so keeping it would alias whichever
    // table position types the same thing: Ukrainian-PC types `\` there against the ANSI backslash key,
    // Hebrew-PC types `;` there against the ANSI semicolon key. Both would fire one binding from two
    // keys and swallow the keystroke. It cannot spell a chord on a layout resolved by position.
    return keyCode == isoSectionKeyCode ? nil : base
}

/// The ISO-only key left of Z (macOS `kVK_ISO_Section`), absent from an ANSI keyboard and from `latinKey`.
private let isoSectionKeyCode: UInt16 = 10

/// The named key for a menu item's key-equivalent CHARACTER, or `nil` for an ordinary printable key.
///
/// The character counterpart of `namedKey(forKeyCode:)`, for projecting live `NSMenuItem` key
/// equivalents back into keymap syntax: a menu item carries a character rather than a virtual key code,
/// and AppKit spells the arrows with private-use function-key scalars and return/tab/space/delete with
/// control characters. Without this a menu chord renders as `cmd+opt+` with the key missing, which
/// cannot be compared against the `cmd+opt+up` the keymap resolved.
///
/// Kept host-free by matching the scalar values rather than the AppKit constants, so `agtermCore` stays
/// AppKit-free; the values are the documented `NSUpArrowFunctionKey` family.
public func namedKey(forKeyEquivalent character: String) -> String? {
    let scalars = character.unicodeScalars
    guard scalars.count == 1, let scalar = scalars.first else { return nil }
    switch scalar.value {
    case 0xF700: return "up"
    case 0xF701: return "down"
    case 0xF702: return "left"
    case 0xF703: return "right"
    case 0x0D, 0x03: return "return" // carriage return, and the numeric keypad's enter
    case 0x09: return "tab"
    case 0x20: return "space"
    case 0x08, 0x7F: return "delete" // backspace, and forward delete
    default: return nil
    }
}

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

    /// The chord rendered as macOS menu glyphs (e.g. `⌘N`, `⌘⌥N`, `⌃P`): modifiers in the macOS order
    /// `⌃⌥⇧⌘`, then the key (single letters uppercased, the named keys as their symbols). Used for the
    /// action-palette shortcut hints so a built-in reads like its menu equivalent; custom commands keep
    /// the raw kitty `displayString`.
    public var glyphString: String {
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        switch key {
        case "tab": s += "⇥"
        case "space": s += "␣"
        case "return": s += "↩"
        case "delete": s += "⌫"
        case "left": s += "←"
        case "right": s += "→"
        case "up": s += "↑"
        case "down": s += "↓"
        default: s += key.count == 1 ? key.uppercased() : key
        }
        return s
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
/// `delete`/`left`/`right`/`up`/`down`) — the keys the app-side runner can actually produce; any other
/// multi-char word (e.g. `esc`, `f1`) is rejected. Returns `nil` for an empty input, an empty chord (e.g. a trailing `>`
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
