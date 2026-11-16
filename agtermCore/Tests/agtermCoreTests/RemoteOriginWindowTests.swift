import Foundation
import Testing
@testable import agtermCore

struct RemoteOriginWindowTests {
    private let build = ControlWindowNode(id: "6F1C0D2E-0000-4000-8000-000000000001", name: "build", open: true, active: true)
    private let notes = ControlWindowNode(id: "9A2B3C4D-0000-4000-8000-000000000002", name: "notes", open: true, active: false)
    private let closed = ControlWindowNode(id: "C0C0C0C0-0000-4000-8000-000000000003", name: "old", open: false, active: false)

    private var mirrored: ControlWindowNode {
        var node = ControlWindowNode(id: "D1D1D1D1-0000-4000-8000-000000000004", name: "server", open: true, active: false)
        node.remote = ControlRemoteWindow(host: "box", catalogID: nil, state: nil)
        return node
    }

    @Test func theOneOpenWindowIsChosenWithoutAsking() throws {
        let chosen = try RemoteOriginWindow.choose(host: "mac", windows: [build, closed, mirrored], requested: nil).get()

        #expect(chosen == build)
    }

    @Test func theOfferedWindowsAreTheOpenLocalOnes() {
        #expect(RemoteOriginWindow.offered([build, closed, mirrored, notes]) == [build, notes])
    }

    @Test func severalOpenWindowsAskForOneByName() {
        let result = RemoteOriginWindow.choose(host: "mac", windows: [build, notes], requested: nil)

        #expect(result == .failure(.ambiguous("mac has 2 open windows; name one with --origin-window: 6f1c0d2e build, 9a2b3c4d notes")))
    }

    @Test func noOpenWindowIsSaid() {
        let result = RemoteOriginWindow.choose(host: "mac", windows: [closed, mirrored], requested: nil)

        #expect(result == .failure(.none("mac has no open window")))
    }

    @Test func aRequestedWindowResolvesByIdOrPrefix() throws {
        let byPrefix = try RemoteOriginWindow.choose(host: "mac", windows: [build, notes], requested: "9a2b").get()
        let byID = try RemoteOriginWindow.choose(host: "mac", windows: [build, notes], requested: build.id).get()

        #expect(byPrefix == notes)
        #expect(byID == build)
    }

    @Test(arguments: [
        ("ffff", "mac has no window ffff"),
        ("C0C0", "window old is closed on mac"),
        ("D1D1", "window server on mac is a remote window itself"),
    ])
    func aRequestedWindowThatCannotBeShownIsNamed(requested: String, error: String) {
        let result = RemoteOriginWindow.choose(host: "mac", windows: [build, closed, mirrored], requested: requested)

        #expect(result.failureMessage == error)
    }
}

private extension Result where Failure == RemoteOriginWindow.Refusal {
    var failureMessage: String? {
        guard case .failure(let refusal) = self else { return nil }
        return refusal.message
    }
}
