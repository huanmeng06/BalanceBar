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

    let contentStack = NSStackView()
    let labelsStack = NSStackView()
    private var stacksVertically = false
    private var detailWidthConstraint: NSLayoutConstraint?
    private var dedicatedLabelsWidthConstraint: NSLayoutConstraint?
    private var wrappingHeightIsDirty = false
    private var wrappingCommitIsScheduled = false
    private var isPerformingLayout = false

    init(
        title: String,
        detail: String? = nil,
        titleAccessory: NSView? = nil,
        accessoryView: NSView? = nil
    ) {
        titleLabel = SettingsWrappingLabel(string: title)
        detailLabel = SettingsWrappingLabel(string: detail ?? "")
        self.titleAccessory = titleAccessory
        self.accessoryView = accessoryView
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
        super.layout()
        // Never invalidate intrinsic size here. Doing so during live resize
        // exploded AppKit's Update Constraints cycle on dual-button rows;
        // doing so in ordinary layout also desynchronized in-place
        // localization rebuilds in the broader Dashboard tests.
        applyWrappingWidths(invalidateHeight: false)
        isPerformingLayout = false
        scheduleWrappingHeightCommitIfNeeded()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            wrappingHeightIsDirty = false
            wrappingCommitIsScheduled = false
        }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        refreshWrappingLayout()
    }

    /// Apply wrapping from the current bounds and update intrinsic height.
    /// Call only outside an in-flight window layout pass.
    func refreshWrappingLayout() {
        syncAdaptiveAccessory()
        applyWrappingWidths(invalidateHeight: true)
        needsLayout = true
        layoutSubtreeIfNeeded()
        // Nested layout can assign the final row width after the first wrap
        // commit. Recommit only when wrapping widened so a stale tall
        // intrinsic height can shrink.
        let settledWidth = wrappingWidthForLabels()
        let settledTitle = wrappingWidthForTitle(labelWidth: settledWidth)
        guard settledTitle > titleLabel.preferredMaxLayoutWidth + 0.5
            || (!detailLabel.isHidden
                && settledWidth > detailLabel.preferredMaxLayoutWidth + 0.5)
        else { return }
        applyWrappingWidths(invalidateHeight: true)
        needsLayout = true
        layoutSubtreeIfNeeded()
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

    private func applyWrappingWidths(invalidateHeight: Bool) {
        let labelWidth = wrappingWidthForLabels()
        // Still publish a wrap width when leftover collapsed to ~0 so a
        // previous wide `preferredMaxLayoutWidth` cannot stick across resize.
        guard labelWidth > 0 else { return }
        let titleWidth = wrappingWidthForTitle(labelWidth: labelWidth)
        let widthChanged = wrappingNeedsUpdate(titleWidth: titleWidth, labelWidth: labelWidth)
        guard widthChanged || (invalidateHeight && wrappingHeightIsDirty) else { return }

        if invalidateHeight {
            titleLabel.preferredMaxLayoutWidth = titleWidth
            if !detailLabel.isHidden {
                detailLabel.preferredMaxLayoutWidth = labelWidth
            }
            wrappingHeightIsDirty = false
            invalidateIntrinsicContentSize()
            notifyHeightHost()
            return
        }

        (titleLabel as? SettingsWrappingLabel)?
            .setPreferredMaxLayoutWidthWithoutInvalidation(titleWidth)
        if !detailLabel.isHidden {
            (detailLabel as? SettingsWrappingLabel)?
                .setPreferredMaxLayoutWidthWithoutInvalidation(labelWidth)
        }
        wrappingHeightIsDirty = true
        scheduleWrappingHeightCommitIfNeeded()
    }

    private func scheduleWrappingHeightCommitIfNeeded() {
        guard wrappingHeightIsDirty else { return }
        guard window?.inLiveResize != true else { return }
        guard !isPerformingLayout else { return }
        guard !wrappingCommitIsScheduled else { return }
        // XCTest shares one AppKit constraint solver. A deferred ICS
        // invalidation here races later tests' in-place localization
        // rebuilds. Tests call `refreshWrappingLayout()` after pinning.
        if AutomatedTestHost.isRunning {
            return
        }
        wrappingCommitIsScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.wrappingCommitIsScheduled = false
            guard self.wrappingHeightIsDirty, self.window != nil else { return }
            guard self.window?.inLiveResize != true else { return }
            self.refreshWrappingLayout()
        }
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
        if stacksVertically {
            if bounds.width > 1 {
                return max(0, bounds.width - Self.horizontalPadding * 2)
            }
            return max(0, contentStack.bounds.width)
        }
        let available = bounds.width > 1
            ? bounds.width
            : (superview?.bounds.width ?? 0)
        guard available > 1 else { return 0 }
        var reserved = Self.horizontalPadding * 2
        if let accessoryView, !accessoryView.isHidden {
            reserved += accessoryWidthForWrapping(accessoryView) + Self.contentSpacing
        }
        let leftover = available - reserved
        if leftover > 1 {
            return leftover
        }
        // Accessory overflowed the row. Wrap against the minimum labels
        // column when the row is wide enough, so a previous wide wrap cannot
        // stick. Skip only when the row has not been assigned a width yet.
        let minimumColumn = Self.horizontalPadding * 2 + Self.minimumInlineLabelWidth
        if available + 0.5 >= minimumColumn {
            return Self.minimumInlineLabelWidth
        }
        return 0
    }

    private func accessoryWidthForWrapping(_ accessoryView: NSView) -> CGFloat {
        // Prefer intrinsic width. Live-resize can inflate `fittingSize`, and
        // a compressed `bounds` (vertical controls) is smaller than the
        // control's natural width.
        let intrinsic = accessoryView.intrinsicContentSize.width
        if intrinsic > 1, intrinsic < 10_000 {
            return intrinsic
        }
        let fitted = accessoryView.fittingSize.width
        let bounded = accessoryView.bounds.width
        if bounded > 1, bounded < 10_000 {
            if fitted > 1, fitted < 10_000 {
                return min(fitted, bounded)
            }
            return bounded
        }
        if fitted > 1, fitted < 10_000 {
            return fitted
        }
        return 1
    }

    private func wrappingWidthForTitle(labelWidth: CGFloat) -> CGFloat {
        guard let titleAccessory, !titleAccessory.isHidden else { return labelWidth }
        let accessoryWidth = max(1, titleAccessory.fittingSize.width)
        return max(0, labelWidth - accessoryWidth - Self.titleAccessorySpacing)
    }

    private func configure(
        title: String,
        detail: String?,
        titleAccessory: NSView?,
        accessoryView: NSView?
    ) {
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
                constant: Self.verticalPadding
            ),
            contentStack.bottomAnchor.constraint(
                lessThanOrEqualTo: bottomAnchor,
                constant: -Self.verticalPadding
            ),
            heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumHeight),
            heightAnchor.constraint(
                greaterThanOrEqualTo: contentStack.heightAnchor,
                constant: Self.verticalPadding * 2
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
        // leftover label width against the accessory's natural width after
        // the stack has chosen its own orientation.
        applyVerticalStacking(shouldPlaceAccessoryOnDedicatedRow(adaptive, availableWidth: availableWidth))
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
        // Uses the accessory's natural width, so a vertical control stack
        // can remain beside the labels when leftover space is enough.
        let remainingWhenBeside = availableWidth
            - accessoryWidthForWrapping(accessoryView)
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
