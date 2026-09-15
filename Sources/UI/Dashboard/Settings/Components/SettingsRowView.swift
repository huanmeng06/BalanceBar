import AppKit

/// Hosts that still own card height (the legacy settings card) can remeasure
/// after a native row's wrapping width changes.
protocol SettingsRowHeightInvalidating: AnyObject {
    func invalidateHostedSettingsRowHeight()
}

/// Native Auto Layout settings row: title, optional detail, trailing control.
/// Height comes from stack intrinsic content size, not a custom measurement cache.
final class SettingsRowView: NSStackView {
    static var minimumHeight: CGFloat { DashboardSettingsComponents.standardRowHeight }
    static let horizontalPadding: CGFloat = 20
    static let verticalPadding: CGFloat = 11
    static let contentSpacing: CGFloat = 20
    static let labelSpacing: CGFloat = 2

    let titleLabel: NSTextField
    let detailLabel: NSTextField
    private(set) var accessoryView: NSView?

    private let labelsStack = NSStackView()

    init(
        title: String,
        detail: String? = nil,
        accessoryView: NSView? = nil
    ) {
        titleLabel = NSTextField(wrappingLabelWithString: title)
        detailLabel = NSTextField(wrappingLabelWithString: detail ?? "")
        self.accessoryView = accessoryView
        super.init(frame: .zero)
        configure(title: title, detail: detail, accessoryView: accessoryView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let wrappingWidth = max(0, labelsStack.bounds.width)
        guard wrappingWidth > 1 else { return }

        var wrappingChanged = false
        if abs(titleLabel.preferredMaxLayoutWidth - wrappingWidth) > 0.5 {
            titleLabel.preferredMaxLayoutWidth = wrappingWidth
            wrappingChanged = true
        }
        if !detailLabel.isHidden,
           abs(detailLabel.preferredMaxLayoutWidth - wrappingWidth) > 0.5 {
            detailLabel.preferredMaxLayoutWidth = wrappingWidth
            wrappingChanged = true
        }
        guard wrappingChanged else { return }
        invalidateIntrinsicContentSize()
        notifyHeightHost()
    }

    private func configure(
        title: String,
        detail: String?,
        accessoryView: NSView?
    ) {
        orientation = .horizontal
        alignment = .centerY
        distribution = .fill
        spacing = Self.contentSpacing
        edgeInsets = NSEdgeInsets(
            top: Self.verticalPadding,
            left: Self.horizontalPadding,
            bottom: Self.verticalPadding,
            right: Self.horizontalPadding
        )
        translatesAutoresizingMaskIntoConstraints = false
        setHuggingPriority(.defaultLow, for: .horizontal)
        setHuggingPriority(.required, for: .vertical)
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
        labelsStack.setHuggingPriority(.defaultLow, for: .horizontal)
        labelsStack.setHuggingPriority(.defaultHigh, for: .vertical)
        labelsStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labelsStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        labelsStack.setContentHuggingPriority(.defaultHigh, for: .vertical)
        labelsStack.setContentCompressionResistancePriority(.required, for: .vertical)
        labelsStack.addArrangedSubview(titleLabel)
        if !detailLabel.isHidden {
            labelsStack.addArrangedSubview(detailLabel)
        }

        addArrangedSubview(labelsStack)
        if let accessoryView {
            accessoryView.translatesAutoresizingMaskIntoConstraints = false
            accessoryView.setContentHuggingPriority(.required, for: .horizontal)
            accessoryView.setContentCompressionResistancePriority(.required, for: .horizontal)
            accessoryView.setContentHuggingPriority(.defaultHigh, for: .vertical)
            accessoryView.setContentCompressionResistancePriority(.required, for: .vertical)
            addArrangedSubview(accessoryView)
        }

        heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumHeight).isActive = true
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
        label.setContentHuggingPriority(.defaultHigh, for: .vertical)
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
