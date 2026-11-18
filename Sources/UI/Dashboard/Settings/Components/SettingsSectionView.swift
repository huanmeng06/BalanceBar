import AppKit
import CoreImage
import QuartzCore

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
    static let cardToFootnoteSpacing: CGFloat = 6

    let headingLabel: NSTextField
    let cardView: SettingsSectionCardView
    let contentStack = NSStackView()
    /// Section-wide caption under the card, aligned with row text.
    let footnoteLabel: NSTextField?
    /// Optional longer explanation revealed under the footnote on demand (hidden at first).
    /// Same width as the footnote; paragraphs are set apart by a small gap instead of a blank line.
    let footnoteDetailLabel: NSTextField?
    static let footnoteToDetailSpacing: CGFloat = 6
    static let footnoteDetailParagraphSpacing: CGFloat = 6
    private(set) var isFootnoteDetailExpanded = false
    /// Clips the detail while its height springs open or shut; the sections below follow
    /// the clip's height, so they glide down and back up with it.
    private let footnoteDetailClip: NSView?
    private var footnoteDetailClipHeight: NSLayoutConstraint?
    private var footnoteDetailClipFill: NSLayoutConstraint?
    private var footnoteDetailTop: NSLayoutConstraint?
    private var footnoteDetailDisplayLink: CADisplayLink?
    /// Steps the spring when the display link stalls (no screen, display asleep), so the
    /// detail always lands instead of freezing half open.
    private var footnoteDetailWatchdog: Timer?
    private var footnoteDetailLastStep: CFTimeInterval = 0
    private var footnoteDetailSpring: FootnoteDetailSpring?
    var isFootnoteDetailAnimatingForTesting: Bool { footnoteDetailSpring != nil }
    /// Section-wide view in its own card under the rows' card (e.g. a live chart).
    let footerView: NSView?
    /// The second card hosting `footerView`; unused without one.
    let footerCardView = SettingsSectionCardView()
    static let cardToFooterCardSpacing: CGFloat = 12
    static let footerCardVerticalInset: CGFloat = 12
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
        separatorIndices: Set<Int>? = nil,
        footnote: String? = nil,
        footnoteDetail: String? = nil,
        footerView: NSView? = nil
    ) {
        headingLabel = NSTextField(labelWithString: title)
        cardView = SettingsSectionCardView()
        footnoteLabel = footnote.map { NSTextField(wrappingLabelWithString: $0) }
        let detailLabel = footnote == nil ? nil : footnoteDetail.map { _ in NSTextField(wrappingLabelWithString: "") }
        footnoteDetailLabel = detailLabel
        footnoteDetailClip = detailLabel.map { _ in NSView() }
        self.footerView = footerView
        self.contentViews = contentViews
        super.init(frame: .zero)
        configure(title: title, separatorIndices: separatorIndices)
        if let footnoteDetail { setFootnoteDetailText(footnoteDetail) }
    }

    convenience init(
        title: String?,
        contentViews: [NSView],
        separatorIndices: Set<Int>? = nil,
        footnote: String? = nil,
        footnoteDetail: String? = nil,
        footerView: NSView? = nil
    ) {
        self.init(
            title: title ?? "",
            contentViews: contentViews,
            separatorIndices: separatorIndices,
            footnote: footnote,
            footnoteDetail: footnoteDetail,
            footerView: footerView
        )
    }

    /// Replaces the detail copy; "\n" separates paragraphs.
    func setFootnoteDetailText(_ text: String) {
        guard let footnoteDetailLabel else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = Self.footnoteDetailParagraphSpacing
        footnoteDetailLabel.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ])
        DashboardSettingsComponents.invalidateHostedSettingsRowHeight(for: footnoteDetailLabel)
    }

    /// Shows or hides the detail under the footnote. Animated, the clip's height follows a
    /// spring — a touch of overshoot opening, settling firmly closing — and every section
    /// below rides along. The text condenses in as the space opens: it fades up from a soft
    /// blur and drops the last few points into place, and reverses on the way out. The
    /// label keeps its frame inside the clip the whole time, so nothing flies in from the
    /// origin. Reduce Motion, or no window, switches at once.
    func setFootnoteDetailExpanded(_ expanded: Bool, animated: Bool) {
        guard let label = footnoteDetailLabel, let clip = footnoteDetailClip,
              let heightConstraint = footnoteDetailClipHeight,
              expanded != isFootnoteDetailExpanded else { return }
        isFootnoteDetailExpanded = expanded
        let animate = animated && window != nil
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animate else {
            finishFootnoteDetailTransition()
            return
        }
        // A toggle mid-flight reverses from wherever the clip is now.
        let from = footnoteDetailSpring.map { _ in heightConstraint.constant } ?? clip.frame.height
        label.isHidden = false
        window?.layoutIfNeeded() // the label has its wrap width and a frame before it shows
        let open = footnoteDetailOpenHeight
        footnoteDetailSpring = expanded
            ? FootnoteDetailSpring(from: from, to: open, openHeight: open, response: 0.46, damping: 0.72)
            : FootnoteDetailSpring(from: from, to: 0, openHeight: open, response: 0.36, damping: 0.92)
        footnoteDetailClipFill?.isActive = false
        heightConstraint.isActive = true
        applyFootnoteDetailHeight(from)
        footnoteDetailLastStep = CACurrentMediaTime()
        if footnoteDetailDisplayLink == nil {
            let link = displayLink(target: self, selector: #selector(stepFootnoteDetailSpring(_:)))
            link.add(to: .main, forMode: .common)
            footnoteDetailDisplayLink = link
        }
        if footnoteDetailWatchdog == nil {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                guard let self, CACurrentMediaTime() - self.footnoteDetailLastStep > 0.034 else { return }
                self.stepFootnoteDetailSpring()
            }
            RunLoop.main.add(timer, forMode: .common)
            footnoteDetailWatchdog = timer
        }
    }

    /// The clip's height with the detail fully shown: the gap above it plus its text.
    private var footnoteDetailOpenHeight: CGFloat {
        guard let label = footnoteDetailLabel else { return 0 }
        return Self.footnoteToDetailSpacing + ceil(max(label.intrinsicContentSize.height, label.frame.height))
    }

    @objc private func stepFootnoteDetailSpring(_ link: CADisplayLink) {
        stepFootnoteDetailSpring()
    }

    private func stepFootnoteDetailSpring() {
        footnoteDetailLastStep = CACurrentMediaTime()
        guard let spring = footnoteDetailSpring, window != nil else {
            finishFootnoteDetailTransition()
            return
        }
        let elapsed = CACurrentMediaTime() - spring.start
        guard !spring.isSettled(after: elapsed) else {
            finishFootnoteDetailTransition()
            return
        }
        applyFootnoteDetailHeight(spring.value(after: elapsed))
    }

    /// One frame: the clip's height, the text's opacity, blur and drop, then the page reflows.
    private func applyFootnoteDetailHeight(_ height: CGFloat) {
        guard let label = footnoteDetailLabel, let clip = footnoteDetailClip,
              let spring = footnoteDetailSpring else { return }
        let height = max(0, height)
        footnoteDetailClipHeight?.constant = height
        let textHeight = max(1, spring.openHeight - Self.footnoteToDetailSpacing)
        let revealed = min(1, max(0, (height - Self.footnoteToDetailSpacing) / textHeight))
        // Text trails the opening a little and leads the closing.
        let opacity = min(1, max(0, (revealed - 0.12) / 0.88))
        label.alphaValue = opacity * opacity * (3 - 2 * opacity)
        footnoteDetailTop?.constant = Self.footnoteToDetailSpacing - 8 * (1 - revealed)
        let blur = 6 * (1 - revealed)
        label.contentFilters = blur > 0.05
            ? [CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: blur])].compactMap { $0 }
            : []
        DashboardSettingsComponents.invalidateHostedSettingsRowHeight(for: clip)
        window?.layoutIfNeeded()
        softenFootnoteDetailEdge(band: 22 * (1 - revealed))
    }

    /// Feathers the clip's bottom edge so the text dissolves into the opening instead of being
    /// cut by a hard line. The band narrows as the text is revealed and is gone once fully open.
    private func softenFootnoteDetailEdge(band: CGFloat) {
        guard let layer = footnoteDetailClip?.layer else { return }
        let height = layer.bounds.height
        guard band > 0.5, height > 0.5 else {
            layer.mask = nil
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let mask = (layer.mask as? CAGradientLayer) ?? CAGradientLayer()
        mask.frame = layer.bounds
        mask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor]
        // Unit space follows the layer: y = 0 is the bottom unless the geometry is flipped.
        let fade = min(1, band / height)
        let bottom: CGFloat = layer.isGeometryFlipped ? 1 : 0
        mask.startPoint = CGPoint(x: 0.5, y: bottom)
        mask.endPoint = CGPoint(x: 0.5, y: layer.isGeometryFlipped ? 1 - fade : fade)
        layer.mask = mask
        CATransaction.commit()
    }

    /// Ends any spring and pins the detail to its resting state: open, the clip hugs the text
    /// (and follows it when the window resizes); closed, the clip is zero tall and the text hidden.
    private func finishFootnoteDetailTransition() {
        footnoteDetailDisplayLink?.invalidate()
        footnoteDetailDisplayLink = nil
        footnoteDetailWatchdog?.invalidate()
        footnoteDetailWatchdog = nil
        footnoteDetailSpring = nil
        guard let label = footnoteDetailLabel, let clip = footnoteDetailClip else { return }
        label.alphaValue = 1
        label.contentFilters = []
        footnoteDetailClip?.layer?.mask = nil
        label.isHidden = !isFootnoteDetailExpanded
        footnoteDetailTop?.constant = Self.footnoteToDetailSpacing
        if isFootnoteDetailExpanded {
            footnoteDetailClipHeight?.isActive = false
            footnoteDetailClipFill?.isActive = true
        } else {
            footnoteDetailClipFill?.isActive = false
            footnoteDetailClipHeight?.constant = 0
            footnoteDetailClipHeight?.isActive = true
        }
        DashboardSettingsComponents.invalidateHostedSettingsRowHeight(for: clip)
        window?.layoutIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, footnoteDetailSpring != nil { finishFootnoteDetailTransition() }
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
                let separator = NSBox()
                separator.boxType = .separator
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
        if let footnoteLabel {
            footnoteLabel.font = .systemFont(ofSize: 12)
            footnoteLabel.isSelectable = false
            footnoteLabel.textColor = .secondaryLabelColor
            footnoteLabel.translatesAutoresizingMaskIntoConstraints = false
            footnoteLabel.setContentHuggingPriority(.required, for: .vertical)
            footnoteLabel.setContentCompressionResistancePriority(.required, for: .vertical)
            footnoteLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            contentStack.addView(footnoteLabel, in: .top)
            contentStack.setCustomSpacing(Self.cardToFootnoteSpacing, after: cardView)
            if let footnoteDetailLabel, let clip = footnoteDetailClip {
                footnoteDetailLabel.isSelectable = false
                footnoteDetailLabel.isHidden = true
                footnoteDetailLabel.wantsLayer = true
                footnoteDetailLabel.layerUsesCoreImageFilters = true
                footnoteDetailLabel.translatesAutoresizingMaskIntoConstraints = false
                footnoteDetailLabel.setContentHuggingPriority(.required, for: .vertical)
                footnoteDetailLabel.setContentCompressionResistancePriority(.required, for: .vertical)
                footnoteDetailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                clip.translatesAutoresizingMaskIntoConstraints = false
                clip.wantsLayer = true
                clip.layer?.masksToBounds = true
                clip.addSubview(footnoteDetailLabel)
                contentStack.addView(clip, in: .top)
                // The gap above the detail lives inside the clip, so a closed detail leaves none.
                contentStack.setCustomSpacing(0, after: footnoteLabel)
            }
        }
        if let footerView {
            // A second card of the same chrome, set apart from the rows but in the same section.
            footerView.translatesAutoresizingMaskIntoConstraints = false
            footerCardView.edgeInsets = NSEdgeInsets(
                top: Self.footerCardVerticalInset, left: SettingsLayout.rowHorizontalInset,
                bottom: Self.footerCardVerticalInset, right: SettingsLayout.rowHorizontalInset)
            footerCardView.addArrangedSubview(footerView)
            footerView.widthAnchor.constraint(
                equalTo: footerCardView.widthAnchor, constant: -2 * SettingsLayout.rowHorizontalInset).isActive = true
            contentStack.addView(footerCardView, in: .top)
            contentStack.setCustomSpacing(
                Self.cardToFooterCardSpacing, after: footnoteDetailClip ?? footnoteLabel ?? cardView)
        }

        addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            cardView.widthAnchor.constraint(equalTo: contentStack.widthAnchor)
        ])
        if let footnoteLabel {
            let inset = SettingsLayout.rowHorizontalInset
            NSLayoutConstraint.activate([
                footnoteLabel.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor, constant: inset),
                footnoteLabel.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor, constant: -inset)
            ])
            if let footnoteDetailLabel, let clip = footnoteDetailClip {
                let top = footnoteDetailLabel.topAnchor.constraint(
                    equalTo: clip.topAnchor, constant: Self.footnoteToDetailSpacing)
                let height = clip.heightAnchor.constraint(equalToConstant: 0)
                NSLayoutConstraint.activate([
                    clip.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor, constant: inset),
                    clip.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor, constant: -inset),
                    footnoteDetailLabel.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
                    footnoteDetailLabel.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
                    top,
                    height
                ])
                footnoteDetailTop = top
                footnoteDetailClipHeight = height
                footnoteDetailClipFill = clip.bottomAnchor.constraint(equalTo: footnoteDetailLabel.bottomAnchor)
            }
        }
        if footerView != nil {
            footerCardView.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }
        reconcileSeparators()
    }

    /// Hairlines follow the final visible rows. They do not store search or
    /// business hidden flags of their own.
    func reconcileSeparators() {
        DashboardSearchVisibility.reconcileDerivedSeparators(
            contentViews: contentViews,
            separators: separators
        )
        cardView.invalidateHostedSettingsRowHeight()
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

    /// Test hook: treat the section as being in a live resize.
    var liveResizeOverrideForTesting: Bool?
    private var pendingWrappingRows: [SettingsRowView] = []

    private var isInLiveResize: Bool { liveResizeOverrideForTesting ?? inLiveResize }

    /// While the window is being dragged the pinned `contentStack` constraints decide
    /// the height; reporting `contentStack.fittingSize` built a temporary layout
    /// engine every frame (#680). Outside live resize the natural height is reported
    /// as before, which search filtering relies on to collapse hidden rows.
    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: isInLiveResize ? NSView.noIntrinsicMetric : naturalHeight
        )
    }

    /// The height the section would take at its current width, measured on demand.
    var naturalHeight: CGFloat {
        let stackHeight = contentStack.intrinsicContentSize.height
        return stackHeight > 0 ? stackHeight : contentStack.fittingSize.height
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// Rows whose wrapping width changed during `layout()` queue their height
    /// commit here; the section commits them together in its next layout round
    /// of the same window update (#690).
    func enqueueWrappingHeightCommit(for row: SettingsRowView) {
        if !pendingWrappingRows.contains(where: { $0 === row }) {
            pendingWrappingRows.append(row)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        commitPendingRowWrapping()
        updateFootnoteWrapWidth()
        updateSearchNaturalHeightConstraintForCurrentVisibility()
    }

    private func commitPendingRowWrapping() {
        guard !pendingWrappingRows.isEmpty else { return }
        let rows = pendingWrappingRows
        pendingWrappingRows.removeAll()
        rows.forEach { $0.flushPendingWrappingHeightCommit() }
    }

    /// A wrapping `NSTextField` only reports a multi-line intrinsic height once it knows
    /// its wrap width; without it the footnote stays on one line and gets clipped.
    private func updateFootnoteWrapWidth() {
        guard let footnoteLabel else { return }
        let width = max(0, bounds.width - 2 * SettingsLayout.rowHorizontalInset)
        guard width > 1 else { return }
        var changed = false
        if abs(footnoteLabel.preferredMaxLayoutWidth - width) > 0.5 {
            footnoteLabel.preferredMaxLayoutWidth = width
            footnoteLabel.invalidateIntrinsicContentSize()
            changed = true
        }
        if let footnoteDetailLabel {
            if abs(footnoteDetailLabel.preferredMaxLayoutWidth - width) > 0.5 {
                footnoteDetailLabel.preferredMaxLayoutWidth = width
                footnoteDetailLabel.invalidateIntrinsicContentSize()
                changed = true
            }
        }
        if changed { invalidateIntrinsicContentSize() }
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

        let naturalHeight = self.naturalHeight
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

/// A damped spring from one clip height to another (SwiftUI-style response and damping).
private struct FootnoteDetailSpring {
    let from: CGFloat
    let to: CGFloat
    /// The clip's fully open height, which maps a height to how much text is revealed.
    let openHeight: CGFloat
    let start = CACurrentMediaTime()
    private let omega: Double
    private let damping: Double

    init(from: CGFloat, to: CGFloat, openHeight: CGFloat, response: Double, damping: Double) {
        self.from = from
        self.to = to
        self.openHeight = openHeight
        omega = 2 * .pi / response
        self.damping = damping
    }

    func value(after t: Double) -> CGFloat {
        let damped = omega * (1 - damping * damping).squareRoot()
        let envelope = exp(-damping * omega * t)
        let progress = 1 - envelope * (cos(damped * t) + damping * omega / damped * sin(damped * t))
        return from + (to - from) * CGFloat(progress)
    }

    /// Done once the remaining swing is under a third of a point.
    func isSettled(after t: Double) -> Bool {
        exp(-damping * omega * t) * Double(abs(to - from)) < 0.3
    }
}
