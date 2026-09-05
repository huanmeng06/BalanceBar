import AppKit

protocol DashboardSettingsRowControlLayout: AnyObject {
    func updateAvailableRowWidth(_ width: CGFloat)
    var usesDedicatedRow: Bool { get }
    var allowsTextDrivenDedicatedRow: Bool { get }
}

enum DashboardSettingsLayoutMetrics {
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

private enum DashboardSettingsControlPlacement: Equatable {
    case horizontal
    case verticalBesideContent
    case dedicatedRow
}

private struct DashboardSettingsWrappingKey: Equatable {
    var text: String
    var fontName: String
    var fontSize: CGFloat
    var lineBreakMode: NSLineBreakMode
    var lineBreakStrategy: NSParagraphStyle.LineBreakStrategy

    init(_ textField: NSTextField) {
        text = textField.stringValue
        let font = textField.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        fontName = font.fontName
        fontSize = font.pointSize
        lineBreakMode = textField.lineBreakMode
        if #available(macOS 10.15, *) {
            lineBreakStrategy = textField.lineBreakStrategy
        } else {
            lineBreakStrategy = .standard
        }
    }
}

private struct DashboardSettingsWrappingCache {
    private var key: DashboardSettingsWrappingKey?
    private var ranges: [(min: CGFloat, max: CGFloat, count: Int)] = []

    mutating func invalidate() {
        key = nil
        ranges.removeAll(keepingCapacity: true)
    }

    mutating func lineCount(for textField: NSTextField, width: CGFloat) -> Int {
        let nextKey = DashboardSettingsWrappingKey(textField)
        if key != nextKey {
            invalidate()
            key = nextKey
        }
        if textField.stringValue.isEmpty || width <= 0 {
            return 0
        }
        if let cached = ranges.first(where: { width + 0.5 >= $0.min && width - 0.5 <= $0.max }) {
            return cached.count
        }
        let lower = ranges.filter { $0.max <= width + 0.5 }.max { $0.max < $1.max }
        let upper = ranges.filter { $0.min + 0.5 >= width }.min { $0.min < $1.min }
        if let lower, let upper, lower.count == upper.count {
            ranges.append((min: lower.max, max: upper.min, count: lower.count))
            mergeRanges()
            return lower.count
        }
        let measurement = DashboardSettingsComponents.measureTextLineLayout(
            textField,
            constrainedTo: width
        )
        if measurement.count <= 1 {
            let floorWidth = max(1, measurement.usedWidth)
            ranges.append((min: floorWidth, max: .greatestFiniteMagnitude, count: max(measurement.count, 1)))
        } else {
            ranges.append((min: width, max: width, count: measurement.count))
        }
        mergeRanges()
        return measurement.count
    }

    private mutating func mergeRanges() {
        guard ranges.count > 1 else { return }
        ranges.sort { $0.min < $1.min }
        var merged: [(min: CGFloat, max: CGFloat, count: Int)] = [ranges[0]]
        for range in ranges.dropFirst() {
            var last = merged[merged.count - 1]
            if last.count == range.count && range.min <= last.max + 1 {
                last.max = max(last.max, range.max)
                merged[merged.count - 1] = last
            } else {
                merged.append(range)
            }
        }
        ranges = merged
    }
}

private struct DashboardSettingsRowContentIdentity: Equatable {
    var title: String
    var subtitle: String
    var titleHidden: Bool
    var subtitleHidden: Bool
    var titleFontName: String
    var subtitleFontName: String
    var titleLineBreak: NSLineBreakMode
    var subtitleLineBreak: NSLineBreakMode
    var controlHidden: Bool
    var controlKind: String
    var controlTitle: String
    var forceDedicated: Bool
}

private final class DashboardSettingsRowView: NSView {
    var forceDedicatedControlRow = false
    let minimumHeight: CGFloat
    let verticalPadding: CGFloat
    weak var labelsView: NSStackView?
    weak var controlView: NSView?
    weak var cardView: DashboardSettingsCardView?
    weak var titleTextField: NSTextField?
    weak var subtitleTextField: NSTextField?
    private var lastMeasuredWidth: CGFloat = -1
    private var lastPreferredHeight: CGFloat = -1
    private var lastContentIdentity: DashboardSettingsRowContentIdentity?
    private var lastAdaptiveUsesDedicatedRow = false
    private var cachedPreferredHeight: CGFloat?
    private var cachedControlFittingSize: NSSize?
    private var cachedMinimumReadableWidth: CGFloat?
    private var cachedTitleSiblingWidth: CGFloat?
    private var titleWrappingCache = DashboardSettingsWrappingCache()
    private var subtitleWrappingCache = DashboardSettingsWrappingCache()
    private var controlPlacement: DashboardSettingsControlPlacement = .horizontal
    private var sideBySideControlConstraints: [NSLayoutConstraint] = []
    private var dedicatedControlConstraints: [NSLayoutConstraint] = []

    init(
        minimumHeight: CGFloat,
        verticalPadding: CGFloat
    ) {
        self.minimumHeight = max(DashboardSettingsComponents.standardRowHeight, minimumHeight)
        self.verticalPadding = max(0, verticalPadding)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isHidden: Bool {
        didSet {
            guard isHidden != oldValue else { return }
            cardView?.markHeightDirty()
        }
    }

    var preferredRowHeight: CGFloat {
        guard labelsView != nil, bounds.width > 0 else { return minimumHeight }
        refreshContentIdentityIfNeeded()
        invalidateHeightCacheIfWidthRequiresMeasurement(bounds.width)
        if let cachedPreferredHeight {
            return cachedPreferredHeight
        }
        return measurePreferredRowHeight()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: preferredRowHeight)
    }

    override func layout() {
        refreshContentIdentityIfNeeded()
        invalidateHeightCacheIfWidthRequiresMeasurement(bounds.width)
        // Plain composite stacks own their internal alignment (for example a
        // slider with endpoint labels). Leave them on the existing centered
        // path; stacks that explicitly conform to the adaptive contract still
        // receive their normal row-width update below.
        if let controlView,
           !(controlView is NSStackView && !(controlView is DashboardSettingsRowControlLayout)) {
            let availableContentAndControlWidth = max(0, bounds.width - 40)
            let adaptiveControl = controlView as? DashboardSettingsRowControlLayout
            adaptiveControl?.updateAvailableRowWidth(availableContentAndControlWidth)
            let usesDedicated = adaptiveControl?.usesDedicatedRow == true
            if usesDedicated != lastAdaptiveUsesDedicatedRow {
                lastAdaptiveUsesDedicatedRow = usesDedicated
                cachedControlFittingSize = nil
                cachedPreferredHeight = nil
            }
            let actionWidth = controlFittingSize().width
            let contentWidthWhenHorizontal = max(
                0,
                availableContentAndControlWidth - actionWidth - 20
            )
            let readableContentWidth = cachedMinimumReadableWidth ?? measuredMinimumReadableContentWidth()
            // Keep the controls' own fitting/orientation contract. Ordinary
            // row controls and explicitly opted-in adaptive controls may move
            // below the text once the natural text reaches the threshold;
            // other composite controls keep their existing placement rules.
            let supportsTextDrivenDedicatedRow = !(controlView is NSStackView) ||
                adaptiveControl?.allowsTextDrivenDedicatedRow == true
            // Measure the line budget at the width the labels actually get
            // while the controls remain beside them. Once that inline text
            // reaches the threshold, move the controls below the complete
            // labels; the labels themselves stay uncapped and can use the
            // newly available width in the dedicated layout.
            let lineBudgetNeedsDedicatedRow = supportsTextDrivenDedicatedRow &&
                textNeedsDedicatedRow(at: contentWidthWhenHorizontal)
            let contentNeedsDedicatedRow = contentWidthWhenHorizontal + 0.5 < readableContentWidth ||
                lineBudgetNeedsDedicatedRow
            let placement: DashboardSettingsControlPlacement
            if forceDedicatedControlRow || contentNeedsDedicatedRow {
                placement = .dedicatedRow
            } else if usesDedicated {
                placement = .verticalBesideContent
            } else {
                placement = .horizontal
            }
            updateControlPlacementIfNeeded(placement)
        }
        super.layout()
        let currentWidth = bounds.width
        let currentHeight = preferredRowHeight
        let heightChanged = abs(currentHeight - lastPreferredHeight) > 0.5
        lastMeasuredWidth = currentWidth
        lastPreferredHeight = currentHeight
        if heightChanged {
            invalidateIntrinsicContentSize()
            cardView?.markHeightDirty()
            cardView?.updateHeightIfNeeded()
        }
    }

    private func refreshContentIdentityIfNeeded() {
        let identity = currentContentIdentity()
        guard identity != lastContentIdentity else { return }
        lastContentIdentity = identity
        invalidateContentCaches()
    }

    private func invalidateContentCaches() {
        cachedPreferredHeight = nil
        cachedControlFittingSize = nil
        cachedMinimumReadableWidth = nil
        cachedTitleSiblingWidth = nil
        titleWrappingCache.invalidate()
        subtitleWrappingCache.invalidate()
        lastMeasuredWidth = -1
        lastPreferredHeight = -1
    }

    private func invalidateHeightCacheIfWidthRequiresMeasurement(_ width: CGFloat) {
        guard cachedPreferredHeight != nil else { return }
        if lastMeasuredWidth < 0 {
            cachedPreferredHeight = nil
            return
        }
        if abs(width - lastMeasuredWidth) <= 0.5 {
            return
        }
        // Widening can only reduce wrapped height. A row already at its floor
        // cannot shrink further, so skip the fitting-size pass.
        if width + 0.5 >= lastMeasuredWidth, cachedPreferredHeight == minimumHeight {
            return
        }
        if cachedPreferredHeight == minimumHeight, labelsStayOnSingleLine(at: width) {
            return
        }
        cachedPreferredHeight = nil
    }

    private func labelsStayOnSingleLine(at rowWidth: CGFloat) -> Bool {
        let available = max(0, rowWidth - 40)
        let actionWidth = cachedControlFittingSize?.width ?? 0
        let contentWidth = max(1, available - actionWidth - 20)
        if let titleTextField, !titleTextField.isHidden {
            if titleWrappingCache.lineCount(for: titleTextField, width: titleWidth(at: contentWidth)) > 1 {
                return false
            }
        }
        if let subtitleTextField, !subtitleTextField.isHidden {
            if subtitleWrappingCache.lineCount(for: subtitleTextField, width: contentWidth) > 1 {
                return false
            }
        }
        return true
    }

    private func currentContentIdentity() -> DashboardSettingsRowContentIdentity {
        let titleFont = titleTextField?.font ?? NSFont.systemFont(ofSize: 14)
        let subtitleFont = subtitleTextField?.font ?? NSFont.systemFont(ofSize: 12)
        return DashboardSettingsRowContentIdentity(
            title: titleTextField?.stringValue ?? "",
            subtitle: subtitleTextField?.stringValue ?? "",
            titleHidden: titleTextField?.isHidden ?? true,
            subtitleHidden: subtitleTextField?.isHidden ?? true,
            titleFontName: titleFont.fontName,
            subtitleFontName: subtitleFont.fontName,
            titleLineBreak: titleTextField?.lineBreakMode ?? .byWordWrapping,
            subtitleLineBreak: subtitleTextField?.lineBreakMode ?? .byWordWrapping,
            controlHidden: controlView?.isHidden ?? true,
            controlKind: controlView.map { String(describing: type(of: $0)) } ?? "",
            controlTitle: controlTitleSnapshot(),
            forceDedicated: forceDedicatedControlRow
        )
    }

    private func controlTitleSnapshot() -> String {
        if let popup = controlView as? NSPopUpButton {
            return (popup.itemTitles + [popup.titleOfSelectedItem ?? ""]).joined(separator: "\u{1f}")
        }
        if let button = controlView as? NSButton {
            return button.title
        }
        if let field = controlView as? NSTextField {
            return field.stringValue
        }
        return ""
    }

    private func measurePreferredRowHeight() -> CGFloat {
        guard let labelsView, bounds.width > 0 else { return minimumHeight }
        DashboardSettingsLayoutMetrics.preferredHeightMeasurements += 1
        labelsView.layoutSubtreeIfNeeded()
        let visibleLabels = labelsView.arrangedSubviews.filter { !$0.isHidden }
        let labelHeight = visibleLabels.reduce(CGFloat(0)) { total, view in
            let height = view.fittingSize.height
            return total + height
        } + max(0, CGFloat(visibleLabels.count - 1)) * labelsView.spacing
        let controlHeight = controlFittingSize().height
        let height: CGFloat
        if controlPlacement == .dedicatedRow {
            height = ceil(max(
                minimumHeight,
                labelHeight + controlHeight + DashboardSettingsComponents.settingsRowContentControlSpacing + verticalPadding * 2
            ))
        } else {
            height = ceil(max(minimumHeight, max(labelHeight, controlHeight) + verticalPadding * 2))
        }
        cachedPreferredHeight = height
        return height
    }

    private func controlFittingSize() -> NSSize {
        guard let controlView, !controlView.isHidden else { return .zero }
        if let cachedControlFittingSize {
            return cachedControlFittingSize
        }
        DashboardSettingsLayoutMetrics.controlFittingMeasurements += 1
        let size = controlView.fittingSize
        cachedControlFittingSize = size
        return size
    }

    private func textNeedsDedicatedRow(at contentWidth: CGFloat) -> Bool {
        let width = max(1, contentWidth)
        if contentWidth <= 0 {
            return titleTextField != nil || subtitleTextField != nil
        }

        let titleLineCount: Int
        if let titleTextField, !titleTextField.isHidden {
            titleLineCount = titleWrappingCache.lineCount(
                for: titleTextField,
                width: titleWidth(at: width)
            )
        } else {
            titleLineCount = 0
        }
        let subtitleLineCount: Int
        if let subtitleTextField, !subtitleTextField.isHidden {
            subtitleLineCount = subtitleWrappingCache.lineCount(
                for: subtitleTextField,
                width: width
            )
        } else {
            subtitleLineCount = 0
        }
        // The configured budget is inclusive: four natural lines may remain
        // beside the control; only the fifth line requires a dedicated row.
        return titleLineCount + subtitleLineCount >
            DashboardSettingsComponents.settingsTextLineReflowThreshold
    }

    private func titleWidth(at contentWidth: CGFloat) -> CGFloat {
        guard let titleTextField,
              let titleStack = titleTextField.superview as? NSStackView,
              titleStack.orientation == .horizontal else {
            return contentWidth
        }
        let siblingWidth = cachedTitleSiblingWidth ?? measuredTitleSiblingWidth(in: titleStack, title: titleTextField)
        let visibleSiblingCount = titleStack.arrangedSubviews.filter {
            $0 !== titleTextField && !$0.isHidden
        }.count
        let siblingSpacing = visibleSiblingCount == 0
            ? 0
            : CGFloat(visibleSiblingCount) * titleStack.spacing
        return max(1, contentWidth - siblingWidth - siblingSpacing)
    }

    private func measuredTitleSiblingWidth(in titleStack: NSStackView, title: NSTextField) -> CGFloat {
        let visibleSiblings = titleStack.arrangedSubviews.filter {
            $0 !== title && !$0.isHidden
        }
        let siblingWidth = visibleSiblings.reduce(CGFloat(0)) { total, view in
            DashboardSettingsLayoutMetrics.controlFittingMeasurements += 1
            let fittingWidth = view.fittingSize.width
            return total + (fittingWidth.isFinite && fittingWidth > 0 ? fittingWidth : 0)
        }
        cachedTitleSiblingWidth = siblingWidth
        return siblingWidth
    }

    private func measuredMinimumReadableContentWidth() -> CGFloat {
        guard let labelsView else { return 0 }
        let width = labelsView.arrangedSubviews
            .filter { !$0.isHidden }
            .map(minimumReadableWidth(in:))
            .max() ?? 0
        cachedMinimumReadableWidth = width
        return width
    }

    private func minimumReadableWidth(in view: NSView) -> CGFloat {
        if let textField = view as? NSTextField {
            guard textField.lineBreakMode == .byWordWrapping else { return 0 }
            return widestUnbreakableRunWidth(in: textField)
        }

        if let stack = view as? NSStackView {
            let visibleSubviews = stack.arrangedSubviews.filter { !$0.isHidden }
            let childWidths = visibleSubviews.map(minimumReadableWidth(in:))
            guard !childWidths.isEmpty else { return 0 }
            if stack.orientation == .horizontal {
                return childWidths.reduce(CGFloat(0), +)
                    + max(0, CGFloat(childWidths.count - 1)) * stack.spacing
            }
            return childWidths.max() ?? 0
        }

        let textWidth = textFields(in: view)
            .filter { $0.lineBreakMode == .byWordWrapping }
            .map(widestUnbreakableRunWidth(in:))
            .max() ?? 0
        DashboardSettingsLayoutMetrics.controlFittingMeasurements += 1
        let fittingWidth = view.fittingSize.width
        return max(textWidth, fittingWidth.isFinite && fittingWidth > 0 ? fittingWidth : 0)
    }

    private func textFields(in view: NSView) -> [NSTextField] {
        if let textField = view as? NSTextField {
            return [textField]
        }
        return view.subviews.flatMap(textFields(in:))
    }

    private func widestUnbreakableRunWidth(in textField: NSTextField) -> CGFloat {
        let font = textField.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        return textField.stringValue
            .split { $0.isWhitespace || $0.isNewline }
            .map { String($0).size(withAttributes: [.font: font]).width }
            .max() ?? 0
    }

    func installControlLayoutConstraints(
        sideBySide: [NSLayoutConstraint],
        dedicated: [NSLayoutConstraint]
    ) {
        sideBySideControlConstraints = sideBySide
        dedicatedControlConstraints = dedicated
        controlPlacement = forceDedicatedControlRow ? .dedicatedRow : .horizontal
        NSLayoutConstraint.activate(forceDedicatedControlRow ? dedicated : sideBySide)
    }

    private func updateControlPlacementIfNeeded(_ placement: DashboardSettingsControlPlacement) {
        guard controlPlacement != placement else { return }
        controlPlacement = placement
        cachedPreferredHeight = nil
        NSLayoutConstraint.deactivate(
            sideBySideControlConstraints +
                dedicatedControlConstraints
        )
        switch placement {
        case .horizontal, .verticalBesideContent:
            NSLayoutConstraint.activate(sideBySideControlConstraints)
        case .dedicatedRow:
            NSLayoutConstraint.activate(dedicatedControlConstraints)
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
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
    // A custom provider may own a row's measured height (for example the
    // fixed-height Status Links editor) while the other rows remain adaptive.
    var automaticallyUpdatesHeight = true
    private var isUpdatingHeight = false
    private var isHeightDirty = true

    override var intrinsicContentSize: NSSize {
        guard rowsStack != nil, let heightConstraint else {
            return NSSize(width: NSView.noIntrinsicMetric, height: 1)
        }
        guard automaticallyUpdatesHeight else {
            return NSSize(width: NSView.noIntrinsicMetric, height: heightConstraint.constant)
        }
        return NSSize(
            width: NSView.noIntrinsicMetric,
            height: heightConstraint.constant
        )
    }

    override func layout() {
        super.layout()
        guard automaticallyUpdatesHeight, !isUpdatingHeight else { return }
        updateHeightIfNeeded()
    }

    func markHeightDirty() {
        isHeightDirty = true
        needsLayout = true
    }

    func updateHeightIfNeeded() {
        guard automaticallyUpdatesHeight,
              !isUpdatingHeight,
              isHeightDirty,
              let rowsStack,
              let heightConstraint else { return }
        DashboardSettingsLayoutMetrics.cardHeightMeasurements += 1
        let requiredHeight = DashboardSettingsComponents.settingsCardHeight(
            rowsStack: rowsStack,
            separators: separators,
            rowHeight: rowHeight
        )
        isHeightDirty = false
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

    /// Measures the natural AppKit line count without applying a row display
    /// cap. The row supplies the labels' current inline width when deciding
    /// whether the control needs its own row.
    static func settingsTextLineCount(
        _ textField: NSTextField,
        constrainedTo width: CGFloat
    ) -> Int {
        measureTextLineLayout(textField, constrainedTo: width).count
    }

    fileprivate static func measureTextLineLayout(
        _ textField: NSTextField,
        constrainedTo width: CGFloat
    ) -> (count: Int, usedWidth: CGFloat) {
        guard width > 0, !textField.stringValue.isEmpty else { return (0, 0) }
        DashboardSettingsLayoutMetrics.textLineMeasurements += 1

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = textField.lineBreakMode
        if #available(macOS 10.15, *) {
            paragraphStyle.lineBreakStrategy = textField.lineBreakStrategy
        }
        let storage = NSTextStorage(
            string: textField.stringValue,
            attributes: [
                .font: textField.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .paragraphStyle: paragraphStyle
            ]
        )
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            size: NSSize(width: max(1, width), height: .greatestFiniteMagnitude)
        )
        textContainer.lineFragmentPadding = 0
        textContainer.lineBreakMode = textField.lineBreakMode
        layoutManager.addTextContainer(textContainer)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        var lineCount = 0
        var glyphIndex = 0
        while glyphIndex < layoutManager.numberOfGlyphs {
            var glyphRange = NSRange()
            layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: &glyphRange,
                withoutAdditionalLayout: true
            )
            let nextGlyphIndex = NSMaxRange(glyphRange)
            guard nextGlyphIndex > glyphIndex else { break }
            lineCount += 1
            glyphIndex = nextGlyphIndex
        }
        return (lineCount, layoutManager.usedRect(for: textContainer).width)
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
        card.layerContentsRedrawPolicy = .onSetNeedsDisplay
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
        titleAccessory: NSView? = nil,
        headerTrailingAccessory: NSView? = nil,
        control: NSView? = nil,
        minimumHeight: CGFloat = 58,
        verticalPadding: CGFloat = 11,
        controlWidthConstrainedToRow: Bool = false,
        forceDedicatedControlRow: Bool = false
    ) -> NSView {
        let row = DashboardSettingsRowView(
            minimumHeight: minimumHeight,
            verticalPadding: verticalPadding
        )
        row.forceDedicatedControlRow = forceDedicatedControlRow
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
        label.maximumNumberOfLines = Self.settingsTitleMaximumNumberOfLines
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let titleView: NSView
        if let titleAccessory {
            let titleStack = NSStackView(views: [label, titleAccessory])
            titleStack.orientation = .horizontal
            titleStack.alignment = .centerY
            titleStack.spacing = 6
            titleStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            titleStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
            titleView = titleStack
        } else {
            titleView = label
        }
        let headerView: NSView
        if let headerTrailingAccessory {
            let header = NSStackView(views: [titleView, NSView(), headerTrailingAccessory])
            header.orientation = .horizontal
            header.alignment = .centerY
            header.spacing = 6
            headerView = header
        } else {
            headerView = titleView
        }
        let labels = NSStackView(views: [headerView])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        if let headerStack = headerView as? NSStackView {
            // `labels` keeps leading alignment for the existing rows, while
            // a header trailing accessory must span the full readable width
            // so its spacer can push the action to the far edge.
            headerStack.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
        }
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
            detail.maximumNumberOfLines = Self.settingsSubtitleMaximumNumberOfLines
            detail.cell?.wraps = true
            detail.cell?.isScrollable = false
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            detail.setContentHuggingPriority(.defaultLow, for: .horizontal)
            labels.addArrangedSubview(detail)
            row.subtitleTextField = detail
        }
        labels.translatesAutoresizingMaskIntoConstraints = false
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.titleTextField = label
        row.labelsView = labels
        row.controlView = control
        row.addSubview(labels)
        let padding = max(0, verticalPadding)
        if let control {
            control.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(control)
            NSLayoutConstraint.activate([
                labels.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 20),
                control.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -20)
            ])
            let sideBySideConstraints = [
                labels.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                labels.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: padding),
                labels.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -padding),
                labels.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -20),
                control.centerYAnchor.constraint(equalTo: row.centerYAnchor)
            ]
            let dedicatedConstraints = [
                labels.topAnchor.constraint(equalTo: row.topAnchor, constant: padding),
                labels.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -20),
                control.topAnchor.constraint(greaterThanOrEqualTo: labels.bottomAnchor, constant: settingsRowContentControlSpacing),
                control.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -padding)
            ]
            row.installControlLayoutConstraints(
                sideBySide: sideBySideConstraints,
                dedicated: dedicatedConstraints
            )
            if controlWidthConstrainedToRow {
                let widthConstraint =
                    control.widthAnchor.constraint(lessThanOrEqualTo: row.widthAnchor, constant: -40)
                widthConstraint.isActive = true
            }
            if forceDedicatedControlRow {
                control.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 20).isActive = true
            }
        } else {
            NSLayoutConstraint.activate([
                labels.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 20),
                labels.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                labels.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: padding),
                labels.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -padding),
                labels.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -20)
            ])
        }
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
