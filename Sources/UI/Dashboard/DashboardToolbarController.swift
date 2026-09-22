import AppKit

/// The sole native toolbar owner. Search is a public `NSSearchToolbarItem`
/// (same class NetNewsWire installs in `MainWindowController`).
///
/// AppKit owns the item view (`view` is unavailable). Compact width uses
/// the documented search-field width constraint so AppKit shows its button
/// representation. Expanding updates that constraint to
/// `preferredWidthForSearchField` without flushing layout, then calls
/// `beginSearchInteraction()`, which the public header says expands to the
/// preferred width and moves keyboard focus — the same focus path
/// NetNewsWire uses with `makeFirstResponder`. Flushing layout or
/// recalculating the key view loop first makes the field jump to the
/// preferred width before AppKit can run its expand animation.
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
    /// Width AppKit uses for this item's button representation when the
    /// toolbar is space-constrained (macOS 26 SDK: 37 × 36).
    static let collapsedSearchFieldWidth: CGFloat = 37
    /// `NSSearchToolbarItem.preferredWidthForSearchField` defaults to 240, and
    /// the item's historical maxSize width is 325. Without a matching width
    /// constraint the field grows to that max. Use the public preferred-width
    /// hook, trimmed slightly for the content pane.
    static let expandedSearchFieldWidth: CGFloat = 220

    let sessionIdentifier = NSToolbar.Identifier("BalanceBarDashboardToolbar.\(UUID().uuidString)")
    private(set) var searchQuery = ""
    private(set) var isSearchExpanded = false
    var onSearchQueryChanged: ((String) -> Void)?

    private let searchItem: NSSearchToolbarItem
    private var searchFieldWidthConstraint: NSLayoutConstraint?
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
            applyPresentation()
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
        applyPresentation()
    }

    func setQuery(_ query: String) {
        if query.isEmpty {
            guard (searchItem.searchField.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            searchItem.searchField.stringValue = ""
            publishQuery("")
            setExpanded(false)
            return
        }
        setExpanded(true)
        let editor = searchItem.searchField.currentEditor() as? NSTextView
        if editor?.hasMarkedText() != true, searchItem.searchField.stringValue != query {
            searchItem.searchField.stringValue = query
        }
        publishQuery(query)
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
        searchFieldWidthConstraint?.isActive = false
        searchFieldWidthConstraint = nil
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

    func handleCollapsedSearchClick(_ event: NSEvent) -> Bool {
        guard !isSearchExpanded, event.window === window else { return false }
        let field = searchItem.searchField
        guard field.window != nil else { return false }
        let fieldInWindow = field.convert(field.bounds, to: nil)
        guard fieldInWindow.contains(event.locationInWindow) else { return false }
        beginSearch()
        return true
    }

    @objc func beginSearch(_ sender: Any? = nil) {
        isSearchExpanded = true
        prepareForSystemSearchInteraction(expanded: true, flushLayout: shouldFlushSearchLayout)
        guard searchItem.searchField.window === window else { return }
        searchItem.beginSearchInteraction()
        if shouldFlushSearchLayout || hostsSearchResponder(window?.firstResponder) != true {
            _ = window?.makeFirstResponder(searchItem.searchField)
        }
        finishSystemSearchPresentation()
    }

    @objc func endSearch(_ sender: Any? = nil) {
        guard !isEndingSearch else { return }
        isEndingSearch = true
        searchItem.searchField.stringValue = ""
        publishQuery("")
        isSearchExpanded = false
        prepareForSystemSearchInteraction(expanded: false, flushLayout: shouldFlushSearchLayout)
        searchItem.endSearchInteraction()
        finishSystemSearchPresentation()
        isEndingSearch = false
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

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField,
              (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        publishQuery(field.stringValue)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard !isEndingSearch, let field = obj.object as? NSSearchField else { return }
        if (window as? DashboardSearchWindow)?.preservesToolbarSearchEditing == true {
            return
        }
        publishQuery(field.stringValue)
        collapseAfterEditing(field)
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        guard !isEndingSearch,
              (sender.currentEditor() as? NSTextView)?.hasMarkedText() != true,
              (window as? DashboardSearchWindow)?.preservesToolbarSearchEditing != true else { return }
        publishQuery(sender.stringValue)
        if sender.stringValue.isEmpty {
            DispatchQueue.main.async { [weak self] in self?.endSearch() }
        } else {
            collapseAfterEditing(sender)
        }
    }

    func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
        (window as? DashboardSearchWindow)?.preservesToolbarSearchEditing != true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)),
              !textView.hasMarkedText() else { return false }
        endSearch(nil)
        return true
    }

    private func configureSearchItem() {
        updateSearchItemLabels()
        searchItem.resignsFirstResponderWithCancel = true
        searchItem.preferredWidthForSearchField = Self.expandedSearchFieldWidth
        searchItem.searchField.sendsSearchStringImmediately = true
        searchItem.searchField.sendsWholeSearchString = false
        searchItem.searchField.delegate = self
        if (searchItem.searchField.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            searchItem.searchField.stringValue = searchQuery
        }
    }

    private func updateSearchItemLabels() {
        let label = tr(.keyDashboardSearchPlaceholder)
        searchItem.label = label
        searchItem.paletteLabel = label
        searchItem.toolTip = label
        searchItem.searchField.placeholderString = label
    }

    /// Tests and Reduce Motion apply the width immediately. Interactive
    /// expand/collapse leaves layout pending so `beginSearchInteraction`
    /// / `endSearchInteraction` can run AppKit's expand animation.
    private var shouldFlushSearchLayout: Bool {
        AutomatedTestHost.isRunning
            || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func setExpanded(_ expanded: Bool) {
        guard expanded != isSearchExpanded else {
            applyPresentation()
            return
        }
        isSearchExpanded = expanded
        applyPresentation()
        window?.recalculateKeyViewLoop()
    }

    private func applyPresentation(flushLayout: Bool = true) {
        searchItem.preferredWidthForSearchField = Self.expandedSearchFieldWidth
        ensureSearchFieldWidthConstraint()
        if isSearchExpanded {
            pinExpandedSearchFieldWidth()
        } else {
            searchFieldWidthConstraint?.constant = Self.collapsedSearchFieldWidth
            searchFieldWidthConstraint?.isActive = true
        }
        if flushLayout {
            searchItem.searchField.window?.layoutIfNeeded()
        }
    }

    /// Keep the documented field width constraint aligned with the public
    /// preferred width. Do not deactivate it on expand: without it the
    /// item grows to the historical max size (325). Do not flush layout
    /// before `beginSearchInteraction`; that jumps to the destination
    /// width and leaves AppKit nothing to animate.
    private func prepareForSystemSearchInteraction(expanded: Bool, flushLayout: Bool) {
        searchItem.preferredWidthForSearchField = Self.expandedSearchFieldWidth
        ensureSearchFieldWidthConstraint()
        searchFieldWidthConstraint?.constant = expanded
            ? Self.expandedSearchFieldWidth
            : Self.collapsedSearchFieldWidth
        searchFieldWidthConstraint?.isActive = true
        if flushLayout {
            searchItem.searchField.window?.layoutIfNeeded()
        }
    }

    private func finishSystemSearchPresentation() {
        guard shouldFlushSearchLayout else { return }
        let editor = searchItem.searchField.currentEditor() as? NSTextView
        if isSearchExpanded, editor?.hasMarkedText() != true {
            searchItem.searchField.selectText(nil)
        }
        searchItem.searchField.window?.layoutIfNeeded()
        window?.recalculateKeyViewLoop()
    }

    private func ensureSearchFieldWidthConstraint() {
        let field = searchItem.searchField
        if searchFieldWidthConstraint == nil {
            searchFieldWidthConstraint = field.widthAnchor.constraint(
                equalToConstant: Self.collapsedSearchFieldWidth
            )
        }
    }

    private func pinExpandedSearchFieldWidth() {
        guard isSearchExpanded else { return }
        ensureSearchFieldWidthConstraint()
        searchFieldWidthConstraint?.constant = Self.expandedSearchFieldWidth
        searchFieldWidthConstraint?.isActive = true
    }

    private func collapseAfterEditing(_ field: NSSearchField) {
        DispatchQueue.main.async { [weak self, weak field] in
            guard let self, self.searchQuery.isEmpty,
                  field?.currentEditor() == nil else { return }
            self.isSearchExpanded = false
            self.prepareForSystemSearchInteraction(
                expanded: false,
                flushLayout: self.shouldFlushSearchLayout
            )
            self.searchItem.endSearchInteraction()
            self.finishSystemSearchPresentation()
        }
    }

    private func publishQuery(_ raw: String) {
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

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown,
           searchController?.handleCollapsedSearchClick(event) == true {
            return
        }
        super.sendEvent(event)
    }

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
        } else if let searchController, searchController.isSearchExpanded {
            searchController.endSearch(sender)
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
