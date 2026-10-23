import AppKit
import Foundation
import Testing
@testable import YoloLightMenu

/// Opt-in because this test briefly presents an AppKit window/popover. All light
/// operations use fake transports; it never scans, connects, or changes hardware.
@Suite(.serialized)
@MainActor
struct PopoverGeometryTests {
    private func eventually(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(3)
        while !condition(), clock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition())
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["YOLOLIGHT_UI_TESTS"] == "1"))
    func frameStaysPinnedThroughoutAnOpenPresentation() async throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        try #require(NSScreen.main != nil, "Requires a logged-in macOS GUI session")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "YoloLight layout test — simulated lights"
        window.isReleasedWhenClosed = false
        let anchor = NSButton(title: "Simulated lights", target: nil, action: nil)
        anchor.frame = NSRect(x: 110, y: 20, width: 140, height: 28)
        window.contentView?.addSubview(anchor)
        window.center()
        window.makeKeyAndOrderFront(nil)
        application.activate()

        let source = FakeLightSource()
        let model = LightsModel(source: source)
        model.start()
        let panel = LightPopover(model: model)
        defer { model.stop(); panel.close(); window.close() }
        panel.show(relativeTo: anchor.bounds, of: anchor)
        try await Task.sleep(for: .milliseconds(350))
        let initial = try #require(panel.popover.contentViewController?.view.window?.frame)
        let initialContentSize = panel.popover.contentSize
        #expect(initialContentSize == PanelLayout(lightCount: 0).size)

        func expectPinned() throws {
            #expect(panel.isShown)
            let current = try #require(panel.popover.contentViewController?.view.window?.frame)
            #expect(current == initial, "Popover origin and size must stay fixed while shown")
            #expect(panel.popover.contentSize == initialContentSize)
            func checkControls(_ view: NSView) {
                if let control = view as? NSControl {
                    #expect(control.isEnabled, "Operations must not dim controls")
                    if let slider = control as? NSSlider {
                        #expect(slider.frame.width >= 150, "Keep the compact row's slider track usable")
                    }
                }
                view.subviews.forEach(checkControls)
            }
            if let view = panel.popover.contentViewController?.view { checkControls(view) }
        }

        // Late discovery must not resize an already rendered empty-state panel.
        source.publish([descriptor(1), descriptor(2)])
        try await Task.sleep(for: .milliseconds(100))
        try expectPinned()
        let first = model.lights[0]
        let transport = try #require(source.transports[first.id])
        #expect(transport.connectionRequests == 0)

        // Drive model transitions without depending on SwiftUI's private control
        // classes or accessibility internals. No operations reach real hardware.
        first.setEditing(true)
        first.setTemperature(3800)
        try await Task.sleep(for: .milliseconds(100))
        try expectPinned()
        first.setEditing(false)
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(40))
            try expectPinned()
        }
        try await eventually { first.isConnected && first.canControl }
        #expect(first.presentation == .verified)
        #expect(source.transports[model.lights[1].id]?.connectionRequests == 0)
        try expectPinned()

        // Repeated model-driven drags and different readout widths must neither
        // resize the window nor change its screen coordinates.
        first.setEditing(true)
        for temperature in stride(from: 2700.0, through: 6500.0, by: 100) {
            first.setTemperature(temperature)
            try await Task.sleep(for: .milliseconds(20))
            try expectPinned()
        }
        first.setEditing(false)
        try await eventually { first.canControl && first.presentation == .verified }
        try expectPinned()
        first.setEditing(true)
        for brightness in [0.0, 9, 10, 99, 100] {
            first.setBrightness(brightness)
            try await Task.sleep(for: .milliseconds(40))
            try expectPinned()
        }
        first.setEditing(false)
        try await eventually { first.canControl && first.presentation == .verified }
        try expectPinned()

        // A two-line error and last-known state occupy the same reserved slot.
        transport.ignoreSets = true
        first.setPower(false)
        try await eventually { first.canControl }
        #expect(first.presentation == .stale)
        #expect(first.failureMessage != nil)
        try await Task.sleep(for: .milliseconds(100))
        try expectPinned()

        panel.show(relativeTo: .zero, of: anchor)
        try expectPinned()

        // Only a new presentation can choose a larger viewport for two lights.
        panel.close()
        try await eventually { !panel.isShown }
        try await Task.sleep(for: .milliseconds(200))
        panel.show(relativeTo: anchor.bounds, of: anchor)
        try await Task.sleep(for: .milliseconds(350))
        #expect(panel.popover.contentSize == PanelLayout(lightCount: 2).size)
        let reopened = try #require(panel.popover.contentViewController?.view.window?.frame)
        source.publish([])
        try await Task.sleep(for: .milliseconds(100))
        #expect(panel.popover.contentViewController?.view.window?.frame == reopened)
        #expect(panel.popover.contentSize == PanelLayout(lightCount: 2).size)
        #expect(source.discoveryRequests.prefix(3).elementsEqual([true, false, true]))
    }
}
