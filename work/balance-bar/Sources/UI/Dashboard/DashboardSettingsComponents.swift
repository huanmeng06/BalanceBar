import AppKit
import OSLog

struct DashboardSettingsMeasurementCounters: Equatable {
    let rowPreferredHeightMeasurements: Int
    let textLineMeasurements: Int
    let controlFittingMeasurements: Int
    let cardHeightMeasurements: Int
}

struct DashboardSettingsRenderingCounters: Equatable {
    let pageDraws: Int
    let documentDraws: Int
    let cardDraws: Int
    let pageLayerUpdates: Int
    let documentLayerUpdates: Int
    let cardLayerUpdates: Int
    let clipBoundsChanges: Int
    let pageDisplayInvalidations: Int
    let documentDisplayInvalidations: Int
    let cardDisplayInvalidations: Int
}

private func dashboardSettingsMetric(_ value: CGFloat) -> Int {
    guard value.isFinite else { return Int.max }
    return Int((value * 2).rounded())
}

private struct DashboardSettingsFontMetric: Hashable {
    let postscriptName: String
    let pointSize: Int
    let symbolicTraits: UInt32

    init(_ font: NSFont?) {
        let font = font ?? .systemFont(ofSize: NSFont.systemFontSize)
        postscriptName = font.fontDescriptor.postscriptName ?? ""
        pointSize = dashboardSettingsMetric(font.pointSize)
        symbolicTraits = font.fontDescriptor.symbolicTraits.rawValue
    }
}

private struct DashboardSettingsControlGeometry: Equatable {
    let identity: ObjectIdentifier?
    let isHidden: Bool
    let boundsHeight: Int
    let usesDedicatedRow: Bool?
}

private struct DashboardSettingsTextLineContentKey: Hashable {
    let text: String
    let font: DashboardSettingsFontMetric
    let lineBreakMode: UInt
    let lineBreakStrategy: UInt
}

private struct DashboardSettingsTextLineRange {
    let lowerWidth: CGFloat
    let upperWidth: CGFloat
    let lineCount: Int
}

private struct DashboardSettingsTextLayoutState: Equatable {
    let titleLineCount: Int
    let subtitleLineCount: Int
}

private struct DashboardSettingsPlacementState: Equatable {
    let contentRevision: UInt
    let controlMetricRevision: UInt
    let placement: DashboardSettingsControlPlacement
    let titleLineCount: Int
    let subtitleLineCount: Int
    let requiresDedicatedRow: Bool
    let adaptiveUsesDedicatedRow: Bool?
}

private struct DashboardSettingsRowMeasurementKey: Equatable {
    let contentRevision: UInt
    let controlMetricRevision: UInt
    let placement: DashboardSettingsControlPlacement
    let textLayoutState: DashboardSettingsTextLayoutState
    let controlWidth: Int
    let controlHeight: Int
}

protocol DashboardSettingsRowControlLayout: AnyObject {
    func updateAvailableRowWidth(_ width: CGFloat)
    var usesDedicatedRow: Bool { get }
    var allowsTextDrivenDedicatedRow: Bool { get }
}

private enum DashboardSettingsControlPlacement: Equatable {
    case horizontal
    case verticalBesideContent
    case dedicatedRow
}

private final class DashboardSettingsRowView: NSView {
    var forceDedicatedControlRow = false {
        didSet {
            guard forceDedicatedControlRow != oldValue else { return }
            invalidateContentMetrics()
        }
    }
    let minimumHeight: CGFloat
    let verticalPadding: CGFloat
    weak var labelsView: NSStackView?
    weak var controlView: NSView?
    weak var cardView: DashboardSettingsCardView?
    weak var titleTextField: NSTextField?
    weak var subtitleTextField: NSTextField?
    private var lastPreferredHeight: CGFloat = -1
    private var controlPlacement: DashboardSettingsControlPlacement = .horizontal
    private var sideBySideControlConstraints: [NSLayoutConstraint] = []
    private var dedicatedControlConstraints: [NSLayoutConstraint] = []
    private var lastPlacementState: DashboardSettingsPlacementState?
    private var lastControlGeometry: DashboardSettingsControlGeometry?
    private var cachedControlFittingSize: NSSize?
    private var cachedPreferredMeasurement: (key: DashboardSettingsRowMeasurementKey, height: CGFloat)?
    private var textLineCountCache: [DashboardSettingsTextLineContentKey: [DashboardSettingsTextLineRange]] = [:]
    private var textLineCountCacheOrder: [DashboardSettingsTextLineContentKey] = []
    private var contentRevisionStorage: UInt = 1
    private var controlMetricRevisionStorage: UInt = 1
    private var heightRevisionStorage: UInt = 0
    private var cachedMinimumReadableContentWidth: CGFloat?
    private var cachedTitleSiblingWidth: CGFloat?

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

    var heightRevision: UInt {
        heightRevisionStorage
    }

    var preferredRowHeight: CGFloat {
        guard let labelsView, bounds.width > 0 else { return minimumHeight }

        let controlSize = currentControlFittingSize()
        let initialTextLayoutState = textLayoutState(for: controlPlacement)
        let key = DashboardSettingsRowMeasurementKey(
            contentRevision: contentRevisionStorage,
            controlMetricRevision: controlMetricRevisionStorage,
            placement: controlPlacement,
            textLayoutState: initialTextLayoutState,
            controlWidth: dashboardSettingsMetric(controlSize.width),
            controlHeight: dashboardSettingsMetric(controlSize.height)
        )
        if let cachedPreferredMeasurement,
           cachedPreferredMeasurement.key == key {
            return cachedPreferredMeasurement.height
        }

        DashboardSettingsComponents.recordRowPreferredHeightMeasurement()
        labelsView.layoutSubtreeIfNeeded()
        let visibleLabels = labelsView.arrangedSubviews.filter { !$0.isHidden }
        let labelHeight = visibleLabels.reduce(CGFloat(0)) { total, view in
            let height = view.fittingSize.height
            return total + height
        } + max(0, CGFloat(visibleLabels.count - 1)) * labelsView.spacing
        let controlHeight = controlSize.height
        let height: CGFloat
        if controlPlacement == .dedicatedRow {
            height = ceil(max(
                minimumHeight,
                labelHeight + controlHeight + DashboardSettingsComponents.settingsRowContentControlSpacing + verticalPadding * 2
            ))
        } else {
            height = ceil(max(minimumHeight, max(labelHeight, controlHeight) + verticalPadding * 2))
        }
        let finalControlSize = currentControlFittingSize()
        let finalKey = DashboardSettingsRowMeasurementKey(
            contentRevision: contentRevisionStorage,
            controlMetricRevision: controlMetricRevisionStorage,
            placement: controlPlacement,
            textLayoutState: textLayoutState(for: controlPlacement),
            controlWidth: dashboardSettingsMetric(finalControlSize.width),
            controlHeight: dashboardSettingsMetric(finalControlSize.height)
        )
        cachedPreferredMeasurement = (finalKey, height)
        return height
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: preferredRowHeight)
    }

    override func layout() {
        refreshControlGeometry()
        if let placementState = currentPlacementState() {
            if placementState != lastPlacementState {
                updateControlPlacementIfNeeded(placementState.placement)
                lastPlacementState = placementState
            }
        } else {
            lastPlacementState = nil
        }
        super.layout()
        refreshControlGeometry()
        let currentHeight = preferredRowHeight
        let heightChanged = abs(currentHeight - lastPreferredHeight) > 0.5
        lastPreferredHeight = currentHeight
        if heightChanged {
            heightRevisionStorage &+= 1
            invalidateIntrinsicContentSize()
            cardView?.markHeightDirty()
        }
    }

    func invalidateContentMetrics() {
        contentRevisionStorage &+= 1
        cachedPreferredMeasurement = nil
        lastPlacementState = nil
        cachedMinimumReadableContentWidth = nil
        cachedTitleSiblingWidth = nil
        textLineCountCache.removeAll(keepingCapacity: true)
        textLineCountCacheOrder.removeAll(keepingCapacity: true)
        needsLayout = true
    }

    func invalidateControlMetrics() {
        controlMetricRevisionStorage &+= 1
        cachedPreferredMeasurement = nil
        cachedControlFittingSize = nil
        lastControlGeometry = nil
        lastPlacementState = nil
        needsLayout = true
    }

    private func currentPlacementState() -> DashboardSettingsPlacementState? {
        guard let controlView,
              !(controlView is NSStackView && !(controlView is DashboardSettingsRowControlLayout))
        else { return nil }

        let availableContentAndControlWidth = max(0, bounds.width - 40)
        let adaptiveControl = controlView as? DashboardSettingsRowControlLayout
        adaptiveControl?.updateAvailableRowWidth(availableContentAndControlWidth)
        let actionWidth = currentControlFittingSize().width
        let contentWidthWhenHorizontal = max(
            0,
            availableContentAndControlWidth - actionWidth - 20
        )
        let readableContentWidth = minimumReadableContentWidth
        let supportsTextDrivenDedicatedRow = !(controlView is NSStackView) ||
            adaptiveControl?.allowsTextDrivenDedicatedRow == true
        let lineCounts = textLineCounts(at: contentWidthWhenHorizontal)
        let lineBudgetNeedsDedicatedRow = supportsTextDrivenDedicatedRow &&
            lineCounts.title + lineCounts.subtitle >
                DashboardSettingsComponents.settingsTextLineReflowThreshold
        let contentNeedsDedicatedRow = contentWidthWhenHorizontal + 0.5 < readableContentWidth ||
            lineBudgetNeedsDedicatedRow
        let placement: DashboardSettingsControlPlacement
        if forceDedicatedControlRow || contentNeedsDedicatedRow {
            placement = .dedicatedRow
        } else if adaptiveControl?.usesDedicatedRow == true {
            placement = .verticalBesideContent
        } else {
            placement = .horizontal
        }
        return DashboardSettingsPlacementState(
            contentRevision: contentRevisionStorage,
            controlMetricRevision: controlMetricRevisionStorage,
            placement: placement,
            titleLineCount: lineCounts.title,
            subtitleLineCount: lineCounts.subtitle,
            requiresDedicatedRow: forceDedicatedControlRow || contentNeedsDedicatedRow,
            adaptiveUsesDedicatedRow: adaptiveControl?.usesDedicatedRow
        )
    }

    private func refreshControlGeometry() {
        let geometry = DashboardSettingsControlGeometry(
            identity: controlView.map(ObjectIdentifier.init),
            isHidden: controlView?.isHidden == true,
            boundsHeight: dashboardSettingsMetric(controlView?.bounds.height ?? 0),
            usesDedicatedRow: (controlView as? DashboardSettingsRowControlLayout)?.usesDedicatedRow
        )
        guard geometry != lastControlGeometry else { return }
        lastControlGeometry = geometry
        controlMetricRevisionStorage &+= 1
        cachedControlFittingSize = nil
        cachedPreferredMeasurement = nil
        lastPlacementState = nil
    }

    private func currentControlFittingSize() -> NSSize {
        refreshControlGeometry()
        if let cachedControlFittingSize {
            return cachedControlFittingSize
        }
        guard let controlView else { return .zero }
        DashboardSettingsComponents.recordControlFittingMeasurement()
        let size = controlView.fittingSize
        cachedControlFittingSize = size
        return size
    }

    private func textLayoutState(
        for placement: DashboardSettingsControlPlacement
    ) -> DashboardSettingsTextLayoutState {
        let availableContentWidth = max(1, bounds.width - 40)
        let controlWidth = currentControlFittingSize().width
        let contentWidth = controlView == nil || placement == .dedicatedRow
            ? availableContentWidth
            : max(1, availableContentWidth - controlWidth - 20)
        let (titleLineCount, subtitleLineCount) = textLineCounts(at: contentWidth)
        return DashboardSettingsTextLayoutState(
            titleLineCount: titleLineCount,
            subtitleLineCount: subtitleLineCount
        )
    }

    private func textLineCounts(at contentWidth: CGFloat) -> (title: Int, subtitle: Int) {
        let width = max(1, contentWidth)
        let titleLineCount: Int
        if let titleTextField, !titleTextField.isHidden {
            titleLineCount = cachedTextLineCount(
                titleTextField,
                constrainedTo: titleWidth(at: width)
            )
        } else {
            titleLineCount = 0
        }
        let subtitleLineCount: Int
        if let subtitleTextField, !subtitleTextField.isHidden {
            subtitleLineCount = cachedTextLineCount(
                subtitleTextField,
                constrainedTo: width
            )
        } else {
            subtitleLineCount = 0
        }
        return (titleLineCount, subtitleLineCount)
    }

    private func textNeedsDedicatedRow(at contentWidth: CGFloat) -> Bool {
        if contentWidth <= 0 {
            return titleTextField != nil || subtitleTextField != nil
        }
        let counts = textLineCounts(at: contentWidth)
        // The configured budget is inclusive: four natural lines may remain
        // beside the control; only the fifth line requires a dedicated row.
        return counts.title + counts.subtitle >
            DashboardSettingsComponents.settingsTextLineReflowThreshold
    }

    private func cachedTextLineCount(
        _ textField: NSTextField,
        constrainedTo width: CGFloat
    ) -> Int {
        let normalizedWidth = max(1, width)
        let key = DashboardSettingsTextLineContentKey(
            text: textField.stringValue,
            font: DashboardSettingsFontMetric(textField.font),
            lineBreakMode: textField.lineBreakMode.rawValue,
            lineBreakStrategy: textField.lineBreakStrategy.rawValue
        )
        if let cached = textLineCountCache[key]?.first(where: {
            normalizedWidth >= $0.lowerWidth && normalizedWidth <= $0.upperWidth
        }) {
            return cached.lineCount
        }

        let lineCount = measureTextLineCount(textField, width: normalizedWidth)
        let range = textLineRange(
            for: textField,
            width: normalizedWidth,
            lineCount: lineCount
        )
        textLineCountCache[key, default: []].append(range)
        if !textLineCountCacheOrder.contains(key) {
            textLineCountCacheOrder.append(key)
        }
        let cacheLimit = 8
        if textLineCountCacheOrder.count > cacheLimit,
           let evicted = textLineCountCacheOrder.first {
            textLineCountCacheOrder.removeFirst()
            textLineCountCache.removeValue(forKey: evicted)
        }
        return lineCount
    }

    private func measureTextLineCount(_ textField: NSTextField, width: CGFloat) -> Int {
        DashboardSettingsComponents.settingsTextLineCount(
            textField,
            constrainedTo: width
        )
    }

    private func textLineRange(
        for textField: NSTextField,
        width: CGFloat,
        lineCount: Int
    ) -> DashboardSettingsTextLineRange {
        var lowerWidth = width
        var upperWidth = width
        let minimumWidth: CGFloat = 1
        let naturalWidth = max(
            width,
            ceil(textField.stringValue.size(withAttributes: [
                .font: textField.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            ]).width) + 1
        )
        let maximumWidth = max(1024, min(32768, naturalWidth))

        var probeWidth = max(minimumWidth, width / 2)
        while probeWidth > minimumWidth {
            let probeCount = measureTextLineCount(textField, width: probeWidth)
            if probeCount != lineCount {
                lowerWidth = findLowerLineBoundary(
                    textField,
                    targetCount: lineCount,
                    differentWidth: probeWidth,
                    sameWidth: lowerWidth
                )
                break
            }
            lowerWidth = probeWidth
            probeWidth = max(minimumWidth, probeWidth / 2)
        }
        if probeWidth <= minimumWidth,
           lowerWidth == width,
           measureTextLineCount(textField, width: minimumWidth) == lineCount {
            lowerWidth = minimumWidth
        }

        probeWidth = min(maximumWidth, max(width * 2, width + 1))
        while probeWidth < maximumWidth {
            let probeCount = measureTextLineCount(textField, width: probeWidth)
            if probeCount != lineCount {
                upperWidth = findUpperLineBoundary(
                    textField,
                    targetCount: lineCount,
                    sameWidth: upperWidth,
                    differentWidth: probeWidth
                )
                break
            }
            upperWidth = probeWidth
            probeWidth = min(maximumWidth, probeWidth * 2)
        }
        if probeWidth >= maximumWidth,
           measureTextLineCount(textField, width: maximumWidth) == lineCount {
            upperWidth = maximumWidth
        }

        return DashboardSettingsTextLineRange(
            lowerWidth: lowerWidth,
            upperWidth: upperWidth,
            lineCount: lineCount
        )
    }

    private func findLowerLineBoundary(
        _ textField: NSTextField,
        targetCount: Int,
        differentWidth: CGFloat,
        sameWidth: CGFloat
    ) -> CGFloat {
        var lower = differentWidth
        var upper = sameWidth
        while upper - lower > 0.25 {
            let middle = (lower + upper) / 2
            if measureTextLineCount(textField, width: middle) == targetCount {
                upper = middle
            } else {
                lower = middle
            }
        }
        return upper
    }

    private func findUpperLineBoundary(
        _ textField: NSTextField,
        targetCount: Int,
        sameWidth: CGFloat,
        differentWidth: CGFloat
    ) -> CGFloat {
        var lower = sameWidth
        var upper = differentWidth
        while upper - lower > 0.25 {
            let middle = (lower + upper) / 2
            if measureTextLineCount(textField, width: middle) == targetCount {
                lower = middle
            } else {
                upper = middle
            }
        }
        return lower
    }

    private func titleWidth(at contentWidth: CGFloat) -> CGFloat {
        guard let titleTextField,
              let titleStack = titleTextField.superview as? NSStackView,
              titleStack.orientation == .horizontal else {
            return contentWidth
        }
        let visibleSiblings = titleStack.arrangedSubviews.filter {
            $0 !== titleTextField && !$0.isHidden
        }
        let siblingWidth: CGFloat
        if let cachedTitleSiblingWidth {
            siblingWidth = cachedTitleSiblingWidth
        } else {
            siblingWidth = visibleSiblings.reduce(CGFloat(0)) { total, view in
                let fittingWidth = view.fittingSize.width
                return total + (fittingWidth.isFinite && fittingWidth > 0 ? fittingWidth : 0)
            }
            cachedTitleSiblingWidth = siblingWidth
        }
        let siblingSpacing = visibleSiblings.isEmpty
            ? 0
            : CGFloat(visibleSiblings.count) * titleStack.spacing
        return max(1, contentWidth - siblingWidth - siblingSpacing)
    }

    private var minimumReadableContentWidth: CGFloat {
        if let cachedMinimumReadableContentWidth {
            return cachedMinimumReadableContentWidth
        }
        guard let labelsView else { return 0 }
        let width = labelsView.arrangedSubviews
            .filter { !$0.isHidden }
            .map(minimumReadableWidth(in:))
            .max() ?? 0
        cachedMinimumReadableContentWidth = width
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

    private func updateControlPlacementIfNeeded(_ placement: DashboardSettingsControlPlacement) {
        guard controlPlacement != placement else { return }
        controlPlacement = placement
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
        cachedPreferredMeasurement = nil
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
        DashboardSettingsComponents.invalidateSettingsRowContent(containing: self)
    }
}

private final class DashboardSettingsCardView: NSView {
    weak var rowsStack: NSStackView?
    weak var heightConstraint: NSLayoutConstraint?
    var separators: [NSView] = []
    var rowHeight: ((NSView) -> CGFloat?)?
    // A custom provider may own a row's measured height (for example the
    // fixed-height Status Links editor) while the other rows remain adaptive.
    var automaticallyUpdatesHeight = true {
        didSet {
            guard automaticallyUpdatesHeight != oldValue else { return }
            if automaticallyUpdatesHeight {
                markHeightDirty()
            }
        }
    }
    private var isUpdatingHeight = false
    private var isHeightDirty = true
    private var lastHeightSignature: DashboardSettingsCardHeightSignature?
    private var lastShadowPathSize: NSSize = .zero

    override func draw(_ dirtyRect: NSRect) {
        DashboardSettingsComponents.recordCardDraw()
        super.draw(dirtyRect)
    }

    override func updateLayer() {
        DashboardSettingsComponents.recordCardLayerUpdate()
        super.updateLayer()
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        DashboardSettingsComponents.recordCardDisplayInvalidation()
        super.setNeedsDisplay(invalidRect)
    }

    private struct DashboardSettingsCardHeightSignature: Equatable {
        struct Row: Equatable {
            let identity: ObjectIdentifier
            let isHidden: Bool
            let geometryHeight: Int?
            let heightRevision: UInt?
            let customHeight: Int?
        }

        let rows: [Row]
        let separatorsHidden: [Bool]
    }

    override var intrinsicContentSize: NSSize {
        guard let heightConstraint else {
            return NSSize(width: NSView.noIntrinsicMetric, height: 1)
        }
        // The height constraint is the card's cheap, already-synchronized
        // geometry cache. Do not rebuild every row's fitting size from an
        // intrinsic-size getter; layout updates this constraint only after a
        // row width/content/visibility revision.
        return NSSize(width: NSView.noIntrinsicMetric, height: heightConstraint.constant)
    }

    override func layout() {
        super.layout()
        updateShadowPathIfNeeded()
        guard automaticallyUpdatesHeight, !isUpdatingHeight else { return }
        updateHeightIfNeeded()
    }

    private func updateShadowPathIfNeeded() {
        guard let layer, bounds.size != lastShadowPathSize else { return }
        lastShadowPathSize = bounds.size
        layer.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: 18,
            cornerHeight: 18,
            transform: nil
        )
    }

    func markHeightDirty() {
        guard automaticallyUpdatesHeight else { return }
        isHeightDirty = true
        needsLayout = true
        rowsStack?.needsLayout = true
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
    }

    func updateHeightIfNeeded() {
        guard automaticallyUpdatesHeight,
              !isUpdatingHeight,
              let rowsStack,
              let heightConstraint else { return }
        let currentSignature = heightSignature(rowsStack: rowsStack)
        guard isHeightDirty || currentSignature != lastHeightSignature else { return }

        isUpdatingHeight = true
        rowsStack.layoutSubtreeIfNeeded()
        let requiredHeight = DashboardSettingsComponents.measuredSettingsCardHeight(
            rowsStack: rowsStack,
            separators: separators,
            rowHeight: rowHeight
        )
        let finalSignature = heightSignature(rowsStack: rowsStack)
        lastHeightSignature = finalSignature
        isHeightDirty = false
        let heightChanged = abs(heightConstraint.constant - requiredHeight) > 0.5
        if heightChanged {
            heightConstraint.constant = requiredHeight
            invalidateIntrinsicContentSize()
        }
        isUpdatingHeight = false
        if heightChanged {
            superview?.needsLayout = true
        }
    }

    fileprivate func synchronizeHeightForManualLayout() {
        guard automaticallyUpdatesHeight else { return }
        for _ in 0..<2 {
            rowsStack?.needsLayout = true
            rowsStack?.arrangedSubviews.forEach { $0.needsLayout = true }
            needsLayout = true
            updateHeightIfNeeded()
        }
    }

    private func heightSignature(
        rowsStack: NSStackView
    ) -> DashboardSettingsCardHeightSignature {
        let rows = rowsStack.arrangedSubviews.map { row in
            let customHeight = rowHeight?(row).map {
                dashboardSettingsMetric(max(1, $0))
            }
            let heightRevision = (row as? DashboardSettingsRowView)?.heightRevision
            let geometryHeight = row is DashboardSettingsRowView
                ? nil
                : dashboardSettingsMetric(row.bounds.height)
            return DashboardSettingsCardHeightSignature.Row(
                identity: ObjectIdentifier(row),
                isHidden: row.isHidden,
                geometryHeight: geometryHeight,
                heightRevision: heightRevision,
                customHeight: customHeight
            )
        }
        return DashboardSettingsCardHeightSignature(
            rows: rows,
            separatorsHidden: separators.map(\.isHidden)
        )
    }
}

private final class DashboardSettingsClipView: NSClipView {
    override func scroll(to newOrigin: NSPoint) {
        let oldOrigin = bounds.origin
        super.scroll(to: newOrigin)
        if oldOrigin != bounds.origin {
            DashboardSettingsComponents.recordClipBoundsChange()
        }
    }

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        let changed = bounds.origin != newOrigin
        super.setBoundsOrigin(newOrigin)
        if changed {
            DashboardSettingsComponents.recordClipBoundsChange()
        }
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

    private struct RenderingCounterStorage {
        var pageDraws = 0
        var documentDraws = 0
        var cardDraws = 0
        var pageLayerUpdates = 0
        var documentLayerUpdates = 0
        var cardLayerUpdates = 0
        var clipBoundsChanges = 0
        var pageDisplayInvalidations = 0
        var documentDisplayInvalidations = 0
        var cardDisplayInvalidations = 0
    }

    private enum RenderingExperiment {
        case baseline
        case opaqueViewport
        case documentLayer
    }

    private static var measurementCounters = DashboardSettingsMeasurementCounters(
        rowPreferredHeightMeasurements: 0,
        textLineMeasurements: 0,
        controlFittingMeasurements: 0,
        cardHeightMeasurements: 0
    )
    private static var renderingCounters = RenderingCounterStorage()
    private static let runtimeRenderingInstrumentationEnabled =
        ProcessInfo.processInfo.environment["BALANCEBAR_DASHBOARD_RENDER_INSTRUMENTATION"] == "1"
    private static let renderingLog = OSLog(
        subsystem: "com.huanmeng06.BalanceBar",
        category: "dashboard-rendering"
    )
    private static let renderingExperiment: RenderingExperiment = {
        switch ProcessInfo.processInfo.environment["BALANCEBAR_DASHBOARD_RENDERING_EXPERIMENT"] {
        case "opaque-viewport": return .opaqueViewport
        case "document-layer": return .documentLayer
        default: return .baseline
        }
    }()

    // This is deliberately opt-in. It is useful for Debug builds and local
    // Instruments runs, while normal app launches pay only for this false
    // branch and preserve the existing rendering topology.
    static var renderingInstrumentationEnabledForTesting = false

    static func invalidateSettingsRowContent(containing view: NSView?) {
        settingsRow(containing: view)?.invalidateContentMetrics()
    }

    static func invalidateSettingsRowControlMetrics(containing view: NSView?) {
        settingsRow(containing: view)?.invalidateControlMetrics()
    }

    private static func settingsRow(containing view: NSView?) -> DashboardSettingsRowView? {
        var current = view
        while let candidate = current {
            if let row = candidate as? DashboardSettingsRowView {
                return row
            }
            current = candidate.superview
        }
        return nil
    }

    static var measurementCountersForTesting: DashboardSettingsMeasurementCounters {
        measurementCounters
    }

    static var renderingCountersForTesting: DashboardSettingsRenderingCounters {
        DashboardSettingsRenderingCounters(
            pageDraws: renderingCounters.pageDraws,
            documentDraws: renderingCounters.documentDraws,
            cardDraws: renderingCounters.cardDraws,
            pageLayerUpdates: renderingCounters.pageLayerUpdates,
            documentLayerUpdates: renderingCounters.documentLayerUpdates,
            cardLayerUpdates: renderingCounters.cardLayerUpdates,
            clipBoundsChanges: renderingCounters.clipBoundsChanges,
            pageDisplayInvalidations: renderingCounters.pageDisplayInvalidations,
            documentDisplayInvalidations: renderingCounters.documentDisplayInvalidations,
            cardDisplayInvalidations: renderingCounters.cardDisplayInvalidations
        )
    }

    static func resetMeasurementCountersForTesting() {
        measurementCounters = DashboardSettingsMeasurementCounters(
            rowPreferredHeightMeasurements: 0,
            textLineMeasurements: 0,
            controlFittingMeasurements: 0,
            cardHeightMeasurements: 0
        )
    }

    static func resetRenderingCountersForTesting() {
        renderingCounters = RenderingCounterStorage()
    }

    private static var renderingInstrumentationEnabled: Bool {
        renderingInstrumentationEnabledForTesting || runtimeRenderingInstrumentationEnabled
    }

    private static func recordRenderingEvent(
        _ name: StaticString,
        update: (inout RenderingCounterStorage) -> Void
    ) {
        guard renderingInstrumentationEnabled else { return }
        update(&renderingCounters)
        if runtimeRenderingInstrumentationEnabled {
            os_signpost(.event, log: renderingLog, name: name)
        }
    }

    fileprivate static func recordPageDraw() {
        recordRenderingEvent("Dashboard page draw") { $0.pageDraws += 1 }
    }

    fileprivate static func recordDocumentDraw() {
        recordRenderingEvent("Dashboard document draw") { $0.documentDraws += 1 }
    }

    fileprivate static func recordCardDraw() {
        recordRenderingEvent("Dashboard card draw") { $0.cardDraws += 1 }
    }

    fileprivate static func recordPageLayerUpdate() {
        recordRenderingEvent("Dashboard page layer update") { $0.pageLayerUpdates += 1 }
    }

    fileprivate static func recordDocumentLayerUpdate() {
        recordRenderingEvent("Dashboard document layer update") { $0.documentLayerUpdates += 1 }
    }

    fileprivate static func recordCardLayerUpdate() {
        recordRenderingEvent("Dashboard card layer update") { $0.cardLayerUpdates += 1 }
    }

    fileprivate static func recordClipBoundsChange() {
        recordRenderingEvent("Dashboard clip bounds change") { $0.clipBoundsChanges += 1 }
    }

    fileprivate static func recordPageDisplayInvalidation() {
        recordRenderingEvent("Dashboard page display invalidation") {
            $0.pageDisplayInvalidations += 1
        }
    }

    fileprivate static func recordDocumentDisplayInvalidation() {
        recordRenderingEvent("Dashboard document display invalidation") {
            $0.documentDisplayInvalidations += 1
        }
    }

    fileprivate static func recordCardDisplayInvalidation() {
        recordRenderingEvent("Dashboard card display invalidation") {
            $0.cardDisplayInvalidations += 1
        }
    }

    fileprivate static func recordRowPreferredHeightMeasurement() {
        measurementCounters = DashboardSettingsMeasurementCounters(
            rowPreferredHeightMeasurements: measurementCounters.rowPreferredHeightMeasurements + 1,
            textLineMeasurements: measurementCounters.textLineMeasurements,
            controlFittingMeasurements: measurementCounters.controlFittingMeasurements,
            cardHeightMeasurements: measurementCounters.cardHeightMeasurements
        )
    }

    fileprivate static func recordTextLineMeasurement() {
        measurementCounters = DashboardSettingsMeasurementCounters(
            rowPreferredHeightMeasurements: measurementCounters.rowPreferredHeightMeasurements,
            textLineMeasurements: measurementCounters.textLineMeasurements + 1,
            controlFittingMeasurements: measurementCounters.controlFittingMeasurements,
            cardHeightMeasurements: measurementCounters.cardHeightMeasurements
        )
    }

    fileprivate static func recordControlFittingMeasurement() {
        measurementCounters = DashboardSettingsMeasurementCounters(
            rowPreferredHeightMeasurements: measurementCounters.rowPreferredHeightMeasurements,
            textLineMeasurements: measurementCounters.textLineMeasurements,
            controlFittingMeasurements: measurementCounters.controlFittingMeasurements + 1,
            cardHeightMeasurements: measurementCounters.cardHeightMeasurements
        )
    }

    fileprivate static func measuredSettingsCardHeight(
        rowsStack: NSStackView,
        separators: [NSView],
        rowHeight: ((NSView) -> CGFloat?)? = nil
    ) -> CGFloat {
        measurementCounters = DashboardSettingsMeasurementCounters(
            rowPreferredHeightMeasurements: measurementCounters.rowPreferredHeightMeasurements,
            textLineMeasurements: measurementCounters.textLineMeasurements,
            controlFittingMeasurements: measurementCounters.controlFittingMeasurements,
            cardHeightMeasurements: measurementCounters.cardHeightMeasurements + 1
        )
        return calculateSettingsCardHeight(
            rowsStack: rowsStack,
            separators: separators,
            rowHeight: rowHeight
        )
    }

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
        guard width > 0, !textField.stringValue.isEmpty else { return 0 }

        recordTextLineMeasurement()
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
        return lineCount
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
        invalidateSettingsRowContent(containing: label)
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
        scrollView.contentView = DashboardSettingsClipView()
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

        let documentView = DashboardSettingsDocumentView(sections: sections)
        switch renderingExperiment {
        case .baseline:
            break
        case .opaqueViewport:
            // Debug-only A/B: keep the scroll mechanics and document tree
            // unchanged while giving the viewport a stable opaque backing.
            scrollView.drawsBackground = true
            scrollView.backgroundColor = dashboardAdaptiveColor(
                light: NSColor(calibratedWhite: 0.94, alpha: 1),
                dark: NSColor(calibratedWhite: 0.12, alpha: 1)
            )
        case .documentLayer:
            // Debug-only A/B: isolate the document in one stable layer. This
            // intentionally remains opt-in because a long document can trade
            // redraw CPU for a larger backing store.
            documentView.wantsLayer = true
            documentView.layer?.isOpaque = true
            documentView.layer?.backgroundColor = dashboardAdaptiveColor(
                light: NSColor(calibratedWhite: 0.94, alpha: 1),
                dark: NSColor(calibratedWhite: 0.12, alpha: 1)
            ).cgColor
        }
        scrollView.documentView = documentView
        root.addSubview(viewportContainer)
        viewportContainer.addSubview(scrollView)
        // Match the measured titlebar/content-host breathing room without
        // making that space part of the scrollable document.
        let viewportTopInset: CGFloat = 52
        let viewportBottomInset: CGFloat = 0
        let documentHeightConstraint = documentView.heightAnchor.constraint(equalToConstant: 1)
        documentHeightConstraint.priority = .defaultHigh
        documentHeightConstraint.isActive = true
        documentView.documentHeightConstraint = documentHeightConstraint
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
        ])
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
        // The outer document now relays card geometry manually. Keep this
        // aggregate height required so AppKit cannot restore a stale card
        // frame after a row's width-sensitive intrinsic height changes.
        cardHeightConstraint.priority = .required
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
        calculateSettingsCardHeight(
            rowsStack: rowsStack,
            separators: separators,
            rowHeight: rowHeight
        )
    }

    private static func calculateSettingsCardHeight(
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
private final class DashboardSettingsDocumentSectionLayoutView: NSStackView {
    private let sections: [NSView]
    private(set) var contentHeight: CGFloat = 0
    private let horizontalInset: CGFloat = 34
    private let verticalSpacing: CGFloat = 28
    private let bottomInset: CGFloat = 34

    init(sections: [NSView]) {
        self.sections = sections
        super.init(frame: .zero)
        // This wrapper and its section children are placed by the manual
        // document layout below. Keeping them out of an outer Auto Layout
        // tree is the point of this container, so their current frames must
        // not be replaced by a zero-sized autoresizing-mask solution.
        translatesAutoresizingMaskIntoConstraints = true
        sections.forEach {
            $0.translatesAutoresizingMaskIntoConstraints = true
            addSubview($0)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    var naturalFittingSize: NSSize {
        let visibleSections = sections.filter { !$0.isHidden }
        guard !visibleSections.isEmpty else { return NSSize(width: 0, height: bottomInset) }
        let width = visibleSections.map { max(0, $0.fittingSize.width) }.max() ?? 0
        let height = visibleSections.reduce(CGFloat(0)) { total, section in
            total + max(1, section.fittingSize.height)
        } + CGFloat(max(0, visibleSections.count - 1)) * verticalSpacing + bottomInset
        return NSSize(width: width, height: height)
    }

    override func layout() {
        super.layout()
        let sectionWidth = max(0, bounds.width - horizontalInset * 2)
        var y: CGFloat = 0

        for section in sections {
            guard !section.isHidden else {
                section.frame = NSRect(x: horizontalInset, y: y, width: sectionWidth, height: 0)
                continue
            }

            section.setFrameOrigin(NSPoint(x: horizontalInset, y: y))
            section.setFrameSize(NSSize(width: sectionWidth, height: max(1, section.frame.height)))
            var measuredHeight = max(1, ceil(section.fittingSize.height))
            // A width change can first invalidate a row, then its card, then
            // the section stack. Give that local subtree a bounded second
            // pass so the manually propagated section height reflects the
            // row's final intrinsic height in the same resize transaction.
            for _ in 0..<3 {
                section.needsLayout = true
                section.layoutSubtreeIfNeeded()
                if let sectionStack = section as? NSStackView,
                   let card = sectionStack.arrangedSubviews
                    .compactMap({ $0 as? DashboardSettingsCardView })
                    .first {
                    card.synchronizeHeightForManualLayout()
                    let cardHeight = max(1, ceil(card.fittingSize.height))
                    if abs(card.frame.height - cardHeight) > 0.5 {
                        card.setFrameSize(NSSize(width: sectionWidth, height: cardHeight))
                        card.layoutSubtreeIfNeeded()
                    }
                    section.invalidateIntrinsicContentSize()
                    section.needsUpdateConstraints = true
                    section.updateConstraintsForSubtreeIfNeeded()
                    section.needsLayout = true
                    section.layoutSubtreeIfNeeded()
                    measuredHeight = layoutSectionStack(sectionStack, width: sectionWidth)
                } else {
                    measuredHeight = max(1, ceil(section.fittingSize.height))
                }
                let heightChanged = abs(section.frame.height - measuredHeight) > 0.5
                section.setFrameSize(NSSize(width: sectionWidth, height: measuredHeight))
                if !heightChanged { break }
            }
            section.needsLayout = true
            section.layoutSubtreeIfNeeded()
            y += measuredHeight + verticalSpacing
        }

        contentHeight = max(0, y - (sections.isEmpty ? 0 : verticalSpacing) + bottomInset)
    }

    private func layoutSectionStack(_ section: NSStackView, width: CGFloat) -> CGFloat {
        let visibleSubviews = section.arrangedSubviews.filter { !$0.isHidden }
        guard !visibleSubviews.isEmpty else {
            section.setFrameSize(NSSize(width: width, height: 1))
            return 1
        }

        let heights = visibleSubviews.map { view -> CGFloat in
            if let card = view as? DashboardSettingsCardView {
                card.synchronizeHeightForManualLayout()
                let height = max(1, ceil(card.fittingSize.height))
                card.setFrameSize(NSSize(width: width, height: height))
                card.layoutSubtreeIfNeeded()
                return max(height, ceil(card.fittingSize.height))
            }
            return max(1, ceil(view.fittingSize.height))
        }
        let totalHeight = max(
            1,
            heights.reduce(CGFloat(0), +) +
                max(0, CGFloat(visibleSubviews.count - 1)) * section.spacing
        )
        section.setFrameSize(NSSize(width: width, height: totalHeight))

        let orderedSubviews: [NSView] = section.isFlipped
            ? visibleSubviews
            : Array(visibleSubviews.reversed())
        var y: CGFloat = 0
        for view in orderedSubviews {
            let height = max(1, ceil(view.fittingSize.height))
            let viewWidth = view is DashboardSettingsCardView ? width : min(width, max(1, ceil(view.fittingSize.width)))
            view.setFrameOrigin(NSPoint(x: 0, y: y))
            view.setFrameSize(NSSize(width: viewWidth, height: height))
            view.layoutSubtreeIfNeeded()
            y += height + section.spacing
        }
        return totalHeight
    }
}

final class DashboardSettingsDocumentView: NSView {
    private let sectionLayoutView: DashboardSettingsDocumentSectionLayoutView
    weak var documentHeightConstraint: NSLayoutConstraint?

    init(sections: [NSView]) {
        sectionLayoutView = DashboardSettingsDocumentSectionLayoutView(sections: sections)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(sectionLayoutView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override var fittingSize: NSSize {
        let naturalSize = sectionLayoutView.naturalFittingSize
        return NSSize(
            width: naturalSize.width + 68,
            height: naturalSize.height
        )
    }

    override func layout() {
        super.layout()
        sectionLayoutView.setFrameSize(NSSize(width: bounds.width, height: max(bounds.height, 1)))
        sectionLayoutView.layoutSubtreeIfNeeded()
        let contentHeight = max(
            sectionLayoutView.contentHeight,
            enclosingScrollView?.contentView.bounds.height ?? superview?.bounds.height ?? 0
        )
        if let documentHeightConstraint,
           abs(documentHeightConstraint.constant - contentHeight) > 0.5 {
            documentHeightConstraint.constant = contentHeight
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        DashboardSettingsComponents.recordDocumentDraw()
        super.draw(dirtyRect)
    }

    override func updateLayer() {
        DashboardSettingsComponents.recordDocumentLayerUpdate()
        super.updateLayer()
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        DashboardSettingsComponents.recordDocumentDisplayInvalidation()
        super.setNeedsDisplay(invalidRect)
    }
}

/// Hosts a settings scroll view in a top-origin coordinate system. The class
/// only supplies AppKit's coordinate convention; it does not write bounds or
/// participate in user scrolling.
final class DashboardSettingsPageView: NSView {
    override var isFlipped: Bool { true }

    override var fittingSize: NSSize {
        guard let viewportContainer = subviews.first,
              let scrollView = viewportContainer.subviews.first(where: { $0 is NSScrollView }) as? NSScrollView,
              let documentView = scrollView.documentView as? DashboardSettingsDocumentView else {
            return super.fittingSize
        }
        // Report the natural width for localization/fitting tests, but do not
        // make the scroll document's height resize a host window. The real
        // Dashboard mounts this page in a frame-managed content host.
        return NSSize(width: documentView.fittingSize.width, height: NSView.noIntrinsicMetric)
    }

    override func draw(_ dirtyRect: NSRect) {
        DashboardSettingsComponents.recordPageDraw()
        super.draw(dirtyRect)
    }

    override func updateLayer() {
        DashboardSettingsComponents.recordPageLayerUpdate()
        super.updateLayer()
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        DashboardSettingsComponents.recordPageDisplayInvalidation()
        super.setNeedsDisplay(invalidRect)
    }
}
