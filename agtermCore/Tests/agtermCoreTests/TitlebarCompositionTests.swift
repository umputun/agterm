import Testing
@testable import agtermCore

struct TitlebarCompositionTests {
    private func compose(workspace: String? = nil, session: String? = "alpha", window: String? = nil,
                         context: String? = nil, detail: String = "/repo", host: String? = nil,
                         mode: ToolbarMode) -> TitlebarComposition {
        TitlebarComposition.compose(
            TitlebarComposition.Parts(workspaceName: workspace, sessionName: session, windowName: window,
                                      context: context, detail: detail, remoteHost: host),
            mode: mode
        )
    }

    @Test(arguments: [ToolbarMode.normal, .compact, .hidden])
    func noContextLeavesEveryModeAsItWas(mode: ToolbarMode) {
        let composed = compose(window: "main", mode: mode)
        switch mode {
        case .normal:
            #expect(composed == TitlebarComposition(title: "alpha — main", subtitle: "/repo"))
        case .compact:
            #expect(composed == TitlebarComposition(title: "alpha — main", subtitle: ""))
        case .hidden:
            #expect(composed == TitlebarComposition(title: "", subtitle: ""))
        }
    }

    @Test func normalPutsContextOnLineTwoInPlaceOfTheDetail() {
        let composed = compose(window: "main", context: "PR #517", mode: .normal)
        #expect(composed.title == "alpha — main")
        #expect(composed.subtitle == "PR #517")
    }

    @Test func normalKeepsTheDetailWhenNoContextIsSet() {
        #expect(compose(mode: .normal).subtitle == "/repo")
    }

    @Test func compactAppendsContextAfterTheIdentitySoTruncationEatsItFirst() {
        let composed = compose(window: "main", context: "PR #517", mode: .compact)
        #expect(composed.title == "alpha — main")
        #expect(composed.tail == " · PR #517")
        #expect(composed.subtitle == "")
    }

    @Test func compactShowsContextAloneWhenEveryIdentityPartIsHidden() {
        let composed = compose(session: nil, window: nil, context: "PR #517", mode: .compact)
        #expect(composed.title == "")
        #expect(composed.tail == "PR #517")
    }

    @Test func hiddenComposesNothingEvenWithAContext() {
        #expect(compose(window: "main", context: "PR #517", mode: .hidden) ==
            TitlebarComposition(title: "", subtitle: ""))
    }

    @Test func aHiddenSessionNameLeavesTheWindowNameAlone() {
        #expect(compose(session: nil, window: "main", mode: .normal).title == "main")
        #expect(compose(session: "alpha", window: nil, mode: .normal).title == "alpha")
        #expect(compose(session: nil, window: nil, mode: .normal).title == "")
    }

    @Test func aHiddenIdentityStillLeavesTheContextOnLineTwoInNormal() {
        let composed = compose(session: nil, window: nil, context: "PR #517", mode: .normal)
        #expect(composed.title == "")
        #expect(composed.subtitle == "PR #517")
    }

    @Test(arguments: [ToolbarMode.normal, .compact])
    func remoteHostStaysOnLineOneAlongsideIdentityAndContext(mode: ToolbarMode) {
        let host = "builder@long.internal.example.com"
        let composed = compose(window: "main", context: "PR #517", host: host, mode: mode)
        #expect(composed.title == "alpha — main")
        #expect(composed.host == host)
        #expect(composed.tail == (mode == .compact ? " · PR #517" : ""))
        #expect(composed.subtitle == (mode == .normal ? "PR #517" : ""))
    }

    @Test(arguments: [ToolbarMode.normal, .compact])
    func remoteHostCanStandAloneWithBothNamesHidden(mode: ToolbarMode) {
        let composed = compose(session: nil, host: "buildbox", mode: mode)
        #expect(composed.title.isEmpty)
        #expect(composed.host == "buildbox")
        #expect(composed.tail.isEmpty)
    }

    @Test func compactContextKeepsItsSeparatorAfterAHostAlone() {
        let composed = compose(session: nil, context: "PR #517", host: "buildbox", mode: .compact)
        #expect(composed.title.isEmpty)
        #expect(composed.host == "buildbox")
        #expect(composed.tail == " · PR #517")
    }

    @Test func hiddenModeDropsEveryRemotePart() {
        let composed = compose(window: "main", context: "PR #517", host: "buildbox", mode: .hidden)
        #expect(composed.title.isEmpty)
        #expect(composed.host == nil)
        #expect(composed.tail.isEmpty)
        #expect(composed.subtitle.isEmpty)
    }

    @Test(arguments: [
        (workspace: "work" as String?, session: "alpha" as String?, window: "main" as String?, title: "work — alpha — main"),
        (workspace: "work", session: "alpha", window: nil, title: "work — alpha"),
        (workspace: "work", session: nil, window: "main", title: "work — main"),
        (workspace: "work", session: nil, window: nil, title: "work"),
        (workspace: nil, session: "alpha", window: "main", title: "alpha — main"),
        (workspace: nil, session: "alpha", window: nil, title: "alpha"),
        (workspace: nil, session: nil, window: "main", title: "main"),
        (workspace: nil, session: nil, window: nil, title: ""),
    ])
    func workspaceLeadsTheIdentityAndEveryAbsentPartCollapses(
        workspace: String?, session: String?, window: String?, title: String
    ) {
        for mode in [ToolbarMode.normal, .compact] {
            #expect(compose(workspace: workspace, session: session, window: window, mode: mode).title == title)
        }
    }

    @Test func workspaceStaysAheadOfTheHostAndCompactContext() {
        let composed = compose(workspace: "work", window: "main", context: "PR #517", host: "buildbox", mode: .compact)
        #expect(composed.title == "work — alpha — main")
        #expect(composed.host == "buildbox")
        #expect(composed.tail == " · PR #517")
    }

    @Test func hiddenModeDropsTheWorkspaceToo() {
        #expect(compose(workspace: "work", window: "main", mode: .hidden).title.isEmpty)
    }

    @Test func workspaceNameIsCappedWithAnEllipsisPastTheLimit() {
        let limit = TitlebarComposition.workspaceNameLimit
        let exact = String(repeating: "w", count: limit)
        #expect(compose(workspace: exact, mode: .compact).title == exact + " — alpha")
        let over = exact + "x"
        #expect(compose(workspace: over, mode: .compact).title == exact + "… — alpha")
    }

    @Test func workspaceCapCountsCharactersNotBytes() {
        let name = String(repeating: "ж", count: TitlebarComposition.workspaceNameLimit)
        #expect(compose(workspace: name, mode: .normal).title == name + " — alpha")
        #expect(compose(workspace: name + "ж", mode: .normal).title == name + "… — alpha")
    }

    @Test func workspaceCapKeepsAComposedCharacterWhole() {
        let family = "👨‍👩‍👧‍👦"
        let name = String(repeating: family, count: TitlebarComposition.workspaceNameLimit)
        #expect(compose(workspace: name, mode: .normal).title == name + " — alpha")
        let capped = compose(workspace: name + "x", mode: .normal).title
        #expect(capped == name + "… — alpha")
        #expect(capped.hasPrefix(String(repeating: family, count: TitlebarComposition.workspaceNameLimit) + "…"))
    }

    @Test func blankWorkspaceNameCollapsesLikeAnAbsentOne() {
        #expect(compose(workspace: "   ", window: "main", mode: .normal).title == "alpha — main")
        #expect(compose(workspace: "  work  ", mode: .normal).title == "work — alpha")
    }
}
