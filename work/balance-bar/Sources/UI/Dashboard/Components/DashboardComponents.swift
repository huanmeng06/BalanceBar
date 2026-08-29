import AppKit

var dashboardUsesDarkAppearance: Bool {
    NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
}

func dashboardAdaptiveColor(light: NSColor, dark: NSColor) -> NSColor {
    dashboardUsesDarkAppearance ? dark : light
}

final class DashboardUpdateBadgeView: NSView {
    private static let diameter: CGFloat = 18

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.diameter, height: Self.diameter)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        NSColor.systemRed.setFill()
        circle.fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let text = NSAttributedString(string: "1", attributes: attributes)
        let textSize = text.size()
        text.draw(at: NSPoint(
            x: bounds.midX - textSize.width / 2,
            y: bounds.midY - textSize.height / 2 + 0.5
        ))
    }

    private func configure() {
        identifier = NSUserInterfaceItemIdentifier("updateAvailableBadge")
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("1")
    }
}

final class DashboardNavigationRowView: NSView {
    weak var iconView: NSImageView?
    weak var titleLabel: NSTextField?
    weak var updateBadgeView: DashboardUpdateBadgeView?

    var isSelected = false {
        didSet { updateAppearance(animated: true) }
    }

    private var isHovered = false
    private var trackingAreaReference: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaReference = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearance(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateAppearance(animated: true)
    }

    func updateAppearance(animated: Bool) {
        let backgroundColor: NSColor
        if isSelected {
            backgroundColor = dashboardAdaptiveColor(
                light: NSColor.systemBlue.withAlphaComponent(0.11),
                dark: NSColor.white.withAlphaComponent(0.12)
            )
        } else if isHovered {
            backgroundColor = dashboardAdaptiveColor(
                light: NSColor.systemBlue.withAlphaComponent(0.055),
                dark: NSColor.white.withAlphaComponent(0.075)
            )
        } else {
            backgroundColor = .clear
        }
        let foregroundColor: NSColor = isSelected
            ? .controlAccentColor
            : (isHovered ? .labelColor : .secondaryLabelColor)

        let changes = {
            self.layer?.backgroundColor = backgroundColor.cgColor
            self.iconView?.contentTintColor = foregroundColor
            self.titleLabel?.textColor = foregroundColor
        }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                changes()
            }
        } else {
            changes()
        }
    }
}

final class QuotaProgressView: NSView {
    let percentage: Double

    init(percentage: Double) {
        self.percentage = min(100, max(0, percentage))
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let track = bounds
        let radius = track.height / 2
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        let width = track.width * CGFloat(percentage / 100)
        guard width > 0 else { return }
        let fill = NSRect(x: track.minX, y: track.minY, width: max(track.height, width), height: track.height)
        Self.progressColor(for: percentage).setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }

    static func progressColor(for percentage: Double) -> NSColor {
        switch percentage {
        case let value where value > 50: return .systemGreen
        case 25...50: return .systemYellow
        case 10..<25: return .systemOrange
        default: return .systemRed
        }
    }
}

final class LunaReserveCardView: NSView {
    private let titleLabel = NSTextField(labelWithString: tr(.keyLunaReserveTitle))
    private let statusLabel = NSTextField(labelWithString: "")
    private let remainingLabel = NSTextField(labelWithString: "")
    private let resetLabel = NSTextField(labelWithString: "")
    private let progressHost = NSView()
    private var progressHostHeightConstraint: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("lunaReserveCard")

        titleLabel.identifier = NSUserInterfaceItemIdentifier("lunaReserveTitle")
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        statusLabel.identifier = NSUserInterfaceItemIdentifier("lunaReserveStatus")
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.alignment = .right
        remainingLabel.identifier = NSUserInterfaceItemIdentifier("lunaReserveRemaining")
        remainingLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        resetLabel.identifier = NSUserInterfaceItemIdentifier("lunaReserveReset")
        resetLabel.font = .systemFont(ofSize: 12)
        resetLabel.textColor = .secondaryLabelColor

        let heading = NSStackView(views: [titleLabel, NSView(), statusLabel])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        let details = NSStackView(views: [remainingLabel, resetLabel])
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 4
        progressHost.identifier = NSUserInterfaceItemIdentifier("lunaReserveProgressHost")
        progressHost.translatesAutoresizingMaskIntoConstraints = false
        progressHostHeightConstraint = progressHost.heightAnchor.constraint(equalToConstant: 6)
        progressHostHeightConstraint.isActive = true

        let stack = NSStackView(views: [heading, details, progressHost])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heading.widthAnchor.constraint(equalTo: stack.widthAnchor),
            details.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progressHost.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func update(quota: LunaReserveQuota) {
        titleLabel.stringValue = tr(.keyLunaReserveTitle)
        statusLabel.stringValue = quota.status.localizedText
        statusLabel.textColor = Self.statusColor(for: quota.status)
        remainingLabel.stringValue = quota.remainingText
        resetLabel.stringValue = quota.resetText
        progressHost.subviews.forEach { $0.removeFromSuperview() }
        if let remaining = quota.remaining {
            progressHost.isHidden = false
            progressHostHeightConstraint.constant = 6
            let progress = QuotaProgressView(percentage: remaining)
            progress.translatesAutoresizingMaskIntoConstraints = false
            progressHost.addSubview(progress)
            NSLayoutConstraint.activate([
                progress.leadingAnchor.constraint(equalTo: progressHost.leadingAnchor),
                progress.trailingAnchor.constraint(equalTo: progressHost.trailingAnchor),
                progress.topAnchor.constraint(equalTo: progressHost.topAnchor),
                progress.bottomAnchor.constraint(equalTo: progressHost.bottomAnchor)
            ])
        } else {
            // A missing percentage is unknown, not zero. Remove the host from
            // the stack so unavailable/loading cards do not reserve a blank
            // progress-bar row.
            progressHost.isHidden = true
            progressHostHeightConstraint.constant = 0
        }
    }

    private static func statusColor(for status: LunaReserveQuota.Status) -> NSColor {
        switch status {
        case .loading:
            return .secondaryLabelColor
        case .available:
            return .systemGreen
        case .unavailable:
            return .secondaryLabelColor
        }
    }
}

final class HoverLinkTextField: NSTextField {
    var onActivate: (() -> Void)?
    private(set) var visibleTextHitRect = NSRect.zero
    private var trackingAreaReference: NSTrackingArea?
    private var isHovered = false
    private var isApplyingStyle = false

    override var stringValue: String {
        didSet {
            guard !isApplyingStyle else { return }
            applyStyle(text: stringValue, underlined: isHovered)
            updateVisibleTextHitRect()
        }
    }

    override var font: NSFont? {
        didSet {
            guard !isApplyingStyle else { return }
            applyStyle(text: stringValue, underlined: isHovered)
            updateVisibleTextHitRect()
        }
    }

    init(text: String) {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = false
        lineBreakMode = .byTruncatingTail
        font = .systemFont(ofSize: 12, weight: .medium)
        applyStyle(text: text, underlined: false)
        updateVisibleTextHitRect()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        updateVisibleTextHitRect()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshTrackingArea()
        synchronizeHoverStateWithMouseLocation()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateVisibleTextHitRect()
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        updateVisibleTextHitRect()
    }

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        super.setBoundsOrigin(newOrigin)
        updateVisibleTextHitRect()
    }

    override func updateTrackingAreas() {
        removeTrackingAreaReference()
        super.updateTrackingAreas()
        updateVisibleTextHitRect()
        installTrackingArea()
        synchronizeHoverStateWithMouseLocation()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        updateVisibleTextHitRect()
        guard !visibleTextHitRect.isEmpty else { return }
        addCursorRect(visibleTextHitRect, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        setHovering(isPointInsideVisibleText(for: event))
    }

    override func mouseExited(with event: NSEvent) {
        setHovering(false)
    }

    override func cursorUpdate(with event: NSEvent) {
        setHovering(isPointInsideVisibleText(for: event))
    }

    override func mouseMoved(with event: NSEvent) {
        setHovering(isPointInsideVisibleText(for: event))
    }

    override func mouseDown(with event: NSEvent) {
        guard isPointInsideVisibleText(for: event) else {
            setHovering(false)
            return
        }
        NSCursor.pointingHand.set()
        onActivate?()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            tearDownInteraction()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func removeFromSuperview() {
        tearDownInteraction()
        super.removeFromSuperview()
    }

    /// Menu item hosts use their own tracking area because NSMenu may keep
    /// movement in its tracking loop instead of delivering it to this view.
    /// The point is deliberately converted before reusing the same visible
    /// glyph hit test used by the normal Dashboard tracking path.
    func updateHover(atHostPoint point: NSPoint, in host: NSView) {
        let pointInLink = convert(point, from: host)
        setHovering(visibleTextHitRect.contains(pointInLink))
    }

    func clearHoverState() {
        setHovering(false)
    }

    private func installTrackingArea() {
        guard !visibleTextHitRect.isEmpty else { return }
        let area = NSTrackingArea(
            rect: visibleTextHitRect,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    private func removeTrackingAreaReference() {
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
            self.trackingAreaReference = nil
        }
    }

    private func setHovering(_ hovered: Bool) {
        guard isHovered != hovered else {
            if hovered {
                NSCursor.pointingHand.set()
            }
            return
        }
        isHovered = hovered
        applyStyle(text: stringValue, underlined: hovered)
        if hovered {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func synchronizeHoverStateWithMouseLocation() {
        guard let window else {
            if isHovered { setHovering(false) }
            return
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setHovering(visibleTextHitRect.contains(point))
    }

    private func tearDownInteraction() {
        removeTrackingAreaReference()
        if isHovered {
            isHovered = false
            applyStyle(text: stringValue, underlined: false)
        }
        NSCursor.arrow.set()
    }

    private func isPointInsideVisibleText(for event: NSEvent) -> Bool {
        let point: NSPoint
        if window != nil {
            point = convert(event.locationInWindow, from: nil)
        } else {
            point = event.locationInWindow
        }
        return visibleTextHitRect.contains(point)
    }

    private func updateVisibleTextHitRect() {
        let previousRect = visibleTextHitRect
        visibleTextHitRect = calculateVisibleTextHitRect()
        guard previousRect != visibleTextHitRect else { return }

        window?.invalidateCursorRects(for: self)
        refreshTrackingArea()
        synchronizeHoverStateWithMouseLocation()
    }

    private func refreshTrackingArea() {
        guard trackingAreaReference != nil || window != nil else { return }
        removeTrackingAreaReference()
        installTrackingArea()
    }

    private func calculateVisibleTextHitRect() -> NSRect {
        guard !bounds.isEmpty,
              let cell,
              !attributedStringValue.string.isEmpty
        else {
            return .zero
        }

        let titleRect = cell.titleRect(forBounds: bounds)
        guard !titleRect.isEmpty else { return .zero }

        let textStorage = NSTextStorage(attributedString: layoutAttributedString())
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: titleRect.size)
        textContainer.lineFragmentPadding = 0
        textContainer.lineBreakMode = cell.lineBreakMode
        textContainer.maximumNumberOfLines = 1
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        let laidGlyphRange = layoutManager.glyphRange(for: textContainer)
        guard laidGlyphRange.length > 0 else { return .zero }

        let visibleGlyphRange: NSRange
        let truncatedGlyphRange = layoutManager.truncatedGlyphRange(
            inLineFragmentForGlyphAt: laidGlyphRange.location
        )
        if truncatedGlyphRange.location == NSNotFound {
            visibleGlyphRange = laidGlyphRange
        } else {
            visibleGlyphRange = NSRange(
                location: laidGlyphRange.location,
                length: max(0, truncatedGlyphRange.location - laidGlyphRange.location)
            )
        }

        let glyphRect = layoutManager.boundingRect(forGlyphRange: visibleGlyphRange, in: textContainer)
        guard !glyphRect.isEmpty else { return .zero }

        let glyphHitRect = NSRect(
            x: titleRect.minX + glyphRect.minX,
            y: titleRect.minY + glyphRect.minY,
            width: glyphRect.width,
            height: glyphRect.height
        )
        return glyphHitRect
            .insetBy(dx: -2, dy: -2)
            .intersection(bounds)
    }

    private func layoutAttributedString() -> NSAttributedString {
        let attributedString = NSMutableAttributedString(attributedString: attributedStringValue)
        guard attributedString.length > 0 else { return attributedString }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = cell?.alignment ?? alignment
        paragraphStyle.lineBreakMode = cell?.lineBreakMode ?? lineBreakMode
        attributedString.addAttribute(
            .paragraphStyle,
            value: paragraphStyle,
            range: NSRange(location: 0, length: attributedString.length)
        )
        return attributedString
    }

    private func applyStyle(text: String, underlined: Bool) {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.linkColor
        ]
        if underlined { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        isApplyingStyle = true
        attributedStringValue = NSAttributedString(string: text, attributes: attributes)
        isApplyingStyle = false
        updateVisibleTextHitRect()
    }
}

/// A local event bridge for one Provider link hosted by an `NSMenuItem.view`.
/// It intentionally tracks the card only to forward movement; the link still
/// owns the glyph-only hover and activation boundary.
final class MenuHoverLinkHostView: NSView {
    private weak var link: HoverLinkTextField?
    private var trackingAreaReference: NSTrackingArea?
    var isMenuTracking: (() -> Bool)?

    var trackedLink: HoverLinkTextField? { link }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func track(_ link: HoverLinkTextField) {
        self.link = link
        refreshTrackingArea()
        synchronizeHoverState()
    }

    override func updateTrackingAreas() {
        removeTrackingAreaReference()
        super.updateTrackingAreas()
        installTrackingArea()
        synchronizeHoverState()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshTrackingArea()
        synchronizeHoverState()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            removeTrackingAreaReference()
            link?.clearHoverState()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func mouseEntered(with event: NSEvent) {
        forwardHover(from: event)
    }

    override func mouseMoved(with event: NSEvent) {
        forwardHover(from: event)
    }

    override func mouseExited(with event: NSEvent) {
        link?.clearHoverState()
    }

    override func removeFromSuperview() {
        tearDownWindowTracking()
        super.removeFromSuperview()
    }

    func forwardHover(atHostPoint point: NSPoint) {
        link?.updateHover(atHostPoint: point, in: self)
    }

    private func installTrackingArea() {
        guard link != nil, !bounds.isEmpty else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    private func refreshTrackingArea() {
        guard trackingAreaReference != nil || window != nil else { return }
        removeTrackingAreaReference()
        installTrackingArea()
    }

    private func removeTrackingAreaReference() {
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
            self.trackingAreaReference = nil
        }
    }

    private func forwardHover(from event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        forwardHover(atHostPoint: point)
    }

    private func synchronizeHoverState() {
        guard let window else {
            link?.clearHoverState()
            return
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        forwardHover(atHostPoint: point)
    }

    private func tearDownWindowTracking() {
        removeTrackingAreaReference()
        link?.clearHoverState()
    }
}

enum DashboardSection: Int, CaseIterable {
    case general
    case menuBar
    case menu
    case advanced
    case about

    var title: String {
        switch self {
        case .general: return tr(.keyDashboardComponentsGeneral)
        case .menuBar: return tr(.keyDashboardComponentsMenuBar)
        case .menu: return tr(.keyDashboardComponentsMenu)
        case .advanced: return tr(.keyDashboardComponentsAdvanced)
        case .about: return tr(.keyDashboardComponentsAbout)
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape.fill"
        case .menuBar: return "menubar.rectangle"
        case .menu: return "filemenu.and.selection"
        case .advanced: return "slider.horizontal.3"
        case .about: return "info.circle.fill"
        }
    }

    var chipColor: NSColor {
        switch self {
        case .general: return .systemGray
        case .menuBar: return .systemBlue
        case .menu: return .systemTeal
        case .advanced: return .systemPurple
        case .about: return .systemGreen
        }
    }
}
