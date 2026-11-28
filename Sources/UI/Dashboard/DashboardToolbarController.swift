import AppKit

/// Owns the native toolbar and the persistent sidebar search field.
final class DashboardToolbarController: NSObject, NSToolbarDelegate, NSSearchFieldDelegate {
    static let identifier = NSToolbar.Identifier("BalanceBarDashboardToolbar")
    static let navigationItemIdentifier = NSToolbarItem.Identifier("BalanceBarDashboardNavigation")
    static let defaultItemIdentifiers: [NSToolbarItem.Identifier] = [
        .flexibleSpace,
        .toggleSidebar,
        .sidebarTrackingSeparator,
        navigationItemIdentifier
    ]

    let sessionIdentifier = NSToolbar.Identifier("BalanceBarDashboardToolbar.\(UUID().uuidString)")
    private(set) var searchQuery = ""
    private(set) var draftQuery = ""
    private(set) var isSearchEditing = false
    var onSearchQueryChanged: ((String) -> Void)?
    var onRevealSearch: (() -> Void)?
    var onManualRefresh: (() -> Void)?
    var onGoBack: (() -> Void)?
    var onGoForward: (() -> Void)?

    var isSearchActive: Bool {
        isSearchEditing || !draftQuery.isEmpty || !searchQuery.isEmpty
    }

    private static let searchTopInset: CGFloat = 9.5
    private static let searchToListSpacing: CGFloat = 10

    let searchField = NSSearchField()
    private(set) lazy var sidebarSearchView: NSView = {
        let container = NSView()
        searchField.translatesAutoresizingMaskIntoConstraints = false
        // The native accessory and the legacy sidebar both place this header
        // below the title bar. Inset within that header on both paths.
        container.addSubview(searchField)
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.searchTopInset),
            searchField.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.searchToListSpacing)
        ])
        return container
    }()
    private lazy var navigationControl: NSSegmentedControl = {
        let control = NSSegmentedControl(
            images: [
                NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: nil)
                    ?? NSImage(size: NSSize(width: 16, height: 16)),
                NSImage(systemSymbolName: "chevron.forward", accessibilityDescription: nil)
                    ?? NSImage(size: NSSize(width: 16, height: 16))
            ],
            trackingMode: .momentary,
            target: self,
            action: #selector(navigationSegmentPressed(_:))
        )
        control.translatesAutoresizingMaskIntoConstraints = false
        control.setEnabled(canGoBack, forSegment: 0)
        control.setEnabled(canGoForward, forSegment: 1)
        return control
    }()
    private lazy var navigationItem: NSToolbarItem = {
        let item = NSToolbarItem(itemIdentifier: Self.navigationItemIdentifier)
        item.view = navigationControl
        item.isNavigational = true
        item.autovalidates = false
        return item
    }()
    private weak var window: NSWindow?
    private weak var toolbar: NSToolbar?
    private var isEndingSearch = false
    private var canGoBack = false
    private var canGoForward = false

    override init() {
        super.init()
        updateSearchFieldLabels()
        searchField.controlSize = .large
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = true
        searchField.target = self
        searchField.action = #selector(submitSearch(_:))
        searchField.delegate = self
    }

    func install(on window: NSWindow) {
        window.isReleasedWhenClosed = false
        self.window = window
        (window as? DashboardSearchWindow)?.searchController = self
        if let toolbar, window.toolbar === toolbar {
            updateNavigationItemLabels()
            setNavigationState(canGoBack: canGoBack, canGoForward: canGoForward)
            updateSearchFieldLabels()
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

    /// Updates only the existing native navigation items. The toolbar and its
    /// item collection remain AppKit-owned so search editing and marked text
    /// are unaffected by page navigation.
    func setNavigationState(canGoBack: Bool, canGoForward: Bool) {
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        navigationItem.autovalidates = false
        navigationControl.setEnabled(canGoBack, forSegment: 0)
        navigationControl.setEnabled(canGoForward, forSegment: 1)
    }

    func setQuery(_ query: String) {
        guard (searchField.currentEditor() as? NSTextView)?.hasMarkedText() != true else {
            return
        }
        draftQuery = query
        if searchField.stringValue != query {
            searchField.stringValue = query
        }
        commitQuery(query)
    }

    func detach() {
        searchField.delegate = nil
        if let window {
            _ = searchField.abortEditing()
            window.endEditing(for: searchField)
            window.makeFirstResponder(nil)
        }
        if window?.toolbar === toolbar {
            window?.toolbar = nil
        }
        (window as? DashboardSearchWindow)?.searchController = nil
        isSearchEditing = false
        toolbar = nil
        window = nil
        canGoBack = false
        canGoForward = false
        navigationControl.setEnabled(false, forSegment: 0)
        navigationControl.setEnabled(false, forSegment: 1)
        onRevealSearch = nil
        onGoBack = nil
        onGoForward = nil
    }

    func hostsSearchResponder(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        if responder === searchField { return true }
        if let textView = responder as? NSTextView,
           textView.isFieldEditor,
           textView.delegate as AnyObject? === searchField {
            return true
        }
        return false
    }

    @objc func beginSearch(_ sender: Any? = nil) {
        onRevealSearch?()
        window?.makeFirstResponder(searchField)
    }

    @objc func cancelSearch(_ sender: Any? = nil) {
        guard !isEndingSearch else { return }
        isEndingSearch = true
        defer { isEndingSearch = false }
        draftQuery = ""
        searchField.stringValue = ""
        commitQuery("")
        if let window, hostsSearchResponder(window.firstResponder) {
            _ = searchField.abortEditing()
            window.makeFirstResponder(nil)
        }
        isSearchEditing = false
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
        guard itemIdentifier == Self.navigationItemIdentifier else { return nil }
        updateNavigationItemLabels()
        return navigationItem
    }

    @objc func manualRefresh(_ sender: Any?) {
        onManualRefresh?()
    }

    @objc func goBack(_ sender: Any?) {
        guard canGoBack else { return }
        onGoBack?()
    }

    @objc func goForward(_ sender: Any?) {
        guard canGoForward else { return }
        onGoForward?()
    }

    @objc private func navigationSegmentPressed(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0:
            goBack(sender)
        case 1:
            goForward(sender)
        default:
            break
        }
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
        if (window as? DashboardSearchWindow)?.preservesSidebarSearchEditing == true {
            return
        }
        isSearchEditing = false
        guard !isEndingSearch, let field = obj.object as? NSSearchField else { return }
        draftQuery = field.stringValue
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        guard !isEndingSearch,
              (sender.currentEditor() as? NSTextView)?.hasMarkedText() != true,
              (window as? DashboardSearchWindow)?.preservesSidebarSearchEditing != true else { return }
        draftQuery = sender.stringValue
        commitQuery(draftQuery)
    }

    func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
        (window as? DashboardSearchWindow)?.preservesSidebarSearchEditing != true
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

    private func updateSearchFieldLabels() {
        let label = tr(.keyDashboardSearchPlaceholder)
        searchField.placeholderString = label
        searchField.setAccessibilityLabel(label)
    }

    private func updateNavigationItemLabels() {
        let backLabel = tr(.keyDashboardNavigationBack)
        let forwardLabel = tr(.keyDashboardNavigationForward)
        navigationControl.setLabel("", forSegment: 0)
        navigationControl.setLabel("", forSegment: 1)
        navigationControl.setToolTip(backLabel, forSegment: 0)
        navigationControl.setToolTip(forwardLabel, forSegment: 1)
        navigationControl.setImage(
            NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: backLabel),
            forSegment: 0
        )
        navigationControl.setImage(
            NSImage(systemSymbolName: "chevron.forward", accessibilityDescription: forwardLabel),
            forSegment: 1
        )
        navigationItem.label = "\(backLabel) / \(forwardLabel)"
        navigationItem.paletteLabel = navigationItem.label
        navigationItem.toolTip = navigationItem.label
        navigationItem.isNavigational = true
        navigationItem.autovalidates = false
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
    /// A shell rebuild can change page and sidebar selection. Keep the live
    /// sidebar field editor and its marked text through those changes.
    var preservesSidebarSearchEditing = false

    override func endEditing(for object: Any?) {
        if preservesSidebarSearchEditing, searchController?.hostsSearchResponder(firstResponder) == true {
            return
        }
        super.endEditing(for: object)
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if preservesSidebarSearchEditing,
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
           let searchController {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "f":
                searchController.beginSearch(nil)
                return true
            case "r":
                searchController.manualRefresh(nil)
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
