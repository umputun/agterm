import Foundation

/// The keyboard modifier flags a chord may require, as a host-free `OptionSet`. The app target maps
/// `NSEvent.ModifierFlags` onto this so the parser and matcher stay AppKit-free; `parseKeybind` spells them
/// `ctrl`/`control`, `cmd`/`command`, `opt`/`option`/`alt`, `shift`.
public struct Modifier: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = Modifier(rawValue: 1 << 0)
    public static let command = Modifier(rawValue: 1 << 1)
    public static let option = Modifier(rawValue: 1 << 2)
    public static let shift = Modifier(rawValue: 1 << 3)
}

/// The base keys a chord may name beyond a single printable character — exactly the named keys the app-side
/// runner can produce from an `NSEvent`, so `parseKeybind` rejects any name the runner could never fire.
/// `esc` is reserved as the leader abort and is NOT bindable. The arrows are here because the six
/// arrow-bound built-ins ship their defaults on them, so the grammar must spell `BuiltinAction.defaultChord`.
///
/// Adding a name means updating five sites, two inbound and three outbound:
/// - `CustomCommandRunner` and `UndoCloseShortcut` resolve `NSEvent` → name via `namedKey(forKeyCode:)`, so
///   a name with no keycode parses in the file yet never fires;
/// - `namedKey(forKeyEquivalent:)` maps a live `NSMenuItem` key-equivalent CHARACTER back for `keymap.list`;
///   a name missing there renders the key absent and breaks comparison with the resolved chord (a test pins the sets equal);
/// - `Chord.glyphString` renders the name in palette hints and tooltips, degrading to the raw name — cosmetic;
/// - `agtermApp.toShortcut`'s `default` arm `KeyEquivalent(Character(chord.key))` TRAPS on a multi-character
///   string — a crash on the first menu render, not a degradation, so update it first.
public let bindableNamedKeys: Set<String> = Set(["tab", "space", "return", "delete"]).union(bindableArrowKeys)

/// The four arrow keys, a subset of `bindableNamedKeys`. Separate for one extra rule: a built-in `map` may
/// not bind a modifier-less arrow (`parseMapLine`), since an always-on menu key-equivalent on a bare arrow
/// swallows the key in the terminal, the palettes, the dashboard grid and every text field.
let bindableArrowKeys: Set<String> = ["left", "right", "up", "down"]

/// The named key for a macOS virtual key code, or `nil` for a key carrying a normal character (which the
/// caller derives from the event). The single source of truth for the keyCode→name half of `NSEvent`→`Chord`,
/// shared by every app-side monitor so a name in `bindableNamedKeys` can't parse yet fail to fire.
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

/// The Latin base character at a physical ANSI key position, or `nil` where there is none (a named key, a
/// function key, the keypad). ANSI letters/digits/punctuation keyed by macOS virtual key code — exactly the
/// single characters `parseKeybind` accepts as a base key, so every entry is spellable in `keymap.conf`. The
/// layout-INDEPENDENT half of key resolution: a key code names a physical position and never changes with
/// the active input source, unlike the character that position produces.
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

/// The macOS virtual key code that produces a chord's base key, or nil when no ANSI position does.
///
/// The inverse of `namedKey(forKeyCode:)`/`latinKey(forKeyCode:)`, derived by scanning them rather than
/// spelled as a third table, so a name or position added to either is reachable here with no second edit.
/// `RegisterEventHotKey` is the caller: a system-wide hotkey is registered by physical position, never by
/// produced character, so it keeps firing when the user switches to a non-Latin layout.
public func keyCode(forChordKey key: String) -> UInt16? {
    // named keys first: their codes are outside the ANSI table, and neither map claims the same code.
    for code in UInt16(0)...127 where namedKey(forKeyCode: code) == key { return code }
    for code in UInt16(0)...127 where latinKey(forKeyCode: code) == key { return code }
    return nil
}

/// The base key for a key press. `produced` is the character the ACTIVE layout puts on that key with no
/// modifiers applied, `layoutIsASCIICapable` whether that layout can type ASCII at all.
///
/// The choice is per LAYOUT, not per key. An ASCII-capable layout (US, Dvorak, Colemak, US-International,
/// French, German) binds by the character it produces, so a chord follows the letter the user sees on the
/// key and an alternative Latin layout keeps its own letter positions. A layout that cannot type ASCII
/// (Russian, Greek, Hebrew, Arabic, Thai) can never produce a character a `keymap.conf` chord is spelled
/// with, so all its keys bind by physical position via `latinKey(forKeyCode:)`.
///
/// Deciding per key (keeping any produced character that happens to be ASCII) does not work: Greek types
/// `;` on the Q position and Hebrew `/`, so a Latin-spelled letter chord would stay dead on exactly the
/// layouts this exists to serve, and two physical keys could collapse onto one chord (on Hebrew the `'` key
/// produces `,` while the `,` key falls back to `,`). Whole-layout resolution keeps `latinKey`'s
/// one-key-per-position mapping intact, so no two TABLE positions collapse; a key code outside the table
/// keeps what it types and still aliases the table for the keypad (keypad `5` and the number row both give
/// `"5"`), harmless because keypad output does not vary by layout.
///
/// A different rule from `InterruptKeystroke.isInterrupt`, which tests the produced character (is it a Latin
/// letter?) rather than the layout: that one classifies a single hardcoded key and needs no layout context.
///
/// Returns `nil` when the press carries no usable base key: on a non-ASCII-capable layout a position outside
/// `latinKey`'s table that produced nothing, plus the ISO section key (a dead key at a TABLE position
/// resolves to its Latin key); on an ASCII-capable layout anything that produced nothing at all, table
/// position or not — that branch never consults the table.
public func chordKey(forKeyCode keyCode: UInt16, produced: String?, layoutIsASCIICapable: Bool) -> String? {
    // space is a named key (`namedKey(forKeyCode:)` claims keyCode 49); a produced space is not a base key.
    let base = produced?.first.map { String($0).lowercased() }.flatMap { $0 == " " ? nil : $0 }
    guard !layoutIsASCIICapable else { return base }
    if let latin = latinKey(forKeyCode: keyCode) { return latin }
    // the ISO section key (an ISO keyboard carries it, an ANSI one does not) has no table position AND types
    // a layout-dependent character, so keeping it would alias whichever table position types the same thing:
    // Ukrainian-PC types `\` there against the ANSI backslash key, Hebrew-PC `;` against the semicolon key.
    // both would fire one binding from two keys and swallow the keystroke.
    return keyCode == isoSectionKeyCode ? nil : base
}

/// The ISO-only key left of Z (macOS `kVK_ISO_Section`), absent from an ANSI keyboard and from `latinKey`.
private let isoSectionKeyCode: UInt16 = 10

/// The named key for a menu item's key-equivalent CHARACTER, or `nil` for an ordinary printable key — the
/// character counterpart of `namedKey(forKeyCode:)`, projecting live `NSMenuItem` key equivalents back into
/// keymap syntax: a menu item carries a character, not a virtual key code, and AppKit spells the arrows with
/// private-use function-key scalars and return/tab/space/delete with control characters. Without this a menu
/// chord renders as `cmd+opt+` with the key missing, uncomparable against the resolved `cmd+opt+up`. Matching
/// scalars rather than the AppKit constants keeps `agtermCore` AppKit-free; they are the documented
/// `NSUpArrowFunctionKey` family.
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
/// keybind starting with it would dead-race the monitor and must be rejected. MIRRORS the monitors' real
/// predicates, not a fixed list:
/// - the Ctrl-Tab session switcher (`SessionSwitcher`) consumes Tab whenever Control is held, with ANY other modifiers;
/// - the Ctrl-1/2 pane shortcuts (`PaneShortcuts`) consume 1/2 only when Control is the SOLE modifier.
/// Used by the built-in `map` check and the custom-command cross-section validation, so neither can rebind one.
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

    /// The chord in kitty syntax (e.g. `cmd+shift+e`), the form the user writes in `keymap.conf`. Modifiers
    /// emit in a fixed `ctrl+cmd+opt+shift` order so the round-trip is stable.
    public var displayString: String {
        var parts: [String] = []
        if mods.contains(.control) { parts.append("ctrl") }
        if mods.contains(.command) { parts.append("cmd") }
        if mods.contains(.option) { parts.append("opt") }
        if mods.contains(.shift) { parts.append("shift") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    /// The chord as macOS menu glyphs (e.g. `⌘⌥N`): modifiers in the macOS order `⌃⌥⇧⌘`, then the key (single
    /// letters uppercased, named keys as symbols) — action-palette hints, so a built-in reads like its menu equivalent;
    /// custom commands keep the raw kitty `displayString`.
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

/// A keybind: an ordered sequence of chords. Length 1 is a simple chord, length > 1 a leader sequence
/// (e.g. `ctrl+a > b`).
public typealias Keybind = [Chord]

public extension Array where Element == Chord {
    /// The keybind in kitty syntax, chords joined with `>` (`ctrl+a>g`) — the spelling `keymap.conf` uses.
    var displayString: String { map(\.displayString).joined(separator: ">") }

    /// The keybind as macOS glyphs, chords joined with `>` (`⌃A>T`). Run together they read as one chord
    /// (`⌃AT` looks like Ctrl-Alt-T), and a space is taken: callers list a binding's ALTERNATIVES
    /// space-separated. `>` is what `keymap.conf` already spells, so the hint matches what the user typed.
    var glyphString: String { map(\.glyphString).joined(separator: ">") }
}

/// What a keybind fires: a custom command by id, or a built-in action. One matcher carries both verbs'
/// monitor-bound binds, and the conflict pass names whichever side lost.
public enum KeybindTarget: Hashable, Sendable {
    case command(UUID)
    case builtin(BuiltinAction)
}

/// Parse a keybind string into a `Keybind`, or `nil` when it is empty, malformed, or names an unknown modifier.
///
/// The grammar is chords separated by `>`, each a `+`-joined list of modifier words and a final base key,
/// case-insensitive: `cmd+shift+e`, `ctrl+a>b`, `ctrl + a > b`. The base key is a single printable character
/// or one of `bindableNamedKeys`; any other multi-char word (`esc`, `f1`) is rejected. Returns `nil` for an
/// empty input, an empty chord (a trailing `>` or `+`), a chord with no base key or more than one, an
/// unrecognized modifier word, or an unproducible named key.
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

/// Parse a binding token into its alternatives, splitting on `|` — the tier above `>` (chords in a sequence)
/// and `+` (modifiers in a chord). Alternatives live inside ONE whitespace-delimited token, with no spaces
/// around the `|`, so `parseCommandLine`'s shell-line tokenizer needs no change.
///
/// Returns `nil` when ANY alternative is malformed, which kills the whole line: binding the half that parsed
/// would hide the typo behind a line that looks like it worked. A token with no `|` yields a one-element list
/// wrapping exactly `parseKeybind`'s result.
///
/// `|` being the separator makes it unspellable as a base key: `cmd+|` splits before `parseChord` sees it.
/// Harmless — no unshifted key produces `|`, so such a binding could never fire; the spelling that does is
/// `shift+\`.
func parseKeybinds(_ s: String) -> [Keybind]? {
    var keybinds: [Keybind] = []
    for part in s.split(separator: "|", omittingEmptySubsequences: false) {
        guard let keybind = parseKeybind(String(part)) else { return nil }
        keybinds.append(keybind)
    }
    return keybinds.isEmpty ? nil : keybinds
}

/// Whether a token `parseKeybinds` rejected still reads as an intended binding: it offers `|` alternatives and
/// at least one of them parses. A `command` line's first token may legitimately be shell text (`ls|grep foo`),
/// so this is what separates a typo in one alternative from a pipeline that happens to lead the line.
func hasMalformedAlternative(_ s: String) -> Bool {
    let parts = s.split(separator: "|", omittingEmptySubsequences: false)
    guard parts.count > 1 else { return false }
    return parts.contains { parseKeybind(String($0)) != nil }
}

/// A binding token's alternatives as raw-substring / parsed-keybind pairs in file order, every repeat of an
/// earlier keybind dropped. `nil` when any alternative is malformed, exactly as `parseKeybinds`. The raw
/// substrings ride along so diagnostics and `CustomCommand.shortcut` quote the user's own spelling instead of
/// a canonicalized re-render (`command+shift+a` must not become `cmd+shift+a`).
func alternativeKeybinds(_ s: String) -> [(raw: String, keybind: Keybind)]? {
    guard let keybinds = parseKeybinds(s) else { return nil }

    let parts = s.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    var kept: [(raw: String, keybind: Keybind)] = []
    for (part, keybind) in zip(parts, keybinds) where !kept.contains(where: { $0.keybind == keybind }) {
        kept.append((part, keybind))
    }
    return kept
}

/// Parse a single chord (a `+`-joined list of modifier words plus one base key), or `nil` when it is empty,
/// has no or multiple base keys, names an unknown modifier, or a multi-char key outside `bindableNamedKeys`.
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

    // reject a multi-char word outside `bindableNamedKeys` so the UI never accepts a chord that can't fire.
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

/// A pair of monitor-bound binds that conflict — either identical or one a sequence-prefix of the other (the
/// wait-or-fire ambiguity). Each side names its target AND the exact keybind that lost, because a target may
/// own several alternatives and only the offending one is dropped.
public struct KeybindConflict: Equatable, Sendable {
    public struct Side: Hashable, Sendable {
        public let target: KeybindTarget
        public let keybind: Keybind

        public init(target: KeybindTarget, keybind: Keybind) {
            self.target = target
            self.keybind = keybind
        }
    }

    public let first: Side
    public let second: Side

    public init(first: Side, second: Side) {
        self.first = first
        self.second = second
    }
}

/// Find conflicts across every monitor-bound bind, from both verbs and every alternative of each. Two binds
/// conflict when one keybind is a prefix of the other (a duplicate is the degenerate equal-length case): the
/// shorter would fire — or be forced to wait — ambiguously while the longer is still being typed. Callers pass
/// already-parsed binds, so an empty or unparseable shortcut never reaches here.
public func keybindConflicts(_ binds: [(keybind: Keybind, target: KeybindTarget)]) -> [KeybindConflict] {
    var conflicts: [KeybindConflict] = []
    for i in binds.indices {
        for j in binds.index(after: i)..<binds.endIndex where isPrefix(binds[i].keybind, of: binds[j].keybind) {
            conflicts.append(KeybindConflict(
                first: KeybindConflict.Side(target: binds[i].target, keybind: binds[i].keybind),
                second: KeybindConflict.Side(target: binds[j].target, keybind: binds[j].keybind)))
        }
    }
    return conflicts
}

/// Whether one keybind is a prefix of another (equal length counts — a duplicate is a prefix of itself).
/// Order-independent: it checks both directions, so callers pass one only.
private func isPrefix(_ a: Keybind, of b: Keybind) -> Bool {
    a == b || isStrictKeybindPrefix(a, of: b) || isStrictKeybindPrefix(b, of: a)
}

/// Whether `prefix` is a STRICT (shorter, leading) prefix of `keybind` — the relation that decides which of
/// two binds can never fire: `KeybindMatcher` fires the exact shorter match rather than waiting out the
/// longer one.
func isStrictKeybindPrefix(_ prefix: Keybind, of keybind: Keybind) -> Bool {
    guard prefix.count < keybind.count else { return false }
    return Array(keybind.prefix(prefix.count)) == prefix
}
