import XCTest
@testable import agterm

@MainActor
final class RemoteLinkObserverTests: XCTestCase {
    func testOnlyAPathThatComesBackRetries() {
        var retries = 0
        let observer = RemoteLinkObserver { retries += 1 }

        observer.pathChanged(satisfied: true)
        observer.pathChanged(satisfied: true)
        XCTAssertEqual(retries, 0, "the first report is the state at start")

        observer.pathChanged(satisfied: false)
        observer.pathChanged(satisfied: true)
        observer.pathChanged(satisfied: false)
        observer.pathChanged(satisfied: true)
        XCTAssertEqual(retries, 2)
    }

    func testAWakeRetriesOnceHoweverManyWindowsStarted() {
        var retries = 0
        let observer = RemoteLinkObserver { retries += 1 }
        observer.start()
        observer.start()

        NotificationCenter.default.post(name: .agtermScreensDidWake, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(retries, 1)
    }
}
