import AppKit

/// Window-level NSToolbar owner for the Dashboard shell.
/// Supplies system sidebar item identifiers only; layout stays AppKit's job.
final class DashboardToolbarController: NSObject, NSToolbarDelegate {
    static let identifier = NSToolbar.Identifier("BalanceBarDashboardToolbar")
    static let defaultItemIdentifiers: [NSToolbarItem.Identifier] = [
        .flexibleSpace,
        .toggleSidebar,
        .sidebarTrackingSeparator
    ]

    func install(on window: NSWindow) {
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

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        // Standard identifiers are provided by AppKit from the default item list.
        nil
    }
}
