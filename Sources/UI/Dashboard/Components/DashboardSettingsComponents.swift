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

    /// Amount editors (low-balance threshold). Fits `10000.00` at regular cell size.
    static let amountCapacityTemplate = "00000.00"
    /// FPS editors. Legal values are two digits (`6...30`).
    static let frameRateCapacityTemplate = "00"

    /// SettingsRow-safe accessory around a compact numeric `NSTextField`.
    /// `SettingsRowView` may lower this stack's vertical hugging; the inner
    /// field keeps `.required` so the cell is not stretched to the row height.
    /// Owns the completion-suppressing delegate wrapper because
    /// `NSTextField.delegate` is weak.
    final class CompactNumericFieldAccessory: NSStackView {
        let field: NSTextField
        let capacityTemplate: String
        fileprivate let numericEditingDelegate: CompactNumericFieldDelegate

        fileprivate init(
            field: NSTextField,
            capacityTemplate: String,
            trailingViews: [NSView],
            externalDelegate: NSTextFieldDelegate?
        ) {
            self.field = field
            self.capacityTemplate = capacityTemplate
            self.numericEditingDelegate = CompactNumericFieldDelegate(
                externalDelegate: externalDelegate
            )
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            orientation = .horizontal
            alignment = .centerY
            spacing = trailingViews.isEmpty ? 0 : 6
            setContentHuggingPriority(.required, for: .horizontal)
            setContentHuggingPriority(.required, for: .vertical)
            setContentCompressionResistancePriority(.required, for: .horizontal)
            setContentCompressionResistancePriority(.required, for: .vertical)
            field.delegate = numericEditingDelegate
            addArrangedSubview(field)
            for view in trailingViews {
                addArrangedSubview(view)
            }
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }

    /// Intercepts field-editor completion without replacing page delegates.
    /// `NSTextFieldCell` has no `completes` in the current SDK; only
    /// `NSComboBoxCell` does. Completion is disabled on the field and on
    /// this editing session's shared field editor.
    fileprivate final class CompactNumericFieldDelegate: NSObject, NSTextFieldDelegate {
        weak var externalDelegate: NSTextFieldDelegate?
        private var storedFieldEditorPolicy: NumericFieldEditorPolicy?
        private weak var configuredFieldEditor: NSTextView?

        init(externalDelegate: NSTextFieldDelegate?) {
            self.externalDelegate = externalDelegate
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            if let field = notification.object as? NSTextField,
               let textView = field.currentEditor() as? NSTextView {
                applyNumericFieldEditorPolicy(to: textView)
            }
            externalDelegate?.controlTextDidBeginEditing?(notification)
        }

        func controlTextDidChange(_ notification: Notification) {
            externalDelegate?.controlTextDidChange?(notification)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            if let field = notification.object as? NSTextField {
                if let textView = field.currentEditor() as? NSTextView {
                    restoreNumericFieldEditorPolicy(on: textView)
                }
                acceptPlaceholderIfFieldIsEmpty(field)
            }
            externalDelegate?.controlTextDidEndEditing?(notification)
        }

        func control(_ control: NSControl, textShouldBeginEditing fieldEditor: NSText) -> Bool {
            if let textView = fieldEditor as? NSTextView {
                applyNumericFieldEditorPolicy(to: textView)
            }
            return externalDelegate?.control?(control, textShouldBeginEditing: fieldEditor) ?? true
        }

        func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
            let allowed = externalDelegate?.control?(
                control,
                textShouldEndEditing: fieldEditor
            ) ?? true
            if allowed, let textView = fieldEditor as? NSTextView {
                restoreNumericFieldEditorPolicy(on: textView)
            }
            return allowed
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            completions words: [String],
            forPartialWordRange charRange: NSRange,
            indexOfSelectedItem index: UnsafeMutablePointer<Int>
        ) -> [String] {
            index.pointee = -1
            return []
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.complete(_:)) {
                return true
            }
            if externalDelegate?.control?(
                control,
                textView: textView,
                doCommandBy: commandSelector
            ) == true {
                return true
            }
            return false
        }

        func textField(
            _ textField: NSTextField,
            textView: NSTextView,
            candidatesForSelectedRange selectedRange: NSRange
        ) -> [Any]? {
            []
        }

        func textField(
            _ textField: NSTextField,
            textView: NSTextView,
            candidates: [NSTextCheckingResult],
            forSelectedRange selectedRange: NSRange
        ) -> [NSTextCheckingResult] {
            []
        }

        func textField(
            _ textField: NSTextField,
            textView: NSTextView,
            shouldSelectCandidateAt index: Int
        ) -> Bool {
            false
        }

        private func applyNumericFieldEditorPolicy(to textView: NSTextView) {
            if storedFieldEditorPolicy == nil {
                storedFieldEditorPolicy = NumericFieldEditorPolicy(textView)
                configuredFieldEditor = textView
            }
            textView.isAutomaticTextCompletionEnabled = false
            textView.isAutomaticSpellingCorrectionEnabled = false
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.isAutomaticTextReplacementEnabled = false
            textView.isContinuousSpellCheckingEnabled = false
            textView.isGrammarCheckingEnabled = false
            textView.isAutomaticDataDetectionEnabled = false
            textView.isAutomaticLinkDetectionEnabled = false
            textView.smartInsertDeleteEnabled = false
            textView.inlinePredictionType = .no
            if #available(macOS 15.0, *) {
                textView.mathExpressionCompletionType = .no
                textView.writingToolsBehavior = .none
            }
        }

        private func restoreNumericFieldEditorPolicy(on textView: NSTextView) {
            guard configuredFieldEditor === textView,
                  let policy = storedFieldEditorPolicy else {
                return
            }
            policy.apply(to: textView)
            storedFieldEditorPolicy = nil
            configuredFieldEditor = nil
        }

        /// An empty numeric field shows a gray placeholder. Tab / focus loss
        /// should commit that placeholder, not restore the previous value.
        private func acceptPlaceholderIfFieldIsEmpty(_ field: NSTextField) {
            let current = (field.currentEditor()?.string ?? field.stringValue)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard current.isEmpty,
                  let placeholder = field.placeholderString?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !placeholder.isEmpty else {
                return
            }
            field.currentEditor()?.string = placeholder
            field.stringValue = placeholder
        }
    }

    /// Snapshot of window-shared field-editor traits so numeric editing
    /// does not leak disabled completion into the next control.
    fileprivate struct NumericFieldEditorPolicy {
        var isAutomaticTextCompletionEnabled: Bool
        var isAutomaticSpellingCorrectionEnabled: Bool
        var isAutomaticQuoteSubstitutionEnabled: Bool
        var isAutomaticDashSubstitutionEnabled: Bool
        var isAutomaticTextReplacementEnabled: Bool
        var isContinuousSpellCheckingEnabled: Bool
        var isGrammarCheckingEnabled: Bool
        var isAutomaticDataDetectionEnabled: Bool
        var isAutomaticLinkDetectionEnabled: Bool
        var smartInsertDeleteEnabled: Bool
        var inlinePredictionType: NSTextInputTraitType
        var mathExpressionCompletionTypeRaw: Int?
        var writingToolsBehaviorRaw: Int?

        init(_ textView: NSTextView) {
            isAutomaticTextCompletionEnabled = textView.isAutomaticTextCompletionEnabled
            isAutomaticSpellingCorrectionEnabled = textView.isAutomaticSpellingCorrectionEnabled
            isAutomaticQuoteSubstitutionEnabled = textView.isAutomaticQuoteSubstitutionEnabled
            isAutomaticDashSubstitutionEnabled = textView.isAutomaticDashSubstitutionEnabled
            isAutomaticTextReplacementEnabled = textView.isAutomaticTextReplacementEnabled
            isContinuousSpellCheckingEnabled = textView.isContinuousSpellCheckingEnabled
            isGrammarCheckingEnabled = textView.isGrammarCheckingEnabled
            isAutomaticDataDetectionEnabled = textView.isAutomaticDataDetectionEnabled
            isAutomaticLinkDetectionEnabled = textView.isAutomaticLinkDetectionEnabled
            smartInsertDeleteEnabled = textView.smartInsertDeleteEnabled
            inlinePredictionType = textView.inlinePredictionType
            if #available(macOS 15.0, *) {
                mathExpressionCompletionTypeRaw = textView.mathExpressionCompletionType.rawValue
                writingToolsBehaviorRaw = textView.writingToolsBehavior.rawValue
            }
        }

        func apply(to textView: NSTextView) {
            textView.isAutomaticTextCompletionEnabled = isAutomaticTextCompletionEnabled
            textView.isAutomaticSpellingCorrectionEnabled = isAutomaticSpellingCorrectionEnabled
            textView.isAutomaticQuoteSubstitutionEnabled = isAutomaticQuoteSubstitutionEnabled
            textView.isAutomaticDashSubstitutionEnabled = isAutomaticDashSubstitutionEnabled
            textView.isAutomaticTextReplacementEnabled = isAutomaticTextReplacementEnabled
            textView.isContinuousSpellCheckingEnabled = isContinuousSpellCheckingEnabled
            textView.isGrammarCheckingEnabled = isGrammarCheckingEnabled
            textView.isAutomaticDataDetectionEnabled = isAutomaticDataDetectionEnabled
            textView.isAutomaticLinkDetectionEnabled = isAutomaticLinkDetectionEnabled
            textView.smartInsertDeleteEnabled = smartInsertDeleteEnabled
            textView.inlinePredictionType = inlinePredictionType
            if #available(macOS 15.0, *) {
                if let mathExpressionCompletionTypeRaw,
                   let mathType = NSTextInputTraitType(rawValue: mathExpressionCompletionTypeRaw) {
                    textView.mathExpressionCompletionType = mathType
                }
                if let writingToolsBehaviorRaw,
                   let writingTools = NSWritingToolsBehavior(rawValue: writingToolsBehaviorRaw) {
                    textView.writingToolsBehavior = writingTools
                }
            }
        }
    }

    /// Compact numeric editor: `NSTextField(string:)`, regular `controlSize`,
    /// rounded bezel, monospaced digits at `NSFont.systemFontSize(for: .regular)`.
    /// Width is `NSCell.cellSize` of `capacityTemplate`, not the current value.
    /// Overflow and the caret scroll inside the cell (`isScrollable`,
    /// `wraps == false`); AppKit pairs that with clipping instead of wrapping.
    /// Height comes from the cell; this factory never installs a height
    /// constraint or a screenshot width. Tab commits the current string; an
    /// empty field commits `placeholderString` before page validation. The
    /// shared field editor's text completion / inline prediction is off for
    /// this editing session only. The returned stack is the accessory.
    static func makeNumericTextField(
        identifier: String? = nil,
        value: String? = nil,
        placeholder: String? = nil,
        capacityTemplate: String,
        trailingViews: [NSView] = [],
        delegate: NSTextFieldDelegate? = nil,
        target: AnyObject? = nil,
        action: Selector? = nil,
        toolTip: String? = nil
    ) -> CompactNumericFieldAccessory {
        let field = NSTextField(string: value ?? "")
        if let identifier {
            field.identifier = NSUserInterfaceItemIdentifier(identifier)
        }
        field.placeholderString = placeholder
        field.controlSize = .regular
        field.cell?.controlSize = .regular
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.font = .monospacedDigitSystemFont(
            ofSize: NSFont.systemFontSize(for: .regular),
            weight: .regular
        )
        field.alignment = .right
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.isAutomaticTextCompletionEnabled = false
        field.allowsCharacterPickerTouchBarItem = false
        field.focusRingType = .default
        field.toolTip = toolTip
        field.translatesAutoresizingMaskIntoConstraints = false
        let compactWidth = compactNumericWidth(for: field, capacityTemplate: capacityTemplate)
        field.widthAnchor.constraint(equalToConstant: compactWidth).isActive = true
        field.setContentHuggingPriority(.required, for: .horizontal)
        field.setContentHuggingPriority(.required, for: .vertical)
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        field.target = target
        field.action = action
        return CompactNumericFieldAccessory(
            field: field,
            capacityTemplate: capacityTemplate,
            trailingViews: trailingViews,
            externalDelegate: delegate
        )
    }

    /// Width AppKit needs to draw `capacityTemplate` in this field's cell,
    /// including bezel chrome. Independent of the live `stringValue`.
    static func compactNumericWidth(
        for field: NSTextField,
        capacityTemplate: String
    ) -> CGFloat {
        let original = field.stringValue
        field.stringValue = capacityTemplate
        let width = ceil(field.cell?.cellSize.width ?? 0)
        field.stringValue = original
        return width
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
