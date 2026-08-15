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
    /// The system-wide chord that summons the quick terminal, nil when the file binds none. Registered with
    /// the OS rather than the app's local monitor, so it deliberately takes NO part in the conflict model:
    /// it never reaches `KeybindMatcher`, and a chord it shares with a menu item resolves by which app is
    /// frontmost. One chord only — no alternatives, no leader sequence, since neither is expressible to
    /// `RegisterEventHotKey`.
    public let globalHotkey: Chord?

    public init(builtinOverrides: [BuiltinAction: Chord], commands: [CustomCommand],
                builtinSequences: [BuiltinAction: [Keybind]] = [:],
                builtinUnbound: Set<BuiltinAction> = [],
                globalHotkey: Chord? = nil) {
        self.builtinOverrides = builtinOverrides
        self.commands = commands
        self.builtinSequences = builtinSequences
        self.builtinUnbound = builtinUnbound
        self.globalHotkey = globalHotkey
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
    /// alternative after it, space-separated (`⌘T ⌃␣>S`); `nil` means "not configured", the caller showing no
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
/// Line-based and kitty-flavored. Blank and `#`-comment lines are ignored (`stripComment` owns the inline
/// rule); the first whitespace token is the verb, `map` or `command`, each owning its own grammar in
/// `parseMapLine` / `parseCommandLine`. Anything else is skipped with a diagnostic.
///
/// Four passes then run over the whole file: `resolveMapLines` folds the `map` lines last-wins to one per
/// action, `resolveBuiltinOverrides` settles built-in-versus-built-in menu chord collisions, `validateBindings`
/// settles every monitor-bound alternative of both verbs against the resulting chord set, and
/// `unboundAfterRestoringStrandedDefaults` hands its default back to an action that ended up with nothing.
/// Only `validateBindings` is order-independent; the first two are order-sensitive by design and by defect
/// respectively (`docs/backlog/builtin-override-collisions-depend-on-line-order.md`).
public func parseKeymap(_ text: String) -> (keymap: Keymap, diagnostics: [KeymapDiagnostic]) {
    // collected in file order, NOT folded into a dict yet, so the final duplicate pass resolves them
    // against the FULLY-resolved chord set and can skip the later-in-file member of a colliding pair.
    var mapLines: [ParsedMapLine] = []
    var commandLines: [ParsedCommandLine] = []
    var diagnostics: [KeymapDiagnostic] = []
    // last-wins like `map`, but with no cross-line resolution to run afterwards: an OS-registered chord
    // collides with nothing agterm owns.
    var globalHotkey: Chord?

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
            parseCommandLine(rest, line: lineNumber, commandLines: &commandLines, diagnostics: &diagnostics)
        case "global-hotkey":
            parseGlobalHotkeyLine(rest, line: lineNumber, hotkey: &globalHotkey, diagnostics: &diagnostics)
        default:
            diagnostics.append(KeymapDiagnostic(line: lineNumber, message: "unknown verb '\(verb)'"))
        }
    }

    // a final pass, not incremental: the cross-section validation below needs the same resolved chord set.
    let resolved = resolveMapLines(mapLines)
    // Cmd-Shift-D belonged to Dashboard before horizontal split existed. Any valid old configuration that
    // explicitly used that chord keeps it: vacate the new action's default unless the file maps that action.
    var compatibilityUnbound = resolved.unbound
    let horizontalMapped = resolved.overrides.contains { $0.action == .toggleHorizontalSplit }
        || resolved.alternatives[.toggleHorizontalSplit] != nil
        || resolved.unbound.contains(.toggleHorizontalSplit)
    let oldDashboardChord = Chord(mods: [.command, .shift], key: "d")
    let oldConfigUsesHorizontalChord = resolved.overrides.contains {
        $0.action != .toggleHorizontalSplit && $0.chord == oldDashboardChord
    } || resolved.alternatives.contains { action, entry in
        action != .toggleHorizontalSplit && entry.alternatives.contains { $0.keybind.first == oldDashboardChord }
    } || commandLines.contains { line in
        line.alternatives.contains { $0.keybind.first == oldDashboardChord }
    }
    if !horizontalMapped, oldConfigUsesHorizontalChord {
        compatibilityUnbound.insert(.toggleHorizontalSplit)
    }
    // Cmd-Shift-G was previously free. An existing explicit binding on it keeps working; Dashboard becomes
    // keyless until the user maps it, instead of a new shipped default invalidating their configuration.
    let newDashboardChord = Chord(mods: [.command, .shift], key: "g")
    let dashboardMapped = resolved.overrides.contains { $0.action == .dashboard }
        || resolved.alternatives[.dashboard] != nil || resolved.unbound.contains(.dashboard)
    let oldConfigUsesNewDashboardChord = resolved.overrides.contains {
        $0.action != .dashboard && $0.chord == newDashboardChord
    } || resolved.alternatives.contains { action, entry in
        action != .dashboard && entry.alternatives.contains { $0.keybind.first == newDashboardChord }
    } || commandLines.contains { line in
        line.alternatives.contains { $0.keybind.first == newDashboardChord }
    }
    if !dashboardMapped, oldConfigUsesNewDashboardChord { compatibilityUnbound.insert(.dashboard) }
    let builtinOverrides = resolveBuiltinOverrides(resolved.overrides, unbound: compatibilityUnbound,
                                                   alternatives: resolved.alternatives, diagnostics: &diagnostics)

    // likewise final: a custom line parsed before a later keyless-built-in `map` must still be validated
    // against the override that `map` installs.
    let menuChords = Set(BuiltinAction.allCases.compactMap {
        resolvedMenuChord($0, overrides: builtinOverrides, unbound: compatibilityUnbound)
    })
    let survivors = validateBindings(monitorAlternatives(commandLines: commandLines,
                                                         mapAlternatives: resolved.alternatives),
                                     menuChords: menuChords, diagnostics: &diagnostics)

    return (Keymap(builtinOverrides: builtinOverrides,
                   commands: applySurvivingShortcuts(to: commandLines, survivors: survivors),
                   builtinSequences: survivingAlternatives(survivors),
                   builtinUnbound: unboundAfterRestoringStrandedDefaults(compatibilityUnbound,
                                                                         overrides: builtinOverrides,
                                                                         survivors: survivors),
                   globalHotkey: globalHotkey),
            diagnostics)
}

/// Parse the remainder of a `global-hotkey` line: one chord token and nothing else. Rejects a bare key
/// outright — a system-wide binding with no modifier would take that key from every other application —
/// and a leader sequence, which `RegisterEventHotKey` cannot express. Repeats are last-wins.
private func parseGlobalHotkeyLine(_ rest: String, line: Int, hotkey: inout Chord?,
                                   diagnostics: inout [KeymapDiagnostic]) {
    let token = String(rest.prefix(while: { !$0.isWhitespace }))
    guard !token.isEmpty else {
        diagnostics.append(KeymapDiagnostic(line: line, message: "global-hotkey needs a chord"))
        return
    }
    let trailing = String(rest.dropFirst(token.count)).trimmingCharacters(in: .whitespaces)
    guard trailing.isEmpty else {
        diagnostics.append(KeymapDiagnostic(line: line,
                                            message: "global-hotkey takes one chord, found '\(rest)'"))
        return
    }
    guard let keybind = parseKeybind(token), keybind.count == 1, let chord = keybind.first else {
        diagnostics.append(KeymapDiagnostic(line: line, message: "invalid global-hotkey chord '\(token)'"))
        return
    }
    guard !chord.mods.isEmpty else {
        diagnostics.append(KeymapDiagnostic(line: line,
                                            message: "global-hotkey '\(token)' must include a modifier"))
        return
    }
    // `parseChord` takes any single character, but the OS registers a PHYSICAL key position, so a base key
    // no ANSI position produces cannot be registered. Diagnose here: this line has no read-back anywhere —
    // `keymap list` does not carry it — so a silent drop at registration leaves the user no signal at all.
    guard keyCode(forChordKey: chord.key) != nil else {
        diagnostics.append(KeymapDiagnostic(
            line: line,
            message: "global-hotkey '\(token)' names no key position; write a shifted symbol as shift+<base>"
        ))
        return
    }
    hotkey = chord
}

/// Whether a diagnostic is about a binding as a whole or about one alternative of several. The ONLY thing
/// separating the two wordings, so a single-alternative binding's text stays byte-identical to the
/// pre-alternatives one; each verb spells its own whole-binding half.
private enum DropScope {
    case wholeBinding
    case alternative

    init(hasSiblings: Bool) {
        self = hasSiblings ? .alternative : .wholeBinding
    }

    /// A parse-time or menu-collision rejection on a `map` line.
    var mapSkipped: String {
        self == .wholeBinding ? "map skipped" : "alternative skipped"
    }

    /// A cross-section drop, on either verb.
    var dropped: String {
        self == .wholeBinding ? "keybind dropped" : "alternative dropped"
    }

    /// A `command` line rejection, whose whole-binding half leaves the command in the palette unkeyed.
    var commandSkipped: String {
        self == .wholeBinding ? "treating the line as palette-only" : "alternative skipped"
    }
}

/// The menu chord an action resolves to against a given override set — the parse-time spelling of
/// `Keymap.equivalent(for:)`, shared by the built-in collision fixpoint and the cross-section chord set.
private func resolvedMenuChord(_ action: BuiltinAction, overrides: [BuiltinAction: Chord],
                               unbound: Set<BuiltinAction>) -> Chord? {
    if let chord = overrides[action] { return chord }
    return unbound.contains(action) ? nil : action.defaultChord
}

/// A binding token's alternatives as raw-substring / parsed-keybind pairs — the shape the whole parse carries
/// so a diagnostic and `CustomCommand.shortcut` can quote the user's own spelling instead of a re-render.
private typealias Alternatives = [(raw: String, keybind: Keybind)]

/// A single valid `map` line: the menu-bindable alternative if it has one, plus the monitor-bound rest.
private struct ParsedMapLine {
    let action: BuiltinAction
    let chord: Chord?
    let alternatives: Alternatives
    let line: Int
}

/// One `map` line's monitor-bound alternatives held until the cross-section pass, with the line to report a
/// drop on and the wording scope — the two things the diagnostics need beyond the binds themselves.
private struct MapLineAlternatives {
    let line: Int
    let scope: DropScope
    let alternatives: Alternatives
}

/// A `command` line's monitor-bound alternatives held beside the command they key, so nothing re-parses
/// `CustomCommand.shortcut` and `applySurvivingShortcuts` is the one place its string form is produced.
private struct ParsedCommandLine {
    let command: CustomCommand
    let alternatives: Alternatives
}

/// A menu-bound `map` alternative, retained in file order until the final cross-builtin duplicate pass.
private struct ParsedOverride {
    let action: BuiltinAction
    let chord: Chord
    let line: Int
}

/// Fold the file-order `map` lines to one per action and split them by dispatch path. A `map` line declares
/// an action's WHOLE binding set, so a later line replaces the earlier one's menu chord and alternatives
/// together — including replacing a menu chord with nothing, which is what `unbound` records.
private func resolveMapLines(_ mapLines: [ParsedMapLine])
    -> (overrides: [ParsedOverride], alternatives: [BuiltinAction: MapLineAlternatives],
        unbound: Set<BuiltinAction>) {
    var latest: [BuiltinAction: ParsedMapLine] = [:]
    for mapLine in mapLines { latest[mapLine.action] = mapLine }

    var overrides: [ParsedOverride] = []
    var alternatives: [BuiltinAction: MapLineAlternatives] = [:]
    var unbound: Set<BuiltinAction> = []
    for mapLine in latest.values.sorted(by: { $0.line < $1.line }) {
        if let chord = mapLine.chord {
            overrides.append(ParsedOverride(action: mapLine.action, chord: chord, line: mapLine.line))
        } else {
            unbound.insert(mapLine.action)
        }
        guard !mapLine.alternatives.isEmpty else { continue }
        let scope = DropScope(hasSiblings: mapLine.chord != nil || mapLine.alternatives.count > 1)
        alternatives[mapLine.action] = MapLineAlternatives(line: mapLine.line, scope: scope,
                                                           alternatives: mapLine.alternatives)
    }
    return (overrides, alternatives, unbound)
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
/// another built-in may claim the default they no longer use. `alternatives` names the lines that also carry
/// monitor-bound binds, which this pass never touches — only a line offering nothing else is skipped whole.
private func resolveBuiltinOverrides(_ overrides: [ParsedOverride], unbound: Set<BuiltinAction>,
                                     alternatives: [BuiltinAction: MapLineAlternatives],
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
        let scope = DropScope(hasSiblings: alternatives[drop.loser] != nil)
        diagnostics.append(KeymapDiagnostic(
            line: drop.line,
            message: "chord conflicts with built-in '\(drop.keeper.rawValue)'; \(scope.mapSkipped)"))
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
    let scope: DropScope
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
}

/// Every monitor-bound alternative of both verbs, custom commands first and `map` lines in file order — the
/// records the cross-section passes compare, drop and quote back.
private func monitorAlternatives(commandLines: [ParsedCommandLine],
                                 mapAlternatives: [BuiltinAction: MapLineAlternatives]) -> [MonitorAlternative] {
    var alternatives: [MonitorAlternative] = []
    for commandLine in commandLines {
        let scope = DropScope(hasSiblings: commandLine.alternatives.count > 1)
        alternatives += commandLine.alternatives.map {
            MonitorAlternative(target: .command(commandLine.command.id), ownerName: commandLine.command.name,
                               raw: $0.raw, keybind: $0.keybind, scope: scope, line: 0)
        }
    }
    for (action, entry) in mapAlternatives.sorted(by: { $0.value.line < $1.value.line }) {
        alternatives += entry.alternatives.map {
            MonitorAlternative(target: .builtin(action), ownerName: action.rawValue, raw: $0.raw,
                               keybind: $0.keybind, scope: entry.scope, line: entry.line)
        }
    }
    return alternatives
}

/// Cross-section validation over every monitor-bound alternative of both verbs, returning the survivors. Only
/// the offending alternative ever goes — its siblings keep firing, which is the whole point of offering
/// alternatives — and a custom command that loses every one of them stays, palette-only.
private func validateBindings(_ alternatives: [MonitorAlternative], menuChords: Set<Chord>,
                              diagnostics: inout [KeymapDiagnostic]) -> [MonitorAlternative] {
    let unshadowed = dropShadowedAlternatives(alternatives, menuChords: menuChords, diagnostics: &diagnostics)
    return dropConflictingAlternatives(unshadowed, diagnostics: &diagnostics)
}

/// Drop every alternative the app would never let the monitor see: one whose FIRST chord is an active built-in
/// menu chord, or that holds a reserved monitor chord at ANY position — the monitor consumes its chord wherever
/// it lands in a leader, so `ctrl+a>ctrl+1` is just as dead as a leading one.
///
/// Built-in menu chords are single, so any bind STARTING with one, single or leader, is shadowed by the menu.
/// Built-in alternatives face the same two tests as custom ones: `map cmd+t|cmd+t>s toggle_split` would
/// otherwise arm the monitor on the very chord that line puts on the menu. `menuChords` already has every
/// override applied, so a bind may freely reuse a default chord the user moved a built-in off of.
private func dropShadowedAlternatives(_ alternatives: [MonitorAlternative], menuChords: Set<Chord>,
                                      diagnostics: inout [KeymapDiagnostic]) -> [MonitorAlternative] {
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
            message: "\(alternative.subject) conflicts with \(kind); \(alternative.scope.dropped)"))
    }
    return kept
}

/// Settle every duplicate-or-prefix conflict among the alternatives pass 1 left, in ONE pass over a relation
/// computed once. A CROSS-TARGET pair drops both sides, upstream's rule for single binds. A SAME-TARGET prefix
/// pair drops the longer alternative, since `KeybindMatcher` fires the exact shorter match and the longer could
/// never run; both spell the same thing, so nothing is lost.
///
/// Nothing is recomputed and no drop cascades, which is what makes the outcome independent of the order the
/// file writes its lines and its `|` alternatives in. The price is that an alternative whose only conflict was
/// with one that also went still dies; that is the deliberate cost of determinism, not an omission — do not
/// add a recovery pass for it.
///
/// A cross-target diagnostic names the OTHER offender so the user can find the pair; a same-target one names
/// the owner both alternatives share. A target's alternatives are deduped, so target plus keybind locates
/// exactly one of them.
private func dropConflictingAlternatives(_ alternatives: [MonitorAlternative],
                                         diagnostics: inout [KeymapDiagnostic]) -> [MonitorAlternative] {
    var position: [KeybindConflict.Side: Int] = [:]
    for (index, alternative) in alternatives.enumerated() {
        position[KeybindConflict.Side(target: alternative.target, keybind: alternative.keybind)] = index
    }
    var otherOffender: [Int: String] = [:]
    func charge(_ index: Int, with offender: String) {
        if otherOffender[index] == nil { otherOffender[index] = offender }
    }
    for conflict in keybindConflicts(alternatives.map { (keybind: $0.keybind, target: $0.target) }) {
        guard let first = position[conflict.first], let second = position[conflict.second] else { continue }
        guard conflict.first.target != conflict.second.target else {
            let longer = isStrictKeybindPrefix(conflict.first.keybind, of: conflict.second.keybind) ? second : first
            charge(longer, with: alternatives[longer].owner)
            continue
        }
        charge(first, with: alternatives[second].owner)
        charge(second, with: alternatives[first].owner)
    }

    var survivors: [MonitorAlternative] = []
    for (index, alternative) in alternatives.enumerated() {
        guard let other = otherOffender[index] else {
            survivors.append(alternative)
            continue
        }
        diagnostics.append(KeymapDiagnostic(
            line: alternative.line,
            message: "\(alternative.subject) conflicts with \(other); \(alternative.scope.dropped)"))
    }
    return survivors
}

/// The surviving monitor-bound binds per built-in, in file order.
private func survivingAlternatives(_ survivors: [MonitorAlternative]) -> [BuiltinAction: [Keybind]] {
    var alternatives: [BuiltinAction: [Keybind]] = [:]
    for survivor in survivors {
        guard case .builtin(let action) = survivor.target else { continue }
        alternatives[action, default: []].append(survivor.keybind)
    }
    return alternatives
}

/// The parsed commands with each keyed one's `shortcut` written from the raw substrings its alternatives kept
/// — the single place the string form is produced, splicing rather than re-rendering so the user's own
/// spelling survives. A command that lost every alternative ends up with `shortcut == ""`, palette-only.
private func applySurvivingShortcuts(to commandLines: [ParsedCommandLine],
                                     survivors: [MonitorAlternative]) -> [CustomCommand] {
    var raws: [UUID: [String]] = [:]
    for survivor in survivors {
        guard case .command(let id) = survivor.target else { continue }
        raws[id, default: []].append(survivor.raw)
    }
    return commandLines.map { commandLine in
        guard !commandLine.alternatives.isEmpty else { return commandLine.command }
        var command = commandLine.command
        command.shortcut = (raws[command.id] ?? []).joined(separator: "|")
        return command
    }
}

/// The unbound set with every STRANDED action removed — one whose `map` line lost its last bind in the
/// cross-section passes, which goes back to its shipped default exactly as one rejected while parsing does:
/// the line bound nothing, so leaving the action keyless would take away a chord the file never asked to move.
/// An action stays unbound when something else already holds that chord, which being unbound is what
/// permitted — the passes above ran against a chord set this action had vacated.
private func unboundAfterRestoringStrandedDefaults(_ unbound: Set<BuiltinAction>,
                                                   overrides: [BuiltinAction: Chord],
                                                   survivors: [MonitorAlternative]) -> Set<BuiltinAction> {
    let stillBound = Set(survivors.compactMap { survivor -> BuiltinAction? in
        guard case .builtin(let action) = survivor.target else { return nil }
        return action
    })
    let stranded = unbound.subtracting(stillBound)
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
private func parseMapLine(_ rest: String, line: Int, mapLines: inout [ParsedMapLine],
                          diagnostics: inout [KeymapDiagnostic]) {
    // split on the first run of general whitespace (space OR tab) so a tab-separated `map` line works.
    let chordText = String(rest.prefix(while: { !$0.isWhitespace }))
    let actionName = String(rest.dropFirst(chordText.count)).trimmingCharacters(in: .whitespaces)
    guard !chordText.isEmpty, !actionName.isEmpty else {
        diagnostics.append(KeymapDiagnostic(line: line, message: "map requires a chord and an action"))
        return
    }

    guard let parsed = alternativeKeybinds(chordText) else {
        diagnostics.append(KeymapDiagnostic(line: line, message: "invalid chord '\(chordText)'"))
        return
    }

    let split = splitMapAlternatives(parsed, line: line, diagnostics: &diagnostics)
    // nothing survived: report no action diagnostic on top of the per-alternative ones, as before.
    guard split.chord != nil || !split.alternatives.isEmpty else { return }
    guard let action = BuiltinAction(rawValue: actionName) else {
        diagnostics.append(KeymapDiagnostic(line: line, message: "unknown action '\(actionName)'"))
        return
    }
    mapLines.append(ParsedMapLine(action: action, chord: split.chord, alternatives: split.alternatives,
                                  line: line))
}

/// Sort a `map` line's alternatives by dispatch path: the first one that can be a menu key equivalent — a
/// single chord passing `map`'s own rules — becomes it, every other one is monitor-bound and follows the
/// monitor's rule instead. The grammar tracks the DISPATCH PATH, not the verb.
///
/// An alternative breaking its path's rule is diagnosed and dropped alone, leaving its siblings; the caller
/// treats a line that kept nothing as having bound nothing. (A MALFORMED alternative never reaches here —
/// `alternativeKeybinds` already killed the line, so a typo cannot hide behind a line that half worked.)
private func splitMapAlternatives(_ parsed: Alternatives, line: Int,
                                  diagnostics: inout [KeymapDiagnostic]) -> (chord: Chord?,
                                                                             alternatives: Alternatives) {
    let scope = DropScope(hasSiblings: parsed.count > 1)
    var menuChord: Chord?
    var alternatives: Alternatives = []
    for alternative in parsed {
        // a chord owned by an always-on NSEvent monitor can't be a menu key-equivalent without dead-racing
        // the monitor, and is just as dead deeper in a sequence, so reject it at any position.
        guard !alternative.keybind.contains(where: isReservedMonitorChord) else {
            diagnostics.append(KeymapDiagnostic(
                line: line,
                message: "chord '\(alternative.raw)' is a reserved shortcut; \(scope.mapSkipped)"))
            continue
        }
        if menuChord == nil, alternative.keybind.count == 1, let chord = alternative.keybind.first {
            // a modifier-less arrow would install an always-on menu key-equivalent swallowing the key
            // everywhere — terminal, palettes, dashboard grid, every text field — and the menu path, unlike
            // the custom-command monitor, has no text-field pass-through.
            guard !(bindableArrowKeys.contains(chord.key) && chord.mods.isEmpty) else {
                diagnostics.append(KeymapDiagnostic(
                    line: line,
                    message: "bare arrow chord '\(alternative.raw)' needs a modifier; \(scope.mapSkipped)"))
                continue
            }
            menuChord = chord
            continue
        }
        // monitor-bound: a bare first chord would be swallowed everywhere in the terminal, the rule
        // `parseCommandLine` already applies to every custom shortcut.
        guard alternative.keybind.first?.mods.isEmpty == false else {
            diagnostics.append(KeymapDiagnostic(
                line: line,
                message: "chord '\(alternative.raw)' needs a modifier on its first key; \(scope.mapSkipped)"))
            continue
        }
        alternatives.append(alternative)
    }
    return (menuChord, alternatives)
}

/// Parse the remainder of a `command` line (after the verb): `"<name>" [chord] <shell...>`. On any failure
/// it appends a diagnostic and leaves `commandLines` untouched. The kept alternatives ride alongside the
/// command; `applySurvivingShortcuts` is what turns them back into `CustomCommand.shortcut`.
private func parseCommandLine(_ rest: String, line: Int, commandLines: inout [ParsedCommandLine],
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
    var kept: Alternatives = []
    var shellLine = afterName
    if !firstToken.isEmpty, let parsed = alternativeKeybinds(firstToken) {
        kept = parsed.filter { $0.keybind.first?.mods.isEmpty == false }
        if kept.isEmpty {
            diagnostics.append(KeymapDiagnostic(line: line,
                message: "command '\(name)' shortcut '\(firstToken)' must include a modifier; \(DropScope.wholeBinding.commandSkipped)"))
        } else {
            for dropped in parsed where dropped.keybind.first?.mods.isEmpty != false {
                diagnostics.append(KeymapDiagnostic(line: line,
                    message: "command '\(name)' shortcut '\(dropped.raw)' must include a modifier; \(DropScope.alternative.commandSkipped)"))
            }
            shellLine = String(afterName.dropFirst(firstToken.count)).trimmingCharacters(in: .whitespaces)
        }
    } else if hasMalformedAlternative(firstToken) {
        // a token mixing a real alternative with a malformed one is a typo, not a shell line. Saying so is
        // what keeps a malformed alternative from hiding inside the command instead of killing the binding.
        diagnostics.append(KeymapDiagnostic(line: line,
            message: "command '\(name)' shortcut '\(firstToken)' has an invalid alternative; \(DropScope.wholeBinding.commandSkipped)"))
    }

    // an empty shell line (just a name, or a name + chord with no command) is a no-op binding; skip it.
    guard !shellLine.trimmingCharacters(in: .whitespaces).isEmpty else {
        diagnostics.append(KeymapDiagnostic(line: line, message: "command '\(name)' has no shell line"))
        return
    }

    commandLines.append(ParsedCommandLine(command: CustomCommand(name: name, command: shellLine, shortcut: ""),
                                          alternatives: kept))
}
