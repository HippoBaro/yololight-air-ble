import Foundation

public enum LightError: Error, LocalizedError, Equatable {
    case invalidIdentity
    case invalidPacket(String)
    case invalidValue(String)
    case notConnected
    case busy
    case timeout
    case disconnected(String)
    case readbackMismatch(expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidIdentity:
            return "The light did not provide a valid six-byte protocol identity."
        case .invalidPacket(let reason), .invalidValue(let reason), .disconnected(let reason):
            return reason
        case .notConnected: return "The light is not connected."
        case .busy: return "Another light operation is in progress."
        case .timeout: return "The light did not respond in time; no result was assumed."
        case .readbackMismatch(let expected, let actual):
            return "Requested \(expected), but the light reports \(actual)."
        }
    }
}

public struct DeviceIdentity: Equatable, Sendable {
    public let identifier: UUID
    public let mac: [UInt8]

    public init(address: String, mac: String) throws {
        let hex = mac.replacingOccurrences(of: ":", with: "")
        guard let identifier = UUID(uuidString: address), hex.utf8.count == 12,
              hex.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw LightError.invalidIdentity
        }
        let characters = Array(hex)
        var bytes: [UInt8] = []
        for index in stride(from: 0, to: 12, by: 2) {
            guard let byte = UInt8(String(characters[index...index + 1]), radix: 16) else {
                throw LightError.invalidIdentity
            }
            bytes.append(byte)
        }
        self.identifier = identifier
        self.mac = bytes
    }
}

public struct LightFrame: Equatable, Sendable {
    public let mac: [UInt8]
    public let command: UInt8
    public let kind: UInt8
    public let sequence: UInt16
    public let payload: [UInt8]

    public static func encode(mac: [UInt8], command: UInt8, kind: UInt8,
                              sequence: UInt16, payload: [UInt8] = []) throws -> Data {
        guard mac.count == 6 else { throw LightError.invalidIdentity }
        guard payload.count <= 4 else {
            throw LightError.invalidPacket("Only small, single-write control packets are supported.")
        }
        let length = payload.count + 4
        var bytes: [UInt8] = [0xff, 0xcc, UInt8(length + 9), 0xe4]
        bytes += mac
        bytes += [UInt8(length + 1), command, kind, UInt8(sequence >> 8), UInt8(sequence & 0xff)]
        bytes += payload
        bytes.append(bytes.reduce(UInt8(0), &+))
        return Data(bytes)
    }

    public static func decode(_ data: Data) throws -> LightFrame {
        let bytes = Array(data)
        guard bytes.count >= 16, bytes[0] == 0xff, bytes[1] == 0xcc, bytes[3] == 0xe4 else {
            throw LightError.invalidPacket("Not a control frame.")
        }
        guard Int(bytes[2]) + 3 == bytes.count, Int(bytes[10]) + 11 == bytes.count else {
            throw LightError.invalidPacket("Invalid frame length.")
        }
        guard bytes.dropLast().reduce(UInt8(0), &+) == bytes.last else {
            throw LightError.invalidPacket("Invalid frame checksum.")
        }
        return LightFrame(mac: Array(bytes[4..<10]), command: bytes[11], kind: bytes[12],
                          sequence: UInt16(bytes[13]) << 8 | UInt16(bytes[14]),
                          payload: Array(bytes[15..<bytes.count - 1]))
    }
}

public enum LightSetting: UInt8, Sendable {
    case power = 1, brightness = 2, temperature = 3

    public var size: Int { self == .temperature ? 2 : 1 }
    public var query: UInt8 { rawValue + 0xa0 }
}

public struct LightState: Equatable, Sendable {
    public let isOn: Bool
    public let brightness: Int
    public let temperature: Int
    public let temperatureRange: ClosedRange<Int>

    public init(isOn: Bool, brightness: Int, temperature: Int, temperatureRange: ClosedRange<Int>) {
        self.isOn = isOn
        self.brightness = brightness
        self.temperature = temperature
        self.temperatureRange = temperatureRange
    }
}
