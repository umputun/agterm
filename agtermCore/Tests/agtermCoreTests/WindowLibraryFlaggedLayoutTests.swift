import Foundation
import Testing
@testable import agtermCore

@MainActor
final class WindowLibraryFlaggedLayoutTests {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("agterm-flagged-layout-\(UUID().uuidString)")

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func launchRestoredStoresCarryTheLayoutPassedToInit() throws {
        let library = WindowLibrary(directory: directory, paneFinalizer: nil, flaggedLayout: .tree)
        let first = try #require(library.windows.first)

        #expect(library.flaggedLayout == .tree)
        #expect(library.store(for: first.id)?.flaggedLayout == .tree)
    }

    @Test func theConvenienceInitDefaultsToFlat() {
        let library = WindowLibrary(directory: directory)

        #expect(library.flaggedLayout == .flat)
    }

    @Test func settingTheLayoutReachesEveryOpenStore() throws {
        let library = WindowLibrary(directory: directory, paneFinalizer: nil)
        let first = try #require(library.windows.first)
        let second = library.newWindow(name: "second")

        library.setFlaggedLayout(.plain)

        #expect(library.store(for: first.id)?.flaggedLayout == .plain)
        #expect(library.store(for: second.id)?.flaggedLayout == .plain)
    }

    @Test func aStoreOpenedAfterTheChangeTakesTheCurrentLayout() throws {
        let library = WindowLibrary(directory: directory, paneFinalizer: nil)
        let closed = library.newWindow(name: "closed")
        library.closeWindow(closed.id)

        library.setFlaggedLayout(.tree)
        let reopened = try #require(library.loadStore(for: closed.id))

        #expect(reopened.flaggedLayout == .tree)
    }
}
