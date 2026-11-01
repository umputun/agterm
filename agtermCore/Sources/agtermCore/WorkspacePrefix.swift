import Foundation

/// Name-prefix matching behind Go to Workspace and `workspace.go --prefix`: anchored at the start of the
/// name, case- and diacritic-insensitive, so one rule decides where the palette jumps and the CLI lands.
public enum WorkspacePrefix {
    public enum Resolution: Equatable, Sendable {
        case match(Int)
        case none
        case ambiguous([Int])
    }

    public static func matches(_ prefix: String, name: String) -> Bool {
        name.range(of: prefix, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil
    }

    public static func matchingIndices(_ prefix: String, in names: [String]) -> [Int] {
        guard !prefix.isEmpty else { return [] }
        return names.indices.filter { matches(prefix, name: names[$0]) }
    }

    /// A lone exact name wins over longer names sharing it as a prefix, or `api` could never reach `api`
    /// beside `api-v2`.
    public static func resolve(_ prefix: String, in names: [String]) -> Resolution {
        let candidates = matchingIndices(prefix, in: names)
        if candidates.count == 1 { return .match(candidates[0]) }
        if candidates.isEmpty { return .none }
        let exact = candidates.filter {
            names[$0].compare(prefix, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        return exact.count == 1 ? .match(exact[0]) : .ambiguous(candidates)
    }
}
