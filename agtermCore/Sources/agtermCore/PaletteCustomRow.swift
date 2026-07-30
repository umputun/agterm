import Foundation

/// Returns the synthetic free-text row label when a picker query has no item match. Whitespace around the
/// query is ignored so an empty search never becomes a selectable value.
public func pickCustomRowLabel(query: String, filteredCount: Int, allowCustom: Bool) -> String? {
    let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard allowCustom, filteredCount == 0, !value.isEmpty else { return nil }
    return "Use \"\(value)\""
}
