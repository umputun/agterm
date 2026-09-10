import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for the status-sound player: which names resolve, and that a resolved clip is started
/// off the main thread. The recording sound overrides playback, so nothing here proves it is audible.
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

    func testStartingAClipLeavesTheMainThread() throws {
        // #575: the first NSSound.play() of a process spent ~0.7s starting CoreAudio on the main actor
        let fixture = try registerRecordingSound()
        let action = try XCTUnwrap(player.action(for: fixture.name))

        action()

        wait(for: [fixture.sound.log.playCalled], timeout: 2)
        let calls = fixture.sound.log.calls
        XCTAssertEqual(calls.map(\.selector), ["stop", "play"], "a replay must stop the clip before starting it")
        XCTAssertEqual(calls.filter(\.onMainThread), [], "neither call may run on the main thread")
    }

    func testStartingACachedClipLeavesTheMainThread() throws {
        let fixture = try registerRecordingSound()
        _ = player.action(for: fixture.name)
        let cached = try XCTUnwrap(player.action(for: fixture.name))

        cached()

        wait(for: [fixture.sound.log.playCalled], timeout: 2)
        XCTAssertEqual(fixture.sound.log.calls.filter(\.onMainThread), [], "the cached branch must hop off the main thread too")
    }

    /// A sound that records its own playback instead of making noise, published under a name unique to the
    /// call so `NSSound(named:)` hands the player this instance and no test inherits another's cache entry.
    private func registerRecordingSound() throws -> (sound: RecordingSound, name: String) {
        let url = URL(fileURLWithPath: "/System/Library/Sounds/Tink.aiff")
        let sound = try XCTUnwrap(RecordingSound(contentsOf: url, byReference: true))
        let name = NSSound.Name("agterm-status-sound-test-\(UUID().uuidString)")
        XCTAssertTrue(sound.setName(name), "the fixture has to be resolvable by name")
        return (sound, name as String)
    }
}

private final class RecordingSound: NSSound {
    let log = PlaybackLog()

    override func stop() -> Bool {
        log.record("stop")
        return true
    }

    override func play() -> Bool {
        log.record("play")
        return true
    }
}

private final class PlaybackLog: @unchecked Sendable {
    struct Call: Equatable {
        let selector: String
        let onMainThread: Bool
    }

    let playCalled = XCTestExpectation(description: "play reached the sound")

    private let lock = NSLock()
    private var recorded: [Call] = []

    var calls: [Call] {
        lock.withLock { recorded }
    }

    func record(_ selector: String) {
        lock.withLock { recorded.append(Call(selector: selector, onMainThread: Thread.isMainThread)) }
        if selector == "play" { playCalled.fulfill() }
    }
}
