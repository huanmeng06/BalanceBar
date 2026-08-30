import AppKit

enum QuotaThresholdSliderMath {
    static let logicalTicks = Array(stride(from: 0, through: 100, by: 5))
    static func snapped(_ value: Double) -> Int { min(100, max(0, Int((value / 5).rounded()) * 5)) }
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

private final class ThumbOnlySliderCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {}
}

private final class ThresholdThumbSlider: NSSlider {
    let boundaryColor: QuotaProgressColor
    var onTrackingChanged: ((Double) -> Void)?
    var onTrackingEnded: (() -> Void)?
    var lastSnappedValue: Int?
    init(color: QuotaProgressColor) {
        boundaryColor = color; super.init(frame: .zero)
        minValue = 0; maxValue = 100; isContinuous = true; numberOfTickMarks = 0; sliderType = .linear; controlSize = .regular
        cell = ThumbOnlySliderCell(); target = self; action = #selector(valueChanged(_:)); setAccessibilityRole(.slider)
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
        setAccessibilityValue("\(value)%")
    }
    @objc private func valueChanged(_ sender: NSSlider) { onTrackingChanged?(sender.doubleValue) }
    override func mouseUp(with event: NSEvent) { super.mouseUp(with: event); onTrackingEnded?() }
    override func keyDown(with event: NSEvent) {
        guard let chars = event.charactersIgnoringModifiers, ["\u{F702}", "\u{F703}", "\u{F700}", "\u{F701}"].contains(chars) else { super.keyDown(with: event); return }
        doubleValue += (chars == "\u{F702}" || chars == "\u{F700}") ? -5 : 5; sendAction(action, to: target)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let knob = (cell as? NSSliderCell)?.knobRect(flipped: isFlipped) ?? .zero
        return knob.insetBy(dx: -5, dy: -5).contains(point) ? super.hitTest(point) : nil
    }
}

final class QuotaColorThresholdSlider: NSControl {
    private var configurationStorage: QuotaProgressColorConfiguration
    private var thumbSliders: [QuotaProgressColor: ThresholdThumbSlider] = [:]
    private var activePopoverColor: QuotaProgressColor?
    private let popover = NSPopover()
    private let popoverLabel = NSTextField(labelWithString: "")
    private var hoverWorkItem: DispatchWorkItem?
    private var trackingAreaReference: NSTrackingArea?
    var onChange: ((QuotaProgressColorConfiguration) -> Void)?
    var configuration: QuotaProgressColorConfiguration { get { configurationStorage } set { applyExternalConfiguration(newValue.normalized()) } }
    var thumbCount: Int { thumbSliders.count }
    var thumbIdentitySet: Set<ObjectIdentifier> { Set(thumbSliders.values.map { ObjectIdentifier($0) }) }

    init(configuration: QuotaProgressColorConfiguration) {
        configurationStorage = configuration.normalized(); super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("quotaProgressThresholdSlider"); setAccessibilityRole(.group)
        let contentView = NSView(frame: .zero)
        popoverLabel.font = NSFont.toolTipsFont(ofSize: NSFont.smallSystemFontSize)
        popoverLabel.textColor = .labelColor
        popoverLabel.alignment = .center
        popoverLabel.isEditable = false
        popoverLabel.isSelectable = false
        popoverLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(popoverLabel)
        NSLayoutConstraint.activate([
            popoverLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 7),
            popoverLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -7),
            popoverLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            popoverLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5)
        ])
        let controller = NSViewController(); controller.view = contentView
        popover.contentViewController = controller; popover.behavior = .transient; popover.animates = false; reconcileThumbSliders()
    }
    required init?(coder: NSCoder) { nil }
    deinit { hoverWorkItem?.cancel(); popover.close() }
    func teardown() {
        hoverWorkItem?.cancel()
        hoverWorkItem = nil
        dismissPopover()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
            self.trackingAreaReference = nil
        }
        thumbSliders.values.forEach {
            $0.onTrackingChanged = nil
            $0.onTrackingEnded = nil
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { teardown() }
    }
    override var intrinsicContentSize: NSSize { NSSize(width: 300, height: 34) }
    private var trackRect: NSRect { bounds.insetBy(dx: 9, dy: 12) }
    private var activeBoundaries: [(QuotaProgressColor, Int)] { configurationStorage.enabledColorsInOrder.dropLast().compactMap { color in configurationStorage.boundary(after: color).map { (color, $0) } } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self); addTrackingArea(area); trackingAreaReference = area
    }
    override func layout() {
        super.layout(); let track = trackRect
        for (color, thumb) in thumbSliders {
            let value = configurationStorage.boundary(after: color) ?? 0
            thumb.frame = NSRect(x: track.minX - 8, y: track.midY - 14, width: track.width + 16, height: 28)
            if abs(thumb.doubleValue - Double(value)) > 0.01 { thumb.doubleValue = Double(value) }
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
    private func reconcileThumbSliders() {
        let wanted = Set(configurationStorage.enabledColorsInOrder.dropLast())
        for color in Array(thumbSliders.keys) where !wanted.contains(color) { thumbSliders[color]?.removeFromSuperview(); thumbSliders.removeValue(forKey: color) }
        for color in wanted where thumbSliders[color] == nil { let thumb = ThresholdThumbSlider(color: color); thumb.onTrackingChanged = { [weak self, weak thumb] value in self?.applyTrackedBoundaryChange(color: color, value: value, thumb: thumb) }; thumb.onTrackingEnded = { [weak self] in self?.finishTracking(color: color) }; thumbSliders[color] = thumb; addSubview(thumb) }
        needsLayout = true; needsDisplay = true
    }
    private func applyExternalConfiguration(_ value: QuotaProgressColorConfiguration) {
        let oldColors = configurationStorage.enabledColors; configurationStorage = value
        if oldColors != value.enabledColors { dismissPopover(); reconcileThumbSliders() }
        for (color, thumb) in thumbSliders {
            let boundary = value.boundary(after: color) ?? 0
            if abs(thumb.doubleValue - Double(boundary)) > 0.01 { thumb.doubleValue = Double(boundary) }
            thumb.lastSnappedValue = boundary
            thumb.updateAccessibilityValue(boundary)
        }
        needsDisplay = true; needsLayout = true
    }
    private func applyTrackedBoundaryChange(color: QuotaProgressColor, value: Double, thumb: ThresholdThumbSlider?) {
        let old = configurationStorage.boundary(after: color) ?? 0; let updated = configurationStorage.settingBoundary(after: color, to: QuotaThresholdSliderMath.snapped(value)); guard let actual = updated.boundary(after: color), actual != old else { return }
        thumb?.doubleValue = Double(actual)
        thumb?.updateAccessibilityValue(actual)
        if thumb?.lastSnappedValue != actual { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now); thumb?.lastSnappedValue = actual }
        configurationStorage = updated; onChange?(updated); sendAction(action, to: target); if activePopoverColor == color { updatePopoverAnchor(for: color) }; needsDisplay = true
    }
    private func finishTracking(color: QuotaProgressColor) {
        guard activePopoverColor == color else { return }
        let pointInWindow = window?.convertPoint(fromScreen: NSEvent.mouseLocation)
        let point = pointInWindow.map { convert($0, from: nil) }
        if let knob = knobRect(for: color), let point, knob.insetBy(dx: -5, dy: -5).contains(point) {
            updatePopoverAnchor(for: color)
        } else {
            dismissPopover()
        }
    }
    override func mouseMoved(with event: NSEvent) {
        hoverWorkItem?.cancel(); let point = convert(event.locationInWindow, from: nil); let color = activeBoundaries.first(where: { knobRect(for: $0.0)?.insetBy(dx: -5, dy: -5).contains(point) == true })?.0; activePopoverColor = color
        if let color { let item = DispatchWorkItem { [weak self] in self?.presentPopover(for: color) }; hoverWorkItem = item; DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item) } else { dismissPopover() }
    }
    override func mouseExited(with event: NSEvent) { hoverWorkItem?.cancel(); dismissPopover() }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let color = activeBoundaries.min(by: { abs((knobRect(for: $0.0)?.midX ?? 0) - point.x) < abs((knobRect(for: $1.0)?.midX ?? 0) - point.x) }),
              let thumb = thumbSliders[color.0] else { return }
        activePopoverColor = color.0
        presentPopover(for: color.0)
        // Let AppKit own the tracking loop even for a blank-track click. The
        // child receives the original window event and therefore gets the
        // native pressed/Liquid Glass state and mouse-up lifecycle.
        thumb.mouseDown(with: event)
    }
    private func knobRect(for color: QuotaProgressColor) -> NSRect? { guard let thumb = thumbSliders[color], let cell = thumb.cell as? NSSliderCell else { return nil }; return convert(cell.knobRect(flipped: thumb.isFlipped), from: thumb) }
    private func presentPopover(for color: QuotaProgressColor) { activePopoverColor = color; updatePopoverAnchor(for: color); if !popover.isShown, let rect = knobRect(for: color) { popover.show(relativeTo: rect, of: self, preferredEdge: .maxY) } }
    private func updatePopoverAnchor(for color: QuotaProgressColor) {
        guard let rect = knobRect(for: color) else { dismissPopover(); return }
        popoverLabel.stringValue = "\(configurationStorage.boundary(after: color) ?? 0)%"
        let labelSize = popoverLabel.fittingSize
        popover.contentSize = NSSize(width: ceil(labelSize.width) + 14, height: ceil(labelSize.height) + 10)
        if popover.isShown { popover.positioningRect = rect }
    }
    private func dismissPopover() { activePopoverColor = nil; popover.close() }
}
