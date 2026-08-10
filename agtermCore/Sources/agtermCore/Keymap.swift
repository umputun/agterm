import Foundation

/// The parsed `keymap.conf`. A built-in override is the single chord the menu carries; a custom command's
/// `shortcut` may be empty (palette-only) or hold `|`-separated alternatives, each a chord or a leader
/// sequence.
public struct Keymap: Equatable, Sendable {
    public let builtinOverrides: [BuiltinAction: Chord]
    public let commands: [CustomCommand]
    /// The built-in binds an `NSMenuItem` cannot carry — a leader sequence, or a second chord where a menu
    /// item holds exactly one key equivalent — dispatched by the app's key monitor instead.
    public let builtinSequences: [BuiltinAction: [Keybind]]
    /// Actions whose `map` line offered no menu-bindable alternative. Distinct from ABSENT, which means
    /// "keep the shipped default": without this, `map ctrl+space>s toggle_split` would leave ⌘D live.
    public let builtinUnbound: Set<BuiltinAction>

    public init(builtinOverrides: [BuiltinAction: Chord], commands: [CustomCommand],
                builtinSequences: [BuiltinAction: [Keybind]] = [:],
                builtinUnbound: Set<BuiltinAction> = []) {
        self.builtinOverrides = builtinOverrides
        self.commands = commands
        self.builtinSequences = builtinSequences
        self.builtinUnbound = builtinUnbound
    }

    /// The active menu chord for a built-in: the user override, else the shipped `defaultChord` — `nil` for
    /// the keyless actions and for one a `map` line left explicitly unbound.
    public func equivalent(for action: BuiltinAction) -> Chord? {
        if let override = builtinOverrides[action] { return override }
        return builtinUnbound.contains(action) ? nil : action.defaultChord
    }

    /// The monitor-bound binds for a built-in, empty when it has none.
    public func sequences(for action: BuiltinAction) -> [Keybind] {
        builtinSequences[action] ?? []
    }

    /// The action's whole binding set as macOS menu glyphs, the menu chord first and each monitor-bound
    /// alternative after it, space-separated (`⌘T ⌃␣S`); `nil` means "not configured", the caller showing no
    /// shortcut. Drives palette hints and toolbar tooltips alike.
    public func glyphHint(for action: BuiltinAction) -> String? {
        let parts = (equivalent(for: action).map { [$0.glyphString] } ?? []) + sequences(for: action).map(\.glyphString)
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// A problem found while parsing `keymap.conf`. `line` is 1-based; `0` is a whole-file or cross-section
/// diagnostic belonging to no single line.
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

/// Parse the text of a `keymap.conf` into a `Keymap` plus diagnostics. Never throws: a bad line becomes a
/// diagnostic and is skipped, so one malformed line never discards the rest of the file.
///
/// Grammar (kitty-flavored), line-based. Blank and `#`-comment lines are ignored; `stripComment` owns the
/// inline-comment rule. The first whitespace-token is the verb:
/// - `map <chord> <action>`: `<chord>` goes through `parseKeybinds`, so it may carry `|`-separated
///   alternatives; the first menu-bindable single chord becomes the key equivalent and the rest are
///   monitor-bound. `<action>` must be a `BuiltinAction` raw value. Collisions are resolved
///   order-INDEPENDENTLY against the final chord set, see `resolveBuiltinOverrides`.
/// - `command "<name>" [chord] <shell...>`: `<name>` is a required double-quoted string (spaces allowed).
///   The token right after the closing quote is the shortcut IFF `parseKeybinds` accepts it, `|`-separated
///   alternatives included; otherwise the whole remainder is the shell line (palette-only), keeping
///   `{AGT_X}` tokens verbatim.
/// - anything else is an unknown verb, skipped with a diagnostic.
///
/// A SINGLE final cross-section pass (`validateBindings`) then drops any monitor-bound alternative, from
/// either verb, that collides with an active built-in menu chord or with another alternative — one diagnostic
/// each, siblings untouched. A custom command that loses every alternative stays, palette-only.
public func parseKeymap(_ text: String) -> (keymap: Keymap, diagnostics: [KeymapDiagnostic]) {
    // collected in file order, NOT folded into a dict yet, so the final duplicate pass resolves them
    // against the FULLY-resolved chord set and can skip the later-in-file member of a colliding pair.
    var mapLines: [ParsedMapLine] = []
    var commands: [CustomCommand] = []
    var diagnostics: [KeymapDiagnostic] = []

    // normalize line endings: a CRLF leaves a trailing `\r` that .whitespaces won't strip (so
    // `toggle_split\r` reads as an unknown action) and a lone-CR file would collapse into one line.
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
            parseMapLine(rest, line: lineNumber, mapLines: &mapLines, diagnostics: &diagnostics)
        case "command":
            parseCommandLine(rest, line: lineNumber, commands: &commands, diagnostics: &diagnostics)
        default:
            diagnostics.append(KeymapDiagnostic(line: lineNumber, message: "unknown verb '\(verb)'"))
        }
    }

    // a final pass, not incremental: the cross-section validation below needs the same resolved chord set.
    let resolved = resolveMapLines(mapLines)
    let builtinOverrides = resolveBuiltinOverrides(resolved.overrides, unbound: resolved.unbound,
                                                   binds: resolved.sequences, diagnostics: &diagnostics)

    // likewise final: a custom line parsed before a later keyless-built-in `map` must still be validated
    // against the override that `map` installs.
    let menuChords = Set(BuiltinAction.allCases.compactMap {
        resolvedMenuChord($0, overrides: builtinOverrides, unbound: resolved.unbound)
    })
    let survivors = validateBindings(monitorAlternatives(commands: commands, binds: resolved.sequences),
                                     menuChords: menuChords, diagnostics: &diagnostics)
    let builtinSequences = survivingSequences(survivors)

    return (Keymap(builtinOverrides: builtinOverrides,
                   commands: applySurvivingShortcuts(to: commands, survivors: survivors),
                   builtinSequences: builtinSequences,
                   builtinUnbound: restoreStrandedDefaults(resolved.unbound, overrides: builtinOverrides,
                                                           sequences: builtinSequences, survivors: survivors)),
            diagnostics)
}

/// The menu chord an action resolves to against a given override set — the parse-time spelling of
/// `Keymap.equivalent(for:)`, shared by the built-in collision fixpoint and the cross-section chord set.
private func resolvedMenuChord(_ action: BuiltinAction, overrides: [BuiltinAction: Chord],
                               unbound: Set<BuiltinAction>) -> Chord? {
    if let chord = overrides[action] { return chord }
    return unbound.contains(action) ? nil : action.defaultChord
}

/// A single valid `map` line: the menu-bindable alternative if it has one, plus the monitor-bound rest,
/// each carrying the raw substring it was written as.
private struct ParsedMapLine {
    let action: BuiltinAction
    let chord: Chord?
    let sequences: [(raw: String, keybind: Keybind)]
    let line: Int
}

/// One `map` line's monitor-bound alternatives held until the cross-section pass, with the line to report a
/// drop on and whether the line offered more than this one bind — the two things the diagnostics need beyond
/// the binds themselves.
private struct MapLineBinds {
    let line: Int
    let hasSiblings: Bool
    let alternatives: [(raw: String, keybind: Keybind)]
}

/// A menu-bound `map` alternative, retained in file order until the final cross-builtin duplicate pass.
private struct ParsedOverride {
    let action: BuiltinAction
    let chord: Chord
    let line: Int
}

/// Fold the file-order `map` lines to one per action and split them by dispatch path. A `map` line declares
/// an action's WHOLE binding set, so a later line replaces the earlier one's menu chord and sequences
/// together — including replacing a menu chord with nothing, which is what `unbound` records.
private func resolveMapLines(_ mapLines: [ParsedMapLine])
    -> (overrides: [ParsedOverride], sequences: [BuiltinAction: MapLineBinds], unbound: Set<BuiltinAction>) {
    var latest: [BuiltinAction: ParsedMapLine] = [:]
    for mapLine in mapLines { latest[mapLine.action] = mapLine }

    var overrides: [ParsedOverride] = []
    var sequences: [BuiltinAction: MapLineBinds] = [:]
    var unbound: Set<BuiltinAction> = []
    for mapLine in latest.values.sorted(by: { $0.line < $1.line }) {
        if let chord = mapLine.chord {
            overrides.append(ParsedOverride(action: mapLine.action, chord: chord, line: mapLine.line))
        } else {
            unbound.insert(mapLine.action)
        }
        guard !mapLine.sequences.isEmpty else { continue }
        let hasSiblings = mapLine.chord != nil || mapLine.sequences.count > 1
        sequences[mapLine.action] = MapLineBinds(line: mapLine.line, hasSiblings: hasSiblings,
                                                 alternatives: mapLine.sequences)
    }
    return (overrides, sequences, unbound)
}

/// Fold the file-order overrides into the final `[BuiltinAction: Chord]`, rejecting only a TRUE
/// final-state collision: two DISTINCT actions resolving to the same chord. Order-independent — NOT
/// decided against a partially-built map — so moving a built-in off a chord and another claiming it
/// succeed in EITHER line order. Re-mapping the SAME action is last-wins and can't collide with itself.
///
/// Fold last-wins per action, then iterate to a FIXPOINT, since a dropped loser REVERTS to its own default
/// and may collide afresh. An override colliding with another action's UNMOVED default loses; two
/// colliding OVERRIDES drop the later-in-file one; each drop is diagnosed. The shipped defaults are all
/// distinct (pinned by `BuiltinActionTests`), so every collision involves ≥1 override and each iteration
/// removes one — the loop terminates.
///
/// `unbound` is the set of actions a `map` line left with no menu chord at all; they occupy nothing, so
/// another built-in may claim the default they no longer use. `binds` names the lines that also carry
/// monitor-bound alternatives, which this pass never touches — only a line offering nothing else is skipped
/// whole.
private func resolveBuiltinOverrides(_ overrides: [ParsedOverride], unbound: Set<BuiltinAction>,
                                     binds: [BuiltinAction: MapLineBinds],
                                     diagnostics: inout [KeymapDiagnostic]) -> [BuiltinAction: Chord] {
    // fold last-wins, remembering each winner's file line so a two-override collision can name the later.
    var candidates: [BuiltinAction: Chord] = [:]
    var overrideLine: [BuiltinAction: Int] = [:]
    for override in overrides {
        candidates[override.action] = override.chord
        overrideLine[override.action] = override.line
    }

    // one loser per pass. drops are line-sorted at the end so diagnostics don't depend on dictionary order.
    var pending: [(loser: BuiltinAction, keeper: BuiltinAction, line: Int)] = []
    while let drop = firstBuiltinCollision(candidates: candidates, unbound: unbound, overrideLine: overrideLine) {
        candidates.removeValue(forKey: drop.loser)
        pending.append(drop)
    }

    for drop in pending.sorted(by: { $0.line < $1.line }) {
        let scope = binds[drop.loser] == nil ? "map skipped" : "alternative skipped"
        diagnostics.append(KeymapDiagnostic(
            line: drop.line,
            message: "chord conflicts with built-in '\(drop.keeper.rawValue)'; \(scope)"))
    }

    return candidates
}

/// One fixpoint iteration: the first chord two distinct actions resolve to, returned as the loser to drop,
/// the keeper, and the loser's file line. nil when the candidate set is collision-free.
private func firstBuiltinCollision(candidates: [BuiltinAction: Chord], unbound: Set<BuiltinAction>,
                                   overrideLine: [BuiltinAction: Int])
    -> (loser: BuiltinAction, keeper: BuiltinAction, line: Int)? {
    // an unbound action holds no chord, so its shipped default stops blocking another built-in. It has no
    // candidate to drop either, which keeps the loop terminating.
    var ownersByChord: [Chord: [BuiltinAction]] = [:]
    for action in BuiltinAction.allCases {
        guard let chord = resolvedMenuChord(action, overrides: candidates, unbound: unbound) else { continue }
        ownersByChord[chord, default: []].append(action)
    }

    // pick the colliding chord deterministically by its earliest-line loser so the loop is stable.
    var best: (loser: BuiltinAction, keeper: BuiltinAction, line: Int)?
    for owners in ownersByChord.values where owners.count > 1 {
        let overriddenOwners = owners.filter { candidates[$0] != nil }
        let defaultOwners = owners.filter { candidates[$0] == nil }
        let decision: (loser: BuiltinAction, keeper: BuiltinAction)?
        if let defaultOwner = defaultOwners.first, let loser = overriddenOwners.first {
            decision = (loser, defaultOwner)
        } else if overriddenOwners.count > 1 {
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

/// One monitor-bound alternative entering the cross-section passes: its owner, the raw spelling to quote back,
/// the parsed keybind the passes compare, and the line to report a drop on — `0` for a custom command, whose
/// source line is not tracked.
private struct MonitorAlternative {
    let target: KeybindTarget
    let ownerName: String
    let raw: String
    let keybind: Keybind
    /// Whether the owner offered more than this one bind. The only thing separating the whole-binding wording
    /// from the per-alternative one, so a single-alternative binding carries no scope suffix.
    let hasSiblings: Bool
    let line: Int

    var owner: String {
        switch target {
        case .command: return "custom command '\(ownerName)'"
        case .builtin: return "built-in '\(ownerName)'"
        }
    }

    var subject: String {
        switch target {
        case .command: return "\(owner) shortcut '\(raw)'"
        case .builtin: return "\(owner) chord '\(raw)'"
        }
    }

    var scope: String { hasSiblings ? "alternative dropped" : "keybind dropped" }
}

/// Every monitor-bound alternative of both verbs, custom commands first and `map` lines in file order — the
/// records the cross-section passes compare, drop and quote back.
private func monitorAlternatives(commands: [CustomCommand],
                                 binds: [BuiltinAction: MapLineBinds]) -> [MonitorAlternative] {
    var alternatives: [MonitorAlternative] = []
    for command in commands {
        guard !command.shortcut.isEmpty, let parsed = alternativeKeybinds(command.shortcut) else { continue }
        alternatives += parsed.map {
            MonitorAlternative(target: .command(command.id), ownerName: command.name, raw: $0.raw,
                               keybind: $0.keybind, hasSiblings: parsed.count > 1, line: 0)
        }
    }
    for (action, entry) in binds.sorted(by: { $0.value.line < $1.value.line }) {
        alternatives += entry.alternatives.map {
            MonitorAlternative(target: .builtin(action), ownerName: action.rawValue, raw: $0.raw,
                               keybind: $0.keybind, hasSiblings: entry.hasSiblings, line: entry.line)
        }
    }
    return alternatives
}

/// Cross-section validation over every monitor-bound alternative of both verbs, returning the survivors: drop
/// one whose FIRST chord equals an active built-in menu chord or that uses a reserved monitor chord
/// (Ctrl-Tab / Ctrl-1/2), then drop the later side of any duplicate/prefix conflict among the rest. Only the
/// offending alternative goes — its siblings keep firing, which is the whole point of offering alternatives.
///
/// Built-in menu chords are single, so any bind STARTING with one, single or leader, is shadowed by the menu.
/// Built-in monitor alternatives face the same two tests as custom ones: `map cmd+t|cmd+t>s toggle_split` would
/// otherwise arm the monitor on the very chord that line puts on the menu. `menuChords` already has every
/// override applied, so a bind may freely reuse a default chord the user moved a built-in off of.
private func validateBindings(_ alternatives: [MonitorAlternative], menuChords: Set<Chord>,
                              diagnostics: inout [KeymapDiagnostic]) -> [MonitorAlternative] {
    // pass 1: a built-in collides on the FIRST chord only, a reserved monitor chord at ANY position — the
    // monitor consumes its chord wherever it lands in a leader, so `ctrl+a>ctrl+1` is just as dead as a
    // leading one.
    var kept: [MonitorAlternative] = []
    for alternative in alternatives {
        let conflictKind: String?
        if let first = alternative.keybind.first, menuChords.contains(first) {
            conflictKind = "a built-in"
        } else if alternative.keybind.contains(where: isReservedMonitorChord) {
            conflictKind = "a reserved shortcut"
        } else {
            conflictKind = nil
        }
        guard let kind = conflictKind else {
            kept.append(alternative)
            continue
        }
        diagnostics.append(KeymapDiagnostic(
            line: alternative.line,
            message: "\(alternative.subject) conflicts with \(kind); \(alternative.scope)"))
    }

    // pass 2: computed over the post-pass-1 set so an alternative dropped there can't re-trigger. each
    // diagnostic names the OTHER offender (the conflict carries both sides) so the user can find the pair.
    // a target's alternatives are deduped, so target plus keybind locates exactly one of them.
    var position: [KeybindConflict.Side: Int] = [:]
    for (index, alternative) in kept.enumerated() {
        position[KeybindConflict.Side(target: alternative.target, keybind: alternative.keybind)] = index
    }
    var otherOffender: [Int: String] = [:]
    for conflict in keybindConflicts(kept.map { (keybind: $0.keybind, target: $0.target) }) {
        guard let first = position[conflict.first], let second = position[conflict.second] else { continue }
        otherOffender[second] = kept[first].owner
        // one binding's own alternatives can collide (`ctrl+a|ctrl+a>b`). Both fire the same thing, so the
        // ambiguity costs the user nothing and dropping the pair would take away a working key for it.
        guard conflict.first.target != conflict.second.target else { continue }
        otherOffender[first] = kept[second].owner
    }

    var survivors: [MonitorAlternative] = []
    for (index, alternative) in kept.enumerated() {
        guard let other = otherOffender[index] else {
            survivors.append(alternative)
            continue
        }
        diagnostics.append(KeymapDiagnostic(
            line: alternative.line,
            message: "\(alternative.subject) conflicts with \(other); \(alternative.scope)"))
    }
    return survivors
}

/// The surviving monitor-bound binds per built-in, in file order.
private func survivingSequences(_ survivors: [MonitorAlternative]) -> [BuiltinAction: [Keybind]] {
    var sequences: [BuiltinAction: [Keybind]] = [:]
    for survivor in survivors {
        guard case .builtin(let action) = survivor.target else { continue }
        sequences[action, default: []].append(survivor.keybind)
    }
    return sequences
}

/// Rewrite each keyed command's shortcut from the raw substrings its alternatives kept, splicing rather than
/// re-rendering so the user's own spelling survives. A command that lost every alternative ends up with
/// `shortcut == ""`, staying in the palette unkeyed.
private func applySurvivingShortcuts(to commands: [CustomCommand],
                                     survivors: [MonitorAlternative]) -> [CustomCommand] {
    var raws: [UUID: [String]] = [:]
    for survivor in survivors {
        guard case .command(let id) = survivor.target else { continue }
        raws[id, default: []].append(survivor.raw)
    }
    var result = commands
    for index in result.indices where !result[index].shortcut.isEmpty {
        result[index].shortcut = (raws[result[index].id] ?? []).joined(separator: "|")
    }
    return result
}

/// An action whose `map` line lost EVERY bind in the cross-section passes goes back to its shipped default,
/// exactly as one rejected while parsing does: the line bound nothing, so leaving the action keyless would
/// take away a chord the file never asked to move. Skipped when something else already holds that chord,
/// which being unbound is what permitted — the passes above ran against a chord set this action had vacated.
private func restoreStrandedDefaults(_ unbound: Set<BuiltinAction>, overrides: [BuiltinAction: Chord],
                                     sequences: [BuiltinAction: [Keybind]],
                                     survivors: [MonitorAlternative]) -> Set<BuiltinAction> {
    let stranded = unbound.filter { sequences[$0] == nil }
    guard !stranded.isEmpty else { return unbound }

    var occupied = Set(survivors.compactMap(\.keybind.first))
    for action in BuiltinAction.allCases where !stranded.contains(action) {
        guard let chord = resolvedMenuChord(action, overrides: overrides, unbound: unbound) else { continue }
        occupied.insert(chord)
    }
    // the shipped defaults are all distinct, so two stranded actions can never want the same chord.
    return unbound.subtracting(stranded.filter { action in
        guard let chord = action.defaultChord else { return false }
        return !occupied.contains(chord)
    })
}

/// Strip a trailing inline comment: a `#` counts only when preceded by whitespace AND outside a quoted
/// span, single OR double. A whole-line `#` comment falls out here too, leaving an empty line for the
/// caller. Single quotes matter so a shell line like `git commit -m 'fix #42'` keeps its `#`; the two
/// quote states are mutually exclusive (a `"` inside `'...'` is literal, and vice versa).
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

/// Parse a `map` line's remainder, `<chord> <action>`: on success appends a `ParsedMapLine` in file order,
/// on any failure a diagnostic, leaving `mapLines` untouched. Cross-builtin duplicate detection is deferred
/// to `resolveBuiltinOverrides`.
///
/// The chord token may hold `|`-separated alternatives. The first one that can be a menu key equivalent —
/// a single chord passing today's `map` rules — becomes it; every other alternative is monitor-bound and
/// follows the monitor's own rule instead. The grammar therefore tracks the DISPATCH PATH, not the verb.
/// A malformed alternative kills the whole line (`alternativeKeybinds` returns nil), while an alternative
/// breaking a rule drops alone; a line whose every alternative dropped records nothing at all, leaving the
/// action on its shipped default, which is also what a rejected single-chord `map` does.
private func parseMapLine(_ rest: String, line: Int, mapLines: inout [ParsedMapLine],
                          diagnostics: inout [KeymapDiagnostic]) {
    // split on the first run of general whitespace (space OR tab) so a tab-separated `map` line works.
    let chordText = String(rest.prefix(while: { !$0.isWhitespace }))
    let actionName = String(rest.dropFirst(chordText.count)).trimmingCharacters(in: .whitespaces)
    guard !chordText.isEmpty, !actionName.isEmpty else {
        diagnostics.append(KeymapDiagnostic(line: line, message: "map requires a chord and an action"))
        return
    }

    guard let alternatives = alternativeKeybinds(chordText) else {
        diagnostics.append(KeymapDiagnostic(line: line, message: "invalid chord '\(chordText)'"))
        return
    }

    // with one alternative a drop IS the line's failure, so its wording carries no per-alternative scope.
    let scope = alternatives.count == 1 ? "map skipped" : "alternative skipped"
    var menuChord: Chord?
    var sequences: [(raw: String, keybind: Keybind)] = []
    for alternative in alternatives {
        // a chord owned by an always-on NSEvent monitor can't be a menu key-equivalent without dead-racing
        // the monitor, and is just as dead deeper in a sequence, so reject it at any position.
        guard !alternative.keybind.contains(where: isReservedMonitorChord) else {
            diagnostics.append(KeymapDiagnostic(line: line,
                                                message: "chord '\(alternative.raw)' is a reserved shortcut; \(scope)"))
            continue
        }
        if menuChord == nil, alternative.keybind.count == 1, let chord = alternative.keybind.first {
            // a modifier-less arrow would install an always-on menu key-equivalent swallowing the key
            // everywhere — terminal, palettes, dashboard grid, every text field — and the menu path, unlike
            // the custom-command monitor, has no text-field pass-through.
            guard !(bindableArrowKeys.contains(chord.key) && chord.mods.isEmpty) else {
                diagnostics.append(KeymapDiagnostic(line: line,
                                                    message: "bare arrow chord '\(alternative.raw)' needs a modifier; \(scope)"))
                continue
            }
            menuChord = chord
            continue
        }
        // monitor-bound: a bare first chord would be swallowed everywhere in the terminal, the rule
        // `parseCommandLine` already applies to every custom shortcut.
        guard alternative.keybind.first?.mods.isEmpty == false else {
            diagnostics.append(KeymapDiagnostic(line: line,
                                                message: "chord '\(alternative.raw)' needs a modifier on its first key; \(scope)"))
            continue
        }
        sequences.append(alternative)
    }

    // nothing survived: report no action diagnostic on top of the per-alternative ones, as before.
    guard menuChord != nil || !sequences.isEmpty else { return }
    guard let action = BuiltinAction(rawValue: actionName) else {
        diagnostics.append(KeymapDiagnostic(line: line, message: "unknown action '\(actionName)'"))
        return
    }
    mapLines.append(ParsedMapLine(action: action, chord: menuChord, sequences: sequences, line: line))
}

/// Parse the remainder of a `command` line (after the verb): `"<name>" [chord] <shell...>`. On any failure
/// it appends a diagnostic and leaves `commands` untouched.
private func parseCommandLine(_ rest: String, line: Int, commands: inout [CustomCommand],
                              diagnostics: inout [KeymapDiagnostic]) {
    guard rest.first == "\"", let closeQuote = rest.dropFirst().firstIndex(of: "\"") else {
        diagnostics.append(KeymapDiagnostic(line: line, message: "command requires a quoted name"))
        return
    }
    let name = String(rest[rest.index(after: rest.startIndex)..<closeQuote])
    let afterName = String(rest[rest.index(after: closeQuote)...]).trimmingCharacters(in: .whitespaces)

    // EVERY alternative's first chord must carry a modifier: a bare key would shadow that key in the
    // terminal, and a palette-only shell line starting with a single-char token (`[`, `:`, a one-letter
    // alias) would be swallowed as a binding. One alternative failing that drops alone, as on a `map` line;
    // the token stays shell only when NOTHING in it is bindable, which is what keeps `command "x" a|b echo`
    // running the same shell line it always did.
    let firstToken = String(afterName.prefix(while: { !$0.isWhitespace }))
    var shortcut = ""
    var shellLine = afterName
    if !firstToken.isEmpty, let alternatives = alternativeKeybinds(firstToken) {
        let kept = alternatives.filter { $0.keybind.first?.mods.isEmpty == false }
        if kept.isEmpty {
            diagnostics.append(KeymapDiagnostic(line: line,
                message: "command '\(name)' shortcut '\(firstToken)' must include a modifier; treating the line as palette-only"))
        } else {
            for dropped in alternatives where dropped.keybind.first?.mods.isEmpty != false {
                diagnostics.append(KeymapDiagnostic(line: line,
                    message: "command '\(name)' shortcut '\(dropped.raw)' must include a modifier; alternative skipped"))
            }
            shortcut = kept.map(\.raw).joined(separator: "|")
            shellLine = String(afterName.dropFirst(firstToken.count)).trimmingCharacters(in: .whitespaces)
        }
    } else if hasMalformedAlternative(firstToken) {
        // a token mixing a real alternative with a malformed one is a typo, not a shell line. Saying so is
        // what keeps a malformed alternative from hiding inside the command instead of killing the binding.
        diagnostics.append(KeymapDiagnostic(line: line,
            message: "command '\(name)' shortcut '\(firstToken)' has an invalid alternative; treating the line as palette-only"))
    }

    // an empty shell line (just a name, or a name + chord with no command) is a no-op binding; skip it.
    guard !shellLine.trimmingCharacters(in: .whitespaces).isEmpty else {
        diagnostics.append(KeymapDiagnostic(line: line, message: "command '\(name)' has no shell line"))
        return
    }

    commands.append(CustomCommand(name: name, command: shellLine, shortcut: shortcut))
}
