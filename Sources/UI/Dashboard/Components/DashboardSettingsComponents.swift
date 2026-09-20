import AppKit

protocol SettingsRowAccessoryLayout: AnyObject {
    func updateAvailableRowWidth(_ width: CGFloat)
    var allowsTextDrivenDedicatedRow: Bool { get }
    /// Minimum width the labels column needs to remain beside this accessory.
    /// Zero means the accessory never requests a dedicated row for label space.
    var minimumInlineLabelWidth: CGFloat { get }
    /// Uncompressed width of the accessory in its current orientation.
    /// Horizontal: sum of children natural widths + spacing.
    /// Vertical: max of children natural widths.
    var naturalAccessoryWidth: CGFloat { get }
}

extension SettingsRowAccessoryLayout {
    var allowsTextDrivenDedicatedRow: Bool { false }
}

/// Compatibility rows stack for `makeSettingsSection`. Production pages use
/// `SettingsSectionView`; this keeps the older factory's live card-height
/// constraint in sync with visible row intrinsic height so a window-sized
/// contentView cannot stretch the first row.
private final class CompatibilitySettingsRowsStackView: NSStackView {
    var cardHeightConstraint: NSLayoutConstraint?
    var separators: [NSView] = []
    var rowHeight: ((NSView) -> CGFloat?)?

    override func layout() {
        super.layout()
        syncCardHeight(relayout: false)
    }

    func syncCardHeight(relayout: Bool = true) {
        guard let constraint = cardHeightConstraint else { return }
        let height = DashboardSettingsComponents.settingsSectionIntrinsicHeight(
            rowsStack: self,
            separators: separators,
            rowHeight: rowHeight,
            relayout: relayout
        )
        guard height > 0, abs(constraint.constant - height) > 0.5 else { return }
        constraint.constant = height
    }
}

enum DashboardSettingsLayoutMetrics {
    /// Always-0 sentinels. The legacy preferred-row-height, wrapping-cache,
    /// card-height, and control-fitting engines have been removed; these
    /// counters exist so tests can prove those paths no longer run.
    static var textLineMeasurements = 0
    static var preferredHeightMeasurements = 0
    static var cardHeightMeasurements = 0
    static var controlFittingMeasurements = 0

    static func reset() {
        textLineMeasurements = 0
        preferredHeightMeasurements = 0
        cardHeightMeasurements = 0
        controlFittingMeasurements = 0
    }
}

enum DashboardSettingsComponents {
    static func invalidateHostedSettingsRowHeight(for view: NSView) {
        view.invalidateIntrinsicContentSize()
        view.needsLayout = true
        view.superview?.invalidateIntrinsicContentSize()
        view.superview?.needsLayout = true
    }
    static let settingsSeparatorHeight: CGFloat = 1
    static let standardRowHeight: CGFloat = 62
    static let settingsRowContentControlSpacing: CGFloat = 12
    // This is an inclusive placement budget, not a text truncation limit.
    // Text fields remain uncapped; a fifth natural line moves the control
    // below the complete content.
    static let settingsTextLineReflowThreshold = 4
    static let settingsTitleMaximumNumberOfLines = 0
    static let settingsSubtitleMaximumNumberOfLines = 0

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
        case .english, .spanish, .german, .french, .portuguese, .russian, .italian, .system:
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
        let label = SettingsSemanticSubtitleLabel(frame: .zero)
        label.setLocalizedSubtitle(subtitle)
        return label
    }

    static func updateSubtitleLabel(
        _ label: NSTextField?,
        with subtitle: LocalizedSubtitle
    ) {
        if let semanticLabel = label as? SettingsSemanticSubtitleLabel {
            semanticLabel.setLocalizedSubtitle(subtitle)
        } else {
            label?.stringValue = subtitle.text
        }
        label?.invalidateIntrinsicContentSize()
        label?.superview?.needsLayout = true
        notifySettingsRowContentChanged(label)
    }

    static func notifySettingsRowContentChanged(_ view: NSView?) {
        var ancestor = view
        while let current = ancestor {
            if let row = current as? SettingsRowView {
                row.invalidateAfterContentChange()
                return
            }
            ancestor = current.superview
        }
        view?.invalidateIntrinsicContentSize()
        view?.needsLayout = true
        view?.superview?.needsLayout = true
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

    /// Settings sections stack only. Page-level `NSScrollView` chrome, the
    /// 52pt viewport inset, and the 34pt document width contract belong to
    /// `DashboardScrollablePageViewController`.
    static func makeSettingsPageContent(_ sections: [NSView]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 28
        stack.distribution = .gravityAreas
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Horizontal width belongs to the scroll document, not to whichever
        // arranged section happens to have the widest intrinsic content. This
        // keeps a page stable when rows are hidden or revealed in place.
        stack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.setContentCompressionResistancePriority(.required, for: .horizontal)
        stack.setContentHuggingPriority(.required, for: .vertical)
        stack.setContentCompressionResistancePriority(.required, for: .vertical)
        stack.setHuggingPriority(.required, for: .vertical)
        stack.setClippingResistancePriority(.required, for: .vertical)
        for section in sections {
            // Top gravity keeps leftover height below the last card instead of
            // opening a gravity gap between sections.
            stack.addView(section, in: .top)
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            section.setContentHuggingPriority(.defaultLow, for: .horizontal)
            section.setContentCompressionResistancePriority(.required, for: .horizontal)
            section.setContentHuggingPriority(.required, for: .vertical)
            section.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        return stack
    }

    /// Compatibility facade for tests that still assemble a complete page view
    /// without a page controller. Production pages wrap
    /// `makeSettingsPageContent` in `DashboardScrollablePageViewController`.
    static func makeSettingsPage(_ sections: [NSView]) -> NSView {
        DashboardScrollablePageViewController.makePageView(
            hosting: makeSettingsPageContent(sections)
        )
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
        heading.font = SettingsSectionView.headingFont
        heading.setContentHuggingPriority(.required, for: .vertical)
        heading.setContentCompressionResistancePriority(.required, for: .vertical)
        let headingMinHeight = ceil(SettingsSectionView.headingFont.boundingRectForFont.height)
        heading.heightAnchor.constraint(greaterThanOrEqualToConstant: headingMinHeight).isActive = true

        let card = SettingsSectionCardView()
        card.detachesHiddenViews = true
        card.setContentHuggingPriority(.required, for: .vertical)
        card.setContentCompressionResistancePriority(.required, for: .vertical)

        let rowsStack = CompatibilitySettingsRowsStackView()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.distribution = .fill
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.detachesHiddenViews = true
        rowsStack.setContentHuggingPriority(.required, for: .vertical)
        rowsStack.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        rowsStack.rowHeight = rowHeight
        card.addSubview(rowsStack)
        NSLayoutConstraint.activate([
            rowsStack.topAnchor.constraint(equalTo: card.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])
        // Exact content height, not a circular card==stack equality. A
        // window-sized contentView would otherwise stretch the first row.
        let cardHeightConstraint = card.heightAnchor.constraint(equalToConstant: 0)
        cardHeightConstraint.priority = NSLayoutConstraint.Priority(rawValue: 999)
        cardHeightConstraint.isActive = true
        rowsStack.cardHeightConstraint = cardHeightConstraint

        var separators: [NSView] = []
        for (index, row) in rows.enumerated() {
            row.translatesAutoresizingMaskIntoConstraints = false
            row.setContentHuggingPriority(.required, for: .vertical)
            row.setContentCompressionResistancePriority(.required, for: .vertical)
            rowsStack.addArrangedSubview(row)
            if let rowWidthReference, row !== rowWidthReference {
                row.widthAnchor.constraint(equalTo: rowWidthReference.widthAnchor).isActive = true
            } else {
                row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            }
            let hasFollowingRow = index < rows.count - 1
            let shouldInsertSeparator = hasFollowingRow
                && (separatorIndices?.contains(index) ?? true)
            if shouldInsertSeparator {
                let separator = NSBox()
                separator.boxType = .separator
                separator.translatesAutoresizingMaskIntoConstraints = false
                separator.heightAnchor.constraint(equalToConstant: settingsSeparatorHeight).isActive = true
                rowsStack.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
                separators.append(separator)
            }
        }
        rowsStack.separators = separators
        rowsStack.syncCardHeight()

        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = SettingsSectionView.headingToCardSpacing
        section.distribution = .gravityAreas
        section.setContentHuggingPriority(.defaultLow, for: .horizontal)
        section.setContentCompressionResistancePriority(.required, for: .horizontal)
        section.setContentHuggingPriority(.required, for: .vertical)
        section.setContentCompressionResistancePriority(.required, for: .vertical)
        section.setHuggingPriority(.required, for: .vertical)
        section.setClippingResistancePriority(.required, for: .vertical)
        section.identifier = DashboardPageSearch.sectionIdentifier
        section.addView(heading, in: .top)
        section.addView(card, in: .top)
        card.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        onLayoutCreated?(rowsStack, cardHeightConstraint, separators)
        return section
    }

    static func makeSettingsRow(
        _ title: String,
        titleLabel: NSTextField? = nil,
        subtitle: String? = nil,
        subtitleContent: LocalizedSubtitle? = nil,
        subtitleLabel: NSTextField? = nil,
        titleAccessory: NSView? = nil,
        headerTrailingAccessory: NSView? = nil,
        trailingControl: NSView? = nil,
        control: NSView? = nil,
        minimumHeight: CGFloat = 58,
        verticalPadding: CGFloat = 11,
        forceDedicatedControlRow: Bool = false
    ) -> NSView {
        let accessory = control ?? trailingControl ?? headerTrailingAccessory
        let detail = subtitle ?? subtitleContent?.text
        let suppliedDetailLabel: NSTextField?
        if let subtitleLabel {
            if let subtitleContent {
                if let semanticLabel = subtitleLabel as? SettingsSemanticSubtitleLabel {
                    semanticLabel.setLocalizedSubtitle(subtitleContent)
                } else if subtitleLabel.stringValue.isEmpty {
                    subtitleLabel.stringValue = subtitleContent.text
                }
            }
            suppliedDetailLabel = subtitleLabel
        } else if let subtitleContent {
            suppliedDetailLabel = makeSubtitleLabel(subtitleContent)
        } else {
            suppliedDetailLabel = nil
        }
        return SettingsRowView(
            title: title,
            detail: detail,
            titleLabel: titleLabel,
            detailLabel: suppliedDetailLabel,
            titleAccessory: titleAccessory,
            accessoryView: accessory,
            minimumHeight: minimumHeight,
            verticalPadding: verticalPadding,
            forceDedicatedControlRow: forceDedicatedControlRow
        )
    }

    static func settingsSectionIntrinsicHeight(
        rowsStack: NSStackView,
        separators: [NSView],
        rowHeight: ((NSView) -> CGFloat?)? = nil,
        relayout: Bool = true
    ) -> CGFloat {
        if relayout {
            rowsStack.layoutSubtreeIfNeeded()
        }
        let rowsHeight = rowsStack.arrangedSubviews.reduce(CGFloat(0)) { total, row in
            guard !(row is NSBox),
                  !row.isHidden,
                  !DashboardSearchVisibility.isCollapsedForSearchLayout(row)
            else { return total }
            if let customHeight = rowHeight?(row) {
                return total + max(1, customHeight)
            }
            if let nativeRow = row as? SettingsRowView {
                return total + nativeRow.hostedCardHeight()
            }
            let frameHeight = row.frame.height
            if frameHeight > 1 {
                return total + frameHeight
            }
            return total + standardRowHeight
        }
        let separatorHeight = CGFloat(separators.filter { !$0.isHidden }.count) * settingsSeparatorHeight
        return max(0, ceil(rowsHeight + separatorHeight))
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

    /// Shared compact numeric editor for Dashboard settings.
    ///
    /// The primitive owns the AppKit visual contract: `NSTextField(string:)`,
    /// small `controlSize`, rounded bezel, and monospaced digits at
    /// `NSFont.systemFontSize(for: .small)`. Callers keep value semantics,
    /// validation, and any field-specific width. Height comes from the cell's
    /// intrinsic size; this factory never installs a height constraint.
    static func makeNumericTextField(
        identifier: String? = nil,
        value: String? = nil,
        placeholder: String? = nil,
        width: CGFloat? = nil,
        delegate: NSTextFieldDelegate? = nil,
        target: AnyObject? = nil,
        action: Selector? = nil,
        toolTip: String? = nil
    ) -> NSTextField {
        let field = NSTextField(string: value ?? "")
        if let identifier {
            field.identifier = NSUserInterfaceItemIdentifier(identifier)
        }
        field.placeholderString = placeholder
        field.controlSize = .small
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.font = .monospacedDigitSystemFont(
            ofSize: NSFont.systemFontSize(for: .small),
            weight: .regular
        )
        field.alignment = .right
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byClipping
        field.focusRingType = .default
        field.delegate = delegate
        field.target = target
        field.action = action
        field.toolTip = toolTip
        if let width {
            field.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        field.setContentHuggingPriority(.required, for: .horizontal)
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        return field
    }

    static func disconnectPopUpButtonActions(in view: NSView?) {
        guard let view else { return }
        if let popup = view as? NSPopUpButton {
            popup.target = nil
            popup.action = nil
        }
        for subview in view.subviews {
            disconnectPopUpButtonActions(in: subview)
        }
    }

    static func makePopUpButton(
        identifier: String? = nil,
        items: [PopUpItem],
        selectedIndex: Int? = nil,
        target: AnyObject?,
        action: Selector?,
        ignoresScrollWheel: Bool = false
    ) -> NSPopUpButton {
        let popup = DashboardSettingsPopUpButton(frame: .zero, pullsDown: false)
        popup.ignoresScrollWheel = ignoresScrollWheel
        if let identifier {
            popup.identifier = NSUserInterfaceItemIdentifier(identifier)
        }
        for (index, item) in items.enumerated() {
            popup.addItem(withTitle: item.title)
            popup.item(at: index)?.representedObject = item.representedObject
        }
        if let selectedIndex {
            popup.selectItem(at: selectedIndex)
        }
        // Bind after the initial selection so programmatic selectItem cannot
        // deliver a leftover action from the previous language.
        popup.target = target
        popup.action = action
        return popup
    }

    static func makeIntervalPopUpButton(
        values: [(Double, String)],
        selected: TimeInterval,
        identifier: String,
        target: AnyObject?,
        action: Selector?
    ) -> NSPopUpButton {
        let popup = makePopUpButton(
            identifier: identifier,
            items: values.map { PopUpItem(
                title: $0.1,
                representedObject: NSNumber(value: $0.0)
            ) },
            selectedIndex: values.firstIndex { abs($0.0 - selected) < 0.001 },
            target: target,
            action: action
        )
        // A fixed 108pt width fits the English and German interval labels but
        // truncates longer localized values such as French "Toutes les 10 s"
        // and Spanish "Durante 30 s". AppKit already measures the complete
        // popup item set, so retain the compact minimum when it is sufficient
        // and grow only the controls whose localized titles need more room.
        // Paired controls can add a required equal-width constraint afterward
        // so their labels share one right-aligned column.
        let compactWidth: CGFloat = 108
        let localizedWidth = ceil(popup.fittingSize.width)
        popup.widthAnchor.constraint(greaterThanOrEqualToConstant: max(compactWidth, localizedWidth)).isActive = true
        return popup
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

/// NSPopUpButton changes the selected item on scroll-wheel. Language must not
/// persist unless the user actually chose a menu item.
final class DashboardSettingsPopUpButton: NSPopUpButton {
    var ignoresScrollWheel = false

    override func scrollWheel(with event: NSEvent) {
        guard ignoresScrollWheel else {
            super.scrollWheel(with: event)
            return
        }
        nextResponder?.scrollWheel(with: event)
    }
}
