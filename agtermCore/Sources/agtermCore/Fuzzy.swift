import Foundation

/// Scores how well `query` matches `target` for the command palettes — lower is a better match,
/// `nil` means no match. The query is split on whitespace into terms (`"cap dev"` is two terms);
/// EVERY term must match `target` and the score is the sum of the per-term scores, so the order
/// between terms doesn't matter — `"cap dev"` and `"dev cap"` both match `caprica-dev`. An empty or
/// whitespace-only query matches everything at `0` (so the unfiltered list keeps its natural order).
/// Case-insensitive.
///
/// Per term: an exact prefix is `0`; a substring is `5 +` the offset where it starts; a scattered
/// subsequence is `40 +` the length gap.
public func fuzzyScore(query: String, target: String) -> Int? {
    let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    guard !terms.isEmpty else { return 0 }
    let t = target.lowercased()
    var total = 0
    for term in terms {
        guard let score = termScore(term, in: t) else { return nil }
        total += score
    }
    return total
}

/// Ranks `items` against `query` for the command palettes: an item matches when any of its `keys`
/// (for example, a title and optional subtitle) matches, scored by the best/lower score of those keys.
/// Matches are sorted best-first with ties broken by the first key, case-insensitively.
///
/// Empty queries score every item at `0`, which makes this an alphabetical sort by first key. Callers
/// that need an empty query to preserve natural input order should skip ranking for that case.
public func fuzzyRank<Item>(query: String, items: [Item], keys: (Item) -> [String]) -> [Item] {
    items.compactMap { item -> (item: Item, score: Int, label: String)? in
        let itemKeys = keys(item)
        guard let best = itemKeys.compactMap({ fuzzyScore(query: query, target: $0) }).min() else { return nil }
        return (item, best, itemKeys.first ?? "")
    }
    .sorted {
        $0.score != $1.score
            ? $0.score < $1.score
            : $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
    }
    .map(\.item)
}

/// Scores a single whitespace-free `term` against the already-lowercased `target`: an exact prefix
/// is `0`, a substring is `5 +` its start offset, a scattered subsequence is `40 +` the length gap,
/// and `nil` when the term doesn't appear at all.
private func termScore(_ term: String, in target: String) -> Int? {
    if target.hasPrefix(term) { return 0 }
    if let range = target.range(of: term) {
        return 5 + target.distance(from: target.startIndex, to: range.lowerBound)
    }
    // subsequence: every term char appears in order, not necessarily adjacent.
    var ti = term.startIndex
    for ch in target where ch == term[ti] {
        ti = term.index(after: ti)
        if ti == term.endIndex { return 40 + (target.count - term.count) }
    }
    return nil
}
