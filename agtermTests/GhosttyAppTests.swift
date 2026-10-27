import GhosttyKit
import XCTest
@testable import agterm

@MainActor
final class GhosttyAppTests: XCTestCase {
    // pins #611: libghostty adopts the user's numeric locale and CoreSVG then mis-sizes SF Symbols.
    func testNumericLocaleIsPinnedAfterGhosttyInit() {
        XCTAssertNotNil(GhosttyApp.shared.app)

        XCTAssertEqual(setlocale(LC_NUMERIC, nil).map { String(cString: $0) }, "C")
    }

    func testTextLocaleKeepsTheAdoptedSetting() {
        XCTAssertNotNil(GhosttyApp.shared.app)

        XCTAssertEqual(setlocale(LC_CTYPE, nil).map { String(cString: $0) }, "ru_RU.UTF-8")
    }

    func testTheConfiguredSplitDividerColorWins() {
        let color = GhosttyApp.splitDividerColor(configured: .systemRed, background: .black, foreground: .white)

        XCTAssertEqual(color, .systemRed)
    }

    func testTheDefaultSplitDividerIsTheBackgroundATenthTowardTheForeground() throws {
        let color = try XCTUnwrap(GhosttyApp.splitDividerColor(configured: nil, background: .black, foreground: .white)
            .usingColorSpace(.sRGB))

        XCTAssertEqual(color.redComponent, 0.1, accuracy: 0.01)
        XCTAssertEqual(color.greenComponent, 0.1, accuracy: 0.01)
        XCTAssertEqual(color.blueComponent, 0.1, accuracy: 0.01)
        XCTAssertEqual(color.alphaComponent, 1)
    }

    func testTheSplitDividerKeepsTheSystemColorBeforeAnyThemeIsRead() {
        XCTAssertEqual(GhosttyApp.splitDividerColor(configured: nil, background: nil, foreground: nil), .separatorColor)
    }

    func testReadsSplitDividerColorAsSetChangedAndRemoved() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func read(_ text: String) throws -> [Int]? {
            let file = dir.appendingPathComponent("\(UUID().uuidString).conf")
            try text.write(to: file, atomically: true, encoding: .utf8)
            let cfg = try XCTUnwrap(ghostty_config_new())
            defer { ghostty_config_free(cfg) }
            file.path.withCString { ghostty_config_load_file(cfg, $0) }
            ghostty_config_finalize(cfg)
            return GhosttyApp.configuredSplitDividerColor(from: cfg)?.usingColorSpace(.sRGB).map {
                [$0.redComponent, $0.greenComponent, $0.blueComponent].map { Int(($0 * 255).rounded()) }
            }
        }

        XCTAssertEqual(try read("split-divider-color = #808080\n"), [128, 128, 128])
        XCTAssertEqual(try read("split-divider-color = #ff8000\n"), [255, 128, 0])
        XCTAssertNil(try read("font-size = 13\n"))
    }

    func testEnvironmentIsLeftForChildProcesses() {
        let env = ProcessInfo.processInfo.environment

        XCTAssertEqual(env["LC_NUMERIC"], "ru_RU.UTF-8")
        XCTAssertEqual(env["LC_CTYPE"], "ru_RU.UTF-8")
        XCTAssertEqual(env["LC_ALL"] ?? "", "")
    }
}
