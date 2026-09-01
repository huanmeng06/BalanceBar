import AppKit

/// A native, fixed-height editor for the user-configured status links.
///
/// The table owns the editing lifecycle. Its model is updated when an edit
/// ends, rather than for every keystroke, so the preferences and status menu
/// only receive complete link arrays at meaningful interaction boundaries.
final class StatusLinksEditorView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    static let nameColumnIdentifier = NSUserInterfaceItemIdentifier("statusLinks.name")
    static let urlColumnIdentifier = NSUserInterfaceItemIdentifier("statusLinks.url")
    static let tableIdentifier = NSUserInterfaceItemIdentifier("statusLinks.table")
    static let scrollViewIdentifier = NSUserInterfaceItemIdentifier("statusLinks.scrollView")
    static let addButtonIdentifier = NSUserInterfaceItemIdentifier("statusLinks.add")
    static let removeButtonIdentifier = NSUserInterfaceItemIdentifier("statusLinks.remove")
    static let resetButtonIdentifier = NSUserInterfaceItemIdentifier("statusLinks.reset")

    static let fixedHeight: CGFloat = 204
    private static let nameCellIdentifier = NSUserInterfaceItemIdentifier("statusLinks.cell.name")
    private static let urlCellIdentifier = NSUserInterfaceItemIdentifier("statusLinks.cell.url")
    private static let statusLinkPasteboardType = NSPasteboard.PasteboardType(
        "com.huanmeng06.BalanceBar.status-link-row"
    )

    private enum Field: Equatable {
        case title
        case url
    }

    private final class StatusLinkTableCellView: NSTableCellView {
        let editor = NSTextField()
        var row = 0
        var field: Field = .title

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)

            editor.translatesAutoresizingMaskIntoConstraints = false
            editor.isEditable = true
            editor.isSelectable = true
            editor.isBordered = false
            editor.drawsBackground = false
            editor.focusRingType = .default
            editor.usesSingleLineMode = true
            editor.lineBreakMode = .byTruncatingTail

            textField = editor
            addSubview(editor)
            NSLayoutConstraint.activate([
                editor.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
                editor.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
                editor.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }

    private(set) var links: [StatusLink]
    private let onLinksChanged: ([StatusLink]) -> Void
    private let onReset: () -> [StatusLink]

    private let listContainer = NSBox()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let horizontalSeparator = NSBox()
    private let footerView = NSStackView()
    private let verticalSeparator = NSBox()
    private let addButton = NSButton()
    private let removeButton = NSButton()
    private let resetButton = NSButton()
    private var heightConstraint: NSLayoutConstraint!
    private var windowCloseObserver: NSObjectProtocol?
    private var isEndingEditing = false
    private var isVisibleState = true
    private(set) var isTornDown = false

    // These read-only seams keep focused XCTest assertions on the native
    // controls without exposing mutable implementation state to callers.
    var tableColumnCount: Int { tableView.tableColumns.count }
    var tableColumnIdentifiers: [NSUserInterfaceItemIdentifier] {
        tableView.tableColumns.map(\.identifier)
    }
    var tableViewForTesting: NSTableView { tableView }
    var scrollViewForTesting: NSScrollView { scrollView }
    var addButtonForTesting: NSButton { addButton }
    var removeButtonForTesting: NSButton { removeButton }
    var resetButtonForTesting: NSButton { resetButton }
    var listContainerForTesting: NSBox { listContainer }
    var footerViewForTesting: NSStackView { footerView }
    var horizontalSeparatorForTesting: NSBox { horizontalSeparator }
    var verticalSeparatorForTesting: NSBox { verticalSeparator }
    var isEditingNameForTesting: Bool {
        editingCell?.field == .title
    }

    var rowCount: Int { links.count }
    var layoutHeight: CGFloat { Self.fixedHeight }
    var currentHeight: CGFloat { max(0, heightConstraint?.constant ?? (isVisibleState ? Self.fixedHeight : 0)) }
    var isVisible: Bool { isVisibleState && currentHeight > 0 && alphaValue > 0 }

    init(
        links: [StatusLink],
        onLinksChanged: @escaping ([StatusLink]) -> Void,
        onReset: @escaping () -> [StatusLink]
    ) {
        self.links = links
        self.onLinksChanged = onLinksChanged
        self.onReset = onReset
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = true
        configureTable()
        configureControls()
        installConstraints()
        updateRemoveButtonState()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: currentHeight)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
            self.windowCloseObserver = nil
        }
        guard let window else { return }
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self, let field = self.editingCell else { return }
            self.commit(field)
        }
    }

    override func layout() {
        super.layout()
        updateTableFrame()
        tableView.sizeLastColumnToFit()
    }

    func setVisible(_ visible: Bool, animated: Bool) {
        guard !isTornDown else { return }
        isVisibleState = visible
        let targetHeight = visible ? Self.fixedHeight : 0
        invalidateEditorLayout()

        guard animated else {
            alphaValue = visible ? 1 : 0
            heightConstraint.constant = targetHeight
            invalidateEditorLayout()
            return
        }

        if visible {
            alphaValue = 0
            heightConstraint.constant = targetHeight
            invalidateEditorLayout()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.animator().alphaValue = 1
            }
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().alphaValue = 0
            self.heightConstraint.animator().constant = targetHeight
        } completionHandler: { [weak self] in
            guard let self, !self.isTornDown, !self.isVisibleState else { return }
            self.alphaValue = 0
            self.heightConstraint.constant = targetHeight
            self.invalidateEditorLayout()
        }
    }

    func updateLinks(_ newLinks: [StatusLink]) {
        guard !isTornDown else { return }
        endEditing()
        links = newLinks
        tableView.reloadData()
        tableView.deselectAll(nil)
        updateRemoveButtonState()
        updateTableFrame()
        invalidateEditorLayout()
    }

    /// Ends an active field-editor session so the final text is delivered to
    /// `controlTextDidEndEditing` before a page is replaced or the window
    /// closes. It is intentionally idempotent for repeated teardown paths.
    @discardableResult
    func endEditing() -> Bool {
        guard !isEndingEditing else { return true }
        guard let field = editingCell else { return true }
        isEndingEditing = true
        defer { isEndingEditing = false }
        guard let window else {
            commit(field)
            return true
        }
        window.endEditing(for: field.editor)
        return true
    }

    func teardown() {
        guard !isTornDown else { return }
        endEditing()
        isTornDown = true
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
            self.windowCloseObserver = nil
        }
        tableView.delegate = nil
        tableView.dataSource = nil
        tableView.unregisterDraggedTypes()
        removeButton.target = nil
        addButton.target = nil
        resetButton.target = nil
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        links.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard !isTornDown,
              links.indices.contains(row),
              let tableColumn,
              let field = field(for: tableColumn.identifier) else {
            return nil
        }

        let identifier = cellIdentifier(for: field)
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? StatusLinkTableCellView)
            ?? StatusLinkTableCellView()
        cell.identifier = identifier
        cell.row = row
        cell.field = field
        cell.editor.delegate = self
        cell.editor.font = .systemFont(ofSize: NSFont.systemFontSize)
        cell.editor.placeholderString = placeholder(for: field)
        cell.editor.stringValue = value(for: field, row: row)
        cell.editor.setAccessibilityIdentifier("\(identifier.rawValue).\(row)")
        return cell
    }

    // MARK: - NSTableViewDelegate

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateRemoveButtonState()
    }

    func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row: Int) -> Bool {
        guard let tableColumn else { return false }
        return !isTornDown && links.indices.contains(row) && field(for: tableColumn.identifier) != nil
    }

    func tableView(
        _ tableView: NSTableView,
        pasteboardWriterForRow row: Int
    ) -> NSPasteboardWriting? {
        guard !isTornDown, links.indices.contains(row) else { return nil }
        endEditing()
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.statusLinkPasteboardType)
        return item
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation operation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard operation == .above,
              let sourceRow = sourceRow(from: info),
              links.indices.contains(sourceRow),
              row >= 0,
              row <= links.count else {
            return []
        }
        return .move
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard dropOperation == .above,
              let sourceRow = sourceRow(from: info),
              links.indices.contains(sourceRow),
              row >= 0,
              row <= links.count else {
            return false
        }

        endEditing()
        let destinationRow = sourceRow < row ? row - 1 : row
        return moveLink(from: sourceRow, to: destinationRow)
    }

    @discardableResult
    func reorderForTesting(from sourceRow: Int, to destinationRow: Int) -> Bool {
        guard !isTornDown else { return false }
        endEditing()
        return moveLink(from: sourceRow, to: destinationRow)
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let editor = notification.object as? NSTextField,
              let cell = cell(containing: editor) else { return }
        commit(cell)
    }

    // MARK: - Actions

    @objc private func addStatusLink(_ sender: NSButton) {
        guard !isTornDown else { return }
        endEditing()
        let row = links.count
        links.append(StatusLink(title: "", url: ""))
        tableView.insertRows(at: IndexSet(integer: row), withAnimation: .effectFade)
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        updateRemoveButtonState()
        onLinksChanged(links)
        tableView.editColumn(
            tableView.tableColumns.firstIndex { $0.identifier == Self.nameColumnIdentifier } ?? 0,
            row: row,
            with: nil,
            select: true
        )
    }

    @objc private func removeStatusLink(_ sender: NSButton) {
        guard !isTornDown else { return }
        endEditing()
        let row = tableView.selectedRow
        guard links.indices.contains(row) else {
            updateRemoveButtonState()
            return
        }

        links.remove(at: row)
        tableView.removeRows(at: IndexSet(integer: row), withAnimation: .effectFade)
        if links.isEmpty {
            tableView.deselectAll(nil)
        } else {
            tableView.selectRowIndexes(
                IndexSet(integer: min(row, links.count - 1)),
                byExtendingSelection: false
            )
        }
        updateRemoveButtonState()
        onLinksChanged(links)
    }

    @objc private func resetStatusLinks(_ sender: NSButton) {
        guard !isTornDown else { return }
        endEditing()
        updateLinks(onReset())
    }

    // MARK: - Setup

    private func configureTable() {
        tableView.identifier = Self.tableIdentifier
        tableView.delegate = self
        tableView.dataSource = self
        tableView.style = .fullWidth
        tableView.rowSizeStyle = .small
        tableView.headerView = NSTableHeaderView()
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.gridStyleMask = []
        tableView.registerForDraggedTypes([Self.statusLinkPasteboardType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)

        let nameColumn = NSTableColumn(identifier: Self.nameColumnIdentifier)
        nameColumn.title = tr(.keyStatusLinksEditorName)
        nameColumn.minWidth = 100
        nameColumn.width = 160
        nameColumn.resizingMask = [.userResizingMask, .autoresizingMask]

        let urlColumn = NSTableColumn(identifier: Self.urlColumnIdentifier)
        urlColumn.title = tr(.keyStatusLinksEditorUrl)
        urlColumn.minWidth = 160
        urlColumn.width = 260
        urlColumn.resizingMask = [.userResizingMask, .autoresizingMask]

        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(urlColumn)

        scrollView.identifier = Self.scrollViewIdentifier
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.borderType = .noBorder
    }

    private func configureControls() {
        configureFooterButton(
            addButton,
            symbolName: "plus",
            accessibilityLabel: "Add",
            action: #selector(addStatusLink(_:))
        )
        addButton.identifier = Self.addButtonIdentifier

        configureFooterButton(
            removeButton,
            symbolName: "minus",
            accessibilityLabel: "Remove",
            action: #selector(removeStatusLink(_:))
        )
        removeButton.identifier = Self.removeButtonIdentifier

        resetButton.title = tr(.keyStatusLinksEditorRestoreDefaults)
        resetButton.target = self
        resetButton.action = #selector(resetStatusLinks(_:))
        resetButton.controlSize = .small
        resetButton.setAccessibilityLabel(tr(.keyStatusLinksEditorRestoreDefaults))
        resetButton.setContentHuggingPriority(.required, for: .horizontal)
        resetButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        resetButton.translatesAutoresizingMaskIntoConstraints = false
        resetButton.identifier = Self.resetButtonIdentifier

        listContainer.boxType = .primary
        listContainer.titlePosition = .noTitle
        listContainer.contentViewMargins = .zero
        listContainer.translatesAutoresizingMaskIntoConstraints = false

        horizontalSeparator.boxType = .separator
        horizontalSeparator.translatesAutoresizingMaskIntoConstraints = false

        footerView.orientation = .horizontal
        footerView.alignment = .centerY
        footerView.distribution = .fill
        footerView.spacing = 8
        footerView.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 0)
        footerView.translatesAutoresizingMaskIntoConstraints = false
        footerView.setContentHuggingPriority(.required, for: .horizontal)
        footerView.setContentCompressionResistancePriority(.required, for: .horizontal)

        verticalSeparator.boxType = .separator
        verticalSeparator.translatesAutoresizingMaskIntoConstraints = false
        verticalSeparator.widthAnchor.constraint(equalToConstant: 1).isActive = true

        footerView.addArrangedSubview(addButton)
        footerView.addArrangedSubview(verticalSeparator)
        footerView.addArrangedSubview(removeButton)
        verticalSeparator.heightAnchor.constraint(equalTo: footerView.heightAnchor, multiplier: 0.55).isActive = true

        listContainer.addSubview(scrollView)
        listContainer.addSubview(horizontalSeparator)
        listContainer.addSubview(footerView)
        addSubview(listContainer)
        addSubview(resetButton)
    }

    private func installConstraints() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        heightConstraint = heightAnchor.constraint(equalToConstant: Self.fixedHeight)
        heightConstraint.priority = .required
        heightConstraint.isActive = true

        let horizontalInset = DashboardSettingsComponents.settingsRowHorizontalInset
        let verticalInset = DashboardSettingsComponents.settingsRowVerticalInset
        let resetSpacing = DashboardSettingsComponents.settingsRowContentControlSpacing
        let listTopConstraint = listContainer.topAnchor.constraint(equalTo: topAnchor, constant: verticalInset)
        listTopConstraint.priority = .required - 1
        let listBottomConstraint = listContainer.bottomAnchor.constraint(
            equalTo: resetButton.topAnchor,
            constant: -resetSpacing
        )
        listBottomConstraint.priority = .required - 1
        let resetBottomConstraint = resetButton.bottomAnchor.constraint(
            equalTo: bottomAnchor,
            constant: -verticalInset
        )
        resetBottomConstraint.priority = .required - 1
        NSLayoutConstraint.activate([
            listContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalInset),
            listContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalInset),
            listTopConstraint,
            listBottomConstraint,
            resetButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalInset),
            resetBottomConstraint,

            scrollView.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: listContainer.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: horizontalSeparator.topAnchor),

            horizontalSeparator.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            horizontalSeparator.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            horizontalSeparator.heightAnchor.constraint(equalToConstant: 1),

            footerView.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            footerView.topAnchor.constraint(equalTo: horizontalSeparator.bottomAnchor),
            footerView.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor)
        ])
    }

    private func configureFooterButton(
        _ button: NSButton,
        symbolName: String,
        accessibilityLabel: String,
        action: Selector
    ) {
        button.target = self
        button.action = action
        button.isBordered = false
        button.controlSize = .small
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel)
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel(accessibilityLabel)
        button.toolTip = accessibilityLabel
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    // MARK: - Model and editing helpers

    private var editingCell: StatusLinkTableCellView? {
        for row in 0..<tableView.numberOfRows {
            for column in 0..<tableView.numberOfColumns {
                guard let cell = tableView.view(
                    atColumn: column,
                    row: row,
                    makeIfNecessary: false
                ) as? StatusLinkTableCellView else { continue }
                if cell.editor.currentEditor() != nil { return cell }
            }
        }
        return nil
    }

    private func commit(_ field: StatusLinkTableCellView) {
        guard !isTornDown, links.indices.contains(field.row) else { return }
        let value = field.editor.currentEditor()?.string ?? field.editor.stringValue
        var updatedLinks = links
        switch field.field {
        case .title:
            updatedLinks[field.row].title = value
        case .url:
            updatedLinks[field.row].url = value
        }
        guard updatedLinks != links else { return }
        links = updatedLinks
        onLinksChanged(links)
    }

    private func moveLink(from sourceRow: Int, to destinationRow: Int) -> Bool {
        guard links.indices.contains(sourceRow), links.indices.contains(destinationRow) else {
            return false
        }
        guard destinationRow != sourceRow else {
            tableView.selectRowIndexes(IndexSet(integer: sourceRow), byExtendingSelection: false)
            return true
        }

        let movedLink = links.remove(at: sourceRow)
        links.insert(movedLink, at: destinationRow)
        tableView.moveRow(at: sourceRow, to: destinationRow)
        tableView.selectRowIndexes(IndexSet(integer: destinationRow), byExtendingSelection: false)
        updateRemoveButtonState()
        onLinksChanged(links)
        return true
    }

    private func value(for field: Field, row: Int) -> String {
        switch field {
        case .title: return links[row].title
        case .url: return links[row].url
        }
    }

    private func placeholder(for field: Field) -> String {
        switch field {
        case .title: return tr(.keyStatusLinksEditorDisplayName)
        case .url: return "https://"
        }
    }

    private func field(for identifier: NSUserInterfaceItemIdentifier) -> Field? {
        switch identifier {
        case Self.nameColumnIdentifier: return .title
        case Self.urlColumnIdentifier: return .url
        default: return nil
        }
    }

    private func cellIdentifier(for field: Field) -> NSUserInterfaceItemIdentifier {
        switch field {
        case .title: return Self.nameCellIdentifier
        case .url: return Self.urlCellIdentifier
        }
    }

    private func cell(containing editor: NSTextField) -> StatusLinkTableCellView? {
        for row in 0..<tableView.numberOfRows {
            for column in 0..<tableView.numberOfColumns {
                guard let cell = tableView.view(
                    atColumn: column,
                    row: row,
                    makeIfNecessary: false
                ) as? StatusLinkTableCellView else { continue }
                if cell.editor === editor { return cell }
            }
        }
        return nil
    }

    private func sourceRow(from info: NSDraggingInfo) -> Int? {
        guard let item = info.draggingPasteboard.pasteboardItems?.first,
              let value = item.string(forType: Self.statusLinkPasteboardType),
              let row = Int(value),
              info.draggingSource as? NSTableView === tableView else {
            return nil
        }
        return row
    }

    private func updateRemoveButtonState() {
        removeButton.isEnabled = !isTornDown && links.indices.contains(tableView.selectedRow)
    }

    private func updateTableFrame() {
        let viewport = scrollView.contentView.bounds
        guard viewport.width > 0 else { return }
        let rowsHeight: CGFloat
        if tableView.numberOfRows > 0 {
            rowsHeight = tableView.rect(ofRow: tableView.numberOfRows - 1).maxY
        } else {
            rowsHeight = 0
        }
        tableView.frame = NSRect(
            x: 0,
            y: 0,
            width: viewport.width,
            height: max(viewport.height, ceil(rowsHeight))
        )
        tableView.autoresizingMask = [.width]
    }

    private func invalidateEditorLayout() {
        invalidateIntrinsicContentSize()
        needsLayout = true
        superview?.needsLayout = true
        superview?.superview?.needsLayout = true
    }
}
