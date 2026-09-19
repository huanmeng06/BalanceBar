import AppKit

/// Hosts that still own card height (the legacy settings card) can remeasure
/// after a native row's wrapping width changes.
protocol SettingsRowHeightInvalidating: AnyObject {
    func invalidateHostedSettingsRowHeight()
}

/// Native Auto Layout settings row: title, optional detail, trailing control.
///
/// The row itself is an `NSView` so the 62pt floor can live on the outer view
/// (centerY + inequality padding), matching `DashboardSettingsRowView`. Making
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
    let labelsStack = NSStackView()
    private var stacksVertically = false
    private var detailWidthConstraint: NSLayoutConstraint?
    private var dedicatedLabelsWidthConstraint: NSLayoutConstraint?
    private var wrappingHeightIsDirty = false
    private var wrappingCommitWorkItem: DispatchWorkItem?
    private var isPerformingLayout = false
    private var accessoryNaturalWidthConstraint: NSLayoutConstraint?

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
        isPerformingLayout = false
        scheduleWrappingHeightCommitIfNeeded()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            cancelPendingWrappingHeightCommit()
        }
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
        invalidateIntrinsicContentSize()
        needsLayout = true
        notifyHeightHost()
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
        let width = labelsStack.bounds.width
        return width > 1 ? width : 0
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
            color: .labelColor
        )
        let detailText = detail ?? ""
        configureLabel(
            detailLabel,
            text: detailText,
            font: .systemFont(ofSize: 12),
            color: .secondaryLabelColor
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
            if accessoryView is DashboardSettingsRowControlLayout {
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
            )
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
    }

    private func configureLabel(
        _ label: NSTextField,
        text: String,
        font: NSFont,
        color: NSColor
    ) {
        label.stringValue = text
        label.font = font
        label.textColor = color
        label.isEditable = false
        label.isSelectable = false
        label.usesSingleLineMode = false
        label.lineBreakMode = DashboardSettingsComponents.settingsSubtitleLineBreakMode(for: text)
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
        guard let accessoryView,
              let adaptive = accessoryView as? DashboardSettingsRowControlLayout
        else { return }
        let availableWidth = max(0, bounds.width - Self.horizontalPadding * 2)
        adaptive.updateAvailableRowWidth(availableWidth)
        // Control orientation (horizontal vs vertical) is independent of row
        // placement (inline / vertical-beside / dedicated-below). Measure
        // leftover label width against the accessory's natural width for its
        // current orientation, never the stack's compressed fitting size.
        let placeOnDedicatedRow = forceDedicatedControlRow
            || shouldPlaceAccessoryOnDedicatedRow(adaptive, availableWidth: availableWidth)
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
        if let adaptive = accessoryView as? DashboardSettingsRowControlLayout {
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

    private func shouldPlaceAccessoryOnDedicatedRow(
        _ adaptive: DashboardSettingsRowControlLayout,
        availableWidth: CGFloat
    ) -> Bool {
        guard let accessoryView,
              !accessoryView.isHidden,
              availableWidth > 0
        else { return false }
        let minimumLabelWidth = adaptive.minimumInlineLabelWidth
        guard minimumLabelWidth > 0 else { return false }
        let remainingWhenBeside = availableWidth
            - max(1, adaptive.naturalAccessoryWidth)
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
