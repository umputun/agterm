import Foundation
import Testing
@testable import agtermCore

struct AppIdentityTests {
    @Test func appIdentityDropsAnUnrecordedCommit() {
        for raw in [nil, "", "unknown"] as [String?] {
            #expect(AppIdentity(version: "0.24.0", recordedCommit: raw).commit == nil)
        }
        #expect(AppIdentity(version: "0.24.0", recordedCommit: "a1b2c3d").commit == "a1b2c3d")
    }

    @Test func installedReadsVersionAndCommitFromTheBundlePlist() throws {
        let bundle = try Self.makeBundle(info: ["CFBundleShortVersionString": "0.35.1", "GitCommit": "def5678"])
        defer { try? FileManager.default.removeItem(at: bundle) }

        #expect(AppIdentity.installed(bundleURL: bundle) == AppIdentity(version: "0.35.1", commit: "def5678"))
    }

    @Test(arguments: [nil, "", "unknown"] as [String?])
    func installedKeepsTheVersionWhenTheCommitIsUnusable(commit: String?) throws {
        var info: [String: Any] = ["CFBundleShortVersionString": "0.35.1"]
        info["GitCommit"] = commit
        let bundle = try Self.makeBundle(info: info)
        defer { try? FileManager.default.removeItem(at: bundle) }

        #expect(AppIdentity.installed(bundleURL: bundle) == AppIdentity(version: "0.35.1"))
    }

    @Test func installedFollowsThePlistAsItChangesOnDisk() throws {
        let bundle = try Self.makeBundle(info: ["CFBundleShortVersionString": "0.35.1", "GitCommit": "def5678"])
        defer { try? FileManager.default.removeItem(at: bundle) }
        #expect(AppIdentity.installed(bundleURL: bundle)?.version == "0.35.1")

        try Self.writeInfo(["CFBundleShortVersionString": "0.36.0", "GitCommit": "abc1234"], bundle: bundle)

        #expect(AppIdentity.installed(bundleURL: bundle) == AppIdentity(version: "0.36.0", commit: "abc1234"))
    }

    @Test func installedIsNilWithoutAReadableVersion() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-none-\(UUID().uuidString).app")
        #expect(AppIdentity.installed(bundleURL: missing) == nil)

        for info in [["GitCommit": "def5678"], ["CFBundleShortVersionString": ""]] as [[String: Any]] {
            let bundle = try Self.makeBundle(info: info)
            defer { try? FileManager.default.removeItem(at: bundle) }
            #expect(AppIdentity.installed(bundleURL: bundle) == nil)
        }

        let malformed = try Self.makeBundle(info: [:])
        defer { try? FileManager.default.removeItem(at: malformed) }
        try Data("not a plist".utf8).write(to: malformed.appendingPathComponent("Contents/Info.plist"))
        #expect(AppIdentity.installed(bundleURL: malformed) == nil)
    }

    @Test func installedIdentityRoundTripsBesideAppAndIsOmittedWhenAbsent() throws {
        let app = AppIdentity(version: "0.34.0", commit: "a1b2c3d")
        let installed = AppIdentity(version: "0.35.1", commit: "def5678")
        let response = ControlResponse(ok: true, result: ControlResult(app: app, installed: installed))
        let decoded = try JSONDecoder().decode(ControlResponse.self, from: JSONEncoder().encode(response))
        #expect(decoded.result?.app == app)
        #expect(decoded.result?.installed == installed)

        let without = try JSONEncoder().encode(ControlResponse(ok: true, result: ControlResult(app: app)))
        #expect(!String(decoding: without, as: UTF8.self).contains("installed"))
        #expect(try JSONDecoder().decode(ControlResponse.self, from: without).result?.installed == nil)
    }

    private static func makeBundle(info: [String: Any]) throws -> URL {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-identity-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try writeInfo(info, bundle: bundle)
        return bundle
    }

    private static func writeInfo(_ info: [String: Any], bundle: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
    }
}
