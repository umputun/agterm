import Foundation
import Testing
@testable import agtermCore

struct ControlPayloadsTests {
    @Test func updateStatusRoundTripsOnVersion() throws {
        let status = ControlUpdateStatus(automaticChecks: true, lastCheck: 1_794_870_000)
        let data = try JSONEncoder().encode(ControlResult(updates: status))
        #expect(try JSONDecoder().decode(ControlResult.self, from: data).updates == status)
    }

    @Test func updateStatusOmitsANeverRunCheckAndIsAbsentWithoutAFeed() throws {
        let never = String(decoding: try JSONEncoder().encode(ControlUpdateStatus(automaticChecks: false, lastCheck: nil)), as: UTF8.self)
        #expect(never == #"{"automaticChecks":false}"#)
        let bare = String(decoding: try JSONEncoder().encode(ControlResult(text: "x")), as: UTF8.self)
        #expect(!bare.contains("updates"))
    }
}
