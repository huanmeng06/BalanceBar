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
    private var trackingAreaReference: NSTrackingArea?
    private var isHovered = false

    init(text: String) {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = false
        lineBreakMode = .byTruncatingTail
        font = .systemFont(ofSize: 12, weight: .medium)
        applyStyle(text: text, underlined: false)
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        removeTrackingAreaReference()
        super.updateTrackingAreas()
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
        synchronizeHoverStateWithMouseLocation()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        setHovering(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovering(false)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseDown(with event: NSEvent) {
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
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if bounds.contains(point) {
            setHovering(true)
        } else if isHovered {
            setHovering(false)
        }
    }

    private func tearDownInteraction() {
        removeTrackingAreaReference()
        if isHovered {
            isHovered = false
            applyStyle(text: stringValue, underlined: false)
        }
        NSCursor.arrow.set()
    }

    private func applyStyle(text: String, underlined: Bool) {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.linkColor
        ]
        if underlined { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        attributedStringValue = NSAttributedString(string: text, attributes: attributes)
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

struct DashboardScrollPosition {
    let operation: String
    let visibleDocumentOffset: CGFloat
    let contentOriginY: CGFloat
    let distanceFromBottom: CGFloat
    let previousMaximumOffset: CGFloat
    let bottomAnchorView: NSView?
    let bottomAnchorViewportY: CGFloat?
}
