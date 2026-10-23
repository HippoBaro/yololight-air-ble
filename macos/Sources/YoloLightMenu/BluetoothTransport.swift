import CoreBluetooth
import Foundation
import LightCore

/// One GATT session, created lazily when the user changes a light's settings.
@MainActor
final class BluetoothTransport: NSObject, LightTransport, @preconcurrency CBPeripheralDelegate {
    let identifier: UUID
    private weak var source: BluetoothLights?
    private(set) var peripheral: CBPeripheral?
    private let serviceID = CBUUID(string: "FFF0")
    private let controlID = CBUUID(string: "FFF1")
    private var control: CBCharacteristic?
    private var identity: DeviceIdentity?
    private var notifying = false
    private var connection: CheckedContinuation<DeviceIdentity, Error>?
    private var writeReply: CheckedContinuation<Void, Error>?
    private var connectionTimeout: Task<Void, Never>?
    private var writeTimeout: Task<Void, Never>?
    private var phase = "connecting to the light"
    private(set) var isConnected = false
    var onNotification: ((Data) -> Void)?
    var onDisconnect: ((Error) -> Void)?

    init(identifier: UUID, source: BluetoothLights) {
        self.identifier = identifier
        self.source = source
        super.init()
    }

    func connect() async throws -> DeviceIdentity {
        if isConnected, let identity { return identity }
        guard connection == nil else { throw LightError.busy }
        guard let source else { throw LightError.notConnected }
        identity = nil
        notifying = false
        phase = "connecting to the light"
        return try await withCheckedThrowingContinuation { continuation in
            connection = continuation
            connectionTimeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard let self else { return }
                self.failed(LightError.disconnected("Timed out \(self.phase). Keep the light powered on and within range, then try again."))
            }
            do { try source.attach(self) } catch { failed(error) }
        }
    }

    func prepare(_ peripheral: CBPeripheral, identity: DeviceIdentity?) {
        self.peripheral = peripheral
        self.identity = identity
        peripheral.delegate = self
    }

    func didConnect() {
        guard let peripheral, peripheral.name == "YLight" else {
            failed(LightError.disconnected("The connected peripheral is not a YLight; refusing control."))
            return
        }
        phase = "discovering the control service"
        peripheral.discoverServices([serviceID])
    }

    func write(_ data: Data) async throws {
        guard isConnected, let peripheral, let control else { throw LightError.notConnected }
        guard writeReply == nil else { throw LightError.busy }
        try await withCheckedThrowingContinuation { continuation in
            writeReply = continuation
            writeTimeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
                self?.failed(LightError.timeout)
            }
            peripheral.writeValue(data, for: control, type: .withResponse)
        }
    }

    func disconnect() { failed(LightError.notConnected) }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.peripheral else { return }
        if let error { failed(error); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceID }) else {
            failed(LightError.disconnected("The light's control service was not found."))
            return
        }
        phase = "discovering the control characteristic"
        peripheral.discoverCharacteristics([controlID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === self.peripheral, service.uuid == serviceID else { return }
        if let error { failed(error); return }
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == controlID }),
              characteristic.properties.contains(.write), characteristic.properties.contains(.notify) else {
            failed(LightError.disconnected("The light's write/notify control characteristic was not found."))
            return
        }
        control = characteristic
        phase = identity == nil ? "waiting for the light's protocol identity announcement" : "enabling notifications"
        peripheral.setNotifyValue(true, for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard peripheral === self.peripheral, characteristic === control else { return }
        if let error { failed(error); return }
        guard characteristic.isNotifying else {
            failed(LightError.disconnected("Notifications from the light are unavailable."))
            return
        }
        notifying = true
        completeAttachmentIfReady()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, characteristic === control else { return }
        if let error { failed(error); return }
        guard let data = characteristic.value else { return }
        if connection != nil, identity == nil,
           let candidate = IdentityAnnouncement.candidate(from: data, identifier: identifier) {
            identity = candidate
            completeAttachmentIfReady()
        }
        onNotification?(data)
    }

    private func completeAttachmentIfReady() {
        guard notifying, let identity, let continuation = connection else { return }
        isConnected = true
        connectionTimeout?.cancel()
        connectionTimeout = nil
        connection = nil
        // This is only a candidate identity. LightSession must read valid status
        // replies before LightModel sends the user's first setting command.
        continuation.resume(returning: identity)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, characteristic === control else { return }
        if let error { failed(error); return }
        writeTimeout?.cancel()
        writeTimeout = nil
        let continuation = writeReply
        writeReply = nil
        continuation?.resume()
    }

    func failed(_ error: Error) {
        let wasConnected = isConnected
        isConnected = false
        notifying = false
        identity = nil
        connectionTimeout?.cancel()
        writeTimeout?.cancel()
        connectionTimeout = nil
        writeTimeout = nil
        peripheral?.delegate = nil
        source?.release(self)
        peripheral = nil
        control = nil
        let oldConnection = connection
        let oldWrite = writeReply
        connection = nil
        writeReply = nil
        oldConnection?.resume(throwing: error)
        oldWrite?.resume(throwing: error)
        if wasConnected { onDisconnect?(error) }
    }
}
