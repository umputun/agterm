import Foundation
import Testing
@testable import agtermCore

struct TerminalSurfaceTests {
    // agterm's natural direction is INVERTED to libghostty's navigate_search string: libghostty's `next`
    // walks newest→oldest (visually UP) and `previous` walks oldest→newest (visually DOWN), so agterm's
    // `.next` (down) must emit `navigate_search:previous` and `.previous` (up) must emit
    // `navigate_search:next`. This pins the corrected mapping so a future "simplify back to rawValue"
    // re-inverts the chevrons and fails here.
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
