import AppKit

/// Shows the real-time boost explanation panel in a popover anchored to the status item button.
final class ModOnboardingPopoverPresenter: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?

    var isShown: Bool { popover?.isShown == true }

    func present(panel: ModOnboardingPanelView, relativeTo anchor: NSView) {
        popover?.close()
        let content = NSViewController()
        content.view = panel
        content.preferredContentSize = panel.fittingSize
        let popover = NSPopover()
        popover.contentViewController = content
        popover.behavior = .transient
        popover.delegate = self
        panel.onRequestClose = { [weak popover] in popover?.close() }
        // Each state of the panel has its own height.
        panel.onContentSizeChange = { [weak content] size in content?.preferredContentSize = size }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        self.popover = popover
    }

    func close() { popover?.close() }

    func popoverDidClose(_ notification: Notification) {
        popover = nil
    }
}
