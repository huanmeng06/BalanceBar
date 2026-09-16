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
    private var wrappingHeightIsDirty = false
    private var wrappingCommitIsScheduled = false
    private var isPerformingLayout = false

    init(
        title: String,
        detail: String? = nil,
        accessoryView: NSView? = nil
    ) {
        titleLabel = SettingsWrappingLabel(string: title)
        detailLabel = SettingsWrappingLabel(string: detail ?? "")
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

    override func layout() {
        isPerformingLayout = true
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
        applyWrappingWidths(invalidateHeight: true)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func applyWrappingWidths(invalidateHeight: Bool) {
        let wrappingWidth = wrappingWidthForLabels()
        guard wrappingWidth > 1 else { return }
        let widthChanged = wrappingNeedsUpdate(to: wrappingWidth)
        guard widthChanged || (invalidateHeight && wrappingHeightIsDirty) else { return }

        if invalidateHeight {
            titleLabel.preferredMaxLayoutWidth = wrappingWidth
            if !detailLabel.isHidden {
                detailLabel.preferredMaxLayoutWidth = wrappingWidth
            }
            wrappingHeightIsDirty = false
            invalidateIntrinsicContentSize()
            notifyHeightHost()
            return
        }

        (titleLabel as? SettingsWrappingLabel)?
            .setPreferredMaxLayoutWidthWithoutInvalidation(wrappingWidth)
        if !detailLabel.isHidden {
            (detailLabel as? SettingsWrappingLabel)?
                .setPreferredMaxLayoutWidthWithoutInvalidation(wrappingWidth)
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

    private func wrappingNeedsUpdate(to wrappingWidth: CGFloat) -> Bool {
        guard wrappingWidth > 1 else { return false }
        if abs(titleLabel.preferredMaxLayoutWidth - wrappingWidth) > 0.5 {
            return true
        }
        if !detailLabel.isHidden,
           abs(detailLabel.preferredMaxLayoutWidth - wrappingWidth) > 0.5 {
            return true
        }
        return false
    }

    private func wrappingWidthForLabels() -> CGFloat {
        var reserved = Self.horizontalPadding * 2
        if let accessoryView, !accessoryView.isHidden {
            let fitted = accessoryView.fittingSize.width
            let accessoryWidth = fitted > 1 ? fitted : accessoryView.bounds.width
            reserved += accessoryWidth + Self.contentSpacing
        }
        let available = bounds.width > 1 ? bounds.width : labelsStack.bounds.width
        guard available > 1 else { return 0 }
        // Keep a usable wrapping width even when the accessory stack reports a
        // stretched fitting size during live resize.
        return max(80, available - reserved)
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
