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

    func install(on window: NSWindow, tracking splitView: NSSplitView) {
        self.splitView = splitView
        let toolbar = NSToolbar(identifier: Self.identifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.defaultItemIdentifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.defaultItemIdentifiers
    }

    func toolbarNavigationalItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar]
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
                return NSToolbarItem(itemIdentifier: .sidebarTrackingSeparator)
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
}
