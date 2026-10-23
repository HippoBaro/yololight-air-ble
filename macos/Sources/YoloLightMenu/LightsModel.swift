import Combine
import Foundation

@MainActor
final class LightsModel: ObservableObject {
    @Published private(set) var lights: [LightModel] = []
    @Published private(set) var status = "Waiting for Bluetooth…"
    private let source: any LightSource
    private var subscriptions: [UUID: AnyCancellable] = [:]
    private var started = false

    var symbol: String {
        if lights.isEmpty { return "lightbulb.slash" }
        return lights.contains { $0.isConnected && $0.isOn == true } ? "lightbulb.fill" : "lightbulb"
    }

    var tooltip: String {
        guard !lights.isEmpty else { return status }
        let ready = lights.filter(\.isConnected).count
        return "\(lights.count) available \(lights.count == 1 ? "light" : "lights"), \(ready) controlled. Click to adjust; ⌘Q to quit."
    }

    /// Hide identifiers for a single light; disambiguate identical names with
    /// the shortest unique suffix. The full UUID remains in the row's help text.
    func title(for light: LightModel) -> String {
        let peers = lights.filter { $0.light.name == light.light.name && $0.id != light.id }
        guard !peers.isEmpty else { return light.light.name }
        let identifier = light.id.uuidString
        var length = 4
        while peers.contains(where: { $0.id.uuidString.suffix(length) == identifier.suffix(length) }) {
            length += 4
        }
        return "\(light.light.name) · \(identifier.suffix(length))"
    }

    init(source: any LightSource = BluetoothLights()) { self.source = source }

    func setDiscoveryActive(_ active: Bool) {
        guard started else { return }
        source.setDiscoveryActive(active)
    }

    func start() {
        guard !started else { return }
        started = true
        source.onLights = { [weak self] descriptors in
            guard let self, self.started else { return }
            self.update(descriptors)
        }
        source.onStatus = { [weak self] status in
            guard let self, self.started else { return }
            self.status = status
        }
        source.start()
    }

    func stop() {
        started = false
        for light in lights { light.stop() }
        subscriptions.removeAll()
        lights = []
        source.onLights = nil
        source.onStatus = nil
        source.stop()
    }

    private func update(_ descriptors: [AvailableLight]) {
        let unique = Dictionary(descriptors.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = unique.values.sorted { $0.id.uuidString < $1.id.uuidString }
        guard ordered.map(\.id) != lights.map(\.id) else { return }
        let existing = Dictionary(uniqueKeysWithValues: lights.map { ($0.id, $0) })
        for light in lights where unique[light.id] == nil {
            light.stop()
            subscriptions.removeValue(forKey: light.id)
        }
        lights = ordered.map { descriptor in
            if let model = existing[descriptor.id] { return model }
            let model = LightModel(light: descriptor, transport: source.makeTransport(for: descriptor))
            subscriptions[descriptor.id] = model.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
            model.start()
            return model
        }
    }
}
