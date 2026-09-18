import AppKit

/// Window-level NSToolbar owner for the Dashboard shell.
/// Sidebar system items stay before the tracking separator; the content-pane
/// search item is a public NSSearchToolbarItem after it.
final class DashboardToolbarController: NSObject, NSToolbarDelegate, NSSearchFieldDelegate {
    static let identifier = NSToolbar.Identifier("BalanceBarDashboardToolbar")
    static let searchItemIdentifier = NSToolbarItem.Identifier("BalanceBarDashboardSearch")
    static let defaultItemIdentifiers: [NSToolbarItem.Identifier] = [
        .flexibleSpace,
        .toggleSidebar,
        .sidebarTrackingSeparator,
        .flexibleSpace,
        searchItemIdentifier
    ]

    private(set) var searchQuery = ""
    var onSearchQueryChanged: ((String) -> Void)?
    private var searchItem: NSSearchToolbarItem?

    func install(on window: NSWindow) {
        let toolbar = NSToolbar(identifier: Self.identifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        restoreSearchFieldText()
    }

    func setQuery(_ query: String) {
        guard query != searchQuery else {
            restoreSearchFieldText()
            return
        }
        searchQuery = query
        restoreSearchFieldText()
        onSearchQueryChanged?(searchQuery)
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
        guard itemIdentifier == Self.searchItemIdentifier else {
            return nil
        }
        let item = searchItem ?? NSSearchToolbarItem(itemIdentifier: itemIdentifier)
        configureSearchItem(item)
        searchItem = item
        return item
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField else { return }
        publishQuery(field.stringValue)
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        publishQuery(sender.stringValue)
    }

    private func configureSearchItem(_ item: NSSearchToolbarItem) {
        let placeholder = tr(.keyDashboardSearchPlaceholder)
        item.label = placeholder
        item.paletteLabel = placeholder
        item.toolTip = placeholder
        item.resignsFirstResponderWithCancel = true
        item.searchField.placeholderString = placeholder
        item.searchField.sendsSearchStringImmediately = true
        item.searchField.sendsWholeSearchString = false
        item.searchField.delegate = self
        item.searchField.stringValue = searchQuery
    }

    private func restoreSearchFieldText() {
        searchItem?.searchField.stringValue = searchQuery
        searchItem?.searchField.placeholderString = tr(.keyDashboardSearchPlaceholder)
    }

    private func publishQuery(_ raw: String) {
        guard raw != searchQuery else { return }
        searchQuery = raw
        onSearchQueryChanged?(searchQuery)
    }
}
