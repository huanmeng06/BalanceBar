import AppKit

enum QuotaThresholdSliderMath {
    static let logicalTicks = Array(stride(from: 0, through: 100, by: 5))
    static func snapped(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return min(100, max(0, Int((value / 5).rounded()) * 5))
    }
    static func shouldEmitAlignmentHaptic(lastSnappedValue: Int?, newValue: Int) -> Bool {
        lastSnappedValue != newValue
    }
    static func crossedTicks(from oldValue: Int, to newValue: Int) -> [Int] {
        guard oldValue != newValue else { return [] }
        let low = min(oldValue, newValue), high = max(oldValue, newValue)
        return logicalTicks.filter { $0 > low && $0 <= high }
    }
    static func visibleTicks(width: CGFloat, thumbValues: [Int]) -> [Int] {
        let interval = width >= 420 ? 5 : (width >= 260 ? 10 : 20)
        return Array(Set(stride(from: 0, through: 100, by: interval)).union([0, 50, 100]).union(thumbValues)).sorted()
    }
}

private final class ThresholdGlassThumbView: NSView {
    let boundaryColor: QuotaProgressColor
    var onStep: ((Int) -> Void)?
    private let effectView: NSView
    let isGlassEffectBacked: Bool
    private(set) var isPressed = false

    init(color: QuotaProgressColor) {
        boundaryColor = color
        if let glass = makeDashboardGlassEffectView(contentView: NSView(), cornerRadius: 12) {
            effectView = glass
            isGlassEffectBacked = true
        } else {
            let effect = NSVisualEffectView(frame: .zero)
            effect.material = .popover
            effect.blendingMode = .withinWindow
            effect.state = .active
            effectView = effect
            isGlassEffectBacked = false
        }
        super.init(frame: .zero)
        effectView.autoresizingMask = [.width, .height]
        addSubview(effectView)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityMinValue(0)
        setAccessibilityMaxValue(100)
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        effectView.frame = bounds
        if isGlassEffectBacked {
            effectView.setValue(bounds.height / 2, forKey: "cornerRadius")
        } else {
            effectView.wantsLayer = true
            effectView.layer?.cornerRadius = bounds.height / 2
            effectView.layer?.masksToBounds = true
        }
    }

    func updateAccessibilityValue(_ value: Int) {
        let label: String
        switch boundaryColor {
        case .red: label = tr(.keyDashboardMenuPageColorRed)
        case .orange: label = tr(.keyDashboardMenuPageColorOrange)
        case .yellow: label = tr(.keyDashboardMenuPageColorYellow)
        case .green: label = tr(.keyDashboardMenuPageColorGreen)
        }
        setAccessibilityLabel(label)
        setAccessibilityValue(value)
        setAccessibilityValueDescription("\(value)%")
    }

    func setInteractionState(hovered: Bool, pressed: Bool) {
        isPressed = pressed
        if isGlassEffectBacked {
            effectView.setValue(pressed ? 1 : 0, forKey: "style") // NSGlassEffectViewStyleClear/Regular
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityPerformIncrement() -> Bool {
        onStep?(5)
        return true
    }
    override func accessibilityPerformDecrement() -> Bool {
        onStep?(-5)
        return true
    }
}

final class QuotaColorThresholdSlider: NSControl {
    struct DebugThumbState: Equatable {
        let color: QuotaProgressColor
        let minimumValue: Double
        let maximumValue: Double
        let value: Double
        let knobMidX: CGFloat
        let isGlassEffectBacked: Bool
        let isPressed: Bool
    }
    private var configurationStorage: QuotaProgressColorConfiguration
    private var thumbViews: [QuotaProgressColor: ThresholdGlassThumbView] = [:]
    private var activePopoverColor: QuotaProgressColor?
    private var trackingColor: QuotaProgressColor?
    private var focusedColor: QuotaProgressColor?
    private var dragOffsetX: CGFloat = 0
    private var lastSnappedValues: [QuotaProgressColor: Int] = [:]
    private let popover = DashboardTextTooltip.makePopover()
    private let popoverLabel = NSTextField(labelWithString: "")
    private var hoverWorkItem: DispatchWorkItem?
    private var trackingAreaReference: NSTrackingArea?
    var onChange: ((QuotaProgressColorConfiguration) -> Void)?
    var configuration: QuotaProgressColorConfiguration { get { configurationStorage } set { applyExternalConfiguration(newValue.normalized()) } }
    var thumbCount: Int { thumbViews.count }
    var thumbIdentitySet: Set<ObjectIdentifier> { Set(thumbViews.values.map { ObjectIdentifier($0) }) }
    var usesNSSliderThumbs: Bool { subviews.contains { $0 is NSSlider } }
    var debugThumbStates: [DebugThumbState] {
        layoutSubtreeIfNeeded()
        return QuotaProgressColor.allCases.compactMap { color in
            guard let thumb = thumbViews[color], let knob = knobRect(for: color), let value = configurationStorage.boundary(after: color) else { return nil }
            return DebugThumbState(color: color, minimumValue: 0, maximumValue: 100, value: Double(value), knobMidX: knob.midX, isGlassEffectBacked: thumb.isGlassEffectBacked, isPressed: thumb.isPressed)
        }
    }

    init(configuration: QuotaProgressColorConfiguration) {
        configurationStorage = configuration.normalized(); super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("quotaProgressThresholdSlider"); setAccessibilityRole(.group)
        let contentView = NSView(frame: .zero)
        DashboardTextTooltip.configure(popoverLabel, alignment: .center)
        popoverLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(popoverLabel)
        NSLayoutConstraint.activate([
            popoverLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 7),
            popoverLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -7),
            popoverLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            popoverLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5)
        ])
        let controller = NSViewController(); controller.view = contentView
        popover.contentViewController = controller; popover.behavior = .transient; popover.animates = false; reconcileThumbViews()
    }
    required init?(coder: NSCoder) { nil }
    deinit { hoverWorkItem?.cancel(); popover.close() }
    func teardown() {
        hoverWorkItem?.cancel()
        hoverWorkItem = nil
        trackingColor = nil
        dragOffsetX = 0
        updateThumbInteractionStates(hovered: nil, pressed: nil)
        dismissPopover()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
            self.trackingAreaReference = nil
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { teardown() }
    }
    override var intrinsicContentSize: NSSize { NSSize(width: 300, height: 34) }
    private var trackRect: NSRect { bounds.insetBy(dx: 9, dy: 12) }
    private var thumbSize: NSSize { NSSize(width: 24, height: 24) }
    private var activeBoundaries: [(QuotaProgressColor, Int)] { configurationStorage.enabledColorsInOrder.dropLast().compactMap { color in configurationStorage.boundary(after: color).map { (color, $0) } } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self); addTrackingArea(area); trackingAreaReference = area
    }
    override func layout() {
        super.layout()
        for (color, thumb) in thumbViews {
            let value = configurationStorage.boundary(after: color) ?? 0
            thumb.frame = thumbRect(for: value)
            thumb.updateAccessibilityValue(value)
        }
        if let activePopoverColor { updatePopoverAnchor(for: activePopoverColor) }
    }
    override func draw(_ dirtyRect: NSRect) {
        let track = trackRect, colors = configurationStorage.enabledColorsInOrder, points = [0] + activeBoundaries.map(\.1) + [100]
        for (index, color) in colors.enumerated() { let x0 = track.minX + track.width * CGFloat(points[index]) / 100; let x1 = track.minX + track.width * CGFloat(points[index + 1]) / 100; color.nsColor.setFill(); NSBezierPath(roundedRect: NSRect(x: x0, y: track.midY - 3, width: max(1, x1 - x0), height: 6), xRadius: 3, yRadius: 3).fill() }
        NSColor.tertiaryLabelColor.setStroke()
        for tick in QuotaThresholdSliderMath.visibleTicks(width: bounds.width, thumbValues: activeBoundaries.map(\.1)) { let x = track.minX + track.width * CGFloat(tick) / 100; let path = NSBezierPath(); path.move(to: NSPoint(x: x, y: track.minY - 3)); path.line(to: NSPoint(x: x, y: track.minY)); path.stroke() }
    }
    private func reconcileThumbViews() {
        let wanted = Set(configurationStorage.enabledColorsInOrder.dropLast())
        for color in Array(thumbViews.keys) where !wanted.contains(color) {
            thumbViews[color]?.removeFromSuperview()
            thumbViews.removeValue(forKey: color)
            lastSnappedValues.removeValue(forKey: color)
        }
        for color in wanted where thumbViews[color] == nil {
            let thumb = ThresholdGlassThumbView(color: color)
            thumb.onStep = { [weak self] delta in self?.stepBoundary(after: color, by: delta) }
            thumbViews[color] = thumb
            lastSnappedValues[color] = configurationStorage.boundary(after: color)
            addSubview(thumb)
        }
        needsLayout = true; needsDisplay = true
    }
    private func applyExternalConfiguration(_ value: QuotaProgressColorConfiguration) {
        guard value != configurationStorage else { return }
        let oldColors = configurationStorage.enabledColors; configurationStorage = value
        if oldColors != value.enabledColors {
            trackingColor = nil
            dragOffsetX = 0
            if let focusedColor, !value.enabledColors.contains(focusedColor) { self.focusedColor = nil }
            updateThumbInteractionStates(hovered: nil, pressed: nil)
            dismissPopover()
            reconcileThumbViews()
        }
        for (color, thumb) in thumbViews {
            let boundary = value.boundary(after: color) ?? 0
            lastSnappedValues[color] = boundary
            thumb.updateAccessibilityValue(boundary)
        }
        needsDisplay = true; needsLayout = true
    }
    private func applyTrackedBoundaryChange(color: QuotaProgressColor, value: Double) {
        let old = configurationStorage.boundary(after: color) ?? 0
        let updated = configurationStorage.settingBoundary(after: color, to: QuotaThresholdSliderMath.snapped(value))
        guard let actual = updated.boundary(after: color) else { return }
        thumbViews[color]?.frame = thumbRect(for: actual)
        thumbViews[color]?.updateAccessibilityValue(actual)
        if trackingColor == color { updatePopoverAnchor(for: color, value: actual) }
        guard actual != old else { return }
        if QuotaThresholdSliderMath.shouldEmitAlignmentHaptic(lastSnappedValue: lastSnappedValues[color], newValue: actual) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        lastSnappedValues[color] = actual
        configurationStorage = updated; onChange?(updated); sendAction(action, to: target); needsDisplay = true
    }
    private func beginTracking(color: QuotaProgressColor) {
        trackingColor = color
        hoverWorkItem?.cancel()
        activePopoverColor = color
        focusedColor = color
        updateThumbInteractionStates(hovered: color, pressed: color)
        presentPopover(for: color)
    }
    private func finishTracking(color: QuotaProgressColor, at point: NSPoint?) {
        guard trackingColor == color else { return }
        defer { trackingColor = nil }
        guard activePopoverColor == color else { dismissPopover(); return }
        if let knob = knobRect(for: color), let point, knob.insetBy(dx: -5, dy: -5).contains(point) {
            updateThumbInteractionStates(hovered: color, pressed: nil)
            updatePopoverAnchor(for: color)
        } else {
            updateThumbInteractionStates(hovered: nil, pressed: nil)
            dismissPopover()
        }
    }
    override func mouseMoved(with event: NSEvent) {
        if let trackingColor {
            updatePopoverAnchor(for: trackingColor)
            return
        }
        hoverWorkItem?.cancel(); let point = convert(event.locationInWindow, from: nil); let color = hitThumb(at: point); activePopoverColor = color
        updateThumbInteractionStates(hovered: color, pressed: nil)
        if let color { let item = DispatchWorkItem { [weak self] in self?.presentPopover(for: color) }; hoverWorkItem = item; DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item) } else { dismissPopover() }
    }
    override func mouseExited(with event: NSEvent) {
        guard trackingColor == nil else { return }
        hoverWorkItem?.cancel(); updateThumbInteractionStates(hovered: nil, pressed: nil); dismissPopover()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let color = hitThumb(at: point), let rect = knobRect(for: color) {
            dragOffsetX = point.x - rect.midX
            window?.makeFirstResponder(self)
            beginTracking(color: color)
            return
        }
        guard let color = nearestBoundary(to: point.x) else { return }
        let track = trackRect
        guard track.width > 0 else { return }
        let rawValue = Double((point.x - track.minX) / track.width * 100)
        focusedColor = color
        applyTrackedBoundaryChange(color: color, value: rawValue)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let color = trackingColor else { return }
        let point = convert(event.locationInWindow, from: nil)
        let track = trackRect
        guard track.width > 0 else { return }
        let rawValue = Double((point.x - dragOffsetX - track.minX) / track.width * 100)
        applyTrackedBoundaryChange(color: color, value: rawValue)
    }
    override func mouseUp(with event: NSEvent) {
        guard let color = trackingColor else { return }
        finishTracking(color: color, at: convert(event.locationInWindow, from: nil))
        dragOffsetX = 0
    }
    override func keyDown(with event: NSEvent) {
        guard let chars = event.charactersIgnoringModifiers,
              ["\u{F702}", "\u{F703}", "\u{F700}", "\u{F701}"].contains(chars),
              let color = focusedColor,
              thumbViews[color] != nil else {
            super.keyDown(with: event)
            return
        }
        stepBoundary(after: color, by: (chars == "\u{F702}" || chars == "\u{F700}") ? -5 : 5)
    }
    func applyRawThumbValueForTesting(_ value: Double, after color: QuotaProgressColor) {
        applyTrackedBoundaryChange(color: color, value: value)
    }
    private func stepBoundary(after color: QuotaProgressColor, by delta: Int) {
        guard let value = configurationStorage.boundary(after: color) else { return }
        applyTrackedBoundaryChange(color: color, value: Double(value + delta))
    }
    private func thumbRect(for value: Int) -> NSRect {
        let track = trackRect
        let centerX = track.minX + track.width * CGFloat(value) / 100
        return NSRect(x: centerX - thumbSize.width / 2, y: track.midY - thumbSize.height / 2, width: thumbSize.width, height: thumbSize.height)
    }
    private func knobRect(for color: QuotaProgressColor) -> NSRect? { thumbViews[color]?.frame }
    private func hitThumb(at point: NSPoint) -> QuotaProgressColor? {
        activeBoundaries.compactMap { color, _ -> (QuotaProgressColor, CGFloat)? in
            guard let rect = knobRect(for: color), rect.insetBy(dx: -4, dy: -4).contains(point) else { return nil }
            return (color, abs(rect.midX - point.x))
        }.min(by: { $0.1 < $1.1 })?.0
    }
    private func nearestBoundary(to x: CGFloat) -> QuotaProgressColor? {
        activeBoundaries.min { lhs, rhs in
            abs((knobRect(for: lhs.0)?.midX ?? 0) - x) < abs((knobRect(for: rhs.0)?.midX ?? 0) - x)
        }?.0
    }
    private func updateThumbInteractionStates(hovered: QuotaProgressColor?, pressed: QuotaProgressColor?) {
        for (color, thumb) in thumbViews { thumb.setInteractionState(hovered: hovered == color, pressed: pressed == color) }
    }
    private func presentPopover(for color: QuotaProgressColor) { activePopoverColor = color; updatePopoverAnchor(for: color); if !popover.isShown, let rect = knobRect(for: color) { popover.show(relativeTo: rect, of: self, preferredEdge: .maxY) } }
    private func updatePopoverAnchor(for color: QuotaProgressColor, value: Int? = nil) {
        guard let rect = knobRect(for: color) else { dismissPopover(); return }
        popoverLabel.stringValue = "\(value ?? configurationStorage.boundary(after: color) ?? 0)%"
        let labelSize = popoverLabel.fittingSize
        popover.contentSize = NSSize(width: ceil(labelSize.width) + 14, height: ceil(labelSize.height) + 10)
        if popover.isShown { popover.positioningRect = rect }
    }
    private func dismissPopover() { activePopoverColor = nil; popover.close() }
}
