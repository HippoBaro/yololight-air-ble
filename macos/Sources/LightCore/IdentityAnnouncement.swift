import Foundation

/// The Air's captured A4 device-type announcement has a nonstandard layout.
/// It supplies only a candidate identity, never a status/setting acknowledgement.
/// Normal replies must still pass LightFrame's length, identity, and checksum checks.
public enum IdentityAnnouncement {
    public static func candidate(from data: Data, identifier: UUID) -> DeviceIdentity? {
        let bytes = Array(data)
        guard bytes.count == 16,
              Array(bytes.prefix(4)) == [0xff, 0xcc, 0x0d, 0xe4],
              Array(bytes.suffix(6)) == [0x05, 0xa4, 0xf1, 0xff, 0x05, 0xff] else { return nil }
        let mac = bytes[4..<10]
        guard mac.contains(where: { $0 != 0 }), mac.contains(where: { $0 != 0xff }) else { return nil }
        return try? DeviceIdentity(address: identifier.uuidString,
                                   mac: mac.map { String(format: "%02x", $0) }.joined())
    }
}
