import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for the status-sound player: which names resolve, and that starting a clip hands the
/// main thread straight back.
@MainActor
final class StatusSoundPlayerTests: XCTestCase {
    private var player: StatusSoundPlayer!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { player = StatusSoundPlayer() }
    }

    func testUnknownSoundNameResolvesToNoAction() {
        XCTAssertNil(player.action(for: "NoSuchSoundXYZ"), "an unresolvable name must report itself as such")
        XCTAssertFalse(player.play("NoSuchSoundXYZ"), "play must fail so the control server can say 'unknown sound'")
    }

    func testEveryOfferedSoundNameResolves() {
        for name in ["default", "beep"] + StatusSoundPlayer.standardNames {
            XCTAssertNotNil(player.action(for: name), "the Settings picker offers \(name), so it must resolve")
        }
    }

    func testPlayingASoundDoesNotHoldTheMainThread() throws {
        // #575: the first NSSound.play() of a process spent ~0.7s starting CoreAudio on the main actor
        let action = try XCTUnwrap(player.action(for: "Tink"))

        let started = ContinuousClock().now
        action()
        let cold = ContinuousClock().now - started

        let cachedAction = try XCTUnwrap(player.action(for: "Tink"))
        let resumed = ContinuousClock().now
        cachedAction()
        let warm = ContinuousClock().now - resumed

        XCTAssertLessThan(cold, .milliseconds(50), "the first play must not wait on audio startup, took \(cold)")
        XCTAssertLessThan(warm, .milliseconds(50), "a cached sound must not wait on playback either, took \(warm)")
    }
}
