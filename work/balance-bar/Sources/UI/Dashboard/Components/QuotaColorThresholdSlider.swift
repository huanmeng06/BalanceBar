import AppKit
import OSLog

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

/// The only view that AppKit tracks, preserving normal Force Click and
/// trackpad gesture handling with its untouched AppKit-provided cell.
private final class ThresholdInteractionSlider: NSSlider {
    var prepareForNativeTracking: ((NSEvent) -> Void)?
    var onTrackingBegan: (() -> Void)?
    var onTrackingChanged: ((Double) -> Void)?
    var onTrackingEnded: (() -> Void)?
    var onKeyboardStep: ((Int) -> Void)?

    init() {
        super.init(frame: .zero)
        minValue = 0
        maxValue = 100
        doubleValue = 0
        sliderType = .linear
        controlSize = .regular
        isContinuous = true
        numberOfTickMarks = 0
        trackFillColor = .clear
        target = self
        action = #selector(valueChanged(_:))
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityMinValue(0)
        setAccessibilityMaxValue(100)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func valueChanged(_ sender: NSSlider) {
        onTrackingChanged?(sender.doubleValue)
    }

    override func mouseDown(with event: NSEvent) {
        prepareForNativeTracking?(event)
        onTrackingBegan?()
        Self.logger.debug("quota native slider mouseDown type=\(event.type.rawValue, privacy: .public) pressure=\(event.pressure, privacy: .public)")
        super.mouseDown(with: event)
        Self.logger.debug("quota native slider mouseDown completed value=\(self.doubleValue, privacy: .public)")
        onTrackingEnded?()
    }

    override func keyDown(with event: NSEvent) {
        guard let characters = event.charactersIgnoringModifiers else {
            super.keyDown(with: event)
            return
        }
        switch characters {
        case "\u{F702}", "\u{F700}": onKeyboardStep?(-5)
        case "\u{F703}", "\u{F701}": onKeyboardStep?(5)
        default: super.keyDown(with: event)
        }
    }

    private static let logger = Logger(subsystem: "com.huanmeng06.BalanceBar", category: "QuotaThresholdSlider")
}

/// The continuous coloured track sits beneath the live stock slider knob.
private final class QuotaThresholdTrackView: NSView {
    weak var owner: QuotaColorThresholdSlider?

    override func draw(_ dirtyRect: NSRect) {
        owner?.drawTrack(in: self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Covers the stock slider's remaining bar material without drawing over the
/// active native knob or its pressed-state presentation.
private final class QuotaThresholdTrackCoverView: NSView {
    weak var owner: QuotaColorThresholdSlider?

    override func draw(_ dirtyRect: NSRect) {
        owner?.drawTrackCover(in: self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Inactive stock knobs remain above the active slider control. They are
/// display-only; all pointer events route to the one native interaction slider.
private final class QuotaThresholdPassiveKnobOverlayView: NSView {
    weak var owner: QuotaColorThresholdSlider?

    override func draw(_ dirtyRect: NSRect) {
        owner?.drawPassiveKnobs(in: self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
    private let interactionSlider = ThresholdInteractionSlider()
    private let trackView = QuotaThresholdTrackView()
    private let trackCover = QuotaThresholdTrackCoverView()
    private let passiveKnobOverlay = QuotaThresholdPassiveKnobOverlayView()
    private var passiveKnobCells: [QuotaProgressColor: NSSliderCell] = [:]
    private var activeBoundaryColor: QuotaProgressColor?
    private var activePopoverColor: QuotaProgressColor?
    private var trackingColor: QuotaProgressColor?
    private var previousTrackingHoleRect: NSRect?
    private var focusedColor: QuotaProgressColor?
    private var lastSnappedValues: [QuotaProgressColor: Int] = [:]
    private let popover = DashboardTextTooltip.makePopover()
    private let popoverLabel = NSTextField(labelWithString: "")
    private var hoverWorkItem: DispatchWorkItem?
    private var trackingAreaReference: NSTrackingArea?
    // Temporary A/B switch for the focus-sensitive native tracking failure.
    // Popovers are deliberately absent until the stock slider path is proven.
    private let popoverEnabledForTrackingDiagnosis = false

    var onChange: ((QuotaProgressColorConfiguration) -> Void)?
    var configuration: QuotaProgressColorConfiguration {
        get { configurationStorage }
        set { applyExternalConfiguration(newValue.normalized()) }
    }
    /// Logical thumb count: one boundary between each adjacent enabled colour.
    var thumbCount: Int { activeBoundaries.count }
    var thumbIdentitySet: Set<ObjectIdentifier> { [ObjectIdentifier(interactionSlider)] }
    var nativeThumbSliders: [NSSlider] { [interactionSlider] }
    var passiveKnobCount: Int { passiveKnobCells.count }
    var usesNSSliderThumbs: Bool { interactionSlider.superview === self }
    var usesCustomSliderCell: Bool { !(interactionSlider.cell is NSSliderCell) }
    var debugThumbStates: [DebugThumbState] {
        layoutSubtreeIfNeeded()
        return activeBoundaries.compactMap { color, value in
            guard let knob = knobRect(for: color), let cell = cell(for: color) else { return nil }
            return DebugThumbState(
                color: color,
                minimumValue: cell.minValue,
                maximumValue: cell.maxValue,
                value: Double(value),
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

        interactionSlider.prepareForNativeTracking = { [weak self] event in
            self?.prepareBoundaryForNativeTracking(event)
        }
        interactionSlider.onTrackingBegan = { [weak self] in self?.beginTracking() }
        interactionSlider.onTrackingChanged = { [weak self] value in self?.applyInteractionValue(value) }
        interactionSlider.onTrackingEnded = { [weak self] in self?.finishTracking() }
        interactionSlider.onKeyboardStep = { [weak self] delta in self?.stepFocusedBoundary(by: delta) }
        trackView.owner = self
        trackView.wantsLayer = false
        addSubview(trackView)
        addSubview(interactionSlider)
        trackCover.owner = self
        trackCover.wantsLayer = false
        addSubview(trackCover)
        passiveKnobOverlay.owner = self
        passiveKnobOverlay.wantsLayer = false
        addSubview(passiveKnobOverlay)

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
        reconcileKnobCells()
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
        previousTrackingHoleRect = nil
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

    private var sliderFrame: NSRect {
        NSRect(x: bounds.minX, y: bounds.midY - 14, width: bounds.width, height: 28)
    }
    private var nativeTrackRect: NSRect {
        guard let cell = interactionSlider.cell as? NSSliderCell else {
            return sliderFrame
        }
        return interactionSlider.convert(cell.barRect(flipped: interactionSlider.isFlipped), to: self)
    }
    private var activeBoundaries: [(QuotaProgressColor, Int)] {
        configurationStorage.enabledColorsInOrder.dropLast().compactMap { color in
            configurationStorage.boundary(after: color).map { (color, $0) }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        guard popoverEnabledForTrackingDiagnosis else {
            trackingAreaReference = nil
            return
        }
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
        trackView.frame = bounds
        interactionSlider.frame = sliderFrame
        trackCover.frame = bounds
        passiveKnobOverlay.frame = bounds
        synchronizeKnobCells()
        if let activePopoverColor { updatePopoverAnchor(for: activePopoverColor) }
        invalidateVisuals()
    }

    private func reconcileKnobCells() {
        let wanted = Set(activeBoundaries.map(\.0))
        for color in Array(passiveKnobCells.keys) where !wanted.contains(color) {
            passiveKnobCells.removeValue(forKey: color)
            lastSnappedValues.removeValue(forKey: color)
        }
        for color in wanted where passiveKnobCells[color] == nil {
            let cell = NSSliderCell()
            cell.minValue = 0
            cell.maxValue = 100
            cell.sliderType = .linear
            cell.numberOfTickMarks = 0
            cell.controlView = interactionSlider
            passiveKnobCells[color] = cell
        }
        if activeBoundaryColor == nil || !wanted.contains(activeBoundaryColor!) {
            activeBoundaryColor = activeBoundaries.first?.0
        }
        synchronizeKnobCells()
        needsLayout = true
        needsDisplay = true
    }

    private func synchronizeKnobCells() {
        guard interactionSlider.frame.width > 0 else { return }
        for (color, value) in activeBoundaries {
            guard let cell = passiveKnobCells[color] else { continue }
            cell.minValue = 0
            cell.maxValue = 100
            cell.doubleValue = Double(value)
            cell.controlView = interactionSlider
            lastSnappedValues[color] = value
        }
        guard let activeBoundaryColor,
              let value = configurationStorage.boundary(after: activeBoundaryColor) else { return }
        if abs(interactionSlider.doubleValue - Double(value)) > 0.01 {
            interactionSlider.doubleValue = Double(value)
        }
        updateInteractionAccessibility(for: activeBoundaryColor, value: value)
    }

    private func applyExternalConfiguration(_ value: QuotaProgressColorConfiguration) {
        guard value != configurationStorage else { return }
        let oldColors = configurationStorage.enabledColors
        configurationStorage = value
        if oldColors != value.enabledColors {
            trackingColor = nil
            if let focusedColor, !value.enabledColors.contains(focusedColor) { self.focusedColor = nil }
            dismissPopover()
            reconcileKnobCells()
        } else {
            synchronizeKnobCells()
        }
        needsDisplay = true
        needsLayout = true
        invalidateVisuals()
    }

    private func prepareBoundaryForNativeTracking(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let color = nearestBoundary(to: point.x),
              let value = configurationStorage.boundary(after: color) else { return }
        activeBoundaryColor = color
        focusedColor = color
        interactionSlider.doubleValue = Double(value)
        updateInteractionAccessibility(for: color, value: value)
    }

    private func beginTracking() {
        guard let activeBoundaryColor else { return }
        trackingColor = activeBoundaryColor
        previousTrackingHoleRect = trackingColor.flatMap { knobRect(for: $0) }
        hoverWorkItem?.cancel()
        invalidateVisuals()
        commitTrackingVisuals()
        guard popoverEnabledForTrackingDiagnosis else { return }
        activePopoverColor = activeBoundaryColor
        presentPopover(for: activeBoundaryColor)
    }

    private func applyInteractionValue(_ value: Double) {
        guard let color = activeBoundaryColor else { return }
        applyTrackedBoundaryChange(color: color, value: value)
    }

    private func applyTrackedBoundaryChange(color: QuotaProgressColor, value: Double) {
        let old = configurationStorage.boundary(after: color) ?? 0
        let updated = configurationStorage.settingBoundary(after: color, to: QuotaThresholdSliderMath.snapped(value))
        guard let actual = updated.boundary(after: color) else { return }
        interactionSlider.doubleValue = Double(actual)
        passiveKnobCells[color]?.doubleValue = Double(actual)
        configurationStorage = updated
        updateInteractionAccessibility(for: color, value: actual)
        if trackingColor == color { updatePopoverAnchor(for: color, value: actual) }
        let currentTrackingHoleRect = trackingColor.flatMap { knobRect(for: $0) }
        guard actual != old else {
            previousTrackingHoleRect = currentTrackingHoleRect
            return
        }
        let coverDirtyRect = trackingCoverDirtyRect(
            from: previousTrackingHoleRect,
            to: currentTrackingHoleRect
        )
        invalidateVisuals(trackCoverDirtyRect: coverDirtyRect)
        commitTrackingVisuals()
        previousTrackingHoleRect = currentTrackingHoleRect
        if QuotaThresholdSliderMath.shouldEmitAlignmentHaptic(lastSnappedValue: lastSnappedValues[color], newValue: actual) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        lastSnappedValues[color] = actual
        onChange?(updated)
        sendAction(action, to: target)
        needsDisplay = true
    }

    private func stepFocusedBoundary(by delta: Int) {
        guard let color = focusedColor ?? activeBoundaryColor,
              let value = configurationStorage.boundary(after: color) else { return }
        activeBoundaryColor = color
        applyTrackedBoundaryChange(color: color, value: Double(value + delta))
    }

    private func finishTracking() {
        guard let color = trackingColor else { return }
        defer {
            let coverDirtyRect = trackingCoverDirtyRect(from: previousTrackingHoleRect, to: nil)
            trackingColor = nil
            previousTrackingHoleRect = nil
            invalidateVisuals(trackCoverDirtyRect: coverDirtyRect)
            commitTrackingVisuals()
        }
        guard activePopoverColor == color else { dismissPopover(); return }
        if let point = currentMousePoint(), let knob = knobRect(for: color), knob.insetBy(dx: -5, dy: -5).contains(point) {
            updatePopoverAnchor(for: color)
        } else {
            dismissPopover()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard popoverEnabledForTrackingDiagnosis else { return }
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
        guard popoverEnabledForTrackingDiagnosis else { return }
        guard trackingColor == nil else { return }
        hoverWorkItem?.cancel()
        dismissPopover()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// The overlay is visual-only. Routing every point to the single native
    /// slider avoids the former sibling-selection path while ensuring AppKit
    /// receives the original trackpad event.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? interactionSlider : nil
    }

    func applyRawThumbValueForTesting(_ value: Double, after color: QuotaProgressColor) {
        activeBoundaryColor = color
        applyTrackedBoundaryChange(color: color, value: value)
    }

    private func cell(for color: QuotaProgressColor) -> NSSliderCell? {
        color == activeBoundaryColor ? interactionSlider.cell as? NSSliderCell : passiveKnobCells[color]
    }

    private func knobRect(for color: QuotaProgressColor) -> NSRect? {
        guard let cell = cell(for: color) else { return nil }
        let knob = cell.knobRect(flipped: interactionSlider.isFlipped)
        return interactionSlider.convert(knob, to: self)
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

    private func updateInteractionAccessibility(for color: QuotaProgressColor, value: Int) {
        let label: String
        switch color {
        case .red: label = tr(.keyDashboardMenuPageColorRed)
        case .orange: label = tr(.keyDashboardMenuPageColorOrange)
        case .yellow: label = tr(.keyDashboardMenuPageColorYellow)
        case .green: label = tr(.keyDashboardMenuPageColorGreen)
        }
        interactionSlider.setAccessibilityLabel(label)
        interactionSlider.setAccessibilityValue(value)
        interactionSlider.setAccessibilityValueDescription("\(value)%")
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

    private func invalidateVisuals(trackCoverDirtyRect: NSRect? = nil) {
        trackView.needsDisplay = true
        if let trackCoverDirtyRect {
            trackCover.setNeedsDisplay(trackCoverDirtyRect)
        } else {
            trackCover.needsDisplay = true
        }
        passiveKnobOverlay.needsDisplay = true
        interactionSlider.needsDisplay = true
    }

    private func trackingCoverDirtyRect(from oldHole: NSRect?, to newHole: NSRect?) -> NSRect? {
        let holes = [oldHole, newHole].compactMap { $0 }.map { trackCover.convert($0, from: self) }
        guard var dirty = holes.first else { return nil }
        for hole in holes.dropFirst() { dirty = dirty.union(hole) }
        return dirty.insetBy(dx: -1, dy: -1)
    }

    /// The ownership switch from passive to live native knob must be committed
    /// before AppKit enters the slider tracking loop, otherwise its first
    /// pressed frame can retain the idle backing-store contents.
    private func commitTrackingVisuals() {
        trackCover.displayIfNeeded()
        passiveKnobOverlay.displayIfNeeded()
        interactionSlider.displayIfNeeded()
    }

    fileprivate func drawTrack(in trackView: QuotaThresholdTrackView) {
        drawColorTrack(in: trackView, excludingActiveKnob: false)
    }

    fileprivate func drawTrackCover(in trackCover: QuotaThresholdTrackCoverView) {
        drawColorTrack(in: trackCover, excludingActiveKnob: true)
    }

    private func drawColorTrack(in drawingView: NSView, excludingActiveKnob: Bool) {
        let track = drawingView.convert(nativeTrackRect, from: self)
        let colorTrack = NSRect(x: track.minX, y: track.midY - 3, width: track.width, height: 6)
        let boundaryXs = activeBoundaries.map { color, _ in
            knobRect(for: color).map { drawingView.convert($0, from: self).midX } ?? track.minX
        }
        let segmentXs = [colorTrack.minX] + boundaryXs + [colorTrack.maxX]
        let activeKnob = excludingActiveKnob
            ? trackingColor.flatMap { knobRect(for: $0) }.map { drawingView.convert($0, from: self) }
            : nil

        let trackPath = NSBezierPath(
            roundedRect: colorTrack,
            xRadius: colorTrack.height / 2,
            yRadius: colorTrack.height / 2
        )
        NSGraphicsContext.saveGraphicsState()
        trackPath.addClip()
        for (index, color) in configurationStorage.enabledColorsInOrder.enumerated() {
            let x0 = segmentXs[index]
            let x1 = segmentXs[index + 1]
            color.nsColor.setFill()
            fillTrackRect(
                NSRect(x: x0, y: colorTrack.minY, width: max(0, x1 - x0), height: colorTrack.height),
                excluding: activeKnob
            )
        }
        NSGraphicsContext.restoreGraphicsState()

        NSColor.tertiaryLabelColor.setStroke()
        for tick in QuotaThresholdSliderMath.visibleTicks(width: bounds.width, thumbValues: activeBoundaries.map(\.1)) {
            let x = activeBoundaries.first(where: { $0.1 == tick })
                .flatMap { knobRect(for: $0.0).map { drawingView.convert($0, from: self).midX } }
                ?? track.minX + track.width * CGFloat(tick) / 100
            guard activeKnob?.contains(NSPoint(x: x, y: track.midY)) != true else { continue }
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: track.minY - 3))
            path.line(to: NSPoint(x: x, y: track.minY))
            path.stroke()
        }
    }

    private func fillTrackRect(_ rect: NSRect, excluding hole: NSRect?) {
        guard rect.width > 0 else { return }
        guard let hole, hole.intersects(rect) else {
            NSBezierPath(rect: rect).fill()
            return
        }
        let left = NSRect(x: rect.minX, y: rect.minY, width: max(0, hole.minX - rect.minX), height: rect.height)
        let right = NSRect(x: max(rect.minX, hole.maxX), y: rect.minY, width: max(0, rect.maxX - hole.maxX), height: rect.height)
        if left.width > 0 { NSBezierPath(rect: left).fill() }
        if right.width > 0 { NSBezierPath(rect: right).fill() }
    }

    fileprivate func drawPassiveKnobs(in overlay: QuotaThresholdPassiveKnobOverlayView) {
        for color in activeBoundaries.map(\.0) where color != trackingColor {
            guard let cell = passiveKnobCells[color] else { continue }
            let knob = interactionSlider.convert(cell.knobRect(flipped: interactionSlider.isFlipped), to: self)
            cell.drawKnob(overlay.convert(knob, from: self))
        }
    }

}
