import CoreBluetooth
import Foundation
import LightCore

@MainActor
protocol LightSource: AnyObject {
    var onLights: (([AvailableLight]) -> Void)? { get set }
    var onStatus: ((String) -> Void)? { get set }
    func start()
    func stop()
    func setDiscoveryActive(_ active: Bool)
    func makeTransport(for light: AvailableLight) -> any LightTransport
}

/// Discovery never connects. Only an explicit per-light control operation can attach.
@MainActor
final class BluetoothLights: NSObject, LightSource, @preconcurrency CBCentralManagerDelegate {
    var onLights: (([AvailableLight]) -> Void)?
    var onStatus: ((String) -> Void)?
    private var central: CBCentralManager?
    private var polling: Task<Void, Never>?
    private var started = false
    private var discoveryActive = false
    private var inventory = LightInventory()
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var clients: [UUID: BluetoothTransport] = [:]
    private var detaching: [UUID: CBPeripheral] = [:]
    private let services = [CBUUID(string: "FFF0"), CBUUID(string: "1812")]
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func start() {
        guard !started else { return }
        started = true
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                self?.refresh()
            }
        }
    }

    func stop() {
        started = false
        discoveryActive = false
        polling?.cancel()
        polling = nil
        central?.stopScan()
        for client in Array(clients.values) { client.disconnect() }
        clients.removeAll()
        detaching.removeAll()
        peripherals.removeAll()
        inventory = LightInventory()
        central?.delegate = nil
        central = nil
    }

    func setDiscoveryActive(_ active: Bool) {
        discoveryActive = active
        updateScan()
        refresh()
    }

    private func updateScan() {
        guard started, let central, central.state == .poweredOn else { return }
        if discoveryActive {
            if !central.isScanning {
                // Air advertises HID (1812), not its FFF0 control service. Duplicate
                // advertisements refresh presence; scanning stops with the popover.
                central.scanForPeripherals(withServices: services,
                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            }
        } else if central.isScanning {
            central.stopScan()
        }
    }

    func makeTransport(for light: AvailableLight) -> any LightTransport {
        BluetoothTransport(identifier: light.id, source: self)
    }

    private func updateSystemConnections() {
        guard let central, central.state == .poweredOn else { return }
        let connected = central.retrieveConnectedPeripherals(withServices: services).filter { $0.name == "YLight" }
        inventory.updateSystem(Set(connected.map(\.identifier)))
        for peripheral in connected { peripherals[peripheral.identifier] = peripheral }
    }

    private func publish() {
        onLights?(inventory.lights(at: now, active: Set(clients.keys)))
    }

    private func refresh() {
        guard started, let central else { return }
        guard central.state == .poweredOn else {
            onLights?([])
            switch central.state {
            case .poweredOff: onStatus?("Turn on Bluetooth in System Settings to find nearby lights.")
            case .unauthorized: onStatus?("Allow YoloLight Air in System Settings → Privacy & Security → Bluetooth.")
            case .unsupported: onStatus?("Bluetooth Low Energy is not supported by this Mac.")
            default: onStatus?("Waiting for Bluetooth…")
            }
            return
        }
        updateSystemConnections()
        publish()
        onStatus?("Turn on your light and keep it nearby. Lights appear automatically while this panel is open.")
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard started, discoveryActive, central === self.central else { return }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]
        guard let identity = LightAdvertisement.identity(name: name, identifier: peripheral.identifier,
            serviceData: serviceData?[CBUUID(string: "AAAB")]) else { return }
        peripherals[peripheral.identifier] = peripheral
        inventory.advertised(identity, at: now)
        publish()
    }

    /// Called only by a user-initiated setting operation, never by enumeration.
    func attach(_ client: BluetoothTransport) throws {
        guard started, let central, central.state == .poweredOn else { throw LightError.notConnected }
        guard detaching[client.identifier] == nil, clients[client.identifier] == nil else {
            throw LightError.disconnected("The previous connection is closing. Try the control again in a moment.")
        }
        updateSystemConnections()
        guard inventory.isAvailable(client.identifier, at: now), let peripheral = peripherals[client.identifier] else {
            throw LightError.disconnected("This light is no longer nearby. Keep it powered on and within range, then try again.")
        }
        clients[client.identifier] = client
        client.prepare(peripheral, identity: inventory.identity(for: client.identifier))
        central.connect(peripheral, options: nil)
    }

    func release(_ client: BluetoothTransport) {
        guard clients[client.identifier] === client else { return }
        clients.removeValue(forKey: client.identifier)
        guard let central, central.state == .poweredOn, let peripheral = client.peripheral else { return }
        if peripheral.state == .connected || peripheral.state == .connecting {
            detaching[client.identifier] = peripheral
            central.cancelPeripheralConnection(peripheral)
        } else if peripheral.state == .disconnecting {
            detaching[client.identifier] = peripheral
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === self.central else { return }
        if central.state != .poweredOn {
            detaching.removeAll()
            inventory.invalidateAvailability()
            peripherals.removeAll()
        }
        updateScan()
        refresh()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === self.central,
              let client = clients[peripheral.identifier], client.peripheral === peripheral else { return }
        client.didConnect()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard central === self.central else { return }
        ended(peripheral, error: error ?? LightError.notConnected)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard central === self.central else { return }
        ended(peripheral, error: error ?? LightError.disconnected("The light disconnected. Adjust a control to try again."))
    }

    private func ended(_ peripheral: CBPeripheral, error: Error) {
        if detaching[peripheral.identifier] === peripheral {
            detaching.removeValue(forKey: peripheral.identifier)
        } else if let client = clients[peripheral.identifier], client.peripheral === peripheral {
            client.failed(error)
        }
        refresh()
    }
}
