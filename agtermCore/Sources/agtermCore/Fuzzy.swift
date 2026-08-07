/// Scores how well `query` matches `target` for the command palettes — lower is better, `nil` is no match.
/// The query splits on whitespace into terms (`"cap dev"` is two); EVERY term must match `target` and the
/// score is their sum, so term order is irrelevant — `"cap dev"` and `"dev cap"` both match `caprica-dev`.
/// An empty or whitespace-only query matches everything at `0`, keeping the unfiltered list's natural
/// order. Case-insensitive. Per term: an exact prefix is `0`, a substring `5 + min(offset, 34)`, a
/// scattered subsequence `40 +` the length gap. The cap keeps a single term's literal match (`39` at
/// worst) ahead of any subsequence-only match; substrings starting at or past offset `34` tie and fall
/// to the caller's tie-break. Summed multi-term scores can still cross bands.
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

/// Ranks `items` against `query` for the command palettes: an item matches when any of its `keys` (a title
/// and optional subtitle, say) matches, scored by the best (lowest) of those keys. Sorted best-first, ties
/// broken by the first key case-insensitively.
///
/// An empty query scores every item `0`, making this an alphabetical sort by first key — a caller needing
/// natural input order there should skip ranking.
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

/// Scores a single whitespace-free `term` against the already-lowercased `target` (see `fuzzyScore` for
/// the scale), `nil` when the term doesn't appear at all.
private func termScore(_ term: String, in target: String) -> Int? {
    if target.hasPrefix(term) { return 0 }
    if let range = target.range(of: term) {
        // 39 max — the substring band must stay under the subsequence floor of 40.
        return 5 + min(target.distance(from: target.startIndex, to: range.lowerBound), 34)
    }
    // subsequence: every term char appears in order, not necessarily adjacent.
    var ti = term.startIndex
    for ch in target where ch == term[ti] {
        ti = term.index(after: ti)
        if ti == term.endIndex { return 40 + (target.count - term.count) }
    }
    return nil
}
