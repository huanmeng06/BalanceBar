import AppKit

/// The sole native toolbar owner. Search is a public `NSSearchToolbarItem`
/// (same class NetNewsWire installs in `MainWindowController`).
///
/// AppKit owns the item view (`view` is unavailable), compact/expanded
/// representation, keyboard focus, and transition. This controller only
/// configures the public item, forwards Cmd+F / Esc to
/// `beginSearchInteraction()` / `endSearchInteraction()`, keeps draft text
/// separate from the committed query, and submits through Return/search.
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
    /// `NSSearchToolbarItem.preferredWidthForSearchField` defaults to 240.
    /// Trimmed slightly for the content pane; AppKit applies it when the
    /// item receives keyboard focus.
    static let expandedSearchFieldWidth: CGFloat = 220

    let sessionIdentifier = NSToolbar.Identifier("BalanceBarDashboardToolbar.\(UUID().uuidString)")
    private(set) var searchQuery = ""
    private(set) var draftQuery = ""
    private(set) var isSearchEditing = false
    var onSearchQueryChanged: ((String) -> Void)?

    var isSearchActive: Bool {
        isSearchEditing || !draftQuery.isEmpty || !searchQuery.isEmpty
    }

    private let searchItem: NSSearchToolbarItem
    private weak var window: NSWindow?
    private weak var toolbar: NSToolbar?
    private var isEndingSearch = false

    override init() {
        searchItem = NSSearchToolbarItem(itemIdentifier: Self.searchItemIdentifier)
        super.init()
        configureSearchItem()
    }

    func install(on window: NSWindow) {
        window.isReleasedWhenClosed = false
        self.window = window
        (window as? DashboardSearchWindow)?.searchController = self
        if let toolbar, window.toolbar === toolbar {
            updateSearchItemLabels()
            return
        }
        let toolbar = NSToolbar(identifier: sessionIdentifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        self.toolbar = toolbar
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        _ = window.toolbar?.items
        window.layoutIfNeeded()
    }

    func setQuery(_ query: String) {
        guard (searchItem.searchField.currentEditor() as? NSTextView)?.hasMarkedText() != true else {
            return
        }
        draftQuery = query
        if searchItem.searchField.stringValue != query {
            searchItem.searchField.stringValue = query
        }
        commitQuery(query)
    }

    func detach() {
        searchItem.searchField.delegate = nil
        if let window {
            _ = searchItem.searchField.abortEditing()
            window.endEditing(for: searchItem.searchField)
            window.makeFirstResponder(nil)
        }
        if window?.toolbar === toolbar {
            window?.toolbar = nil
        }
        (window as? DashboardSearchWindow)?.searchController = nil
        isSearchEditing = false
        toolbar = nil
        window = nil
    }

    func hostsSearchResponder(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        if responder === searchItem.searchField { return true }
        if let textView = responder as? NSTextView,
           textView.isFieldEditor,
           textView.delegate as AnyObject? === searchItem.searchField {
            return true
        }
        return false
    }

    @objc func beginSearch(_ sender: Any? = nil) {
        if toolbar?.isVisible == false {
            toolbar?.isVisible = true
        }
        searchItem.beginSearchInteraction()
    }

    @objc func cancelSearch(_ sender: Any? = nil) {
        guard !isEndingSearch else { return }
        isEndingSearch = true
        defer { isEndingSearch = false }
        draftQuery = ""
        searchItem.searchField.stringValue = ""
        commitQuery("")
        searchItem.endSearchInteraction()
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
        guard itemIdentifier == Self.searchItemIdentifier else { return nil }
        configureSearchItem()
        return searchItem
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        isSearchEditing = true
        if let field = obj.object as? NSSearchField {
            draftQuery = field.stringValue
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField,
              (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        draftQuery = field.stringValue
        // The accepted query is updated with every non-marked editor change.
        // The composition layer may coalesce the expensive projection, but
        // every owner observes one current query value during page changes.
        commitQuery(draftQuery)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if (window as? DashboardSearchWindow)?.preservesToolbarSearchEditing == true {
            return
        }
        isSearchEditing = false
        guard !isEndingSearch, let field = obj.object as? NSSearchField else { return }
        draftQuery = field.stringValue
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        guard !isEndingSearch,
              (sender.currentEditor() as? NSTextView)?.hasMarkedText() != true,
              (window as? DashboardSearchWindow)?.preservesToolbarSearchEditing != true else { return }
        draftQuery = sender.stringValue
        commitQuery(draftQuery)
    }

    func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
        (window as? DashboardSearchWindow)?.preservesToolbarSearchEditing != true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)),
              !textView.hasMarkedText() else { return false }
        cancelSearch(nil)
        return true
    }

    @objc private func submitSearch(_ sender: NSSearchField) {
        guard (sender.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        draftQuery = sender.stringValue
        commitQuery(draftQuery)
    }

    private func configureSearchItem() {
        updateSearchItemLabels()
        searchItem.preferredWidthForSearchField = Self.expandedSearchFieldWidth
        searchItem.resignsFirstResponderWithCancel = true
        searchItem.searchField.sendsSearchStringImmediately = false
        searchItem.searchField.sendsWholeSearchString = true
        searchItem.searchField.target = self
        searchItem.searchField.action = #selector(submitSearch(_:))
        searchItem.searchField.delegate = self
        if (searchItem.searchField.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            searchItem.searchField.stringValue = draftQuery
        }
    }

    private func updateSearchItemLabels() {
        let label = tr(.keyDashboardSearchPlaceholder)
        searchItem.label = label
        searchItem.paletteLabel = label
        searchItem.toolTip = label
        searchItem.searchField.placeholderString = label
    }

    private func commitQuery(_ raw: String) {
        guard raw != searchQuery else { return }
        searchQuery = raw
        onSearchQueryChanged?(searchQuery)
    }
}

/// Window-scoped shortcut without a global event monitor or menu dependency.
final class DashboardSearchWindow: NSWindow {
    weak var searchController: DashboardToolbarController?
    /// AppKit ends window editing when replacing `contentViewController`.
    /// Toolbar search lives outside that view, so a shell rebuild must keep
    /// the same field editor and any marked text.
    var preservesToolbarSearchEditing = false

    override func endEditing(for object: Any?) {
        if preservesToolbarSearchEditing, searchController?.hostsSearchResponder(firstResponder) == true {
            return
        }
        super.endEditing(for: object)
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if preservesToolbarSearchEditing,
           searchController?.hostsSearchResponder(firstResponder) == true,
           searchController?.hostsSearchResponder(responder) != true {
            return true
        }
        return super.makeFirstResponder(responder)
    }

    override func cancelOperation(_ sender: Any?) {
        if let editor = firstResponder as? NSTextView, editor.hasMarkedText() {
            super.cancelOperation(sender)
        } else if let searchController,
                  searchController.isSearchActive || searchController.hostsSearchResponder(firstResponder) {
            searchController.cancelSearch(sender)
        } else {
            super.cancelOperation(sender)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad]) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "f",
           let searchController {
            searchController.beginSearch(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
