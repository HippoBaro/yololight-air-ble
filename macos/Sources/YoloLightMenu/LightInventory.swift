import Foundation
import LightCore

struct AvailableLight: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
}

/// In-memory merge of fresh advertisements and current system connections.
/// Identity knowledge survives advertising stopping, but never implies availability.
struct LightInventory {
    static let advertisementLifetime: TimeInterval = 30
    private var seen: [UUID: TimeInterval] = [:]
    private var identities: [UUID: DeviceIdentity] = [:]
    private(set) var systemIDs: Set<UUID> = []

    mutating func advertised(_ identity: DeviceIdentity, at time: TimeInterval) {
        seen[identity.identifier] = time
        identities[identity.identifier] = identity
    }

    mutating func updateSystem(_ identifiers: Set<UUID>) { systemIDs = identifiers }

    func identity(for id: UUID) -> DeviceIdentity? { identities[id] }

    func isAvailable(_ id: UUID, at time: TimeInterval) -> Bool {
        if systemIDs.contains(id) { return true }
        guard let lastSeen = seen[id] else { return false }
        return time - lastSeen <= Self.advertisementLifetime
    }

    func lights(at time: TimeInterval, active: Set<UUID> = []) -> [AvailableLight] {
        let ids = Set(seen.keys).union(systemIDs).filter { isAvailable($0, at: time) }
        return Set(ids).union(active).sorted { $0.uuidString < $1.uuidString }
            .map { AvailableLight(id: $0, name: "YLight") }
    }

    mutating func invalidateAvailability() {
        seen.removeAll()
        systemIDs.removeAll()
    }
}
