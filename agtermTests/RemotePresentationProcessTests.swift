import XCTest
@testable import agterm
import agtermCore

@MainActor
final class RemotePresentationProcessTests: XCTestCase {
    private var lines: [String] = []
    private var closes: [String] = []

    private func open(_ argv: [String]) -> RemotePresentationLink {
        RemotePresentationProcess().open(
            argv,
            onLine: { [weak self] in self?.lines.append(String(decoding: $0, as: UTF8.self)) },
            onClose: { [weak self] in self?.closes.append($0) })
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) {
        let met = expectation(description: "condition met")
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(timeout)
            while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
            met.fulfill()
        }
        wait(for: [met], timeout: timeout + 1)
    }

    func testLinesTravelBothWaysThroughTheChild() {
        let link = open(["/bin/cat"])

        link.send(Data("one\ntwo\n".utf8))

        waitUntil { self.lines.count == 2 }
        XCTAssertEqual(lines, ["one", "two"])
        link.stop()
        waitUntil { !self.closes.isEmpty }
    }

    func testTheChildsExitStatusIsTheCloseReason() {
        let link = open(["/bin/sh", "-c", "echo hello; exit 3"])

        waitUntil { !self.closes.isEmpty }

        XCTAssertEqual(closes, ["exit 3"])
        XCTAssertEqual(lines, ["hello"])
        link.stop()
    }

    func testStoppingEndsTheChildAndClosesOnce() {
        let link = open(["/bin/cat"])

        link.stop()
        link.stop()

        waitUntil { !self.closes.isEmpty }
        XCTAssertEqual(closes.count, 1)
        link.send(Data("late\n".utf8))
        XCTAssertEqual(closes.count, 1)
    }

    func testACommandThatCannotRunClosesWithTheReason() {
        let link = open(["/nonexistent/agterm-bridge"])

        waitUntil { !self.closes.isEmpty }

        XCTAssertEqual(closes.count, 1)
        XCTAssertTrue(lines.isEmpty)
        link.stop()
    }

    // the exit was reported while the child's last lines were still queued for delivery
    func testTheCloseArrivesAfterEveryLineTheChildWrote() {
        var order: [String] = []
        let link = RemotePresentationProcess().open(
            ["/bin/sh", "-c", "i=0; while [ $i -lt 200 ]; do echo line$i; i=$((i+1)); done"],
            onLine: { _ in order.append("line") },
            onClose: { _ in order.append("close") })
        Thread.sleep(forTimeInterval: 0.5)

        waitUntil { order.contains("close") }

        XCTAssertEqual(order.count, 201)
        XCTAssertEqual(order.last, "close")
        _ = link
    }

    func testAnOversizedLineIsNeverDeliveredEvenWhenItsNewlineArrivesWithIt() {
        let size = PresentationCodec.maxFrameBytes + 1
        let link = open(["/bin/sh", "-c", "head -c \(size) /dev/zero | tr '\\0' a; echo; echo after"])

        waitUntil { !self.closes.isEmpty }

        XCTAssertEqual(lines.map(\.count), [])
        XCTAssertEqual(closes.count, 1)
        _ = link
    }

    // a descendant holding the child's pipes kept both reader threads and their descriptors after the close
    func testADescendantHoldingThePipesLosesThemOnceTheLinkCloses() throws {
        let pidFile = NSTemporaryDirectory() + "agterm-rp-descendant-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: pidFile) }
        let script = "sh -c 'echo $$ > \"$0\"; while :; do echo tick; sleep 0.1; done' \"\(pidFile)\" & exit 0"
        let link = open(["/bin/sh", "-c", script])

        waitUntil(6) { !self.closes.isEmpty }
        let pid = try XCTUnwrap(Int32((try String(contentsOfFile: pidFile, encoding: .utf8))
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(pid, SIGKILL) }

        waitUntil(4) { kill(pid, 0) != 0 }

        XCTAssertEqual(closes, ["exit 0"])
        XCTAssertNotEqual(kill(pid, 0), 0, "its next write found the pipe closed")
        _ = link
    }
}
