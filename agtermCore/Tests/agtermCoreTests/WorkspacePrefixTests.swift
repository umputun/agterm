import Foundation
import Testing
@testable import agtermCore

struct WorkspacePrefixTests {
    @Test func matchesFromTheStartIgnoringCaseAndDiacritics() {
        #expect(WorkspacePrefix.matches("AG", name: "agterm"))
        #expect(WorkspacePrefix.matches("cafe", name: "Café ops"))
        #expect(!WorkspacePrefix.matches("term", name: "agterm"))
    }

    @Test func emptyPrefixMatchesNothing() {
        #expect(WorkspacePrefix.matchingIndices("", in: ["a", "b"]).isEmpty)
        #expect(WorkspacePrefix.resolve("", in: ["a"]) == .none)
    }

    @Test func resolvesUniqueNoneAndAmbiguous() {
        let names = ["agterm", "api", "api-v2", "billing"]
        #expect(WorkspacePrefix.resolve("ag", in: names) == .match(0))
        #expect(WorkspacePrefix.resolve("z", in: names) == .none)
        #expect(WorkspacePrefix.resolve("a", in: names) == .ambiguous([0, 1, 2]))
    }

    @Test func aLoneExactNameBeatsLongerNamesSharingIt() {
        #expect(WorkspacePrefix.resolve("API", in: ["api", "api-v2"]) == .match(0))
        #expect(WorkspacePrefix.resolve("api", in: ["api", "API"]) == .ambiguous([0, 1]))
    }
}

@MainActor
struct AppStoreWorkspacePrefixTests {
    @Test func resolvesWithinTheFocusFilter() {
        let store = makeStore()
        let agterm = store.addWorkspace(name: "agterm")
        let api = store.addWorkspace(name: "api")
        #expect(store.resolveWorkspacePrefix("a") == .ambiguous(["agterm", "api"]))
        store.setFocusedWorkspace(api.id)
        #expect(store.resolveWorkspacePrefix("a") == .workspace(api.id))
        #expect(store.resolveWorkspacePrefix("ag") == .none, "a filtered-out workspace has no row to land on")
        store.setFocusEnabled(false)
        #expect(store.resolveWorkspacePrefix("ag") == .workspace(agterm.id))
    }

    @Test func isUnavailableInFlaggedMode() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: work.id, cwd: "/a")!
        store.setFlag(true, forSession: session.id)
        store.setSidebarMode(.flagged)
        #expect(store.resolveWorkspacePrefix("work") == .unavailable)
    }

    @Test func controlErrorNamesTheOutcome() {
        #expect(WorkspacePrefixOutcome.workspace(UUID()).controlError(prefix: "a") == nil)
        #expect(WorkspacePrefixOutcome.none.controlError(prefix: "zz") == "no workspace matches prefix: zz")
        #expect(WorkspacePrefixOutcome.ambiguous(["agterm", "api"]).controlError(prefix: "a")
            == "prefix a matches several workspaces: agterm, api")
    }
}
