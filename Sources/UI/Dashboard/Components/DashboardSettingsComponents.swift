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
    var trailingControlHidden: Bool
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
    weak var trailingControlView: NSView?
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
            trailingControlHidden: trailingControlView?.isHidden ?? true,
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
        labelsView.layoutSubtreeIfNeeded()
        let visibleLabels = labelsView.arrangedSubviews.filter { !$0.isHidden }
        let contentWidth = max(1, labelsView.bounds.width > 1 ? labelsView.bounds.width : bounds.width - 40)
        let labelHeight = visibleLabels.reduce(CGFloat(0)) { total, view in
            return total + measuredArrangedLabelHeight(view, contentWidth: contentWidth)
        } + max(0, CGFloat(visibleLabels.count - 1)) * labelsView.spacing
        let controlHeight = controlFittingSize().height
        let trailingHeight = trailingControlFittingSize().height
        let headerHeight = max(labelHeight, trailingHeight)
        let height: CGFloat
        if controlPlacement == .dedicatedRow {
            height = ceil(max(
                minimumHeight,
                headerHeight + controlHeight + DashboardSettingsComponents.settingsRowContentControlSpacing + verticalPadding * 2
            ))
        } else {
            height = ceil(max(minimumHeight, max(headerHeight, controlHeight) + verticalPadding * 2))
        }
        cachedPreferredHeight = height
        return height
    }

    private func measuredArrangedLabelHeight(_ view: NSView, contentWidth: CGFloat) -> CGFloat {
        if let textField = view as? NSTextField {
            return measuredTextHeight(textField, fallbackWidth: contentWidth)
        }
        let fitting = view.fittingSize.height
        if fitting > 1 {
            return fitting
        }
        if let stack = view as? NSStackView {
            let visible = stack.arrangedSubviews.filter { !$0.isHidden }
            if stack.orientation == .vertical {
                let nested = visible.reduce(CGFloat(0)) { total, child in
                    total + measuredArrangedLabelHeight(child, contentWidth: contentWidth)
                }
                return nested + max(0, CGFloat(visible.count - 1)) * stack.spacing
            }
            if let title = visible.first as? NSTextField {
                return measuredTextHeight(title, fallbackWidth: titleWidth(at: contentWidth))
            }
        }
        return max(0, fitting)
    }

    private func measuredTextHeight(_ textField: NSTextField, fallbackWidth: CGFloat) -> CGFloat {
        let fitting = textField.fittingSize.height
        if textField.stringValue.isEmpty {
            return max(0, fitting)
        }

        let frameHeight = textField.bounds.height
        let laidOutWidth = textField.bounds.width
        let measureWidth = laidOutWidth > 1 ? laidOutWidth : max(1, fallbackWidth)
        let cellHeight = textField.cell?.cellSize(
            forBounds: NSRect(
                x: 0,
                y: 0,
                width: measureWidth,
                height: .greatestFiniteMagnitude
            )
        ).height ?? 0

        // In-place subtitle updates can compress a wrapping title to zero.
        // Measure the real text so the row can grow instead of hiding it.
        if frameHeight <= 1 || fitting <= 1 {
            return max(1, cellHeight, fitting)
        }
        if cellHeight > frameHeight + 2 {
            return cellHeight
        }
        return max(fitting, frameHeight)
    }

    private func controlFittingSize() -> NSSize {
        guard let controlView, !controlView.isHidden else { return .zero }
        if let cachedControlFittingSize {
            return cachedControlFittingSize
        }
        let size = controlView.fittingSize
        cachedControlFittingSize = size
        return size
    }

    private func trailingControlFittingSize() -> NSSize {
        guard let trailingControlView, !trailingControlView.isHidden else { return .zero }
        return trailingControlView.fittingSize
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

    fileprivate func invalidateAfterContentChange() {
        lastContentIdentity = nil
        invalidateContentCaches()
        invalidateIntrinsicContentSize()
        needsLayout = true
        superview?.needsLayout = true
        cardView?.markHeightDirty()
        cardView?.needsLayout = true
        cardView?.updateHeightIfNeeded()
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
    private var isApplyingEmphasis = false
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

    override var font: NSFont? {
        get { super.font }
        set {
            super.font = newValue
            applyEmphasisFontsIfNeeded()
        }
    }

    override var textColor: NSColor? {
        get { super.textColor }
        set {
            super.textColor = newValue
            applyEmphasisFontsIfNeeded()
        }
    }

    func setLocalizedSubtitle(_ subtitle: LocalizedSubtitle) {
        localizedSubtitle = subtitle
        lastAppliedWidth = -1
        isApplyingLayoutText = true
        super.stringValue = subtitle.text
        isApplyingLayoutText = false
        applyLayoutTextIfNeeded()
        applyEmphasisFontsIfNeeded()
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
            applyEmphasisFontsIfNeeded()
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
            applyEmphasisFontsIfNeeded()
            return
        }
        isApplyingLayoutText = true
        super.stringValue = layoutText
        isApplyingLayoutText = false
        lastAppliedWidth = width
        applyEmphasisFontsIfNeeded()
        invalidateIntrinsicContentSize()
    }

    private func applyEmphasisFontsIfNeeded() {
        guard !isApplyingLayoutText, !isApplyingEmphasis else { return }
        guard let localizedSubtitle, !localizedSubtitle.emphasisGroups.isEmpty else { return }
        let displayed = super.stringValue
        guard !displayed.isEmpty else { return }
        let font = self.font ?? NSFont.systemFont(ofSize: 12)
        let attributed = NSMutableAttributedString(
            string: displayed,
            attributes: [
                .font: font,
                .foregroundColor: textColor ?? NSColor.secondaryLabelColor
            ]
        )
        let bold = NSFont.systemFont(ofSize: font.pointSize, weight: .bold)
        let source = localizedSubtitle.text as NSString
        let layout = displayed as NSString
        for range in localizedSubtitle.emphasisGroups {
            guard range.location >= 0,
                  range.length > 0,
                  NSMaxRange(range) <= source.length else {
                continue
            }
            let token = source.substring(with: range)
            let found = layout.range(of: token)
            guard found.location != NSNotFound else { continue }
            attributed.addAttribute(.font, value: bold, range: found)
        }
        isApplyingEmphasis = true
        isApplyingLayoutText = true
        attributedStringValue = attributed
        isApplyingLayoutText = false
        isApplyingEmphasis = false
    }
}

private final class DashboardSettingsCardView: NSView, SettingsRowHeightInvalidating {
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

    func invalidateHostedSettingsRowHeight() {
        markHeightDirty()
    }

    func updateHeightIfNeeded() {
        guard automaticallyUpdatesHeight,
              !isUpdatingHeight,
              isHeightDirty,
              let rowsStack,
              let heightConstraint else { return }
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
        notifySettingsRowContentChanged(label)
    }

    static func notifySettingsRowContentChanged(_ view: NSView?) {
        var ancestor = view
        while let current = ancestor {
            if let row = current as? DashboardSettingsRowView {
                row.invalidateAfterContentChange()
                return
            }
            ancestor = current.superview
        }
        view?.invalidateIntrinsicContentSize()
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
        for section in sections {
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            section.setContentHuggingPriority(.defaultLow, for: .horizontal)
            section.setContentCompressionResistancePriority(.required, for: .horizontal)
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
        let section = SettingsSectionView(title: title, contentViews: rows, separatorIndices: separatorIndices)
        onLayoutCreated?(section.cardView, section.cardView.heightAnchor.constraint(equalToConstant: 0), section.separators)
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
        controlWidthConstrainedToRow: Bool = false,
        forceDedicatedControlRow: Bool = false
    ) -> NSView {
        let accessory = control ?? trailingControl ?? headerTrailingAccessory
        let detail = subtitle ?? subtitleContent?.text
        return SettingsRowView(title: title, detail: detail, accessoryView: accessory)
    }

    static func settingsCardHeight(rowsStack: NSStackView, separators: [NSView], rowHeight: ((NSView) -> CGFloat?)? = nil) -> CGFloat {
        rowsStack.layoutSubtreeIfNeeded()
        return max(0, rowsStack.fittingSize.height)
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
