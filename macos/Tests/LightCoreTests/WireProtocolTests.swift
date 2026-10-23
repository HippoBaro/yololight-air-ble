import Foundation
import Testing
@testable import LightCore

let syntheticAddress = "00000000-0000-0000-0000-000000000001"
let syntheticMAC: [UInt8] = [2, 0, 0, 0, 0, 1]

func bytes(_ hex: String) -> Data {
    let characters = Array(hex)
    return Data(stride(from: 0, to: characters.count, by: 2).map {
        UInt8(String(characters[$0...$0 + 1]), radix: 16)!
    })
}

struct WireProtocolTests {
    @Test func queryMatchesPythonVector() throws {
        #expect(try LightFrame.encode(mac: syntheticMAC, command: 0xa2, kind: 2, sequence: 1)
                == bytes("ffcc0de402000000000105a202000169"))
    }

    @Test func brightnessMatchesPythonVector() throws {
        #expect(try LightFrame.encode(mac: syntheticMAC, command: 2, kind: 1, sequence: 12, payload: [20])
                == bytes("ffcc0ee4020000000001060201000c14e9"))
    }

    @Test func temperatureMatchesPythonVector() throws {
        #expect(try LightFrame.encode(mac: syntheticMAC, command: 3, kind: 1,
                                     sequence: 23, payload: [0x0f, 0x3c])
                == bytes("ffcc0fe402000000000107030100170f3c2e"))
    }

    @Test func replyLayouts() throws {
        let samples: [(String, UInt8, [UInt8])] = [
            ("ffcc0ee402000000000106a202ffff1981", 0xa2, [25]),
            ("ffcc0fe402000000000107a302ffff0fa01a", 0xa3, [0x0f, 0xa0]),
            ("ffcc0ee402000000000106a102ffff0168", 0xa1, [1]),
            ("ffcc11e402000000000109a502ffff0a8c196484", 0xa5, [0x0a, 0x8c, 0x19, 0x64]),
        ]
        for (hex, command, payload) in samples {
            let frame = try LightFrame.decode(bytes(hex))
            #expect(frame.mac == syntheticMAC)
            #expect(frame.command == command)
            #expect(frame.kind == 2)
            #expect(frame.sequence == 0xffff)
            #expect(frame.payload == payload)
        }
    }

    @Test func malformedFramesAreRejected() throws {
        let valid = try LightFrame.encode(mac: syntheticMAC, command: 0xa2, kind: 2, sequence: 1)
        for length in 0..<valid.count {
            #expect(throws: (any Error).self) { try LightFrame.decode(valid.prefix(length)) }
        }
        for index in [0, 1, 2, 3, 10, valid.count - 1] {
            var corrupt = valid
            corrupt[index] ^= 1
            #expect(throws: (any Error).self) { try LightFrame.decode(corrupt) }
        }
        #expect(throws: (any Error).self) { try LightFrame.decode(valid + Data([0])) }
        #expect(throws: (any Error).self) { try LightFrame.decode(bytes("ffcc0de402000000000105a4f1ff05ff")) }
    }

    @Test func invalidBuildIsRejected() {
        #expect(throws: (any Error).self) {
            try LightFrame.encode(mac: [1, 2, 3], command: 2, kind: 1, sequence: 1)
        }
        #expect(throws: (any Error).self) {
            try LightFrame.encode(mac: syntheticMAC, command: 2, kind: 1, sequence: 1, payload: [1, 2, 3, 4, 5])
        }
    }

    @Test func identityParsingDoesNotReverseBytes() throws {
        for mac in ["020000000001", "02:00:00:00:00:01"] {
            let device = try DeviceIdentity(address: syntheticAddress, mac: mac)
            #expect(device.identifier.uuidString == syntheticAddress)
            #expect(device.mac == syntheticMAC)
        }
        #expect(try DeviceIdentity(address: syntheticAddress, mac: "02:00:00:00:AB:CD").mac
                == [2, 0, 0, 0, 0xab, 0xcd])
    }

    @Test func invalidIdentitiesAreRejected() {
        #expect(throws: LightError.invalidIdentity) {
            try DeviceIdentity(address: "not-a-uuid", mac: "020000000001")
        }
        for mac in ["", "0200000000", "02000000000100", "02000000000g", "éééééé"] {
            #expect(throws: LightError.invalidIdentity) {
                try DeviceIdentity(address: syntheticAddress, mac: mac)
            }
        }
    }
}
