import GhosttyKit
import XCTest
@testable import agterm
@testable import agtermCore

/// Pins the Swift flag mapping and count against the bundled libghostty.
@MainActor
final class ShellIntegrationFeatureBitsTests: XCTestCase {
    private func resolvedBits(_ cfg: ghostty_config_t) -> UInt32? {
        let key = "shell-integration-features"
        var bits: UInt32 = 0
        let got = key.withCString { ghostty_config_get(cfg, &bits, $0, UInt(key.utf8.count)) }
        return got ? bits : nil
    }

    func testDefaultBitsMatchTheKnownLayout() throws {
        let cfg = try XCTUnwrap(ghostty_config_new())
        defer { ghostty_config_free(cfg) }
        ghostty_config_finalize(cfg)

        // ghostty's own defaults: cursor, title and path on; sudo and both ssh flags off.
        XCTAssertEqual(resolvedBits(cfg), 0b100101)
    }

    // catches a trailing upstream field the per-name mapping test cannot see
    func testBoolTrueCoversExactlyTheFlagsWeKnowAbout() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("all.conf")
        try "shell-integration-features = true\n".write(to: file, atomically: true, encoding: .utf8)

        let cfg = try XCTUnwrap(ghostty_config_new())
        defer { ghostty_config_free(cfg) }
        file.path.withCString { ghostty_config_load_file(cfg, $0) }
        ghostty_config_finalize(cfg)

        let known = (UInt32(1) << UInt32(ShellIntegrationFeatures.ordered.count)) - 1
        XCTAssertEqual(resolvedBits(cfg), known, "libghostty has a shell-integration feature ShellIntegrationFeatures.ordered does not")
    }

    func testEachFlagOccupiesTheBitItsNameIsMappedTo() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // each spelling must move only its own bit against ghostty's defaults
        let defaults: UInt32 = 0b100101
        for (index, name) in ShellIntegrationFeatures.ordered.enumerated() {
            let bit = UInt32(1) << UInt32(index)
            for (value, expected) in [(name, defaults | bit), ("no-\(name)", defaults & ~bit)] {
                let file = dir.appendingPathComponent("\(value).conf")
                try "shell-integration-features = \(value)\n".write(to: file, atomically: true, encoding: .utf8)

                let cfg = try XCTUnwrap(ghostty_config_new())
                defer { ghostty_config_free(cfg) }
                file.path.withCString { ghostty_config_load_file(cfg, $0) }
                ghostty_config_finalize(cfg)

                XCTAssertEqual(resolvedBits(cfg), expected, "\(value) does not move bit \(index) alone")
            }
        }
    }
}
