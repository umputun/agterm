import XCTest
@testable import agterm

/// `ghostty_surface_new` returns NULL for as long as the display is asleep, so a session a scheduled job
/// creates in that window realizes no surface and its `--command` never runs. Nothing else re-attempts —
/// SwiftUI runs no layout for an off-display window — so this bridge is the only thing that revives the
/// pane (#416). Measured: creation starts succeeding at display wake, with the screen still locked.
@MainActor
final class SystemWakeObserverTests: XCTestCase {
    func testDisplayWakeIsRepostedOnTheAppNotificationCenter() {
        let observer = SystemWakeObserver()
        observer.start()

        let reposted = expectation(forNotification: .agtermScreensDidWake, object: nil, notificationCenter: .default)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)

        wait(for: [reposted], timeout: 2)
    }

    func testStartIsIdempotentSoOneWakeStaysOneRepost() {
        let observer = SystemWakeObserver()
        observer.start()
        observer.start()
        observer.start()

        var reposts = 0
        let token = NotificationCenter.default.addObserver(forName: .agtermScreensDidWake, object: nil,
                                                          queue: .main) { _ in reposts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        let settled = expectation(description: "repost delivered")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        XCTAssertEqual(reposts, 1, "the scene .task starts this per window, so repeated starts must not fan out")
    }
}
