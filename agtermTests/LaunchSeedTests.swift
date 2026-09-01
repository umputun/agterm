import XCTest
@testable import agterm
import agtermCore

/// The deferred launch seed: which panes are classified as paceable without consuming anything, and what
/// each disposition consumes when the seed finally resolves.
@MainActor
final class LaunchSeedTests: XCTestCase {
    private let configuration = ZmxSupport.Configuration(
        command: "'/bin/zmx' 'attach' 'agterm-pane'",
        environment: ["SHELL": "/bin/zsh", "ZDOTDIR": "/bundle/zsh"],
        daemonName: "agterm-pane",
        socketDirectory: "/tmp/zmx",
        paneID: "pane"
    )

    // MARK: - ordinary

    func testOrdinaryPacesACaptureTheDenylistAccepts() {
        let session = restoredSession()
        session.pendingForegroundCommand = ["npm", "run", "dev"]

        let provider = ordinaryProvider(session: session, pane: .left)

        XCTAssertTrue(provider.shouldPace)
        XCTAssertEqual(provider.resolve(.left).initialInput, "'npm' 'run' 'dev'\n")
    }

    func testOrdinaryPacesANonEmptyPinAndARestoredDurableCommand() {
        let pinned = restoredSession()
        pinned.pendingRestoreCommand = "tail -f /tmp/log"
        let pinnedProvider = ordinaryProvider(session: pinned, pane: .left)
        XCTAssertTrue(pinnedProvider.shouldPace)
        XCTAssertEqual(pinnedProvider.resolve(.left).initialInput, "tail -f /tmp/log\n")

        let durable = restoredSession()
        durable.splitInitialCommand = "htop"
        let durableProvider = ordinaryProvider(session: durable, pane: .right)
        XCTAssertTrue(durableProvider.shouldPace)
        XCTAssertEqual(durableProvider.resolve(.right).command, "htop")
    }

    func testOrdinaryDoesNotPaceAPinNoneADeniedCaptureOrAPlainShell() {
        let pinNone = restoredSession()
        pinNone.initialCommand = "htop"
        pinNone.pendingRestoreCommand = ""
        XCTAssertFalse(ordinaryProvider(session: pinNone, pane: .left).shouldPace)

        let denied = restoredSession()
        denied.initialCommand = "htop"
        denied.pendingForegroundCommand = ["tmux", "attach"]
        let deniedProvider = ordinaryProvider(session: denied, pane: .left, denylist: ["tmux"])
        XCTAssertFalse(deniedProvider.shouldPace)
        let deniedSeed = deniedProvider.resolve(.left)
        XCTAssertNil(deniedSeed.command, "a denied capture suppresses the durable command too")
        XCTAssertNil(deniedSeed.initialInput)

        XCTAssertFalse(ordinaryProvider(session: restoredSession(), pane: .left).shouldPace)
    }

    func testOrdinaryConsumesEachPendingSlotOnce() {
        let session = restoredSession()
        session.pendingForegroundCommand = ["npm", "run", "dev"]
        session.pendingRestoreCommand = "tail -f /tmp/log"
        session.restoreCommand = "tail -f /tmp/log"

        _ = ordinaryProvider(session: session, pane: .left).resolve(.left)

        XCTAssertNil(session.pendingForegroundCommand)
        XCTAssertNil(session.pendingRestoreCommand)
        XCTAssertEqual(session.restoreCommand, "tail -f /tmp/log", "the sticky pin outlives the launch")
    }

    /// Preserving the slots under `none` would let a mode change to rerun before the next clean quit replay
    /// a command the user launched a plain shell under.
    func testExplicitNoneDropsBothPendingSlotsAndSpawnsAPlainShell() {
        let session = restoredSession()
        session.initialCommand = "htop"
        session.pendingForegroundCommand = ["npm", "run", "dev"]
        session.pendingRestoreCommand = "tail -f /tmp/log"

        let provider = ordinaryProvider(session: session, pane: .left, restoreEnabled: false)

        XCTAssertFalse(provider.shouldPace)
        let seed = provider.resolve(.left)
        XCTAssertNil(seed.command)
        XCTAssertNil(seed.initialInput)
        XCTAssertNil(session.pendingForegroundCommand)
        XCTAssertNil(session.pendingRestoreCommand)
    }

    // MARK: - wrapped

    func testWrappedPacesAnEligibleCaptureAndARestoredDurableCommand() {
        let captured = restoredSession()
        captured.pendingForegroundCommand = ["npm", "run", "dev"]
        let capturedProvider = wrappedProvider(session: captured, pane: .left)
        XCTAssertTrue(capturedProvider.shouldPace)
        XCTAssertEqual(capturedProvider.resolve(.left).command, ZmxSupport.attachCommand(
            configuration, replaying: ["npm", "run", "dev"], denylist: []))

        let durable = restoredSession()
        durable.splitInitialCommand = "htop"
        let durableProvider = wrappedProvider(session: durable, pane: .right)
        XCTAssertTrue(durableProvider.shouldPace)
        XCTAssertNotEqual(durableProvider.resolve(.right).command, configuration.command)
    }

    func testWrappedDoesNotPaceAPaneCarryingOnlyAStickyPin() {
        let session = restoredSession()
        session.restoreCommand = "tail -f /tmp/log"
        session.pendingRestoreCommand = "tail -f /tmp/log"

        let provider = wrappedProvider(session: session, pane: .left)

        XCTAssertFalse(provider.shouldPace)
        XCTAssertEqual(provider.resolve(.left).command, configuration.command)
        XCTAssertEqual(session.pendingRestoreCommand, "tail -f /tmp/log",
                       "a live pane never reads the pin, so it stays armed for the next rerun launch")
    }

    func testWrappedDoesNotPaceADeniedCaptureOrARunningDaemon() {
        let denied = restoredSession()
        denied.pendingForegroundCommand = ["tmux", "attach"]
        XCTAssertFalse(wrappedProvider(session: denied, pane: .left, denylist: ["tmux"]).shouldPace)

        let survivor = restoredSession()
        survivor.pendingForegroundCommand = ["npm", "run", "dev"]
        XCTAssertFalse(wrappedProvider(session: survivor, pane: .left,
                                       runningNames: [configuration.daemonName]).shouldPace,
                       "attaching a surviving daemon runs no program")
        XCTAssertTrue(wrappedProvider(session: survivor, pane: .left, runningNames: ["agterm-other"]).shouldPace)
        XCTAssertTrue(wrappedProvider(session: survivor, pane: .left, runningNames: nil).shouldPace,
                      "a failed list must pace every replaying pane")
    }

    // MARK: - fallback

    func testFallbackIsNeverPacedAndLeavesThePinAndCapturePending() {
        let session = restoredSession()
        session.initialCommand = "htop"
        session.pendingForegroundCommand = ["npm", "run", "dev"]
        session.pendingRestoreCommand = "tail -f /tmp/log"

        let provider = LaunchSeedProvider.pane(
            session: session, pane: .left, disposition: .fallback,
            policy: .init(restoreEnabled: true, denylist: [], runningNames: nil))

        XCTAssertFalse(provider.shouldPace)
        XCTAssertNil(provider.resolve(.left).command, "a restored fallback pane runs no durable command")
        XCTAssertEqual(session.pendingForegroundCommand, ["npm", "run", "dev"])
        XCTAssertEqual(session.pendingRestoreCommand, "tail -f /tmp/log")
    }

    /// `session.swap` moves a mounted surface into the other slot and swaps the pending payloads with it,
    /// so the seed must read the slot the pane occupies at spawn time.
    func testResolvingReadsTheLivePaneNotTheOneItWasBuiltIn() {
        let session = restoredSession()
        session.pendingForegroundCommand = ["npm", "run", "dev"]
        session.pendingSplitForegroundCommand = ["htop"]

        let seed = ordinaryProvider(session: session, pane: .left).resolve(.right)

        XCTAssertEqual(seed.initialInput, "'htop'\n")
        XCTAssertNil(session.pendingSplitForegroundCommand)
        XCTAssertEqual(session.pendingForegroundCommand, ["npm", "run", "dev"])
    }

    // MARK: - classification

    func testClassifyingAPaneConsumesNoSlot() {
        for disposition in [ZmxLaunch.Disposition.ordinary, .wrapped(configuration), .fallback] {
            let session = restoredSession()
            session.pendingForegroundCommand = ["npm", "run", "dev"]
            session.pendingSplitForegroundCommand = ["htop"]
            session.pendingRestoreCommand = "tail -f /tmp/log"
            session.pendingSplitRestoreCommand = "less /tmp/log"

            for pane in [StatusPane.left, .right] {
                _ = LaunchSeedProvider.pane(
                    session: session, pane: pane, disposition: disposition,
                    policy: .init(restoreEnabled: true, denylist: [], runningNames: nil)).shouldPace
            }

            XCTAssertEqual(session.pendingForegroundCommand, ["npm", "run", "dev"])
            XCTAssertEqual(session.pendingSplitForegroundCommand, ["htop"])
            XCTAssertEqual(session.pendingRestoreCommand, "tail -f /tmp/log")
            XCTAssertEqual(session.pendingSplitRestoreCommand, "less /tmp/log")
        }
    }

    func testAFreshPaneIsNeverPaced() {
        let session = Session(initialCwd: "/tmp")
        session.initialCommand = "htop"

        XCTAssertFalse(ordinaryProvider(session: session, pane: .left).shouldPace)
        XCTAssertFalse(wrappedProvider(session: session, pane: .left).shouldPace)
        XCTAssertEqual(ordinaryProvider(session: session, pane: .left).resolve(.left).command, "htop")
    }

    private func restoredSession() -> Session {
        let session = Session(initialCwd: "/tmp")
        session.wasRestored = true
        return session
    }

    private func ordinaryProvider(session: Session, pane: StatusPane, denylist: Set<String> = [],
                                  restoreEnabled: Bool = true) -> LaunchSeedProvider {
        LaunchSeedProvider.pane(
            session: session, pane: pane, disposition: .ordinary,
            policy: .init(restoreEnabled: restoreEnabled, denylist: denylist, runningNames: nil))
    }

    private func wrappedProvider(session: Session, pane: StatusPane, denylist: Set<String> = [],
                                 runningNames: Set<String>? = nil) -> LaunchSeedProvider {
        LaunchSeedProvider.pane(
            session: session, pane: pane, disposition: .wrapped(configuration),
            policy: .init(restoreEnabled: true, denylist: denylist, runningNames: runningNames))
    }
}
