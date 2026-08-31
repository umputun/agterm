import Foundation
import Testing
@testable import agtermCore

struct RestoreModeTests {
    @Test(arguments: [
        (#""none""#, RestoreMode.none),
        (#""rerun""#, RestoreMode.rerun),
        (#""live""#, RestoreMode.live),
        (#""future""#, RestoreMode.none),
    ])
    func decodeIsLossy(raw: String, expected: RestoreMode) throws {
        #expect(try JSONDecoder().decode(RestoreMode.self, from: Data(raw.utf8)) == expected)
    }

    @Test func roundTrip() throws {
        for mode in RestoreMode.allCases {
            #expect(try JSONDecoder().decode(RestoreMode.self, from: JSONEncoder().encode(mode)) == mode)
        }
    }

    @Test func settingsNames() {
        #expect(RestoreMode.allCases.map(\.displayName) == ["Fresh shells", "Re-run commands", "Live sessions"])
    }

}
