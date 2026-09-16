import AppKit

/// Refresh-only native row for the two interval popups.
///
/// Generic `SettingsRowView` keeps a trailing accessory in its content stack.
/// These controls need a side-by-side vs dedicated-below placement that is
/// specific to Refresh, so the measurement and constraint switch live here
/// instead of in the shared row.
final class DashboardRefreshBalanceUpdatesRowView: NSView {
    let titleLabel: NSTextField
    let detailLabel: NSTextField
    let labelsStack = NSStackView()
    let intervalControls: DashboardAdaptiveControlsStackView

    private var sideBySideConstraints: [NSLayoutConstraint] = []
    private var stackedConstraints: [NSLayoutConstraint] = []
    private var isStacked = true

    init(
        title: String,
        detail: String,
        intervalControls: DashboardAdaptiveControlsStackView
    ) {
        titleLabel = NSTextField(wrappingLabelWithString: title)
        detailLabel = NSTextField(wrappingLabelWithString: detail)
        self.intervalControls = intervalControls
        super.init(frame: .zero)
        configure(title: title, detail: detail)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func enclosing(_ view: NSView) -> DashboardRefreshBalanceUpdatesRowView? {
        var current: NSView? = view
        while let candidate = current {
            if let row = candidate as? DashboardRefreshBalanceUpdatesRowView {
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
            updatePlacement()
            applyWrappingWidths()
            needsUpdateConstraints = true
            needsLayout = true
        }
    }

    override func updateConstraints() {
        updatePlacement()
        super.updateConstraints()
    }

    override func layout() {
        updatePlacement()
        super.layout()
        applyWrappingWidths()
    }

    private func updatePlacement() {
        let available = bounds.width > 1
            ? max(0, bounds.width - SettingsRowView.horizontalPadding * 2)
            : 0
        if available > 1 {
            intervalControls.updateAvailableRowWidth(available)
        }
        let accessoryFitting = intervalControls.fittingSize.width
        let wantsStacked = available <= 1
            || intervalControls.usesDedicatedRow
            || accessoryFitting + 0.5 > available
        if wantsStacked {
            intervalControls.orientation = .vertical
            intervalControls.alignment = .trailing
        }
        applyStacked(wantsStacked)
    }

    private func applyStacked(_ wantsStacked: Bool) {
        guard wantsStacked != isStacked else { return }
        NSLayoutConstraint.deactivate(sideBySideConstraints + stackedConstraints)
        isStacked = wantsStacked
        NSLayoutConstraint.activate(
            wantsStacked ? stackedConstraints : sideBySideConstraints
        )
        intervalControls.invalidateIntrinsicContentSize()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func applyWrappingWidths() {
        let wrappingWidth = wrappingWidthForLabels()
        guard wrappingWidth > 1 else { return }

        var wrappingChanged = false
        if abs(titleLabel.preferredMaxLayoutWidth - wrappingWidth) > 0.5 {
            titleLabel.preferredMaxLayoutWidth = wrappingWidth
            wrappingChanged = true
        }
        if abs(detailLabel.preferredMaxLayoutWidth - wrappingWidth) > 0.5 {
            detailLabel.preferredMaxLayoutWidth = wrappingWidth
            wrappingChanged = true
        }
        guard wrappingChanged else { return }
        invalidateIntrinsicContentSize()
    }

    private func wrappingWidthForLabels() -> CGFloat {
        var reserved = SettingsRowView.horizontalPadding * 2
        if !isStacked, !intervalControls.isHidden {
            let accessoryWidth = intervalControls.bounds.width > 1
                ? intervalControls.bounds.width
                : intervalControls.fittingSize.width
            reserved += accessoryWidth + SettingsRowView.contentSpacing
        }
        if bounds.width > 1 {
            return max(0, bounds.width - reserved)
        }
        return max(0, labelsStack.bounds.width)
    }

    private func configure(title: String, detail: String) {
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
        configureLabel(
            detailLabel,
            text: detail,
            font: .systemFont(ofSize: 12),
            color: .secondaryLabelColor
        )

        labelsStack.orientation = .vertical
        labelsStack.alignment = .leading
        labelsStack.spacing = SettingsRowView.labelSpacing
        labelsStack.translatesAutoresizingMaskIntoConstraints = false
        labelsStack.setHuggingPriority(.required, for: .vertical)
        labelsStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labelsStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        labelsStack.setContentHuggingPriority(.required, for: .vertical)
        labelsStack.setContentCompressionResistancePriority(.required, for: .vertical)
        labelsStack.addArrangedSubview(titleLabel)
        labelsStack.addArrangedSubview(detailLabel)

        intervalControls.translatesAutoresizingMaskIntoConstraints = false
        intervalControls.setContentHuggingPriority(.required, for: .horizontal)
        intervalControls.setContentCompressionResistancePriority(.required, for: .horizontal)
        intervalControls.setContentHuggingPriority(.defaultHigh, for: .vertical)
        intervalControls.setContentCompressionResistancePriority(.required, for: .vertical)
        // Seed a tiny available width so the adaptive stack stays vertical
        // until this row knows its real width. Otherwise its own layout()
        // treats infinite width as "fits side-by-side" and fights stacked
        // constraints at 320pt.
        intervalControls.updateAvailableRowWidth(1)
        intervalControls.orientation = .vertical
        intervalControls.alignment = .trailing

        addSubview(labelsStack)
        addSubview(intervalControls)

        let sideBySideSpacing = labelsStack.trailingAnchor.constraint(
            lessThanOrEqualTo: intervalControls.leadingAnchor,
            constant: -SettingsRowView.contentSpacing
        )
        sideBySideSpacing.priority = NSLayoutConstraint.Priority(999)

        sideBySideConstraints = [
            labelsStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            intervalControls.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -SettingsRowView.horizontalPadding
            ),
            intervalControls.centerYAnchor.constraint(equalTo: centerYAnchor),
            intervalControls.topAnchor.constraint(
                greaterThanOrEqualTo: topAnchor,
                constant: SettingsRowView.verticalPadding
            ),
            intervalControls.bottomAnchor.constraint(
                lessThanOrEqualTo: bottomAnchor,
                constant: -SettingsRowView.verticalPadding
            ),
            sideBySideSpacing
        ]
        stackedConstraints = [
            labelsStack.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -SettingsRowView.horizontalPadding
            ),
            labelsStack.topAnchor.constraint(
                equalTo: topAnchor,
                constant: SettingsRowView.verticalPadding
            ),
            intervalControls.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -SettingsRowView.horizontalPadding
            ),
            intervalControls.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor,
                constant: SettingsRowView.horizontalPadding
            ),
            intervalControls.topAnchor.constraint(
                greaterThanOrEqualTo: labelsStack.bottomAnchor,
                constant: SettingsRowView.contentSpacing
            ),
            intervalControls.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -SettingsRowView.verticalPadding
            )
        ]

        NSLayoutConstraint.activate([
            labelsStack.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: SettingsRowView.horizontalPadding
            ),
            labelsStack.topAnchor.constraint(
                greaterThanOrEqualTo: topAnchor,
                constant: SettingsRowView.verticalPadding
            ),
            labelsStack.bottomAnchor.constraint(
                lessThanOrEqualTo: bottomAnchor,
                constant: -SettingsRowView.verticalPadding
            ),
            heightAnchor.constraint(greaterThanOrEqualToConstant: SettingsRowView.minimumHeight),
            heightAnchor.constraint(
                greaterThanOrEqualTo: labelsStack.heightAnchor,
                constant: SettingsRowView.verticalPadding * 2
            ),
            heightAnchor.constraint(
                greaterThanOrEqualTo: intervalControls.heightAnchor,
                constant: SettingsRowView.verticalPadding * 2
            )
        ] + stackedConstraints)
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
}
