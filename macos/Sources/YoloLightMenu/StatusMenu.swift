import AppKit
import ServiceManagement

/// A standard status-item menu, separate from the left-click light popover.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu(title: "YoloLight Air")
    private let startupItem = NSMenuItem(title: "Open at Startup", action: nil, keyEquivalent: "")
    private let loginItem: any LoginItemService
    private let onQuit: @MainActor () -> Void
    private let onError: @MainActor (Error) -> Void
    private(set) var isUpdating = false

    init(loginItem: any LoginItemService = SystemLoginItemService(),
         onQuit: @escaping @MainActor () -> Void = { NSApp.terminate(nil) },
         onError: @escaping @MainActor (Error) -> Void = StatusMenu.presentError) {
        self.loginItem = loginItem
        self.onQuit = onQuit
        self.onError = onError
        super.init()
        menu.autoenablesItems = false
        menu.allowsContextMenuPlugIns = false
        if #available(macOS 15.2, *) { menu.automaticallyInsertsWritingToolsItems = false }
        menu.delegate = self
        startupItem.target = self
        startupItem.action = #selector(toggleStartup)
        menu.addItem(startupItem)
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = .command
        quit.target = self
        menu.addItem(quit)
        refresh()
    }

    static func isContextClick(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        return event.type == .rightMouseUp
            || (event.type == .leftMouseUp && event.modifierFlags.contains(.control))
    }

    func show(for item: NSStatusItem) {
        guard let button = item.button else { return }
        // Let AppKit position, highlight, and track the standard menu. Do not
        // leave it attached: an ordinary left click must still open the popover.
        item.menu = menu
        defer { item.menu = nil }
        button.performClick(nil)
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    private func refresh() {
        let status = loginItem.status
        startupItem.state = status == .enabled ? .on : .off
        startupItem.isEnabled = !isUpdating
        switch status {
        case .enabled:
            startupItem.toolTip = "Start automatically when you log in. Click to turn off."
        case .notRegistered:
            startupItem.toolTip = "Start automatically when you log in."
        case .requiresApproval:
            startupItem.toolTip = "Approval is required in System Settings. Click to open Login Items."
        case .notFound:
            startupItem.toolTip = "Register this app to start automatically when you log in."
        @unknown default:
            startupItem.isEnabled = false
            startupItem.toolTip = "Login item status is unavailable."
        }
    }

    @objc private func toggleStartup() {
        guard !isUpdating else { return }
        let enable = loginItem.status != .enabled
        isUpdating = true
        refresh()
        Task { await changeStartup(to: enable) }
    }

    private func changeStartup(to enabled: Bool) async {
        defer { isUpdating = false; refresh() }
        do {
            if enabled {
                switch loginItem.status {
                case .enabled: return
                case .requiresApproval:
                    loginItem.openSettings()
                    return
                case .notRegistered, .notFound:
                    try loginItem.register()
                @unknown default: return
                }
                if loginItem.status == .requiresApproval { loginItem.openSettings() }
            } else if loginItem.status != .notRegistered {
                try await loginItem.unregister()
            }
        } catch {
            // A denied registration can report both an error and requiresApproval.
            // Only an explicit enable request should take the user to Settings.
            if enabled && loginItem.status == .requiresApproval {
                loginItem.openSettings()
            } else {
                onError(error)
            }
        }
    }

    @objc private func quit() { onQuit() }

    private static func presentError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t change Open at Startup"
        alert.informativeText = "\(error.localizedDescription)\n\nKeep the app in Applications and try again. You can also manage login items in System Settings."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
