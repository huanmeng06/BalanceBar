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

    init(
        title: String,
        detail: String? = nil,
        titleAccessory: NSView? = nil,
        accessoryView: NSView? = nil
    ) {
        titleLabel = NSTextField(wrappingLabelWithString: title)
        detailLabel = NSTextField(wrappingLabelWithString: detail ?? "")
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

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - bounds.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged {
            applyWrappingWidths()
            needsLayout = true
        }
    }

    override func layout() {
        syncAdaptiveAccessory()
        applyWrappingWidths()
        super.layout()
        applyWrappingWidths()
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
        invalidateIntrinsicContentSize()
        notifyHeightHost()
        needsLayout = true
    }

    private func applyWrappingWidths() {
        let labelWidth = wrappingWidthForLabels()
        guard labelWidth > 1 else { return }
        let titleWidth = wrappingWidthForTitle(labelWidth: labelWidth)

        var wrappingChanged = false
        if abs(titleLabel.preferredMaxLayoutWidth - titleWidth) > 0.5 {
            titleLabel.preferredMaxLayoutWidth = titleWidth
            wrappingChanged = true
        }
        if !detailLabel.isHidden,
           abs(detailLabel.preferredMaxLayoutWidth - labelWidth) > 0.5 {
            detailLabel.preferredMaxLayoutWidth = labelWidth
            wrappingChanged = true
        }
        guard wrappingChanged else { return }
        invalidateIntrinsicContentSize()
        notifyHeightHost()
        needsLayout = true
    }

    private func wrappingWidthForLabels() -> CGFloat {
        if stacksVertically {
            if bounds.width > 1 {
                return max(0, bounds.width - Self.horizontalPadding * 2)
            }
            return max(0, contentStack.bounds.width)
        }
        var reserved = Self.horizontalPadding * 2
        if let accessoryView, !accessoryView.isHidden {
            // fittingSize ignores a leftover full-width frame from the
            // previous vertical pass, which would otherwise wrap titles
            // into a sliver and inflate the wide-row height.
            reserved += max(1, accessoryView.fittingSize.width) + Self.contentSpacing
        }
        if bounds.width > 1 {
            return max(0, bounds.width - reserved)
        }
        return max(0, labelsStack.bounds.width)
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
        // Control orientation (side-by-side vs stacked popups/buttons) is
        // independent of row placement (accessory beside text vs below it).
        applyVerticalStacking(shouldPlaceAccessoryOnDedicatedRow(adaptive, availableWidth: availableWidth))
        applyWrappingWidths()
    }

    private func shouldPlaceAccessoryOnDedicatedRow(
        _ adaptive: DashboardSettingsRowControlLayout,
        availableWidth: CGFloat
    ) -> Bool {
        // `usesDedicatedRow` means the controls themselves went vertical.
        // Label-column placement is separate: the accessory can stay
        // horizontal while moving onto the row below the labels.
        if adaptive.usesDedicatedRow {
            return true
        }
        guard let accessoryView,
              !accessoryView.isHidden,
              availableWidth > 0
        else { return false }
        let minimumLabelWidth = adaptive.minimumInlineLabelWidth
        guard minimumLabelWidth > 0 else { return false }
        let remainingWhenBeside = availableWidth
            - max(1, accessoryView.fittingSize.width)
            - Self.contentSpacing
        return remainingWhenBeside + 0.5 < minimumLabelWidth
    }

    private func applyVerticalStacking(_ vertical: Bool) {
        guard stacksVertically != vertical else { return }
        stacksVertically = vertical
        if vertical {
            contentStack.orientation = .vertical
            contentStack.alignment = .width
            contentStack.spacing = DashboardSettingsComponents.settingsRowContentControlSpacing
            accessoryView?.setContentHuggingPriority(.defaultLow, for: .horizontal)
        } else {
            contentStack.orientation = .horizontal
            contentStack.alignment = .centerY
            contentStack.spacing = Self.contentSpacing
            accessoryView?.setContentHuggingPriority(.required, for: .horizontal)
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
