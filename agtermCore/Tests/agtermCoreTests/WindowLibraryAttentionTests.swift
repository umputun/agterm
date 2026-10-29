import Foundation
import Testing
@testable import agtermCore

@MainActor
final class WindowLibraryAttentionTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-attention-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func addSession(to store: AppStore, status: AgentStatus, workspace: UUID? = nil) throws -> Session {
        let session = try #require(store.addSession(toWorkspace: workspace ?? store.workspaces[0].id, cwd: "/tmp", select: false))
        store.setAgentIndicator(AgentIndicator(status: status), forSession: session.id)
        return session
    }

    private func step(_ library: WindowLibrary, from source: UUID, forward: Bool = true,
                      eligible: (UUID) -> Bool = { _ in true }) -> UUID? {
        library.attentionStep(from: source, forward: forward, eligible: eligible)?.sessionID
    }

    @Test func anAttentionCompanionIsLabelledAfterItsParent() throws {
        let library = WindowLibrary(directory: directory)
        let store = try #require(library.activeStore)
        let parent = try addSession(to: store, status: .idle)
        store.renameSession(parent.id, to: "api")
        let companion = try store.addCompanion(to: parent.id, options: CompanionOptions(name: "logs")).get()
        store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: companion.id)

        let entry = try #require(library.attentionAcrossWindows.first { $0.session.id == companion.id })

        #expect(library.attentionLabel(entry) == "api › logs")
    }

    @Test func stepsThroughWindowsInLibraryOrderThenSidebarOrder() throws {
        let library = WindowLibrary(directory: directory)
        let first = try #require(library.activeWindowID)
        let firstStore = try #require(library.store(for: first))
        let origin = try addSession(to: firstStore, status: .idle)
        let local = try addSession(to: firstStore, status: .completed)
        let second = library.newWindow(name: "second")
        let secondStore = try #require(library.store(for: second.id))
        let remote = try addSession(to: secondStore, status: .blocked)
        firstStore.selectSession(origin.id)

        let found = try #require(library.attentionStep(from: first, forward: true, eligible: { _ in true }))
        #expect(found.windowID == first)
        #expect(found.sessionID == local.id)
        firstStore.selectSession(local.id)
        let next = try #require(library.attentionStep(from: first, forward: true, eligible: { _ in true }))
        #expect(next.windowID == second.id)
        #expect(next.sessionID == remote.id)
    }

    @Test func wrapsFromTheLastWindowBackToTheFirst() throws {
        let library = WindowLibrary(directory: directory)
        let first = try #require(library.activeWindowID)
        let firstStore = try #require(library.store(for: first))
        let early = try addSession(to: firstStore, status: .completed)
        let second = library.newWindow(name: "second")
        let secondStore = try #require(library.store(for: second.id))
        let origin = try addSession(to: secondStore, status: .idle)
        secondStore.selectSession(origin.id)

        #expect(step(library, from: second.id) == early.id)
    }

    @Test func steppingBackwardFromTheFirstWindowWrapsToTheLast() throws {
        let library = WindowLibrary(directory: directory)
        let first = try #require(library.activeWindowID)
        let firstStore = try #require(library.store(for: first))
        let origin = try addSession(to: firstStore, status: .idle)
        let second = library.newWindow(name: "second")
        let secondStore = try #require(library.store(for: second.id))
        let late = try addSession(to: secondStore, status: .blocked)
        firstStore.selectSession(origin.id)

        #expect(step(library, from: first, forward: false) == late.id)
    }

    @Test func excludesTheCurrentSession() throws {
        let library = WindowLibrary(directory: directory)
        let first = try #require(library.activeWindowID)
        let firstStore = try #require(library.store(for: first))
        let only = try addSession(to: firstStore, status: .idle)
        firstStore.selectSession(only.id)
        firstStore.setAgentIndicator(AgentIndicator(status: .blocked), forSession: only.id)
        _ = library.newWindow(name: "second")

        #expect(step(library, from: first) == nil)
    }

    @Test func skipsAnIneligibleWindowAndKeepsScanning() throws {
        let library = WindowLibrary(directory: directory)
        let first = try #require(library.activeWindowID)
        let firstStore = try #require(library.store(for: first))
        let origin = try addSession(to: firstStore, status: .idle)
        let covered = library.newWindow(name: "covered")
        _ = try addSession(to: try #require(library.store(for: covered.id)), status: .blocked)
        let open = library.newWindow(name: "open")
        let reachable = try addSession(to: try #require(library.store(for: open.id)), status: .blocked)
        firstStore.selectSession(origin.id)

        #expect(step(library, from: first, eligible: { $0 != covered.id }) == reachable.id)
    }

    @Test func keepsTheSourcePositionWhenTheSourceIsNotEligible() throws {
        let library = WindowLibrary(directory: directory)
        let first = try #require(library.activeWindowID)
        let firstStore = try #require(library.store(for: first))
        let origin = try addSession(to: firstStore, status: .idle)
        let local = try addSession(to: firstStore, status: .blocked)
        _ = library.newWindow(name: "second")
        firstStore.selectSession(origin.id)

        #expect(step(library, from: first, eligible: { $0 != first }) == local.id)
    }

    @Test func honorsEachWindowsFocusFilter() throws {
        let library = WindowLibrary(directory: directory)
        let first = try #require(library.activeWindowID)
        let firstStore = try #require(library.store(for: first))
        let origin = try addSession(to: firstStore, status: .idle)
        let second = library.newWindow(name: "second")
        let secondStore = try #require(library.store(for: second.id))
        _ = try addSession(to: secondStore, status: .blocked)
        let marked = secondStore.addWorkspace(name: "marked")
        let shown = try addSession(to: secondStore, status: .completed, workspace: marked.id)
        secondStore.setFocusMembership(marked.id, member: true)
        secondStore.setFocusEnabled(true)
        firstStore.selectSession(origin.id)

        #expect(step(library, from: first) == shown.id)
    }

    @Test(arguments: [false, true])
    func appliesEachWindowsIncludesActiveRule(included: Bool) throws {
        let library = WindowLibrary(directory: directory)
        let first = try #require(library.activeWindowID)
        let firstStore = try #require(library.store(for: first))
        let origin = try addSession(to: firstStore, status: .idle)
        let second = library.newWindow(name: "second")
        let secondStore = try #require(library.store(for: second.id))
        let running = try addSession(to: secondStore, status: .active)
        secondStore.attentionIncludesActive = included
        firstStore.selectSession(origin.id)

        #expect(step(library, from: first) == (included ? running.id : nil))
    }

    @Test(arguments: [true, false])
    func matchesTheInWindowStepWithOneWindowOpen(forward: Bool) throws {
        let library = WindowLibrary(directory: directory)
        let store = try #require(library.activeStore)
        let source = try #require(library.activeWindowID)
        _ = try addSession(to: store, status: .completed)
        let origin = try addSession(to: store, status: .idle)
        _ = try addSession(to: store, status: .blocked)
        store.selectSession(origin.id)

        let crossed = step(library, from: source, forward: forward)
        store.navigateSession(forward ? .nextAttention : .previousAttention)

        #expect(crossed != nil)
        #expect(crossed == store.selectedSessionID)
    }

    @Test func theStoreStepStaysInItsWindowWithTheFlagOn() throws {
        let library = WindowLibrary(directory: directory)
        let firstStore = try #require(library.activeStore)
        let origin = try addSession(to: firstStore, status: .idle)
        let second = library.newWindow(name: "second")
        _ = try addSession(to: try #require(library.store(for: second.id)), status: .blocked)
        firstStore.attentionNavigationAcrossWindows = true
        firstStore.selectSession(origin.id)

        #expect(firstStore.navigateSession(.nextAttention) == nil)
        #expect(firstStore.selectedSessionID == origin.id)
    }

    @Test(arguments: [true, false])
    func entersAtTheEndsWithNoSelection(forward: Bool) throws {
        let library = WindowLibrary(directory: directory)
        let first = try #require(library.activeWindowID)
        let firstStore = try #require(library.store(for: first))
        let early = try addSession(to: firstStore, status: .completed)
        let second = library.newWindow(name: "second")
        let late = try addSession(to: try #require(library.store(for: second.id)), status: .blocked)
        firstStore.selectSession(nil)

        #expect(step(library, from: first, forward: forward) == (forward ? early.id : late.id))
    }
}
