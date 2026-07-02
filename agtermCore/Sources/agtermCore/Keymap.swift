import Foundation

/// The parsed keymap: the built-in actions the user rebound, plus the custom commands defined in
/// `keymap.conf`.
///
/// `builtinOverrides` maps a `BuiltinAction` to the single chord the user `map`ped to it (built-in
/// overrides are single-chord only). `commands` are the custom commands, each with a `shortcut` that
/// may be empty (palette-only) or a leader sequence.
public struct Keymap: Equatable, Sendable {
    public let builtinOverrides: [BuiltinAction: Chord]
    public let commands: [CustomCommand]

    public init(builtinOverrides: [BuiltinAction: Chord], commands: [CustomCommand]) {
        self.builtinOverrides = builtinOverrides
        self.commands = commands
    }

    /// The active chord for a built-in action: the user override when one is present, else the
    /// action's shipped `defaultChord` (which is `nil` for the keyless and arrow-bound actions).
    public func equivalent(for action: BuiltinAction) -> Chord? {
        builtinOverrides[action] ?? action.defaultChord
    }

    /// The action's current shortcut as a macOS menu glyph string (e.g. `⌘N`, `⌃⌘S`), or `nil` when
    /// the action has no shortcut at all. Resolves the effective chord (`equivalent(for:)` — user
    /// override else shipped default) and renders it via `Chord.glyphString`; for the arrow-bound
    /// actions, which have no expressible default, it falls back to the hardcoded `arrowGlyphFallback`.
    /// `nil` means "not configured" — the caller shows no shortcut. Drives both the action-palette
    /// hints and the toolbar tooltips so the two surfaces can't drift.
    public func glyphHint(for action: BuiltinAction) -> String? {
        equivalent(for: action)?.glyphString ?? action.arrowGlyphFallback
    }
}

/// A single problem found while parsing `keymap.conf`. `line` is 1-based; `0` is reserved for a
/// whole-file or cross-section diagnostic that doesn't belong to a single line.
public struct KeymapDiagnostic: Equatable, Sendable {
    public let line: Int
    public let message: String

    public init(line: Int, message: String) {
        self.line = line
        self.message = message
    }
}

/// Host-free loader for the user keymap file. Missing files recover as an empty keymap with no
/// diagnostics; existing unreadable or invalid-UTF8 files recover with a single line-0 diagnostic.
public struct KeymapStore: Sendable {
    public let configDirectory: URL

    public init(configDirectory: URL) {
        self.configDirectory = configDirectory
    }

    public var path: URL {
        ConfigPaths.keymapPath(configDirectory: configDirectory)
    }

    public func load() -> (keymap: Keymap, diagnostics: [KeymapDiagnostic]) {
        do {
            let text = try String(contentsOf: path, encoding: .utf8)
            return parseKeymap(text)
        } catch {
            let empty = Keymap(builtinOverrides: [:], commands: [])
            guard FileManager.default.fileExists(atPath: path.path) else {
                return (empty, [])
            }
            let diagnostic = KeymapDiagnostic(
                line: 0,
                message: "could not read keymap.conf: \(error.localizedDescription)")
            return (empty, [diagnostic])
        }
    }
}

/// Parse the text of a `keymap.conf` into a `Keymap` plus a list of diagnostics. Never throws: a bad
/// line becomes a diagnostic and is skipped, so a single malformed line never discards the rest of
/// the file.
///
/// Grammar (kitty-flavored): the file is line-based. Blank lines and lines whose first non-space
/// character is `#` are ignored. A trailing inline comment is stripped when a `#` is preceded by
/// whitespace AND lies outside any quoted span, single OR double (so a `#` inside a `command "name"`,
/// inside a double-quoted shell arg, or inside a single-quoted one like `git commit -m 'fix #42'` is
/// kept) — this keeps `command "x" echo a#b` and `map cmd+a#` handling simple while allowing
/// `map cmd+d toggle_split  # rebind`.
///
/// The first whitespace-token is the verb:
/// - `map <chord> <action>`: `<chord>` is parsed via `parseKeybind` (a leader sequence, count > 1, is
///   rejected — built-ins are single-chord); `<action>` must be a `BuiltinAction` raw value. Resolution
///   is order-INDEPENDENT and decided against the FINAL resolved built-in set: only a chord that two
///   DISTINCT actions resolve to in the final state is a duplicate. When that happens an override
///   colliding with another action's unmoved default loses (the default owner keeps the chord); two
///   colliding overrides → the later one (in file order) loses, each with a diagnostic. So
///   `map cmd+d new_session` and `map cmd+shift+d toggle_split` both succeed in either order (the final
///   state is conflict-free — toggle_split has moved off cmd+d).
/// - `command "<name>" [chord] <shell...>`: `<name>` is a required double-quoted string (may contain
///   spaces). The token right after the closing quote is the chord IFF `parseKeybind` accepts it;
///   otherwise there is no chord and the whole remainder is the shell line (palette-only). The shell
///   line keeps `{AGT_X}` tokens verbatim.
/// - anything else is an unknown verb and is skipped with a diagnostic.
///
/// After every line is parsed, a SINGLE final cross-section validation pass runs (see
/// `validateCommands`): it drops any custom keybind that collides with an active built-in chord or with
/// another custom keybind, appending a diagnostic for each. The dropped command stays in the result
/// (palette-only) with its `shortcut` cleared.
public func parseKeymap(_ text: String) -> (keymap: Keymap, diagnostics: [KeymapDiagnostic]) {
    // overrides are collected in file order (NOT folded into a dict yet), so the final cross-builtin
    // duplicate pass can resolve them against the FULLY-resolved active chord set and skip the
    // later-in-file member of a colliding pair.
    var parsedOverrides: [ParsedOverride] = []
    var commands: [CustomCommand] = []
    var diagnostics: [KeymapDiagnostic] = []

    // normalize line endings so CRLF (`\r\n`) and lone-CR (`\r`) files split into lines correctly:
    // without this a CRLF line leaves a trailing `\r` that .whitespaces won't strip (so `toggle_split\r`
    // reads as an unknown action) and a lone-CR file collapses into one line.
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    let rawLines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    for (index, rawLine) in rawLines.enumerated() {
        let lineNumber = index + 1
        let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }

        let verb = String(line.prefix(while: { !$0.isWhitespace }))
        let rest = String(line.dropFirst(verb.count)).trimmingCharacters(in: .whitespaces)

        switch verb {
        case "map":
            parseMapLine(rest, line: lineNumber, overrides: &parsedOverrides, diagnostics: &diagnostics)
        case "command":
            parseCommandLine(rest, line: lineNumber, commands: &commands, diagnostics: &diagnostics)
        default:
            diagnostics.append(KeymapDiagnostic(line: lineNumber, message: "unknown verb '\(verb)'"))
        }
    }

    // resolve the overrides against the final active chord set (a built-in's unmoved default OR an
    // already-accepted override), skipping any `map` whose chord is already owned by a DIFFERENT
    // action and diagnosing it. This must be a final pass, not incremental: `map cmd+shift+d
    // toggle_split` then `map cmd+d new_session` succeeds (toggle_split moved off cmd+d frees it),
    // and the freed-default case for custom commands below relies on the same final resolution.
    let builtinOverrides = resolveBuiltinOverrides(parsedOverrides, diagnostics: &diagnostics)

    // cross-section validation is a SINGLE final pass over the fully-resolved built-in set, NOT run
    // incrementally during line parsing: a custom line parsed before a later keyless-built-in `map`
    // must still be validated against the override that `map` installs, so all `map`/`command` lines
    // are collected first.
    let keymap = Keymap(builtinOverrides: builtinOverrides, commands: commands)
    let validated = validateCommands(keymap.commands, against: keymap, diagnostics: &diagnostics)

    return (Keymap(builtinOverrides: builtinOverrides, commands: validated), diagnostics)
}

/// A single valid `map` line, retained in file order until the final cross-builtin duplicate pass.
private struct ParsedOverride {
    let action: BuiltinAction
    let chord: Chord
    let line: Int
}

/// Fold the file-order overrides into the final `[BuiltinAction: Chord]`, rejecting only those that
/// produce a TRUE final-state collision: two DISTINCT actions resolving to the same chord. Resolution
/// is order-independent — it is NOT decided against a partially-built map, so `map cmd+d new_session`
/// and `map cmd+shift+d toggle_split` succeed in EITHER order (the final state is conflict-free:
/// new_session=cmd+d, toggle_split moved off cmd+d).
///
/// Algorithm: (1) fold overrides last-wins per action into a candidate map; (2) iterate to a FIXPOINT —
/// each pass computes every action's resolved chord (candidate override, else its default), finds a
/// chord claimed by two distinct actions, and drops one loser. Dropping a loser REVERTS it to its own
/// default, which may collide afresh with another action; the loop re-checks until no collision remains.
/// Loser rule per collision: an override colliding with another action's UNMOVED default loses (keep the
/// default owner); two colliding OVERRIDES → the later-in-file one loses. Each dropped override is
/// diagnosed. The 12 shipped defaults are distinct, so every collision involves at least one override
/// and each iteration removes ≥1 override → the loop terminates. Re-mapping the SAME action is last-wins
/// (it can't collide with itself).
private func resolveBuiltinOverrides(_ overrides: [ParsedOverride],
                                     diagnostics: inout [KeymapDiagnostic]) -> [BuiltinAction: Chord] {
    // (1) candidate overrides folded last-wins; remember the file line of the winning override per
    // action so a two-override collision can name the later one.
    var candidates: [BuiltinAction: Chord] = [:]
    var overrideLine: [BuiltinAction: Int] = [:]
    for override in overrides {
        candidates[override.action] = override.chord
        overrideLine[override.action] = override.line
    }

    // (2) iterate to a fixpoint. each pass drops one collision's loser; dropping reverts it to its
    // default, which the next pass re-checks. drops are remembered (line-sorted at the end) so the
    // emitted diagnostics are deterministic regardless of dictionary iteration order.
    var pending: [(loser: BuiltinAction, keeper: BuiltinAction, line: Int)] = []
    while let drop = firstBuiltinCollision(candidates: candidates, overrideLine: overrideLine) {
        candidates.removeValue(forKey: drop.loser)
        pending.append(drop)
    }

    for drop in pending.sorted(by: { $0.line < $1.line }) {
        diagnostics.append(KeymapDiagnostic(
            line: drop.line,
            message: "chord conflicts with built-in '\(drop.keeper.rawValue)'; map skipped"))
    }

    return candidates
}

/// One iteration of the fixpoint: find the first chord that two distinct actions resolve to (an
/// override colliding with a default, or two overrides), and return the loser to drop, the keeper it
/// collided with, and the loser's file line. Returns nil when the candidate set is collision-free.
private func firstBuiltinCollision(candidates: [BuiltinAction: Chord],
                                   overrideLine: [BuiltinAction: Int])
    -> (loser: BuiltinAction, keeper: BuiltinAction, line: Int)? {
    let resolvedChord: (BuiltinAction) -> Chord? = { action in candidates[action] ?? action.defaultChord }

    var ownersByChord: [Chord: [BuiltinAction]] = [:]
    for action in BuiltinAction.allCases {
        guard let chord = resolvedChord(action) else { continue }
        ownersByChord[chord, default: []].append(action)
    }

    // pick the colliding chord deterministically by its earliest-line loser so the loop is stable.
    var best: (loser: BuiltinAction, keeper: BuiltinAction, line: Int)?
    for owners in ownersByChord.values where owners.count > 1 {
        let overriddenOwners = owners.filter { candidates[$0] != nil }
        let defaultOwners = owners.filter { candidates[$0] == nil }
        let decision: (loser: BuiltinAction, keeper: BuiltinAction)?
        if let defaultOwner = defaultOwners.first, let loser = overriddenOwners.first {
            // an unmoved default keeps the chord; an override that collided with it loses.
            decision = (loser, defaultOwner)
        } else if overriddenOwners.count > 1 {
            // two (or more) overrides claim the same chord: keep the earliest, drop the latest.
            let sorted = overriddenOwners.sorted { (overrideLine[$0] ?? 0) < (overrideLine[$1] ?? 0) }
            decision = (sorted[sorted.count - 1], sorted[0])
        } else {
            decision = nil
        }
        guard let decision else { continue }
        let line = overrideLine[decision.loser] ?? 0
        if best == nil || line < best!.line {
            best = (decision.loser, decision.keeper, line)
        }
    }
    return best
}

/// Cross-section validation: drop a custom keybind whose FIRST chord equals any active built-in chord
/// OR a reserved monitor chord (Ctrl-Tab / Ctrl-1/2), and drop both keybinds of any custom-vs-custom
/// duplicate/prefix conflict. A dropped keybind clears the command's `shortcut` to `""` (the command
/// stays in the palette, unkeyed) and adds a diagnostic.
///
/// Built-ins are single-chord, so any custom bind STARTING with that chord — single or leader — is
/// shadowed by the menu and is dropped. The reserved monitor chords (`isReservedMonitorChord`) are owned
/// by the app's always-on NSEvent monitors, not the menu, and are equally un-rebindable. The active
/// built-in chord set already has every override applied (via `Keymap.equivalent(for:)`), so a custom
/// command may freely reuse a default chord the user moved a built-in off of.
private func validateCommands(_ commands: [CustomCommand], against keymap: Keymap,
                              diagnostics: inout [KeymapDiagnostic]) -> [CustomCommand] {
    // active built-in chords: the override when present, else the shipped default. The keyless and
    // arrow-bound actions contribute a chord only when the user mapped one (defaultChord == nil), so
    // an unmapped arrow default never collides with a (parseable) custom chord.
    let builtinChords = Set(BuiltinAction.allCases.compactMap { keymap.equivalent(for: $0) })

    var result = commands

    // pass 1: drop a custom keybind that collides with a built-in (its FIRST chord — built-ins are
    // single-chord and shadow anything starting with that chord) OR with a reserved monitor chord at
    // ANY position (the monitor consumes its chord wherever it lands in a leader, so a later reserved
    // chord like `ctrl+a>ctrl+1` is just as dead as a leading one). line 0 — the command's source line
    // isn't tracked, so cross-section diagnostics use the whole-file line.
    for index in result.indices {
        let command = result[index]
        guard !command.shortcut.isEmpty, let keybind = parseKeybind(command.shortcut),
              let firstChord = keybind.first else { continue }
        let conflictKind: String?
        if builtinChords.contains(firstChord) {
            conflictKind = "a built-in"
        } else if keybind.contains(where: isReservedMonitorChord) {
            conflictKind = "a reserved shortcut"
        } else {
            conflictKind = nil
        }
        guard let kind = conflictKind else { continue }
        diagnostics.append(KeymapDiagnostic(
            line: 0,
            message: "custom command '\(command.name)' shortcut '\(command.shortcut)' conflicts with \(kind); keybind dropped"))
        result[index].shortcut = ""
    }

    // pass 2: drop BOTH keybinds of any custom-vs-custom duplicate/prefix conflict (computed over the
    // post-pass-1 set so a keybind already dropped in pass 1 can't re-trigger here). One diagnostic per
    // command names the OTHER offender (the conflict carries both ids) so the user can find the pair.
    let conflicts = keybindConflicts(result)
    let nameByID = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0.name) })
    var otherOffender: [UUID: String] = [:]
    for conflict in conflicts {
        otherOffender[conflict.first] = nameByID[conflict.second]
        otherOffender[conflict.second] = nameByID[conflict.first]
    }
    for index in result.indices {
        guard let other = otherOffender[result[index].id] else { continue }
        diagnostics.append(KeymapDiagnostic(
            line: 0,
            message: "custom command '\(result[index].name)' shortcut '\(result[index].shortcut)' conflicts with custom command '\(other)'; keybind dropped"))
        result[index].shortcut = ""
    }

    return result
}

/// Strip a trailing inline comment: a `#` is a comment when it is preceded by whitespace AND sits
/// outside a quoted span (single OR double). A leading `#` (the whole-line comment) is handled by the
/// caller, but it also falls out here since position 0 has no preceding whitespace only when the line
/// starts with `#` after trimming — the caller trims and re-checks emptiness, so a `# ...` line becomes
/// empty. Single quotes matter because a shell line like `git commit -m 'fix #42'` must keep its `#`;
/// the two quote states are mutually exclusive (a `"` inside `'...'` is literal, and vice versa).
private func stripComment(_ line: String) -> String {
    var inSingleQuotes = false
    var inDoubleQuotes = false
    var previousWasSpace = true // start-of-line counts as preceded-by-whitespace, so a leading `#` cuts
    var result = ""
    for ch in line {
        if ch == "\"" && !inSingleQuotes {
            inDoubleQuotes.toggle()
            result.append(ch)
            previousWasSpace = false
            continue
        }
        if ch == "'" && !inDoubleQuotes {
            inSingleQuotes.toggle()
            result.append(ch)
            previousWasSpace = false
            continue
        }
        if ch == "#" && !inSingleQuotes && !inDoubleQuotes && previousWasSpace {
            break
        }
        result.append(ch)
        previousWasSpace = ch.isWhitespace
    }
    return result
}

/// Parse the remainder of a `map` line (everything after the `map` verb): `<chord> <action>`. On
/// success it appends a `ParsedOverride` (in file order); on any failure it appends a diagnostic and
/// leaves `overrides` untouched. Cross-builtin duplicate detection is deferred to
/// `resolveBuiltinOverrides` (a final pass over the resolved active chord set).
private func parseMapLine(_ rest: String, line: Int, overrides: inout [ParsedOverride],
                          diagnostics: inout [KeymapDiagnostic]) {
    // split on the first run of general whitespace (space OR tab) so a tab-separated `map` line works.
    let chordText = String(rest.prefix(while: { !$0.isWhitespace }))
    let actionName = String(rest.dropFirst(chordText.count)).trimmingCharacters(in: .whitespaces)
    guard !chordText.isEmpty, !actionName.isEmpty else {
        diagnostics.append(KeymapDiagnostic(line: line, message: "map requires a chord and an action"))
        return
    }

    guard let keybind = parseKeybind(chordText) else {
        diagnostics.append(KeymapDiagnostic(line: line, message: "invalid chord '\(chordText)'"))
        return
    }
    guard keybind.count == 1, let chord = keybind.first else {
        diagnostics.append(KeymapDiagnostic(line: line, message: "built-in shortcut cannot be a leader sequence"))
        return
    }
    // a chord owned by an always-on NSEvent monitor (Ctrl-Tab / Ctrl-1/2) can't be a menu key-equivalent
    // without dead-racing the monitor, so reject it for built-ins exactly as for custom commands.
    guard !isReservedMonitorChord(chord) else {
        diagnostics.append(KeymapDiagnostic(line: line, message: "chord '\(chordText)' is a reserved shortcut; map skipped"))
        return
    }
    guard let action = BuiltinAction(rawValue: actionName) else {
        diagnostics.append(KeymapDiagnostic(line: line, message: "unknown action '\(actionName)'"))
        return
    }
    overrides.append(ParsedOverride(action: action, chord: chord, line: line))
}

/// Parse the remainder of a `command` line (everything after the `command` verb):
/// `"<name>" [chord] <shell...>`. On any failure it appends a diagnostic and leaves `commands`
/// untouched.
private func parseCommandLine(_ rest: String, line: Int, commands: inout [CustomCommand],
                              diagnostics: inout [KeymapDiagnostic]) {
    guard rest.first == "\"", let closeQuote = rest.dropFirst().firstIndex(of: "\"") else {
        diagnostics.append(KeymapDiagnostic(line: line, message: "command requires a quoted name"))
        return
    }
    let name = String(rest[rest.index(after: rest.startIndex)..<closeQuote])
    let afterName = String(rest[rest.index(after: closeQuote)...]).trimmingCharacters(in: .whitespaces)

    // the token right after the closing quote is the chord iff parseKeybind accepts it AND it carries
    // a modifier; otherwise the whole remainder is the shell line (palette-only). a modifier is
    // required so a custom shortcut can't be a bare key that shadows that key in the terminal — and so
    // a palette-only shell line that happens to start with a single-char token (`[`, `:`, a one-letter
    // alias) isn't silently swallowed as a binding.
    let firstToken = String(afterName.prefix(while: { !$0.isWhitespace }))
    var shortcut = ""
    var shellLine = afterName
    if !firstToken.isEmpty, let keybind = parseKeybind(firstToken) {
        if keybind.first?.mods.isEmpty == false {
            shortcut = firstToken
            shellLine = String(afterName.dropFirst(firstToken.count)).trimmingCharacters(in: .whitespaces)
        } else {
            diagnostics.append(KeymapDiagnostic(line: line,
                message: "command '\(name)' shortcut '\(firstToken)' must include a modifier; treating the line as palette-only"))
        }
    }

    // an empty shell line (just a name, or a name + chord with no command) is a no-op binding; skip it.
    guard !shellLine.trimmingCharacters(in: .whitespaces).isEmpty else {
        diagnostics.append(KeymapDiagnostic(line: line, message: "command '\(name)' has no shell line"))
        return
    }

    commands.append(CustomCommand(name: name, command: shellLine, shortcut: shortcut))
}
