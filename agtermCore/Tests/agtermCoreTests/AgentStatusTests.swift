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
        // blocked/completed clear on ANY key — you've engaged with the prompt / finished result
        #expect(AgentStatus.blocked.clearedByKeystroke(isInterrupt: false))
        #expect(AgentStatus.blocked.clearedByKeystroke(isInterrupt: true))
        #expect(AgentStatus.completed.clearedByKeystroke(isInterrupt: false))
        #expect(AgentStatus.completed.clearedByKeystroke(isInterrupt: true))
        // active clears ONLY on an interrupt keystroke (Esc or Ctrl-C); ordinary typing leaves the glyph
        #expect(!AgentStatus.active.clearedByKeystroke(isInterrupt: false))
        #expect(AgentStatus.active.clearedByKeystroke(isInterrupt: true))
        // idle has no glyph to clear
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
        // matching pane clears iff the status itself is clearable by that keystroke
        #expect(AgentIndicator(status: .blocked, statusPane: .right).clearedBy(pane: .right, isInterrupt: false))
        #expect(AgentIndicator(status: .blocked, statusPane: .right).clearedBy(pane: .right, isInterrupt: true))
        #expect(AgentIndicator(status: .completed, statusPane: .scratch).clearedBy(pane: .scratch, isInterrupt: false))
        // active clears only on an interrupt keystroke, and only for its own pane
        #expect(!AgentIndicator(status: .active, statusPane: .right).clearedBy(pane: .right, isInterrupt: false))
        #expect(AgentIndicator(status: .active, statusPane: .right).clearedBy(pane: .right, isInterrupt: true))
        // idle never clears
        #expect(!AgentIndicator(status: .idle, statusPane: .right).clearedBy(pane: .right, isInterrupt: true))
    }

    @Test func clearedByNonMatchingPaneNeverClears() {
        // a keystroke from a different pane must never clear a background block
        #expect(!AgentIndicator(status: .blocked, statusPane: .right).clearedBy(pane: .left, isInterrupt: false))
        #expect(!AgentIndicator(status: .blocked, statusPane: .right).clearedBy(pane: .left, isInterrupt: true))
        #expect(!AgentIndicator(status: .blocked, statusPane: .scratch).clearedBy(pane: .left, isInterrupt: false))
        #expect(!AgentIndicator(status: .active, statusPane: .scratch).clearedBy(pane: .right, isInterrupt: true))
    }

    @Test func clearedByNilStatusPaneTreatedAsLeft() {
        // nil statusPane behaves as .left (main): a left keystroke clears, right/scratch do not
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
        // explicit per-call sound wins on any status, even when a blocked default is set.
        #expect(AgentStatus.blocked.effectiveSound(perCall: "Glass", blockedDefault: "Sosumi") == "Glass")
        #expect(AgentStatus.active.effectiveSound(perCall: "Glass", blockedDefault: "Sosumi") == "Glass")
    }

    @Test func effectiveSoundUsesBlockedDefaultOnlyForBlocked() {
        // no per-call sound: the configured default plays for blocked, but never for the other states.
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
        // blocked is most urgent, then active, then completed
        #expect(AgentStatus.blocked.attentionRank < AgentStatus.active.attentionRank)
        #expect(AgentStatus.active.attentionRank < AgentStatus.completed.attentionRank)
        #expect(AgentStatus.blocked.attentionRank == 0)
        #expect(AgentStatus.active.attentionRank == 1)
        #expect(AgentStatus.completed.attentionRank == 2)
        // idle is never sorted (filtered out first); sorts after the non-idle states
        #expect(AgentStatus.completed.attentionRank < AgentStatus.idle.attentionRank)
    }

    @Test func symbolNameMapsNonIdleStatesAndIdleIsEmpty() {
        #expect(AgentStatus.active.symbolName == "ellipsis.circle.fill")
        #expect(AgentStatus.blocked.symbolName == "exclamationmark.circle.fill")
        #expect(AgentStatus.completed.symbolName == "checkmark.circle.fill")
        // idle never renders a glyph
        #expect(AgentStatus.idle.symbolName == "")
    }
}
