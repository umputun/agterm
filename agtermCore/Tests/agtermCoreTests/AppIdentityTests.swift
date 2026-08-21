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
}
