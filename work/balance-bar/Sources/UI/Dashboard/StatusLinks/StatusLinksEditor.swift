import AppKit

enum StatusLinkField: Equatable {
    case title
    case url
}

/// Keeps native table grid lines confined to the header and real data rows.
/// The table still owns all grid, selection, and color drawing through AppKit.
final class StatusLinksTableView: NSTableView {
    private(set) var lastGridClipRectForTesting: NSRect?

    override func drawGrid(inClipRect clipRect: NSRect) {
        guard numberOfRows > 0 else {
            lastGridClipRectForTesting = nil
            return
        }

        let lastRowRect = rect(ofRow: numberOfRows - 1)
        guard !lastRowRect.isNull,
              lastRowRect.minY > bounds.minY else {
            lastGridClipRectForTesting = nil
            return
        }

        let rowsRect = NSRect(
            x: bounds.minX,
            y: bounds.minY,
            width: bounds.width,
            height: lastRowRect.minY - bounds.minY
        )
        let gridClipRect = clipRect.intersection(rowsRect)
        guard !gridClipRect.isNull,
              gridClipRect.width > 0,
              gridClipRect.height > 0 else {
            lastGridClipRectForTesting = nil
            return
        }

        lastGridClipRectForTesting = gridClipRect
        super.drawGrid(inClipRect: gridClipRect)
    }
}

/// Prevents a short embedded table from forwarding scroll gestures to the
/// surrounding settings page. Drawing remains entirely AppKit-owned.
final class StatusLinksScrollView: NSScrollView {
    var allowsVerticalScrolling = false

    override func scrollWheel(with event: NSEvent) {
        guard allowsVerticalScrolling else { return }
        super.scrollWheel(with: event)
    }
}

/// The native AppKit editor for the configurable menu-bar status links.
///
/// The historical type name is kept because Dashboard composition and a few
/// test seams use it. It is no longer a hosting view: every editor control,
/// including the editable table cells, is AppKit-owned.
final class StatusLinksEditorHostingView: NSView,
    NSTableViewDataSource,
    NSTableViewDelegate,
    NSTextFieldDelegate
{
    static let fixedHeight: CGFloat = 190
    static let tableViewportHeight: CGFloat = 134
    static let tableRowHeight: CGFloat = 22
    static let tableCornerRadius: CGFloat = 12
    static let tableBorderWidth: CGFloat = 1
    static let fieldHorizontalInset: CGFloat = 12
    static let fieldTrailingInset: CGFloat = fieldHorizontalInset * 2
    static let nameColumnMinimumWidth: CGFloat = 120
    static let urlColumnMinimumWidth: CGFloat = 220

    private let onChange: (Int, StatusLinkField, String) -> Void
    private let onAdd: () -> Void
    private let onRemove: (Int) -> Void
    private let onReset: () -> Void

    private(set) var links: [StatusLink]
    private(set) var isTornDown = false

    let tableView: StatusLinksTableView
    let tableContainer: NSBox
    let scrollView: StatusLinksScrollView
    let nameColumn: NSTableColumn
    let urlColumn: NSTableColumn
    let resetButton: NSButton
    let actionsControl: NSSegmentedControl

    private var heightConstraint: NSLayoutConstraint?
    private var lastColumnLayoutWidth: CGFloat = -1
    private var editingGeneration = 0

    // These accessors keep the view hierarchy easy to inspect in focused
    // XCTest coverage without exposing implementation state to production.
    var tableViewForTesting: NSTableView { tableView }
    var tableContainerForTesting: NSBox { tableContainer }
    var scrollViewForTesting: NSScrollView { scrollView }
    var resetButtonForTesting: NSButton { resetButton }
    var actionsControlForTesting: NSSegmentedControl { actionsControl }

    var addButtonForTesting: NSSegmentedControl { actionsControl }
    var removeButtonForTesting: NSSegmentedControl { actionsControl }

    var rowCount: Int { links.count }
    var layoutHeight: CGFloat { Self.fixedHeight }
    var currentHeight: CGFloat { max(0, heightConstraint?.constant ?? layoutHeight) }
    var isVisible: Bool { currentHeight > 0 && alphaValue > 0 }

    init(
        links: [StatusLink],
        onChange: @escaping (Int, StatusLinkField, String) -> Void,
        onAdd: @escaping () -> Void,
        onRemove: @escaping (Int) -> Void,
        onReset: @escaping () -> Void
    ) {
        self.links = links
        self.onChange = onChange
        self.onAdd = onAdd
        self.onRemove = onRemove
        self.onReset = onReset

        let tableView = StatusLinksTableView()
        let nameColumn = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("statusLinks.name.column")
        )
        let urlColumn = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("statusLinks.url.column")
        )
        let tableContainer = NSBox()
        let scrollView = StatusLinksScrollView()
        let resetButton = NSButton(
            title: tr(.keyStatusLinksEditorRestoreDefaults),
            target: nil,
            action: nil
        )
        let actionsControl = NSSegmentedControl()

        self.tableView = tableView
        self.tableContainer = tableContainer
        self.scrollView = scrollView
        self.nameColumn = nameColumn
        self.urlColumn = urlColumn
        self.resetButton = resetButton
        self.actionsControl = actionsControl

        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = true

        configureResetButton(resetButton)
        configureTable(
            tableView,
            nameColumn: nameColumn,
            urlColumn: urlColumn
        )
        configureScrollView(scrollView, documentView: tableView)
        configureTableContainer(tableContainer, contentView: scrollView)
        configureActionsControl(actionsControl)

        addSubview(resetButton)
        addSubview(tableContainer)
        addSubview(actionsControl)

        NSLayoutConstraint.activate([
            tableContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            tableContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            tableContainer.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            tableContainer.heightAnchor.constraint(equalToConstant: Self.tableViewportHeight),

            actionsControl.leadingAnchor.constraint(equalTo: tableContainer.leadingAnchor),
            actionsControl.topAnchor.constraint(equalTo: tableContainer.bottomAnchor, constant: 8),
            actionsControl.heightAnchor.constraint(equalToConstant: 24),

            resetButton.trailingAnchor.constraint(equalTo: tableContainer.trailingAnchor),
            resetButton.leadingAnchor.constraint(
                greaterThanOrEqualTo: actionsControl.trailingAnchor,
                constant: 12
            ),
            resetButton.centerYAnchor.constraint(equalTo: actionsControl.centerYAnchor)
        ])

        let heightConstraint = heightAnchor.constraint(equalToConstant: Self.fixedHeight)
        heightConstraint.isActive = true
        self.heightConstraint = heightConstraint

        updateRemoveControlState()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        teardown()
    }

    override func layout() {
        super.layout()
        updateColumnWidthsIfNeeded()
        updateTableDocumentFrame()
    }

    func updateLinks(
        _ newLinks: [StatusLink],
        selectLastRow: Bool = false,
        completion: (() -> Void)? = nil
    ) {
        guard !isTornDown else {
            completion?()
            return
        }

        let oldCount = links.count
        let previousSelection = tableView.selectedRow
        let isAddingRow = selectLastRow && newLinks.count > oldCount

        links = newLinks
        tableView.reloadData()
        tableView.noteNumberOfRowsChanged()
        updateTableDocumentFrame()

        let nextSelection: Int?
        if newLinks.isEmpty {
            nextSelection = nil
        } else if isAddingRow {
            nextSelection = newLinks.indices.last
        } else if previousSelection >= 0 {
            nextSelection = min(previousSelection, newLinks.count - 1)
        } else {
            nextSelection = nil
        }

        applySelection(nextSelection)
        completion?()

        if isAddingRow, let nextSelection {
            beginNameEditing(row: nextSelection)
        }
    }

    func setVisible(_ visible: Bool, animated: Bool) {
        guard !isTornDown else { return }
        let targetHeight = visible ? Self.fixedHeight : 0
        let generation = editingGeneration

        // Keep the native controls pinned to the top while the outer row is
        // collapsed. clipsToBounds prevents the fixed editor content from
        // crossing the preceding settings row during a reveal.
        heightConstraint?.constant = targetHeight
        synchronizeAncestorCardHeight(animated: animated)

        guard animated else {
            alphaValue = visible ? 1 : 0
            needsLayout = true
            superview?.needsLayout = true
            return
        }

        if visible {
            alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                self.animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                self.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                guard let self, self.editingGeneration == generation else { return }
                self.alphaValue = 0
                self.needsLayout = true
                self.superview?.needsLayout = true
            }
        }
    }

    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        editingGeneration &+= 1
        tableView.delegate = nil
        tableView.dataSource = nil
        resetButton.target = nil
        actionsControl.target = nil
        heightConstraint?.isActive = false
        heightConstraint = nil
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        links.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard links.indices.contains(row), let tableColumn else { return nil }

        let isNameColumn = tableColumn.identifier == nameColumn.identifier
        let cellIdentifier = NSUserInterfaceItemIdentifier(
            isNameColumn ? "statusLinks.name.cell" : "statusLinks.url.cell"
        )
        let cell = (tableView.makeView(withIdentifier: cellIdentifier, owner: self)
            as? NSTableCellView) ?? makeCell(identifier: cellIdentifier)
        cell.identifier = cellIdentifier

        let field: NSTextField
        if let existing = cell.textField {
            field = existing
        } else {
            field = makeTextField()
            cell.textField = field
            cell.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(
                    equalTo: cell.leadingAnchor,
                    constant: Self.fieldHorizontalInset
                ),
                field.trailingAnchor.constraint(
                    equalTo: cell.trailingAnchor,
                    constant: -Self.fieldTrailingInset
                ),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                field.heightAnchor.constraint(equalToConstant: field.intrinsicContentSize.height)
            ])
        }

        field.tag = row
        field.identifier = NSUserInterfaceItemIdentifier(
            "statusLinks.\(isNameColumn ? "name" : "url").\(row)"
        )
        field.placeholderString = isNameColumn
            ? tr(.keyStatusLinksEditorDisplayName)
            : "https://"
        field.stringValue = isNameColumn ? links[row].title : links[row].url
        field.setAccessibilityLabel(
            isNameColumn
                ? "\(tr(.keyStatusLinksEditorName)) \(row + 1)"
                : "\(tr(.keyStatusLinksEditorUrl)) \(row + 1)"
        )
        field.delegate = self
        field.isEditable = true
        field.isSelectable = true
        field.isContinuous = true
        field.isBordered = false
        field.drawsBackground = false
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.focusRingType = .default

        return cell
    }

    // MARK: - NSTableViewDelegate

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateRemoveControlState()
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        commit(field)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        commit(field)
    }

    // MARK: - Native actions

    @objc private func performAction(_ sender: NSSegmentedControl) {
        let segment = sender.selectedSegment
        sender.selectedSegment = -1
        performAction(segment: segment)
    }

    private func performAction(segment: Int) {
        switch segment {
        case 0:
            onAdd()
        case 1:
            let row = tableView.selectedRow
            guard links.indices.contains(row) else {
                updateRemoveControlState()
                return
            }
            onRemove(row)
        default:
            break
        }
    }

    func performActionForTesting(segment: Int) {
        performAction(segment: segment)
    }

    @objc private func restoreDefaults(_ sender: NSButton) {
        onReset()
    }

    private func configureResetButton(_ button: NSButton) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.target = self
        button.action = #selector(restoreDefaults(_:))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12)
        button.identifier = NSUserInterfaceItemIdentifier("statusLinks.reset")
        button.setAccessibilityLabel(tr(.keyStatusLinksEditorRestoreDefaults))
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func configureTable(
        _ table: StatusLinksTableView,
        nameColumn: NSTableColumn,
        urlColumn: NSTableColumn
    ) {
        nameColumn.title = tr(.keyStatusLinksEditorName)
        nameColumn.minWidth = Self.nameColumnMinimumWidth
        nameColumn.resizingMask = .autoresizingMask
        urlColumn.title = tr(.keyStatusLinksEditorUrl)
        urlColumn.minWidth = Self.urlColumnMinimumWidth
        urlColumn.resizingMask = .autoresizingMask

        table.addTableColumn(nameColumn)
        table.addTableColumn(urlColumn)
        table.headerView = nil
        table.delegate = self
        table.dataSource = self
        table.identifier = NSUserInterfaceItemIdentifier("statusLinks.table")
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.allowsColumnSelection = false
        table.allowsColumnReordering = false
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.rowSizeStyle = .medium
        table.rowHeight = Self.tableRowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.style = .fullWidth
        table.selectionHighlightStyle = .regular
        table.usesAlternatingRowBackgroundColors = false
        table.gridStyleMask = [.solidHorizontalGridLineMask]
        table.gridColor = .separatorColor
        table.setAccessibilityLabel(tr(.keyStatusLinksEditorStatusLinks))
        table.setAccessibilityRole(.table)
    }

    private func configureScrollView(_ scrollView: StatusLinksScrollView, documentView: NSView) {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .none
        scrollView.drawsBackground = false
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = Self.tableCornerRadius
        scrollView.layer?.cornerCurve = .continuous
        scrollView.layer?.masksToBounds = true
        scrollView.setAccessibilityLabel(tr(.keyStatusLinksEditorStatusLinks))

        documentView.translatesAutoresizingMaskIntoConstraints = true
        documentView.autoresizingMask = [.width]
    }

    private func configureTableContainer(_ container: NSBox, contentView: NSView) {
        container.translatesAutoresizingMaskIntoConstraints = false
        container.boxType = .custom
        container.borderWidth = Self.tableBorderWidth
        container.cornerRadius = Self.tableCornerRadius
        container.borderColor = .gridColor
        container.fillColor = .clear
        container.contentViewMargins = .zero
        container.contentView = contentView

        let borderInset = Self.tableBorderWidth
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: borderInset
            ),
            contentView.trailingAnchor.constraint(
                equalTo: container.trailingAnchor,
                constant: -borderInset
            ),
            contentView.topAnchor.constraint(
                equalTo: container.topAnchor,
                constant: borderInset
            ),
            contentView.bottomAnchor.constraint(
                equalTo: container.bottomAnchor,
                constant: -borderInset
            )
        ])
    }

    private func configureActionsControl(_ control: NSSegmentedControl) {
        control.translatesAutoresizingMaskIntoConstraints = false
        control.segmentCount = 2
        control.trackingMode = .momentary
        control.segmentStyle = .automatic
        control.setWidth(28, forSegment: 0)
        control.setWidth(28, forSegment: 1)
        control.segmentDistribution = .fillEqually
        if let plus = NSImage(
            systemSymbolName: "plus",
            accessibilityDescription: "Add status link"
        ) {
            control.setImage(plus, forSegment: 0)
            control.setLabel("", forSegment: 0)
        } else {
            control.setLabel("+", forSegment: 0)
        }
        if let minus = NSImage(
            systemSymbolName: "minus",
            accessibilityDescription: "Remove status link"
        ) {
            control.setImage(minus, forSegment: 1)
            control.setLabel("", forSegment: 1)
        } else {
            control.setLabel("−", forSegment: 1)
        }
        control.setAlignment(.center, forSegment: 0)
        control.setAlignment(.center, forSegment: 1)
        control.target = self
        control.action = #selector(performAction(_:))
        control.identifier = NSUserInterfaceItemIdentifier("statusLinks.actions")
        control.toolTip = "Add or remove status links"
        control.setAccessibilityLabel("Status Links actions")
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        return cell
    }

    private func makeTextField() -> NSTextField {
        let field = NSTextField()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = .systemFont(ofSize: 13)
        field.alignment = .left
        field.isBordered = false
        field.drawsBackground = false
        field.usesSingleLineMode = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        return field
    }

    private func updateColumnWidthsIfNeeded() {
        let availableWidth = tableView.bounds.width
        guard availableWidth > 0,
              abs(availableWidth - lastColumnLayoutWidth) > 0.5 else { return }

        let nameWidth = max(
            Self.nameColumnMinimumWidth,
            min(availableWidth / 3, availableWidth - Self.urlColumnMinimumWidth)
        )
        nameColumn.width = nameWidth
        urlColumn.width = max(Self.urlColumnMinimumWidth, availableWidth - nameWidth)
        lastColumnLayoutWidth = availableWidth
    }

    private func updateTableDocumentFrame() {
        let viewportSize = scrollView.contentView.bounds.size
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }

        let lastRow = tableView.numberOfRows - 1
        let rowsHeight: CGFloat
        if lastRow >= 0 {
            let lastRowRect = tableView.rect(ofRow: lastRow)
            rowsHeight = lastRowRect.isNull ? 0 : lastRowRect.maxY
        } else {
            rowsHeight = 0
        }

        let shouldScroll = rowsHeight > viewportSize.height + 0.5
        scrollView.allowsVerticalScrolling = shouldScroll
        if scrollView.hasVerticalScroller != shouldScroll {
            scrollView.hasVerticalScroller = shouldScroll
        }
        let documentHeight = max(viewportSize.height, rowsHeight)
        let newFrame = NSRect(
            x: 0,
            y: 0,
            width: viewportSize.width,
            height: documentHeight
        )
        if tableView.frame != newFrame {
            tableView.frame = newFrame
        }
    }

    private func applySelection(_ row: Int?) {
        guard let row, links.indices.contains(row) else {
            tableView.deselectAll(nil)
            updateRemoveControlState()
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        updateRemoveControlState()
    }

    private func updateRemoveControlState() {
        actionsControl.setEnabled(
            links.indices.contains(tableView.selectedRow),
            forSegment: 1
        )
    }

    private func beginNameEditing(row: Int) {
        guard links.indices.contains(row) else { return }
        editingGeneration &+= 1
        let generation = editingGeneration
        applySelection(row)

        func editIfPossible() {
            guard !self.isTornDown,
                  generation == self.editingGeneration,
                  self.links.indices.contains(row) else { return }
            self.tableView.layoutSubtreeIfNeeded()
            let cell = self.tableView.view(
                atColumn: 0,
                row: row,
                makeIfNecessary: true
            ) as? NSTableCellView
            self.tableView.editColumn(0, row: row, with: nil, select: true)
            if self.tableView.editedRow < 0, let field = cell?.textField {
                self.window?.makeFirstResponder(field)
            }
        }

        editIfPossible()
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.editingGeneration else { return }
            editIfPossible()
        }
    }

    private func commit(_ field: NSTextField) {
        let row = field.tag
        guard links.indices.contains(row),
              let fieldIdentifier = field.identifier?.rawValue else { return }

        let statusField: StatusLinkField
        if fieldIdentifier.hasPrefix("statusLinks.name.") {
            statusField = .title
        } else if fieldIdentifier.hasPrefix("statusLinks.url.") {
            statusField = .url
        } else {
            return
        }

        let value = field.stringValue
        switch statusField {
        case .title:
            guard links[row].title != value else { return }
            links[row].title = value
        case .url:
            guard links[row].url != value else { return }
            links[row].url = value
        }
        onChange(row, statusField, value)
    }

    private func synchronizeAncestorCardHeight(animated: Bool) {
        guard let rowsStack = superview as? NSStackView,
              let card = rowsStack.superview else { return }
        let separators = rowsStack.arrangedSubviews.compactMap { $0 as? NSBox }
        let requiredHeight = DashboardSettingsComponents.settingsCardHeight(
            rowsStack: rowsStack,
            separators: separators,
            rowHeight: { [weak self] row in
                guard let self, row === self else { return nil }
                return self.currentHeight
            }
        )
        let constraint = card.constraints.first {
            ($0.firstItem as? NSView) === card
                && $0.firstAttribute == .height
                && $0.relation == .equal
        }
        if animated {
            constraint?.animator().constant = requiredHeight
        } else {
            constraint?.constant = requiredHeight
        }
        card.invalidateIntrinsicContentSize()
        card.needsLayout = true
        rowsStack.needsLayout = true
    }
}
