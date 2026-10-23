import AppKit
import Foundation
import ServiceManagement
import Testing
@testable import YoloLightMenu

/// Uses fake login items only. No registration, System Settings, or real quits.
@Suite(.serialized)
@MainActor
struct StatusMenuTests {
    private func eventually(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while !condition(), clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }

    private func controller(_ service: FakeLoginItemService,
                            onQuit: @escaping @MainActor () -> Void = {},
                            onError: @escaping @MainActor (Error) -> Void = { _ in }) -> StatusMenu {
        NSApplication.shared.setActivationPolicy(.accessory)
        return StatusMenu(loginItem: service, onQuit: onQuit, onError: onError)
    }

    @Test func menuHasOnlyTheRequestedStandardItemsAndOpeningNeverRegisters() {
        let service = FakeLoginItemService()
        let menu = controller(service)
        menu.menuWillOpen(menu.menu)
        #expect(menu.menu.items.map(\.title) == ["Open at Startup", "Quit"])
        #expect(menu.menu.items.allSatisfy { $0.view == nil && $0.isEnabled })
        #expect(menu.menu.items[0].state == .off)
        #expect(menu.menu.items[1].keyEquivalent == "q")
        #expect(menu.menu.items[1].keyEquivalentModifierMask == .command)
        #expect(menu.menu.showsStateColumn)
        #expect(!menu.menu.autoenablesItems)
        #expect(service.registrations == 0 && service.unregistrations == 0 && service.settingsOpened == 0)
    }

    @Test func checkmarkTracksSystemChangesOnEachOpening() {
        let service = FakeLoginItemService()
        service.status = .enabled
        let menu = controller(service)
        #expect(menu.menu.items[0].state == .on)
        for status in [SMAppService.Status.notRegistered, .requiresApproval, .notFound, .enabled] {
            service.status = status
            menu.menuWillOpen(menu.menu)
            #expect(menu.menu.items[0].state == (status == .enabled ? .on : .off))
        }
        #expect(service.registrations == 0 && service.unregistrations == 0 && service.settingsOpened == 0)
    }

    @Test func nativeMenuActionsEnableThenDisableStartup() async throws {
        let service = FakeLoginItemService()
        let menu = controller(service)
        menu.menu.performActionForItem(at: 0)
        #expect(menu.isUpdating)
        #expect(menu.menu.items[0].state == .off, "Never show success before the system reports enabled")
        try await eventually { !menu.isUpdating }
        #expect(service.registrations == 1 && service.unregistrations == 0)
        #expect(menu.menu.items[0].state == .on)
        menu.menu.performActionForItem(at: 0)
        try await eventually { !menu.isUpdating }
        #expect(service.registrations == 1 && service.unregistrations == 1)
        #expect(menu.menu.items[0].state == .off)
        #expect(service.settingsOpened == 0)
    }

    @Test func approvalPendingOpensSettingsWithoutClaimingEnabled() async throws {
        let service = FakeLoginItemService()
        service.status = .requiresApproval
        let menu = controller(service)
        #expect(menu.menu.items[0].toolTip?.contains("Approval") == true)
        menu.menu.performActionForItem(at: 0)
        try await eventually { !menu.isUpdating }
        #expect(service.settingsOpened == 1)
        #expect(service.registrations == 0 && service.unregistrations == 0)
        #expect(menu.menu.items[0].state == .off)
        service.status = .enabled
        menu.menuWillOpen(menu.menu)
        #expect(menu.menu.items[0].state == .on)
    }

    @Test func registrationRequiringApprovalIsUncheckedAndOpensSettings() async throws {
        let service = FakeLoginItemService()
        service.registrationResult = .requiresApproval
        let menu = controller(service)
        menu.menu.performActionForItem(at: 0)
        try await eventually { !menu.isUpdating }
        #expect(service.registrations == 1 && service.settingsOpened == 1)
        #expect(menu.menu.items[0].state == .off)
    }

    @Test func deniedRegistrationUsesSystemApprovalRatherThanAnErrorAlert() async throws {
        let service = FakeLoginItemService()
        service.registrationError = LoginItemTestError()
        service.requireApprovalOnError = true
        var errors = 0
        let menu = controller(service, onError: { _ in errors += 1 })
        menu.menu.performActionForItem(at: 0)
        try await eventually { !menu.isUpdating }
        #expect(errors == 0 && service.settingsOpened == 1)
        #expect(menu.menu.items[0].state == .off)
    }

    @Test func failedRegistrationReportsErrorAndAllowsExplicitRetry() async throws {
        let service = FakeLoginItemService()
        service.registrationError = LoginItemTestError()
        var messages: [String] = []
        let menu = controller(service, onError: { messages.append($0.localizedDescription) })
        menu.menu.performActionForItem(at: 0)
        try await eventually { !menu.isUpdating }
        #expect(messages == ["Synthetic login-item failure."])
        #expect(menu.menu.items[0].state == .off && menu.menu.items[0].isEnabled)
        #expect(service.registrations == 1 && service.settingsOpened == 0)
        service.registrationError = nil
        menu.menu.performActionForItem(at: 0)
        try await eventually { !menu.isUpdating }
        #expect(service.registrations == 2 && menu.menu.items[0].state == .on)
    }

    @Test func failedUnregistrationDoesNotClearCheckmarkOrOpenSettings() async throws {
        let service = FakeLoginItemService()
        service.status = .enabled
        service.unregistrationError = LoginItemTestError()
        var errors = 0
        let menu = controller(service, onError: { _ in errors += 1 })
        menu.menu.performActionForItem(at: 0)
        try await eventually { !menu.isUpdating }
        #expect(errors == 1 && service.unregistrations == 1)
        #expect(menu.menu.items[0].state == .on && menu.menu.items[0].isEnabled)
        #expect(service.settingsOpened == 0)
    }

    @Test func busyStartupRejectsRepeatedActionsButQuitRemainsAvailable() async throws {
        let service = FakeLoginItemService()
        service.status = .enabled
        service.holdUnregistration = true
        var quits = 0
        let menu = controller(service, onQuit: { quits += 1 })
        defer { service.finishUnregistration() }
        menu.menu.performActionForItem(at: 0)
        try await eventually { service.unregistrations == 1 }
        #expect(menu.isUpdating && !menu.menu.items[0].isEnabled)
        #expect(menu.menu.items[1].isEnabled)
        menu.menu.performActionForItem(at: 0)
        menu.menu.performActionForItem(at: 1)
        #expect(quits == 1 && service.unregistrations == 1)
        service.finishUnregistration()
        try await eventually { !menu.isUpdating }
        #expect(menu.menu.items[0].state == .off && menu.menu.items[0].isEnabled)
    }

    @Test func quitDoesNotChangeLoginItemRegistration() {
        let service = FakeLoginItemService()
        service.status = .enabled
        var quits = 0
        let menu = controller(service, onQuit: { quits += 1 })
        menu.menu.performActionForItem(at: 1)
        #expect(quits == 1)
        #expect(service.status == .enabled)
        #expect(service.registrations == 0 && service.unregistrations == 0)
    }

    @Test func notFoundCanBeExplicitlyRegistered() async throws {
        let service = FakeLoginItemService()
        service.status = .notFound
        let menu = controller(service)
        menu.menu.performActionForItem(at: 0)
        try await eventually { !menu.isUpdating }
        #expect(service.registrations == 1 && menu.menu.items[0].state == .on)
    }

    @Test func rightAndControlClicksOpenMenuWhileNormalClickRemainsForControls() throws {
        func event(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        #expect(StatusMenu.isContextClick(try event(.rightMouseUp)))
        #expect(StatusMenu.isContextClick(try event(.leftMouseUp, .control)))
        #expect(!StatusMenu.isContextClick(try event(.leftMouseUp)))
        #expect(!StatusMenu.isContextClick(try event(.leftMouseUp, .command)))
        #expect(!StatusMenu.isContextClick(nil), "Accessibility/keyboard activation still opens the controls")
    }
}

private struct LoginItemTestError: LocalizedError {
    var errorDescription: String? { "Synthetic login-item failure." }
}

@MainActor
private final class FakeLoginItemService: LoginItemService {
    var status: SMAppService.Status = .notRegistered
    var registrationResult: SMAppService.Status = .enabled
    var registrationError: Error?
    var unregistrationError: Error?
    var requireApprovalOnError = false
    var holdUnregistration = false
    var registrations = 0
    var unregistrations = 0
    var settingsOpened = 0
    private var unregistration: CheckedContinuation<Void, Never>?

    func register() throws {
        registrations += 1
        if let registrationError {
            if requireApprovalOnError { status = .requiresApproval }
            throw registrationError
        }
        status = registrationResult
    }

    func unregister() async throws {
        unregistrations += 1
        if holdUnregistration { await withCheckedContinuation { unregistration = $0 } }
        if let unregistrationError { throw unregistrationError }
        status = .notRegistered
    }

    func finishUnregistration() {
        unregistration?.resume()
        unregistration = nil
    }

    func openSettings() { settingsOpened += 1 }
}
