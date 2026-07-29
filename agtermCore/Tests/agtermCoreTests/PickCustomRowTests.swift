import Testing
@testable import agtermCore

struct PickCustomRowTests {
    @Test func emptyQueryDoesNotOfferCustomRow() {
        #expect(pickCustomRowLabel(query: "", filteredCount: 0, allowCustom: true) == nil)
        #expect(pickCustomRowLabel(query: " \t ", filteredCount: 0, allowCustom: true) == nil)
    }

    @Test func unmatchedQueryOffersCustomRowWhenAllowed() {
        #expect(pickCustomRowLabel(query: "new value", filteredCount: 0, allowCustom: true)
            == "Use \"new value\"")
    }

    @Test func unmatchedQueryDoesNotOfferCustomRowWhenDisallowed() {
        #expect(pickCustomRowLabel(query: "new value", filteredCount: 0, allowCustom: false) == nil)
    }

    @Test func matchingQueryDoesNotOfferCustomRow() {
        #expect(pickCustomRowLabel(query: "one", filteredCount: 1, allowCustom: true) == nil)
    }
}
