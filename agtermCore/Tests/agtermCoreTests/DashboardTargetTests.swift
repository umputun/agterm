import Foundation
import Testing
@testable import agtermCore

struct DashboardTargetTests {
    private let uuid = "9F3CAAAA-0000-0000-0000-000000000001"

    @Test func bareTargetHasNoPane() {
        let target = DashboardTarget(rawValue: uuid)
        #expect(target == DashboardTarget(head: uuid, pane: nil))
    }

    @Test func bareActiveHasNoPane() {
        #expect(DashboardTarget(rawValue: "active") == DashboardTarget(head: "active", pane: nil))
    }

    @Test func barePrefixHasNoPane() {
        #expect(DashboardTarget(rawValue: "9F3C") == DashboardTarget(head: "9F3C", pane: nil))
    }

    @Test func leftSuffixSelectsPrimary() {
        #expect(DashboardTarget(rawValue: "\(uuid):left") == DashboardTarget(head: uuid, pane: .primary))
    }

    @Test func rightSuffixSelectsSplit() {
        #expect(DashboardTarget(rawValue: "\(uuid):right") == DashboardTarget(head: uuid, pane: .split))
    }

    @Test func activeCarriesASuffix() {
        #expect(DashboardTarget(rawValue: "active:left") == DashboardTarget(head: "active", pane: .primary))
    }

    @Test func prefixCarriesASuffix() {
        #expect(DashboardTarget(rawValue: "9F3C:right") == DashboardTarget(head: "9F3C", pane: .split))
    }

    @Test(arguments: ["LEFT", "Left", "lEfT"])
    func paneSuffixIsCaseInsensitive(_ suffix: String) {
        #expect(DashboardTarget(rawValue: "\(uuid):\(suffix)")?.pane == .primary)
    }

    @Test func headCaseIsPreservedForTheResolver() {
        #expect(DashboardTarget(rawValue: "\(uuid):left")?.head == uuid)
    }

    @Test func emptyTargetIsRejected() {
        #expect(DashboardTarget(rawValue: "") == nil)
    }

    @Test func emptyHeadIsRejected() {
        #expect(DashboardTarget(rawValue: ":left") == nil)
    }

    @Test func emptyPaneIsRejected() {
        #expect(DashboardTarget(rawValue: "\(uuid):") == nil)
    }

    @Test func typoedPaneIsRejectedRatherThanTreatedAsAHead() {
        #expect(DashboardTarget(rawValue: "\(uuid):lft") == nil)
    }

    // primary/split parse as TerminalZoomSurface but are not the spelling dashboardMembers emits
    @Test(arguments: ["primary", "split"])
    func enumAliasSpellingsAreRejected(_ suffix: String) {
        #expect(DashboardTarget(rawValue: "\(uuid):\(suffix)") == nil)
    }

    @Test(arguments: ["scratch", "overlay"])
    func nonMemberSurfacesAreRejected(_ suffix: String) {
        #expect(DashboardTarget(rawValue: "\(uuid):\(suffix)") == nil)
    }

    // the pane-overlay zoom surfaces parse as TerminalZoomSurface; the allowlist here must keep refusing them
    @Test(arguments: ["overlay-left", "overlay-right"])
    func paneOverlaySurfacesAreRejected(_ suffix: String) {
        #expect(TerminalZoomSurface(controlName: suffix) != nil)
        #expect(DashboardTarget(rawValue: "\(uuid):\(suffix)") == nil)
    }

    // the surface.zoom form must fail outright, not resolve to a head of "surface"
    @Test func surfaceZoomFormIsRejected() {
        #expect(DashboardTarget(rawValue: "surface:\(uuid):left") == nil)
    }
}
