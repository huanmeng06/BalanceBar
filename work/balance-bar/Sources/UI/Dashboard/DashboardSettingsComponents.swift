import AppKit

private final class DashboardSettingsRowView: NSView {
    let minimumHeight: CGFloat
    let verticalPadding: CGFloat
    weak var labelsView: NSStackView?
    weak var controlView: NSView?
    weak var cardView: DashboardSettingsCardView?
    private var lastMeasuredWidth: CGFloat = -1
    private var lastPreferredHeight: CGFloat = -1

    init(minimumHeight: CGFloat, verticalPadding: CGFloat) {
        self.minimumHeight = max(62, minimumHeight)
        self.verticalPadding = max(0, verticalPadding)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var preferredRowHeight: CGFloat {
        guard let labelsView, bounds.width > 0 else { return minimumHeight }

        labelsView.layoutSubtreeIfNeeded()
        let visibleLabels = labelsView.arrangedSubviews.filter { !$0.isHidden }
        let labelHeight = visibleLabels.reduce(CGFloat(0)) { total, view in
            let height = view.fittingSize.height
            return total + height
        } + max(0, CGFloat(visibleLabels.count - 1)) * labelsView.spacing
        let controlHeight = controlView?.fittingSize.height ?? 0
        return ceil(max(minimumHeight, max(labelHeight, controlHeight) + verticalPadding * 2))
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: preferredRowHeight)
    }

    override func layout() {
        super.layout()
        let currentWidth = bounds.width
        let currentHeight = preferredRowHeight
        let changed = abs(currentWidth - lastMeasuredWidth) > 0.5 ||
            abs(currentHeight - lastPreferredHeight) > 0.5
        lastMeasuredWidth = currentWidth
        lastPreferredHeight = currentHeight
        if changed {
            invalidateIntrinsicContentSize()
            cardView?.updateHeightIfNeeded()
        }
    }
}

/// NSTextField keeps the source subtitle separate from the layout string.
/// Semantic groups are converted to non-breaking layout tokens only when the
/// complete group fits on one line; a group wider than the label is left
/// available to the language's normal wrapping rules. Explicit line-break
/// metadata is applied to the layout copy only. The source string therefore
/// remains suitable for accessibility, tests, and later updates.
private final class DashboardSettingsSubtitleLabel: NSTextField {
    private var localizedSubtitle: LocalizedSubtitle?
    private var isApplyingLayoutText = false
    private var lastAppliedWidth: CGFloat = -1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureSubtitleAppearance()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureSubtitleAppearance()
    }

    private func configureSubtitleAppearance() {
        isBezeled = false
        drawsBackground = false
        backgroundColor = .clear
        isEditable = false
        isSelectable = false
    }

    override var stringValue: String {
        didSet {
            guard !isApplyingLayoutText else { return }
            localizedSubtitle = nil
            lastAppliedWidth = -1
        }
    }

    func setLocalizedSubtitle(_ subtitle: LocalizedSubtitle) {
        localizedSubtitle = subtitle
        lastAppliedWidth = -1
        isApplyingLayoutText = true
        super.stringValue = subtitle.text
        isApplyingLayoutText = false
        applyLayoutTextIfNeeded()
        invalidateIntrinsicContentSize()
    }

    override func layout() {
        applyLayoutTextIfNeeded()
        super.layout()
    }

    override var intrinsicContentSize: NSSize {
        applyLayoutTextIfNeeded()
        return super.intrinsicContentSize
    }

    private func applyLayoutTextIfNeeded() {
        guard let localizedSubtitle else { return }
        let width = bounds.width
        guard width > 0 else {
            if super.stringValue != localizedSubtitle.text {
                isApplyingLayoutText = true
                super.stringValue = localizedSubtitle.text
                isApplyingLayoutText = false
            }
            return
        }
        guard abs(width - lastAppliedWidth) > 0.5 || super.stringValue == localizedSubtitle.text else {
            return
        }
        let font = self.font ?? NSFont.systemFont(ofSize: 12)
        let layoutText = DashboardSettingsComponents.subtitleDisplayText(
            localizedSubtitle,
            constrainedTo: width,
            font: font
        )
        guard layoutText != super.stringValue else {
            lastAppliedWidth = width
            return
        }
        isApplyingLayoutText = true
        super.stringValue = layoutText
        isApplyingLayoutText = false
        lastAppliedWidth = width
        invalidateIntrinsicContentSize()
    }
}

private final class DashboardSettingsCardView: NSView {
    weak var rowsStack: NSStackView?
    weak var heightConstraint: NSLayoutConstraint?
    var separators: [NSView] = []
    var rowHeight: ((NSView) -> CGFloat?)?
    // A custom provider owns an animated row's height (for example the
    // Status Links editor) and synchronizes the card explicitly so the
    // surrounding scroll anchors remain stable during that animation.
    var automaticallyUpdatesHeight = true
    private var isUpdatingHeight = false

    override var intrinsicContentSize: NSSize {
        guard let rowsStack, let heightConstraint else {
            return NSSize(width: NSView.noIntrinsicMetric, height: 1)
        }
        guard automaticallyUpdatesHeight else {
            return NSSize(width: NSView.noIntrinsicMetric, height: heightConstraint.constant)
        }
        return NSSize(
            width: NSView.noIntrinsicMetric,
            height: DashboardSettingsComponents.settingsCardHeight(
                rowsStack: rowsStack,
                separators: separators,
                rowHeight: rowHeight
            )
        )
    }

    override func layout() {
        super.layout()
        guard automaticallyUpdatesHeight, !isUpdatingHeight else { return }
        rowsStack?.layoutSubtreeIfNeeded()
        updateHeightIfNeeded()
    }

    func updateHeightIfNeeded() {
        guard automaticallyUpdatesHeight,
              !isUpdatingHeight,
              let rowsStack,
              let heightConstraint else { return }
        let requiredHeight = DashboardSettingsComponents.settingsCardHeight(
            rowsStack: rowsStack,
            separators: separators,
            rowHeight: rowHeight
        )
        guard abs(heightConstraint.constant - requiredHeight) > 0.5 else { return }
        isUpdatingHeight = true
        heightConstraint.constant = requiredHeight
        invalidateIntrinsicContentSize()
        isUpdatingHeight = false
        superview?.needsLayout = true
    }
}

enum DashboardSettingsComponents {
    static let settingsSeparatorHeight: CGFloat = 1

    /// CJK UI copy is naturally breakable between characters. Word wrapping
    /// treats a run without spaces as one large word, which leaves an entire
    /// suffix stranded on the next line even though adaptive row height can
    /// now accommodate the additional line. English keeps word wrapping so
    /// Latin words are never laid out one letter at a time.
    static func settingsSubtitleLineBreakMode(for subtitle: String) -> NSLineBreakMode {
        // Numeric summaries intentionally use non-breaking spaces to keep a
        // descriptor/value group together. Character wrapping would ignore
        // that grouping and could split `0.0 pt` again.
        if subtitle.contains("\u{00A0}") {
            return .byWordWrapping
        }
        switch AppLanguage.resolved {
        case .simplifiedChinese, .traditionalChineseTaiwan, .traditionalChineseHongKong, .japanese, .korean:
            return .byCharWrapping
        case .english, .spanish, .german, .system:
            return .byWordWrapping
        }
    }

    /// Semantic subtitles use word wrapping so AppKit honors the invisible
    /// non-breaking layout tokens inside marked ranges. CJK text still gets
    /// character-boundary opportunities from Unicode's line-break engine;
    /// the marker ranges provide the stronger group-boundary behavior.
    static func settingsSubtitleLineBreakMode(
        for subtitle: LocalizedSubtitle
    ) -> NSLineBreakMode {
        return .byWordWrapping
    }

    /// Builds the text used by AppKit for one subtitle layout pass. The
    /// source ranges come from the localization resource and remain valid for
    /// any language or key that uses the shared semantic marker contract.
    static func subtitleDisplayText(
        _ subtitle: LocalizedSubtitle,
        constrainedTo width: CGFloat,
        font: NSFont
    ) -> String {
        guard width > 0 else { return subtitle.text }
        let source = subtitle.text as NSString
        var replacements: [(range: NSRange, text: String)] = []

        for semanticRange in subtitle.lineBreakBeforeSemanticGroups {
            guard sourceRangeIsValid(semanticRange, in: source),
                  subtitle.semanticGroups.contains(where: { $0 == semanticRange }),
                  let breakRange = lineBreakRange(before: semanticRange, in: source) else {
                continue
            }
            replacements.append((breakRange, "\n"))
        }

        for semanticRange in subtitle.semanticGroups {
            guard sourceRangeIsValid(semanticRange, in: source) else { continue }
            let groupText = source.substring(with: semanticRange)
            let groupWidth = groupText.size(withAttributes: [.font: font]).width
            if groupWidth <= width + 0.5 {
                replacements.append((
                    semanticRange,
                    nonBreakingSemanticText(groupText)
                ))
            } else {
                for atomicRange in subtitle.atomicGroups where contains(
                    semanticRange,
                    inner: atomicRange
                ) {
                    guard sourceRangeIsValid(atomicRange, in: source) else { continue }
                    replacements.append((
                        atomicRange,
                        nonBreakingAtomicText(source.substring(with: atomicRange))
                    ))
                }
            }
        }

        for atomicRange in subtitle.atomicGroups {
            guard sourceRangeIsValid(atomicRange, in: source),
                  !subtitle.semanticGroups.contains(where: {
                      contains($0, inner: atomicRange)
                  }) else {
                continue
            }
            replacements.append((
                atomicRange,
                nonBreakingAtomicText(source.substring(with: atomicRange))
            ))
        }

        guard !replacements.isEmpty else { return subtitle.text }
        let rendered = NSMutableString(string: subtitle.text)
        for replacement in replacements.sorted(by: { lhs, rhs in
            if lhs.range.location == rhs.range.location {
                return lhs.range.length > rhs.range.length
            }
            return lhs.range.location > rhs.range.location
        }) {
            guard replacement.range.location >= 0,
                  NSMaxRange(replacement.range) <= rendered.length else {
                continue
            }
            rendered.replaceCharacters(in: replacement.range, with: replacement.text)
        }
        return rendered as String
    }

    static func makeSubtitleLabel(_ subtitle: LocalizedSubtitle) -> NSTextField {
        let label = DashboardSettingsSubtitleLabel(frame: .zero)
        label.setLocalizedSubtitle(subtitle)
        return label
    }

    static func updateSubtitleLabel(
        _ label: NSTextField?,
        with subtitle: LocalizedSubtitle
    ) {
        if let semanticLabel = label as? DashboardSettingsSubtitleLabel {
            semanticLabel.setLocalizedSubtitle(subtitle)
        } else {
            label?.stringValue = subtitle.text
        }
        label?.invalidateIntrinsicContentSize()
        label?.superview?.needsLayout = true
    }

    private static func sourceRangeIsValid(_ range: NSRange, in source: NSString) -> Bool {
        range.location >= 0 && range.length > 0 && NSMaxRange(range) <= source.length
    }

    private static func contains(_ outer: NSRange, inner: NSRange) -> Bool {
        outer.location <= inner.location && NSMaxRange(inner) <= NSMaxRange(outer)
    }

    private static func lineBreakRange(
        before range: NSRange,
        in source: NSString
    ) -> NSRange? {
        guard range.location > 0 else {
            return NSRange(location: range.location, length: 0)
        }

        let prefix = source.substring(to: range.location)
        var whitespaceLength = 0
        for character in prefix.reversed() {
            guard isSubtitleWhitespace(character) else { break }
            whitespaceLength += character.utf16.count
        }
        if whitespaceLength > 0 {
            return NSRange(
                location: range.location - whitespaceLength,
                length: whitespaceLength
            )
        }
        return NSRange(location: range.location, length: 0)
    }

    private static func nonBreakingSemanticText(_ text: String) -> String {
        let characters = Array(text)
        var result = ""
        for character in characters {
            if !result.isEmpty {
                result.append("\u{2060}")
            }
            if isSubtitleWhitespace(character) {
                result.append("\u{00A0}")
                continue
            }
            result.append(character)
        }
        return result
    }

    private static func nonBreakingAtomicText(_ text: String) -> String {
        let characters = Array(text)
        var result = ""
        for character in characters {
            if !result.isEmpty {
                result.append("\u{2060}")
            }
            if isSubtitleWhitespace(character) {
                result.append("\u{00A0}")
                continue
            }
            result.append(character)
        }
        return result
    }

    private static func isSubtitleWhitespace(_ character: Character) -> Bool {
        character == "\u{00A0}" || character.unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }

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
        let viewportContainer = NSView()
        viewportContainer.translatesAutoresizingMaskIntoConstraints = false
        let scrollView = NSScrollView()
        scrollView.contentView = NSClipView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        // Do not inherit a window/titlebar content inset when a fresh page is
        // mounted. AppKit still owns all user bounds and momentum behavior;
        // this only makes the scroll host's legal top coincide with its
        // document's top edge across window creation and page replacement.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
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
        // Horizontal width belongs to the scroll document, not to whichever
        // arranged section happens to have the widest intrinsic content. This
        // keeps a page stable when rows are hidden or revealed in place.
        stack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.setContentCompressionResistancePriority(.required, for: .horizontal)
        stack.setContentHuggingPriority(.required, for: .vertical)
        stack.setContentCompressionResistancePriority(.required, for: .vertical)
        documentView.addSubview(stack)
        root.addSubview(viewportContainer)
        viewportContainer.addSubview(scrollView)
        // Match the measured titlebar/content-host breathing room without
        // making that space part of the scrollable document.
        let viewportTopInset: CGFloat = 52
        let viewportBottomInset: CGFloat = 0
        NSLayoutConstraint.activate([
            viewportContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            viewportContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            viewportContainer.topAnchor.constraint(equalTo: root.topAnchor, constant: viewportTopInset),
            viewportContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -viewportBottomInset),
            scrollView.leadingAnchor.constraint(equalTo: viewportContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: viewportContainer.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: viewportContainer.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: viewportContainer.bottomAnchor),
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
            section.setContentHuggingPriority(.defaultLow, for: .horizontal)
            section.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        return root
    }

    static func makeSettingsSection(
        _ title: String,
        rows: [NSView],
        separatorIndices: Set<Int>? = nil,
        rowWidthReference: NSView? = nil,
        rowHeight: ((NSView) -> CGFloat?)? = nil,
        onLayoutCreated: ((NSStackView, NSLayoutConstraint, [NSView]) -> Void)? = nil
    ) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        let card = DashboardSettingsCardView()
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
        rowsStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        rowsStack.setContentCompressionResistancePriority(.required, for: .horizontal)
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
            (row as? DashboardSettingsRowView)?.cardView = card
            rowsStack.addArrangedSubview(row)
            if let rowWidthReference, row !== rowWidthReference {
                // Some arranged rows change their intrinsic width when they
                // are hidden and revealed. For pages that opt in, keep every
                // peer tied to the first stable row rather than allowing the
                // visible row's content to choose a new width.
                row.widthAnchor.constraint(equalTo: rowWidthReference.widthAnchor).isActive = true
            } else {
                row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            }
            let hasFollowingRow = index < rows.count - 1
            let shouldInsertSeparator = hasFollowingRow && (separatorIndices?.contains(index) ?? true)
            if shouldInsertSeparator {
                let separator = NSBox()
                separator.boxType = .separator
                separator.heightAnchor.constraint(equalToConstant: settingsSeparatorHeight).isActive = true
                rowsStack.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
                separators.append(separator)
            }
        }

        // NSView has no intrinsic height. Give the card the exact height of
        // its current rows so a short settings page cannot stretch the first
        // row to fill the scroll viewport. The card re-evaluates this value
        // after layout because wrapping labels are width-sensitive, including
        // when a custom provider owns one peer row.
        let cardHeightConstraint = card.heightAnchor.constraint(
            equalToConstant: settingsCardHeight(
                rowsStack: rowsStack,
                separators: separators,
                rowHeight: rowHeight
            )
        )
        // The arranged rows own required minimums. Keep the aggregate card
        // height just below required so a visibility/content transition can
        // pass through one layout transaction without asking AppKit to break
        // a row floor while the stack is converging; the synchronized value
        // remains the exact steady-state height after layout.
        cardHeightConstraint.priority = NSLayoutConstraint.Priority(rawValue: 999)
        cardHeightConstraint.isActive = true
        card.rowsStack = rowsStack
        card.heightConstraint = cardHeightConstraint
        card.separators = separators
        card.rowHeight = rowHeight
        card.setContentHuggingPriority(.required, for: .vertical)
        card.setContentCompressionResistancePriority(.required, for: .vertical)
        card.invalidateIntrinsicContentSize()
        // A custom provider may own one row's height, but it must not disable
        // adaptive remeasurement for the other rows in the same card.
        card.automaticallyUpdatesHeight = true
        onLayoutCreated?(rowsStack, cardHeightConstraint, separators)

        let section = NSStackView(views: [heading, card])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 11
        section.setContentHuggingPriority(.defaultLow, for: .horizontal)
        section.setContentCompressionResistancePriority(.required, for: .horizontal)
        card.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    static func makeSettingsRow(
        _ title: String,
        titleLabel: NSTextField? = nil,
        subtitle: String? = nil,
        subtitleContent: LocalizedSubtitle? = nil,
        subtitleLabel: NSTextField? = nil,
        control: NSView? = nil,
        minimumHeight: CGFloat = 58,
        verticalPadding: CGFloat = 11
    ) -> NSView {
        let row = DashboardSettingsRowView(
            minimumHeight: minimumHeight,
            verticalPadding: verticalPadding
        )
        // Keep a required floor for short rows. The low-priority equality
        // preserves the old compact geometry as a fallback while allowing
        // the row's intrinsic content height to win when a subtitle wraps.
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: row.minimumHeight).isActive = true
        let compactHeightConstraint = row.heightAnchor.constraint(equalToConstant: row.minimumHeight)
        compactHeightConstraint.priority = .defaultLow
        compactHeightConstraint.isActive = true

        let label = titleLabel ?? NSTextField(wrappingLabelWithString: title)
        label.stringValue = title
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.isEditable = false
        label.isSelectable = false
        // Use the same width-sensitive wrapping contract as subtitles. A
        // localized title must yield width to the row's control and contribute
        // its full fitting height instead of keeping a single-line intrinsic
        // width that clips long translations inside the fixed row.
        label.usesSingleLineMode = false
        label.lineBreakMode = Self.settingsSubtitleLineBreakMode(for: title)
        label.maximumNumberOfLines = 0
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let labels = NSStackView(views: [label])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        let subtitleText = subtitleContent?.text ?? subtitle
        if let subtitleText, !subtitleText.isEmpty {
            let detail: NSTextField
            if let subtitleLabel {
                detail = subtitleLabel
            } else if subtitleContent != nil {
                detail = DashboardSettingsSubtitleLabel(frame: .zero)
            } else {
                detail = NSTextField(wrappingLabelWithString: subtitleText)
            }
            if let subtitleContent,
               let semanticLabel = detail as? DashboardSettingsSubtitleLabel {
                semanticLabel.setLocalizedSubtitle(subtitleContent)
            } else {
                detail.stringValue = subtitleText
            }
            detail.font = .systemFont(ofSize: 12)
            detail.textColor = .secondaryLabelColor
            detail.isEditable = false
            detail.isSelectable = false
            // `subtitleLabel` is part of the public row contract. Callers
            // often create it with `labelWithString:` so they can update the
            // summary later; that initializer is single-line/truncating by
            // default. Normalize both supplied and internally-created labels
            // here so every subtitle uses the available row width and can
            // contribute its full fitting height.
            detail.usesSingleLineMode = false
            detail.lineBreakMode = if let subtitleContent {
                Self.settingsSubtitleLineBreakMode(for: subtitleContent)
            } else {
                Self.settingsSubtitleLineBreakMode(for: subtitleText)
            }
            detail.maximumNumberOfLines = 0
            detail.cell?.wraps = true
            detail.cell?.isScrollable = false
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            detail.setContentHuggingPriority(.defaultLow, for: .horizontal)
            labels.addArrangedSubview(detail)
        }
        labels.translatesAutoresizingMaskIntoConstraints = false
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.labelsView = labels
        row.controlView = control
        row.addSubview(labels)
        let padding = max(0, verticalPadding)
        var constraints = [
            labels.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 20),
            labels.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            labels.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: padding),
            labels.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -padding)
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

    static func setSettingsCardAutomaticHeightUpdates(
        for view: NSView,
        enabled: Bool
    ) {
        guard let card = view as? DashboardSettingsCardView else { return }
        card.automaticallyUpdatesHeight = enabled
        if enabled {
            card.needsLayout = true
            card.superview?.needsLayout = true
        }
    }

    static func settingsRowHeight(
        _ row: NSView,
        rowHeight: ((NSView) -> CGFloat?)? = nil
    ) -> CGFloat {
        if let customHeight = rowHeight?(row) {
            return max(1, customHeight)
        }
        if let adaptiveRow = row as? DashboardSettingsRowView {
            return max(1, adaptiveRow.preferredRowHeight)
        }
        let explicitHeight = row.constraints.first {
            ($0.firstItem as? NSView) === row &&
                $0.firstAttribute == .height &&
                $0.relation == .equal &&
                $0.priority == .required
        }?.constant
        return max(1, explicitHeight ?? row.fittingSize.height)
    }

    static func settingsCardHeight(
        rowsStack: NSStackView,
        separators: [NSView],
        rowHeight: ((NSView) -> CGFloat?)? = nil
    ) -> CGFloat {
        let rowsHeight = rowsStack.arrangedSubviews.reduce(CGFloat(0)) { total, row in
            guard !(row is NSBox), !row.isHidden else { return total }
            return total + settingsRowHeight(row, rowHeight: rowHeight)
        }
        let separatorHeight = CGFloat(separators.filter { !$0.isHidden }.count) * settingsSeparatorHeight
        return max(1, ceil(rowsHeight + separatorHeight))
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

/// Settings documents use a top-origin coordinate system. NSScrollView remains
/// the only user-scroll bounds owner.
final class DashboardSettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// Hosts a settings scroll view in a top-origin coordinate system. The class
/// only supplies AppKit's coordinate convention; it does not write bounds or
/// participate in user scrolling.
final class DashboardSettingsPageView: NSView {
    override var isFlipped: Bool { true }
}
