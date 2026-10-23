import Foundation
import LightCore
import Testing
@testable import YoloLightMenu

struct LightInventoryTests {
    private func identity(_ index: Int) -> DeviceIdentity {
        try! DeviceIdentity(address: String(format: "00000000-0000-0000-0000-%012d", index),
                            mac: String(format: "0200000000%02x", index))
    }

    @Test func advertisementsAreAvailableWithoutSystemConnections() {
        var inventory = LightInventory()
        let light = identity(1)
        inventory.advertised(light, at: 10)
        #expect(inventory.systemIDs.isEmpty)
        #expect(inventory.lights(at: 11).map(\.id) == [light.identifier])
        #expect(inventory.isAvailable(light.identifier, at: 11))
        #expect(inventory.identity(for: light.identifier) == light)
    }

    @Test func mergesSourcesAndSortsWithoutDuplicates() {
        var inventory = LightInventory()
        let first = identity(1), second = identity(2), third = identity(3)
        inventory.advertised(second, at: 10)
        inventory.advertised(first, at: 11)
        inventory.updateSystem([second.identifier, third.identifier])
        #expect(inventory.lights(at: 12).map(\.id) == [first.identifier, second.identifier, third.identifier])
        #expect(inventory.identity(for: third.identifier) == nil)
    }

    @Test func advertisementsExpireButIdentityKnowledgeDoesNotGrantAvailability() {
        var inventory = LightInventory()
        let light = identity(1)
        inventory.advertised(light, at: 10)
        #expect(inventory.lights(at: 41).isEmpty)
        #expect(!inventory.isAvailable(light.identifier, at: 41))
        #expect(inventory.identity(for: light.identifier) == light)
        inventory.advertised(light, at: 42)
        #expect(inventory.isAvailable(light.identifier, at: 43))
    }

    @Test func connectedDevicesRemainVisibleWhenTheyStopAdvertising() {
        var inventory = LightInventory()
        let light = identity(1)
        inventory.advertised(light, at: 10)
        inventory.updateSystem([light.identifier])
        #expect(inventory.lights(at: 100).map(\.id) == [light.identifier])
        #expect(inventory.identity(for: light.identifier) == light)
        inventory.updateSystem([])
        #expect(inventory.lights(at: 100).isEmpty)
    }

    @Test func pendingLocalAttachmentKeepsItsRowButNotUnrelatedDevices() {
        var inventory = LightInventory()
        let first = identity(1), second = identity(2)
        inventory.advertised(first, at: 10)
        inventory.advertised(second, at: 10)
        #expect(inventory.lights(at: 100, active: [first.identifier]).map(\.id) == [first.identifier])
        #expect(!inventory.isAvailable(second.identifier, at: 100))
    }

    @Test func radioResetInvalidatesAllAvailability() {
        var inventory = LightInventory()
        let light = identity(1)
        inventory.advertised(light, at: 10)
        inventory.updateSystem([light.identifier])
        inventory.invalidateAvailability()
        #expect(inventory.lights(at: 11).isEmpty)
        #expect(!inventory.isAvailable(light.identifier, at: 11))
    }
}
