import AppKit
import SwiftUI

@MainActor
final class LightPopover: NSObject, NSPopoverDelegate {
    let popover = NSPopover()
    private let model: LightsModel
    private let hosting: NSHostingController<ControlPanel>

    var isShown: Bool { popover.isShown }

    init(model: LightsModel) {
        self.model = model
        hosting = NSHostingController(rootView: ControlPanel(model: model, layout: PanelLayout(lightCount: 0)))
        super.init()
        // Automatic preferred-content sizing makes AppKit reposition the popover
        // whenever hints/readouts change. Only show(relativeTo:of:) may size it.
        hosting.sizingOptions = []
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.delegate = self
    }

    func show(relativeTo bounds: NSRect, of view: NSView) {
        guard !popover.isShown else { return }
        let layout = PanelLayout(lightCount: model.lights.count)
        hosting.rootView = ControlPanel(model: model, layout: layout)
        hosting.preferredContentSize = layout.size
        popover.contentSize = layout.size
        popover.show(relativeTo: bounds, of: view, preferredEdge: .minY)
        hosting.view.window?.makeKey()
    }

    func close() { popover.performClose(nil) }

    func popoverWillShow(_ notification: Notification) { model.setDiscoveryActive(true) }
    func popoverDidClose(_ notification: Notification) { model.setDiscoveryActive(false) }
}
