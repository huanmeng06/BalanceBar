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

    let titleLabel: NSTextField
    let detailLabel: NSTextField
    private(set) var accessoryView: NSView?

    let contentStack = NSStackView()
    let labelsStack = NSStackView()

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
        super.layout()
        applyWrappingWidths()
    }

    private func applyWrappingWidths() {
        let wrappingWidth = wrappingWidthForLabels()
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

    private func wrappingWidthForLabels() -> CGFloat {
        var reserved = Self.horizontalPadding * 2
        if let accessoryView, !accessoryView.isHidden {
            let accessoryWidth = accessoryView.bounds.width > 1
                ? accessoryView.bounds.width
                : accessoryView.fittingSize.width
            reserved += accessoryWidth + Self.contentSpacing
        }
        if bounds.width > 1 {
            return max(0, bounds.width - reserved)
        }
        return max(0, labelsStack.bounds.width)
    }

    private func configure(
        title: String,
        detail: String?,
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
        labelsStack.addArrangedSubview(titleLabel)
        if !detailLabel.isHidden {
            labelsStack.addArrangedSubview(detailLabel)
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
            accessoryView.setContentCompressionResistancePriority(.required, for: .horizontal)
            accessoryView.setContentHuggingPriority(.defaultHigh, for: .vertical)
            accessoryView.setContentCompressionResistancePriority(.required, for: .vertical)
            contentStack.addArrangedSubview(accessoryView)
        }

        addSubview(contentStack)
        NSLayoutConstraint.activate([
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
        ])
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
