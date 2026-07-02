import Testing
@testable import agtermCore

struct FuzzyTests {
    @Test func emptyQueryMatchesEverythingAtZero() {
        #expect(fuzzyScore(query: "", target: "anything") == 0)
    }

    @Test func exactPrefixScoresZero() {
        #expect(fuzzyScore(query: "new", target: "New Session") == 0)
    }

    @Test func caseInsensitive() {
        #expect(fuzzyScore(query: "NEW", target: "new session") == 0)
    }

    @Test func substringScoresByOffset() {
        // "session" starts at offset 4 in "New Session".
        #expect(fuzzyScore(query: "session", target: "New Session") == 5 + 4)
    }

    @Test func subsequenceScoresAboveSubstring() {
        // "nsn" is a scattered subsequence of "New Session", not a substring.
        let score = fuzzyScore(query: "nsn", target: "New Session")
        #expect(score != nil)
        #expect(score! >= 40)
    }

    @Test func noMatchReturnsNil() {
        #expect(fuzzyScore(query: "xyz", target: "New Session") == nil)
    }

    @Test func prefixBeatsSubstringBeatsSubsequence() {
        let prefix = fuzzyScore(query: "ne", target: "New Session")!
        let substring = fuzzyScore(query: "ew", target: "New Session")!
        let subsequence = fuzzyScore(query: "nss", target: "New Session")!
        #expect(prefix < substring)
        #expect(substring < subsequence)
    }

    @Test func multiTermMatchesAcrossWordBoundaries() {
        // "cap dev" (two whitespace-separated terms) matches "caprica-dev": "cap" is a prefix and
        // "dev" a later substring, even though the literal "cap dev" is neither.
        #expect(fuzzyScore(query: "cap dev", target: "caprica-dev") != nil)
    }

    @Test func multiTermIsOrderIndependent() {
        #expect(fuzzyScore(query: "cap dev", target: "caprica-dev")
            == fuzzyScore(query: "dev cap", target: "caprica-dev"))
    }

    @Test func multiTermRequiresEveryTerm() {
        // one term matches, the other doesn't → no match.
        #expect(fuzzyScore(query: "cap xyz", target: "caprica-dev") == nil)
    }

    @Test func collapsesRepeatedWhitespaceBetweenTerms() {
        #expect(fuzzyScore(query: "cap   dev", target: "caprica-dev") != nil)
    }

    @Test func whitespaceOnlyQueryMatchesEverything() {
        #expect(fuzzyScore(query: "  \t ", target: "anything") == 0)
    }

    @Test func fuzzyRankSortsBestMatchFirstAndDropsNonMatches() {
        let items = ["New Workspace", "New Session", "Close Session"]
        let ranked = fuzzyRank(query: "new", items: items, keys: { [$0] })

        #expect(ranked == ["New Session", "New Workspace"])
    }

    @Test func fuzzyRankPrefersLowerScore() {
        let items = ["New Session", "Session List"]

        #expect(fuzzyRank(query: "sess", items: items, keys: { [$0] }) == ["Session List", "New Session"])
    }

    @Test func fuzzyRankMatchesAnyKeyUsingTheBestScore() {
        struct Command: Equatable {
            let title: String
            let subtitle: String
        }
        let items = [
            Command(title: "Toggle Split", subtitle: "panes"),
            Command(title: "Reload", subtitle: "split config")
        ]

        let ranked = fuzzyRank(query: "split", items: items, keys: { [$0.title, $0.subtitle] })

        #expect(ranked == [
            Command(title: "Reload", subtitle: "split config"),
            Command(title: "Toggle Split", subtitle: "panes")
        ])
    }

    @Test func fuzzyRankEmptyQueryAlphabetizesByFirstKey() {
        let items = ["beta", "Alpha", "gamma"]

        #expect(fuzzyRank(query: "", items: items, keys: { [$0] }) == ["Alpha", "beta", "gamma"])
    }

    @Test func fuzzyRankTermCharactersMustMatchInOrder() {
        let items = ["Split Pane", "Panel Split"]

        #expect(fuzzyRank(query: "ps", items: items, keys: { [$0] }) == ["Panel Split"])
    }
}
