import Foundation
import Testing
@testable import agtermCore

struct TerminalSurfaceTests {
    // libghostty's `next` walks newest→oldest (visually UP) and `previous` the other way, so agterm's
    // directions map INVERTED. A "simplify back to rawValue" re-inverts the chevrons and fails here.
    @Test(arguments: [
        (SearchDirection.next, "navigate_search:previous"),
        (SearchDirection.previous, "navigate_search:next"),
    ])
    func ghosttyActionInvertsDirection(direction: SearchDirection, expected: String) {
        #expect(direction.ghosttyAction == expected)
    }

    @Test func nextAndPreviousMapToDistinctActions() {
        #expect(SearchDirection.next.ghosttyAction != SearchDirection.previous.ghosttyAction)
    }
}
