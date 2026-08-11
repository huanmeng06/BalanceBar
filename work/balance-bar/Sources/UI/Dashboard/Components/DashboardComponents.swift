import AppKit

var dashboardUsesDarkAppearance: Bool {
    NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
}

func dashboardAdaptiveColor(light: NSColor, dark: NSColor) -> NSColor {
    dashboardUsesDarkAppearance ? dark : light
}

final class DashboardNavigationRowView: NSView {
    weak var iconView: NSImageView?
    weak var titleLabel: NSTextField?

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

final class HoverLinkTextField: NSTextField {
    var onActivate: (() -> Void)?
    private(set) var visibleTextHitRect = NSRect.zero
    private var trackingAreaReference: NSTrackingArea?
    private weak var menuTrackingHost: NSView?
    private var menuTrackingAreaReference: NSTrackingArea?
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

    /// Menu item views are tracked by NSMenu's modal event loop. Attach a
    /// local tracking area to the item view so mouse movement continues to
    /// update the cursor even when the normal cursor-update path is skipped.
    /// The area is intentionally used only for cursor state; activation still
    /// checks `visibleTextHitRect`.
    func installMenuTrackingArea(in host: NSView) {
        removeMenuTrackingArea()
        menuTrackingHost = host
        let area = NSTrackingArea(
            rect: host.bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways],
            owner: self,
            userInfo: nil
        )
        host.addTrackingArea(area)
        menuTrackingAreaReference = area
    }

    private func installTrackingArea() {
        guard !visibleTextHitRect.isEmpty else { return }
        let area = NSTrackingArea(
            rect: visibleTextHitRect,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    private func removeMenuTrackingArea() {
        if let menuTrackingHost, let menuTrackingAreaReference {
            menuTrackingHost.removeTrackingArea(menuTrackingAreaReference)
        }
        menuTrackingHost = nil
        menuTrackingAreaReference = nil
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
        removeMenuTrackingArea()
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
        guard trackingAreaReference != nil else { return }
        removeTrackingAreaReference()
        installTrackingArea()
        synchronizeHoverStateWithMouseLocation()
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

enum DashboardSection: Int, CaseIterable {
    case general
    case menuBar
    case menu
    case advanced
    case about

    var title: String {
        switch self {
        case .general: return tr("通用", "General")
        case .menuBar: return tr("菜单栏", "Menu Bar")
        case .menu: return tr("菜单", "Menu")
        case .advanced: return tr("高级", "Advanced")
        case .about: return tr("关于", "About")
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
