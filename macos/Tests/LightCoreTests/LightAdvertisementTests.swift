import Foundation
import Testing
@testable import LightCore

struct LightAdvertisementTests {
    private let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let data = Data([0xff, 0x02, 0, 0, 0, 0, 1])

    @Test func extractsIdentityWithoutReversingBytes() throws {
        let identity = try #require(LightAdvertisement.identity(name: "YLight", identifier: id, serviceData: data))
        #expect(identity.identifier == id)
        #expect(identity.mac == [2, 0, 0, 0, 0, 1])
    }

    @Test func rejectsOtherDevicesAndMissingData() {
        #expect(LightAdvertisement.identity(name: "Other", identifier: id, serviceData: data) == nil)
        #expect(LightAdvertisement.identity(name: nil, identifier: id, serviceData: data) == nil)
        #expect(LightAdvertisement.identity(name: "YLight", identifier: id, serviceData: nil) == nil)
    }

    @Test func rejectsMalformedOrPlaceholderIdentities() {
        for bytes: [UInt8] in [[], [0xff], [0, 2, 0, 0, 0, 0, 1], [0xff, 2, 0, 0, 0, 0, 1, 0],
                               [0xff, 0, 0, 0, 0, 0, 0], Array(repeating: 0xff, count: 7)] {
            #expect(LightAdvertisement.identity(name: "YLight", identifier: id, serviceData: Data(bytes)) == nil)
        }
    }
}
