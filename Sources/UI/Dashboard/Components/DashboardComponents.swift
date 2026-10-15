import AppKit

/// Shared visual language for transient text tooltips used by compact
/// controls and wider account labels. Callers own their content sizing and
/// layout-specific padding.
enum DashboardTextTooltip {
    static var font: NSFont { NSFont.toolTipsFont(ofSize: NSFont.smallSystemFontSize) }

    static func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        return popover
    }

    static func configure(_ label: NSTextField, alignment: NSTextAlignment = .left) {
        label.font = font
        label.textColor = .labelColor
        label.alignment = alignment
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.isBordered = false
    }
}

/// Menu-hosted hover-hint bubble. Short copy stays a compact single line;
/// longer copy wraps at `maximumTextWidth` instead of growing into an
/// infinite-width bar. Unlike mailbox tooltips, this does not force a
/// 160pt minimum width.
struct DashboardTextTooltipLayout: Equatable {
    static let maximumTextWidth: CGFloat = 280
    static let textHeightMeasurementSlack: CGFloat = 2
    static let horizontalInset: CGFloat = 10
    static let verticalInset: CGFloat = 6

    let textWidth: CGFloat
    let textHeight: CGFloat
    let contentSize: NSSize
    let wraps: Bool

    static func make(for text: String, font: NSFont) -> Self {
        let unwrappedSize = (text as NSString).size(withAttributes: [.font: font])
        let unwrappedWidth = ceil(unwrappedSize.width)
        let singleLineHeight = max(
            ceil(font.ascender - font.descender + 2),
            ceil(unwrappedSize.height)
        )
        let wraps = unwrappedWidth > maximumTextWidth
        if !wraps {
            let textWidth = max(1, unwrappedWidth + 2)
            return Self(
                textWidth: textWidth,
                textHeight: singleLineHeight,
                contentSize: NSSize(
                    width: textWidth + horizontalInset * 2,
                    height: singleLineHeight + verticalInset * 2
                ),
                wraps: false
            )
        }

        let textWidth = maximumTextWidth
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        let measuredText = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .paragraphStyle: paragraphStyle
            ]
        ).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let measurementLabel = NSTextField(wrappingLabelWithString: text)
        measurementLabel.font = font
        measurementLabel.lineBreakMode = .byWordWrapping
        measurementLabel.usesSingleLineMode = false
        measurementLabel.maximumNumberOfLines = 0
        measurementLabel.preferredMaxLayoutWidth = textWidth
        measurementLabel.cell?.wraps = true
        measurementLabel.cell?.truncatesLastVisibleLine = false
        measurementLabel.cell?.lineBreakMode = .byWordWrapping
        let textHeight = max(
            singleLineHeight,
            ceil(measuredText.height) + textHeightMeasurementSlack,
            ceil(measurementLabel.fittingSize.height)
        )
        return Self(
            textWidth: textWidth,
            textHeight: textHeight,
            contentSize: NSSize(
                width: textWidth + horizontalInset * 2,
                height: textHeight + verticalInset * 2
            ),
            wraps: true
        )
    }
}

/// Source / hint bubble for menu-hosted hover links. Native `toolTip`
/// often never appears inside an `NSMenu` tracking loop.
struct DashboardForecastTooltipContent: Equatable {
    let title: String
    let body: String
    let source: String
    let disclaimer: String

    var plainText: String { [title, body, source, disclaimer].joined(separator: "\n\n") }
}

final class DashboardForecastTooltipViewController: NSViewController {
    private let content: DashboardForecastTooltipContent
    static let padding: CGFloat = 13

    init(content: DashboardForecastTooltipContent) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let sourceFont = NSFont.systemFont(ofSize: 12)
        // Allow the source/date to fit one line in common locales; longer
        // translations wrap naturally rather than widening indefinitely.
        let width = min(360, max(264, ceil((content.source as NSString).size(
            withAttributes: [.font: sourceFont]
        ).width) + 4))
        let rows: [(String, String, NSFont, NSColor, CGFloat)] = [
            ("title", content.title, .systemFont(ofSize: 13, weight: .semibold), .labelColor, 5),
            ("body", content.body, .systemFont(ofSize: 12), NSColor.labelColor, 10),
            ("source", content.source, sourceFont, .secondaryLabelColor, 10),
            ("disclaimer", content.disclaimer, .systemFont(ofSize: 11), .secondaryLabelColor, 0)
        ]
        let root = NSView()
        var labels: [(NSTextField, CGFloat, CGFloat)] = []
        for (id, text, font, color, spacing) in rows {
            let label = NSTextField(wrappingLabelWithString: text)
            label.identifier = NSUserInterfaceItemIdentifier("forecastTooltip.\(id)")
            label.font = font
            label.textColor = color
            label.lineBreakMode = .byWordWrapping
            label.usesSingleLineMode = false
            label.maximumNumberOfLines = 0
            label.preferredMaxLayoutWidth = width
            label.cell?.wraps = true
            label.cell?.truncatesLastVisibleLine = false
            let measured = label.cell?.cellSize(forBounds: NSRect(
                x: 0, y: 0, width: width, height: .greatestFiniteMagnitude
            )).height ?? label.fittingSize.height
            let height = max(ceil(measured) + 2, ceil(font.ascender - font.descender + 2))
            labels.append((label, height, spacing))
            root.addSubview(label)
        }
        let totalHeight = labels.reduce(Self.padding * 2) { $0 + $1.1 + $1.2 }
        root.frame = NSRect(x: 0, y: 0, width: width + Self.padding * 2, height: totalHeight)
        var top = totalHeight - Self.padding
        for (label, height, spacing) in labels {
            label.frame = NSRect(x: Self.padding, y: top - height, width: width, height: height)
            top -= height + spacing
        }
        view = root
    }
}

final class DashboardTextTooltipViewController: NSViewController {
    private let text: String

    init(text: String) {
        self.text = text
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let font = DashboardTextTooltip.font
        let layout = DashboardTextTooltipLayout.make(for: text, font: font)
        let root = NSView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: layout.contentSize.width,
                height: layout.contentSize.height
            )
        )
        let label: NSTextField
        if layout.wraps {
            label = NSTextField(wrappingLabelWithString: text)
            label.lineBreakMode = .byWordWrapping
            label.usesSingleLineMode = false
            label.maximumNumberOfLines = 0
            label.preferredMaxLayoutWidth = layout.textWidth
            label.cell?.wraps = true
            label.cell?.truncatesLastVisibleLine = false
            label.cell?.lineBreakMode = .byWordWrapping
        } else {
            label = NSTextField(labelWithString: text)
        }
        DashboardTextTooltip.configure(label)
        label.stringValue = text
        label.frame = NSRect(
            x: DashboardTextTooltipLayout.horizontalInset,
            y: DashboardTextTooltipLayout.verticalInset,
            width: layout.textWidth,
            height: layout.textHeight
        )
        root.addSubview(label)
        view = root
    }
}

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

enum QuotaProgressFillOrigin: Equatable {
    case leading
    case trailing
}

final class QuotaProgressView: NSView {
    private(set) var percentage: Double {
        didSet {
            if oldValue != percentage {
                needsDisplay = true
            }
        }
    }
    var fillRatio: Double { percentage / 100 }
    let colorConfiguration: QuotaProgressColorConfiguration
    let fillOrigin: QuotaProgressFillOrigin
    private var interpolator: OverviewNumericInterpolator?
    private var pendingAnimatedPercentage: Double?
    private var pendingAnimatedDuration: TimeInterval = OverviewNumericTransition.duration

    var hasPendingAnimationForTesting: Bool { pendingAnimatedPercentage != nil }

    init(
        percentage: Double,
        colorConfiguration: QuotaProgressColorConfiguration = .default,
        fillOrigin: QuotaProgressFillOrigin = .leading
    ) {
        self.percentage = min(100, max(0, percentage))
        self.colorConfiguration = colorConfiguration.normalized()
        self.fillOrigin = fillOrigin
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        interpolator?.cancel()
    }

    func setPercentage(
        _ value: Double,
        animated: Bool,
        duration: TimeInterval = OverviewNumericTransition.duration
    ) {
        let clamped = min(100, max(0, value))
        interpolator?.cancel()
        interpolator = nil
        pendingAnimatedPercentage = nil
        if abs(clamped - percentage) < 0.0001 {
            percentage = clamped
            return
        }
        if !animated {
            percentage = clamped
            return
        }
        if window == nil {
            pendingAnimatedPercentage = clamped
            pendingAnimatedDuration = duration
            return
        }
        animate(to: clamped, duration: duration)
    }

    func playPendingAnimationIfNeeded() {
        guard let pending = pendingAnimatedPercentage else { return }
        pendingAnimatedPercentage = nil
        setPercentage(pending, animated: true, duration: pendingAnimatedDuration)
    }

    private func animate(to value: Double, duration: TimeInterval) {
        let interpolator = OverviewNumericInterpolator(
            from: percentage,
            to: value,
            duration: duration
        ) { [weak self] current in
            self?.percentage = current
        }
        self.interpolator = interpolator
        interpolator.start()
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = bounds
        let radius = track.height / 2
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        guard let fill = Self.fillRect(in: track, percentage: percentage, fillOrigin: fillOrigin) else {
            return
        }
        Self.progressColor(for: colorPercentage, configuration: colorConfiguration).setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }

    /// Trailing fill is elapsed time from the right; color still follows remaining.
    var colorPercentage: Double {
        switch fillOrigin {
        case .leading:
            return percentage
        case .trailing:
            return 100 - percentage
        }
    }

    static func fillRect(
        in bounds: NSRect,
        percentage: Double,
        fillOrigin: QuotaProgressFillOrigin
    ) -> NSRect? {
        let width = bounds.width * CGFloat(min(100, max(0, percentage)) / 100)
        guard width > 0 else { return nil }
        let fillWidth = min(bounds.width, max(bounds.height, width))
        switch fillOrigin {
        case .leading:
            return NSRect(
                x: bounds.minX,
                y: bounds.minY,
                width: fillWidth,
                height: bounds.height
            )
        case .trailing:
            return NSRect(
                x: bounds.maxX - fillWidth,
                y: bounds.minY,
                width: fillWidth,
                height: bounds.height
            )
        }
    }

    static func progressColor(for percentage: Double, configuration: QuotaProgressColorConfiguration = .default) -> NSColor {
        let normalized = configuration.normalized()
        let active = normalized.enabledColorsInOrder
        for (index, color) in active.dropLast().enumerated() {
            guard let boundary = normalized.boundary(after: color) else { continue }
            let belongsToCurrent = index == active.count - 2 ? percentage <= Double(boundary) : percentage < Double(boundary)
            if belongsToCurrent { return color.nsColor }
        }
        return (active.last ?? .green).nsColor
    }
}

/// Geometry is animated directly, never raster-scaled with a transform.
final class PaceTickLayer: CALayer {
    static let restSize = CGSize(width: 2, height: 8)
    static let hoverSize = CGSize(width: 3.5, height: 11)
    private(set) var isHovered = false
    var strokeLayer: CALayer { sublayers!.first { $0.name == "pace.stroke" }! }
    var bodyLayer: CALayer { sublayers!.first { $0.name == "pace.body" }! }

    override init() {
        super.init()
        let stroke = CALayer()
        stroke.name = "pace.stroke"
        let body = CALayer()
        body.name = "pace.body"
        addSublayer(stroke)
        addSublayer(body)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bounds = CGRect(x: 0, y: 0, width: 16, height: 18)
        applyMetrics(hovered: false)
        CATransaction.commit()
    }

    override init(layer: Any) {
        super.init(layer: layer)
        if let source = layer as? PaceTickLayer {
            // Explicitly copy children so model and presentation instances
            // never share our stored geometry references.
            bounds = source.bounds
            position = source.position
            contentsScale = source.contentsScale
            sublayers = [source.strokeLayer, source.bodyLayer].map { original in
                let copy = CALayer()
                copy.name = original.name
                copy.bounds = original.bounds
                copy.position = original.position
                copy.anchorPoint = original.anchorPoint
                copy.cornerRadius = original.cornerRadius
                copy.opacity = original.opacity
                copy.backgroundColor = original.backgroundColor
                copy.contentsScale = original.contentsScale
                return copy
            }
            isHovered = source.isHovered
        }
    }

    required init?(coder: NSCoder) { nil }

    private func applyMetrics(hovered: Bool) {
        let size = hovered ? Self.hoverSize : Self.restSize
        let stroke: CGFloat = hovered ? 1 : 0.75
        bodyLayer.bounds = CGRect(origin: .zero, size: size)
        bodyLayer.cornerRadius = size.width / 2
        bodyLayer.opacity = hovered ? 1 : 0.85
        strokeLayer.bounds = CGRect(x: 0, y: 0, width: size.width + stroke * 2, height: size.height + stroke * 2)
        strokeLayer.cornerRadius = strokeLayer.bounds.width / 2
        bodyLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        strokeLayer.position = bodyLayer.position
    }

    func updateGeometry(center: CGPoint, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        position = center
        for node in [self, strokeLayer, bodyLayer] { node.contentsScale = scale > 0 ? scale : 1 }
        CATransaction.commit()
    }

    func updateColors(for appearance: NSAppearance) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        appearance.performAsCurrentDrawingAppearance {
            bodyLayer.backgroundColor = NSColor.labelColor.cgColor
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            strokeLayer.backgroundColor = (dark ? NSColor.black : NSColor.white).withAlphaComponent(0.4).cgColor
        }
        CATransaction.commit()
    }

    func setHovered(_ hovered: Bool, reduceMotion: Bool, immediately: Bool = false) {
        guard isHovered != hovered || reduceMotion || immediately else { return }
        let nodes = [bodyLayer, strokeLayer]
        let starts = nodes.map { node -> (CGRect, CGFloat, Float) in
            let visible = node.presentation() ?? node
            return (visible.bounds, visible.cornerRadius, visible.opacity)
        }
        nodes.forEach { $0.removeAllAnimations() }
        isHovered = hovered
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyMetrics(hovered: hovered)
        CATransaction.commit()
        guard !reduceMotion, !immediately else { return }
        for (index, node) in nodes.enumerated() {
            let values: [(String, Any, Any)] = [
                ("bounds", NSValue(rect: starts[index].0), NSValue(rect: node.bounds)),
                ("cornerRadius", starts[index].1, node.cornerRadius),
                ("opacity", starts[index].2, node.opacity)
            ]
            for (key, from, to) in values {
                let animation: CABasicAnimation
                if hovered {
                    let spring = CASpringAnimation(keyPath: key)
                    spring.damping = 18
                    spring.stiffness = 320
                    spring.mass = 1
                    spring.initialVelocity = 0
                    spring.duration = spring.settlingDuration
                    animation = spring
                } else {
                    animation = CABasicAnimation(keyPath: key)
                    animation.duration = 0.15
                    animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                }
                animation.fromValue = from
                animation.toValue = to
                node.add(animation, forKey: "pace.\(key)")
            }
        }
    }
}

private final class QuotaPaceMarkerOverlay: NSView {
    let tick = PaceTickLayer()
    var centerX: CGFloat = 0 { didSet { updateGeometry() } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(tick)
        tick.updateColors(for: effectiveAppearance)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() { super.layout(); updateGeometry() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateGeometry() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateGeometry() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        tick.updateColors(for: effectiveAppearance)
    }

    private func updateGeometry() {
        tick.updateGeometry(center: CGPoint(x: centerX, y: bounds.midY), scale: window?.backingScaleFactor ?? 1)
    }
}

final class QuotaProgressPaceView: NSView, NSPopoverDelegate {
    let progress: QuotaProgressView
    let numericIdentity: OverviewNumericIdentity
    private(set) var quotaWindow: OfficialQuotaWindow
    private(set) var pace: OfficialQuotaUsagePace?
    private(set) var prediction: OfficialQuotaUsagePrediction?
    private let marker = QuotaPaceMarkerOverlay(frame: .zero)
    var markerLayerForTesting: PaceTickLayer { marker.tick }
    var markerReduceMotionForTesting: Bool?
    private var reduceMarkerMotion: Bool { markerReduceMotionForTesting ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    func refreshMarkerAccessibility() {
        guard !isMenuDismissalSuspended else { return }
        if reduceMarkerMotion {
            marker.tick.setHovered(isHovered, reduceMotion: true)
            popover?.animates = false
        }
    }
    private var trackingAreaReference: NSTrackingArea?
    // Detached previews/tests use the same coordinator, never a second timing implementation.
    private lazy var detachedInteraction = SectionFocusController()
    private var hoverInteraction: SectionFocusController { menuHoverHost?.sectionFocus ?? detachedInteraction }
    private var popover: NSPopover?
    private var closingPopovers: [NSPopover] = []
    var dismissalTrace: MenuDismissalTrace?
    var dismissalExperiment = PaceDismissalExperiment.current
    private var isMenuDismissalSuspended = false
    private var popoverTraces: [ObjectIdentifier: MenuDismissalTrace] = [:]
    var closingPopoverCountForTesting: Int { closingPopovers.count }
    private var presentationNow = Date()
    private var displayTimeZone = TimeZone.autoupdatingCurrent
    var pointerLocationForTesting: NSPoint?
    var onHoverChanged: ((Bool) -> Void)?
    private(set) var isHovered = false {
        didSet {
            guard oldValue != isHovered else { return }
            dismissalTrace?.record(isHovered ? "marker.enter" : "marker.leave", view: self,
                details: "kind=\(quotaWindow.kind); hovered=\(isHovered)")
            if let onHoverChanged { onHoverChanged(isHovered) }
            else {
                hoverInteraction.isActive = isMenuTracking
                hoverInteraction.hoverChanged(quotaWindow.kind == .sevenDay ? .sevenDay : .fiveHour,
                    isHovering: isHovered, pace: self)
            }
        }
    }
    private(set) var isMenuTracking = false
    var isTooltipVisible: Bool { popover?.isShown == true }
    // Background XCTest parks native windows offscreen and denies key focus.
    // Inject only system presentation; production always uses NSPopover.
    var makePopoverForTesting: (() -> NSPopover)?
    var hasPendingShowForTesting: Bool { hoverInteraction.hasPendingShow(for: self) }
    var hasPendingCloseForTesting: Bool { hoverInteraction.hasPendingClose(for: self) }

    init(
        percentage: Double,
        window: OfficialQuotaWindow,
        identity: OverviewNumericIdentity,
        now: Date,
        colorConfiguration: QuotaProgressColorConfiguration,
        cycleStart: Date? = nil,
        timeZone: TimeZone = .autoupdatingCurrent
    ) {
        self.progress = QuotaProgressView(percentage: percentage, colorConfiguration: colorConfiguration)
        self.quotaWindow = window
        self.numericIdentity = identity
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("quotaProgressPace")
        progress.identifier = OverviewNumericPresentation.progressIdentifier(for: identity)
        wantsLayer = true
        addSubview(progress)
        addSubview(marker)
        setAccessibilityRole(.staticText)
        update(window: window, now: now, cycleStart: cycleStart, timeZone: timeZone)
    }

    required init?(coder: NSCoder) { nil }

    // Hover is forwarded by the menu host; decoration must not consume clicks or scrolling.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    deinit {
        popover?.animates = false
        popover?.close()
    }

    func setPercentage(_ value: Double, animated: Bool, duration: TimeInterval) {
        guard !isMenuDismissalSuspended else { return }
        progress.setPercentage(value, animated: animated, duration: duration)
    }

    func update(window: OfficialQuotaWindow, now: Date, cycleStart: Date? = nil, timeZone: TimeZone = .autoupdatingCurrent) {
        guard !isMenuDismissalSuspended else { return }
        let next = OfficialQuotaUsagePace.make(for: window, now: now)
        if quotaWindow.resetAt != window.resetAt || quotaWindow.kind != window.kind
            || quotaWindow.durationSeconds != window.durationSeconds || next == nil {
            menuHoverHost?.invalidateSectionFocus(for: self)
            clearInteraction()
        }
        quotaWindow = window
        presentationNow = now
        displayTimeZone = timeZone
        pace = next
        prediction = OfficialQuotaUsagePrediction.make(for: window, cycleStart: cycleStart, now: now)
        marker.isHidden = next == nil
        marker.centerX = markerCenterX
        marker.needsDisplay = true
        updateTrackingAreas()
        reconcileHoverAfterGeometryChange()
        setAccessibilityLabel(accessibilityText)
        setAccessibilityHelp(accessibilityText)
        if isTooltipVisible { showTooltip() }
    }

    var markerCenterX: CGFloat {
        1 + max(0, bounds.width - 2) * CGFloat((pace?.expectedRemaining ?? 0) / 100)
    }

    var markerHitRect: NSRect {
        guard pace != nil else { return .zero }
        return NSRect(x: markerCenterX - 8, y: bounds.midY - 9, width: 16, height: 18)
            .intersection(bounds).intersection(visibleRect)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard !isMenuDismissalSuspended else { return }
        // Keep the original track frame exact: Auto Layout rounds a 5pt child
        // centered inside an 18pt host by half a point on a 1x backing scale.
        progress.frame = NSRect(x: 0, y: bounds.midY - 2.5, width: bounds.width, height: 5)
        marker.frame = bounds
        let next = markerCenterX
        marker.centerX = next
        marker.needsDisplay = true
        updateTrackingAreas()
        reconcileHoverAfterGeometryChange()
        if isTooltipVisible { showTooltip() }
    }

    private func reconcileHoverAfterGeometryChange() {
        guard isHovered else { return }
        let point = pointerLocationForTesting ?? window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) }
        if point.map({ markerHitRect.contains($0) }) != true { clearInteraction() }
    }

    override func updateTrackingAreas() {
        if isMenuDismissalSuspended {
            if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
            trackingAreaReference = nil
            super.updateTrackingAreas()
            return
        }
        if trackingAreaReference?.rect == markerHitRect { return }
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        trackingAreaReference = nil
        super.updateTrackingAreas()
        guard !markerHitRect.isEmpty else { return }
        let area = NSTrackingArea(rect: markerHitRect,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaReference = area
    }

    func invalidatePresentation() {
        if isMenuDismissalSuspended || menuHoverHost?.isMenuDismissing == true {
            stopMenuInteractionPreservingVisuals()
            return
        }
        menuHoverHost?.invalidateSectionFocus(for: self)
        isMenuTracking = false
        clearInteraction()
        pace = nil
        prediction = nil
        marker.isHidden = true
        updateTrackingAreas()
        setAccessibilityLabel("")
        setAccessibilityHelp("")
    }

    func setMenuTracking(_ active: Bool) {
        if isMenuDismissalSuspended {
            if !active { stopMenuInteractionPreservingVisuals() }
            return
        }
        isMenuTracking = active
        if !active { clearInteraction() }
    }

    func updateHover(at point: NSPoint) {
        let hovering = isMenuTracking && window != nil && !isHidden && markerHitRect.contains(point)
        guard hovering != isHovered else { return }
        marker.tick.setHovered(hovering, reduceMotion: reduceMarkerMotion)
        isHovered = hovering
    }

    func clearInteraction() {
        if isMenuDismissalSuspended || menuHoverHost?.isMenuDismissing == true {
            stopMenuInteractionPreservingVisuals()
            return
        }
        if let host = menuHoverHost { host.invalidateSectionFocus(for: self) }
        else { detachedInteraction.invalidateInteraction(for: self) }
        isHovered = false
        marker.tick.setHovered(false, reduceMotion: reduceMarkerMotion, immediately: true)
        dismissTooltip(animated: false)
    }

    func stopMenuInteractionPreservingVisuals() {
        isMenuDismissalSuspended = true
        isMenuTracking = false
        isHovered = false
        updateTrackingAreas()
        dismissTooltip(animated: false)
    }

    func finishMenuInteractionAfterDismissal() {
        isMenuDismissalSuspended = false
        clearInteraction()
    }

    func dismissTooltip(animated: Bool) {
        // Keep animated closes owned until AppKit reports completion. Never
        // transfer or issue close a second time to a departing Popover.
        if !animated { closingPopovers.forEach { $0.animates = false } }
        guard let departing = popover else { return }
        popover = nil
        departing.delegate = self
        closingPopovers.append(departing)
        departing.animates = animated && !reduceMarkerMotion && dismissalExperiment != .popoverCloseOff
        (popoverTraces[ObjectIdentifier(departing)] ?? dismissalTrace)?.record("popover.close.request", view: self,
            popover: departing, details: "animates=\(departing.animates); closing=\(closingPopovers.count)")
        departing.close()
    }

    func popoverWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSPopover else { return }
        (popoverTraces[ObjectIdentifier(closing)] ?? dismissalTrace)?.record("popover.willClose", view: self,
            popover: closing, details: "animates=\(closing.animates)")
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover else { return }
        let trace = popoverTraces.removeValue(forKey: ObjectIdentifier(closed)) ?? dismissalTrace
        trace?.record("popover.didClose", view: self, popover: closed,
            details: "active_matches=\(popover === closed); closing=\(closingPopovers.count)")
        if popover === closed { popover = nil }
        closingPopovers.removeAll { $0 === closed }
    }

    override func mouseEntered(with event: NSEvent) { forwardHover(event) }
    override func mouseMoved(with event: NSEvent) { forwardHover(event) }
    override func mouseExited(with event: NSEvent) { updateHover(at: NSPoint(x: -100, y: -100)) }
    private var menuHoverHost: MenuHoverLinkHostView? {
        var ancestor = superview
        while let view = ancestor {
            if let host = view as? MenuHoverLinkHostView { return host }
            ancestor = view.superview
        }
        return nil
    }

    private func forwardHover(_ event: NSEvent) {
        if let host = menuHoverHost {
            host.forwardHover(atHostPoint: host.convert(event.locationInWindow, from: nil))
        } else {
            updateHover(at: convert(event.locationInWindow, from: nil))
        }
    }

    func adoptVisibleTooltip(from previous: QuotaProgressPaceView) {
        guard let shared = previous.popover, shared.isShown else { return }
        previous.popover = nil
        if let trace = previous.popoverTraces.removeValue(forKey: ObjectIdentifier(shared)) {
            popoverTraces[ObjectIdentifier(shared)] = trace
        }
        dismissalTrace?.record("popover.transfer", view: self, popover: shared)
        shared.delegate = self
        previous.marker.tick.setHovered(false, reduceMotion: previous.reduceMarkerMotion)
        previous.isHovered = false
        popover = shared
        showTooltip() // Existing content/anchor changes deliberately suppress native animation.
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { setMenuTracking(false) }
        super.viewWillMove(toWindow: newWindow)
    }
    override func removeFromSuperview() {
        setMenuTracking(false)
        super.removeFromSuperview()
    }

    func firePendingShowForTesting() { hoverInteraction.firePendingShowForTesting(for: self) }
    func firePendingCloseForTesting() { hoverInteraction.firePendingCloseForTesting(for: self) }

    var tooltipContent: QuotaPaceTooltipContent? {
        guard let pace else { return nil }
        return QuotaPaceTooltipContent(pace: pace, prediction: prediction, resetAt: quotaWindow.resetAt, windowKind: quotaWindow.kind, now: presentationNow, timeZone: displayTimeZone)
    }

    private var accessibilityText: String {
        guard let content = tooltipContent else { return "" }
        return [content.title, content.body].compactMap { $0 }.joined(separator: "\n")
    }

    func showTooltip() {
        guard isMenuTracking, isHovered, window?.isVisible == true,
              !markerHitRect.isEmpty, let content = tooltipContent else { return }
        let anchorView = (menuHoverHost as NSView?) ?? self
        let anchor = anchorView.convert(markerHitRect, from: self)
        if let popover, popover.isShown {
            popover.animates = false
            if let controller = popover.contentViewController as? QuotaPaceTooltipViewController {
                controller.update(content: content)
                if popover.contentSize != controller.contentSize { popover.contentSize = controller.contentSize }
            }
            if popover.positioningRect != anchor { popover.positioningRect = anchor }
            return
        }
        let controller = QuotaPaceTooltipViewController(content: content)
        controller.loadViewIfNeeded()
        let nextPopover = makePopoverForTesting?() ?? DashboardTextTooltip.makePopover()
        nextPopover.delegate = self
        if let dismissalTrace { popoverTraces[ObjectIdentifier(nextPopover)] = dismissalTrace }
        dismissalTrace?.record("popover.show.request", view: self, popover: nextPopover)
        nextPopover.contentViewController = controller
        nextPopover.contentSize = controller.contentSize
        nextPopover.animates = !reduceMarkerMotion
        // A common menu anchor lets 5h/7d transfer the same native window
        // without closing/reopening a transient popover during menu tracking.
        nextPopover.show(relativeTo: anchor, of: anchorView, preferredEdge: .minY)
        popover = nextPopover.isShown ? nextPopover : nil
        if !nextPopover.isShown { popoverTraces.removeValue(forKey: ObjectIdentifier(nextPopover)) }
        dismissalTrace?.record("popover.show.result", view: self, popover: nextPopover,
            details: "shown=\(nextPopover.isShown); animates=\(nextPopover.animates)")
    }
}

struct QuotaPaceTooltipContent: Equatable {
    let title: String
    let body: String?

    init(title: String, body: String?) {
        self.title = title
        self.body = body
    }

    init(pace: OfficialQuotaUsagePace, prediction: OfficialQuotaUsagePrediction?, resetAt: Date? = nil,
         windowKind: OfficialQuotaWindow.Kind = .fiveHour, language: AppLanguage = .selected, now: Date = Date(), timeZone: TimeZone = .autoupdatingCurrent) {
        title = pace.actualRemaining == 0
            ? tr(.keyQuotaPaceStatusExhausted, language: language) : pace.status.title(language: language)
        switch pace.status {
        case .unused:
            body = tr(.keyQuotaPaceBodyUnused, language: language)
        case _ where pace.actualRemaining == 0:
            if let resetAt, resetAt.timeIntervalSince1970.isFinite, resetAt > now {
                body = tr(.keyQuotaPaceBodyExhausted,
                    arguments: [Self.displayTime(resetAt, now: now, timeZone: timeZone, language: language)], language: language)
            } else {
                body = tr(.keyQuotaPaceBodyResetUnavailable, language: language)
            }
        case .fast:
            if case .runsOut(let seconds) = prediction, seconds.isFinite, seconds > 0,
               let resetAt, resetAt.timeIntervalSince1970.isFinite, resetAt > now,
               now.addingTimeInterval(seconds) < resetAt,
               let rounded = Self.roundedExhaustionDate(now.addingTimeInterval(seconds), now: now, timeZone: timeZone,
                    windowKind: windowKind),
               rounded < resetAt {
                body = tr(.keyQuotaPaceBodyFast,
                    arguments: [Self.displayTime(rounded, now: now, timeZone: timeZone, language: language)], language: language)
            } else {
                body = tr(.keyQuotaPaceBodyQualitativeFast, language: language)
            }
        case .normal:
            body = tr(.keyQuotaPaceBodyNormal, language: language)
        case .slow:
            body = tr(.keyQuotaPaceBodySlow, language: language)
        }
    }

    /// Round the actual instant on the configured local clock, including
    /// DST folds/gaps. Ties move forward; never display a past estimate.
    static func roundedExhaustionDate(_ date: Date, now: Date, timeZone: TimeZone,
                                      windowKind: OfficialQuotaWindow.Kind = .fiveHour) -> Date? {
        guard date.timeIntervalSince1970.isFinite, now.timeIntervalSince1970.isFinite, date > now else { return nil }
        let calendar = AppDisplayTime.calendar(timeZone: timeZone)
        let interval = windowKind == .sevenDay ? 30 : 5
        func floorToInterval(_ value: Date) -> Date? {
            guard let minuteStart = calendar.dateInterval(of: .minute, for: value)?.start else { return nil }
            return calendar.date(byAdding: .minute, value: -(calendar.component(.minute, from: value) % interval), to: minuteStart)
        }
        guard let floor = floorToInterval(date) else { return nil }
        let rounded = date.timeIntervalSince(floor) >= Double(interval * 30)
            ? calendar.date(byAdding: .minute, value: interval, to: floor) : floor
        guard let rounded else { return nil }
        if rounded > now { return rounded }
        return floorToInterval(now).flatMap { calendar.date(byAdding: .minute, value: interval, to: $0) }
    }

    static func displayTime(_ date: Date, now: Date, timeZone: TimeZone, language: AppLanguage) -> String {
        let calendar = AppDisplayTime.calendar(timeZone: timeZone)
        let time = AppDisplayTime.formatter(timeZone: timeZone, dateFormat: "HH:mm").string(from: date)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        if days == 0 { return time }
        if days == 1 { return tr(.keyQuotaPaceTimeTomorrow, arguments: [time], language: language) }
        let formatter = DateFormatter()
        let localeID: String = switch AppLanguage.resolved(for: language, preferredLanguages: Locale.preferredLanguages) {
        case .simplifiedChinese: "zh_CN"
        case .traditionalChineseTaiwan: "zh_TW"
        case .traditionalChineseHongKong: "zh_HK"
        case .japanese: "ja_JP"
        case .korean: "ko_KR"
        case .spanish: "es_ES"
        case .portuguese: "pt_PT"
        case .french: "fr_FR"
        case .german: "de_DE"
        case .russian: "ru_RU"
        case .italian: "it_IT"
        case .english, .system: "en_US"
        }
        formatter.locale = Locale(identifier: localeID)
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        if (2...6).contains(days) {
            formatter.setLocalizedDateFormatFromTemplate("EEE")
        } else {
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            formatter.setLocalizedDateFormatFromTemplate(sameYear ? "Md" : "yMd")
        }
        return "\(formatter.string(from: date)) \(time)"
    }
}

final class QuotaPaceTooltipViewController: NSViewController {
    private(set) var content: QuotaPaceTooltipContent
    private(set) var contentSize = NSSize.zero
    private(set) var layoutRevision = 0
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let stack = NSStackView()
    private var textConstraints: [NSLayoutConstraint] = []
    var visibleLabelsForTesting: [NSTextField] { stack.arrangedSubviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden } }

    init(content: QuotaPaceTooltipContent) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .labelColor
        DashboardTextTooltip.configure(bodyLabel)
        for label in [titleLabel, bodyLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.maximumNumberOfLines = 0
            label.cell?.wraps = true
            label.cell?.truncatesLastVisibleLine = false
            label.lineBreakMode = .byWordWrapping
            label.usesSingleLineMode = false
            label.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10)
        ])
        layoutContent()
    }

    func update(content: QuotaPaceTooltipContent) {
        guard self.content != content else { return }
        self.content = content
        if isViewLoaded { layoutContent() }
        else { loadViewIfNeeded() }
    }

    private func layoutContent() {
        layoutRevision += 1
        titleLabel.stringValue = content.title
        bodyLabel.stringValue = content.body ?? ""
        bodyLabel.isHidden = bodyLabel.stringValue.isEmpty
        let labels = bodyLabel.isHidden ? [titleLabel] : [titleLabel, bodyLabel]
        stack.setViews(labels, in: .top)
        NSLayoutConstraint.deactivate(textConstraints)
        for label in labels {
            label.preferredMaxLayoutWidth = 0
            label.invalidateIntrinsicContentSize()
        }
        let width = min(232, max(1, labels.map { ceil($0.intrinsicContentSize.width) }.max() ?? 1))
        textConstraints = labels.map { $0.widthAnchor.constraint(equalToConstant: width) }
        for label in labels {
            label.preferredMaxLayoutWidth = width
            label.invalidateIntrinsicContentSize()
        }
        NSLayoutConstraint.activate(textConstraints)
        contentSize = view.fittingSize
        view.setFrameSize(contentSize)
        view.layoutSubtreeIfNeeded()
    }
}

private extension OfficialQuotaUsagePace.Status {
    func title(language: AppLanguage) -> String {
        switch self {
        case .unused: tr(.keyQuotaPaceStatusUnused, language: language)
        case .fast: tr(.keyQuotaPaceStatusFast, language: language)
        case .normal: tr(.keyQuotaPaceStatusNormal, language: language)
        case .slow: tr(.keyQuotaPaceStatusSlow, language: language)
        }
    }
}

extension QuotaProgressColor {
    var nsColor: NSColor {
        switch self { case .red: .systemRed; case .orange: .systemOrange; case .yellow: .systemYellow; case .green: .systemGreen }
    }
}

final class LunaReserveCardView: NSView {
    var colorConfiguration: QuotaProgressColorConfiguration = .default
    var showsProgressBar = true
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

    override var isHidden: Bool {
        get { super.isHidden }
        set {
            DashboardSearchVisibility.writeHidden(self, newValue) { super.isHidden = $0 }
        }
    }

    func update(quota: LunaReserveQuota, timeZone: TimeZone = .autoupdatingCurrent) {
        titleLabel.stringValue = tr(.keyLunaReserveTitle)
        statusLabel.stringValue = quota.status.localizedText
        statusLabel.textColor = Self.statusColor(for: quota.status)
        remainingLabel.stringValue = quota.remainingText
        resetLabel.stringValue = quota.resetDisplayText(timeZone: timeZone).map { tr(.keyLunaReserveResetValue, arguments: [$0]) } ?? tr(.keyLunaReserveResetUnavailable)
        progressHost.subviews.forEach { $0.removeFromSuperview() }
        if showsProgressBar, let remaining = quota.remaining {
            progressHost.isHidden = false
            progressHostHeightConstraint.constant = 6
            let progress = QuotaProgressView(percentage: remaining, colorConfiguration: colorConfiguration)
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

class HoverLinkTextField: NSTextField {
    enum InteractionMode: Equatable {
        case normal
        case menuHosted
    }

    var onActivate: (() -> Void)?
    /// Structured forecast presentation; plain hints keep their compact layout.
    var forecastTooltipContent: DashboardForecastTooltipContent?
    /// Invalidate an open bubble only when its displayed content changes.
    /// The next hover presents the latest content without replacing the link.
    func updateForecastTooltipContent(_ content: DashboardForecastTooltipContent) {
        guard forecastTooltipContent != content else { return }
        forecastTooltipContent = content
        hoverHint = content.plainText
        cancelPendingHoverHint()
        dismissHoverHint()
    }

    var restingTextColor: NSColor = .linkColor {
        didSet { applyStyle(text: stringValue, underlined: isHovered) }
    }
    /// Shown while the pointer is over the visible glyphs. Native `toolTip`
    /// is the Dashboard fallback; menu hosts present a popover instead.
    var hoverHint: String = "" {
        didSet {
            refreshNativeTooltip()
            if hoverHint.isEmpty {
                cancelPendingHoverHint()
                dismissHoverHint()
            }
        }
    }
    /// Instance-level delay before the menu popover. Default 0 keeps other
    /// links immediate. Moving inside the same target does not reset.
    var hoverHintDelay: TimeInterval = 0 {
        didSet {
            refreshNativeTooltip()
        }
    }
    private(set) var interactionMode: InteractionMode = .normal
    private(set) var visibleTextHitRect = NSRect.zero
    private(set) var isHoverHintVisible = false
    private(set) var isHoverHintScheduled = false
    private var trackingAreaReference: NSTrackingArea?
    private var isHovered = false
    private var isApplyingStyle = false
    private var hintPopover: NSPopover?
    private var hoverHintTimer: Timer?

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

    override var alignment: NSTextAlignment {
        didSet {
            guard !isApplyingStyle else { return }
            // NSTextField's alignment alone does not update the paragraph
            // embedded in an already styled attributed value.
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
        guard interactionMode == .normal else { return }
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
        guard interactionMode == .normal else { return }
        installTrackingArea()
        synchronizeHoverStateWithMouseLocation()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard interactionMode == .normal else { return }
        updateVisibleTextHitRect()
        guard !visibleTextHitRect.isEmpty else { return }
        addCursorRect(visibleTextHitRect, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        guard interactionMode == .normal else { return }
        setHovering(isPointInsideVisibleText(for: event))
    }

    override func mouseExited(with event: NSEvent) {
        guard interactionMode == .normal else { return }
        setHovering(false)
    }

    override func cursorUpdate(with event: NSEvent) {
        guard interactionMode == .normal else { return }
        setHovering(isPointInsideVisibleText(for: event))
    }

    override func mouseMoved(with event: NSEvent) {
        guard interactionMode == .normal else { return }
        setHovering(isPointInsideVisibleText(for: event))
    }

    override func mouseDown(with event: NSEvent) {
        guard isPointInsideVisibleText(for: event) else {
            return
        }
        if interactionMode == .normal {
            NSCursor.pointingHand.set()
        }
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
        guard interactionMode == .menuHosted else { return }
        let pointInLink = convert(point, from: host)
        setHovering(visibleTextHitRect.contains(pointInLink))
    }

    func setInteractionMode(_ mode: InteractionMode) {
        guard interactionMode != mode else { return }
        removeTrackingAreaReference()
        interactionMode = mode
        guard mode == .normal else {
            clearHoverState()
            return
        }
        refreshTrackingArea()
        synchronizeHoverStateWithMouseLocation()
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
            if hovered, interactionMode == .normal {
                NSCursor.pointingHand.set()
            }
            return
        }
        isHovered = hovered
        applyStyle(text: stringValue, underlined: hovered)
        if hovered, interactionMode == .normal {
            NSCursor.pointingHand.set()
        } else if interactionMode == .normal {
            NSCursor.arrow.set()
        }
        if hovered {
            scheduleHoverHintIfNeeded()
        } else {
            cancelPendingHoverHint()
            dismissHoverHint()
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
        cancelPendingHoverHint()
        dismissHoverHint()
        if isHovered {
            isHovered = false
            applyStyle(text: stringValue, underlined: false)
        }
        if interactionMode == .normal {
            NSCursor.arrow.set()
        }
    }

    private func refreshNativeTooltip() {
        if hoverHintDelay > 0 || hoverHint.isEmpty {
            toolTip = nil
        } else {
            toolTip = hoverHint
        }
    }

    private func scheduleHoverHintIfNeeded() {
        guard !hoverHint.isEmpty else { return }
        if hoverHintDelay <= 0 {
            presentHoverHintIfNeeded()
            return
        }
        guard hoverHintTimer == nil, !isHoverHintVisible else { return }
        let timer = Timer(timeInterval: hoverHintDelay, repeats: false) { [weak self] _ in
            self?.hoverHintTimer = nil
            self?.isHoverHintScheduled = false
            self?.presentHoverHintIfNeeded()
        }
        hoverHintTimer = timer
        isHoverHintScheduled = true
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelPendingHoverHint() {
        hoverHintTimer?.invalidate()
        hoverHintTimer = nil
        isHoverHintScheduled = false
    }

    func firePendingHoverHintForTesting() {
        hoverHintTimer?.fire()
        cancelPendingHoverHint()
    }

    private func presentHoverHintIfNeeded() {
        cancelPendingHoverHint()
        guard interactionMode == .menuHosted,
              isHovered,
              !hoverHint.isEmpty,
              window != nil,
              hintPopover == nil else {
            return
        }
        let popover = DashboardTextTooltip.makePopover()
        let controller: NSViewController
        if let content = forecastTooltipContent {
            controller = DashboardForecastTooltipViewController(content: content)
        } else {
            controller = DashboardTextTooltipViewController(text: hoverHint)
        }
        controller.loadViewIfNeeded()
        popover.contentViewController = controller
        popover.contentSize = controller.view.frame.size
        hintPopover = popover
        toolTip = nil
        let anchor = visibleTextHitRect.isEmpty ? bounds : visibleTextHitRect
        popover.show(relativeTo: anchor, of: self, preferredEdge: .maxY)
        guard popover.isShown else {
            hintPopover = nil
            if hoverHintDelay <= 0 {
                toolTip = hoverHint
            }
            isHoverHintVisible = false
            return
        }
        isHoverHintVisible = true
    }

    private func dismissHoverHint() {
        hintPopover?.close()
        hintPopover = nil
        isHoverHintVisible = false
        refreshNativeTooltip()
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
        guard interactionMode == .normal else { return }
        refreshTrackingArea()
        synchronizeHoverStateWithMouseLocation()
    }

    private func refreshTrackingArea() {
        guard interactionMode == .normal else { return }
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
        // The attributed string is drawn independently of the cell. Use the
        // view's current alignment so right-aligned menu amounts do not fall
        // back to the cell's default leading alignment.
        paragraphStyle.alignment = alignment
        paragraphStyle.lineBreakMode = cell?.lineBreakMode ?? lineBreakMode
        attributedString.addAttribute(
            .paragraphStyle,
            value: paragraphStyle,
            range: NSRange(location: 0, length: attributedString.length)
        )
        return attributedString
    }

    private func applyStyle(text: String, underlined: Bool) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = alignment
        paragraphStyle.lineBreakMode = cell?.lineBreakMode ?? lineBreakMode
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 12),
            .foregroundColor: underlined ? NSColor.linkColor : restingTextColor,
            .paragraphStyle: paragraphStyle
        ]
        if underlined { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        isApplyingStyle = true
        attributedStringValue = NSAttributedString(string: text, attributes: attributes)
        isApplyingStyle = false
        updateVisibleTextHitRect()
    }
}

/// A local event bridge for links and quota markers in an `NSMenuItem.view`.
/// The card forwards movement; each element retains its precise hover boundary.
final class MenuHoverLinkHostView: NSView {
    let sectionFocus = SectionFocusController()
    private var replacingFocusSections = false
    private var replacementPace: (OverviewNumericIdentity, OfficialQuotaWindow)?
    var focusPointerLocationForTesting: NSPoint?
    var overviewLayout: OpenCodexCardFrames?
    var providerIdentity = ""
    var forecastContentKey: StatusItemController.ForecastContentKey?
    var bankedResetCardIDs: [String?] = []
    var quotaPaceAccount: OpenAIAccountPresentation?
    var quotaPaceClient: AssistantClient?
    private(set) var isMenuContentVisible = false
    private(set) var isMenuDismissing = false
    var isPaceMenuTracking: Bool { paceMenuTracking }
    var outgoingMenuWindow: NSWindow? { dismissalWindow }
    private(set) var dismissalTrace: MenuDismissalTrace?
    private var menuDismissalObserver: NSObjectProtocol?
    private weak var dismissalWindow: NSWindow?
    private var dismissalGeneration = 0
    private var dismissalPaceViews: [QuotaProgressPaceView] = []
    var dismissalExperiment = PaceDismissalExperiment.current
    private var ticketBoundsObserver: NSObjectProtocol?

    deinit {
        if let menuDismissalObserver { NotificationCenter.default.removeObserver(menuDismissalObserver) }
        if let ticketBoundsObserver { NotificationCenter.default.removeObserver(ticketBoundsObserver) }
        if let ticketScrollMonitor { NSEvent.removeMonitor(ticketScrollMonitor) }
        if let resignActiveObserver { NotificationCenter.default.removeObserver(resignActiveObserver) }
    }

    func setMenuContentVisible(_ visible: Bool) {
        let wasActive = isMenuContentVisible || paceMenuTracking
        isMenuContentVisible = visible
        if visible {
            finishMenuDismissal(beforeOpening: true)
            setPaceMenuTracking(true)
        } else if wasActive || isMenuDismissing {
            beginMenuDismissal()
        } else {
            setPaceMenuTracking(false)
        }
        refreshMarqueeVisibility()
    }

    func setDismissalTrace(_ trace: MenuDismissalTrace?) {
        dismissalTrace = trace
        trace?.host = self
        sectionFocus.dismissalTrace = trace
        for section in subviews.compactMap({ $0 as? OpenCodexOverviewSectionView }) { section.dismissalTrace = trace }
        paceViews.forEach { $0.dismissalTrace = trace }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        guard let trace = dismissalTrace, let section = subview as? OpenCodexOverviewSectionView else { return }
        section.dismissalTrace = trace
        paceViews.forEach { $0.dismissalTrace = trace }
        trace.record("section.add", view: section, details: "section=\(section.sectionID.identifier)")
    }

    private func beginMenuDismissal() {
        guard !isMenuDismissing else { return }
        dismissalTrace?.record("dismissal.begin", view: self)
        guard let departingWindow = window, departingWindow.isVisible else {
            setPaceMenuTracking(false)
            return
        }
        isMenuDismissing = true
        isMenuContentVisible = false
        dismissalWindow = departingWindow
        dismissalGeneration += 1
        let token = dismissalGeneration
        let trace = dismissalTrace
        paceMenuTracking = false
        dismissalPaceViews = paceViews
        sectionFocus.suspendForMenuDismissal()
        dismissalPaceViews.forEach { $0.stopMenuInteractionPreservingVisuals() }
        removeTrackingAreaReference()
        removeTicketScrollMonitor()
        link?.clearHoverState()
        // Occlusion is only an auxiliary cleanup signal, not animation completion.
        // Detach and next-open cleanup also work without this notification.
        menuDismissalObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: departingWindow, queue: .main
        ) { [weak self, weak departingWindow] _ in
            trace?.record("window.occlusion", view: self)
            guard let self, self.isMenuDismissing, self.dismissalGeneration == token, let departingWindow,
                  self.dismissalWindow === departingWindow else { return }
            self.finishMenuDismissal()
        }
    }

    func finishMenuDismissal(beforeOpening: Bool = false) {
        guard isMenuDismissing else { return }
        guard beforeOpening || dismissalWindow?.isVisible != true else {
            dismissalTrace?.record("dismissal.cleanup.deferred", view: self,
                details: "departing_window=\(MenuDismissalTrace.id(dismissalWindow)); departing_visible=true")
            return
        }
        dismissalTrace?.record("dismissal.cleanup", view: self,
            details: "before_opening=\(beforeOpening); departing_window=\(MenuDismissalTrace.id(dismissalWindow)); departing_visible=\(dismissalWindow?.isVisible ?? false)")
        dismissalGeneration += 1
        if let menuDismissalObserver {
            NotificationCenter.default.removeObserver(menuDismissalObserver)
            self.menuDismissalObserver = nil
        }
        isMenuDismissing = false
        dismissalWindow = nil
        sectionFocus.finishMenuDismissal()
        var visited = Set<ObjectIdentifier>()
        for pace in dismissalPaceViews + paceViews where visited.insert(ObjectIdentifier(pace)).inserted {
            pace.finishMenuInteractionAfterDismissal()
        }
        dismissalPaceViews.removeAll()
    }

    func prepareForMenuWindowDetachment() -> Bool {
        if !isMenuDismissing, isMenuContentVisible || paceMenuTracking, window?.isVisible == true {
            beginMenuDismissal()
        }
        return isMenuDismissing
    }

    func refreshMarqueeVisibility() {
        func visit(_ node: NSView) {
            (node as? AccountMarqueeView)?.refreshScrollVisibility()
            node.subviews.forEach(visit)
        }
        visit(self)
    }

    private weak var link: HoverLinkTextField?
    private weak var ticketScrollView: BankedResetTicketScrollView?
    private var trackingAreaReference: NSTrackingArea?
    private var ticketScrollMonitor: Any?
    private var resignActiveObserver: NSObjectProtocol?
    private var paceMenuTracking = false
    private var monitoredWindow: ObjectIdentifier?
    private var monitoredViews = Set<ObjectIdentifier>()
    private(set) var monitorRegistrationCountForTesting = 0

    var paceViews: [QuotaProgressPaceView] {
        func collect(_ view: NSView) -> [QuotaProgressPaceView] {
            view.subviews.flatMap { child in
                if let pace = child as? QuotaProgressPaceView { return [pace] }
                return collect(child)
            }
        }
        return collect(self)
    }

    func setPaceMenuTracking(_ active: Bool) {
        guard !isMenuDismissing else { return }
        if paceMenuTracking != active {
            paceMenuTracking = active
            if !active { clearPaceHover() }
            refreshTrackingArea()
        }
        reconcilePaceMenuTracking()
    }

    /// Data refresh only reconciles replaced children. A matching monitor
    /// keeps its identity; menu open/close owns activation and teardown.
    func reconcilePaceMenuTracking() {
        guard !isMenuDismissing else { return }
        reconcileSectionFocus()
        paceViews.forEach { $0.setMenuTracking(paceMenuTracking) }
        installTicketScrollMonitor()
    }

    func clearPaceHover() {
        guard !isMenuDismissing else { return }
        sectionFocus.reset()
        paceViews.forEach { $0.clearInteraction() }
    }

    func beginFocusSectionReplacement() {
        let id = sectionFocus.hoveredID ?? sectionFocus.focusedID
        let section = id.flatMap { sectionFocus.sections[$0] }
        replacementPace = paceViews.first { pace in section.map { pace.isDescendant(of: $0) } ?? false }
            .map { ($0.numericIdentity, $0.quotaWindow) }
        replacingFocusSections = true
    }
    func finishFocusSectionReplacement() {
        replacingFocusSections = false
        if let (identity, previous) = replacementPace {
            let matching = paceViews.contains {
                $0.numericIdentity == identity && $0.quotaWindow.kind == previous.kind
                    && $0.quotaWindow.durationSeconds == previous.durationSeconds
                    && $0.quotaWindow.resetAt == previous.resetAt && $0.pace != nil
            }
            if !matching { sectionFocus.reset() }
        }
        replacementPace = nil
        reconcilePaceMenuTracking()
        if let window, paceMenuTracking {
            let point = focusPointerLocationForTesting ?? convert(window.mouseLocationOutsideOfEventStream, from: nil)
            forwardHover(atHostPoint: point)
            let valid = paceViews.contains { $0.pace != nil && $0.isHovered }
            if !valid { sectionFocus.reset() }
        }
    }

    func reconcileSectionFocus() {
        guard !isMenuDismissing, !replacingFocusSections else { return }
        sectionFocus.isActive = paceMenuTracking
        sectionFocus.experiment = dismissalExperiment
        paceViews.forEach { $0.dismissalExperiment = dismissalExperiment }
        let sections = Dictionary(uniqueKeysWithValues: subviews.compactMap {
            ($0 as? OpenCodexOverviewSectionView).map { ($0.sectionID, $0) }
        })
        sectionFocus.update(sections: sections)
        for (id, section) in sections {
            let views = paceViews.filter { $0.isDescendant(of: section) }
            for pace in views {
                pace.onHoverChanged = { [weak self, weak section, weak pace] hovered in
                    guard let self, !self.replacingFocusSections, let section, let pace,
                          self.sectionFocus.sections[id] === section, section.superview === self,
                          pace.isDescendant(of: section) else { return }
                    self.sectionFocus.hoverChanged(id, isHovering: hovered, pace: pace)
                }
                if pace.isHovered, pace.pace != nil { sectionFocus.hoverChanged(id, isHovering: true, pace: pace) }
            }
        }
    }

    func focusSectionWillBeRemoved(_ section: OpenCodexOverviewSectionView) {
        guard !isMenuDismissing, !replacingFocusSections, sectionFocus.sections[section.sectionID] === section else { return }
        if sectionFocus.focusedID == section.sectionID || sectionFocus.hoveredID == section.sectionID { sectionFocus.reset() }
    }

    func invalidateSectionFocus(for pace: QuotaProgressPaceView) {
        guard !isMenuDismissing, !replacingFocusSections else { return }
        sectionFocus.invalidateInteraction(for: pace)
        let affected = [sectionFocus.focusedID, sectionFocus.hoveredID].compactMap { $0 }.contains { id in
            sectionFocus.sections[id].map { pace.isDescendant(of: $0) } ?? false
        }
        if affected { sectionFocus.reset() }
    }

    var trackedLink: HoverLinkTextField? { link }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func track(_ link: HoverLinkTextField) {
        self.link = link
        link.setInteractionMode(.menuHosted)
        refreshTrackingArea()
        synchronizeHoverState()
    }

    func trackTicketScroll(_ scrollView: BankedResetTicketScrollView) {
        ticketScrollView = scrollView
        if let ticketBoundsObserver { NotificationCenter.default.removeObserver(ticketBoundsObserver) }
        scrollView.contentView.postsBoundsChangedNotifications = true
        ticketBoundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak self] _ in self?.refreshMarqueeVisibility() }
        installTicketScrollMonitor()
    }

    override func scrollWheel(with event: NSEvent) {
        clearPaceHover()
        if handleTicketScroll(event) {
            return
        }
        super.scrollWheel(with: event)
    }

    override func updateTrackingAreas() {
        removeTrackingAreaReference()
        super.updateTrackingAreas()
        installTrackingArea()
        synchronizeHoverState()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        dismissalTrace?.record("view.didMoveToWindow", view: self)
        if isMenuDismissing {
            finishMenuDismissal()
            return
        }
        refreshTrackingArea()
        synchronizeHoverState()
        installTicketScrollMonitor()
        refreshMarqueeVisibility()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        dismissalTrace?.record("view.willMoveToWindow", view: self,
            details: "next_window=\(MenuDismissalTrace.id(newWindow))")
        if newWindow == nil {
            _ = prepareForMenuWindowDetachment()
            tearDownWindowTracking() // A suspended host stops input without restoring visuals.
            finishMenuDismissal() // Only finishes if the retained old window is already hidden.
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
        paceViews.forEach { $0.updateHover(at: NSPoint(x: -100, y: -100)) }
    }

    override func removeFromSuperview() {
        dismissalTrace?.record("view.removeFromSuperview", view: self)
        _ = prepareForMenuWindowDetachment()
        setMenuContentVisible(false)
        tearDownWindowTracking()
        super.removeFromSuperview()
        finishMenuDismissal()
    }

    func forwardHover(atHostPoint point: NSPoint) {
        link?.updateHover(atHostPoint: point, in: self)
        let next = paceViews.first { $0.isMenuTracking && $0.markerHitRect.contains($0.convert(point, from: self)) }
        // Deliver the new target first so a late leave cannot cancel its timeline.
        if let next { next.updateHover(at: next.convert(point, from: self)) }
        for paceView in paceViews where paceView !== next {
            paceView.updateHover(at: paceView.convert(point, from: self))
        }
    }

    private func installTrackingArea() {
        guard !isMenuDismissing else { return }
        guard (link != nil || !paceViews.isEmpty), !bounds.isEmpty else { return }
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
            clearPaceHover()
            return
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        forwardHover(atHostPoint: point)
    }

    private func tearDownWindowTracking() {
        removeTrackingAreaReference()
        removeTicketScrollMonitor()
        clearPaceHover()
        link?.clearHoverState()
    }

    func containsTicketScrollPoint(_ pointInWindow: NSPoint) -> Bool {
        guard let ticketScrollView else { return false }
        return ticketScrollView.bounds.contains(ticketScrollView.convert(pointInWindow, from: nil))
    }

    private func handleTicketScroll(_ event: NSEvent) -> Bool {
        guard let ticketScrollView, containsTicketScrollPoint(event.locationInWindow) else { return false }
        ticketScrollView.scrollWheel(with: event)
        return true
    }

    private func installTicketScrollMonitor() {
        guard !isMenuDismissing else { return }
        let views = Set((paceMenuTracking ? paceViews.map(ObjectIdentifier.init) : [])
            + (ticketScrollView.map { [ObjectIdentifier($0)] } ?? []))
        let targetWindow = window.map(ObjectIdentifier.init)
        if ticketScrollMonitor != nil && monitoredWindow == targetWindow && monitoredViews == views { return }
        removeTicketScrollMonitor()
        guard !views.isEmpty, let targetWindow else { return }
        monitoredWindow = targetWindow
        monitoredViews = views
        monitorRegistrationCountForTesting += 1
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.dismissalTrace?.record("application.resignActive", view: self)
            if self.isMenuContentVisible { self.setMenuContentVisible(false) }
            else { self.clearPaceHover() }
        }
        ticketScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            self.dismissalTrace?.record("input.cleanup", view: self, details: "type=\(event.type.rawValue)")
            self.clearPaceHover()
            if event.type == .scrollWheel, self.handleTicketScroll(event) { return nil }
            return event
        }
    }

    private func removeTicketScrollMonitor() {
        monitoredWindow = nil
        monitoredViews.removeAll()
        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
            self.resignActiveObserver = nil
        }
        if let ticketScrollMonitor {
            NSEvent.removeMonitor(ticketScrollMonitor)
            self.ticketScrollMonitor = nil
        }
    }
}

enum DashboardSection: Int, CaseIterable {
    case general = 0
    case menuBar = 1
    case menu = 2
    case advanced = 3
    case about = 4
    /// Notifications intentionally uses a non-contiguous raw value. Older
    /// Dashboard restoration data and source-list probes treat 0...4 as the
    /// original settings contract; the new independent page must not rewrite
    /// those persisted identities.
    case notifications = 10

    /// Keep the long-standing settings search/order contract intact. Consumers
    /// that need the complete navigation order can use `navigationCases`.
    static let allCases: [DashboardSection] = [.general, .menuBar, .menu, .advanced, .about]
    static let navigationCases: [DashboardSection] = [.general, .notifications, .menuBar, .menu, .advanced, .about]

    var title: String {
        switch self {
        case .general: return tr(.keyDashboardComponentsGeneral)
        case .menuBar: return tr(.keyDashboardComponentsMenuBar)
        case .menu: return tr(.keyDashboardComponentsMenu)
        case .advanced: return tr(.keyDashboardComponentsAdvanced)
        case .about: return tr(.keyDashboardComponentsAbout)
        case .notifications: return tr("dashboard.components.notifications")
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape.fill"
        case .menuBar: return "menubar.rectangle"
        case .menu: return "filemenu.and.selection"
        case .advanced: return "slider.horizontal.3"
        case .about: return "info.circle.fill"
        case .notifications: return "bell.badge.fill"
        }
    }

    var chipColor: NSColor {
        switch self {
        case .general: return .systemGray
        case .menuBar: return .systemBlue
        case .menu: return .systemTeal
        case .advanced: return .systemPurple
        case .about: return .systemGreen
        case .notifications: return .systemOrange
        }
    }
}

/// Wrapping subtitle that styles one interior phrase as a link. Hover and
/// click apply only to that range; the rest stays secondary label color.
final class InlineRangeLinkTextField: NSTextField {
    var onActivate: (() -> Void)?
    private(set) var linkRange = NSRange(location: NSNotFound, length: 0)
    private(set) var linkHitRect = NSRect.zero
    private(set) var linkHitRects: [NSRect] = []
    private var sourceText = ""
    private var linkPhrase: String?
    private var trackingAreaReferences: [NSTrackingArea] = []
    private var isHovered = false
    private var isApplyingStyle = false

    var hasLink: Bool {
        linkRange.location != NSNotFound && linkRange.length > 0
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = false
        usesSingleLineMode = false
        lineBreakMode = .byWordWrapping
        maximumNumberOfLines = 0
        cell?.wraps = true
        cell?.isScrollable = false
        font = .systemFont(ofSize: 12)
        textColor = .secondaryLabelColor
    }

    required init?(coder: NSCoder) { nil }

    override var stringValue: String {
        didSet {
            guard !isApplyingStyle else { return }
            sourceText = stringValue
            refreshLinkRange()
            applyStyle(underlined: isHovered)
            updateLinkHitRect()
        }
    }

    override var font: NSFont? {
        didSet {
            guard !isApplyingStyle else { return }
            applyStyle(underlined: isHovered)
            updateLinkHitRect()
        }
    }

    override var textColor: NSColor? {
        didSet {
            guard !isApplyingStyle else { return }
            applyStyle(underlined: isHovered)
        }
    }

    func setContent(
        _ text: String,
        linkPhrase: String?,
        onActivate: (() -> Void)?
    ) {
        self.onActivate = onActivate
        self.linkPhrase = linkPhrase
        sourceText = text
        refreshLinkRange()
        applyStyle(underlined: false)
        isHovered = false
        updateLinkHitRect()
    }

    override func layout() {
        super.layout()
        updateLinkHitRect()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshTrackingArea()
        synchronizeHoverStateWithMouseLocation()
    }

    override func updateTrackingAreas() {
        removeTrackingAreaReference()
        super.updateTrackingAreas()
        updateLinkHitRect()
        if trackingAreaReferences.isEmpty {
            installTrackingArea()
        }
        synchronizeHoverStateWithMouseLocation()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        updateLinkHitRect()
        for rect in linkHitRects where !rect.isEmpty {
            addCursorRect(rect, cursor: .pointingHand)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        setHovering(isPointInsideLink(for: event))
    }

    override func mouseExited(with event: NSEvent) {
        setHovering(false)
    }

    override func cursorUpdate(with event: NSEvent) {
        setHovering(isPointInsideLink(for: event))
    }

    override func mouseMoved(with event: NSEvent) {
        setHovering(isPointInsideLink(for: event))
    }

    override func mouseDown(with event: NSEvent) {
        guard isPointInsideLink(for: event) else { return }
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

    private func refreshLinkRange() {
        guard let phrase = linkPhrase, !phrase.isEmpty else {
            linkRange = NSRange(location: NSNotFound, length: 0)
            return
        }
        let range = (sourceText as NSString).range(of: phrase)
        linkRange = range.location == NSNotFound ? NSRange(location: NSNotFound, length: 0) : range
    }

    private func applyStyle(underlined: Bool) {
        let text = sourceText
        let attributed = NSMutableAttributedString(string: text)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = lineBreakMode
        let body: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ]
        if attributed.length > 0 {
            attributed.addAttributes(body, range: NSRange(location: 0, length: attributed.length))
        }
        if hasLink, NSMaxRange(linkRange) <= attributed.length {
            var linkAttributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.linkColor
            ]
            if underlined {
                linkAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            attributed.addAttributes(linkAttributes, range: linkRange)
        }
        isApplyingStyle = true
        attributedStringValue = attributed
        isApplyingStyle = false
    }

    private func installTrackingArea() {
        trackingAreaReferences = linkHitRects.filter { !$0.isEmpty }.map { rect in
            let area = NSTrackingArea(
                rect: rect,
                options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeInKeyWindow],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            return area
        }
    }

    private func removeTrackingAreaReference() {
        for area in trackingAreaReferences {
            removeTrackingArea(area)
        }
        trackingAreaReferences = []
    }

    private func setHovering(_ hovered: Bool) {
        guard isHovered != hovered else {
            if hovered {
                NSCursor.pointingHand.set()
            }
            return
        }
        isHovered = hovered
        applyStyle(underlined: hovered)
        if hovered {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
        window?.invalidateCursorRects(for: self)
    }

    private func synchronizeHoverStateWithMouseLocation() {
        guard let window else {
            if isHovered { setHovering(false) }
            return
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setHovering(isPointInsideLink(point))
    }

    private func tearDownInteraction() {
        removeTrackingAreaReference()
        if isHovered {
            isHovered = false
            applyStyle(underlined: false)
        }
        NSCursor.arrow.set()
    }

    private func isPointInsideLink(for event: NSEvent) -> Bool {
        let point: NSPoint
        if window != nil {
            point = convert(event.locationInWindow, from: nil)
        } else {
            point = event.locationInWindow
        }
        return isPointInsideLink(point)
    }

    private func isPointInsideLink(_ point: NSPoint) -> Bool {
        linkHitRects.contains { $0.contains(point) }
    }

    private func updateLinkHitRect() {
        let previousRects = linkHitRects
        let rects = calculateLinkHitRects()
        linkHitRects = rects
        linkHitRect = rects.first.map { first in
            rects.dropFirst().reduce(first) { $0.union($1) }
        } ?? .zero
        guard previousRects != rects else { return }
        window?.invalidateCursorRects(for: self)
        refreshTrackingArea()
        synchronizeHoverStateWithMouseLocation()
    }

    private func refreshTrackingArea() {
        guard !trackingAreaReferences.isEmpty || window != nil else { return }
        removeTrackingAreaReference()
        installTrackingArea()
    }

    private func calculateLinkHitRects() -> [NSRect] {
        guard hasLink,
              !bounds.isEmpty,
              let cell,
              attributedStringValue.length >= NSMaxRange(linkRange)
        else {
            return []
        }

        let titleRect = cell.titleRect(forBounds: bounds)
        guard !titleRect.isEmpty else { return [] }

        let layoutWidth: CGFloat
        if preferredMaxLayoutWidth > 1 {
            layoutWidth = min(preferredMaxLayoutWidth, max(1, titleRect.width))
        } else {
            layoutWidth = max(1, titleRect.width)
        }
        let textStorage = NSTextStorage(attributedString: attributedStringValue)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            size: NSSize(width: layoutWidth, height: .greatestFiniteMagnitude)
        )
        textContainer.lineFragmentPadding = 0
        textContainer.lineBreakMode = cell.lineBreakMode
        textContainer.maximumNumberOfLines = 0
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        var actualRange = NSRange(location: 0, length: 0)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: linkRange,
            actualCharacterRange: &actualRange
        )
        guard glyphRange.length > 0 else { return [] }

        var fragmentRects: [NSRect] = []
        layoutManager.enumerateEnclosingRects(
            forGlyphRange: glyphRange,
            withinSelectedGlyphRange: glyphRange,
            in: textContainer
        ) { rect, _ in
            guard !rect.isEmpty else { return }
            let hitRect = NSRect(
                x: titleRect.minX + rect.minX,
                y: titleRect.minY + rect.minY,
                width: rect.width,
                height: rect.height
            )
            .insetBy(dx: -2, dy: -2)
            .intersection(self.bounds)
            if !hitRect.isEmpty {
                fragmentRects.append(hitRect)
            }
        }
        return fragmentRects
    }
}
