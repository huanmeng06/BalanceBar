import AppKit

/// Window-level NSToolbar owner for the Dashboard shell.
/// Supplies system sidebar items only; page actions stay out of the window controller.
final class DashboardToolbarController: NSObject, NSToolbarDelegate {
    static let identifier = NSToolbar.Identifier("BalanceBarDashboardToolbar")
    static let defaultItemIdentifiers: [NSToolbarItem.Identifier] = [
        .toggleSidebar,
        .sidebarTrackingSeparator
    ]

    private weak var splitView: NSSplitView?
    private var sidebarCollapseObservation: NSKeyValueObservation?

    func install(on window: NSWindow, tracking splitView: NSSplitView) {
        self.splitView = splitView
        let toolbar = NSToolbar(identifier: Self.identifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        configureToggleSidebar(in: toolbar)
        observeSidebarCollapse(in: window)
        syncTrackingSeparatorVisibility(in: window)
    }

    func toolbarWillAddItem(_ notification: Notification) {
        guard let item = notification.userInfo?[NSToolbarUserInfoKey.itemKey] as? NSToolbarItem else {
            return
        }
        configureToggleSidebar(item)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.defaultItemIdentifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.defaultItemIdentifiers
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .toggleSidebar:
            let item = NSToolbarItem(itemIdentifier: .toggleSidebar)
            item.action = #selector(NSSplitViewController.toggleSidebar(_:))
            item.target = nil
            return item
        case .sidebarTrackingSeparator:
            guard let splitView else {
                return nil
            }
            return NSTrackingSeparatorToolbarItem(
                identifier: .sidebarTrackingSeparator,
                splitView: splitView,
                dividerIndex: 0
            )
        default:
            return nil
        }
    }

    private func observeSidebarCollapse(in window: NSWindow) {
        guard let splitController = window.contentViewController as? NSSplitViewController,
              let sidebarItem = splitController.splitViewItems.first(where: { $0.behavior == .sidebar })
        else {
            sidebarCollapseObservation = nil
            return
        }
        sidebarCollapseObservation = sidebarItem.observe(\.isCollapsed, options: [.new]) { [weak self, weak window] _, _ in
            guard let self, let window else { return }
            self.syncTrackingSeparatorVisibility(in: window)
        }
    }

    private func syncTrackingSeparatorVisibility(in window: NSWindow) {
        guard let toolbar = window.toolbar else { return }
        let isCollapsed = (window.contentViewController as? NSSplitViewController)?
            .splitViewItems
            .first { $0.behavior == .sidebar }?
            .isCollapsed ?? false
        // When the full-height sidebar collapses, the tracking separator
        // moves into the leading cluster and shoves the system toggle away
        // from the traffic lights. Hide it while there is no divider to track.
        for item in toolbar.items where item.itemIdentifier == .sidebarTrackingSeparator {
            if #available(macOS 15.0, *) {
                item.isHidden = isCollapsed
            }
        }
        configureToggleSidebar(in: toolbar)
    }

    private func configureToggleSidebar(in toolbar: NSToolbar) {
        toolbar.items.forEach(configureToggleSidebar)
    }

    private func configureToggleSidebar(_ item: NSToolbarItem) {
        guard item.itemIdentifier == .toggleSidebar else { return }
        item.action = #selector(NSSplitViewController.toggleSidebar(_:))
        item.target = nil
    }
}
