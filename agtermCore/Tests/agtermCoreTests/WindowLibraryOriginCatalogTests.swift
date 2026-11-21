import Foundation
import Testing
@testable import agtermCore

@MainActor
final class WindowLibraryOriginCatalogTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
    private lazy var library = WindowLibrary(directory: directory)

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func refusal(_ window: String?, live: Bool = true) -> OriginCatalogRefusal? {
        guard case .failure(let refusal) = library.originCatalogStore(window: window, liveActive: live) else { return nil }
        return refusal
    }

    @Test func anOpenLocalWindowServesItsStore() throws {
        let window = try #require(library.activeWindowID)

        guard case .success(let origin) = library.originCatalogStore(window: window.uuidString, liveActive: true) else {
            Issue.record("refused")
            return
        }
        #expect(origin.id == window)
        #expect(origin.store === library.store(for: window))
    }

    @Test func withoutLiveSessionsEveryWindowIsRefusedForGood() throws {
        let window = try #require(library.activeWindowID)

        let refused = try #require(refusal(window.uuidString, live: false))

        #expect(refused == .notLive)
        #expect(refused.final)
        #expect(refused.message(host: "box") == "box does not run Live sessions, which a remote window needs")
    }

    @Test func aHelloWithoutAWindowIsRefusedForGood() throws {
        let refused = try #require(refusal(nil))

        #expect(refused == .noWindow)
        #expect(refused.final)
        #expect(refused.message(host: "box") == "the request names no window on box")
    }

    @Test func anUnknownWindowIsRefusedForGood() throws {
        let unknown = UUID().uuidString

        let refused = try #require(refusal(unknown))

        #expect(refused == .unknown(unknown))
        #expect(refused.final)
        #expect(refused.message(host: "box") == "box has no window \(unknown)")
    }

    @Test func aRemoteWindowIsRefusedForGood() throws {
        let remote = library.newRemoteWindow(host: "buildbox")

        let refused = try #require(refusal(remote.id.uuidString))

        #expect(refused == .remote(remote.name))
        #expect(refused.final)
        #expect(refused.message(host: "box") == "window \(remote.name) on box is a remote window itself")
    }

    @Test func aClosedWindowIsRefusedUntilItReopens() throws {
        let second = library.newWindow(name: "second")
        library.closeWindow(second.id)

        let refused = try #require(refusal(second.id.uuidString))

        #expect(refused == .closed("second"))
        #expect(!refused.final)
        #expect(refused.message(host: "box") == "window second is closed on box")
    }
}
