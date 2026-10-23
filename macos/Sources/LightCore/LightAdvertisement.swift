import Foundation

/// Advertisement-only identity extraction. No connection or GATT access is needed.
public enum LightAdvertisement {
    public static func identity(name: String?, identifier: UUID, serviceData: Data?) -> DeviceIdentity? {
        guard name == "YLight", let serviceData else { return nil }
        let bytes = Array(serviceData)
        guard bytes.count == 7, bytes[0] == 0xff else { return nil }
        let mac = bytes.dropFirst()
        guard mac.contains(where: { $0 != 0 }), mac.contains(where: { $0 != 0xff }) else { return nil }
        return try? DeviceIdentity(address: identifier.uuidString,
                                   mac: mac.map { String(format: "%02x", $0) }.joined())
    }
}
