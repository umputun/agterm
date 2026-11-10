import Testing
@testable import agtermCore

struct RemoteLinkRefusalTests {
    @Test(arguments: RemoteLinkRefusal.allCases)
    func everyRefusalNamesTheHostAndTravelsByItsRawValue(_ refusal: RemoteLinkRefusal) {
        #expect(refusal.message(host: "buildbox").contains("buildbox"))
        #expect(RemoteLinkRefusal(rawValue: refusal.rawValue) == refusal)
    }

    @Test func eachRefusalHasItsOwnText() {
        let texts = RemoteLinkRefusal.allCases.map { $0.message(host: "h") }
        #expect(Set(texts).count == texts.count)
    }
}
