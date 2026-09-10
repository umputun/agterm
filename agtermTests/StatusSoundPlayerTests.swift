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

    func testUnknownSoundNameResolvesToNoAction() async {
        let action = await player.action(for: "NoSuchSoundXYZ")
        let played = await player.play("NoSuchSoundXYZ")
        XCTAssertNil(action, "an unresolvable name must report itself as such")
        XCTAssertFalse(played, "play must fail so the control server can say 'unknown sound'")
    }

    func testEveryOfferedSoundNameResolves() async {
        for name in ["default", "beep"] + StatusSoundPlayer.standardNames {
            let action = await player.action(for: name)
            XCTAssertNotNil(action, "the Settings picker offers \(name), so it must resolve")
        }
    }

    func testStartingAClipLeavesTheMainThread() async throws {
        // #575: the first NSSound.play() of a process took ~0.9s, on the main actor
        let fixture = try registerRecordingSound()
        let resolved = await player.action(for: fixture.name)
        let action = try XCTUnwrap(resolved)

        action()

        await fulfillment(of: [fixture.sound.log.playCalled], timeout: 2)
        let calls = fixture.sound.log.calls
        XCTAssertEqual(calls.map(\.selector), ["stop", "play"], "a replay must stop the clip before starting it")
        XCTAssertEqual(calls.filter(\.onMainThread), [], "neither call may run on the main thread")
    }

    func testStartingACachedClipLeavesTheMainThread() async throws {
        let fixture = try registerRecordingSound()
        _ = await player.action(for: fixture.name)
        let resolved = await player.action(for: fixture.name)
        let cached = try XCTUnwrap(resolved)

        cached()

        await fulfillment(of: [fixture.sound.log.playCalled], timeout: 2)
        XCTAssertEqual(fixture.sound.log.calls.map(\.selector), ["stop", "play"])
        XCTAssertEqual(fixture.sound.log.calls.filter(\.onMainThread), [], "the cached branch must hop off the main thread too")
    }

    func testResolutionLeavesMainActorFreeWhileWorkerIsHeld() async {
        let gate = StatusSoundResolutionGate(sound: nil)
        let player = StatusSoundPlayer(resolve: { _ in gate.resolve() })
        let pending = Task { await player.action(for: "held") != nil }
        await fulfillment(of: [gate.started], timeout: 2)
        XCTAssertFalse(gate.onMainThread)
        XCTAssertFalse(gate.finished)
        gate.release.signal()
        let resolved = await pending.value
        XCTAssertFalse(resolved)
    }

    func testCachedPlaybackDoesNotWaitForResolution() async throws {
        let sound = try XCTUnwrap(RecordingSound(contentsOfFile: "/System/Library/Sounds/Tink.aiff", byReference: true))
        let gate = StatusSoundResolutionGate(sound: nil)
        let player = StatusSoundPlayer(resolve: { name in name == "held" ? gate.resolve() : sound })
        _ = await player.action(for: "cached")
        let pending = Task { await player.action(for: "held") != nil }
        await fulfillment(of: [gate.started], timeout: 2)
        let cached = expectation(description: "cache bypasses busy worker")
        let lookup = Task {
            let action = await player.action(for: "cached")
            XCTAssertNotNil(action)
            action?()
            cached.fulfill()
        }
        await fulfillment(of: [cached, sound.log.playCalled], timeout: 2)
        gate.release.signal()
        await lookup.value
        _ = await pending.value
    }

    func testResolutionDoesNotWaitForBusyPlayback() async throws {
        let busy = try XCTUnwrap(RecordingSound(contentsOfFile: "/System/Library/Sounds/Tink.aiff", byReference: true))
        let fresh = try XCTUnwrap(RecordingSound(contentsOfFile: "/System/Library/Sounds/Tink.aiff", byReference: true))
        let release = DispatchSemaphore(value: 0)
        // a stuck playback queue outlives the test and would hang every later one
        defer { release.signal() }
        busy.log.holdPlay(until: release)
        let player = StatusSoundPlayer(resolve: { name in name == "busy" ? busy : fresh })

        let occupyAction = await player.action(for: "busy")
        let occupy = try XCTUnwrap(occupyAction)
        occupy()
        await fulfillment(of: [busy.log.playCalled], timeout: 2)

        let resolved = expectation(description: "a fresh name resolves while playback is held")
        let lookup = Task {
            let action = await player.action(for: "fresh")
            XCTAssertNotNil(action)
            resolved.fulfill()
        }
        await fulfillment(of: [resolved], timeout: 2)
        release.signal()
        await lookup.value
    }

    func testPreviewDiscardsSelectionChangedDuringResolution() async throws {
        for replacement: String? in ["newer", nil] {
            let sound = try XCTUnwrap(RecordingSound(contentsOfFile: "/System/Library/Sounds/Tink.aiff", byReference: true))
            let barrier = try XCTUnwrap(RecordingSound(contentsOfFile: "/System/Library/Sounds/Tink.aiff", byReference: true))
            let gate = StatusSoundResolutionGate(sound: sound)
            let player = StatusSoundPlayer(resolve: { name in name == "held" ? gate.resolve() : barrier })
            var selected: String? = "held"
            let pending = Task { await player.preview("held", ifCurrent: { selected == "held" }) }
            await fulfillment(of: [gate.started], timeout: 2)
            selected = replacement
            gate.release.signal()
            await pending.value
            let action = await player.action(for: "barrier")
            action?()
            await fulfillment(of: [barrier.log.playCalled], timeout: 2)
            XCTAssertTrue(sound.log.calls.isEmpty)
        }
    }

    func testCurrentPreviewBypassesStatusThrottle() async throws {
        let sound = try XCTUnwrap(RecordingSound(contentsOfFile: "/System/Library/Sounds/Tink.aiff", byReference: true))
        sound.log.playCalled.expectedFulfillmentCount = 2
        let player = StatusSoundPlayer(resolve: { _ in sound })
        let played = await player.play("preview")
        XCTAssertTrue(played)
        await player.preview("preview", ifCurrent: { true })
        await fulfillment(of: [sound.log.playCalled], timeout: 2)
        XCTAssertEqual(sound.log.calls.map(\.selector), ["stop", "play", "stop", "play"])
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

final class RecordingSound: NSSound {
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

final class PlaybackLog: @unchecked Sendable {
    struct Call: Equatable {
        let selector: String
        let onMainThread: Bool
    }

    let playCalled = XCTestExpectation(description: "play reached the sound")

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var playHold: DispatchSemaphore?

    var calls: [Call] {
        lock.withLock { recorded }
    }

    /// Block the caller's queue inside `play()` until `semaphore` is signalled, so a test can hold the
    /// playback queue occupied while it exercises something that must not wait on it.
    func holdPlay(until semaphore: DispatchSemaphore) {
        lock.withLock { playHold = semaphore }
    }

    func record(_ selector: String) {
        let hold = lock.withLock { () -> DispatchSemaphore? in
            recorded.append(Call(selector: selector, onMainThread: Thread.isMainThread))
            return selector == "play" ? playHold : nil
        }
        if selector == "play" { playCalled.fulfill() }
        if let hold { _ = hold.wait(timeout: .now() + 10) }
    }
}

final class StatusSoundResolutionGate: @unchecked Sendable {
    let started = XCTestExpectation(description: "resolver entered")
    let completed = XCTestExpectation(description: "resolver finished")
    let release = DispatchSemaphore(value: 0)
    private let sound: NSSound?
    private let lock = NSLock()
    private var recordedMainThread = false
    private var didFinish = false

    init(sound: NSSound?) { self.sound = sound }

    var onMainThread: Bool { lock.withLock { recordedMainThread } }
    var finished: Bool { lock.withLock { didFinish } }

    func resolve() -> NSSound? {
        defer { completed.fulfill() }
        lock.withLock { recordedMainThread = Thread.isMainThread }
        started.fulfill()
        if !Thread.isMainThread { _ = release.wait(timeout: .now() + 10) }
        lock.withLock { didFinish = true }
        return sound
    }
}
