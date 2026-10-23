import Combine
import Foundation
import LightCore
import Testing
@testable import YoloLightMenu

func descriptor(_ index: Int) -> AvailableLight {
    AvailableLight(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!, name: "YLight")
}

@MainActor
final class ModelTransport: LightTransport {
    let device: DeviceIdentity
    var eligible: () -> Bool = { true }
    var isConnected = false
    var onNotification: ((Data) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    var ignoreSets = false
    var ignoreQueries = false
    var onSetting: (() -> Void)?
    var onQuery: (() -> Void)?
    var connectError: LightError?
    var connectionRequests = 0
    var attachments = 0
    var writes: [LightFrame] = []
    var values: [UInt8: [UInt8]] = [0xa1: [1], 0xa2: [25], 0xa3: [0x0f, 0xa0], 0xa5: [0x0a, 0x8c, 0x19, 0x64]]

    init(light: AvailableLight) {
        let index = Int(light.id.uuidString.suffix(2))!
        device = try! DeviceIdentity(address: light.id.uuidString, mac: String(format: "0200000000%02x", index))
    }

    func connect() async throws -> DeviceIdentity {
        connectionRequests += 1
        guard eligible() else { throw LightError.notConnected }
        if let connectError { throw connectError }
        attachments += 1
        isConnected = true
        return device
    }
    func disconnect() {
        let connected = isConnected
        isConnected = false
        if connected { onDisconnect?(LightError.notConnected) }
    }
    func write(_ data: Data) async throws {
        guard isConnected else { throw LightError.notConnected }
        let frame = try LightFrame.decode(data)
        writes.append(frame)
        if frame.kind == 1 { onSetting?() }
        if frame.kind == 2 { onQuery?() }
        if frame.kind == 1, !ignoreSets { values[frame.command + 0xa0] = frame.payload }
        if frame.kind == 2, !ignoreQueries {
            onNotification?(try LightFrame.encode(mac: device.mac, command: frame.command, kind: 2,
                                                  sequence: 0xffff, payload: values[frame.command] ?? []))
        }
    }
    var settings: [LightFrame] { writes.filter { $0.kind == 1 } }
}

@MainActor
final class FakeLightSource: LightSource {
    var onLights: (([AvailableLight]) -> Void)?
    var onStatus: ((String) -> Void)?
    var availableIDs: Set<UUID> = []
    var transports: [UUID: ModelTransport] = [:]
    var creationCount = 0
    var starts = 0
    var stops = 0
    var discoveryRequests: [Bool] = []
    var configure: (ModelTransport) -> Void = { _ in }

    func start() { starts += 1; publish([]) }
    func stop() { stops += 1 }
    func setDiscoveryActive(_ active: Bool) { discoveryRequests.append(active) }
    func publish(_ lights: [AvailableLight]) {
        availableIDs = Set(lights.map(\.id))
        onLights?(lights)
        onStatus?(lights.isEmpty ? "No nearby lights." : "Nearby lights.")
    }
    func makeTransport(for light: AvailableLight) -> any LightTransport {
        creationCount += 1
        let transport = ModelTransport(light: light)
        transport.eligible = { [weak self] in self?.availableIDs.contains(light.id) == true }
        configure(transport)
        transports[light.id] = transport
        return transport
    }
}

@Suite(.serialized)
@MainActor
struct LightModelTests {
    private func eventually(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while !condition(), clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }

    private func withModel(_ operation: (LightModel, ModelTransport) async throws -> Void) async throws {
        let transport = ModelTransport(light: descriptor(1))
        let model = LightModel(light: descriptor(1), transport: transport)
        defer { model.stop() }
        model.start()
        try await operation(model, transport)
    }

    @Test func startupAndPollingNeverConnectAndStateIsUnknown() async throws {
        let transport = ModelTransport(light: descriptor(1))
        let model = LightModel(light: descriptor(1), transport: transport, refreshInterval: .milliseconds(20))
        defer { model.stop() }
        model.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.canControl)
        #expect(!model.isConnected)
        #expect(model.isOn == nil)
        #expect(model.brightnessText == "—")
        #expect(model.temperatureText == "—")
        #expect(model.presentation == .unread)
        #expect(!model.presentation.isVerified)
        #expect(model.powerAccessibilityValue.contains("Unknown"))
        #expect(model.brightnessAccessibilityValue.contains("Unknown"))
        #expect(model.temperatureAccessibilityValue.contains("Unknown"))
        #expect(model.failureMessage == nil)
        #expect(transport.connectionRequests == 0)
        #expect(transport.writes.isEmpty)
    }

    @Test func firstPowerEditConnectsReadsThenWritesAndVerifies() async throws {
        try await withModel { model, transport in
            model.setPower(false)
            #expect(model.isBusy)
            #expect(model.presentation == .connecting)
            try await eventually { model.canControl }
            #expect(model.isOn == false)
            #expect(model.isConnected)
            #expect(model.presentation == .verified)
            #expect(model.powerAccessibilityValue == "Off. Verified value.")
            #expect(model.brightnessAccessibilityValue.contains("Verified"))
            #expect(model.brightness == 25)
            #expect(model.temperature == 4000)
            #expect(transport.attachments == 1)
            #expect(transport.writes.prefix(4).map(\.command) == [0xa1, 0xa2, 0xa3, 0xa5])
            #expect(transport.writes.prefix(4).allSatisfy { $0.kind == 2 })
            #expect(transport.settings.map(\.payload) == [[0]])
        }
    }

    @Test func rejectedBusyEditsRepublishBindingsWithoutQueuingCommands() async throws {
        try await withModel { model, transport in
            model.setPower(true)
            #expect(model.isBusy)
            #expect(model.powerAccessibilityValue.contains("not verified"))
            var updates = 0
            let observation = model.objectWillChange.sink { updates += 1 }
            model.setPower(false)
            model.setBrightness(75)
            model.setTemperature(5500)
            #expect(updates == 3)
            #expect(model.isOn == true)
            #expect(model.brightness == 50)
            #expect(model.temperature == 4000)
            withExtendedLifetime(observation) {}
            try await eventually { model.canControl }
            try await Task.sleep(for: .milliseconds(350))
            #expect(transport.settings.map(\.payload) == [[1]])
            #expect(model.isOn == true)
            #expect(model.brightness == 25)
            #expect(model.temperature == 4000)
        }
    }

    @Test func dragDoesNotConnectUntilReleaseAndAppliesOnlyFinalValue() async throws {
        try await withModel { model, transport in
            model.setEditing(true)
            model.setBrightness(20)
            model.setBrightness(21)
            #expect(model.brightnessText == "21%")
            #expect(model.presentation == .editing)
            #expect(model.brightnessAccessibilityValue.contains("Not applied"))
            #expect(model.temperatureAccessibilityValue.contains("Unknown"))
            try await Task.sleep(for: .milliseconds(350))
            #expect(transport.connectionRequests == 0)
            #expect(transport.writes.isEmpty)
            model.setEditing(false)
            try await eventually { !transport.settings.isEmpty && model.canControl }
            #expect(transport.settings.map(\.payload) == [[21]])
            #expect(model.brightness == 21)
        }
    }

    @Test func keyboardChangesDebounceBeforeConnecting() async throws {
        try await withModel { model, transport in
            model.setTemperature(3800)
            model.setEditing(false) // Redundant idle callbacks must not flush the debounce.
            model.setTemperature(3900)
            model.setEditing(false)
            try await Task.sleep(for: .milliseconds(100))
            #expect(transport.connectionRequests == 0)
            try await eventually { !transport.settings.isEmpty && model.canControl }
            #expect(transport.attachments == 1)
            #expect(transport.settings.map(\.payload) == [[0x0f, 0x3c]])
            #expect(model.temperature == 3900)
        }
    }

    @Test func standardSliderEditingCallbacksCoalesceRapidChanges() async throws {
        try await withModel { model, transport in
            for value in [4100.0, 4200, 4300] {
                model.setEditing(true)
                model.setTemperature(value)
                model.setEditing(false)
                try await Task.sleep(for: .milliseconds(100))
                #expect(transport.connectionRequests == 0)
                #expect(model.presentation == .editing)
            }
            try await eventually { model.presentation == .verified && model.canControl }
            #expect(transport.settings.count == 1)
            #expect(model.temperature == 4300)
        }
    }

    @Test func failedWriteRestoresReadStateAndAllowsUserRetry() async throws {
        try await withModel { model, transport in
            transport.ignoreSets = true
            model.setPower(false)
            try await eventually { model.canControl }
            #expect(model.isOn == true)
            #expect(!model.isConnected)
            #expect(model.status.contains("reports 1"))
            #expect(model.failureMessage?.contains("reports 1") == true)
            #expect(model.presentation == .stale)
            #expect(model.brightnessAccessibilityValue.contains("Last known"))
            transport.ignoreSets = false
            model.setPower(false)
            try await eventually { model.canControl }
            #expect(model.isOn == false)
            #expect(transport.connectionRequests == 2)
            #expect(model.presentation == .verified)
            #expect(model.failureMessage == nil)
        }
    }

    @Test func disconnectDiscardsUnsentEditsAndDoesNotAutoReconnect() async throws {
        let transport = ModelTransport(light: descriptor(1))
        let model = LightModel(light: descriptor(1), transport: transport, refreshInterval: .milliseconds(20))
        model.start()
        defer { model.stop() }
        model.setPower(true)
        try await eventually { model.canControl }
        let count = transport.settings.count
        model.setBrightness(20)
        transport.disconnect()
        try await Task.sleep(for: .milliseconds(400))
        #expect(transport.settings.count == count)
        #expect(model.brightness == 25)
        #expect(!model.isConnected)
        #expect(model.presentation == .stale)
        #expect(model.brightnessText == "25%")
        #expect(model.brightnessAccessibilityValue.contains("not current state"))
        #expect(model.canControl)
        #expect(transport.connectionRequests == 1)
    }

    @Test func invalidInitialStatusPreventsAnySettingWrite() async throws {
        try await withModel { model, transport in
            transport.values[0xa1] = [2]
            model.setPower(true)
            try await eventually { model.canControl }
            #expect(transport.settings.isEmpty)
            #expect(model.isOn == nil)
            #expect(!model.isConnected)
        }
    }

    @Test func firstTemperatureEditRespectsFreshlyReadLimits() async throws {
        try await withModel { model, transport in
            transport.values[0xa5] = [0x0f, 0xa0, 0x19, 0x64] // 4000–6500 K
            model.setEditing(true)
            model.setTemperature(3000)
            model.setEditing(false)
            try await eventually { model.canControl && model.presentation != .editing }
            #expect(transport.settings.isEmpty)
            #expect(model.temperatureRange == 4000...6500)
            #expect(model.temperature == 4000)
        }
    }

    @Test func emptyListAndOpeningPanelNeverConnect() {
        let source = FakeLightSource()
        let model = LightsModel(source: source)
        model.start()
        defer { model.stop() }
        model.setDiscoveryActive(true)
        source.publish([descriptor(1)])
        model.setDiscoveryActive(false)
        #expect(source.discoveryRequests == [true, false])
        #expect(source.transports[descriptor(1).id]?.connectionRequests == 0)
        #expect(model.lights[0].canControl)
    }

    @Test func eachLightConnectsIndependentlyOnlyWhenUsed() async throws {
        let source = FakeLightSource()
        let model = LightsModel(source: source)
        model.start()
        defer { model.stop() }
        source.publish([descriptor(2), descriptor(1)])
        let first = try #require(source.transports[descriptor(1).id])
        let second = try #require(source.transports[descriptor(2).id])
        #expect(model.lights.map(\.id) == [descriptor(1).id, descriptor(2).id])
        model.lights[0].setPower(true)
        try await eventually { model.lights[0].canControl }
        #expect(first.settings.map(\.mac) == [first.device.mac])
        #expect(second.connectionRequests == 0)
        #expect(second.writes.isEmpty)
        #expect(model.lights[1].isOn == nil)
        model.lights[1].setPower(false)
        try await eventually { model.lights[1].canControl }
        #expect(second.settings.map(\.mac) == [second.device.mac])
        #expect(model.lights[0].isOn == true)
        #expect(model.lights[1].isOn == false)
    }

    @Test func repeatedDiscoveryPreservesRowsWithoutAttachments() {
        let source = FakeLightSource()
        let model = LightsModel(source: source)
        model.start()
        defer { model.stop() }
        source.publish([descriptor(1)])
        let original = model.lights[0]
        source.publish([descriptor(1), descriptor(1)])
        #expect(model.lights.count == 1)
        #expect(model.lights[0] === original)
        #expect(source.creationCount == 1)
        #expect(source.transports[descriptor(1).id]?.attachments == 0)
    }

    @Test func removingLightCancelsUnsentFirstUseWithoutAffectingOthers() async throws {
        let source = FakeLightSource()
        let model = LightsModel(source: source)
        model.start()
        defer { model.stop() }
        source.publish([descriptor(1), descriptor(2)])
        let first = try #require(source.transports[descriptor(1).id])
        model.lights[0].setBrightness(20)
        source.publish([descriptor(2)])
        try await Task.sleep(for: .milliseconds(350))
        #expect(model.lights.map(\.id) == [descriptor(2).id])
        #expect(model.lights[0].canControl)
        #expect(first.connectionRequests == 0)
        #expect(first.writes.isEmpty)
    }

    @Test func unavailableAtFirstUseDoesNotWriteOrRetryAutomatically() async throws {
        let source = FakeLightSource()
        let model = LightsModel(source: source)
        model.start()
        defer { model.stop() }
        source.publish([descriptor(1)])
        source.availableIDs = []
        let transport = try #require(source.transports[descriptor(1).id])
        model.lights[0].setPower(true)
        try await eventually { model.lights[0].canControl }
        #expect(transport.connectionRequests == 1)
        #expect(transport.attachments == 0)
        #expect(transport.writes.isEmpty)
        #expect(!model.lights[0].isConnected)
    }

    @Test func missingIdentityRejectsSettingsButLeavesRetryAvailable() async throws {
        let source = FakeLightSource()
        source.configure = { $0.connectError = .invalidIdentity }
        let model = LightsModel(source: source)
        model.start()
        defer { model.stop() }
        source.publish([descriptor(1)])
        let transport = try #require(source.transports[descriptor(1).id])
        model.lights[0].setPower(false)
        try await eventually { model.lights[0].canControl }
        #expect(transport.connectionRequests == 1)
        #expect(transport.writes.isEmpty)
        #expect(model.lights[0].isOn == nil)
        #expect(model.lights[0].status.contains("protocol identity"))
    }

    @Test func oneLightsFailureDoesNotConnectOrDisableOthers() async throws {
        let source = FakeLightSource()
        let model = LightsModel(source: source)
        model.start()
        defer { model.stop() }
        source.publish([descriptor(1), descriptor(2)])
        source.transports[descriptor(1).id]?.ignoreSets = true
        model.lights[0].setPower(false)
        try await eventually { model.lights[0].canControl }
        #expect(!model.lights[0].isConnected)
        #expect(model.lights[1].canControl)
        #expect(source.transports[descriptor(2).id]?.connectionRequests == 0)
    }

    @Test func removalDuringFirstReadDoesNotSendThePendingSetting() async throws {
        let source = FakeLightSource()
        source.configure = { $0.ignoreQueries = true }
        let model = LightsModel(source: source)
        model.start()
        defer { model.stop() }
        source.publish([descriptor(1)])
        model.lights[0].setPower(false)
        try await eventually { source.transports[descriptor(1).id]?.writes.isEmpty == false }
        source.publish([descriptor(2)])
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.lights.count == 1)
        #expect(model.lights[0].id == descriptor(2).id)
        #expect(source.transports[descriptor(1).id]?.settings.isEmpty == true)
        #expect(source.transports[descriptor(1).id]?.isConnected == false)
        #expect(source.transports[descriptor(2).id]?.connectionRequests == 0)
    }

    @Test func optimisticConnectedEditsAreNotPresentedAsVerified() async throws {
        try await withModel { model, transport in
            model.setPower(true)
            try await eventually { model.canControl }
            #expect(model.presentation == .verified)
            let previousSettings = transport.settings.count
            model.setEditing(true)
            model.setBrightness(42)
            #expect(model.isConnected)
            #expect(model.presentation == .editing)
            #expect(!model.presentation.isVerified)
            #expect(model.brightnessAccessibilityValue.contains("Not applied"))
            #expect(transport.settings.count == previousSettings)
            var observedApplying = false
            transport.onSetting = {
                observedApplying = true
                #expect(model.presentation == .applying)
                #expect(!model.presentation.isVerified)
                #expect(!model.canControl)
            }
            model.setEditing(false)
            try await eventually { model.canControl && model.presentation == .verified }
            #expect(observedApplying)
            #expect(model.presentation == .verified)
            #expect(model.brightness == 42)
        }
    }

    @Test func backgroundRefreshKeepsVerifiedPresentationWithoutFlicker() async throws {
        let transport = ModelTransport(light: descriptor(1))
        let model = LightModel(light: descriptor(1), transport: transport, refreshInterval: .milliseconds(20))
        defer { model.stop() }
        model.start()
        model.setPower(true)
        try await eventually { model.canControl }
        var observedRefresh = false
        transport.onQuery = {
            observedRefresh = true
            #expect(model.isBusy)
            #expect(model.presentation == .verified)
        }
        try await eventually { observedRefresh }
    }

    @Test func titlesOnlyUseIdentifiersToDisambiguateAndHandleSuffixCollisions() {
        let source = FakeLightSource()
        let model = LightsModel(source: source)
        model.start()
        defer { model.stop() }
        source.publish([descriptor(1)])
        #expect(model.title(for: model.lights[0]) == "YLight")
        source.publish([descriptor(1), descriptor(2)])
        #expect(model.lights.map { model.title(for: $0) } == ["YLight · 0001", "YLight · 0002"])
        source.publish([descriptor(1), descriptor(10001)])
        #expect(model.lights.map { model.title(for: $0) } == ["YLight · 00000001", "YLight · 00010001"])
    }

    @Test func stoppedModelIgnoresLateDiscoveryAndVisibilityUpdates() {
        let source = FakeLightSource()
        let model = LightsModel(source: source)
        model.start()
        let lateUpdate = source.onLights
        model.stop()
        lateUpdate?([descriptor(1)])
        model.setDiscoveryActive(true)
        #expect(model.lights.isEmpty)
        #expect(source.creationCount == 0)
        #expect(source.discoveryRequests.isEmpty)
        #expect(source.stops == 1)
    }
}
