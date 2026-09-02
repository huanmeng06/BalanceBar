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

    private struct PendingEdit {
        let row: Int
        let field: Field
        var value: String
    }

    private final class StatusLinkTableCellView: NSTableCellView {
        let editor = NSTextField()
        var row = 0
        var field: Field = .title

        func setEditingAppearance(_ isEditing: Bool) {
            editor.drawsBackground = isEditing
            editor.backgroundColor = isEditing ? .textBackgroundColor : .clear
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)

            editor.translatesAutoresizingMaskIntoConstraints = false
            editor.isEditable = true
            editor.isSelectable = true
            editor.isBordered = false
            setEditingAppearance(false)
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
    private let footerHostView = NSView()
    private let footerView = NSStackView()
    private let verticalSeparator = NSBox()
    private let addButton = NSButton()
    private let removeButton = NSButton()
    private let resetButton = NSButton()
    private var heightConstraint: NSLayoutConstraint!
    private var windowCloseObserver: NSObjectProtocol?
    private weak var activeEditingCell: StatusLinkTableCellView?
    private var pendingEdit: PendingEdit?
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
    var footerHostViewForTesting: NSView { footerHostView }
    var footerViewForTesting: NSStackView { footerView }
    var horizontalSeparatorForTesting: NSBox { horizontalSeparator }
    var verticalSeparatorForTesting: NSBox { verticalSeparator }
    var isEditingNameForTesting: Bool {
        pendingEdit?.field == .title
    }
    @discardableResult
    func editForTesting(column: Int, row: Int) -> Bool {
        beginEditing(column: column, row: row)
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
            self?.commitPendingEdit()
        }
    }

    override func layout() {
        super.layout()
        updateTableFrame()
        updateColumnWidths()
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
        guard let field = activeEditingCell else {
            commitPendingEdit()
            return true
        }
        isEndingEditing = true
        defer { isEndingEditing = false }
        guard let window else {
            commitPendingEdit()
            finishEditingAppearance(for: field)
            return true
        }
        window.endEditing(for: field.editor)
        if activeEditingCell === field {
            commitPendingEdit()
            finishEditingAppearance(for: field)
        }
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
        cell.setEditingAppearance(
            activeEditingCell === cell
                && pendingEdit?.row == row
                && pendingEdit?.field == field
        )
        cell.editor.setAccessibilityIdentifier("\(identifier.rawValue).\(row)")
        return cell
    }

    // MARK: - NSTableViewDelegate

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateRemoveButtonState()
    }

    func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row: Int) -> Bool {
        guard !isTornDown,
              links.indices.contains(row),
              let tableColumn,
              field(for: tableColumn.identifier) != nil,
              let column = tableView.tableColumns.firstIndex(of: tableColumn),
              let cell = tableView.view(
                atColumn: column,
                row: row,
                makeIfNecessary: true
              ) as? StatusLinkTableCellView else {
            return false
        }
        prepareEditing(cell, value: cell.editor.stringValue)
        return true
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

    func controlTextDidBeginEditing(_ notification: Notification) {
        guard !isTornDown,
              let editor = notification.object as? NSTextField,
              let cell = cell(containing: editor),
              links.indices.contains(cell.row) else { return }

        prepareEditing(cell, value: editor.currentEditor()?.string ?? editor.stringValue)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard !isTornDown,
              let editor = notification.object as? NSTextField,
              activeEditingCell?.editor === editor,
              var edit = pendingEdit else { return }
        edit.value = editor.currentEditor()?.string ?? editor.stringValue
        pendingEdit = edit
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let editor = notification.object as? NSTextField else { return }
        let cell = activeEditingCell?.editor === editor
            ? activeEditingCell
            : cell(containing: editor)
        guard let cell else { return }
        if pendingEdit?.row == cell.row, pendingEdit?.field == cell.field {
            pendingEdit?.value = editor.stringValue
            commitPendingEdit()
        } else {
            commit(row: cell.row, field: cell.field, value: editor.stringValue)
        }
        finishEditingAppearance(for: cell)
    }

    // MARK: - Actions

    @objc private func addStatusLink(_ sender: NSButton) {
        guard !isTornDown else { return }
        endEditing()
        let row = links.count
        links.append(StatusLink(title: "", url: ""))
        tableView.insertRows(at: IndexSet(integer: row), withAnimation: [])
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        updateRemoveButtonState()
        onLinksChanged(links)
        beginEditing(
            column: tableView.tableColumns.firstIndex {
                $0.identifier == Self.nameColumnIdentifier
            } ?? 0,
            row: row
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
        tableView.rowSizeStyle = .medium
        tableView.headerView = nil
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.allowsColumnSelection = false
        tableView.allowsColumnReordering = false
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.gridStyleMask = []
        tableView.registerForDraggedTypes([Self.statusLinkPasteboardType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)

        let nameColumn = NSTableColumn(identifier: Self.nameColumnIdentifier)
        nameColumn.title = tr(.keyStatusLinksEditorName)
        nameColumn.minWidth = 100
        nameColumn.width = 160
        nameColumn.resizingMask = [.autoresizingMask]

        let urlColumn = NSTableColumn(identifier: Self.urlColumnIdentifier)
        urlColumn.title = tr(.keyStatusLinksEditorUrl)
        urlColumn.minWidth = 200
        urlColumn.width = 320
        urlColumn.resizingMask = [.autoresizingMask]

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
        scrollView.drawsBackground = false
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
        listContainer.translatesAutoresizingMaskIntoConstraints = false

        horizontalSeparator.boxType = .separator
        horizontalSeparator.translatesAutoresizingMaskIntoConstraints = false

        footerHostView.translatesAutoresizingMaskIntoConstraints = false
        footerHostView.setContentHuggingPriority(.required, for: .vertical)
        footerHostView.setContentCompressionResistancePriority(.required, for: .vertical)

        footerView.orientation = .horizontal
        footerView.alignment = .centerY
        footerView.distribution = .fill
        footerView.spacing = 0
        footerView.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        footerView.translatesAutoresizingMaskIntoConstraints = false
        footerView.setContentHuggingPriority(.required, for: .horizontal)
        footerView.setContentCompressionResistancePriority(.required, for: .horizontal)

        verticalSeparator.boxType = .separator
        verticalSeparator.translatesAutoresizingMaskIntoConstraints = false
        verticalSeparator.widthAnchor.constraint(equalToConstant: 1).isActive = true

        footerView.addArrangedSubview(addButton)
        footerView.addArrangedSubview(verticalSeparator)
        footerView.addArrangedSubview(removeButton)

        guard let listContentView = listContainer.contentView else {
            preconditionFailure("A primary NSBox must provide a native content view")
        }
        listContentView.addSubview(scrollView)
        listContentView.addSubview(horizontalSeparator)
        listContentView.addSubview(footerHostView)
        footerHostView.addSubview(footerView)
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
        let systemControlHeight = max(addButton.fittingSize.height, removeButton.fittingSize.height)
        let footerHeight = ceil(systemControlHeight + resetSpacing)
        let footerHeightConstraint = footerHostView.heightAnchor.constraint(equalToConstant: footerHeight)
        footerHeightConstraint.priority = .defaultHigh
        guard let listContentView = listContainer.contentView else {
            preconditionFailure("A primary NSBox must provide a native content view")
        }
        let preferredListWidthConstraint = listContentView.widthAnchor.constraint(
            greaterThanOrEqualToConstant: tableView.tableColumns.reduce(CGFloat(0)) {
                $0 + $1.width
            }
        )
        preferredListWidthConstraint.priority = .defaultLow
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
            preferredListWidthConstraint,
            listTopConstraint,
            listBottomConstraint,
            resetButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalInset),
            resetBottomConstraint,

            scrollView.leadingAnchor.constraint(equalTo: listContentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: listContentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: listContentView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: horizontalSeparator.topAnchor),

            horizontalSeparator.leadingAnchor.constraint(equalTo: listContentView.leadingAnchor),
            horizontalSeparator.trailingAnchor.constraint(equalTo: listContentView.trailingAnchor),
            horizontalSeparator.heightAnchor.constraint(equalToConstant: horizontalSeparator.fittingSize.height),

            footerHostView.leadingAnchor.constraint(equalTo: listContentView.leadingAnchor),
            footerHostView.trailingAnchor.constraint(equalTo: listContentView.trailingAnchor),
            footerHostView.topAnchor.constraint(equalTo: horizontalSeparator.bottomAnchor),
            footerHostView.bottomAnchor.constraint(equalTo: listContentView.bottomAnchor),
            footerHeightConstraint,

            footerView.leadingAnchor.constraint(equalTo: footerHostView.leadingAnchor),
            footerView.topAnchor.constraint(equalTo: footerHostView.topAnchor),
            footerView.bottomAnchor.constraint(equalTo: footerHostView.bottomAnchor),
            verticalSeparator.heightAnchor.constraint(
                equalTo: footerHostView.heightAnchor,
                multiplier: 0.55
            ),
            addButton.widthAnchor.constraint(equalTo: footerHostView.heightAnchor),
            addButton.heightAnchor.constraint(equalTo: footerHostView.heightAnchor),
            removeButton.widthAnchor.constraint(equalTo: footerHostView.heightAnchor),
            removeButton.heightAnchor.constraint(equalTo: footerHostView.heightAnchor)
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

    private func commitPendingEdit() {
        guard let edit = pendingEdit else { return }
        commit(row: edit.row, field: edit.field, value: edit.value)
    }

    private func prepareEditing(_ cell: StatusLinkTableCellView, value: String) {
        if let previousCell = activeEditingCell, previousCell !== cell {
            previousCell.setEditingAppearance(false)
        }
        activeEditingCell = cell
        pendingEdit = PendingEdit(row: cell.row, field: cell.field, value: value)
        tableView.selectRowIndexes(IndexSet(integer: cell.row), byExtendingSelection: false)
        cell.setEditingAppearance(true)
    }

    @discardableResult
    private func beginEditing(column: Int, row: Int) -> Bool {
        guard !isTornDown,
              links.indices.contains(row),
              tableView.tableColumns.indices.contains(column),
              let cell = tableView.view(
                atColumn: column,
                row: row,
                makeIfNecessary: true
              ) as? StatusLinkTableCellView else {
            return false
        }
        prepareEditing(cell, value: cell.editor.stringValue)
        tableView.editColumn(column, row: row, with: nil, select: true)
        return true
    }

    private func commit(row: Int, field: Field, value: String) {
        guard !isTornDown, links.indices.contains(row) else { return }
        var updatedLinks = links
        switch field {
        case .title:
            updatedLinks[row].title = value
        case .url:
            updatedLinks[row].url = value
        }
        guard updatedLinks != links else { return }
        links = updatedLinks
        onLinksChanged(links)
    }

    private func finishEditingAppearance(for cell: StatusLinkTableCellView) {
        cell.setEditingAppearance(false)
        if activeEditingCell === cell {
            activeEditingCell = nil
            pendingEdit = nil
        }
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
        var ancestor = editor.superview
        while let view = ancestor {
            if let cell = view as? StatusLinkTableCellView { return cell }
            ancestor = view.superview
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

    private func updateColumnWidths() {
        guard tableView.tableColumns.count == 2 else { return }
        let availableWidth = tableView.bounds.width
        guard availableWidth > 0 else { return }

        let nameWidth = floor(availableWidth / 3)
        tableView.tableColumns[0].width = nameWidth
        tableView.tableColumns[1].width = availableWidth - nameWidth
    }

    private func invalidateEditorLayout() {
        invalidateIntrinsicContentSize()
        needsLayout = true
        superview?.needsLayout = true
        superview?.superview?.needsLayout = true
    }
}
