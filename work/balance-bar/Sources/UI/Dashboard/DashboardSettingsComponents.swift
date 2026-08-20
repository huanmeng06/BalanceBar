import AppKit

enum DashboardSettingsComponents {
    struct PopUpItem {
        let title: String
        let representedObject: Any?

        init(title: String, representedObject: Any? = nil) {
            self.title = title
            self.representedObject = representedObject
        }
    }

    static func makeSettingsPage(_ sections: [NSView]) -> NSView {
        let root = DashboardSettingsPageView()
        let scrollView = NSScrollView()
        scrollView.contentView = NSClipView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        // Keep the scrollbar discoverable on dense settings pages. The
        // document is taller than the viewport when the status-link editor is
        // present, so hiding the scroller makes the add control look missing.
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let documentView = DashboardSettingsDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        let stack = NSStackView(views: sections)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 28
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setContentHuggingPriority(.required, for: .vertical)
        stack.setContentCompressionResistancePriority(.required, for: .vertical)
        documentView.addSubview(stack)
        root.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),
            // The document top is the native legal top; no duplicate titlebar
            // or document inset is placed in the scrollable content range.
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 34),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -34),
            // The stack must fit inside the document, but it should keep its
            // natural height when the page is shorter than the viewport.
            // Using an equality here makes AppKit stretch the first row to
            // consume all remaining space.
            stack.bottomAnchor.constraint(lessThanOrEqualTo: documentView.bottomAnchor, constant: -34)
        ])
        for section in sections {
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return root
    }

    static func makeSettingsSection(
        _ title: String,
        rows: [NSView],
        separatorIndices: Set<Int>? = nil,
        rowHeight: ((NSView) -> CGFloat?)? = nil,
        onLayoutCreated: ((NSStackView, NSLayoutConstraint, [NSView]) -> Void)? = nil
    ) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 18
        card.layer?.backgroundColor = dashboardAdaptiveColor(
            light: NSColor.white.withAlphaComponent(0.94),
            dark: NSColor.white.withAlphaComponent(0.065)
        ).cgColor
        card.layer?.borderColor = dashboardAdaptiveColor(
            light: NSColor.white.withAlphaComponent(0.95),
            dark: NSColor.white.withAlphaComponent(0.075)
        ).cgColor
        card.layer?.borderWidth = 0.5
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = dashboardUsesDarkAppearance ? 0.20 : 0.08
        card.layer?.shadowRadius = 14
        card.layer?.shadowOffset = NSSize(width: 0, height: -3)
        card.layer?.masksToBounds = false

        let rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.distribution = .fill
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.setContentHuggingPriority(.required, for: .vertical)
        // The card has an explicit height that changes when rows are added or
        // removed. Let the stack follow that constraint instead of preserving
        // its previous intrinsic height and leaving an empty gravity area.
        rowsStack.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        card.addSubview(rowsStack)
        NSLayoutConstraint.activate([
            rowsStack.topAnchor.constraint(equalTo: card.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])
        var separators: [NSView] = []
        for (index, row) in rows.enumerated() {
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            let hasFollowingRow = index < rows.count - 1
            let shouldInsertSeparator = hasFollowingRow && (separatorIndices?.contains(index) ?? true)
            if shouldInsertSeparator {
                let separator = NSBox()
                separator.boxType = .separator
                separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
                rowsStack.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: rowsStack.widthAnchor, constant: -32).isActive = true
                separators.append(separator)
            }
        }

        // NSView has no intrinsic height. Give the card the exact height of
        // its rows so a short settings page cannot stretch the first row to
        // fill the scroll viewport.
        let visibleRows = rows.filter { !$0.isHidden }
        let rowsHeight = visibleRows.reduce(CGFloat(0)) { partial, row in
            let explicitHeight = row.constraints.first {
                ($0.firstItem as? NSView) === row &&
                    $0.firstAttribute == .height &&
                    $0.relation == .equal
            }?.constant
            let fittingHeight = rowHeight?(row) ?? row.fittingSize.height
            return partial + max(1, explicitHeight ?? fittingHeight)
        }
        let separatorHeight = CGFloat(separators.filter { !$0.isHidden }.count)
        let cardHeightConstraint = card.heightAnchor.constraint(
            equalToConstant: max(1, ceil(rowsHeight + separatorHeight))
        )
        cardHeightConstraint.isActive = true
        onLayoutCreated?(rowsStack, cardHeightConstraint, separators)

        let section = NSStackView(views: [heading, card])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 11
        card.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    static func makeSettingsRow(
        _ title: String,
        subtitle: String? = nil,
        subtitleLabel: NSTextField? = nil,
        control: NSView? = nil,
        minimumHeight: CGFloat = 58
    ) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: max(62, minimumHeight)).isActive = true

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.isEditable = false
        label.isSelectable = false
        let labels = NSStackView(views: [label])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        if let subtitle, !subtitle.isEmpty {
            let detail = subtitleLabel ?? NSTextField(wrappingLabelWithString: subtitle)
            detail.stringValue = subtitle
            detail.font = .systemFont(ofSize: 12)
            detail.textColor = .secondaryLabelColor
            detail.isEditable = false
            detail.isSelectable = false
            labels.addArrangedSubview(detail)
        }
        labels.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(labels)
        var constraints = [
            labels.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 20),
            labels.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            labels.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 11),
            labels.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -11)
        ]
        if let control {
            control.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(control)
            constraints.append(contentsOf: [
                control.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -20),
                control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                labels.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -20)
            ])
        } else {
            constraints.append(labels.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -20))
        }
        NSLayoutConstraint.activate(constraints)
        return row
    }

    static func makePageHeader(_ title: String, subtitle: String) -> NSStackView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 24, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: subtitle)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [heading, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    static func makeSwitch(
        identifier: String,
        isOn: Bool,
        target: AnyObject?,
        action: Selector?
    ) -> NSSwitch {
        let control = NSSwitch()
        control.identifier = NSUserInterfaceItemIdentifier(identifier)
        control.state = isOn ? .on : .off
        control.target = target
        control.action = action
        return control
    }

    static func makePopUpButton(
        identifier: String? = nil,
        items: [PopUpItem],
        selectedIndex: Int? = nil,
        target: AnyObject?,
        action: Selector?
    ) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        if let identifier {
            popup.identifier = NSUserInterfaceItemIdentifier(identifier)
        }
        popup.target = target
        popup.action = action
        for (index, item) in items.enumerated() {
            popup.addItem(withTitle: item.title)
            popup.item(at: index)?.representedObject = item.representedObject
        }
        if let selectedIndex {
            popup.selectItem(at: selectedIndex)
        }
        return popup
    }

    static func makeIntervalPopUpButton(
        values: [(Double, String)],
        selected: TimeInterval,
        identifier: String,
        target: AnyObject?,
        action: Selector?
    ) -> NSPopUpButton {
        makePopUpButton(
            identifier: identifier,
            items: values.map { PopUpItem(
                title: $0.1,
                representedObject: NSNumber(value: $0.0)
            ) },
            selectedIndex: values.firstIndex { abs($0.0 - selected) < 0.001 },
            target: target,
            action: action
        )
    }
}

/// Owns only the one-time native starting position for a newly mounted
/// settings page. Ordinary user scrolling remains entirely AppKit-owned.
final class DashboardSettingsPageView: NSView {
    private var didEstablishInitialTopOrigin = false
    private var isEstablishingInitialTopOrigin = false

    override func layout() {
        super.layout()
        guard !didEstablishInitialTopOrigin,
              !isEstablishingInitialTopOrigin,
              let scrollView = subviews.first(where: { $0 is NSScrollView }) as? NSScrollView,
              let documentView = scrollView.documentView,
              scrollView.contentView.bounds.width > 0,
              scrollView.contentView.bounds.height > 0,
              documentView.bounds.width > 0,
              documentView.bounds.height > 0 else {
            return
        }

        isEstablishingInitialTopOrigin = true
        defer { isEstablishingInitialTopOrigin = false }

        let contentView = scrollView.contentView
        // The document is flipped, but the clip view is not. Converting the
        // document's visual minY into the clip coordinate system therefore
        // produces the opposite endpoint. Native clip origins are expressed
        // in the clip view's superview coordinate system: the flipped
        // document's frame minY is the visual top origin.
        contentView.scroll(to: NSPoint(
            x: documentView.frame.minX,
            y: documentView.frame.minY
        ))
        scrollView.reflectScrolledClipView(contentView)
        DashboardScrollTrace.marker(
            "settings-initial-top-origin",
            source: "DashboardSettingsPageView",
            flags: "one-shot=true; coordinate=flipped-document-frame-min"
        )
        didEstablishInitialTopOrigin = true
    }
}

/// Settings documents use AppKit's native top-origin convention. With a
/// flipped document, the top inset is the legal visual start and a short page
/// naturally has no vertical range; NSScrollView remains the only user-scroll
/// bounds owner.
final class DashboardSettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}
