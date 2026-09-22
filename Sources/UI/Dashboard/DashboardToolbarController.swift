import AppKit

/// The sole native toolbar owner. AppKit keeps one trailing search identifier.
///
/// `NSSearchToolbarItem.endSearchInteraction()` only restores natural width in a
/// wide window, inserting/removing that item crashes AppKit, and assigning its
/// hosted `searchField` to another item leaves the field in a null window.
/// This slot keeps one public `NSToolbarItem` whose stable host view shows
/// either a circular button or a public `NSSearchField`.
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

    // AppKit synchronizes item mutations between toolbars with equal IDs even
    // when autosaving is off. Search presentation belongs to this session only.
    let sessionIdentifier = NSToolbar.Identifier("BalanceBarDashboardToolbar.\(UUID().uuidString)")
    private(set) var searchQuery = ""
    private(set) var isSearchExpanded = false
    var onSearchQueryChanged: ((String) -> Void)?

    private let slotView = DashboardSearchSlotView()
    private let searchField = NSSearchField()
    private let collapsedButton: NSButton
    private var slotItem: NSToolbarItem?
    private weak var window: NSWindow?
    private weak var toolbar: NSToolbar?
    private var isEndingSearch = false

    override init() {
        let label = tr(.keyDashboardSearchPlaceholder)
        collapsedButton = NSButton(
            image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: label) ?? NSImage(),
            target: nil,
            action: #selector(searchButtonClicked(_:))
        )
        super.init()
        collapsedButton.target = self
        collapsedButton.bezelStyle = .circular
        collapsedButton.isBordered = true
        collapsedButton.imagePosition = .imageOnly
        collapsedButton.setButtonType(.momentaryPushIn)
        collapsedButton.sizeToFit()
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.delegate = self
        slotView.addSubview(collapsedButton)
        slotView.addSubview(searchField)
        applyPresentation()
        updateLabels()
    }

    func install(on window: NSWindow) {
        window.isReleasedWhenClosed = false
        self.window = window
        (window as? DashboardSearchWindow)?.searchController = self
        // Rebuilding the page shell must not detach the active field editor,
        // discard marked text, or reset an empty-but-focused search.
        if let toolbar, window.toolbar === toolbar {
            updateLabels()
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
    }

    func setQuery(_ query: String) {
        if query.isEmpty {
            guard (searchField.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            searchField.stringValue = ""
            publishQuery("")
            setExpanded(false)
            return
        }
        setExpanded(true)
        let editor = searchField.currentEditor() as? NSTextView
        if editor?.hasMarkedText() != true, searchField.stringValue != query {
            searchField.stringValue = query
        }
        publishQuery(query)
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
        slotItem?.view = nil
        slotItem = nil
        toolbar = nil
        window = nil
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

    @objc private func searchButtonClicked(_ sender: Any?) {
        DispatchQueue.main.async { [weak self] in self?.beginSearch() }
    }

    @objc func beginSearch(_ sender: Any? = nil) {
        setExpanded(true)
        guard searchField.window === window else { return }
        _ = window?.makeFirstResponder(searchField)
        let editor = searchField.currentEditor() as? NSTextView
        if editor?.hasMarkedText() != true {
            searchField.selectText(nil)
        }
    }

    @objc func endSearch(_ sender: Any? = nil) {
        guard !isEndingSearch else { return }
        isEndingSearch = true
        searchField.stringValue = ""
        publishQuery("")
        _ = searchField.abortEditing()
        window?.endEditing(for: searchField)
        setExpanded(false)
        restoreCollapsedFocus()
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
        if slotItem == nil {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = slotView
            slotItem = item
        }
        applyPresentation()
        updateLabels()
        return slotItem
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

    private func setExpanded(_ expanded: Bool) {
        guard expanded != isSearchExpanded else { return }
        isSearchExpanded = expanded
        applyPresentation()
        window?.recalculateKeyViewLoop()
    }

    private func applyPresentation() {
        collapsedButton.sizeToFit()
        let buttonSize = collapsedButton.fittingSize
        if isSearchExpanded {
            slotView.preferredSize = NSSize(
                width: 220,
                height: max(searchField.fittingSize.height, 22)
            )
        } else {
            slotView.preferredSize = NSSize(
                width: min(max(buttonSize.width, 24), 36),
                height: min(max(buttonSize.height, 24), 36)
            )
        }
        collapsedButton.isHidden = isSearchExpanded
        searchField.isHidden = !isSearchExpanded
        collapsedButton.refusesFirstResponder = isSearchExpanded
        searchField.refusesFirstResponder = !isSearchExpanded
        collapsedButton.setAccessibilityElement(!isSearchExpanded)
        searchField.setAccessibilityElement(isSearchExpanded)
        slotView.layoutContent(
            expanded: isSearchExpanded,
            buttonSize: buttonSize
        )
    }

    private func restoreCollapsedFocus() {
        guard let window else { return }
        if collapsedButton.window === window, !collapsedButton.isHidden {
            window.makeFirstResponder(collapsedButton)
        } else if window.firstResponder === searchField
            || (window.firstResponder as? NSTextView)?.delegate as AnyObject? === searchField {
            window.makeFirstResponder(nil)
        }
    }

    private func collapseAfterEditing(_ field: NSSearchField) {
        DispatchQueue.main.async { [weak self, weak field] in
            guard let self, self.searchQuery.isEmpty,
                  field?.currentEditor() == nil else { return }
            self.setExpanded(false)
            if let window = self.window, window.firstResponder === window {
                self.restoreCollapsedFocus()
            }
        }
    }

    private func updateLabels() {
        let label = tr(.keyDashboardSearchPlaceholder)
        let item = slotItem
        item?.label = label
        item?.paletteLabel = label
        item?.toolTip = label
        collapsedButton.setAccessibilityLabel(label)
        collapsedButton.toolTip = label
        searchField.placeholderString = label
        searchField.setAccessibilityLabel(label)
    }

    private func publishQuery(_ raw: String) {
        guard raw != searchQuery else { return }
        searchQuery = raw
        onSearchQueryChanged?(searchQuery)
    }
}

/// Auto Layout-free host that stays assigned to the single search toolbar item.
private final class DashboardSearchSlotView: NSView {
    var preferredSize = NSSize(width: 28, height: 28) {
        didSet { invalidateIntrinsicContentSize() }
    }

    override var intrinsicContentSize: NSSize { preferredSize }

    func layoutContent(expanded: Bool, buttonSize: NSSize) {
        frame.size = preferredSize
        for subview in subviews {
            if subview is NSSearchField {
                subview.frame = expanded ? bounds : .zero
            } else {
                subview.frame = NSRect(
                    x: (bounds.width - buttonSize.width) / 2,
                    y: (bounds.height - buttonSize.height) / 2,
                    width: buttonSize.width,
                    height: buttonSize.height
                )
            }
        }
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
