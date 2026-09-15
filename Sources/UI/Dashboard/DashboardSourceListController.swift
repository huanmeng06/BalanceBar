import AppKit

enum DashboardSidebarGroup: Int, CaseIterable {
    case appearance
    case system

    var title: String {
        switch self {
        case .appearance: return tr(.keyDashboardWindowControllerAppearance)
        case .system: return tr(.keyDashboardWindowControllerSystem)
        }
    }

    var sections: [DashboardSection] {
        switch self {
        case .appearance: return [.menuBar, .menu]
        case .system: return [.advanced, .about]
        }
    }
}

/// Stable outline item. Groups are never navigation destinations; section
/// nodes map 1:1 onto `DashboardSection`. Provider pages are not represented.
final class DashboardSidebarNode: NSObject {
    enum Kind {
        case group(DashboardSidebarGroup)
        case section(DashboardSection)
    }

    let kind: Kind
    private(set) var children: [DashboardSidebarNode] = []

    var isGroup: Bool {
        if case .group = kind { return true }
        return false
    }

    var section: DashboardSection? {
        if case .section(let section) = kind { return section }
        return nil
    }

    var group: DashboardSidebarGroup? {
        if case .group(let group) = kind { return group }
        return nil
    }

    var title: String {
        switch kind {
        case .group(let group): return group.title
        case .section(let section): return section.title
        }
    }

    fileprivate init(kind: Kind, children: [DashboardSidebarNode] = []) {
        self.kind = kind
        self.children = children
    }

    static func makeNavigationTree() -> [DashboardSidebarNode] {
        let general = DashboardSidebarNode(kind: .section(.general))
        let groups = DashboardSidebarGroup.allCases.map { group in
            DashboardSidebarNode(
                kind: .group(group),
                children: group.sections.map { DashboardSidebarNode(kind: .section($0)) }
            )
        }
        return [general] + groups
    }
}

final class DashboardSourceListOutlineView: NSOutlineView {
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
}

final class DashboardSourceListCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("DashboardSourceListSectionCell")

    private(set) var updateBadgeView = DashboardUpdateBadgeView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier

        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyDown
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        icon.setAccessibilityElement(false)

        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        updateBadgeView.setContentHuggingPriority(.required, for: .horizontal)
        updateBadgeView.setContentCompressionResistancePriority(.required, for: .horizontal)
        updateBadgeView.isHidden = true

        let stack = NSStackView(views: [icon, title])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
        stack.detachesHiddenViews = true
        stack.setViews([icon, title], in: .leading)
        stack.setViews([updateBadgeView], in: .trailing)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        imageView = icon
        textField = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(section: DashboardSection, showsUpdateBadge: Bool) {
        imageView?.image = NSImage(systemSymbolName: section.symbolName, accessibilityDescription: nil)
        imageView?.contentTintColor = .labelColor
        imageView?.setAccessibilityElement(false)
        textField?.stringValue = section.title
        textField?.toolTip = section.title
        setAccessibilityLabel(section.title)
        setShowsUpdateBadge(section == .general && showsUpdateBadge)
    }

    func setShowsUpdateBadge(_ visible: Bool) {
        updateBadgeView.isHidden = !visible
    }
}

final class DashboardSourceListGroupCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("DashboardSourceListGroupCell")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.textColor = .tertiaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            title.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        textField = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String) {
        textField?.stringValue = title
        setAccessibilityLabel(title)
    }
}

/// Owns the native source-list outline. Selection lives on the outline view;
/// this object is only the data source/delegate and badge owner.
final class DashboardSourceListController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let scrollView = NSScrollView()
    let outlineView = DashboardSourceListOutlineView()
    let roots: [DashboardSidebarNode]
    var onSelectSection: ((DashboardSection) -> Void)?

    var view: NSView { scrollView }

    private var showsUpdateAvailableBadge = false
    private var isApplyingProgrammaticSelection = false
    private var isTornDown = false

    override init() {
        roots = DashboardSidebarNode.makeNavigationTree()
        super.init()
        configureOutline()
        reloadAndExpand()
    }

    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        onSelectSection = nil
        outlineView.dataSource = nil
        outlineView.delegate = nil
    }

    func selectedSection() -> DashboardSection? {
        let row = outlineView.selectedRow
        guard row >= 0 else { return nil }
        return (outlineView.item(atRow: row) as? DashboardSidebarNode)?.section
    }

    func row(for section: DashboardSection) -> Int? {
        guard let node = node(for: section) else { return nil }
        let row = outlineView.row(forItem: node)
        return row >= 0 ? row : nil
    }

    func node(for section: DashboardSection) -> DashboardSidebarNode? {
        for root in roots {
            if root.section == section { return root }
            if let child = root.children.first(where: { $0.section == section }) {
                return child
            }
        }
        return nil
    }

    func applySelection(_ section: DashboardSection?) {
        guard !isTornDown else { return }
        expandGroups()
        isApplyingProgrammaticSelection = true
        defer { isApplyingProgrammaticSelection = false }
        if let section, let row = row(for: section) {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            outlineView.deselectAll(nil)
        }
    }

    func setShowsUpdateAvailableBadge(_ visible: Bool) {
        showsUpdateAvailableBadge = visible
        guard let row = row(for: .general),
              let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? DashboardSourceListCellView
        else { return }
        cell.setShowsUpdateBadge(visible)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return roots.count }
        return (item as? DashboardSidebarNode)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return roots[index] }
        return (item as! DashboardSidebarNode).children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? DashboardSidebarNode)?.isGroup ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? DashboardSidebarNode)?.isGroup ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? DashboardSidebarNode)?.section != nil
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet
    ) -> IndexSet {
        let selectable = IndexSet(proposedSelectionIndexes.filter { row in
            (outlineView.item(atRow: row) as? DashboardSidebarNode)?.section != nil
        })
        if isApplyingProgrammaticSelection {
            return selectable
        }
        if proposedSelectionIndexes.isEmpty {
            return outlineView.selectedRowIndexes
        }
        if !selectable.isEmpty {
            return selectable
        }
        guard let proposedRow = proposedSelectionIndexes.first else {
            return outlineView.selectedRowIndexes
        }
        let current = outlineView.selectedRow
        let direction = proposedRow >= current ? 1 : -1
        var row = proposedRow
        while row >= 0 && row < outlineView.numberOfRows {
            if (outlineView.item(atRow: row) as? DashboardSidebarNode)?.section != nil {
                return IndexSet(integer: row)
            }
            row += direction
        }
        return outlineView.selectedRowIndexes
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? DashboardSidebarNode else { return nil }
        if node.isGroup {
            let cell = outlineView.makeView(withIdentifier: DashboardSourceListGroupCellView.identifier, owner: self)
                as? DashboardSourceListGroupCellView ?? DashboardSourceListGroupCellView()
            cell.configure(title: node.title)
            return cell
        }
        guard let section = node.section else { return nil }
        let cell = outlineView.makeView(withIdentifier: DashboardSourceListCellView.identifier, owner: self)
            as? DashboardSourceListCellView ?? DashboardSourceListCellView()
        cell.configure(section: section, showsUpdateBadge: section == .general && showsUpdateAvailableBadge)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        (item as? DashboardSidebarNode)?.title
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingProgrammaticSelection, !isTornDown else { return }
        guard let section = selectedSection() else { return }
        onSelectSection?(section)
    }

    private func configureOutline() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("DashboardSourceListColumn"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .default
        outlineView.floatsGroupRows = false
        outlineView.allowsEmptySelection = true
        outlineView.allowsMultipleSelection = false
        outlineView.allowsTypeSelect = true
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.gridStyleMask = []
        outlineView.backgroundColor = .clear
        outlineView.autoresizesOutlineColumn = true
        outlineView.dataSource = self
        outlineView.delegate = self

        scrollView.documentView = outlineView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
    }

    private func reloadAndExpand() {
        outlineView.reloadData()
        expandGroups()
        outlineView.sizeLastColumnToFit()
    }

    private func expandGroups() {
        for root in roots where root.isGroup {
            outlineView.expandItem(root, expandChildren: true)
        }
    }
}
