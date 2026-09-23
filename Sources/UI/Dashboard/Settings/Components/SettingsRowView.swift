import AppKit

/// A subtitle label that keeps localization metadata available while AppKit
/// solves the native row's label width. The display copy may gain explicit
/// semantic line breaks at the solved width; the source value remains intact
/// for accessibility and later updates.
final class SettingsSemanticSubtitleLabel: NSTextField {
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
        usesSingleLineMode = false
        lineBreakMode = .byWordWrapping
        maximumNumberOfLines = 0
        cell?.wraps = true
        cell?.isScrollable = false
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

    /// Localization source, without layout-inserted line breaks.
    var sourceAccessibilityText: String {
        localizedSubtitle?.text ?? stringValue
    }
}

/// AppKit accessibility relationships for a settings title and one standard
/// trailing control. Multi-control accessories keep their existing labels.
enum DashboardSettingsAccessibility {
    static func bind(
        titleLabel: NSTextField,
        detailLabel: NSTextField?,
        accessory: NSView?
    ) {
        guard let control = primaryStandardControl(in: accessory) else {
            return
        }
        if hasExplicitProductLabel(control, rowTitle: titleLabel.stringValue) {
            if (control.accessibilityTitleUIElement() as AnyObject?) === titleLabel {
                control.setAccessibilityTitleUIElement(nil)
                titleLabel.setAccessibilityElement(true)
            }
            return
        }

        control.setAccessibilityTitleUIElement(titleLabel)
        titleLabel.setAccessibilityElement(false)

        if let detailLabel, !detailLabel.isHidden {
            let help = sourceAccessibilityText(of: detailLabel)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !help.isEmpty {
                control.setAccessibilityHelp(help)
                detailLabel.setAccessibilityElement(false)
            }
        }
    }

    static func primaryStandardControl(in accessory: NSView?) -> NSView? {
        guard let accessory else { return nil }
        if accessory is QuotaColorThresholdSlider {
            return nil
        }
        if accessory is NSTableView || accessory is NSScrollView {
            return nil
        }
        if let compact = accessory as? DashboardSettingsComponents.CompactNumericFieldAccessory {
            return compact.field
        }
        if isStandardBindableControl(accessory) {
            return accessory
        }
        guard let stack = accessory as? NSStackView else { return nil }
        let candidates = stack.arrangedSubviews.compactMap { subview -> NSView? in
            if let compact = subview as? DashboardSettingsComponents.CompactNumericFieldAccessory {
                return compact.field
            }
            return isStandardBindableControl(subview) ? subview : nil
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private static func isStandardBindableControl(_ view: NSView) -> Bool {
        if view is NSSwitch { return true }
        if view is NSPopUpButton { return true }
        if let field = view as? NSTextField, field.isEditable { return true }
        return false
    }

    private static func hasExplicitProductLabel(_ control: NSView, rowTitle: String) -> Bool {
        if control is NSSwitch {
            return false
        }
        let label = (control.accessibilityLabel() ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return false }
        if label == rowTitle { return false }
        if let popup = control as? NSPopUpButton {
            let selected = popup.titleOfSelectedItem ?? popup.selectedItem?.title ?? ""
            if label == selected { return false }
        }
        if let field = control as? NSTextField, field.isEditable {
            if label == field.stringValue { return false }
            if let placeholder = field.placeholderString, label == placeholder { return false }
        }
        return true
    }

    private static func sourceAccessibilityText(of label: NSTextField) -> String {
        if let semantic = label as? SettingsSemanticSubtitleLabel {
            return semantic.sourceAccessibilityText
        }
        return label.stringValue
    }
}

/// Hosts that still own card height (the native settings card) can remeasure
/// after a native row's wrapping width changes.
protocol SettingsRowHeightInvalidating: AnyObject {
    func invalidateHostedSettingsRowHeight()
}

/// Native Auto Layout settings row: title, optional detail, trailing control.
///
/// The row itself is an `NSView` so the 62pt floor can live on the outer view
/// (centerY + inequality padding) without a parent-side measurement pass. Making
/// `SettingsRowView` an `NSStackView` stretched the nested labels stack to the
/// inner 40pt and then stretched the title field, which kept a 2pt *frame* gap
/// while the drawn glyphs sat much farther apart.
final class SettingsRowView: NSView {
    static var minimumHeight: CGFloat { DashboardSettingsComponents.standardRowHeight }
    static let horizontalPadding: CGFloat = 20
    static let verticalPadding: CGFloat = 11
    static let contentSpacing: CGFloat = 20
    static let labelSpacing: CGFloat = 2
    static let titleAccessorySpacing: CGFloat = 6
    /// Floor for the labels column when it shares a row with an accessory.
    /// This is a geometric inset, not a window-width breakpoint.
    static let minimumInlineLabelWidth: CGFloat = 120

    let titleLabel: NSTextField
    let detailLabel: NSTextField
    let titleHeaderStack = NSStackView()
    private(set) var titleAccessory: NSView?
    private(set) var accessoryView: NSView?

    private let rowMinimumHeight: CGFloat
    private let rowVerticalPadding: CGFloat
    private let forceDedicatedControlRow: Bool

    let contentStack = NSStackView()
    let labelsStack: NSStackView = SettingsLabelsStackView()
    private let ownsTitleLabel: Bool
    private let ownsDetailLabel: Bool
    private var stacksVertically = false
    private var detailWidthConstraint: NSLayoutConstraint?
    private var dedicatedLabelsWidthConstraint: NSLayoutConstraint?
    private var wrappingHeightIsDirty = false
    private var wrappingCommitWorkItem: DispatchWorkItem?
    private var isPerformingLayout = false
    private var accessoryNaturalWidthConstraint: NSLayoutConstraint?
    private var searchNaturalHeightConstraint: NSLayoutConstraint?
    private var labelsMinimumHeightConstraint: NSLayoutConstraint?

    init(
        title: String,
        detail: String? = nil,
        titleLabel: NSTextField? = nil,
        detailLabel: NSTextField? = nil,
        titleAccessory: NSView? = nil,
        accessoryView: NSView? = nil,
        minimumHeight: CGFloat = SettingsRowView.minimumHeight,
        verticalPadding: CGFloat = SettingsRowView.verticalPadding,
        forceDedicatedControlRow: Bool = false
    ) {
        ownsTitleLabel = titleLabel == nil
        ownsDetailLabel = detailLabel == nil
        self.titleLabel = titleLabel ?? SettingsWrappingLabel(string: title)
        self.detailLabel = detailLabel ?? SettingsWrappingLabel(string: detail ?? "")
        self.titleAccessory = titleAccessory
        self.accessoryView = accessoryView
        rowMinimumHeight = max(SettingsRowView.minimumHeight, minimumHeight)
        rowVerticalPadding = max(0, verticalPadding)
        self.forceDedicatedControlRow = forceDedicatedControlRow
        super.init(frame: .zero)
        configure(
            title: title,
            detail: detail,
            titleAccessory: titleAccessory,
            accessoryView: accessoryView
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isHidden: Bool {
        get { super.isHidden }
        set {
            DashboardSearchVisibility.writeHidden(self, newValue) { super.isHidden = $0 }
        }
    }

    private var hasSearchHiddenSiblingInOwningCard: Bool {
        var ancestor = superview
        while let view = ancestor {
            if let card = view as? SettingsSectionCardView {
                return card.arrangedSubviews.contains { sibling in
                    sibling !== self && DashboardSearchVisibility.isSearchHidden(sibling)
                }
            }
            ancestor = view.superview
        }
        return false
    }

    static func enclosing(_ view: NSView) -> SettingsRowView? {
        var current: NSView? = view
        while let candidate = current {
            if let row = candidate as? SettingsRowView {
                return row
            }
            current = candidate.superview
        }
        return nil
    }

    override func layout() {
        isPerformingLayout = true
        syncAdaptiveAccessory()
        updateAccessoryNaturalWidthLock()
        super.layout()
        // Constraint solver has already set this row's and contentStack's
        // frames. Force the content stack to re-layout against those frames so
        // labelsStack.bounds.width is the solved column, including when the
        // row grows and AppKit would otherwise skip a laid-out subtree.
        contentStack.needsLayout = true
        contentStack.layoutSubtreeIfNeeded()
        recordSolvedWrappingWidthIfNeeded()
        updateSearchNaturalHeightConstraint()
        isPerformingLayout = false
        scheduleWrappingHeightCommitIfNeeded()
    }

    private func updateSearchNaturalHeightConstraint() {
        guard hasSearchHiddenSiblingInOwningCard else {
            searchNaturalHeightConstraint?.isActive = false
            return
        }

        let naturalHeight = hostedCardHeight()
        if let searchNaturalHeightConstraint {
            if abs(searchNaturalHeightConstraint.constant - naturalHeight) > 0.5 {
                searchNaturalHeightConstraint.constant = naturalHeight
            }
            searchNaturalHeightConstraint.isActive = true
            return
        }

        let constraint = heightAnchor.constraint(equalToConstant: naturalHeight)
        constraint.isActive = true
        searchNaturalHeightConstraint = constraint
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            cancelPendingWrappingHeightCommit()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        bindAccessibility()
    }

    deinit {
        wrappingCommitWorkItem?.cancel()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        refreshWrappingLayout()
    }

    /// Apply wrapping from the current bounds and update intrinsic height.
    /// Call only outside an in-flight window layout pass.
    func refreshWrappingLayout() {
        cancelPendingWrappingHeightCommitKeepingDirtyFlag()
        syncAdaptiveAccessory()
        needsLayout = true
        layoutSubtreeIfNeeded()
        wrappingHeightIsDirty = true
        performScheduledWrappingHeightCommit()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// Runs the same coalesced height commit production schedules after
    /// `layout()`. Tests use this to observe the mouse-down path without
    /// calling `refreshWrappingLayout()` (the mouse-up settle).
    func flushPendingWrappingHeightCommitForTesting() {
        wrappingCommitWorkItem?.cancel()
        performScheduledWrappingHeightCommit()
    }

    static func flushPendingWrappingHeightCommits(in view: NSView) {
        if let row = view as? SettingsRowView {
            row.flushPendingWrappingHeightCommitForTesting()
        }
        view.subviews.forEach { flushPendingWrappingHeightCommits(in: $0) }
    }

    func updateDetail(_ text: String?) {
        let detailText = text ?? ""
        detailLabel.stringValue = detailText
        detailLabel.lineBreakMode = DashboardSettingsComponents.settingsSubtitleLineBreakMode(
            for: detailText
        )
        let shouldShow = !detailText.isEmpty
        if shouldShow, detailLabel.superview == nil {
            labelsStack.addArrangedSubview(detailLabel)
            installDetailWidthConstraintIfNeeded()
        } else if !shouldShow, detailLabel.superview != nil {
            detailWidthConstraint?.isActive = false
            labelsStack.removeArrangedSubview(detailLabel)
            detailLabel.removeFromSuperview()
        }
        detailLabel.isHidden = !shouldShow
        detailLabel.invalidateIntrinsicContentSize()
        wrappingHeightIsDirty = true
        refreshWrappingLayout()
        notifyHeightHost()
        bindAccessibility()
    }

    /// Invalidates the row after a caller updates a supplied title or detail
    /// label in place (for example a localized subtitle or inline link).
    /// Native sections derive their height from the row's intrinsic content;
    /// no parent-side fitting-size measurement is needed.
    func invalidateAfterContentChange() {
        titleLabel.invalidateIntrinsicContentSize()
        detailLabel.invalidateIntrinsicContentSize()
        labelsStack.invalidateIntrinsicContentSize()
        contentStack.invalidateIntrinsicContentSize()
        wrappingHeightIsDirty = true
        refreshWrappingLayout()
        notifyHeightHost()
        bindAccessibility()
    }

    /// Content height used by the compatibility section factory. Not an
    /// Auto Layout intrinsic size — an equal height constraint on the row
    /// itself would resurrect the legacy measurement engine.
    func hostedCardHeight() -> CGFloat {
        let labelsHeight = labelsContentHeight()
        let accessoryHeight: CGFloat
        if let accessoryView, !accessoryView.isHidden {
            let intrinsic = accessoryView.intrinsicContentSize.height
            if intrinsic > 0, intrinsic != NSView.noIntrinsicMetric {
                accessoryHeight = intrinsic
            } else if accessoryView.bounds.height > 1 {
                accessoryHeight = accessoryView.bounds.height
            } else {
                accessoryHeight = 0
            }
        } else {
            accessoryHeight = 0
        }
        let contentHeight = stacksVertically
            ? labelsHeight
                + DashboardSettingsComponents.settingsRowContentControlSpacing
                + accessoryHeight
            : max(labelsHeight, accessoryHeight)
        return max(rowMinimumHeight, contentHeight + rowVerticalPadding * 2)
    }

    private func recordSolvedWrappingWidthIfNeeded() {
        let labelWidth = wrappingWidthForLabels()
        guard labelWidth > 1 else {
            wrappingHeightIsDirty = true
            return
        }
        let titleWidth = wrappingWidthForTitle(labelWidth: labelWidth)
        guard wrappingNeedsUpdate(titleWidth: titleWidth, labelWidth: labelWidth) else { return }
        wrappingHeightIsDirty = true
        // Assign wrapping now so title and detail share the solved column
        // before the deferred ICS commit. Do not invalidate ICS here:
        // that is what caused Update Constraints loops inside layout().
        writeWrappingWidths(
            titleWidth: titleWidth,
            labelWidth: labelWidth,
            invalidateLabels: false
        )
    }

    private func scheduleWrappingHeightCommitIfNeeded() {
        guard wrappingHeightIsDirty else { return }
        guard !isPerformingLayout else { return }
        guard wrappingCommitWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.performScheduledWrappingHeightCommit()
        }
        wrappingCommitWorkItem = work
        DispatchQueue.main.async(execute: work)
    }

    private func performScheduledWrappingHeightCommit() {
        wrappingCommitWorkItem = nil
        guard wrappingHeightIsDirty else { return }
        let labelWidth = wrappingWidthForLabels()
        guard labelWidth > 1 else {
            needsLayout = true
            return
        }
        let titleWidth = wrappingWidthForTitle(labelWidth: labelWidth)
        wrappingHeightIsDirty = false
        writeWrappingWidths(
            titleWidth: titleWidth,
            labelWidth: labelWidth,
            invalidateLabels: true
        )
        labelsStack.invalidateIntrinsicContentSize()
        contentStack.invalidateIntrinsicContentSize()
        updateLabelsMinimumHeight()
        invalidateIntrinsicContentSize()
        labelsStack.needsLayout = true
        contentStack.needsLayout = true
        needsLayout = true
        notifyHeightHost()
    }

    private func writeWrappingWidths(
        titleWidth: CGFloat,
        labelWidth: CGFloat,
        invalidateLabels: Bool
    ) {
        if invalidateLabels {
            titleLabel.preferredMaxLayoutWidth = titleWidth
            if !detailLabel.isHidden {
                detailLabel.preferredMaxLayoutWidth = labelWidth
            }
            titleLabel.invalidateIntrinsicContentSize()
            if !detailLabel.isHidden {
                detailLabel.invalidateIntrinsicContentSize()
            }
            return
        }
        if let wrappingTitle = titleLabel as? SettingsWrappingLabel {
            wrappingTitle.setPreferredMaxLayoutWidthWithoutInvalidation(titleWidth)
        } else {
            titleLabel.preferredMaxLayoutWidth = titleWidth
        }
        if !detailLabel.isHidden {
            if let wrappingDetail = detailLabel as? SettingsWrappingLabel {
                wrappingDetail.setPreferredMaxLayoutWidthWithoutInvalidation(labelWidth)
            } else {
                detailLabel.preferredMaxLayoutWidth = labelWidth
            }
        }
    }

    private func cancelPendingWrappingHeightCommit() {
        wrappingCommitWorkItem?.cancel()
        wrappingCommitWorkItem = nil
        wrappingHeightIsDirty = false
    }

    private func cancelPendingWrappingHeightCommitKeepingDirtyFlag() {
        wrappingCommitWorkItem?.cancel()
        wrappingCommitWorkItem = nil
    }

    private func wrappingNeedsUpdate(titleWidth: CGFloat, labelWidth: CGFloat) -> Bool {
        if abs(titleLabel.preferredMaxLayoutWidth - titleWidth) > 0.5 {
            return true
        }
        if !detailLabel.isHidden,
           abs(detailLabel.preferredMaxLayoutWidth - labelWidth) > 0.5 {
            return true
        }
        return false
    }

    private func wrappingWidthForLabels() -> CGFloat {
        let laidOut = labelsStack.bounds.width
        if laidOut > 1 { return laidOut }
        let available = max(0, bounds.width - Self.horizontalPadding * 2)
        guard available > 1 else { return 0 }
        if stacksVertically || accessoryView == nil || accessoryView?.isHidden == true {
            return available
        }
        let accessoryWidth: CGFloat
        if let adaptive = accessoryView as? SettingsRowAccessoryLayout {
            accessoryWidth = adaptive.naturalAccessoryWidth
        } else if let accessoryView {
            accessoryWidth = Self.naturalWidth(of: accessoryView)
        } else {
            accessoryWidth = 0
        }
        guard accessoryWidth > 1 else { return available }
        return max(0, available - accessoryWidth - Self.contentSpacing)
    }

    private func wrappingWidthForTitle(labelWidth: CGFloat) -> CGFloat {
        guard let titleAccessory, !titleAccessory.isHidden else { return labelWidth }
        let accessoryWidth: CGFloat
        if titleAccessory.bounds.width > 1 {
            accessoryWidth = titleAccessory.bounds.width
        } else {
            let intrinsic = titleAccessory.intrinsicContentSize.width
            accessoryWidth = intrinsic > 1 && intrinsic != NSView.noIntrinsicMetric
                ? intrinsic
                : 0
        }
        guard accessoryWidth > 0 else { return labelWidth }
        return max(0, labelWidth - accessoryWidth - Self.titleAccessorySpacing)
    }

    private func configure(
        title: String,
        detail: String?,
        titleAccessory: NSView?,
        accessoryView: NSView?
    ) {
        identifier = DashboardPageSearch.rowIdentifier
        DashboardPageSearch.markSearchableRow(self)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)

        configureLabel(
            titleLabel,
            text: title,
            font: .systemFont(ofSize: 14, weight: .semibold),
            color: .labelColor,
            overwriteContent: ownsTitleLabel
        )
        let detailText = detail ?? detailLabel.stringValue
        configureLabel(
            detailLabel,
            text: detailText,
            font: .systemFont(ofSize: 12),
            color: .secondaryLabelColor,
            overwriteContent: ownsDetailLabel
        )
        detailLabel.isHidden = detailText.isEmpty

        labelsStack.orientation = .vertical
        labelsStack.alignment = .leading
        labelsStack.spacing = Self.labelSpacing
        labelsStack.translatesAutoresizingMaskIntoConstraints = false
        labelsStack.setHuggingPriority(.required, for: .vertical)
        labelsStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labelsStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        labelsStack.setContentHuggingPriority(.required, for: .vertical)
        labelsStack.setContentCompressionResistancePriority(.required, for: .vertical)
        if let titleAccessory {
            titleHeaderStack.orientation = .horizontal
            titleHeaderStack.alignment = .centerY
            titleHeaderStack.spacing = Self.titleAccessorySpacing
            titleHeaderStack.translatesAutoresizingMaskIntoConstraints = false
            titleHeaderStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
            titleHeaderStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            titleAccessory.translatesAutoresizingMaskIntoConstraints = false
            titleAccessory.setContentHuggingPriority(.required, for: .horizontal)
            titleAccessory.setContentCompressionResistancePriority(.required, for: .horizontal)
            titleHeaderStack.addArrangedSubview(titleLabel)
            titleHeaderStack.addArrangedSubview(titleAccessory)
            labelsStack.addArrangedSubview(titleHeaderStack)
        } else {
            labelsStack.addArrangedSubview(titleLabel)
        }
        if !detailLabel.isHidden {
            labelsStack.addArrangedSubview(detailLabel)
            installDetailWidthConstraintIfNeeded()
        }

        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.distribution = .fill
        contentStack.spacing = Self.contentSpacing
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.setHuggingPriority(.required, for: .vertical)
        contentStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        contentStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contentStack.setContentHuggingPriority(.required, for: .vertical)
        contentStack.setContentCompressionResistancePriority(.required, for: .vertical)
        contentStack.addArrangedSubview(labelsStack)
        if let accessoryView {
            accessoryView.translatesAutoresizingMaskIntoConstraints = false
            accessoryView.setContentHuggingPriority(.required, for: .horizontal)
            if accessoryView is SettingsRowAccessoryLayout {
                accessoryView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            } else {
                accessoryView.setContentCompressionResistancePriority(.required, for: .horizontal)
            }
            accessoryView.setContentHuggingPriority(.defaultHigh, for: .vertical)
            accessoryView.setContentCompressionResistancePriority(.required, for: .vertical)
            contentStack.addArrangedSubview(accessoryView)
        }

        addSubview(contentStack)
        var constraints: [NSLayoutConstraint] = [
            contentStack.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Self.horizontalPadding
            ),
            contentStack.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Self.horizontalPadding
            ),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            contentStack.topAnchor.constraint(
                greaterThanOrEqualTo: topAnchor,
                constant: rowVerticalPadding
            ),
            contentStack.bottomAnchor.constraint(
                lessThanOrEqualTo: bottomAnchor,
                constant: -rowVerticalPadding
            ),
            heightAnchor.constraint(greaterThanOrEqualToConstant: rowMinimumHeight),
            heightAnchor.constraint(
                greaterThanOrEqualTo: contentStack.heightAnchor,
                constant: rowVerticalPadding * 2
            ),
            contentStack.heightAnchor.constraint(greaterThanOrEqualTo: labelsStack.heightAnchor)
        ]
        if let accessoryView {
            constraints.append(
                accessoryView.widthAnchor.constraint(
                    lessThanOrEqualTo: widthAnchor,
                    constant: -(Self.horizontalPadding * 2)
                )
            )
        }
        NSLayoutConstraint.activate(constraints)
        bindAccessibility()
    }

    private func bindAccessibility() {
        DashboardSettingsAccessibility.bind(
            titleLabel: titleLabel,
            detailLabel: detailLabel.isHidden ? nil : detailLabel,
            accessory: accessoryView
        )
    }

    private func configureLabel(
        _ label: NSTextField,
        text: String,
        font: NSFont,
        color: NSColor,
        overwriteContent: Bool
    ) {
        if overwriteContent, !(label is SettingsSemanticSubtitleLabel) {
            label.stringValue = text
        }
        label.font = font
        label.textColor = color
        label.isEditable = false
        label.isSelectable = false
        label.usesSingleLineMode = false
        let wrappingText = overwriteContent || label.stringValue.isEmpty ? text : label.stringValue
        if label is SettingsSemanticSubtitleLabel {
            label.lineBreakMode = DashboardSettingsComponents.settingsSubtitleLineBreakMode(
                for: LocalizedSubtitle(text: wrappingText)
            )
        } else {
            label.lineBreakMode = DashboardSettingsComponents.settingsSubtitleLineBreakMode(for: wrappingText)
        }
        label.maximumNumberOfLines = 0
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        label.setContentHuggingPriority(.required, for: .vertical)
    }

    private func installDetailWidthConstraintIfNeeded() {
        guard detailLabel.superview != nil else { return }
        if detailWidthConstraint == nil {
            detailWidthConstraint = detailLabel.widthAnchor.constraint(equalTo: labelsStack.widthAnchor)
        }
        detailWidthConstraint?.isActive = true
    }

    private func syncAdaptiveAccessory() {
        guard let accessoryView, !accessoryView.isHidden else { return }
        let availableWidth = max(0, bounds.width - Self.horizontalPadding * 2)
        if let adaptive = accessoryView as? SettingsRowAccessoryLayout {
            adaptive.updateAvailableRowWidth(availableWidth)
        }
        // Control orientation (horizontal vs vertical) is independent of row
        // placement (inline / vertical-beside / dedicated-below). Measure
        // leftover label width against the accessory's natural width for its
        // current orientation, never the stack's compressed fitting size.
        // Ordinary controls use the same 120pt leftover floor unless an
        // adaptive accessory opts out with minimumInlineLabelWidth == 0.
        let placeOnDedicatedRow = forceDedicatedControlRow
            || shouldPlaceAccessoryOnDedicatedRow(availableWidth: availableWidth)
        applyVerticalStacking(placeOnDedicatedRow)
        updateAccessoryNaturalWidthLock()
    }

    private func updateAccessoryNaturalWidthLock() {
        guard let accessoryView, !accessoryView.isHidden else { return }
        if stacksVertically {
            accessoryNaturalWidthConstraint?.isActive = false
            return
        }
        let naturalWidth: CGFloat
        if let adaptive = accessoryView as? SettingsRowAccessoryLayout {
            naturalWidth = adaptive.naturalAccessoryWidth
        } else {
            naturalWidth = Self.naturalWidth(of: accessoryView)
        }
        guard naturalWidth > 1 else {
            accessoryNaturalWidthConstraint?.isActive = false
            return
        }
        if let constraint = accessoryNaturalWidthConstraint {
            constraint.constant = naturalWidth
            constraint.isActive = true
            return
        }
        let constraint = accessoryView.widthAnchor.constraint(equalToConstant: naturalWidth)
        constraint.priority = NSLayoutConstraint.Priority(999)
        constraint.isActive = true
        accessoryNaturalWidthConstraint = constraint
    }

    private static func naturalWidth(of view: NSView) -> CGFloat {
        if let stack = view as? NSStackView {
            let visible = stack.arrangedSubviews.filter { !$0.isHidden }
            let widths = visible.map(naturalWidth(of:))
            if stack.orientation == .vertical {
                return widths.max() ?? 0
            }
            return widths.reduce(0, +) + max(0, CGFloat(visible.count - 1)) * stack.spacing
        }
        let fitting = view.fittingSize.width
        return fitting.isFinite && fitting > 0 ? fitting : 0
    }

    private func shouldPlaceAccessoryOnDedicatedRow(availableWidth: CGFloat) -> Bool {
        guard let accessoryView,
              !accessoryView.isHidden,
              availableWidth > 0
        else { return false }
        let minimumLabelWidth: CGFloat
        let naturalWidth: CGFloat
        if let adaptive = accessoryView as? SettingsRowAccessoryLayout {
            minimumLabelWidth = adaptive.minimumInlineLabelWidth
            naturalWidth = adaptive.naturalAccessoryWidth
        } else {
            minimumLabelWidth = Self.minimumInlineLabelWidth
            naturalWidth = Self.naturalWidth(of: accessoryView)
        }
        guard minimumLabelWidth > 0 else { return false }
        let remainingWhenBeside = availableWidth
            - max(1, naturalWidth)
            - Self.contentSpacing
        return remainingWhenBeside + 0.5 < minimumLabelWidth
    }

    private func applyVerticalStacking(_ vertical: Bool) {
        guard stacksVertically != vertical else { return }
        stacksVertically = vertical
        if dedicatedLabelsWidthConstraint == nil {
            let constraint = labelsStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor)
            // NSStackView keeps required side-by-side constraints for one pass
            // after orientation flips. Stay below required so that leftover
            // pass cannot unsatisfy the row.
            constraint.priority = NSLayoutConstraint.Priority(999)
            dedicatedLabelsWidthConstraint = constraint
        }
        if vertical {
            contentStack.orientation = .vertical
            contentStack.alignment = .trailing
            contentStack.spacing = DashboardSettingsComponents.settingsRowContentControlSpacing
            accessoryView?.setContentHuggingPriority(.required, for: .horizontal)
            dedicatedLabelsWidthConstraint?.isActive = true
        } else {
            dedicatedLabelsWidthConstraint?.isActive = false
            contentStack.orientation = .horizontal
            contentStack.alignment = .centerY
            contentStack.spacing = Self.contentSpacing
            accessoryView?.setContentHuggingPriority(.required, for: .horizontal)
        }
        wrappingHeightIsDirty = true
        if isPerformingLayout {
            needsLayout = true
            return
        }
        invalidateIntrinsicContentSize()
        notifyHeightHost()
        needsLayout = true
    }

    private func labelsContentHeight() -> CGFloat {
        let titleHeight = measuredFieldHeight(titleLabel, isTitle: true)
        guard !detailLabel.isHidden else { return titleHeight }
        return titleHeight + Self.labelSpacing + measuredFieldHeight(detailLabel, isTitle: false)
    }

    private func measuredFieldHeight(_ field: NSTextField, isTitle: Bool) -> CGFloat {
        let solved = wrappingWidthForLabels()
        let width: CGFloat
        if solved > 1 {
            width = isTitle ? wrappingWidthForTitle(labelWidth: solved) : solved
        } else if field.preferredMaxLayoutWidth > 1 {
            width = field.preferredMaxLayoutWidth
        } else {
            width = field.bounds.width
        }
        return SettingsTextHeight.measured(field, at: width)
    }

    private func updateLabelsMinimumHeight() {
        let height = labelsContentHeight()
        guard height > 1 else { return }
        if let constraint = labelsMinimumHeightConstraint {
            if abs(constraint.constant - height) > 0.5 {
                constraint.constant = height
            }
            constraint.isActive = true
            return
        }
        let constraint = labelsStack.heightAnchor.constraint(greaterThanOrEqualToConstant: height)
        constraint.priority = .required
        constraint.isActive = true
        labelsMinimumHeightConstraint = constraint
    }

    private func notifyHeightHost() {
        var current: NSView? = superview
        while let view = current {
            if let host = view as? SettingsRowHeightInvalidating {
                host.invalidateHostedSettingsRowHeight()
                return
            }
            current = view.superview
        }
    }
}

/// Vertical labels stack that exports a real intrinsic height from its
/// arranged fields. A plain `NSStackView` reports `noIntrinsicMetric`, so a
/// taller fixed accessory (the 42pt Menu Bar preview) can win the horizontal
/// stack and clip wrapped title/detail text.
private final class SettingsLabelsStackView: NSStackView {
    override var intrinsicContentSize: NSSize {
        let height = arrangedContentHeight()
        return NSSize(
            width: NSView.noIntrinsicMetric,
            height: height > 0 ? height : NSView.noIntrinsicMetric
        )
    }

    private func arrangedContentHeight() -> CGFloat {
        let visible = arrangedSubviews.filter { !$0.isHidden }
        let heights = visible.map(measuredHeight).filter { $0 > 0 }
        guard !heights.isEmpty else { return 0 }
        return heights.reduce(0, +) + spacing * CGFloat(max(0, heights.count - 1))
    }

    private func measuredHeight(_ view: NSView) -> CGFloat {
        if let field = view as? NSTextField {
            let width = field.preferredMaxLayoutWidth > 1
                ? field.preferredMaxLayoutWidth
                : field.bounds.width
            return SettingsTextHeight.measured(field, at: width)
        }
        if let stack = view as? NSStackView {
            let visible = stack.arrangedSubviews.filter { !$0.isHidden }
            let heights = visible.map(measuredHeight).filter { $0 > 0 }
            guard !heights.isEmpty else { return 0 }
            if stack.orientation == .vertical {
                return heights.reduce(0, +) + stack.spacing * CGFloat(max(0, heights.count - 1))
            }
            return heights.max() ?? 0
        }
        let intrinsic = view.intrinsicContentSize.height
        guard intrinsic > 0, intrinsic != NSView.noIntrinsicMetric else { return 0 }
        return intrinsic
    }
}

/// Height of a wrapping settings label at a solved column width. Unconstrained
/// `intrinsicContentSize` is ignored because AppKit reports a stacked glyph
/// height when `preferredMaxLayoutWidth` is still 0.
private enum SettingsTextHeight {
    static func measured(_ field: NSTextField, at width: CGFloat) -> CGFloat {
        let fontHeight = ceil(
            (field.font ?? NSFont.systemFont(ofSize: 12)).boundingRectForFont.height
        )
        guard width > 1, let cell = field.cell else { return fontHeight }
        let fitted = cell.cellSize(
            forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        ).height
        return max(fontHeight, fitted)
    }
}

/// Wrapping label whose `preferredMaxLayoutWidth` can be assigned during
/// `layout()` without dirtying the window constraint pass.
private final class SettingsWrappingLabel: NSTextField {
    private var suppressIntrinsicInvalidation = false

    convenience init(string: String) {
        self.init(labelWithString: string)
    }

    func setPreferredMaxLayoutWidthWithoutInvalidation(_ width: CGFloat) {
        suppressIntrinsicInvalidation = true
        preferredMaxLayoutWidth = width
        suppressIntrinsicInvalidation = false
    }

    override func invalidateIntrinsicContentSize() {
        guard !suppressIntrinsicInvalidation else { return }
        super.invalidateIntrinsicContentSize()
    }
}
