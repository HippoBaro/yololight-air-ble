import AppKit
import Combine
import SwiftUI

@main
struct YoloLightMenuApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = LightsModel()
    private lazy var panel = LightPopover(model: model)
    private var statusItem: NSStatusItem?
    private var subscription: AnyCancellable?
    private var keyboardMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenus()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        item.button?.setAccessibilityLabel("YoloLight Air")
        subscription = model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.updateIcon() }
        }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, self.panel.isShown else { return false }
                if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "q" {
                    NSApp.terminate(nil)
                    return true
                }
                if event.keyCode == 53 {
                    self.panel.close()
                    return true
                }
                return false
            }
            return handled ? nil : event
        }
        updateIcon()
        model.start()
    }

    private func installMenus() {
        let menu = NSMenu()
        let appMenu = NSMenu(title: "YoloLight Air")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let quit = NSMenuItem(title: "Quit YoloLight Air", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        appMenu.addItem(quit)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    private func updateIcon() {
        let image = NSImage(systemSymbolName: model.symbol, accessibilityDescription: "YoloLight Air")
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.toolTip = "YoloLight Air — \(model.tooltip)"
        statusItem?.button?.setAccessibilityHelp(model.tooltip)
    }

    @objc private func togglePanel() {
        guard let button = statusItem?.button else { return }
        if panel.isShown {
            panel.close()
        } else {
            NSApp.activate(ignoringOtherApps: true)
            panel.show(relativeTo: button.bounds, of: button)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
    }
}
