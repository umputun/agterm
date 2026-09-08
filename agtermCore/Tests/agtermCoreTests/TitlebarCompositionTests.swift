import Testing
@testable import agtermCore

struct TitlebarCompositionTests {
    private func compose(session: String? = "alpha", window: String? = nil, context: String? = nil,
                         detail: String = "/repo", host: String? = nil, mode: ToolbarMode) -> TitlebarComposition {
        TitlebarComposition.compose(
            TitlebarComposition.Parts(sessionName: session, windowName: window, context: context, detail: detail,
                                      remoteHost: host),
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
}
