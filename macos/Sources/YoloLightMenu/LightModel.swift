import Combine
import Foundation
import LightCore

/// Per-light state. Discovery/startup never connects; only an explicit edit does.
@MainActor
final class LightModel: ObservableObject, Identifiable {
    nonisolated let light: AvailableLight
    nonisolated var id: UUID { light.id }
    @Published private(set) var isOn: Bool?
    @Published private(set) var brightness = 50.0
    @Published private(set) var temperature = 4000.0
    @Published private(set) var temperatureRange = 2700.0...6500.0
    @Published private(set) var isConnected = false
    @Published private(set) var isBusy = false
    @Published private(set) var status = "Adjust a control to connect. Current settings have not been read."
    @Published private(set) var failureMessage: String?

    private let session: LightSession
    private let refreshInterval: Duration
    private var lastState: LightState?
    private var monitorTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var pendingChange: (LightSetting, Int)?
    private var activeSetting: LightSetting?
    private var editing = false
    private var stopping = false

    var canControl: Bool { !isBusy && !stopping }
    var presentation: LightPresentation {
        if activeSetting != nil { return isConnected ? .applying : .connecting }
        if pendingChange != nil { return .editing }
        if !isConnected { return lastState == nil ? .unread : .stale }
        return .verified
    }
    var powerAccessibilityValue: String {
        guard let isOn else { return "Unknown. Not read from the light." }
        return "\(isOn ? "On" : "Off"). \(presentation.accessibilityContext)"
    }
    var brightnessAccessibilityValue: String {
        brightnessText == "—" ? "Unknown. Not read from the light."
            : "\(Int(brightness)) percent. \(presentation.accessibilityContext)"
    }
    var temperatureAccessibilityValue: String {
        temperatureText == "—" ? "Unknown. Not read from the light."
            : "\(Int(temperature)) kelvin. \(presentation.accessibilityContext)"
    }
    var brightnessText: String {
        lastState != nil || pendingChange?.0 == .brightness || activeSetting == .brightness ? "\(Int(brightness))%" : "—"
    }
    var temperatureText: String {
        lastState != nil || pendingChange?.0 == .temperature || activeSetting == .temperature ? "\(Int(temperature)) K" : "—"
    }

    init(light: AvailableLight, transport: any LightTransport, refreshInterval: Duration = .seconds(5)) {
        self.light = light
        self.refreshInterval = refreshInterval
        session = LightSession(transport: transport)
        session.onDisconnect = { [weak self] error in
            guard let self, !self.stopping else { return }
            self.editing = false
            self.pendingChange = nil
            self.debounceTask?.cancel()
            self.restoreLastState()
            self.isConnected = false
            self.failureMessage = error.localizedDescription
            self.status = "\(error.localizedDescription) Adjust a control to reconnect."
        }
    }

    func start() {
        guard monitorTask == nil, !stopping else { return }
        monitorTask = Task { [weak self, refreshInterval] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: refreshInterval) } catch { return }
            }
        }
    }

    func stop() {
        stopping = true
        monitorTask?.cancel()
        actionTask?.cancel()
        debounceTask?.cancel()
        pendingChange = nil
        editing = false
        session.onDisconnect = nil
        session.disconnect()
        isConnected = false
        isBusy = false
    }

    func setPower(_ on: Bool) {
        // Standard SwiftUI controls stay visually enabled. Republish on rejected
        // keyboard/accessibility edits so their bindings redraw the actual value.
        guard canControl else { objectWillChange.send(); return }
        isOn = on
        apply(.power, value: on ? 1 : 0)
    }

    func setBrightness(_ value: Double) {
        guard canControl, value.isFinite, (0...100).contains(value) else { objectWillChange.send(); return }
        brightness = value.rounded()
        stage(.brightness, value: Int(brightness))
    }

    func setTemperature(_ value: Double) {
        guard canControl, value.isFinite, temperatureRange.contains(value) else { objectWillChange.send(); return }
        temperature = (value / 100).rounded() * 100
        stage(.temperature, value: Int(temperature))
    }

    func setEditing(_ value: Bool) {
        guard !stopping, editing != value else { return }
        editing = value
        if value { debounceTask?.cancel() } else { scheduleCommit() }
    }

    private func stage(_ setting: LightSetting, value: Int) {
        pendingChange = (setting, value)
        scheduleCommit()
    }

    private func scheduleCommit() {
        debounceTask?.cancel()
        // Stock SwiftUI Slider brackets keyboard/accessibility changes too.
        // Debounce completed edits as well as unbracketed binding changes;
        // never connect or apply while a drag is still in progress.
        guard !editing, pendingChange != nil else { return }
        debounceTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self, !self.stopping, !self.editing else { return }
            self.commitPendingChange()
        }
    }

    private func commitPendingChange() {
        debounceTask?.cancel()
        guard let (setting, value) = pendingChange else { return }
        pendingChange = nil
        guard canControl else { restoreLastState(); return }
        apply(setting, value: value)
    }

    private func apply(_ setting: LightSetting, value: Int) {
        guard canControl else { return }
        pendingChange = nil
        activeSetting = setting
        failureMessage = nil
        debounceTask?.cancel()
        isBusy = true
        status = session.isConnected ? "Applying and verifying the setting…" : "Connecting to read and apply your setting…"
        actionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.activeSetting = nil; self.isBusy = false }
            do {
                try Task.checkCancellation()
                if !self.session.isConnected {
                    try await self.session.connect()
                    try Task.checkCancellation()
                    // Validate the identity and read actual state before the first setting write.
                    let initial = try await self.session.status()
                    try Task.checkCancellation()
                    guard !self.stopping else { return }
                    self.accept(initial)
                    self.isConnected = true
                }
                try Task.checkCancellation()
                guard !self.stopping else { return }
                self.status = "Applying and verifying the setting…"
                try await self.session.set(setting, to: value)
                try Task.checkCancellation()
                guard !self.stopping else { return }
                let state = try await self.session.status()
                guard !self.stopping else { return }
                self.accept(state)
                self.status = "Connected — settings verified."
            } catch {
                self.recover(from: error)
            }
        }
    }

    private func refresh() async {
        // Never connect/reconnect in the background, even if macOS holds a connection.
        guard session.isConnected, !stopping, !isBusy, !editing, pendingChange == nil else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try Task.checkCancellation()
            let state = try await session.status()
            guard !stopping else { return }
            accept(state)
            status = "Connected — settings verified."
        } catch {
            recover(from: error)
        }
    }

    private func accept(_ state: LightState) {
        lastState = state
        isOn = state.isOn
        brightness = Double(state.brightness)
        temperatureRange = Double(state.temperatureRange.lowerBound)...Double(state.temperatureRange.upperBound)
        temperature = Double(state.temperature)
    }

    private func restoreLastState() {
        if let lastState { accept(lastState) } else {
            isOn = nil
            brightness = 50
            temperature = 4000
        }
    }

    private func recover(from error: Error) {
        guard !stopping else { return }
        restoreLastState()
        isConnected = false
        session.disconnect()
        failureMessage = error.localizedDescription
        status = "\(error.localizedDescription) Adjust a control to try again."
    }
}
