import Testing
@testable import agtermCore

struct AgentStatusTests {
    @Test func rawValueRoundTrip() {
        #expect(AgentStatus(rawValue: "idle") == .idle)
        #expect(AgentStatus(rawValue: "active") == .active)
        #expect(AgentStatus(rawValue: "completed") == .completed)
        #expect(AgentStatus(rawValue: "blocked") == .blocked)
    }

    @Test func unknownRawValueIsNil() {
        #expect(AgentStatus(rawValue: "running") == nil)
        #expect(AgentStatus(rawValue: "") == nil)
        #expect(AgentStatus(rawValue: "Active") == nil) // case-sensitive
    }

    @Test func allCasesCoverAllStates() {
        #expect(AgentStatus.allCases == [.idle, .active, .completed, .blocked])
    }

    @Test func needsAttentionOnlyBlockedAndCompleted() {
        #expect(AgentStatus.blocked.needsAttention)
        #expect(AgentStatus.completed.needsAttention)
        #expect(!AgentStatus.idle.needsAttention)
        #expect(!AgentStatus.active.needsAttention)
    }

    @Test func clearedByKeystrokeClearsAttentionAlwaysAndActiveOnlyOnInterrupt() {
        #expect(AgentStatus.blocked.clearedByKeystroke(isInterrupt: false))
        #expect(AgentStatus.blocked.clearedByKeystroke(isInterrupt: true))
        #expect(AgentStatus.completed.clearedByKeystroke(isInterrupt: false))
        #expect(AgentStatus.completed.clearedByKeystroke(isInterrupt: true))
        // isInterrupt = Esc or Ctrl-C; ordinary typing leaves the glyph
        #expect(!AgentStatus.active.clearedByKeystroke(isInterrupt: false))
        #expect(AgentStatus.active.clearedByKeystroke(isInterrupt: true))
        #expect(!AgentStatus.idle.clearedByKeystroke(isInterrupt: false))
        #expect(!AgentStatus.idle.clearedByKeystroke(isInterrupt: true))
    }

    @Test func indicatorDefaults() {
        let indicator = AgentIndicator()
        #expect(indicator.status == .idle)
        #expect(indicator.blink == false)
        #expect(indicator.autoReset == false)
        #expect(indicator.color == nil)
        #expect(indicator.statusPane == nil)
    }

    @Test func indicatorCustomInit() {
        let indicator = AgentIndicator(status: .active, blink: true, autoReset: true, color: "#ff0000")
        #expect(indicator.status == .active)
        #expect(indicator.blink == true)
        #expect(indicator.autoReset == true)
        #expect(indicator.color == "#ff0000")
        #expect(indicator.statusPane == nil)
    }

    @Test func statusPaneRawValueRoundTrip() {
        #expect(StatusPane(rawValue: "left") == .left)
        #expect(StatusPane(rawValue: "right") == .right)
        #expect(StatusPane(rawValue: "scratch") == .scratch)
        #expect(StatusPane(rawValue: "main") == nil)
        #expect(StatusPane.allCases == [.left, .right, .scratch])
    }

    @Test func statusPaneControlAliasesPreserveCanonicalReadback() {
        for alias in ["left", "top", "primary"] {
            #expect(StatusPane(controlName: alias) == .left)
            #expect(StatusPane(controlName: alias)?.rawValue == "left")
        }
        for alias in ["right", "bottom", "split"] {
            #expect(StatusPane(controlName: alias) == .right)
            #expect(StatusPane(controlName: alias)?.rawValue == "right")
        }
    }

    @Test func indicatorCarriesStatusPane() {
        let indicator = AgentIndicator(status: .blocked, statusPane: .right)
        #expect(indicator.status == .blocked)
        #expect(indicator.statusPane == .right)
    }

    @Test func indicatorEquatableIncludesStatusPane() {
        #expect(AgentIndicator(status: .blocked, statusPane: .right) == AgentIndicator(status: .blocked, statusPane: .right))
        #expect(AgentIndicator(status: .blocked, statusPane: .right) != AgentIndicator(status: .blocked, statusPane: .left))
        #expect(AgentIndicator(status: .blocked, statusPane: .right) != AgentIndicator(status: .blocked))
    }

    @Test func clearedByMatchingPaneFollowsClearedByKeystroke() {
        #expect(AgentIndicator(status: .blocked, statusPane: .right).clearedBy(pane: .right, isInterrupt: false))
        #expect(AgentIndicator(status: .blocked, statusPane: .right).clearedBy(pane: .right, isInterrupt: true))
        #expect(AgentIndicator(status: .completed, statusPane: .scratch).clearedBy(pane: .scratch, isInterrupt: false))
        #expect(!AgentIndicator(status: .active, statusPane: .right).clearedBy(pane: .right, isInterrupt: false))
        #expect(AgentIndicator(status: .active, statusPane: .right).clearedBy(pane: .right, isInterrupt: true))
        #expect(!AgentIndicator(status: .idle, statusPane: .right).clearedBy(pane: .right, isInterrupt: true))
    }

    @Test func clearedByNonMatchingPaneNeverClears() {
        #expect(!AgentIndicator(status: .blocked, statusPane: .right).clearedBy(pane: .left, isInterrupt: false))
        #expect(!AgentIndicator(status: .blocked, statusPane: .right).clearedBy(pane: .left, isInterrupt: true))
        #expect(!AgentIndicator(status: .blocked, statusPane: .scratch).clearedBy(pane: .left, isInterrupt: false))
        #expect(!AgentIndicator(status: .active, statusPane: .scratch).clearedBy(pane: .right, isInterrupt: true))
    }

    @Test func clearedByNilStatusPaneTreatedAsLeft() {
        #expect(AgentIndicator(status: .blocked).clearedBy(pane: .left, isInterrupt: false))
        #expect(!AgentIndicator(status: .blocked).clearedBy(pane: .right, isInterrupt: false))
        #expect(!AgentIndicator(status: .blocked).clearedBy(pane: .scratch, isInterrupt: true))
        #expect(AgentIndicator(status: .active).clearedBy(pane: .left, isInterrupt: true))
        #expect(!AgentIndicator(status: .active).clearedBy(pane: .left, isInterrupt: false))
    }

    @Test func indicatorEquatableEqual() {
        #expect(AgentIndicator(status: .blocked, blink: true) == AgentIndicator(status: .blocked, blink: true))
        #expect(AgentIndicator() == AgentIndicator(status: .idle, blink: false, autoReset: false))
        #expect(AgentIndicator(status: .completed, autoReset: true) == AgentIndicator(status: .completed, autoReset: true))
    }

    @Test func effectiveSoundPrefersPerCallOverDefault() {
        #expect(AgentStatus.blocked.effectiveSound(perCall: "Glass", blockedDefault: "Sosumi") == "Glass")
        #expect(AgentStatus.active.effectiveSound(perCall: "Glass", blockedDefault: "Sosumi") == "Glass")
    }

    @Test func effectiveSoundUsesBlockedDefaultOnlyForBlocked() {
        #expect(AgentStatus.blocked.effectiveSound(perCall: nil, blockedDefault: "Sosumi") == "Sosumi")
        #expect(AgentStatus.active.effectiveSound(perCall: nil, blockedDefault: "Sosumi") == nil)
        #expect(AgentStatus.completed.effectiveSound(perCall: nil, blockedDefault: "Sosumi") == nil)
        #expect(AgentStatus.idle.effectiveSound(perCall: nil, blockedDefault: "Sosumi") == nil)
    }

    @Test func effectiveSoundTreatsEmptyAsUnset() {
        #expect(AgentStatus.blocked.effectiveSound(perCall: "", blockedDefault: "Sosumi") == "Sosumi")
        #expect(AgentStatus.blocked.effectiveSound(perCall: nil, blockedDefault: "") == nil)
        #expect(AgentStatus.blocked.effectiveSound(perCall: nil, blockedDefault: nil) == nil)
    }

    @Test func indicatorEquatableNotEqual() {
        #expect(AgentIndicator(status: .active) != AgentIndicator(status: .completed))
        #expect(AgentIndicator(status: .active, blink: true) != AgentIndicator(status: .active, blink: false))
        #expect(AgentIndicator(status: .completed, autoReset: true) != AgentIndicator(status: .completed, autoReset: false))
        // a color-only difference is distinguished, so a color change reloads the sidebar row (RowContent).
        #expect(AgentIndicator(status: .blocked, color: "#ff0000") != AgentIndicator(status: .blocked))
        #expect(AgentIndicator(status: .blocked, color: "#ff0000") != AgentIndicator(status: .blocked, color: "#00ff00"))
    }

    @Test func attentionRankOrdersBlockedActiveCompleted() {
        #expect(AgentStatus.blocked.attentionRank < AgentStatus.active.attentionRank)
        #expect(AgentStatus.active.attentionRank < AgentStatus.completed.attentionRank)
        #expect(AgentStatus.blocked.attentionRank == 0)
        #expect(AgentStatus.active.attentionRank == 1)
        #expect(AgentStatus.completed.attentionRank == 2)
        // idle is filtered out before sorting, so it ranks after the non-idle states
        #expect(AgentStatus.completed.attentionRank < AgentStatus.idle.attentionRank)
    }

    @Test func symbolNameMapsNonIdleStatesAndIdleIsEmpty() {
        // every unconfigured state draws the same plain circle; the tint is what tells them apart
        #expect(AgentStatus.active.symbolName(override: nil, configured: nil) == "circle.fill")
        #expect(AgentStatus.blocked.symbolName(override: nil, configured: nil) == "circle.fill")
        #expect(AgentStatus.completed.symbolName(override: nil, configured: nil) == "circle.fill")
        #expect(AgentStatus.idle.symbolName(override: nil, configured: nil) == "")
    }

    @Test func statusShapeSymbolNamesAreFilledVariants() {
        #expect(StatusShape.circle.symbolName == "circle.fill")
        #expect(StatusShape.square.symbolName == "square.fill")
        #expect(StatusShape.triangle.symbolName == "triangle.fill")
        #expect(StatusShape.diamond.symbolName == "diamond.fill")
        #expect(StatusShape.capsule.symbolName == "capsule.fill")
        #expect(StatusShape.star.symbolName == "star.fill")
    }

    @Test func statusShapeDisplayNamesAreCapitalizedRawValues() {
        // the e2e's menu-item titles and its post-relaunch picker value are pinned here, not in the view
        #expect(StatusShape.circle.displayName == "Circle")
        #expect(StatusShape.square.displayName == "Square")
        #expect(StatusShape.triangle.displayName == "Triangle")
        #expect(StatusShape.diamond.displayName == "Diamond")
        #expect(StatusShape.capsule.displayName == "Capsule")
        #expect(StatusShape.star.displayName == "Star")
    }

    @Test func statusShapeValidNamesCoverEveryCaseInBothJoinedForms() {
        // the dispatcher's rejection uses the pipe form, the CLI's help and rejection the comma form
        #expect(StatusShape.validNamesList == "circle|square|triangle|diamond|capsule|star")
        #expect(StatusShape.validNamesPhrase == "circle, square, triangle, diamond, capsule, star")
        for shape in StatusShape.allCases {
            #expect(StatusShape.validNamesList.contains(shape.rawValue))
            #expect(StatusShape.validNamesPhrase.contains(shape.rawValue))
        }
    }

    @Test func statusShapeAllCasesAndRawValues() {
        #expect(StatusShape.allCases == [.circle, .square, .triangle, .diamond, .capsule, .star])
        #expect(StatusShape(rawValue: "triangle") == .triangle)
        #expect(StatusShape(rawValue: "hexagon") == nil)
        #expect(StatusShape(rawValue: "Circle") == nil) // case-sensitive
        #expect(StatusShape(rawValue: "") == nil)
    }

    @Test func symbolNameOverrideWinsOverConfigured() {
        #expect(AgentStatus.blocked.symbolName(override: .triangle, configured: .square) == "triangle.fill")
        #expect(AgentStatus.active.symbolName(override: .star, configured: nil) == "star.fill")
        // an explicit circle override is a real choice, not "unset", so it still beats the configured shape
        #expect(AgentStatus.completed.symbolName(override: .circle, configured: .star) == "circle.fill")
    }

    @Test func symbolNameConfiguredWinsOverDefault() {
        #expect(AgentStatus.active.symbolName(override: nil, configured: .capsule) == "capsule.fill")
        #expect(AgentStatus.blocked.symbolName(override: nil, configured: .diamond) == "diamond.fill")
        #expect(AgentStatus.completed.symbolName(override: nil, configured: .square) == "square.fill")
    }

    @Test func symbolNameBothNilIsThePlainCircleDefault() {
        #expect(AgentStatus.active.symbolName(override: nil, configured: nil) == StatusShape.circle.symbolName)
        #expect(AgentStatus.blocked.symbolName(override: nil, configured: nil) == StatusShape.circle.symbolName)
        #expect(AgentStatus.completed.symbolName(override: nil, configured: nil) == StatusShape.circle.symbolName)
        #expect(AgentStatus.blocked.symbolName(override: nil, configured: nil)
            == AgentStatus.blocked.symbolName(override: nil, configured: .circle))
    }

    @Test func symbolNameIdleIsEmptyInEveryCombination() {
        #expect(AgentStatus.idle.symbolName(override: nil, configured: nil) == "")
        #expect(AgentStatus.idle.symbolName(override: .star, configured: nil) == "")
        #expect(AgentStatus.idle.symbolName(override: nil, configured: .square) == "")
        #expect(AgentStatus.idle.symbolName(override: .star, configured: .square) == "")
    }

    @Test func indicatorShapeParticipatesInEquality() {
        // a shape-only difference is distinguished, so a shape change reloads the sidebar row (RowContent).
        #expect(AgentIndicator(status: .blocked, shape: .triangle) != AgentIndicator(status: .blocked))
        #expect(AgentIndicator(status: .blocked, shape: .triangle) != AgentIndicator(status: .blocked, shape: .square))
        #expect(AgentIndicator(status: .blocked, shape: .triangle) == AgentIndicator(status: .blocked, shape: .triangle))
        #expect(AgentIndicator(status: .blocked).shape == nil)
    }

    @Test func tooltipTextNamesVisibleStatusesAndOmitsIdle() {
        #expect(AgentStatus.active.tooltipText == "Agent status: Active")
        #expect(AgentStatus.blocked.tooltipText == "Agent status: Blocked")
        #expect(AgentStatus.completed.tooltipText == "Agent status: Completed")
        #expect(AgentStatus.idle.tooltipText == nil)
    }
}
