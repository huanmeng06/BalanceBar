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
        return Array(Set(stride(from: 0, through: 100, by: interval))
            .union([0, 50, 100]).union(thumbValues)).sorted()
    }
}

final class QuotaColorThresholdSlider: NSControl {
    var configuration: QuotaProgressColorConfiguration { didSet { if configuration != configuration.normalized() { configuration = configuration.normalized() }; needsDisplay = true } }
    var onChange: ((QuotaProgressColorConfiguration) -> Void)?
    private var draggedColor: QuotaProgressColor?
    private var hoveredColor: QuotaProgressColor?
    private var trackingAreaReference: NSTrackingArea?
    private let popover = NSPopover()
    private let popoverLabel = NSTextField(labelWithString: "")
    private var hoverWorkItem: DispatchWorkItem?
    private lazy var nativeCell: NSSliderCell = { let cell = NSSliderCell(); cell.controlSize = .regular; return cell }()

    init(configuration: QuotaProgressColorConfiguration) {
        self.configuration = configuration.normalized()
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("quotaProgressThresholdSlider")
        setAccessibilityRole(.slider)
        let controller = NSViewController(); controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 54, height: 28))
        popoverLabel.frame = NSRect(x: 8, y: 5, width: 38, height: 18); popoverLabel.alignment = .center
        controller.view.addSubview(popoverLabel); popover.contentViewController = controller; popover.behavior = .transient; popover.animates = false
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: 300, height: 34) }
    private var trackRect: NSRect { bounds.insetBy(dx: 9, dy: 12) }
    private var activeBoundaries: [(QuotaProgressColor, Int)] {
        configuration.enabledColorsInOrder.dropLast().compactMap { color in configuration.boundary(after: color).map { (color, $0) } }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); trackingAreaReference = area
    }
    override func draw(_ dirtyRect: NSRect) {
        let track = trackRect, colors = configuration.enabledColorsInOrder, boundaries = activeBoundaries.map(\.1)
        let points = [0] + boundaries + [100]
        for (index, color) in colors.enumerated() {
            let x0 = track.minX + track.width * CGFloat(points[index]) / 100
            let x1 = track.minX + track.width * CGFloat(points[index + 1]) / 100
            color.nsColor.setFill(); NSBezierPath(roundedRect: NSRect(x: x0, y: track.midY - 3, width: max(1, x1 - x0), height: 6), xRadius: 3, yRadius: 3).fill()
        }
        NSColor.tertiaryLabelColor.setStroke()
        for tick in QuotaThresholdSliderMath.visibleTicks(width: bounds.width, thumbValues: boundaries) {
            let x = track.minX + track.width * CGFloat(tick) / 100
            let path = NSBezierPath(); path.move(to: NSPoint(x: x, y: track.minY - 3)); path.line(to: NSPoint(x: x, y: track.minY)); path.stroke()
        }
        for (_, value) in activeBoundaries { nativeCell.drawKnob(NSRect(x: x(for: value) - 7, y: track.midY - 10, width: 14, height: 20)) }
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        draggedColor = nearestBoundary(to: point.x)?.0
        guard let draggedColor else { return }
        update(color: draggedColor, event: event, showPopover: true)
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            update(color: draggedColor, event: next, showPopover: true)
        }
        self.draggedColor = nil
        if hoveredColor == nil { popover.close() }
        sendAction(action, to: target)
    }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil); hoveredColor = nearestBoundary(to: point.x, maximumDistance: 9)?.0
        hoverWorkItem?.cancel()
        if let hoveredColor {
            let item = DispatchWorkItem { [weak self] in guard self?.hoveredColor == hoveredColor else { return }; self?.showPopover(for: hoveredColor) }
            hoverWorkItem = item; DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
        } else { popover.close() }
    }
    override func mouseExited(with event: NSEvent) { hoverWorkItem?.cancel(); hoveredColor = nil; if draggedColor == nil { popover.close() } }
    private func update(color: QuotaProgressColor, event: NSEvent, showPopover: Bool) {
        let point = convert(event.locationInWindow, from: nil)
        let proposed = QuotaThresholdSliderMath.snapped(Double((point.x - trackRect.minX) / max(1, trackRect.width) * 100))
        let old = configuration.boundary(after: color) ?? proposed
        let updated = configuration.settingBoundary(after: color, to: proposed)
        let actual = updated.boundary(after: color) ?? old
        if actual != old {
            configuration = updated
            for _ in QuotaThresholdSliderMath.crossedTicks(from: old, to: actual) { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            onChange?(configuration); sendAction(action, to: target)
        }
        if showPopover { self.showPopover(for: color) }
    }
    private func x(for value: Int) -> CGFloat { trackRect.minX + trackRect.width * CGFloat(value) / 100 }
    private func nearestBoundary(to x: CGFloat, maximumDistance: CGFloat = .greatestFiniteMagnitude) -> (QuotaProgressColor, Int)? {
        activeBoundaries.min { abs(self.x(for: $0.1) - x) < abs(self.x(for: $1.1) - x) }.flatMap { abs(self.x(for: $0.1) - x) <= maximumDistance ? $0 : nil }
    }
    private func showPopover(for color: QuotaProgressColor) {
        guard let value = configuration.boundary(after: color) else { return }
        popoverLabel.stringValue = "\(value)%"
        let rect = NSRect(x: x(for: value) - 1, y: trackRect.midY, width: 2, height: 2)
        if !popover.isShown { popover.show(relativeTo: rect, of: self, preferredEdge: .maxY) }
    }
}
