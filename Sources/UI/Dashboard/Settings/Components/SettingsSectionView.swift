import AppKit

/// Native Auto Layout settings section: optional heading plus a card that
/// stacks row / content views.
///
/// Height comes from the arranged content's intrinsic sizes and constraints.
/// The card does not install an explicit `heightConstraint`, call
/// `settingsSectionIntrinsicHeight`, or remeasure hosted rows through the legacy
/// preferred-height engine.
final class SettingsSectionView: NSView {
    static let headingFont = NSFont.systemFont(ofSize: 17, weight: .semibold)
    static let headingToCardSpacing: CGFloat = 11
    static let cornerRadius: CGFloat = 18
    static let borderWidth: CGFloat = 0.5
    static let shadowRadius: CGFloat = 14
    static let shadowOffset = NSSize(width: 0, height: -3)

    let headingLabel: NSTextField
    let cardView: SettingsSectionCardView
    let contentStack = NSStackView()
    private(set) var contentViews: [NSView]
    private(set) var separators: [NSView] = []
    private var searchNaturalHeightConstraint: NSLayoutConstraint?

    var rowsStack: NSStackView { cardView }
    var hasSearchNaturalHeightConstraintForTesting: Bool {
        searchNaturalHeightConstraint?.isActive == true
    }

    init(
        title: String,
        contentViews: [NSView],
        separatorIndices: Set<Int>? = nil
    ) {
        headingLabel = NSTextField(labelWithString: title)
        cardView = SettingsSectionCardView()
        self.contentViews = contentViews
        super.init(frame: .zero)
        configure(title: title, separatorIndices: separatorIndices)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func enclosing(_ view: NSView) -> SettingsSectionView? {
        var current: NSView? = view
        while let candidate = current {
            if let section = candidate as? SettingsSectionView {
                return section
            }
            current = candidate.superview
        }
        return nil
    }

    private func configure(title: String, separatorIndices: Set<Int>?) {
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)

        headingLabel.font = Self.headingFont
        headingLabel.isEditable = false
        headingLabel.isSelectable = false
        headingLabel.translatesAutoresizingMaskIntoConstraints = false
        headingLabel.setContentHuggingPriority(.required, for: .vertical)
        headingLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        headingLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headingLabel.heightAnchor.constraint(
            greaterThanOrEqualToConstant: ceil(Self.headingFont.boundingRectForFont.height)
        ).isActive = true
        identifier = DashboardPageSearch.sectionIdentifier
        headingLabel.isHidden = title.isEmpty

        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        cardView.setContentCompressionResistancePriority(.required, for: .horizontal)
        cardView.setContentHuggingPriority(.required, for: .vertical)
        cardView.setContentCompressionResistancePriority(.required, for: .vertical)
        cardView.setHuggingPriority(.required, for: .vertical)
        cardView.setClippingResistancePriority(.required, for: .vertical)
        cardView.detachesHiddenViews = true

        for (index, row) in contentViews.enumerated() {
            row.translatesAutoresizingMaskIntoConstraints = false
            row.setContentHuggingPriority(.required, for: .vertical)
            row.setContentCompressionResistancePriority(.required, for: .vertical)
            row.setContentHuggingPriority(.defaultLow, for: .horizontal)
            cardView.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: cardView.widthAnchor).isActive = true

            let hasFollowingRow = index < contentViews.count - 1
            let shouldInsertSeparator = hasFollowingRow
                && (separatorIndices?.contains(index) ?? true)
            if shouldInsertSeparator {
                let separator = SettingsCardSeparatorView()
                separator.translatesAutoresizingMaskIntoConstraints = false
                separator.heightAnchor.constraint(
                    equalToConstant: DashboardSettingsComponents.settingsSeparatorHeight
                ).isActive = true
                cardView.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: cardView.widthAnchor).isActive = true
                separators.append(separator)
            }
        }

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = Self.headingToCardSpacing
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        contentStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        contentStack.setContentHuggingPriority(.required, for: .vertical)
        contentStack.setContentCompressionResistancePriority(.required, for: .vertical)
        contentStack.setHuggingPriority(.required, for: .vertical)
        contentStack.setClippingResistancePriority(.required, for: .vertical)
        contentStack.detachesHiddenViews = true
        if !headingLabel.isHidden {
            contentStack.addView(headingLabel, in: .top)
        }
        contentStack.addView(cardView, in: .top)

        addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            cardView.widthAnchor.constraint(equalTo: contentStack.widthAnchor)
        ])
    }

    /// Keeps the section-title band above the card. Search's empty state has
    /// no title text, but its card should still start where a titled card
    /// starts. The card already spans the content column; pinning the empty
    /// label to that width makes its frame 4pt wider because `NSTextField`
    /// alignment insets sit outside the alignment rect.
    func reserveHeadingBand() {
        headingLabel.stringValue = ""
        headingLabel.isHidden = false
        headingLabel.setAccessibilityElement(false)
        headingLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if headingLabel.superview == nil {
            contentStack.insertView(headingLabel, at: 0, in: .top)
        }
    }

    override var isHidden: Bool {
        get { super.isHidden }
        set {
            DashboardSearchVisibility.writeHidden(self, newValue) { super.isHidden = $0 }
        }
    }

    override var intrinsicContentSize: NSSize {
        let stackHeight = contentStack.intrinsicContentSize.height
        let height = stackHeight > 0 ? stackHeight : contentStack.fittingSize.height
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    override func layout() {
        super.layout()
        updateSearchNaturalHeightConstraintForCurrentVisibility()
    }

    func updateSearchNaturalHeightConstraintForCurrentVisibility() {
        // Global search stacks already collapse hidden arranged sections with
        // NSStackView's native visibility semantics. Locking the section to a
        // transient intrinsic height here creates a required constraint that
        // can capture the pre-wrapping size for one layout pass.
        if isInsideGlobalSearchProjection {
            searchNaturalHeightConstraint?.isActive = false
            return
        }
        guard !DashboardSearchVisibility.isSearchHidden(self),
              !DashboardSearchVisibility.isBusinessHidden(self)
        else {
            searchNaturalHeightConstraint?.isActive = false
            return
        }
        let hasSearchHiddenSibling: Bool
        if let stack = superview as? NSStackView,
           stack.arrangedSubviews.contains(where: { $0 === self }) {
            hasSearchHiddenSibling = stack.arrangedSubviews.contains { sibling in
                sibling !== self && DashboardSearchVisibility.isSearchHidden(sibling)
            }
        } else {
            hasSearchHiddenSibling = searchHiddenSiblingInAncestorContainer()
        }

        guard hasSearchHiddenSibling else {
            searchNaturalHeightConstraint?.isActive = false
            return
        }

        let naturalHeight = intrinsicContentSize.height
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

    private var isInsideGlobalSearchProjection: Bool {
        var ancestor = superview
        while let view = ancestor {
            if view.identifier == DashboardPageSearch.globalSearchGroupIdentifier {
                return true
            }
            ancestor = view.superview
        }
        return false
    }

    private func searchHiddenSiblingInAncestorContainer() -> Bool {
        var child: NSView = self
        var ancestor = superview
        while let container = ancestor {
            if container.subviews.contains(where: { sibling in
                sibling !== child && containsSearchHiddenSection(in: sibling)
            }) {
                return true
            }
            child = container
            ancestor = container.superview
        }
        return false
    }

    private func containsSearchHiddenSection(in view: NSView) -> Bool {
        if let section = view as? SettingsSectionView {
            return section !== self && DashboardSearchVisibility.isSearchHidden(section)
        }
        return view.subviews.contains { containsSearchHiddenSection(in: $0) }
    }
}

/// Mid-card hairline. `NSBox` does not participate in `writeHidden`, so search
/// must route `isHidden` through the same business/search split as rows.
final class SettingsCardSeparatorView: NSBox {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        boxType = .separator
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
}

/// Card chrome only. Hosted rows keep their own intrinsic heights; wrapping
/// invalidation is a layout pass, not a parent-driven height measurement.
final class SettingsSectionCardView: NSStackView, SettingsRowHeightInvalidating {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyChrome()
    }

    func invalidateHostedSettingsRowHeight() {
        var current: NSView? = self
        while let view = current {
            view.invalidateIntrinsicContentSize()
            view.needsLayout = true
            if view is SettingsSectionView {
                break
            }
            current = view.superview
        }
        for subview in subviews {
            subview.invalidateIntrinsicContentSize()
            subview.needsLayout = true
        }
    }

    private func configure() {
        orientation = .vertical
        alignment = .leading
        distribution = .fill
        spacing = 0
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        applyChrome()
    }

    private func applyChrome() {
        layer?.cornerRadius = SettingsSectionView.cornerRadius
        layer?.backgroundColor = dashboardAdaptiveColor(
            light: NSColor.white.withAlphaComponent(0.94),
            dark: NSColor.white.withAlphaComponent(0.065)
        ).cgColor
        layer?.borderColor = dashboardAdaptiveColor(
            light: NSColor.white.withAlphaComponent(0.95),
            dark: NSColor.white.withAlphaComponent(0.075)
        ).cgColor
        layer?.borderWidth = SettingsSectionView.borderWidth
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = dashboardUsesDarkAppearance ? 0.20 : 0.08
        layer?.shadowRadius = SettingsSectionView.shadowRadius
        layer?.shadowOffset = SettingsSectionView.shadowOffset
        layer?.masksToBounds = false
    }
}
