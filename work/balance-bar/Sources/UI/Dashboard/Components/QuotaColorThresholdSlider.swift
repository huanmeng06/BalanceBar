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

/// A real AppKit slider. Its stock cell owns knob drawing, press state, and tracking.
private final class ThresholdThumbSlider: NSSlider {
    let boundaryColor: QuotaProgressColor
    var onTrackingBegan: (() -> Void)?
    var onTrackingChanged: ((Double) -> Void)?
    var onTrackingEnded: (() -> Void)?

    init(color: QuotaProgressColor) {
        boundaryColor = color
        super.init(frame: .zero)
        minValue = 0
        maxValue = 100
        doubleValue = 0
        sliderType = .linear
        controlSize = .regular
        isContinuous = true
        numberOfTickMarks = 0
        target = self
        action = #selector(valueChanged(_:))
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityMinValue(0)
        setAccessibilityMaxValue(100)
    }

    required init?(coder: NSCoder) { nil }

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

    @objc private func valueChanged(_ sender: NSSlider) {
        onTrackingChanged?(sender.doubleValue)
    }

    override func mouseDown(with event: NSEvent) {
        onTrackingBegan?()
        super.mouseDown(with: event)
        onTrackingEnded?()
    }
}

final class QuotaColorThresholdSlider: NSControl {
    struct DebugThumbState: Equatable {
        let color: QuotaProgressColor
        let minimumValue: Double
        let maximumValue: Double
        let value: Double
        let knobMidX: CGFloat
        let knobMidY: CGFloat
    }

    private var configurationStorage: QuotaProgressColorConfiguration
    private var thumbSliders: [QuotaProgressColor: ThresholdThumbSlider] = [:]
    private var activePopoverColor: QuotaProgressColor?
    private var trackingColor: QuotaProgressColor?
    private var focusedColor: QuotaProgressColor?
    private var lastSnappedValues: [QuotaProgressColor: Int] = [:]
    private let popover = DashboardTextTooltip.makePopover()
    private let popoverLabel = NSTextField(labelWithString: "")
    private var hoverWorkItem: DispatchWorkItem?
    private var trackingAreaReference: NSTrackingArea?

    var onChange: ((QuotaProgressColorConfiguration) -> Void)?
    var configuration: QuotaProgressColorConfiguration {
        get { configurationStorage }
        set { applyExternalConfiguration(newValue.normalized()) }
    }
    var thumbCount: Int { thumbSliders.count }
    var thumbIdentitySet: Set<ObjectIdentifier> { Set(thumbSliders.values.map { ObjectIdentifier($0) }) }
    var nativeThumbSliders: [NSSlider] {
        QuotaProgressColor.allCases.compactMap { thumbSliders[$0] }
    }
    var usesNSSliderThumbs: Bool { nativeThumbSliders.count == thumbSliders.count }
    var debugThumbStates: [DebugThumbState] {
        layoutSubtreeIfNeeded()
        return QuotaProgressColor.allCases.compactMap { color in
            guard let slider = thumbSliders[color],
                  let knob = knobRect(for: color),
                  configurationStorage.boundary(after: color) != nil else { return nil }
            return DebugThumbState(
                color: color,
                minimumValue: slider.minValue,
                maximumValue: slider.maxValue,
                value: slider.doubleValue,
                knobMidX: knob.midX,
                knobMidY: knob.midY
            )
        }
    }

    init(configuration: QuotaProgressColorConfiguration) {
        configurationStorage = configuration.normalized()
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("quotaProgressThresholdSlider")
        setAccessibilityRole(.group)

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
        let controller = NSViewController()
        controller.view = contentView
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = false
        reconcileThumbSliders()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        hoverWorkItem?.cancel()
        popover.close()
    }

    func teardown() {
        hoverWorkItem?.cancel()
        hoverWorkItem = nil
        trackingColor = nil
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
    private var sliderFrame: NSRect { NSRect(x: trackRect.minX - 8, y: trackRect.midY - 14, width: trackRect.width + 16, height: 28) }
    private var activeBoundaries: [(QuotaProgressColor, Int)] {
        configurationStorage.enabledColorsInOrder.dropLast().compactMap { color in
            configurationStorage.boundary(after: color).map { (color, $0) }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func layout() {
        super.layout()
        for (color, slider) in thumbSliders {
            let value = configurationStorage.boundary(after: color) ?? 0
            slider.frame = sliderFrame
            slider.doubleValue = Double(value)
            slider.updateAccessibilityValue(value)
        }
        if let activePopoverColor { updatePopoverAnchor(for: activePopoverColor) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = trackRect
        let colors = configurationStorage.enabledColorsInOrder
        let points = [0] + activeBoundaries.map(\.1) + [100]
        for (index, color) in colors.enumerated() {
            let x0 = track.minX + track.width * CGFloat(points[index]) / 100
            let x1 = track.minX + track.width * CGFloat(points[index + 1]) / 100
            color.nsColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: x0, y: track.midY - 3, width: max(1, x1 - x0), height: 6), xRadius: 3, yRadius: 3).fill()
        }
        NSColor.tertiaryLabelColor.setStroke()
        for tick in QuotaThresholdSliderMath.visibleTicks(width: bounds.width, thumbValues: activeBoundaries.map(\.1)) {
            let x = track.minX + track.width * CGFloat(tick) / 100
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: track.minY - 3))
            path.line(to: NSPoint(x: x, y: track.minY))
            path.stroke()
        }
    }

    private func reconcileThumbSliders() {
        let wanted = Set(configurationStorage.enabledColorsInOrder.dropLast())
        for color in Array(thumbSliders.keys) where !wanted.contains(color) {
            thumbSliders[color]?.removeFromSuperview()
            thumbSliders.removeValue(forKey: color)
            lastSnappedValues.removeValue(forKey: color)
        }
        for color in wanted where thumbSliders[color] == nil {
            let slider = ThresholdThumbSlider(color: color)
            slider.onTrackingBegan = { [weak self] in self?.beginTracking(color: color) }
            slider.onTrackingChanged = { [weak self] value in self?.applyTrackedBoundaryChange(color: color, value: value) }
            slider.onTrackingEnded = { [weak self] in self?.finishTracking(color: color) }
            thumbSliders[color] = slider
            lastSnappedValues[color] = configurationStorage.boundary(after: color)
            addSubview(slider)
        }
        needsLayout = true
        needsDisplay = true
    }

    private func applyExternalConfiguration(_ value: QuotaProgressColorConfiguration) {
        guard value != configurationStorage else { return }
        let oldColors = configurationStorage.enabledColors
        configurationStorage = value
        if oldColors != value.enabledColors {
            trackingColor = nil
            if let focusedColor, !value.enabledColors.contains(focusedColor) { self.focusedColor = nil }
            dismissPopover()
            reconcileThumbSliders()
        }
        for (color, slider) in thumbSliders {
            let boundary = value.boundary(after: color) ?? 0
            lastSnappedValues[color] = boundary
            slider.doubleValue = Double(boundary)
            slider.updateAccessibilityValue(boundary)
        }
        needsDisplay = true
        needsLayout = true
    }

    private func applyTrackedBoundaryChange(color: QuotaProgressColor, value: Double) {
        let old = configurationStorage.boundary(after: color) ?? 0
        let updated = configurationStorage.settingBoundary(after: color, to: QuotaThresholdSliderMath.snapped(value))
        guard let actual = updated.boundary(after: color) else { return }
        let slider = thumbSliders[color]
        slider?.doubleValue = Double(actual)
        slider?.updateAccessibilityValue(actual)
        if trackingColor == color { updatePopoverAnchor(for: color, value: actual) }
        guard actual != old else { return }
        if QuotaThresholdSliderMath.shouldEmitAlignmentHaptic(lastSnappedValue: lastSnappedValues[color], newValue: actual) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        lastSnappedValues[color] = actual
        configurationStorage = updated
        onChange?(updated)
        sendAction(action, to: target)
        needsDisplay = true
    }

    private func beginTracking(color: QuotaProgressColor) {
        trackingColor = color
        hoverWorkItem?.cancel()
        activePopoverColor = color
        focusedColor = color
        window?.makeFirstResponder(thumbSliders[color])
        presentPopover(for: color)
    }

    private func finishTracking(color: QuotaProgressColor) {
        guard trackingColor == color else { return }
        defer { trackingColor = nil }
        guard activePopoverColor == color else { dismissPopover(); return }
        if let point = currentMousePoint(), let knob = knobRect(for: color), knob.insetBy(dx: -5, dy: -5).contains(point) {
            updatePopoverAnchor(for: color)
        } else {
            dismissPopover()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        if let trackingColor {
            updatePopoverAnchor(for: trackingColor)
            return
        }
        hoverWorkItem?.cancel()
        let point = convert(event.locationInWindow, from: nil)
        let color = hitThumb(at: point)
        activePopoverColor = color
        if let color {
            let item = DispatchWorkItem { [weak self] in self?.presentPopover(for: color) }
            hoverWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
        } else {
            dismissPopover()
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard trackingColor == nil else { return }
        hoverWorkItem?.cancel()
        dismissPopover()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Knobs route to the child stock sliders. Empty track space remains a parent jump target.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        if let color = hitThumb(at: point), let slider = thumbSliders[color] { return slider }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let color = nearestBoundary(to: point.x) else { return }
        let track = trackRect
        guard track.width > 0 else { return }
        focusedColor = color
        let rawValue = Double((point.x - track.minX) / track.width * 100)
        applyTrackedBoundaryChange(color: color, value: rawValue)
    }

    func applyRawThumbValueForTesting(_ value: Double, after color: QuotaProgressColor) {
        applyTrackedBoundaryChange(color: color, value: value)
    }

    private func knobRect(for color: QuotaProgressColor) -> NSRect? {
        guard let slider = thumbSliders[color], let cell = slider.cell as? NSSliderCell else { return nil }
        return slider.convert(cell.knobRect(flipped: slider.isFlipped), to: self)
    }

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

    private func presentPopover(for color: QuotaProgressColor) {
        activePopoverColor = color
        updatePopoverAnchor(for: color)
        if !popover.isShown, let rect = knobRect(for: color) {
            popover.show(relativeTo: rect, of: self, preferredEdge: .maxY)
        }
    }

    private func updatePopoverAnchor(for color: QuotaProgressColor, value: Int? = nil) {
        guard let rect = knobRect(for: color) else { dismissPopover(); return }
        popoverLabel.stringValue = "\(value ?? configurationStorage.boundary(after: color) ?? 0)%"
        let labelSize = popoverLabel.fittingSize
        popover.contentSize = NSSize(width: ceil(labelSize.width) + 14, height: ceil(labelSize.height) + 10)
        if popover.isShown { popover.positioningRect = rect }
    }

    private func dismissPopover() {
        activePopoverColor = nil
        popover.close()
    }

    private func currentMousePoint() -> NSPoint? {
        guard let window else { return nil }
        return convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
    }
}
