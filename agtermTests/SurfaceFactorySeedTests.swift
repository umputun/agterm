import XCTest
@testable import agterm
import agtermCore

@MainActor
final class SurfaceFactorySeedTests: XCTestCase {
    private let configuration = ZmxSupport.Configuration(
        command: "'/bin/zmx' 'attach' 'agterm-pane'",
        environment: ["SHELL": "/bin/zsh", "ZDOTDIR": "/bundle/zsh"],
        daemonName: "agterm-pane",
        socketDirectory: "/tmp/zmx",
        paneID: "pane"
    )

    func testWrappedPrimaryConsumesReplayOnceWithoutTouchingStickyOverride() throws {
        let session = restoredSession()
        session.pendingForegroundCommand = ["/usr/bin/tail", "-f", "/tmp/log file"]
        session.restoreCommand = "sticky"
        session.pendingRestoreCommand = "sticky"

        let first = try XCTUnwrap(ZmxLaunch.surfaceSeed(
            disposition: .wrapped(configuration), session: session, pane: .left, denylist: []
        ))
        XCTAssertEqual(first.command, ZmxSupport.attachCommand(
            configuration, replaying: ["/usr/bin/tail", "-f", "/tmp/log file"], denylist: []
        ))
        XCTAssertNil(first.initialInput)
        XCTAssertNil(session.pendingForegroundCommand)
        XCTAssertEqual(session.restoreCommand, "sticky")
        XCTAssertEqual(session.pendingRestoreCommand, "sticky")

        let second = try XCTUnwrap(ZmxLaunch.surfaceSeed(
            disposition: .wrapped(configuration), session: session, pane: .left, denylist: []
        ))
        XCTAssertEqual(second.command, configuration.command)
        XCTAssertNil(second.initialInput)
    }

    func testWrappedSplitConsumesReplayOnceWithoutTouchingStickyOverride() throws {
        let session = restoredSession()
        session.pendingSplitForegroundCommand = ["/usr/bin/watch", "date"]
        session.splitRestoreCommand = "sticky split"
        session.pendingSplitRestoreCommand = "sticky split"

        let first = try XCTUnwrap(ZmxLaunch.surfaceSeed(
            disposition: .wrapped(configuration), session: session, pane: .right, denylist: []
        ))
        XCTAssertEqual(first.command, ZmxSupport.attachCommand(
            configuration, replaying: ["/usr/bin/watch", "date"], denylist: []
        ))
        XCTAssertNil(first.initialInput)
        XCTAssertNil(session.pendingSplitForegroundCommand)
        XCTAssertEqual(session.splitRestoreCommand, "sticky split")
        XCTAssertEqual(session.pendingSplitRestoreCommand, "sticky split")

        let second = try XCTUnwrap(ZmxLaunch.surfaceSeed(
            disposition: .wrapped(configuration), session: session, pane: .right, denylist: []
        ))
        XCTAssertEqual(second.command, configuration.command)
        XCTAssertNil(second.initialInput)
    }

    func testFallbackDoesNotConsumeEitherReplay() {
        let session = restoredSession()
        session.pendingForegroundCommand = ["primary"]
        session.pendingSplitForegroundCommand = ["split"]

        XCTAssertNil(ZmxLaunch.surfaceSeed(
            disposition: .fallback, session: session, pane: .left, denylist: []
        ))
        XCTAssertNil(ZmxLaunch.surfaceSeed(
            disposition: .fallback, session: session, pane: .right, denylist: []
        ))
        XCTAssertEqual(session.pendingForegroundCommand, ["primary"])
        XCTAssertEqual(session.pendingSplitForegroundCommand, ["split"])
    }

    func testDeniedReplaySuppressesDurableCommandOnBothPanes() throws {
        for pane in [StatusPane.left, .right] {
            let session = restoredSession()
            setDurableCommand("echo durable", on: pane, session: session)
            setPendingCapture(["/usr/bin/tmux", "attach"], on: pane, session: session)

            let seed = try XCTUnwrap(ZmxLaunch.surfaceSeed(
                disposition: .wrapped(configuration), session: session, pane: pane, denylist: ["tmux"]
            ))

            XCTAssertEqual(seed.command, configuration.command)
            XCTAssertNil(seed.initialInput)
            XCTAssertNil(pendingCapture(on: pane, session: session))
        }
    }

    func testRestoredWrappedPanesUseDurableCommandWhenCaptureIsAbsent() throws {
        for pane in [StatusPane.left, .right] {
            let session = restoredSession()
            setDurableCommand("printf durable && echo 'two words'", on: pane, session: session)

            let seed = try XCTUnwrap(ZmxLaunch.surfaceSeed(
                disposition: .wrapped(configuration), session: session, pane: pane, denylist: []
            ))

            XCTAssertNotEqual(seed.command, configuration.command)
            XCTAssertTrue(seed.command.contains("printf durable && echo"))
            XCTAssertNil(seed.initialInput)
        }
    }

    func testFreshWrappedPrimaryKeepsCreationInput() throws {
        let session = Session(initialCwd: "/tmp")
        session.initialCommand = "ssh example"

        let seed = try XCTUnwrap(ZmxLaunch.surfaceSeed(
            disposition: .wrapped(configuration), session: session, pane: .left, denylist: []
        ))

        XCTAssertEqual(seed.command, configuration.command)
        XCTAssertEqual(seed.initialInput, "ssh example\n")
    }

    private func restoredSession() -> Session {
        let session = Session(initialCwd: "/tmp")
        session.wasRestored = true
        return session
    }

    private func setDurableCommand(_ command: String, on pane: StatusPane, session: Session) {
        switch pane {
        case .left: session.initialCommand = command
        case .right: session.splitInitialCommand = command
        case .scratch: XCTFail("scratch is not restored")
        }
    }

    private func setPendingCapture(_ argv: [String], on pane: StatusPane, session: Session) {
        switch pane {
        case .left: session.pendingForegroundCommand = argv
        case .right: session.pendingSplitForegroundCommand = argv
        case .scratch: XCTFail("scratch is not restored")
        }
    }

    private func pendingCapture(on pane: StatusPane, session: Session) -> [String]? {
        switch pane {
        case .left: session.pendingForegroundCommand
        case .right: session.pendingSplitForegroundCommand
        case .scratch: nil
        }
    }
}
