import ServiceManagement

/// macOS owns the preference; no separate UserDefaults flag can get out of sync.
@MainActor
protocol LoginItemService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
    func openSettings()
}

@MainActor
final class SystemLoginItemService: LoginItemService {
    private let service = SMAppService.mainApp

    var status: SMAppService.Status { service.status }
    func register() throws { try service.register() }
    func unregister() async throws { try await service.unregister() }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
