import os
import XCTest
@testable import agterm

final class LaunchTraceTests: XCTestCase {
    func testEachStageIsLoggedOnceWithItsFirstDetail() {
        let logged = OSAllocatedUnfairLock(initialState: [String]())
        let trace = LaunchTrace { stage, detail in logged.withLock { $0.append("\(stage.rawValue)|\(detail)") } }

        trace.mark(.sceneTask)
        trace.mark(.socket, "bound=true")
        trace.mark(.sceneTask)
        trace.mark(.socket, "bound=false")

        XCTAssertEqual(logged.withLock { $0 }, ["scene task|", "socket|bound=true"])
    }
}
