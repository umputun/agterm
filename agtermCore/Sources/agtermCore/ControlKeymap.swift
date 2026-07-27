import Foundation

/// One rebindable built-in and the chord the keymap currently resolves it to.
public struct ControlKeymapAction: Codable, Sendable, Equatable {
    /// The action's `keymap.conf` name, e.g. `close_session`.
    public var action: String
    /// The resolved chord in kitty syntax (`cmd+shift+e`), omitted when the action is keyless.
    ///
    /// One shipped default cannot be typed back into `keymap.conf`: `increase_font_size` is ⌘+, which
    /// renders `cmd++` and does not re-parse (`+` is the chord joiner). It is reported verbatim anyway,
    /// because the live `menu` half renders that item identically — substituting a placeholder here would
    /// turn the one row that compares correctly into a false mismatch, which costs more than the wart.
    public var chord: String?
    /// `true` when the action's resolved chord DIFFERS from its shipped default; omitted otherwise.
    ///
    /// Deliberately a comparison of chords rather than "a `map` line exists for this action": a
    /// redundant `map cmd+w close_session` parses fine and leaves the action on its default, and marking
    /// that as overridden would report a difference a caller cannot see anywhere else.
    public var overridden: Bool?

    public init(action: String, chord: String? = nil, overridden: Bool? = nil) {
        self.action = action
        self.chord = chord
        self.overridden = overridden
    }
}

/// One `command` line from `keymap.conf`.
public struct ControlKeymapCommand: Codable, Sendable, Equatable {
    public var name: String
    /// The raw kitty-syntax shortcut, omitted for a palette-only command (or one whose chord was
    /// dropped as colliding — the diagnostics say which).
    public var shortcut: String?

    public init(name: String, shortcut: String? = nil) {
        self.name = name
        self.shortcut = shortcut
    }
}

/// A `keymap.conf` parse problem, the same pair the Key Mapping settings tab shows.
public struct ControlKeymapDiagnostic: Codable, Sendable, Equatable {
    /// 1-based. `0` is the sentinel for a whole-file or cross-section problem (a chord collision between
    /// two sections) that belongs to no single line.
    public var line: Int
    public var message: String

    public init(line: Int, message: String) {
        self.line = line
        self.message = message
    }
}

/// A live menu item that carries a key equivalent.
///
/// This is the half that makes `keymap.list` diagnostic rather than merely descriptive. The `actions`
/// list says what the keymap RESOLVED; this says what the menu bar is actually dispatching, and the two
/// can disagree — SwiftUI defers its menu rebuild to the next app activation, so a chord can be correct
/// in the model and stale in the menu.
public struct ControlKeymapMenuItem: Codable, Sendable, Equatable {
    /// The owning top-level menu's title, e.g. `File`.
    public var menu: String
    public var title: String
    /// The chord in kitty syntax, so it compares directly against an action's `chord`.
    public var chord: String
    /// The item's Objective-C action selector. agterm's own SwiftUI items all report `menuAction:`;
    /// anything else is an AppKit-supplied item (`performClose:`, `closeAll:`, …), which is what a
    /// stock item competing for an agterm chord looks like.
    public var selector: String?
    /// `false` when the item is disabled and its chord therefore INERT — AppKit consumes the key
    /// equivalent and fires nothing, so a same-chord enabled sibling does not run either. Omitted when
    /// the item is enabled, which is the ordinary case.
    ///
    /// Worth reporting because disabled items are routine here rather than exotic: most File/View/Navigate
    /// items carry a `modalActive` gate, so with the dashboard open the menu is largely inert while still
    /// holding every chord. A caller comparing `actions` against `menu` would otherwise see the binding
    /// present and conclude the menu is fine.
    public var enabled: Bool?

    public init(menu: String, title: String, chord: String, selector: String? = nil, enabled: Bool? = nil) {
        self.menu = menu
        self.title = title
        self.chord = chord
        self.selector = selector
        self.enabled = enabled
    }
}

/// The `keymap.list` payload: what the keymap resolved, plus what the menu bar is really carrying.
public struct ControlKeymap: Codable, Sendable, Equatable {
    /// The `keymap.conf` that produced this, so a caller knows which file to edit.
    public var path: String
    public var actions: [ControlKeymapAction]
    public var commands: [ControlKeymapCommand]
    public var diagnostics: [ControlKeymapDiagnostic]
    /// Live menu key equivalents; omitted when the caller could not read the menu bar.
    public var menu: [ControlKeymapMenuItem]?

    public init(path: String, actions: [ControlKeymapAction], commands: [ControlKeymapCommand],
                diagnostics: [ControlKeymapDiagnostic], menu: [ControlKeymapMenuItem]? = nil) {
        self.path = path
        self.actions = actions
        self.commands = commands
        self.diagnostics = diagnostics
        self.menu = menu
    }
}

public extension ControlKeymap {
    /// Project a parsed keymap into the `keymap.list` payload. Host-free: the caller supplies the live
    /// `menu` separately, since only the app target can read `NSApp.mainMenu`.
    ///
    /// Actions come out in `BuiltinAction.allCases` order rather than sorted, so the listing groups the
    /// way the file's own reference comment does (window, workspace, session, …) instead of scattering
    /// related actions alphabetically.
    static func project(keymap: Keymap, diagnostics: [KeymapDiagnostic], path: String,
                        menu: [ControlKeymapMenuItem]? = nil) -> ControlKeymap {
        let actions = BuiltinAction.allCases.map { action in
            let resolved = keymap.equivalent(for: action)
            return ControlKeymapAction(action: action.rawValue,
                                       chord: resolved?.displayString,
                                       overridden: resolved != action.defaultChord ? true : nil)
        }
        let commands = keymap.commands.map {
            ControlKeymapCommand(name: $0.name, shortcut: $0.shortcut.isEmpty ? nil : $0.shortcut)
        }
        return ControlKeymap(path: path, actions: actions, commands: commands,
                             diagnostics: diagnostics.map { ControlKeymapDiagnostic(line: $0.line, message: $0.message) },
                             menu: menu)
    }
}
