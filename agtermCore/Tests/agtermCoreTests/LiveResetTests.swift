import Foundation
import Testing
@testable import agtermCore

struct LiveResetTests {
    private static let windowID = UUID()
    private static let sessionA = UUID()
    private static let sessionB = UUID()
    private static let paneA = UUID()
    private static let paneASplit = UUID()
    private static let paneB = UUID()

    private static func claim(_ pane: UUID, role: ZmxPaneRole = .left, session: UUID = sessionA) -> ZmxPaneClaim {
        ZmxPaneClaim(paneIdentity: pane, pane: role, pendingClose: false, windowID: windowID, windowName: "w",
                     windowState: .open, workspaceID: nil, workspaceName: "default",
                     sessionID: session, sessionName: "build")
    }

    private static func record(_ pane: UUID, leader: Int32?) -> ZmxSessionRecord {
        ZmxSessionRecord(name: ZmxSupport.daemonName(for: pane), clients: 0, leaderPID: leader)
    }

    private static func target(_ pane: UUID, session: UUID = sessionA, leader: Int32) -> LiveReset.Target {
        LiveReset.Target(paneIdentity: pane, sessionID: session, daemon: ZmxSupport.daemonName(for: pane), leaderPID: leader)
    }

    private static func classifier(_ table: [String: SessionHost.Attribution]) -> (String, Int32) -> SessionHost.Attribution {
        { name, _ in table[name] ?? .unknown }
    }

    @Test func selectKeepsOrphanedAndAppPanesOnly() {
        let paneC = UUID(), paneD = UUID()
        let claims = ZmxClaimWalk(claims: [Self.claim(Self.paneA), Self.claim(Self.paneB, session: Self.sessionB),
                                           Self.claim(paneC), Self.claim(paneD)], complete: true)
        let records = [Self.record(Self.paneA, leader: 10), Self.record(Self.paneB, leader: 11),
                       Self.record(paneC, leader: 12), Self.record(paneD, leader: 13)]
        let classify = Self.classifier([ZmxSupport.daemonName(for: Self.paneA): .orphaned,
                                        ZmxSupport.daemonName(for: Self.paneB): .app,
                                        ZmxSupport.daemonName(for: paneC): .supervisor,
                                        ZmxSupport.daemonName(for: paneD): .unknown])

        let selection = LiveReset.select(claims: claims, records: records, classify: classify)

        #expect(selection.targets == [Self.target(Self.paneA, leader: 10), Self.target(Self.paneB, session: Self.sessionB, leader: 11)])
        #expect(selection.inventoryComplete)
        #expect(selection.sessionCount == 2)
    }

    @Test func selectExcludesPanesWithoutAReadableLeader() {
        let claims = ZmxClaimWalk(claims: [Self.claim(Self.paneA), Self.claim(Self.paneB)], complete: false)
        let records = [Self.record(Self.paneA, leader: nil)]
        let classify: (String, Int32) -> SessionHost.Attribution = { _, _ in .orphaned }

        let selection = LiveReset.select(claims: claims, records: records, classify: classify)

        #expect(selection.targets.isEmpty)
        #expect(!selection.inventoryComplete)
    }

    @Test func selectCountsASplitSessionOnce() {
        let claims = ZmxClaimWalk(claims: [Self.claim(Self.paneA), Self.claim(Self.paneASplit, role: .right)], complete: true)
        let records = [Self.record(Self.paneA, leader: 10), Self.record(Self.paneASplit, leader: 20)]

        let selection = LiveReset.select(claims: claims, records: records, classify: { _, _ in .orphaned })

        #expect(selection.targets.count == 2)
        #expect(selection.sessionCount == 1)
    }

    @Test func selectRejectsAPaneClaimedTwice() {
        let claims = ZmxClaimWalk(claims: [Self.claim(Self.paneA), Self.claim(Self.paneA, session: Self.sessionB)], complete: true)
        let records = [Self.record(Self.paneA, leader: 10)]

        let selection = LiveReset.select(claims: claims, records: records, classify: { _, _ in .orphaned })

        #expect(selection.targets == [Self.target(Self.paneA, leader: 10)])
        #expect(!selection.inventoryComplete)
    }

    private static func marker(_ targets: [LiveReset.Target]) -> LiveReset.Marker {
        LiveReset.Marker(targets: targets, createdAt: Date(timeIntervalSince1970: 0))
    }

    @Test func narrowKillsOnlyTheSameLeaderStillOrphaned() {
        let marker = Self.marker([Self.target(Self.paneA, leader: 10)])
        let narrowed = LiveReset.narrow(marker: marker, claimed: [Self.paneA],
                                        records: [Self.record(Self.paneA, leader: 10)], classify: { _, _ in .orphaned })

        #expect(narrowed.dispositions == [Self.target(Self.paneA, leader: 10): .kill])
        #expect(narrowed.kill == [Self.target(Self.paneA, leader: 10)])
        #expect(!narrowed.inventoryFailed)
    }

    @Test func narrowMarksAMissingDaemonGone() {
        let marker = Self.marker([Self.target(Self.paneA, leader: 10)])
        let narrowed = LiveReset.narrow(marker: marker, claimed: [Self.paneA], records: [], classify: { _, _ in .orphaned })

        #expect(narrowed.dispositions[Self.target(Self.paneA, leader: 10)] == .gone)
        #expect(narrowed.kill.isEmpty)
    }

    @Test(arguments: [
        (claimed: false, leader: Int32?.some(10), attribution: SessionHost.Attribution.orphaned),
        (claimed: true, leader: Int32?.some(11), attribution: SessionHost.Attribution.orphaned),
        (claimed: true, leader: Int32?.none, attribution: SessionHost.Attribution.orphaned),
        (claimed: true, leader: Int32?.some(10), attribution: SessionHost.Attribution.supervisor),
        (claimed: true, leader: Int32?.some(10), attribution: SessionHost.Attribution.app),
        (claimed: true, leader: Int32?.some(10), attribution: SessionHost.Attribution.unknown),
    ])
    func narrowSkipsUnclaimedChangedUnreadableOrReattributed(claimed: Bool, leader: Int32?, attribution: SessionHost.Attribution) {
        let target = Self.target(Self.paneA, leader: 10)
        let narrowed = LiveReset.narrow(marker: Self.marker([target]), claimed: claimed ? [Self.paneA] : [],
                                        records: [Self.record(Self.paneA, leader: leader)], classify: { _, _ in attribution })

        #expect(narrowed.dispositions[target] == .skipped)
        #expect(narrowed.kill.isEmpty)
    }

    @Test func narrowWithoutAListingKillsNothingAndReportsInventoryFailure() {
        let target = Self.target(Self.paneA, leader: 10)
        let narrowed = LiveReset.narrow(marker: Self.marker([target]), claimed: [Self.paneA], records: nil,
                                        classify: { _, _ in .orphaned })

        #expect(narrowed.inventoryFailed)
        #expect(narrowed.kill.isEmpty)
        #expect(narrowed.dispositions[target] == .skipped)
    }

    @Test func narrowWithoutAListingToleratesADuplicatedMarkerTarget() {
        let target = Self.target(Self.paneA, leader: 10)
        let narrowed = LiveReset.narrow(marker: Self.marker([target, target]), claimed: [Self.paneA], records: nil,
                                        classify: { _, _ in .orphaned })

        #expect(narrowed.inventoryFailed)
        #expect(narrowed.dispositions == [target: .skipped])
    }

    @Test func narrowWithoutClaimsKillsNothing() {
        let target = Self.target(Self.paneA, leader: 10)
        let narrowed = LiveReset.narrow(marker: Self.marker([target]), claimed: nil,
                                        records: [Self.record(Self.paneA, leader: 10)], classify: { _, _ in .orphaned })

        #expect(narrowed.kill.isEmpty)
        #expect(narrowed.dispositions[target] == .skipped)
    }

    @Test func narrowNeverAddsADaemonAbsentFromTheMarker() {
        let target = Self.target(Self.paneA, leader: 10)
        let narrowed = LiveReset.narrow(marker: Self.marker([target]), claimed: [Self.paneA, Self.paneB],
                                        records: [Self.record(Self.paneA, leader: 10), Self.record(Self.paneB, leader: 11)],
                                        classify: { _, _ in .orphaned })

        #expect(narrowed.kill == [target])
        #expect(narrowed.dispositions.count == 1)
    }

    @Test func outcomeCountsASessionResetWhenEveryPaneIsConfirmedOrGone() {
        let a = Self.target(Self.paneA, leader: 10)
        let split = Self.target(Self.paneASplit, leader: 20)
        let b = Self.target(Self.paneB, session: Self.sessionB, leader: 30)
        let narrowed = LiveReset.Narrowed(dispositions: [a: .kill, split: .gone, b: .kill], inventoryFailed: false)

        let outcome = LiveReset.outcome(narrowed: narrowed, survivors: [], inventoryFailed: false)

        #expect(outcome.panes == LiveReset.PaneCounts(confirmed: 3, killed: 2, gone: 1, skipped: 0))
        #expect(outcome.unconfirmed.isEmpty)
        #expect(outcome.sessions == LiveReset.SessionCounts(affected: 2, reset: 2, partial: 0, unconfirmed: 0))
    }

    @Test func outcomeCountsASplitSessionWithOneSurvivorAsOnePartialSession() {
        let a = Self.target(Self.paneA, leader: 10)
        let split = Self.target(Self.paneASplit, leader: 20)
        let narrowed = LiveReset.Narrowed(dispositions: [a: .kill, split: .kill], inventoryFailed: false)

        let outcome = LiveReset.outcome(narrowed: narrowed, survivors: [20], inventoryFailed: false)

        #expect(outcome.panes == LiveReset.PaneCounts(confirmed: 2, killed: 1, gone: 0, skipped: 0))
        #expect(outcome.unconfirmed == [Self.paneASplit])
        #expect(outcome.sessions == LiveReset.SessionCounts(affected: 1, reset: 0, partial: 1, unconfirmed: 1))
    }

    @Test func outcomeCountsTwoSurvivorsInOneSessionOnce() {
        let a = Self.target(Self.paneA, leader: 10)
        let split = Self.target(Self.paneASplit, leader: 20)
        let b = Self.target(Self.paneB, session: Self.sessionB, leader: 30)
        let narrowed = LiveReset.Narrowed(dispositions: [a: .kill, split: .kill, b: .skipped], inventoryFailed: false)

        let outcome = LiveReset.outcome(narrowed: narrowed, survivors: [10, 20], inventoryFailed: false)

        #expect(Set(outcome.unconfirmed) == [Self.paneA, Self.paneASplit])
        #expect(outcome.sessions == LiveReset.SessionCounts(affected: 2, reset: 0, partial: 2, unconfirmed: 1))
        #expect(outcome.panes.skipped == 1)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-live-reset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func markerStoreWritesThenConsumesOnce() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LiveResetMarkerStore(directory: dir)
        let marker = Self.marker([Self.target(Self.paneA, leader: 10)])

        try store.write(marker)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(LiveReset.markerFilename).path))

        let consumed = try store.consume()
        #expect(consumed == marker)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(LiveReset.markerFilename).path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(LiveReset.consumedFilename).path))

        #expect(try store.consume() == nil)

        store.removeConsumed()
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(LiveReset.consumedFilename).path))
    }

    @Test(arguments: ["not json", "{\"version\":2,\"createdAt\":0,\"targets\":[]}"])
    func markerStoreRemovesAnInvalidMarkerAndReportsIt(contents: String) throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LiveResetMarkerStore(directory: dir)
        try contents.write(to: dir.appendingPathComponent(LiveReset.markerFilename), atomically: true, encoding: .utf8)

        #expect(throws: LiveResetMarkerStore.Failure.invalid) { try store.consume() }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(LiveReset.markerFilename).path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(LiveReset.consumedFilename).path))
    }

    @Test func markerStoreRemoveClearsBothFiles() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LiveResetMarkerStore(directory: dir)
        try store.write(Self.marker([]))
        _ = try store.consume()
        try store.write(Self.marker([]))

        store.remove()

        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(LiveReset.markerFilename).path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(LiveReset.consumedFilename).path))
    }

    @Test(arguments: [(1, "1 live session will be reset."), (2, "2 live sessions will be reset.")])
    func dialogTextCountsSessions(count: Int, opening: String) {
        let text = LiveReset.dialogText(sessionCount: count)
        #expect(text.title == "Reset Live Sessions?")
        #expect(text.body.hasPrefix(opening))
        #expect(text.body.contains("quits and reopens itself"))
        #expect(!text.body.lowercased().contains("zmx"))
    }

    @Test func notificationIsSilentWhenEverySessionWasReset() {
        let outcome = LiveReset.Outcome(panes: .init(confirmed: 2, killed: 2, gone: 0, skipped: 0), unconfirmed: [],
                                        sessions: .init(affected: 2, reset: 2, partial: 0, unconfirmed: 0), inventoryFailed: false)
        #expect(LiveReset.notificationText(outcome: outcome) == nil)
    }

    @Test func notificationReportsAPartialResetWithoutSurvivors() {
        let outcome = LiveReset.Outcome(panes: .init(confirmed: 3, killed: 2, gone: 0, skipped: 1), unconfirmed: [],
                                        sessions: .init(affected: 3, reset: 2, partial: 1, unconfirmed: 0), inventoryFailed: false)
        let text = LiveReset.notificationText(outcome: outcome)
        #expect(text == "The reset covered 2 of 3 live sessions. Run Help ▸ Reset Live Sessions… again for the rest.")
    }

    @Test func notificationReportsSurvivorsBySession() {
        let outcome = LiveReset.Outcome(panes: .init(confirmed: 3, killed: 1, gone: 0, skipped: 0),
                                        unconfirmed: [Self.paneA, Self.paneASplit],
                                        sessions: .init(affected: 2, reset: 1, partial: 1, unconfirmed: 1), inventoryFailed: false)
        let text = LiveReset.notificationText(outcome: outcome)
        #expect(text == "The reset covered 1 of 2 live sessions. Run Help ▸ Reset Live Sessions… again for the rest. "
            + "Some previous processes in 1 session may still be running; those commands were not restarted.")
    }

    @Test func notificationForAMixedSessionDoesNotClaimEveryCommandStayedDown() {
        let a = Self.target(Self.paneA, leader: 10)
        let split = Self.target(Self.paneASplit, leader: 20)
        let narrowed = LiveReset.Narrowed(dispositions: [a: .kill, split: .kill], inventoryFailed: false)
        let outcome = LiveReset.outcome(narrowed: narrowed, survivors: [20], inventoryFailed: false)

        let text = LiveReset.notificationText(outcome: outcome)

        #expect(text == "The reset covered 0 of 1 live sessions. Run Help ▸ Reset Live Sessions… again for the rest. "
            + "Some previous processes in 1 session may still be running; those commands were not restarted.")
    }

    @Test func notificationReportsAnUnreadableSessionList() {
        let outcome = LiveReset.Outcome(panes: .init(confirmed: 1, killed: 0, gone: 0, skipped: 1), unconfirmed: [],
                                        sessions: .init(affected: 1, reset: 0, partial: 1, unconfirmed: 0), inventoryFailed: true)
        #expect(LiveReset.notificationText(outcome: outcome) == "Live sessions were not reset: the session list could not be read.")
    }

    @Test(arguments: RestoreMode.allCases, RestoreMode.allCases)
    func menuIsVisibleOnlyWhenBothModesAreLive(configured: RestoreMode, active: RestoreMode) {
        #expect(LiveReset.menuVisible(configured: configured, active: active) == (configured == .live && active == .live))
    }
}
