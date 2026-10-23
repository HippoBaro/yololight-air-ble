import Foundation
import Testing
@testable import LightCore

@MainActor
final class FakeTransport: LightTransport {
    var isConnected = false
    var onNotification: ((Data) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    var values: [UInt8: [UInt8]] = [0xa1: [1], 0xa2: [25], 0xa3: [0x0f, 0xa0], 0xa5: [0x0a, 0x8c, 0x19, 0x64]]
    var writes: [LightFrame] = []
    var ignoreSets = false
    var ignoreQueries = false
    var writeError: LightError?
    var beforeReply: ((LightFrame) -> Void)?
    var acknowledgementDelay = Duration.zero
    private var writing = false

    func connect() async throws -> DeviceIdentity {
        isConnected = true
        return try DeviceIdentity(address: syntheticAddress, mac: "020000000001")
    }

    func disconnect() {
        let connected = isConnected
        isConnected = false
        if connected { onDisconnect?(LightError.notConnected) }
    }

    func write(_ data: Data) async throws {
        guard isConnected else { throw LightError.notConnected }
        guard !writing else { throw LightError.busy }
        writing = true
        defer { writing = false }
        if let writeError { throw writeError }
        let frame = try LightFrame.decode(data)
        writes.append(frame)
        if frame.kind == 1, !ignoreSets { values[frame.command + 0xa0] = frame.payload }
        if frame.kind == 2 {
            beforeReply?(frame)
            if !ignoreQueries {
                let reply = try LightFrame.encode(mac: frame.mac, command: frame.command, kind: 2,
                                                  sequence: 0xffff, payload: values[frame.command] ?? [])
                onNotification?(reply)
            }
        }
        if acknowledgementDelay > .zero { try await Task.sleep(for: acknowledgementDelay) }
    }
}

@Suite(.serialized)
@MainActor
struct LightSessionTests {
    private func connected(timeout: Duration = .seconds(1)) async throws -> (LightSession, FakeTransport) {
        let transport = FakeTransport()
        let session = LightSession(transport: transport, replyTimeout: timeout, settlingDelay: .zero)
        try await session.connect()
        return (session, transport)
    }

    @Test func statusOnlyQueries() async throws {
        let (session, transport) = try await connected()
        let state = try await session.status()
        #expect(state == LightState(isOn: true, brightness: 25, temperature: 4000, temperatureRange: 2700...6500))
        #expect(transport.writes.map(\.command) == [0xa1, 0xa2, 0xa3, 0xa5])
        #expect(transport.writes.map(\.sequence) == [1, 2, 3, 4])
        #expect(transport.writes.allSatisfy { $0.kind == 2 })
    }

    @Test func settersVerifyReadback() async throws {
        let (session, transport) = try await connected()
        let brightness = try await session.set(.brightness, to: 20)
        let temperature = try await session.set(.temperature, to: 3900)
        let power = try await session.set(.power, to: 0)
        #expect(brightness == 20)
        #expect(temperature == 3900)
        #expect(power == 0)
        let state = try await session.status()
        #expect(state == LightState(isOn: false, brightness: 20, temperature: 3900, temperatureRange: 2700...6500))
        #expect(transport.writes.filter { $0.kind == 1 }.map(\.command) == [2, 3, 1])
    }

    @Test func mismatchIsNotSuccess() async throws {
        let (session, transport) = try await connected()
        transport.ignoreSets = true
        await #expect(throws: LightError.readbackMismatch(expected: 20, actual: 25)) {
            try await session.set(.brightness, to: 20)
        }
        #expect(!session.isConnected)
    }

    @Test func invalidBrightnessDoesNotWrite() async throws {
        for value in [-1, 101] {
            let (session, transport) = try await connected()
            await #expect(throws: (any Error).self) { try await session.set(.brightness, to: value) }
            #expect(transport.writes.isEmpty)
        }
    }

    @Test func invalidPowerDoesNotWrite() async throws {
        for value in [-1, 2] {
            let (session, transport) = try await connected()
            await #expect(throws: (any Error).self) { try await session.set(.power, to: value) }
            #expect(transport.writes.isEmpty)
        }
    }

    @Test func invalidTemperatureOnlyQueriesLimits() async throws {
        for value in [2600, 6600, 4001] {
            let (session, transport) = try await connected()
            await #expect(throws: (any Error).self) { try await session.set(.temperature, to: value) }
            #expect(transport.writes.map(\.command) == [0xa5])
            #expect(transport.writes.allSatisfy { $0.kind == 2 })
        }
    }

    @Test func invalidAndForeignNotificationsAreIgnored() async throws {
        let (session, transport) = try await connected()
        transport.beforeReply = { [weak transport] frame in
            transport?.onNotification?(Data([0, 1, 2]))
            transport?.onNotification?(bytes("ffcc0de402000000000105a4f1ff05ff"))
            transport?.onNotification?(try! LightFrame.encode(mac: [2, 0, 0, 0, 0, 2], command: frame.command,
                                                             kind: 2, sequence: 0xffff, payload: [0]))
            transport?.onNotification?(try! LightFrame.encode(mac: syntheticMAC, command: 0x99,
                                                             kind: 2, sequence: 0xffff, payload: [0]))
            transport?.onNotification?(try! LightFrame.encode(mac: syntheticMAC, command: frame.command,
                                                             kind: 1, sequence: 0xffff, payload: [0]))
        }
        let state = try await session.status()
        #expect(state.brightness == 25)
    }

    @Test func staleReplyBeforeQueryIsIgnored() async throws {
        let (session, transport) = try await connected()
        transport.onNotification?(try LightFrame.encode(mac: syntheticMAC, command: 0xa2,
                                                        kind: 2, sequence: 0xffff, payload: [100]))
        let state = try await session.status()
        #expect(state.brightness == 25)
    }

    @Test func wrongPayloadSizeFails() async throws {
        let (session, transport) = try await connected()
        transport.values[0xa2] = [0, 25]
        await #expect(throws: LightError.invalidPacket("Unexpected reply payload length.")) {
            try await session.status()
        }
        #expect(!session.isConnected)
    }

    @Test func timeoutClosesSessionAndAllowsFreshConnection() async throws {
        let (session, transport) = try await connected(timeout: .milliseconds(20))
        transport.ignoreQueries = true
        await #expect(throws: LightError.timeout) { try await session.status() }
        #expect(!session.isConnected)
        transport.ignoreQueries = false
        try await session.connect()
        let state = try await session.status()
        #expect(state.brightness == 25)
    }

    @Test func disconnectDuringQueryCompletesWithError() async throws {
        let (session, transport) = try await connected()
        transport.beforeReply = { [weak transport] _ in transport?.disconnect() }
        await #expect(throws: LightError.notConnected) { try await session.status() }
    }

    @Test func writeErrorIsNotHidden() async throws {
        let (session, transport) = try await connected()
        transport.writeError = .disconnected("Synthetic write failure")
        await #expect(throws: LightError.disconnected("Synthetic write failure")) { try await session.status() }
        #expect(!session.isConnected)
    }

    @Test func waitsForWriteAcknowledgementEvenWhenNotificationArrivesFirst() async throws {
        let (session, transport) = try await connected()
        transport.acknowledgementDelay = .milliseconds(5)
        let state = try await session.status()
        #expect(state.brightness == 25)
        #expect(transport.writes.count == 4)
    }

    @Test func concurrentOperationsAreRejected() async throws {
        let (session, transport) = try await connected()
        transport.ignoreQueries = true
        let first = Task { try await session.status() }
        for _ in 0..<100 where transport.writes.isEmpty { await Task.yield() }
        #expect(!transport.writes.isEmpty)
        await #expect(throws: LightError.busy) { try await session.set(.brightness, to: 20) }
        session.disconnect()
        await #expect(throws: (any Error).self) { try await first.value }
        #expect(transport.writes.allSatisfy { $0.kind == 2 })
    }

    @Test func invalidStatusValuesAreRejected() async throws {
        let invalid: [(UInt8, [UInt8])] = [
            (0xa1, [2]), (0xa2, [101]), (0xa3, [0, 1]),
            (0xa5, [0, 0, 0x19, 0x64]), (0xa5, [0x19, 0x64, 0x0a, 0x8c]),
        ]
        for (command, payload) in invalid {
            let (session, transport) = try await connected()
            transport.values[command] = payload
            await #expect(throws: (any Error).self) { try await session.status() }
            #expect(!session.isConnected)
        }
    }
}
